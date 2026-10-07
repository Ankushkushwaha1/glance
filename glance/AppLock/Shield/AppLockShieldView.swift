//
//  AppLockShieldView.swift
//  glance
//
//  A SwiftUI view displayed on the shield panel.
//

import SwiftUI
import AppKit

enum ShieldState {
    case idle
    case verifying
    case success
    case failed
}

@Observable
final class AppLockShieldModel {
    var appName: String = ""
    var appIcon: NSImage? = nil
    var state: ShieldState = .idle
    var onTryAgain: (() -> Void)? = nil
    var onQuitApp: (() -> Void)? = nil
}

struct AppLockShieldView: View {
    var model: AppLockShieldModel
    @Environment(\.accessibilityReduceTransparency) var reduceTransparency
    
    @State private var isPulsing = false
    
    var body: some View {
        ZStack {
            // Background
            if reduceTransparency {
                Color.black.opacity(0.6)
                    .ignoresSafeArea()
            } else {
                VisualEffectView(material: .hudWindow, blendingMode: .behindWindow)
                    .ignoresSafeArea()
                Color.black.opacity(0.3)
                    .ignoresSafeArea()
            }
            
            // Centered Card
            VStack(spacing: 24) {
                if let icon = model.appIcon {
                    Image(nsImage: icon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 64, height: 64)
                } else {
                    Image(systemName: "app.fill")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 64, height: 64)
                        .foregroundColor(.gray)
                }
                
                Text(model.appName)
                    .font(.title2)
                    .fontWeight(.bold)
                    .foregroundColor(.white)
                
                VStack(spacing: 16) {
                    if model.state == .verifying {
                        Text("Verifying…")
                            .font(.headline)
                            .foregroundColor(.white.opacity(0.8))
                        
                        Circle()
                            .fill(Color.blue) // Use GlanceTheme.accent in production
                            .frame(width: 24, height: 24)
                            .scaleEffect(isPulsing ? 1.2 : 0.8)
                            .opacity(isPulsing ? 0.5 : 1.0)
                            .animation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true), value: isPulsing)
                            .onAppear {
                                isPulsing = true
                            }
                    } else if model.state == .failed {
                        Text("Face not recognized")
                            .font(.headline)
                            .foregroundColor(.red)
                        
                        HStack(spacing: 16) {
                            Button("Try Again") {
                                model.onTryAgain?()
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.blue) // Use GlanceTheme.accent in production
                            
                            Button("Quit App") {
                                model.onQuitApp?()
                            }
                            .buttonStyle(.bordered)
                            .tint(.red)
                        }
                    } else if model.state == .success {
                        Text("Unlocked")
                            .font(.headline)
                            .foregroundColor(.green)
                    }
                }
                .frame(height: 60)
            }
            .padding(40)
            .background(
                RoundedRectangle(cornerRadius: 24)
                    .fill(Color.black.opacity(0.5))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 24)
                    .stroke(Color.white.opacity(0.1), lineWidth: 1)
            )
        }
        .animation(.easeInOut, value: model.state)
    }
}
