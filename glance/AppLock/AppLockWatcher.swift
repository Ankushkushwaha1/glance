//
//  AppLockWatcher.swift
//  glance
//
//  Monitors app launches and activations to detect locked apps.
//

import AppKit
import Foundation
import Combine

@Observable @MainActor
final class AppLockWatcher {
    
    var onLockedAppDetected: ((NSRunningApplication) -> Void)?
    var onBackgroundLocked: ((NSRunningApplication) -> Void)?
    var onFocusLost: ((String) -> Void)?
    var onAppTerminated: ((String) -> Void)?
    
    private var runningObservation: NSKeyValueObservation?
    private var cancellables = Set<AnyCancellable>()
    private var reconcileTimer: Timer?
    
    func start() {
        // 1. KVO on NSWorkspace.shared.runningApplications (earliest signal)
        runningObservation = NSWorkspace.shared.observe(\.runningApplications, options: [.old, .new]) { [weak self] workspace, change in
            guard let self = self else { return }
            
            if let newApps = change.newValue, let oldApps = change.oldValue {
                let addedApps = Set(newApps).subtracting(Set(oldApps))
                for app in addedApps {
                    Task { @MainActor in
                        self.consider(app)
                    }
                }
            }
        }
        
        // 2. NSWorkspace notifications
        let center = NSWorkspace.shared.notificationCenter
        
        center.publisher(for: NSWorkspace.didActivateApplicationNotification)
            .sink { [weak self] notification in
                guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                self?.consider(app, isActivation: true)
            }
            .store(in: &cancellables)
            
        center.publisher(for: NSWorkspace.didUnhideApplicationNotification)
            .sink { [weak self] notification in
                guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                self?.consider(app, isActivation: true)
            }
            .store(in: &cancellables)
            
        center.publisher(for: NSWorkspace.didDeactivateApplicationNotification)
            .sink { [weak self] notification in
                guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      let bundleId = app.bundleIdentifier else { return }
                self?.onFocusLost?(bundleId)
            }
            .store(in: &cancellables)
            
        center.publisher(for: NSWorkspace.didTerminateApplicationNotification)
            .sink { [weak self] notification in
                guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      let bundleId = app.bundleIdentifier else { return }
                self?.onAppTerminated?(bundleId)
            }
            .store(in: &cancellables)
            
        // 3. Reconcile timer
        reconcileTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                for app in NSWorkspace.shared.runningApplications {
                    self.consider(app)
                }
            }
        }
    }
    
    func stop() {
        runningObservation?.invalidate()
        runningObservation = nil
        
        cancellables.removeAll()
        
        reconcileTimer?.invalidate()
        reconcileTimer = nil
    }
    
    private func consider(_ app: NSRunningApplication, isActivation: Bool = false) {
        guard let bundleId = app.bundleIdentifier else { return }
        
        // Check if the app is locked
        let isLocked = GlanceSettings.shared.lockedAppBundleIDs.contains(bundleId)
        guard isLocked else { return }
        
        if isActivation || app.isActive {
            onLockedAppDetected?(app)
        } else {
            onBackgroundLocked?(app)
        }
    }
}
