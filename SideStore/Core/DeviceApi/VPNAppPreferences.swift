// zh-patch: User-selected launch target for the local VPN prerequisite.
import Foundation

enum VPNOperationContext {
    // Background refresh/Shortcuts are noninteractive even if the host is visible.
    @TaskLocal private static var handoffAttempt: VPNHandoffAttempt?

    static var isInteractive: Bool { handoffAttempt != nil }

    static func withOperation<T>(isInteractive: Bool, operation: () async throws -> T) async rethrows -> T {
        // Each manual invocation gets a fresh attempt, shared by its child tasks.
        // Returning from the VPN app must not delay the user's next invocation.
        try await $handoffAttempt.withValue(isInteractive ? VPNHandoffAttempt() : nil, operation: operation)
    }

    static func claimHandoff() -> Bool { handoffAttempt?.claim() ?? false }
}

private final class VPNHandoffAttempt: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !claimed else { return false }
        claimed = true
        return true
    }
}

enum VPNAppDestination: String, CaseIterable {
    case localDevVPN
    case shortcut
    case customURL
}

enum VPNAppPreferences {
    static let autoOpenKey = "zh.vpn.autoOpen"
    static let destinationKey = "zh.vpn.destination"
    static let shortcutNameKey = "zh.vpn.shortcutName"
    static let customURLKey = "zh.vpn.customURL"
    static let localDevVPNURL = URL(string: "localdevvpn://")!
    static let defaultShortcutName = "打开 VPN"

    static func automaticallyOpens(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: autoOpenKey) as? Bool ?? true
    }

    static func destination(in defaults: UserDefaults = .standard) -> VPNAppDestination {
        VPNAppDestination(rawValue: defaults.string(forKey: destinationKey) ?? "") ?? .localDevVPN
    }

    static func launchURL(in defaults: UserDefaults = .standard) -> URL? {
        switch destination(in: defaults) {
        case .localDevVPN:
            return localDevVPNURL
        case .shortcut:
            let name = (defaults.string(forKey: shortcutNameKey) ?? defaultShortcutName)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, name.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }
            var components = URLComponents()
            components.scheme = "shortcuts"
            components.host = "run-shortcut"
            components.queryItems = [URLQueryItem(name: "name", value: name)]
            return components.url
        case .customURL:
            return customLaunchURL(defaults.string(forKey: customURLKey) ?? "")
        }
    }

    static func customLaunchURL(_ value: String) -> URL? {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              value.contains("://"), let url = URL(string: value), let scheme = url.scheme?.lowercased(),
              !["http", "https", "file", "data", "javascript", "tel", "sms", "mailto"].contains(scheme)
        else { return nil }
        return url
    }
}

enum LocalVPNDetection {
    // iOS may keep IPv6-only utun interfaces for system services with no user VPN.
    // Only count IPv6 tunnels when the user explicitly configured an IPv6 peer.
    static func isTunnel(name: String, address: String, allowIPv6: Bool) -> Bool {
        let name = name.lowercased()
        guard name.hasPrefix("utun") || name.hasPrefix("ipsec") else { return false }
        let octets = address.split(separator: ".").compactMap { UInt8($0) }
        if octets.count == 4 {
            return octets[0] > 0 && octets[0] != 127 && octets[0] < 224
        }
        let lower = address.lowercased()
        return allowIPv6 && lower.contains(":") && !lower.hasPrefix("fe80:") && lower != "::" && lower != "::1"
    }
}
