import Foundation

public struct Team: Sendable {}
public struct KeyStore: Sendable {
    public func exportP12() throws -> Data { Data("test key store".utf8) }
}

public struct ProvisioningProfile: Sendable {
    public let name: String
    public let bundleIdentifier: String
    public let teamIdentifier: String
    public let entitlements: [String: any Sendable]
    public let data: Data
}

public enum SignerError: Error {
    case invalidApp(cause: String)
    case missingProvisioningProfile(bundleIdentifier: String)
    case unknown(cause: String)
}

func debugLog(_ message: String) {}
func verboseLog(_ message: String) {}

public struct AppBundle: Hashable, Sendable {
    public let fileURL: URL
    public let bundleIdentifier: String

    public init?(fileURL: URL) {
        guard let data = try? Data(contentsOf: fileURL.appendingPathComponent("Info.plist")),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String],
              let identifier = info["CFBundleIdentifier"] else { return nil }
        self.fileURL = fileURL
        self.bundleIdentifier = identifier
    }

    public var isExtension: Bool { fileURL.pathExtension == "appex" }
    public var appExtensions: Set<AppBundle> {
        let plugins = fileURL.appendingPathComponent("PlugIns")
        let urls = (try? FileManager.default.contentsOfDirectory(at: plugins, includingPropertiesForKeys: nil)) ?? []
        return Set(urls.filter { $0.pathExtension == "appex" }.compactMap { AppBundle(fileURL: $0) })
    }
    public var allAppBundles: [AppBundle] { [self] + Array(appExtensions) }
    public var entitlements: [String: any Sendable] {
        let url = fileURL.appendingPathComponent("Signature.plist")
        guard let data = try? Data(contentsOf: url),
              let value = try? PropertyListSerialization.propertyList(from: data, format: nil) else { return [:] }
        return value as? [String: any Sendable] ?? [:]
    }
}

public enum CodeSigner {
    nonisolated(unsafe) static var dropMemory = false
    nonisolated(unsafe) static var calls = 0

    public static func sign(
        appPath: String,
        keyData: Data,
        entitlementProvider: (String) -> String,
        progress: () -> Void
    ) throws {
        calls += 1
        let app = AppBundle(fileURL: URL(fileURLWithPath: appPath))!
        let framework = app.fileURL.appendingPathComponent("Frameworks/Test.framework/Test").path
        precondition(entitlementProvider(framework).isEmpty, "Entitlements leaked into a framework")
        for bundle in app.allAppBundles {
            let path = bundle.isExtension ? bundle.fileURL.appendingPathComponent("Helper").path : ""
            let xml = entitlementProvider(path)
            var values = try PropertyListSerialization.propertyList(
                from: Data(xml.utf8), format: nil
            ) as! [String: any Sendable]
            values = dropMemory ? withoutMemory(values) : values
            try writePlist(values, to: bundle.fileURL.appendingPathComponent("Signature.plist"))
            progress()
        }
    }

    private static func withoutMemory(_ values: [String: any Sendable]) -> [String: any Sendable] {
        values.filter { !MemoryEntitlements.keys.contains($0.key) }
    }
}

func writePlist(_ value: Any, to url: URL) throws {
    let data = try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0)
    try data.write(to: url)
}

typealias ALTApplication = AppBundle
struct ALTEntitlement: Hashable {
    let rawValue: String
}
final class InstalledExtension {
    let bundleIdentifier: String
    let resignedBundleIdentifier: String
    var customEntitlements: [String: any Sendable]?
    init(_ identifier: String, entitlements: [String: any Sendable]?) {
        bundleIdentifier = identifier
        resignedBundleIdentifier = identifier
        customEntitlements = entitlements
    }
}
final class InstalledApp {
    var directoryURL: URL
    var customEntitlements: [String: any Sendable]?
    var appExtensions: [InstalledExtension] = []
    init(directoryURL: URL) { self.directoryURL = directoryURL }
}
final class TestContext {
    var customEntitlementsByBundleID: [String: [String: any Sendable]] = [:]
    var additionalEntitlements: [ALTEntitlement: any Sendable] = [:]
    var installedApp: InstalledApp?
}
