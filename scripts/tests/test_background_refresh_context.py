"""Run detached refresh ownership regressions against real macOS CoreData.

Only the production initializer, resolver and refresh handoff are compiled.
The store is in memory; signing, device calls and notifications are test doubles.
"""

from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
SWIFTC = shutil.which("swiftc")

HARNESS = r'''
import Foundation
import CoreData
import Darwin

func fail(_ message: String) -> Never {
    fputs("Regression failed: " + message + "\n", stderr)
    fflush(stderr)
    exit(1)
}

func expect(_ condition: Bool, _ message: String) {
    if !condition { fail(message) }
}

@objc(RefreshContextTestInstalledApp)
final class InstalledApp: NSManagedObject {
    @NSManaged var name: String
    @NSManaged var bundleIdentifier: String
    @NSManaged var certificateSerialNumber: String?
}

enum OperationError: Error { case invalidParameters(String) }
enum StoreApp { static let altstoreAppID = "synthetic.sidestore" }

final class OperationContext {
    let dbBackgroundContext: NSManagedObjectContext
    var error: Error?
    init(_ dbContext: NSManagedObjectContext) { dbBackgroundContext = dbContext }
}

class BaseStandaloneOperation<Context, Value> {
    let context: Context
    let progress = Progress(totalUnitCount: 100)
    init(context: Context) throws { self.context = context }
    func setProgress(_ value: Int64) { progress.completedUnitCount = value }
}

final class RefreshGroup {
    let context: OperationContext
    let results: [String: Result<InstalledApp, Error>]
    var beginInstallationHandler: ((InstalledApp) -> Void)?
    var completionHandler: (([String: Result<InstalledApp, Error>]) -> Void)? {
        didSet {
            guard let completed = completionHandler else { return }
            let results = self.results
            Task { completed(results) }
        }
    }
    init(context: OperationContext, results: [String: Result<InstalledApp, Error>]) {
        self.context = context
        self.results = results
    }
}

final class AppManager {
    static let shared = AppManager()
    var receivedContext: NSManagedObjectContext?
    var receivedApps: [InstalledApp] = []

    func refresh(_ apps: [InstalledApp], presentingViewController: Any?,
                 dbContext: NSManagedObjectContext? = nil) -> RefreshGroup {
        receivedContext = dbContext
        receivedApps = apps
        let context = dbContext ?? apps.first!.managedObjectContext!
        let results = context.performAndWait {
            Dictionary(uniqueKeysWithValues: apps.map {
                ($0.bundleIdentifier, Result<InstalledApp, Error>.success($0))
            })
        }
        return RefreshGroup(context: OperationContext(context), results: results)
    }
}

final class BackgroundRefreshAppsOperation: BaseStandaloneOperation<OperationContext, [String: Result<InstalledApp, Error>]> {
    let installedApps: [InstalledApp]
// INIT_METHOD
// RESOLVE_METHOD
// REFRESH_METHOD

    func runRefresh() async throws -> [String: Result<InstalledApp, Error>] {
        try await self.refresh(installedApps)
    }
    private func scheduleFinishedRefreshingNotification(for result: Result<[String: Result<InstalledApp, Error>], Error>) {}
}

final class Fixture {
    let coordinator: NSPersistentStoreCoordinator
    var objectIDs: [NSManagedObjectID] = []
    static let records = [
        ("synthetic.sidestore", "SideStore", "SYNTHETIC-CERT-A"),
        ("synthetic.app", "Second App", "SYNTHETIC-CERT-B")
    ]

    init() throws {
        let entity = NSEntityDescription()
        entity.name = "InstalledApp"
        entity.managedObjectClassName = NSStringFromClass(InstalledApp.self)
        entity.properties = ["name", "bundleIdentifier", "certificateSerialNumber"].map { name in
            let attribute = NSAttributeDescription()
            attribute.name = name
            attribute.attributeType = .stringAttributeType
            attribute.isOptional = name == "certificateSerialNumber"
            return attribute
        }
        let model = NSManagedObjectModel()
        model.entities = [entity]
        coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
        try coordinator.addPersistentStore(ofType: NSInMemoryStoreType, configurationName: nil, at: nil, options: nil)
        let writer = newContext()
        objectIDs = try writer.performAndWait {
            let apps = Self.records.map { record in
                let app = NSEntityDescription.insertNewObject(forEntityName: "InstalledApp", into: writer) as! InstalledApp
                app.bundleIdentifier = record.0
                app.name = record.1
                app.certificateSerialNumber = record.2
                return app
            }
            try writer.save()
            return apps.map(\.objectID)
        }
    }

    func newContext() -> NSManagedObjectContext {
        let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator
        return context
    }

    func fetch(in context: NSManagedObjectContext) throws -> [InstalledApp] {
        try context.performAndWait {
            try objectIDs.map { try context.existingObject(with: $0) as! InstalledApp }
        }
    }

    func verify(_ operation: BackgroundRefreshAppsOperation) {
        let context = operation.context.dbBackgroundContext
        context.performAndWait {
            expect(operation.installedApps.map(\.objectID) == objectIDs, "Selected object IDs changed")
            for (app, record) in zip(operation.installedApps, Self.records) {
                expect(app.managedObjectContext === context, "Refresh retained an app from the caller's context")
                expect(app.bundleIdentifier == record.0, "Bundle identifier was lost")
                expect(app.name == record.1, "App name was lost")
                expect(app.certificateSerialNumber == record.2, "Certificate metadata was lost")
            }
        }
    }
}

@main
struct BackgroundRefreshContextRegression {
    static func main() async {
        do {
            try await releasedCaller()
            try resetCaller()
            try invalidSelection()
            print("Background refresh CoreData ownership regression passed")
        } catch {
            fail("Unexpected CoreData error: \(error)")
        }
    }

    static func releasedCaller() async throws {
        let fixture = try Fixture()
        weak var callerContext: NSManagedObjectContext?
        var originalApps: [InstalledApp] = []
        let operation = try autoreleasepool {
            let caller = fixture.newContext()
            callerContext = caller
            originalApps = try fixture.fetch(in: caller)
            return try BackgroundRefreshAppsOperation(installedApps: originalApps,
                context: OperationContext(fixture.newContext()))
        }

        // Keep the source objects alive while proving their context was released.
        // Reading an invalidated object's context property is not supported.
        withExtendedLifetime(originalApps) {
            expect(callerContext == nil, "The original fetch context was not released")
            fixture.verify(operation)
        }
        let results = try await operation.runRefresh()
        expect(AppManager.shared.receivedContext === operation.context.dbBackgroundContext,
                     "Refresh handed its apps to a different database context")
        expect(Set(results.keys) == Set(Fixture.records.map { $0.0 }), "Refresh result bundle identifiers changed")
        for result in results.values {
            let app = try result.get()
            expect(app.managedObjectContext === operation.context.dbBackgroundContext, "Results lost their owning context")
        }
        expect(operation.progress.completedUnitCount == 100, "Refresh progress did not finish")
        print("case: original fetch context released before detached refresh; names, IDs and certificates preserved")
    }

    static func resetCaller() throws {
        let fixture = try Fixture()
        let caller = fixture.newContext()
        let apps = try fixture.fetch(in: caller)
        let operation = try BackgroundRefreshAppsOperation(installedApps: apps,
            context: OperationContext(fixture.newContext()))
        caller.performAndWait { caller.reset() }
        fixture.verify(operation)
        print("case: caller reset after dispatch does not invalidate the operation's apps")
    }

    static func invalidSelection() throws {
        let fixture = try Fixture()
        let caller = fixture.newContext()
        let temporary = caller.performAndWait {
            NSEntityDescription.insertNewObject(forEntityName: "InstalledApp", into: caller) as! InstalledApp
        }
        expectFailure("temporary selection") {
            _ = try BackgroundRefreshAppsOperation(installedApps: [temporary],
                context: OperationContext(fixture.newContext()))
        }
        caller.performAndWait { caller.reset() }

        let apps = try fixture.fetch(in: caller)
        try caller.performAndWait {
            caller.delete(apps[0])
            try caller.save()
        }
        expectFailure("deleted selection") {
            _ = try BackgroundRefreshAppsOperation(installedApps: [apps[0]],
                context: OperationContext(fixture.newContext()))
        }

        let empty = try BackgroundRefreshAppsOperation(installedApps: [],
            context: OperationContext(fixture.newContext()))
        expect(empty.installedApps.isEmpty, "Empty selection was not preserved")
        print("case: temporary and deleted selections fail; an empty selection is preserved")
    }

    static func expectFailure(_ name: String, _ work: () throws -> Void) {
        do {
            try work()
            fail("Invalid " + name + " was accepted")
        } catch {}
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


def production_harness(source=None):
    source = source or (ROOT / "SideStore/Core/Operations/StandaloneOperations/BackgroundRefreshAppsOperation.swift").read_text(encoding="utf-8")
    resolver = "private static func resolveInstalledApp("
    methods = {
        "INIT_METHOD": declaration(source, "init(installedApps:"),
        "RESOLVE_METHOD": declaration(source, resolver) if resolver in source else "",
        "REFRESH_METHOD": declaration(source, "private func refresh("),
    }
    harness = HARNESS
    for marker, method in methods.items():
        harness = harness.replace("// " + marker, method)
    return harness


@unittest.skipUnless(SWIFTC and sys.platform == "darwin", "Requires macOS swiftc and real CoreData")
class BackgroundRefreshContextTests(unittest.TestCase):
    def test_detached_refresh_preserves_live_app_records(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "Regression.swift"
            binary = Path(directory) / "regression"
            source.write_text(production_harness(), encoding="utf-8")
            compiled = subprocess.run([SWIFTC, "-parse-as-library", "-O", str(source), "-o", str(binary)],
                                      capture_output=True, text=True, timeout=90)
            self.assertEqual(compiled.returncode, 0, compiled.stdout + compiled.stderr)
            result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=20)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            print(result.stdout, end="")
            self.assertIn("Background refresh CoreData ownership regression passed", result.stdout)


if __name__ == "__main__":
    unittest.main()
