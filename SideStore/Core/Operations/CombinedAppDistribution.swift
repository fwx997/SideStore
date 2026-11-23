import Foundation

/// The installed host is authoritative for self signing and distribution policy.
/// Framework bundle IDs remain the original app IDs inside the signed LC host.
enum CombinedAppDistribution {
    static let embeddedAppsKey = "LCEmbeddedApps"
    static let updateURLKey = "LCCombinedUpdateURL"
    static let sourceURLKey = "LCCombinedSourceURL"
    static let receiptKey = "LCCombinedSelfSignReceipt"
    static let companions = ["SideStore", "SideInstaller"]
    static let protectedInfoKeys: Set<String> = [
        embeddedAppsKey, updateURLKey, sourceURLKey, receiptKey, "CFBundleVersion", "CFBundleShortVersionString",
        "BGTaskSchedulerPermittedIdentifiers", "CFBundleURLTypes", "UIBackgroundModes", "NSSupportsLiveActivities"
    ]

    static func isSelfIdentifier(_ identifier: String, base: String, running: String) -> Bool {
        !identifier.isEmpty && (identifier == base || identifier == running)
    }

    static func usesRunningBundle(isSelf: Bool, isStoreUpdate: Bool, hasInstalledInput: Bool) -> Bool {
        isSelf && !isStoreUpdate && hasInstalledInput
    }

    /// CFBundleVersion is a dot-separated numeric build, independent of the
    /// marketing version. Compare components without overflowing an integer.
    static func isNewerBuild(_ candidate: String?, than installed: String?) -> Bool {
        guard let candidate, let installed,
              let latest = buildComponents(candidate), let current = buildComponents(installed) else { return false }
        for index in 0..<max(latest.count, current.count) {
            let left = index < latest.count ? latest[index] : "0"
            let right = index < current.count ? current[index] : "0"
            if left.count != right.count { return left.count > right.count }
            if left != right { return left > right }
        }
        return false
    }

    private static func buildComponents(_ value: String) -> [String]? {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.allSatisfy({ part in
            !part.isEmpty && part.utf8.allSatisfy { (48...57).contains($0) }
        }) else { return nil }
        return parts.map { part in
            let digits = part.drop(while: { $0 == "0" })
            return digits.isEmpty ? "0" : String(digits)
        }
    }

    static func hostURL(for bundleURL: URL) -> URL {
        guard bundleURL.lastPathComponent == "SideStoreApp.framework" else { return bundleURL }
        return bundleURL.deletingLastPathComponent().deletingLastPathComponent()
    }

    static func info(at bundleURL: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: bundleURL.appendingPathComponent("Info.plist"))
        guard let info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw Failure.invalidPackage
        }
        return info
    }

    static func requiresCompanions(at bundleURL: URL) -> Bool {
        let apps = (try? info(at: bundleURL)[embeddedAppsKey]) as? [String] ?? []
        return apps.contains("SideInstaller") || FileManager.default.fileExists(
            atPath: bundleURL.appendingPathComponent("Frameworks/SideInstallerApp.framework").path
        )
    }

    static func updateURL(in info: [String: Any]) throws -> URL {
        guard let value = info[updateURLKey] as? String,
              let url = URL(string: value), url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else {
            throw Failure.missingUpdateURL
        }
        return url
    }

    static func validatePackage(at bundleURL: URL) throws {
        let host = try info(at: bundleURL)
        let apps = Set(host[embeddedAppsKey] as? [String] ?? [])
        guard Set(companions).isSubset(of: apps),
              let version = host["CFBundleShortVersionString"] as? String, !version.isEmpty,
              let build = host["CFBundleVersion"] as? String, !build.isEmpty else { throw Failure.invalidPackage }
        try validateExecutable(at: bundleURL, info: host)
        try validateFramework("SideStore", identifiers: ["com.SideStore.SideStore"], in: bundleURL)
        try validateFramework("SideInstaller", identifiers: ["com.frizzlem.sideinstaller", "com.frizzle.sideinstaller"], in: bundleURL)
        try validateExtension("LiveProcess", in: bundleURL, host: host)
        try validateExtension("SideInstallerLiveActivity", in: bundleURL, host: host)
    }

    private static func validateExtension(_ name: String, in hostURL: URL, host: [String: Any]) throws {
        let url = hostURL.appendingPathComponent("PlugIns/\(name).appex")
        let values = try info(at: url)
        guard let hostID = host["CFBundleIdentifier"] as? String,
              let identifier = values["CFBundleIdentifier"] as? String, identifier == hostID + "." + name,
              values["CFBundleVersion"] as? String == host["CFBundleVersion"] as? String,
              values["CFBundleShortVersionString"] as? String == host["CFBundleShortVersionString"] as? String else {
            throw Failure.invalidPackage
        }
        try validateExecutable(at: url, info: values)
    }

    static func preservingDistributionInfo(_ custom: [String: Any], original: [String: Any]) -> [String: Any] {
        var result = custom
        for key in protectedInfoKeys { result[key] = original[key] }
        return result
    }

    static func preservingSendableDistributionInfo(
        _ custom: [String: any Sendable], original: [String: any Sendable]
    ) -> [String: any Sendable] {
        var result = custom
        for key in protectedInfoKeys { result[key] = original[key] }
        return result
    }

    static func rebasedTaskIdentifiers(_ identifiers: [String], from original: String, base: String, to target: String) -> [String] {
        var seen = Set<String>()
        return identifiers.compactMap { identifier in
            let rewritten: String
            if identifier == target || identifier.hasPrefix(target + ".") {
                rewritten = identifier
            } else if identifier == original || identifier.hasPrefix(original + ".") {
                rewritten = target + identifier.dropFirst(original.count)
            } else if identifier == base || identifier.hasPrefix(base + ".") {
                rewritten = target + identifier.dropFirst(base.count)
            } else {
                rewritten = identifier
            }
            return seen.insert(rewritten).inserted ? rewritten : nil
        }
    }

    private static func validateFramework(_ name: String, identifiers: Set<String>, in host: URL) throws {
        let url = host.appendingPathComponent("Frameworks/\(name)App.framework")
        let dictionary = try info(at: url)
        guard let identifier = dictionary["CFBundleIdentifier"] as? String,
              identifiers.contains(identifier) else { throw Failure.invalidPackage }
        try validateExecutable(at: url, info: dictionary)
    }

    private static func validateExecutable(at url: URL, info: [String: Any]) throws {
        guard let executable = info["CFBundleExecutable"] as? String,
              !executable.isEmpty, executable == (executable as NSString).lastPathComponent,
              !executable.contains("\\"), executable != ".", executable != ".." else {
            throw Failure.invalidPackage
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.appendingPathComponent(executable).path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber, size.intValue > 0 else { throw Failure.invalidPackage }
    }

    enum Failure: LocalizedError {
        case invalidPackage
        case missingUpdateURL
        var errorDescription: String? {
            switch self {
            case .invalidPackage:
                return NSLocalizedString("This update is not a complete LiveContainer + SideStore + SideInstaller package. The installed apps were kept.", comment: "")
            case .missingUpdateURL:
                return NSLocalizedString("This combined build has no valid HTTPS update URL. Install a complete combined IPA to update it.", comment: "")
            }
        }
    }
}

enum CombinedAppBootstrap {
    static let pendingKey = "LCCombinedBootstrapPending"
    static let expectedReceiptKey = "LCCombinedBootstrapExpectedReceipt"
    static let certificatePasswordKey = "LCCombinedBootstrapCertificatePassword"
    static let certificateSerialKey = "LCCombinedBootstrapCertificateSerial"

    static func certificatePassword(for serial: String, defaults: UserDefaults = .standard) -> String? {
        guard !serial.isEmpty,
              let expected = defaults.string(forKey: certificateSerialKey),
              serial.caseInsensitiveCompare(expected) == .orderedSame else { return nil }
        return defaults.string(forKey: certificatePasswordKey)
    }

    static func certificateWasImported(serial: String, defaults: UserDefaults = .standard) {
        guard let expected = defaults.string(forKey: certificateSerialKey),
              serial.caseInsensitiveCompare(expected) == .orderedSame else { return }
        defaults.removeObject(forKey: certificatePasswordKey)
        defaults.removeObject(forKey: certificateSerialKey)
    }

    static func isPending(bundleURL: URL, defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: pendingKey)
            && CombinedAppDistribution.requiresCompanions(at: bundleURL)
    }

    static func prepareReceipt(defaults: UserDefaults = .standard) -> String? {
        guard defaults.bool(forKey: pendingKey) else { return nil }
        let receipt = UUID().uuidString
        defaults.set(receipt, forKey: expectedReceiptKey)
        return receipt
    }

    @discardableResult
    static func completeIfInstalled(at bundleURL: URL, defaults: UserDefaults = .standard) -> Bool {
        guard defaults.bool(forKey: pendingKey),
              let expected = defaults.string(forKey: expectedReceiptKey),
              let info = try? CombinedAppDistribution.info(at: bundleURL),
              info[CombinedAppDistribution.receiptKey] as? String == expected,
              (try? CombinedAppDistribution.validatePackage(at: bundleURL)) != nil else { return false }
        defaults.set(false, forKey: pendingKey)
        defaults.removeObject(forKey: expectedReceiptKey)
        return true
    }
}
