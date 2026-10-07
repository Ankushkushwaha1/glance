//
//  AppLockController.swift
//  glance
//
//  Orchestrates face verification for locked apps.
//

import AppKit
import Foundation
import Combine

@Observable @MainActor
final class AppLockController {
    
    static let shared = AppLockController()
    
    private let watcher = AppLockWatcher()
    private let sessionBook = AppLockSessionBook.shared
    private let shieldController = AppLockShieldController.shared
    
    private(set) var activeApp: NSRunningApplication?
    private var queue: [NSRunningApplication] = []
    var isVerifying: Bool = false
    
    private var cancellables = Set<AnyCancellable>()
    private var verificationTask: Task<Void, Never>?
    
    private init() {
        setupWatcher()
        setupSystemEventHandling()
    }
    
    func start() {
        watcher.start()
    }
    
    func stop() {
        watcher.stop()
        shieldController.dismiss()
        sessionsRevokeAll()
    }
    
    private func setupWatcher() {
        watcher.onLockedAppDetected = { [weak self] app in
            self?.handleLockedAppDetected(app)
        }
        
        watcher.onBackgroundLocked = { [weak self] app in
            guard let bundleId = app.bundleIdentifier else { return }
            if !(self?.sessionBook.hasValidSession(for: bundleId) ?? false) {
                app.hide()
            }
        }
        
        watcher.onFocusLost = { [weak self] bundleId in
            self?.sessionBook.recordFocusLoss(for: bundleId)
        }
        
        watcher.onAppTerminated = { [weak self] bundleId in
            self?.sessionBook.removeSession(for: bundleId)
        }
    }
    
    private func handleLockedAppDetected(_ app: NSRunningApplication) {
        guard let bundleId = app.bundleIdentifier else { return }
        
        if sessionBook.hasValidSession(for: bundleId) {
            return
        }
        
        if isVerifying {
            if activeApp != app && !queue.contains(app) {
                queue.append(app)
            }
            return
        }
        
        startVerification(for: app)
    }
    
    private func startVerification(for app: NSRunningApplication) {
        isVerifying = true
        activeApp = app
        
        // Steal focus immediately
        NSApp.activate(ignoringOtherApps: true)
        
        // Hide the locked app
        app.hide()
        
        // Show shield
        shieldController.present(for: app,
                                 onTryAgain: { [weak self] in
                                     self?.retryVerification()
                                 },
                                 onQuit: { [weak self] in
                                     self?.quitActiveApp()
                                 })
        
        runFaceVerification()
    }
    
    private func runFaceVerification() {
        verificationTask?.cancel()
        
        verificationTask = Task {
            let pipeline = FaceRecognitionPipeline()
            let camera = CameraManager()
            
            do {
                try await camera.start()
                let start = Date()
                var success = false
                
                while Date().timeIntervalSince(start) < 5.0 {
                    if Task.isCancelled { break }
                    
                    guard let frame = await camera.captureFrame() else {
                        try await Task.sleep(nanoseconds: 100_000_000)
                        continue
                    }
                    
                    let isLive = await LivenessAnalyzer.shared.analyze(frame)
                    guard isLive else {
                        try await Task.sleep(nanoseconds: 100_000_000)
                        continue
                    }
                    
                    let identities = FaceEnrollmentStore.shared.activeIdentities
                    
                    if let embedding = try? await pipeline.extractEmbedding(from: frame) {
                        var bestScore: Float = 0.0
                        for identity in identities {
                            for enrolledEmbedding in identity.embeddings {
                                let score = FaceEmbedding.cosineSimilarity(embedding, enrolledEmbedding)
                                if score > bestScore {
                                    bestScore = score
                                }
                            }
                        }
                        
                        if bestScore >= GlanceSettings.shared.matchThreshold {
                            success = true
                            break
                        }
                    }
                    
                    try await Task.sleep(nanoseconds: 100_000_000)
                }
                
                await camera.stop()
                
                if Task.isCancelled { return }
                
                if success {
                    handleVerificationSuccess()
                } else {
                    handleVerificationFailure()
                }
                
            } catch {
                await camera.stop()
                if !Task.isCancelled {
                    handleVerificationFailure()
                }
            }
        }
    }
    
    private func handleVerificationSuccess() {
        guard let app = activeApp, let bundleId = app.bundleIdentifier else { return }
        
        sessionBook.grantSession(for: bundleId)
        shieldController.dismiss()
        
        app.unhide()
        app.activate(options: .activateIgnoringOtherApps)
        
        finishCurrentVerification()
    }
    
    private func handleVerificationFailure() {
        shieldController.showFailure()
    }
    
    private func retryVerification() {
        shieldController.showVerifying()
        runFaceVerification()
    }
    
    private func quitActiveApp() {
        verificationTask?.cancel()
        activeApp?.hide()
        activeApp?.terminate()
        shieldController.dismiss()
        finishCurrentVerification()
    }
    
    private func finishCurrentVerification() {
        activeApp = nil
        isVerifying = false
        
        if let nextApp = queue.first {
            queue.removeFirst()
            startVerification(for: nextApp)
        }
    }
    
    private func sessionsRevokeAll() {
        sessionBook.revokeAll()
        activeApp?.hide()
        for app in queue {
            app.hide()
        }
    }
    
    private func setupSystemEventHandling() {
        let center = NSWorkspace.shared.notificationCenter
        let distCenter = DistributedNotificationCenter.default()
        
        center.publisher(for: NSWorkspace.willSleepNotification)
            .sink { [weak self] _ in self?.sessionsRevokeAll() }
            .store(in: &cancellables)
            
        center.publisher(for: NSWorkspace.screensDidSleepNotification)
            .sink { [weak self] _ in self?.sessionsRevokeAll() }
            .store(in: &cancellables)
            
        center.publisher(for: NSWorkspace.sessionDidResignActiveNotification)
            .sink { [weak self] _ in self?.sessionsRevokeAll() }
            .store(in: &cancellables)
            
        distCenter.publisher(for: Notification.Name("com.apple.screenIsLocked"))
            .sink { [weak self] _ in self?.sessionsRevokeAll() }
            .store(in: &cancellables)
    }
}
