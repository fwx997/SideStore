// zh-patch: Check VPN availability before device work, including cellular refresh.
import Foundation
import UIKit

@MainActor
enum VPNAppManager {
    private static var isOpening = false
    private static var connectionHandoff: ConnectionHandoff?
    private static let connectionPollNanoseconds: UInt64 = 250_000_000
    private static let foregroundConnectionTimeout: TimeInterval = 15
    private static let totalConnectionTimeout: TimeInterval = 300

    @MainActor private final class ConnectionHandoff {
        var task: Task<Void, Never>?
        var result: Bool?
        var waiters = 0
    }

    static var isForeground: Bool {
        UIApplication.shared.applicationState == .active &&
        UIApplication.shared.connectedScenes.contains { $0.activationState == .foregroundActive }
    }

    nonisolated static var isLocalVPNMissing: Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        guard ConnectionConfig.shared.useLocalVPN else { return false }
        let allowIPv6 = ConnectionConfig.shared.overrideTunnelPeerIp.contains(":")
        return !minimuxer.network.activeInterfaces.contains {
            LocalVPNDetection.isTunnel(name: $0.name, address: $0.ip, allowIPv6: allowIPv6)
        }
        #endif
    }

    static func requireVPN(allowAppLaunch: Bool = true) async throws {
        // Preserve the existing background readiness/timing path. Only a manual
        // operation may add a preflight or hand off to another app.
        guard VPNOperationContext.isInteractive else { return }
        try Task.checkCancellation()
        guard isLocalVPNMissing || (allowAppLaunch && connectionHandoff != nil) else { return }
        debugLog("[VPNAppManager] Local VPN is not connected; checking automatic handoff before transport.")
        if allowAppLaunch, try await automaticallyOpenIfNeeded() {
            try Task.checkCancellation()
            if isForeground && !isLocalVPNMissing { return }
        }
        try Task.checkCancellation()
        throw OperationError.noVPN(reason: "No active local VPN interface")
    }

    nonisolated static func connectionError(_ error: Error) -> Error {
        guard !(error is CancellationError) else { return error }
        if isLocalVPNMissing {
            debugLog("[VPNAppManager] VPN disconnected during device operation: \(error)")
            return OperationError.noVPN(reason: String(describing: error))
        }
        let reason = String(describing: error)
        guard reason.localizedCaseInsensitiveContains("RwAfc") else { return error }
        debugLog("[VPNAppManager] Device file transfer failed: \(error)")
        return OperationError.deviceConnectionFailed(reason: reason)
    }

    private static func automaticallyOpenIfNeeded() async throws -> Bool {
        guard VPNOperationContext.isInteractive, VPNAppPreferences.automaticallyOpens() else { return false }
        if let handoff = connectionHandoff {
            _ = VPNOperationContext.claimHandoff()
            return try await waitForHandoff(handoff)
        }
        guard isForeground, !isOpening, VPNOperationContext.claimHandoff() else { return false }
        debugLog("[VPNAppManager] Opening VPN app once for this manual operation.")
        guard VPNAppPreferences.destination() == .localDevVPN else {
            _ = await openSelectedApp()
            return false
        }
        let handoff = ConnectionHandoff()
        connectionHandoff = handoff
        handoff.task = Task { @MainActor in
            guard await openSelectedApp() else {
                handoff.result = false
                return
            }
            handoff.result = await waitForVPNConnection()
        }
        return try await waitForHandoff(handoff)
    }

    private static func waitForHandoff(_ handoff: ConnectionHandoff) async throws -> Bool {
        handoff.waiters += 1
        defer {
            handoff.waiters -= 1
            if handoff.waiters == 0 {
                handoff.task?.cancel()
                handoff.task = nil
                if connectionHandoff === handoff { connectionHandoff = nil }
            }
        }
        while true {
            try Task.checkCancellation()
            if let result = handoff.result { return result }
            try await Task.sleep(nanoseconds: connectionPollNanoseconds)
        }
    }

    private static func waitForVPNConnection() async -> Bool {
        let started = ProcessInfo.processInfo.systemUptime
        var previousCheck = started
        var wasForeground = isForeground
        var foregroundElapsed: TimeInterval = 0
        let pollInterval = TimeInterval(connectionPollNanoseconds) / 1_000_000_000
        while !Task.isCancelled {
            do { try await Task.sleep(nanoseconds: connectionPollNanoseconds) }
            catch { return false }
            let now = ProcessInfo.processInfo.systemUptime
            let foreground = isForeground
            if now - started >= totalConnectionTimeout { break }
            if foreground && wasForeground {
                // A suspended app must not spend its foreground grace period away.
                foregroundElapsed += min(now - previousCheck, pollInterval * 2)
            }
            previousCheck = now
            wasForeground = foreground
            if foreground && !isLocalVPNMissing { return true }
            if foregroundElapsed >= foregroundConnectionTimeout { break }
        }
        debugLog("[VPNAppManager] LocalDevVPN did not return with an active VPN before the wait ended.")
        return false
    }

    @discardableResult
    static func openSelectedApp() async -> Bool {
        guard !Task.isCancelled, isForeground, !isOpening,
              let url = VPNAppPreferences.launchURL(callbackScheme: CellularRefreshManager.callbackScheme)
        else { return false }
        isOpening = true
        defer { isOpening = false }
        // A successful open only confirms the launch request, never a VPN connection.
        // This handoff needs proper testing on-device in both standalone and embedded SideStore.
        let opened = await UIApplication.shared.open(url)
        debugLog("[VPNAppManager] VPN app launch accepted: \(opened)")
        return opened
    }
}
