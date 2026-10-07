//
//  AppLockSessionBook.swift
//  glance
//
//  Tracks active unlock sessions for applications.
//

import Foundation

/// In-memory tracker for unlocked application sessions.
@MainActor
public final class AppLockSessionBook {
    private struct Session {
        let policy: RelockPolicy
        let grantedAt: TimeInterval // Monotonic system uptime
        var focusLostAt: TimeInterval? // Monotonic system uptime when focus was lost
    }
    
    // Volatile storage of active sessions
    private var sessions: [String: Session] = [:]
    
    public init() {}
    
    /// Monotonic clock for time tracking (prevents time-change bypass)
    private var currentUptime: TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }
    
    /// Grants an unlock session for the specified app.
    public func grant(_ bundleID: String, policy: RelockPolicy) {
        sessions[bundleID] = Session(policy: policy, grantedAt: currentUptime, focusLostAt: nil)
    }
    
    /// Checks if a session is still valid according to its policy.
    public func isUnlocked(_ bundleID: String) -> Bool {
        guard let session = sessions[bundleID] else {
            return false
        }
        
        let now = currentUptime
        
        switch session.policy {
        case .everyTime:
            // If it has lost focus at all, it's locked.
            // If it currently has focus, focusLostAt is nil, so it's unlocked.
            return session.focusLostAt == nil
            
        case .afterMinutes(let minutes):
            let seconds = TimeInterval(minutes * 60)
            return (now - session.grantedAt) < seconds
            
        case .afterFocusLossMinutes(let minutes):
            if let lostAt = session.focusLostAt {
                let seconds = TimeInterval(minutes * 60)
                return (now - lostAt) < seconds
            }
            // If it hasn't lost focus, it remains unlocked
            return true
        }
    }
    
    /// Records when a locked app loses focus.
    public func focusLost(_ bundleID: String) {
        if var session = sessions[bundleID] {
            // Only record the first time focus is lost if it wasn't already recorded
            if session.focusLostAt == nil {
                session.focusLostAt = currentUptime
                sessions[bundleID] = session
            }
        }
    }
    
    /// Records when a locked app gains focus.
    public func focusGained(_ bundleID: String) {
        guard var session = sessions[bundleID] else { return }
        
        if isUnlocked(bundleID) {
            switch session.policy {
            case .afterFocusLossMinutes:
                // Returning resets the focus loss timer
                session.focusLostAt = nil
                sessions[bundleID] = session
            case .everyTime, .afterMinutes:
                // No change needed
                break
            }
        } else {
            // Clean up invalid session
            revoke(bundleID)
        }
    }
    
    /// Clears all active sessions (e.g., used on system sleep or screen lock).
    public func revokeAll() {
        sessions.removeAll()
    }
    
    /// Revokes a single app's session.
    public func revoke(_ bundleID: String) {
        sessions.removeValue(forKey: bundleID)
    }
}
