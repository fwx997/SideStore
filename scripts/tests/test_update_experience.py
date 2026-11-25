"""Exercise update persistence in SQLite and real download/source helpers."""

from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

from test_combined_distribution import method

ROOT = Path(__file__).resolve().parents[2]
OPERATIONS = ROOT / "SideStore/Core/Operations"
SWIFTC = shutil.which("swiftc")


def execute(sources, program):
    with tempfile.TemporaryDirectory() as temporary:
        folder = Path(temporary)
        main = folder / "main.swift"
        main.write_text(program, encoding="utf-8")
        binary = folder / "checks"
        compiled = subprocess.run([SWIFTC, "-swift-version", "6", *map(str, sources), str(main), "-o", str(binary)],
                                  capture_output=True, text=True, timeout=120)
        if compiled.returncode:
            raise AssertionError(compiled.stdout + compiled.stderr)
        result = subprocess.run([str(binary), str(folder)], capture_output=True, text=True, timeout=30)
        if result.returncode:
            raise AssertionError(result.stdout + result.stderr)


@unittest.skipUnless(SWIFTC, "Requires Swift for production update helpers")
class UpdateExperienceTests(unittest.TestCase):
    def test_transfer_speed_unknown_size_stall_and_old_callbacks(self):
        source = (OPERATIONS / "CombinedUpdateSourceSettings.swift").read_text(encoding="utf-8")
        normalize = method(source, "static func normalize(")
        program = "import Foundation\nenum Address {\n" + normalize + "\n}\n" + r'''
var transfer = DownloadTransferStatus(now: 0)
precondition(transfer.phase == .connecting)
transfer.record(received: 500, expected: 1000, now: 0.5)
precondition(transfer.bytesPerSecond == 1000 && transfer.received == 500)
transfer.record(received: 1000, expected: 2000, now: 1)
precondition(transfer.bytesPerSecond == 1000)
precondition(transfer.text(now: 5).contains("Waiting for data"))
precondition(transfer.text(now: 5).contains("0 B/s"))
transfer.record(received: 1500, expected: -1, now: 6)
precondition(transfer.expected == 0 && !transfer.text(now: 6).contains("%"))
let store = DownloadTransferStatusStore()
let old = store.begin(for: "app")
let latest = store.begin(for: "app")
store.record(for: "app", id: old, received: 999, expected: 1000)
store.remove(for: "app", id: old)
precondition(store.text(for: "app") == "Connecting to download server…")
store.processing(for: "app", id: latest)
precondition(store.text(for: "app") == "Download complete. Processing app…")
store.remove(for: "app", id: latest)
precondition(store.text(for: "app") == nil)
precondition(Address.normalize(" https://example.com/updates/ ")?.absoluteString == "https://example.com/updates/source.json")
precondition(Address.normalize("https://example.com/catalog.json")?.absoluteString == "https://example.com/catalog.json")
for input in ["http://example.com", "https://u:p@example.com", "https://example.com/a#x", "", "file:///tmp/x"] {
    precondition(Address.normalize(input) == nil)
}
'''
        execute([OPERATIONS / "DownloadTransferStatus.swift"], program)

    @unittest.skipUnless(sys.platform == "darwin", "SQLite/CoreData requires macOS")
    def test_sqlite_update_flags_follow_runtime_build_and_each_copy(self):
        source = (ROOT / "AltStore/Core/Model/InstalledApp.swift").read_text(encoding="utf-8")
        methods = "\n".join(method(source, declaration) for declaration in (
            "public override func willSave()", "func synchronizeUpdateAvailability()", "@objc public var hasUpdate:"))
        program = SQLITE_PREFIX + methods + SQLITE_SUFFIX
        execute([OPERATIONS / "CombinedAppDistribution.swift"], program)


SQLITE_PREFIX = r'''
import Foundation
import CoreData
extension Bundle {
    enum Info {
        static var activeBundleURL: URL { URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("Host.app") }
        static var activeBundleIdentifier: String { "com.kdt.livecontainer.TEST" }
    }
}
extension UserDefaults { var isBetaUpdatesEnabled: Bool { false } }
enum ReleaseTrackType { static let betaTracks: Set<String> = ["beta"] }
struct SemanticVersion: Comparable {
    let major: Int; let minor: Int; let patch: Int
    let build: String? = nil; let preRelease: String? = nil
    init?(_ string: String) {
        let parts = string.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        major = parts[0]; minor = parts[1]; patch = parts[2]
    }
    static func < (lhs: Self, rhs: Self) -> Bool { (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch) }
}
@objc(UpdateTestVersion) class AppVersion: NSManagedObject {
    @NSManaged var version: String
    @NSManaged var buildVersion: String?
    var channel: String { "stable" }
}
@objc(UpdateTestStore) class StoreApp: NSManagedObject {
    static let altstoreAppID = "com.kdt.livecontainer"
    @NSManaged var latestSupportedVersion: AppVersion?
    var isPledgeRequired: Bool { false }
    var isPledged: Bool { true }
}
@objc(UpdateTestInstalled) class InstalledApp: NSManagedObject {
    @NSManaged var version: String
    @NSManaged var buildVersion: String
    @NSManaged var storeBuildVersion: String?
    @NSManaged var bundleIdentifier: String
    @NSManaged var resignedBundleIdentifier: String
    @NSManaged var isActive: Bool
    @NSManaged var storeApp: StoreApp?
    func matches(_ other: AppVersion) -> Bool { version == other.version && storeBuildVersion == other.buildVersion }
'''

SQLITE_SUFFIX = r'''
}
func attribute(_ name: String, _ type: NSAttributeType) -> NSAttributeDescription {
    let value = NSAttributeDescription(); value.name = name; value.attributeType = type; value.isOptional = true
    return value
}
func entity(_ name: String, _ type: AnyClass, _ fields: [(String, NSAttributeType)]) -> NSEntityDescription {
    let result = NSEntityDescription(); result.name = name; result.managedObjectClassName = NSStringFromClass(type)
    result.properties = fields.map { attribute($0.0, $0.1) }; return result
}
func relation(_ name: String, _ destination: NSEntityDescription) -> NSRelationshipDescription {
    let value = NSRelationshipDescription(); value.name = name; value.destinationEntity = destination
    value.maxCount = 1; value.minCount = 0; value.isOptional = true; return value
}
let host = Bundle.Info.activeBundleURL
try FileManager.default.createDirectory(at: host, withIntermediateDirectories: true)
let info: [String: Any] = ["CFBundleIdentifier": Bundle.Info.activeBundleIdentifier, "CFBundleShortVersionString": "3.8.14",
                          "CFBundleVersion": "20261125.58", "CFBundlePackageType": "APPL", "LCEmbeddedApps": ["SideStore", "SideInstaller"]]
try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: host.appendingPathComponent("Info.plist"))
let installed = entity("InstalledApp", InstalledApp.self, [("version", .stringAttributeType), ("buildVersion", .stringAttributeType),
    ("storeBuildVersion", .stringAttributeType), ("bundleIdentifier", .stringAttributeType),
    ("resignedBundleIdentifier", .stringAttributeType), ("isActive", .booleanAttributeType), ("hasUpdate", .booleanAttributeType)])
let store = entity("StoreApp", StoreApp.self, [])
let version = entity("AppVersion", AppVersion.self, [("version", .stringAttributeType), ("buildVersion", .stringAttributeType)])
installed.properties.append(relation("storeApp", store)); store.properties.append(relation("latestSupportedVersion", version))
let model = NSManagedObjectModel(); model.entities = [installed, store, version]
let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
try coordinator.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil,
    at: URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("checks.sqlite"))
let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType); context.persistentStoreCoordinator = coordinator
let release = AppVersion(entity: version, insertInto: context); release.version = "3.8.14"; release.buildVersion = "20261125.58"
let catalog = StoreApp(entity: store, insertInto: context); catalog.latestSupportedVersion = release
@MainActor func make(_ identifier: String, _ build: String) -> InstalledApp {
    let app = InstalledApp(entity: installed, insertInto: context)
    app.version = "3.8.14"; app.buildVersion = build; app.storeBuildVersion = build
    app.bundleIdentifier = StoreApp.altstoreAppID; app.resignedBundleIdentifier = identifier
    app.isActive = true; app.storeApp = catalog; return app
}
let current = make(Bundle.Info.activeBundleIdentifier, "20261124.55")
let other = make("com.kdt.livecontainer2.TEST", "20261124.55")
precondition(!current.hasUpdate && other.hasUpdate)
try context.save()
let fetch = NSFetchRequest<InstalledApp>(entityName: "InstalledApp"); fetch.predicate = NSPredicate(format: "hasUpdate == YES")
func check(_ condition: Bool) { precondition(condition) }
check(try context.fetch(fetch).count == 1)
// Reproduce a persisted stale flag independently of the computed getter.
let stale = NSBatchUpdateRequest(entityName: "InstalledApp"); stale.propertiesToUpdate = ["hasUpdate": true]
try context.execute(stale); context.reset()
check(try context.fetch(fetch).count == 2)
for app in try context.fetch(NSFetchRequest<InstalledApp>(entityName: "InstalledApp")) { app.synchronizeUpdateAvailability() }
try context.save()
check(try context.fetch(fetch).count == 1)
let oldCopy = try context.fetch(fetch)[0]; oldCopy.storeBuildVersion = "20261125.58"; oldCopy.buildVersion = "20261125.58"
try context.save(); check(try context.fetch(fetch).isEmpty)
oldCopy.storeApp?.latestSupportedVersion?.buildVersion = "20261125.59"
for app in try context.fetch(NSFetchRequest<InstalledApp>(entityName: "InstalledApp")) { app.synchronizeUpdateAvailability() }
try context.save(); check(try context.fetch(fetch).count == 2)
oldCopy.isActive = false; try context.save(); check(try context.fetch(fetch).count == 1)
print("SQLite update flag, equal/newer build and independent copies verified")
'''


if __name__ == "__main__":
    unittest.main()
