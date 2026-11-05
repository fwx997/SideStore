"""Exercise real pairing selection, parsing and startup with synthetic credentials.

Uses the pinned minimuxer parser. Bundle locations, preferences, and device calls
are test doubles; no Apple account, pairing secret, or device is used.
"""

from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
SWIFTC = shutil.which("swiftc")

HARNESS = r'''
import Foundation

enum MinimuxerConstants {
    static let remotePairingPort: UInt16 = 49152
    static let lockdowndPort: UInt16 = 62078
}
struct UTType {
    init?(filenameExtension: String) {}
    private init() {}
    static let propertyList = UTType()
    static let xml = UTType()
}
final class UserDefaults {
    static let standard = UserDefaults()
    var preferredPairingProtocol: PairingProtocol?
    var activePairingProtocol: PairingProtocol?
    var isPairingReset = false
    var enableEMPforWireguard = false
}
final class ConnectionConfig {
    static let shared = ConnectionConfig()
    var useLocalVPN = true
}
struct Bundle {
    let bundleURL: URL
    static var main = Bundle(bundleURL: URL(fileURLWithPath: "/unused-framework"))
    enum Info {
        static var activeBundle = Bundle(bundleURL: URL(fileURLWithPath: "/unused-host"))
    }
    func url(forResource name: String, withExtension ext: String) -> URL? {
        let url = bundleURL.appendingPathComponent(name + "." + ext)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
    func object(forInfoDictionaryKey key: String) -> Any? {
        guard let data = try? Data(contentsOf: bundleURL.appendingPathComponent("Info.plist")),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        return plist[key]
    }
}
extension FileManager {
    var documentsDirectory: URL { Fixture.documents }
}
#if os(Linux) || os(Windows)
extension URL {
    func startAccessingSecurityScopedResource() -> Bool { false }
    func stopAccessingSecurityScopedResource() {}
}
#endif
final class NetworkFixture {
    var isIKEv2IPSecAvailable = false
    func refreshEndpoint() async { Fixture.events.append("endpoint") }
}
final class MinimuxerFixture { let network = NetworkFixture() }
let minimuxer = MinimuxerFixture()
func minimuxerPairingProtocol() -> PairingProtocol { Fixture.started?.mode ?? .unknown }
func debugLog(_ message: String) {}
func expect(_ condition: Bool) { precondition(condition) }
enum Failure: Error { case start }
enum MinimuxerError: Error {
    case noDevice(String), noConnection(String), notReachable(String), noVPN(String)
    case invalidVPN(String), notStarted(String), pairingNotLoaded(String)
    case connectionModeNotConfigured(String)
    case invalidPairing(protocol: PairingProtocol, reason: String)
    var description: String { "Synthetic minimuxer error" }
}
func startEMProxy() async throws { Fixture.events.append("emproxy") }
func minimuxerStart(_ content: String, preferred: PairingProtocol?) async throws {
    Fixture.events.append("start")
    if Fixture.failStart { throw Failure.start }
    // The real gateway enforces this exact content/preferred pairing match.
    Fixture.started = try PairingFileParser.parse(content: content, preferred: preferred)
}
func fetchUDID(forceLive: Bool) async throws -> String {
    precondition(forceLive)
    Fixture.events.append("device-check")
    if Fixture.failDevice { throw MinimuxerError.invalidPairing(protocol: .rppairing, reason: "test") }
    return "SYNTHETIC-DEVICE"
}
final class AppBootManager {
    static let shared = AppBootManager()
    var needsPairingPrompt = false
// STARTUP_METHOD
}

enum Fixture {
    static let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    static var documents = root
    static var started: (any PairingFile)?
    static var failStart = false
    static var failDevice = false
    static var events: [String] = []
    static var number = 0
    static let manager = PairingFileManager.shared
    static let remote: [String: Any] = [
        "identifier": "SYNTHETIC-REMOTE",
        "private_key": Data(repeating: 1, count: 32),
        "public_key": Data(repeating: 2, count: 32)
    ]
    static let lockdown: [String: Any] = [
        "WiFiMACAddress": "00:00:00:00:00:00", "SystemBUID": "SYNTHETIC-BUID",
        "RootPrivateKey": Data([1]), "HostPrivateKey": Data([2]), "HostID": "SYNTHETIC-HOST",
        "RootCertificate": Data([3]), "UDID": "SYNTHETIC-DEVICE", "EscrowBag": Data([4]),
        "HostCertificate": Data([5]), "DeviceCertificate": Data([6])
    ]
    static var mixed: [String: Any] { remote.merging(lockdown, uniquingKeysWith: { a, _ in a }) }
    static func content(_ plist: [String: Any]) throws -> String {
        String(data: try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0), encoding: .utf8)!
    }
    static func reset(_ name: String) throws {
        number += 1
        let base = root.appendingPathComponent(String(number))
        documents = base.appendingPathComponent("Documents")
        Bundle.Info.activeBundle = Bundle(bundleURL: base.appendingPathComponent("LiveContainer.app"))
        Bundle.main = Bundle(bundleURL: Bundle.Info.activeBundle.bundleURL.appendingPathComponent("Frameworks/SideStoreApp.framework"))
        for url in [documents, Bundle.main.bundleURL] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        let prefs = UserDefaults.standard
        prefs.preferredPairingProtocol = nil
        prefs.activePairingProtocol = nil
        prefs.isPairingReset = false
        prefs.enableEMPforWireguard = false
        ConnectionConfig.shared.useLocalVPN = true
        minimuxer.network.isIKEv2IPSecAvailable = false
        started = nil
        failStart = false
        failDevice = false
        events = []
        AppBootManager.shared.needsPairingPrompt = false
        print("case: " + name)
    }
    static func write(_ plist: [String: Any], mode: PairingProtocol) throws {
        try content(plist).write(to: manager.pairingFileURL(for: mode), atomically: true, encoding: .utf8)
    }
    static func embed(_ plist: [String: Any], in bundle: Bundle, info: Bool = false) throws {
        let text = try content(plist)
        let name = AppConstants.Pairing.bundleResourceName
        if info {
            let data = try PropertyListSerialization.data(fromPropertyList: [name: text], format: .xml, options: 0)
            try data.write(to: bundle.bundleURL.appendingPathComponent("Info.plist"))
        } else {
            try text.write(to: bundle.bundleURL.appendingPathComponent(name + ".mobiledevicepairing"), atomically: true, encoding: .utf8)
        }
    }
    static func selected() throws -> any PairingFile {
        guard let content = manager.fetchPairingFile() else { preconditionFailure("No pairing selected") }
        return try manager.pairingFileForStartup(content)
    }
    static func expectRemote(_ selected: any PairingFile) {
        precondition(selected.mode == .rppairing)
        precondition((selected as? RPPairingFile)?.identifier == "SYNTHETIC-REMOTE")
    }
}

@main
struct PairingRegression {
    static func main() async throws {
        defer { try? FileManager.default.removeItem(at: Fixture.root) }
        try importedFiles()
        try embeddedFiles()
        try preservedModes()
        try await startup()
        errorMapping()
        print("Pairing selection and startup regression passed")
    }
    static func importedFiles() throws {
        let manager = Fixture.manager
        try Fixture.reset("stale Lockdown preference with imported Remote Pairing")
        try Fixture.write(Fixture.lockdown, mode: .lockdown)
        try Fixture.write(Fixture.remote, mode: .rppairing)
        manager.preferredProtocol = .lockdown
        manager.persistedActiveProtocol = .lockdown
        let original = try String(contentsOf: manager.pairingFileURL(for: .lockdown))
        Fixture.expectRemote(try Fixture.selected())
        expect(try String(contentsOf: manager.pairingFileURL(for: .lockdown)) == original)
        precondition(manager.preferredProtocol == .lockdown)

        try Fixture.reset("imported Remote Pairing without preference keys")
        try Fixture.write(Fixture.remote, mode: .rppairing)
        precondition(manager.hasPairingFile())
        Fixture.expectRemote(try Fixture.selected())

        try Fixture.reset("imported Lockdown without preference keys")
        try Fixture.write(Fixture.lockdown, mode: .lockdown)
        precondition(manager.hasPairingFile())
        expect(try Fixture.selected().mode == .lockdown)

        try Fixture.reset("dual-format imported pairing selects Remote Pairing")
        try Fixture.write(Fixture.mixed, mode: .rppairing)
        manager.preferredProtocol = .lockdown
        Fixture.expectRemote(try Fixture.selected())

        try Fixture.reset("legacy dual-format file is adopted without losing data")
        let legacy = Fixture.documents.appendingPathComponent(AppConstants.Pairing.legacyPairingFileName)
        let combined = try Fixture.content(Fixture.mixed)
        try combined.write(to: legacy, atomically: true, encoding: .utf8)
        manager.adoptLegacyPairingFileIfNeeded()
        precondition(!FileManager.default.fileExists(atPath: legacy.path))
        expect(try String(contentsOf: manager.pairingFileURL(for: .rppairing)) == combined)
        Fixture.expectRemote(try Fixture.selected())
    }
    static func embeddedFiles() throws {
        try Fixture.reset("host bundle pairing is found outside the SideStore framework")
        try Fixture.embed(Fixture.remote, in: Bundle.Info.activeBundle)
        try Fixture.write(Fixture.lockdown, mode: .lockdown)
        Fixture.manager.preferredProtocol = .lockdown
        Fixture.expectRemote(try Fixture.selected())

        try Fixture.reset("host Info.plist supports dual-format embedded credentials")
        try Fixture.embed(Fixture.mixed, in: Bundle.Info.activeBundle, info: true)
        Fixture.manager.preferredProtocol = .lockdown
        Fixture.expectRemote(try Fixture.selected())

        try Fixture.reset("existing framework embedded pairing still works")
        try Fixture.embed(Fixture.remote, in: Bundle.main)
        Fixture.expectRemote(try Fixture.selected())

        try Fixture.reset("invalid imported remote file falls back to valid host pairing")
        try "invalid plist".write(to: Fixture.manager.pairingFileURL(for: .rppairing), atomically: true, encoding: .utf8)
        try Fixture.embed(Fixture.remote, in: Bundle.Info.activeBundle)
        Fixture.expectRemote(try Fixture.selected())

        try Fixture.reset("pairing reset ignores imported files but permits fresh host credentials")
        try Fixture.write(Fixture.remote, mode: .rppairing)
        UserDefaults.standard.isPairingReset = true
        precondition(Fixture.manager.fetchPairingFile() == nil)
        try Fixture.embed(Fixture.remote, in: Bundle.Info.activeBundle)
        Fixture.expectRemote(try Fixture.selected())

        try Fixture.reset("invalid or missing remote credentials cannot claim readiness")
        try Fixture.embed(Fixture.lockdown, in: Bundle.Info.activeBundle)
        precondition(PairingFileManager.embeddedRPPairingFile() == nil)
        precondition(!Fixture.manager.hasPairingFile())
        precondition(Fixture.manager.fetchPairingFile(for: .unknown) == nil)
    }
    static func preservedModes() throws {
        try Fixture.reset("remote server preserves explicit Lockdown pairing")
        ConnectionConfig.shared.useLocalVPN = false
        try Fixture.write(Fixture.lockdown, mode: .lockdown)
        try Fixture.write(Fixture.remote, mode: .rppairing)
        try Fixture.embed(Fixture.remote, in: Bundle.Info.activeBundle)
        Fixture.manager.preferredProtocol = .lockdown
        expect(try Fixture.selected().mode == .lockdown)

        try Fixture.reset("IPSec local VPN preserves explicit Lockdown pairing")
        minimuxer.network.isIKEv2IPSecAvailable = true
        try Fixture.write(Fixture.lockdown, mode: .lockdown)
        try Fixture.write(Fixture.remote, mode: .rppairing)
        try Fixture.embed(Fixture.remote, in: Bundle.Info.activeBundle)
        Fixture.manager.preferredProtocol = .lockdown
        expect(try Fixture.selected().mode == .lockdown)

        try Fixture.reset("single-format content wins over incompatible saved preference")
        ConnectionConfig.shared.useLocalVPN = false
        Fixture.manager.preferredProtocol = .rppairing
        let parsed = try Fixture.manager.pairingFileForStartup(Fixture.content(Fixture.lockdown))
        precondition(parsed.mode == .lockdown)
    }
    static func startup() async throws {
        try Fixture.reset("startup passes selected content and matching protocol to the gateway")
        Fixture.manager.preferredProtocol = .lockdown
        Fixture.manager.persistedActiveProtocol = .lockdown
        try Fixture.write(Fixture.remote, mode: .rppairing)
        try await AppBootManager.shared.startMinimuxer(pairingFile: Fixture.content(Fixture.lockdown))
        Fixture.expectRemote(Fixture.started!)
        precondition(Fixture.manager.persistedActiveProtocol == .rppairing)
        precondition(Fixture.events == ["start", "endpoint", "device-check"])

        try Fixture.reset("failed startup leaves persisted protocol unchanged")
        Fixture.manager.persistedActiveProtocol = .lockdown
        Fixture.failStart = true
        do {
            try await AppBootManager.shared.startMinimuxer(pairingFile: Fixture.content(Fixture.remote))
            preconditionFailure("Expected startup failure")
        } catch Failure.start {}
        precondition(Fixture.manager.persistedActiveProtocol == .lockdown)
        precondition(Fixture.events == ["start"])

        try Fixture.reset("real pairing validation errors still fail startup")
        Fixture.failDevice = true
        do {
            try await AppBootManager.shared.startMinimuxer(pairingFile: Fixture.content(Fixture.remote))
            preconditionFailure("Expected device verification failure")
        } catch MinimuxerError.invalidPairing {}
        precondition(AppBootManager.shared.needsPairingPrompt)
    }
    static func errorMapping() {
        let mismatch = MinimuxerError.invalidVPN("utun is present but no ipsec/IKEv2 interface found — LocalDevVPN may not support the lockdown protocol on iOS 26.4+")
        precondition(mismatch.asOperationError == .remotePairingRequired)
        precondition(MinimuxerError.invalidVPN("TCP port poll failed").asOperationError == .invalidVPN(reason: "TCP port poll failed"))
        precondition(MinimuxerError.noVPN("VPN disconnected").asOperationError == .noVPN(reason: "VPN disconnected"))
    }
}
'''


def declaration(source, signature):
    start = source.index(signature)
    cursor = source.index("{", start)
    depth = 1
    end = cursor + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end]


def production_harness(common=None):
    common = common or ROOT / "Dependencies/minimuxer/Common"
    parser = "\n".join((common / name).read_text(encoding="utf-8") for name in (
        "PairingProtocol.swift", "ConcurrencyUtils.swift", "PairingFile.swift"))
    constants = (ROOT / "SideStore/AppConstants.swift").read_text(encoding="utf-8")
    pairing_constants = declaration(constants, "public enum Pairing {")
    pairing_constants = pairing_constants.replace(
        "public static let documentationURL          = AppConstants.URLs.pairingDocumentation", "")
    manager = (ROOT / "SideStore/Core/Pairing/PairingFileManager.swift").read_text(encoding="utf-8")
    manager = manager.replace("import UniformTypeIdentifiers", "").replace("import MinimuxerCommon", "")
    boot = (ROOT / "SideStore/AppBootManager.swift").read_text(encoding="utf-8")
    start = declaration(boot, "public nonisolated func startMinimuxer(pairingFile: String)")
    wrapper = (ROOT / "SideStore/Core/DeviceApi/MinimuxerWrapper.swift").read_text(encoding="utf-8")
    error_mapping = declaration(wrapper, "extension MinimuxerError {")
    errors = (ROOT / "SideStore/Core/Operations/Errors/OperationError.swift").read_text(encoding="utf-8")
    return "\n".join((parser, "enum AppConstants {" + pairing_constants + "}", manager,
                      errors, error_mapping, HARNESS.replace("// STARTUP_METHOD", start)))


@unittest.skipUnless(SWIFTC, "swiftc is required to execute production pairing selection")
class PairingSelectionTests(unittest.TestCase):
    def test_pairing_sources_and_startup_protocol(self):
        with tempfile.TemporaryDirectory(prefix="ss-pairing-") as directory:
            source = Path(directory) / "PairingRegression.swift"
            binary = Path(directory) / "PairingRegression"
            source.write_text(production_harness(), encoding="utf-8")
            command = [SWIFTC, "-swift-version", "5", "-parse-as-library", str(source), "-o", str(binary)]
            result = subprocess.run(command, capture_output=True, text=True, timeout=120)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
