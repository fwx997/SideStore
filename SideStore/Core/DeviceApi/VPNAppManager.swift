// zh-patch: Check VPN availability before device work, including cellular refresh.
import Foundation
import UIKit

@MainActor
enum VPNAppManager {
    private static var isOpening = false

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
        guard isLocalVPNMissing else { return }
        debugLog("[VPNAppManager] Local VPN is not connected; stopping device operation before transport.")
        if allowAppLaunch { await automaticallyOpenIfNeeded() }
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

    private static func automaticallyOpenIfNeeded() async {
        guard VPNOperationContext.isInteractive, VPNAppPreferences.automaticallyOpens(), isForeground, !isOpening,
              VPNOperationContext.claimHandoff() else { return }
        debugLog("[VPNAppManager] Opening VPN app once for this manual operation.")
        _ = await openSelectedApp()
    }

    @discardableResult
    static func openSelectedApp() async -> Bool {
        guard isForeground, !isOpening, let url = VPNAppPreferences.launchURL() else { return false }
        isOpening = true
        defer { isOpening = false }
        // A successful open only confirms the launch request, never a VPN connection.
        // This handoff needs proper testing on-device in both standalone and embedded SideStore.
        let opened = await UIApplication.shared.open(url)
        debugLog("[VPNAppManager] VPN app launch accepted: \(opened)")
        return opened
    }
}
