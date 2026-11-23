import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

func expect(_ value: @autoclosure () -> Bool, _ message: String) {
    precondition(value(), message)
}

func rejects(_ operation: () throws -> Void) {
    do { try operation(); fatalError("Expected rejection") } catch {}
}

func plist(_ values: [String: Any], at url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0).write(to: url)
}

func bundle(_ name: String, id: String, in directory: URL) throws -> URL {
    let url = directory.appendingPathComponent(name)
    try plist(["CFBundleIdentifier": id, "CFBundleExecutable": "Executable", "CFBundleVersion": "42", "CFBundleShortVersionString": "3.9"], at: url.appendingPathComponent("Info.plist"))
    try Data([0xCA, 0xFE]).write(to: url.appendingPathComponent("Executable"))
    return url
}

func combinedBundle(in directory: URL) throws -> URL {
    let host = try bundle("LiveContainer.app", id: "com.kdt.livecontainer.TEAM123456", in: directory)
    var info = try CombinedAppDistribution.info(at: host)
    info[CombinedAppDistribution.embeddedAppsKey] = CombinedAppDistribution.companions
    try plist(info, at: host.appendingPathComponent("Info.plist"))
    let frameworks = host.appendingPathComponent("Frameworks")
    _ = try bundle("SideStoreApp.framework", id: "com.SideStore.SideStore", in: frameworks)
    _ = try bundle("SideInstallerApp.framework", id: "com.frizzlem.sideinstaller", in: frameworks)
    let plugins = host.appendingPathComponent("PlugIns")
    _ = try bundle("LiveProcess.appex", id: "com.kdt.livecontainer.TEAM123456.LiveProcess", in: plugins)
    _ = try bundle("SideInstallerLiveActivity.appex", id: "com.kdt.livecontainer.TEAM123456.SideInstallerLiveActivity", in: plugins)
    return host
}

struct AppVersion { let version: String; let buildVersion: String? }
struct ALTApplication { let version: String; let buildVersion: String }
enum VerificationError: Error {
    case mismatch
    static func mismatchedVersion(version: String, expectedVersion: String, app: ALTApplication) -> Self { .mismatch }
    static func mismatchedBuildVersion(_ version: String, expectedVersion: String, app: ALTApplication) -> Self { .mismatch }
}
struct VersionHarness {}

struct ALTCertificate {
    let serialNumber: String
    let privateKey = Data([1])
    let machineIdentifier: String? = nil
    init(p12Data: Data, password: String?) throws {
        let value = try JSONSerialization.jsonObject(with: p12Data) as! [String: String]
        guard value["password"] == (password ?? "") else { throw VerificationError.mismatch }
        serialNumber = value["serial"]!
    }
}
struct ActiveCertificate { let certificate: ALTCertificate; let password: String? }
final class Keychain: @unchecked Sendable {
    static let shared = Keychain()
    var signingCertificatePassword: String? = nil
}
extension Bundle { var certificateURL: URL { bundleURL.appendingPathComponent("ALTCertificate.p12") } }
struct CertificateHarness {
    let bundle: Bundle
    var activeCertificate: ActiveCertificate? = nil
    func getLocalCertificate(serialNumber: String) -> ALTCertificate? { nil }
    func debugLog(_ value: String) {}
    func verboseLog(_ value: String) {}
}

@main struct Main {
    static func main() throws {
        let scenario = CommandLine.arguments[1]
        if scenario == "lock-child" {
            let lock = CompanionSigningLock(directory: URL(fileURLWithPath: CommandLine.arguments[2]))
            do {
                let lease = try lock.acquire()
                FileHandle.standardOutput.write(Data("acquired\n".utf8))
                if CommandLine.arguments.count > 3 { _ = readLine() }
                lease.release()
            } catch { print("busy") }
            return
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = try combinedBundle(in: directory)
        let defaults = UserDefaults(suiteName: "combined-test-" + UUID().uuidString)!
        switch scenario {
        case "routing": routing()
        case "package": try package(host)
        case "missing-sideinstaller":
            try FileManager.default.removeItem(at: host.appendingPathComponent("Frameworks/SideInstallerApp.framework"))
            rejects { try CombinedAppDistribution.validatePackage(at: host) }
        case "extensions": try extensions(host)
        case "url": url()
        case "version": version()
        case "build-update": buildUpdate()
        case "metadata": metadata()
        case "background-identifiers": backgroundIdentifiers()
        case "receipt": try receipt(host, defaults)
        case "password": password(defaults)
        case "certificate": try certificate(host)
        case "lock": try locks(directory)
        default: fatalError("Unknown scenario")
        }
    }

    static func routing() {
        let base = "com.kdt.livecontainer"
        let running = base + ".TEAM123456"
        expect(CombinedAppDistribution.isSelfIdentifier(base, base: base, running: running), "base identity")
        expect(CombinedAppDistribution.isSelfIdentifier(running, base: base, running: running), "signed identity")
        for other in [base + "2", base + ".OTHERTEAM1", running + ".extension", "prefix." + base] {
            expect(!CombinedAppDistribution.isSelfIdentifier(other, base: base, running: running), "unrelated identity")
        }
        expect(CombinedAppDistribution.usesRunningBundle(isSelf: true, isStoreUpdate: false, hasInstalledInput: true), "self resign uses installed host")
        expect(!CombinedAppDistribution.usesRunningBundle(isSelf: true, isStoreUpdate: true, hasInstalledInput: true), "update downloads new host")
        expect(!CombinedAppDistribution.usesRunningBundle(isSelf: true, isStoreUpdate: false, hasInstalledInput: false), "explicit IPA import uses imported package")
    }

    static func package(_ host: URL) throws {
        try CombinedAppDistribution.validatePackage(at: host)
        let resolved = CombinedAppDistribution.hostURL(for: host.appendingPathComponent("Frameworks/SideStoreApp.framework"))
        expect(resolved.standardizedFileURL.path == host.standardizedFileURL.path, "framework resolves outer host")
        let executable = host.appendingPathComponent("Frameworks/SideInstallerApp.framework/Executable")
        try Data().write(to: executable)
        rejects { try CombinedAppDistribution.validatePackage(at: host) }
    }

    static func extensions(_ host: URL) throws {
        let target = host.appendingPathComponent("PlugIns/SideInstallerLiveActivity.appex/Info.plist")
        var values = try CombinedAppDistribution.info(at: target.deletingLastPathComponent())
        values["CFBundleVersion"] = "1"
        try plist(values, at: target)
        rejects { try CombinedAppDistribution.validatePackage(at: host) }
        values["CFBundleVersion"] = "42"
        values["CFBundleIdentifier"] = "com.frizzlem.sideinstaller.LiveActivity"
        try plist(values, at: target)
        rejects { try CombinedAppDistribution.validatePackage(at: host) }
    }

    static func url() {
        let key = CombinedAppDistribution.updateURLKey
        expect((try? CombinedAppDistribution.updateURL(in: [key: "https://example.invalid/combined.ipa"])) != nil, "HTTPS")
        for value in ["http://example.invalid/app.ipa", "file:///tmp/app.ipa", "https://user:pass@example.invalid/app.ipa", ""] {
            rejects { _ = try CombinedAppDistribution.updateURL(in: [key: value]) }
        }
    }

    static func version() {
        let verifier = VersionHarness()
        let app = ALTApplication(version: "3.9", buildVersion: "42")
        try! verifier.verifyCombinedVersion(app, expected: AppVersion(version: "3.9", buildVersion: "42"))
        rejects { try verifier.verifyCombinedVersion(app, expected: AppVersion(version: "3.10", buildVersion: "42")) }
        rejects { try verifier.verifyCombinedVersion(app, expected: AppVersion(version: "3.9", buildVersion: "43")) }
    }

    static func buildUpdate() {
        expect(CombinedAppDistribution.isNewerBuild("20261123.10", than: "20261123.9"), "numeric component ordering")
        expect(CombinedAppDistribution.isNewerBuild("20261124.1", than: "20261123.999"), "later date")
        expect(CombinedAppDistribution.isNewerBuild("1.0.1", than: "1"), "missing components are zero")
        expect(CombinedAppDistribution.isNewerBuild("9999999999999999999999.2", than: "9999999999999999999999.1"), "no integer overflow")
        for previous in ["20261123.10", "20261124.1", "20261123.010.0"] {
            expect(!CombinedAppDistribution.isNewerBuild("20261123.10", than: previous), "same or older build is never an update")
        }
        expect(!CombinedAppDistribution.isNewerBuild("1", than: "1.0.0"), "zero padding is equal")
        for invalid in [nil, "", "1..2", ".1", "1.", "1.beta", "1.-2", "1.２"] as [String?] {
            expect(!CombinedAppDistribution.isNewerBuild(invalid, than: "1"), "invalid candidate is rejected")
            expect(!CombinedAppDistribution.isNewerBuild("2", than: invalid), "unknown current build cannot justify an update")
        }
    }

    static func metadata() {
        let source: [String: Any] = ["LCEmbeddedApps": ["SideStore", "SideInstaller"], "CFBundleVersion": "42", "LCCombinedUpdateURL": "https://example.invalid/new.ipa"]
        let old: [String: Any] = ["LCEmbeddedApps": ["SideStore"], "CFBundleVersion": "1", "CFBundleDisplayName": "My App", "LCCombinedUpdateURL": "https://example.invalid/old.ipa"]
        let merged = CombinedAppDistribution.preservingDistributionInfo(old, original: source)
        expect(merged["CFBundleVersion"] as? String == "42", "old cached build must not override")
        expect(merged["CFBundleDisplayName"] as? String == "My App", "user name survives")
        expect(merged["LCEmbeddedApps"] as? [String] == ["SideStore", "SideInstaller"], "companions survive")
    }

    static func backgroundIdentifiers() {
        let base = "com.kdt.livecontainer"
        let signed = base + ".TEAM123456"
        let ids = [base + ".install.*", signed + ".install.*", "other.refresh"]
        let once = CombinedAppDistribution.rebasedTaskIdentifiers(ids, from: signed, base: base, to: signed)
        expect(once == [signed + ".install.*", "other.refresh"], "no duplicate team suffix")
        expect(CombinedAppDistribution.rebasedTaskIdentifiers(once, from: signed, base: base, to: signed) == once, "idempotent")
        let new = base + ".NEWTEAM123"
        expect(CombinedAppDistribution.rebasedTaskIdentifiers(once, from: signed, base: base, to: new).first == new + ".install.*", "team migration")
    }

    static func receipt(_ host: URL, _ defaults: UserDefaults) throws {
        defaults.set(true, forKey: CombinedAppBootstrap.pendingKey)
        let receipt = CombinedAppBootstrap.prepareReceipt(defaults: defaults)!
        expect(!CombinedAppBootstrap.completeIfInstalled(at: host, defaults: defaults), "not installed yet")
        var info = try CombinedAppDistribution.info(at: host)
        info[CombinedAppDistribution.receiptKey] = "previous-install"
        try plist(info, at: host.appendingPathComponent("Info.plist"))
        expect(!CombinedAppBootstrap.completeIfInstalled(at: host, defaults: defaults), "stale receipt")
        expect(defaults.bool(forKey: CombinedAppBootstrap.pendingKey), "failure preserves pending")
        info[CombinedAppDistribution.receiptKey] = receipt
        try plist(info, at: host.appendingPathComponent("Info.plist"))
        expect(CombinedAppBootstrap.completeIfInstalled(at: host, defaults: defaults), "installed receipt accepted")
        expect(!defaults.bool(forKey: CombinedAppBootstrap.pendingKey), "no repeated prompt")
    }

    static func password(_ defaults: UserDefaults) {
        defaults.set("SERIAL-A", forKey: CombinedAppBootstrap.certificateSerialKey)
        defaults.set("", forKey: CombinedAppBootstrap.certificatePasswordKey)
        expect(CombinedAppBootstrap.certificatePassword(for: "serial-a", defaults: defaults) == "", "empty handoff password supported")
        expect(CombinedAppBootstrap.certificatePassword(for: "SERIAL-B", defaults: defaults) == nil, "bound to identity")
        CombinedAppBootstrap.certificateWasImported(serial: "SERIAL-B", defaults: defaults)
        expect(defaults.object(forKey: CombinedAppBootstrap.certificatePasswordKey) != nil, "failed import preserves handoff")
        CombinedAppBootstrap.certificateWasImported(serial: "SERIAL-A", defaults: defaults)
        expect(defaults.object(forKey: CombinedAppBootstrap.certificatePasswordKey) == nil, "success erases password")
    }

    static func certificate(_ host: URL) throws {
        let defaults = UserDefaults.standard
        defaults.set("SERIAL-A", forKey: CombinedAppBootstrap.certificateSerialKey)
        defaults.set("bootstrap-machine", forKey: CombinedAppBootstrap.certificatePasswordKey)
        defer {
            defaults.removeObject(forKey: CombinedAppBootstrap.certificateSerialKey)
            defaults.removeObject(forKey: CombinedAppBootstrap.certificatePasswordKey)
        }
        let data = try JSONSerialization.data(withJSONObject: ["serial": "SERIAL-A", "password": "bootstrap-machine"])
        try data.write(to: host.appendingPathComponent("ALTCertificate.p12"))
        let harness = CertificateHarness(bundle: Bundle(url: host)!)
        expect(harness.getSignableCertificate(for: "SERIAL-A", fallbackPassword: "different-anisette")?.serialNumber == "SERIAL-A", "handoff decrypts with exact machine password")
        defaults.set("SERIAL-B", forKey: CombinedAppBootstrap.certificateSerialKey)
        expect(harness.getSignableCertificate(for: "SERIAL-B", fallbackPassword: "bootstrap-machine") == nil, "decrypted wrong serial rejected")
    }

    static func child(_ directory: URL, hold: Bool = false) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        process.arguments = ["lock-child", directory.path] + (hold ? ["hold"] : [])
        process.standardOutput = Pipe()
        process.standardInput = Pipe()
        try process.run()
        return process
    }

    static func outcome(_ process: Process) -> String {
        process.waitUntilExit()
        return String(data: (process.standardOutput as! Pipe).fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)!.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func locks(_ directory: URL) throws {
        let coordinator = CompanionSigningLock(directory: directory)
        let first = try coordinator.acquire()
        let nested = try coordinator.acquire()
        var probe = try child(directory)
        expect(outcome(probe) == "busy", "other process cannot sign")
        first.release()
        first.release()
        probe = try child(directory)
        expect(outcome(probe) == "busy", "idempotent release keeps nested lease")
        nested.release()
        probe = try child(directory)
        expect(outcome(probe) == "acquired", "last release frees lock")
        let holder = try child(directory, hold: true)
        let ready = (holder.standardOutput as! Pipe).fileHandleForReading.availableData
        expect(String(data: ready, encoding: .utf8)?.contains("acquired") == true, "child acquired before checking contention")
        probe = try child(directory)
        expect(outcome(probe) == "busy", "child owns lock")
        holder.terminate()
        holder.waitUntilExit()
        probe = try child(directory)
        expect(outcome(probe) == "acquired", "process death releases descriptor")
    }
}
