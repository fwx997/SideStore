"""Execute production refresh operations with device and Core Data test doubles."""

from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
SWIFTC = shutil.which("swiftc")
OPERATIONS = ROOT / "SideStore/Core/Operations"


def member(source, signature):
    start = source.index(signature)
    opening = source.index("{", start)
    depth = 1
    end = opening + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end]


def production_source():
    model = (ROOT / "AltStore/Core/Model/InstalledApp.swift").read_text(encoding="utf-8")
    contexts = (OPERATIONS / "OperationContexts.swift").read_text(encoding="utf-8")
    runner = (OPERATIONS / "PipelineRunner.swift").read_text(encoding="utf-8")
    replacements = {
        "// MODEL_METHODS": "\n".join(member(model, signature) for signature in (
            "func update(provisioningProfile: ALTProvisioningProfile)",
            "func update(provisioningProfiles: [String: ALTProvisioningProfile])",
        )),
        "// BATCH_TYPE": member(contexts, "struct PendingProfileBatch"),
        "// RUNNER_METHODS": "\n".join(member(runner, signature) for signature in (
            "func performOperation(for operation: AppOperation",
            "private func completeOperation(_ operation: AppOperation",
        )),
    }
    result = HARNESS
    for marker, replacement in replacements.items():
        result = result.replace(marker, replacement)
    for relative in (
        "PipelineOperations/RefreshAppOperation.swift",
        "StandaloneOperations/InjectBatchProfilesOperation.swift",
    ):
        source = (OPERATIONS / relative).read_text(encoding="utf-8")
        result += re.sub(r"^import (Foundation|CoreData|SideSign)\s*$", "", source, flags=re.M)
    return result


HARNESS = r'''
import Foundation
import CoreFoundation

enum Failure: Error { case install, save, missing }
enum ALTError: Error { case invalidApp(reason: String) }
enum OperationError: Error {
    case invalidParameters(String), cancelled
}
enum CertificateStatus { case valid }
enum LoggedError { enum Operation { case refresh } }
func debugLog(_ message: String) {}

final class Probe: @unchecked Sendable {
    static let shared = Probe()
    var installed: [Data] = []
    var failAt = 0
    var pauses = 0
    var restores = 0
    var widgets = 0
    var successes = 0
    func reset() {
        installed = []; failAt = 0; pauses = 0; restores = 0
        widgets = 0; successes = 0
    }
}
func installProvisioningProfiles(_ data: Data) async throws {
    let probe = Probe.shared
    if probe.failAt == probe.installed.count + 1 { throw Failure.install }
    probe.installed.append(data)
}
final class CellularRefreshManager: @unchecked Sendable {
    static let shared = CellularRefreshManager()
    func withRestorationScope<T>(_ body: () async throws -> T) async throws -> T {
        do { return try await body() }
        catch {
            try await turnOnDataIfNeeded()
            throw error
        }
    }
    func turnOffDataIfNeeded() async throws { Probe.shared.pauses += 1 }
    func turnOnDataIfNeeded() async throws { Probe.shared.restores += 1 }
}
struct ALTProvisioningProfile {
    let creationDate: Date
    let expirationDate: Date
    let data: Data
    init(_ number: Int) {
        creationDate = Date(timeIntervalSince1970: Double(number))
        expirationDate = creationDate.addingTimeInterval(604800)
        data = Data(String(number).utf8)
    }
}
final class InstalledExtension {
    let bundleIdentifier: String
    var customBundleIdentifier: String?
    var refreshedDate = Date.distantPast
    var expirationDate = Date.distantPast
    init(_ id: String, custom: String? = nil) {
        bundleIdentifier = id; customBundleIdentifier = custom
    }
    func update(provisioningProfile: ALTProvisioningProfile) {
        refreshedDate = provisioningProfile.creationDate
        expirationDate = provisioningProfile.expirationDate
    }
}
final class InstalledApp: @unchecked Sendable {
    let bundleIdentifier: String
    var customBundleIdentifier: String?
    let objectID: Int
    var useMainProfile = false
    var certificateStatus: CertificateStatus?
    var refreshedDate = Date.distantPast
    var expirationDate = Date.distantPast
    var appExtensions: [InstalledExtension] = []
    init(_ id: String, objectID: Int = 1, custom: String? = nil) {
        bundleIdentifier = id; self.objectID = objectID; customBundleIdentifier = custom
    }
    // MODEL_METHODS
}
final class NSManagedObjectContext: @unchecked Sendable {
    var records: [Int: InstalledApp] = [:]
    var hasChanges = true
    var failSave = false
    var savedExpirations: [Int: Date] = [:]
    var saves = 0
    func perform<T>(_ body: () throws -> T) async rethrows -> T { try body() }
    func object(with id: Int) -> Any { records[id]! }
    func existingObject(with id: Int) throws -> Any {
        guard let app = records[id] else { throw Failure.missing }
        return app
    }
    func save() throws {
        if failSave { throw Failure.save }
        saves += 1
        savedExpirations = records.mapValues { $0.expirationDate }
        hasChanges = false
    }
    func processPendingChanges() {}
}
struct ALTApplication { let name = "Example" }
class StandaloneOperationContext {
    let dbBackgroundContext: NSManagedObjectContext
    init(steps: [Int] = [], dbBackgroundContext: NSManagedObjectContext) {
        self.dbBackgroundContext = dbBackgroundContext
    }
}
extension Array where Element == Int {
    static var scheduleExpirationWarningNotification: [Int] { [] }
}
// BATCH_TYPE
final class SharedPipelineContext {
    var pendingProfiles: [String: PendingProfileBatch] = [:]
    func addPendingProfileBatch(_ batch: PendingProfileBatch) {
        pendingProfiles[batch.bundleID] = batch
    }
}
final class InstallAppOperationContext: StandaloneOperationContext {
    var provisioningProfiles: [String: ALTProvisioningProfile]?
    var targetAppBundle: ALTApplication? = ALTApplication()
    var isCellularRefreshGroup = false
    let sharedContext = SharedPipelineContext()
    var installedApp: InstalledApp?
    var targetCertStatus: CertificateStatus? = .valid
    var bundleIdentifier: String { installedApp!.bundleIdentifier }
}
class BaseStandaloneOperation<Context, Output> {
    let context: Context
    let progress = Progress(totalUnitCount: 100)
    init(context: Context) throws { self.context = context }
    func execute(parentProgress: Progress? = nil) async throws {}
    func executePreconditionCheck(parentProgress: Progress?) async throws {
        try Task.checkCancellation()
    }
    func setProgress(_ count: Int64) { progress.completedUnitCount = count }
}
class BasePipelineOperation<Context, Output> {
    let context: Context
    let progress = Progress(totalUnitCount: 100)
    init(context: Context) throws { self.context = context }
    func execute(parentProgress: Progress? = nil) async throws -> Output { fatalError() }
    func executePreconditionCheck(parentProgress: Progress?) async throws {
        try Task.checkCancellation()
    }
    func setProgress(_ count: Int64) { progress.completedUnitCount = count }
}
struct AppOperation {
    let app: InstalledApp
    var bundleIdentifier: String { app.bundleIdentifier }
    let loggedErrorOperation = LoggedError.Operation.refresh
    func logSummary(status: String, elapsed: Double, error: Error? = nil) {
        if status == "SUCCESS" { Probe.shared.successes += 1 }
    }
}
struct PipelineExecutionHandler {}
final class ProgressStore {
    func set(_ progress: Progress?, for operation: AppOperation) {}
}
final class ErrorLogger {
    func getMappedError(for operation: AppOperation, error: Error) -> Error { error }
    func log(_ error: Error, operation: LoggedError.Operation, app: InstalledApp) {}
}
final class RefreshGroup {
    let dbContext: NSManagedObjectContext
    let sharedContext: SharedPipelineContext
    let operationStartTime = CFAbsoluteTimeGetCurrent()
    var results: [String: Result<InstalledApp, Error>] = [:]
    init(_ context: InstallAppOperationContext) {
        dbContext = context.dbBackgroundContext; sharedContext = context.sharedContext
    }
    func set(_ result: Result<InstalledApp, Error>, forAppWithBundleIdentifier id: String) {
        results[id] = result
    }
}
struct DatabaseManager {
    static let shared = DatabaseManager()
    let viewContext = NSManagedObjectContext()
}
enum StoreApp { static let altstoreAppID = "host.app" }
enum WidgetDataManager {
    static func publishCurrentInstalledApps(in context: NSManagedObjectContext) async {
        Probe.shared.widgets += 1
    }
}
final class ScheduleExpirationWarningNotificationOperation {
    init(installedApp: InstalledApp, context: StandaloneOperationContext) throws {}
    func execute() async throws {}
}
final class PipelineRunner {
    let progress = ProgressStore()
    let logger = ErrorLogger()
    let operationContext: InstallAppOperationContext
    init(_ context: InstallAppOperationContext) { operationContext = context }
    func performPipeline(for operation: AppOperation, handler: PipelineExecutionHandler,
                         group: RefreshGroup, operationsCount: Int) async throws -> InstalledApp {
        try await RefreshAppOperation(context: operationContext).execute(parentProgress: nil)
    }
    func finish(_ app: InstalledApp, group: RefreshGroup) async throws {
        try await completeOperation(AppOperation(app: app), result: app, group: group, operationsCount: 2)
    }
    // RUNNER_METHODS
}

@available(macOS 13.0, *)
@main struct Regression {
    static func main() async throws {
        try await matchingProfiles()
        try await queuedThenCompleted()
        try await multipleApps()
        try await injectionFailure()
        try await saveFailure()
        try await cancellation()
        try await singleRefresh()
        print("Batch refresh date persistence and completion regressions passed")
    }
    static func fixture(custom: Bool = false) -> InstallAppOperationContext {
        Probe.shared.reset()
        let db = NSManagedObjectContext()
        let context = InstallAppOperationContext(dbBackgroundContext: db)
        let app = InstalledApp("example.app", custom: custom ? "renamed.app" : nil)
        app.appExtensions = [InstalledExtension("example.app.widget",
                                                custom: custom ? "renamed.app.widget" : nil)]
        db.records[app.objectID] = app
        context.installedApp = app
        let id = app.customBundleIdentifier ?? app.bundleIdentifier
        context.provisioningProfiles = [id: ALTProvisioningProfile(100),
                                        id + ".widget": ALTProvisioningProfile(200)]
        return context
    }
    static func matchingProfiles() async throws {
        let context = fixture(custom: true)
        let app = context.installedApp!
        try app.update(provisioningProfiles: context.provisioningProfiles!)
        precondition(app.expirationDate == ALTProvisioningProfile(100).expirationDate)
        precondition(app.refreshedDate == ALTProvisioningProfile(100).creationDate)
        precondition(app.appExtensions[0].expirationDate == ALTProvisioningProfile(200).expirationDate)
        app.useMainProfile = true
        try app.update(provisioningProfiles: ["renamed.app": ALTProvisioningProfile(300)])
        precondition(app.appExtensions[0].expirationDate == ALTProvisioningProfile(300).expirationDate)
        do {
            try app.update(provisioningProfiles: ["renamed.app.widget": ALTProvisioningProfile(400)])
            preconditionFailure("An extension profile must never substitute for the main profile")
        } catch ALTError.invalidApp { }
        precondition(app.expirationDate == ALTProvisioningProfile(300).expirationDate)
    }
    static func prepare(_ context: InstallAppOperationContext) async throws -> (RefreshGroup, PipelineRunner) {
        context.isCellularRefreshGroup = true
        let group = RefreshGroup(context)
        let runner = PipelineRunner(context)
        try await runner.performOperation(for: AppOperation(app: context.installedApp!),
                                          handler: PipelineExecutionHandler(), group: group, operationsCount: 2)
        precondition(group.results.isEmpty && Probe.shared.successes == 0 && Probe.shared.widgets == 0,
                     "Queuing profiles must not publish a success or stale widget data")
        precondition(context.installedApp!.expirationDate == .distantPast)
        precondition(context.dbBackgroundContext.saves == 0 && Probe.shared.installed.isEmpty)
        return (group, runner)
    }
    static func inject(_ context: InstallAppOperationContext, group: RefreshGroup,
                       runner: PipelineRunner) async throws {
        let operation = try InjectBatchProfilesOperation(
            batches: Array(context.sharedContext.pendingProfiles.values), context: context,
            onAppCompleted: { _, app in try await runner.finish(app, group: group) })
        try await operation.execute(parentProgress: nil)
    }
    static func queuedThenCompleted() async throws {
        let context = fixture(custom: true)
        let (group, runner) = try await prepare(context)
        // Batch input can belong to the UI context. Mutations must resolve it in the background context.
        let stored = InstalledApp("example.app", custom: "renamed.app")
        stored.appExtensions = [InstalledExtension("example.app.widget", custom: "renamed.app.widget")]
        context.dbBackgroundContext.records[stored.objectID] = stored
        try await inject(context, group: group, runner: runner)
        precondition(context.installedApp!.expirationDate == .distantPast)
        precondition(stored.expirationDate == ALTProvisioningProfile(100).expirationDate)
        precondition(stored.appExtensions[0].expirationDate == ALTProvisioningProfile(200).expirationDate)
        precondition(context.dbBackgroundContext.savedExpirations[stored.objectID] == stored.expirationDate)
        precondition(Probe.shared.installed.count == 2 && Probe.shared.pauses == 1 && Probe.shared.restores == 1)
        precondition(Probe.shared.successes == 1 && Probe.shared.widgets == 1)
        let result = try group.results[stored.bundleIdentifier]!.get()
        precondition(result === stored)
    }
    static func injectionFailure() async throws {
        let context = fixture()
        let (group, runner) = try await prepare(context)
        Probe.shared.failAt = 2
        do {
            try await inject(context, group: group, runner: runner)
            preconditionFailure("A failed profile installation must fail the batch")
        } catch Failure.install { }
        precondition(context.installedApp!.expirationDate == .distantPast)
        precondition(context.dbBackgroundContext.saves == 0 && group.results.isEmpty)
        precondition(Probe.shared.widgets == 0 && Probe.shared.successes == 0 && Probe.shared.restores == 1)
    }
    static func multipleApps() async throws {
        let context = fixture()
        let first = context.installedApp!
        let (group, runner) = try await prepare(context)
        let second = InstalledApp("another.app", objectID: 2)
        context.dbBackgroundContext.records[second.objectID] = second
        context.installedApp = second
        context.provisioningProfiles = [second.bundleIdentifier: ALTProvisioningProfile(500)]
        try await runner.performOperation(for: AppOperation(app: second),
                                          handler: PipelineExecutionHandler(), group: group, operationsCount: 2)
        precondition(group.results.isEmpty && context.sharedContext.pendingProfiles.count == 2)
        try await inject(context, group: group, runner: runner)
        precondition(first.expirationDate == ALTProvisioningProfile(100).expirationDate)
        precondition(second.expirationDate == ALTProvisioningProfile(500).expirationDate)
        precondition(context.dbBackgroundContext.savedExpirations.count == 2 && group.results.count == 2)
        precondition(Probe.shared.installed.count == 3 && Probe.shared.pauses == 1 && Probe.shared.restores == 1)
        precondition(Probe.shared.successes == 2 && Probe.shared.widgets == 2)
    }
    static func saveFailure() async throws {
        let context = fixture()
        let (group, runner) = try await prepare(context)
        context.dbBackgroundContext.failSave = true
        do {
            try await inject(context, group: group, runner: runner)
            preconditionFailure("Saving metadata must succeed before reporting completion")
        } catch Failure.save { }
        precondition(context.dbBackgroundContext.savedExpirations.isEmpty && group.results.isEmpty)
        precondition(Probe.shared.widgets == 0 && Probe.shared.successes == 0 && Probe.shared.restores == 1)
    }
    static func cancellation() async throws {
        let context = fixture()
        let (group, runner) = try await prepare(context)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await inject(context, group: group, runner: runner)
        }
        do { try await task.value; preconditionFailure("Cancelled batches must not install profiles") }
        catch is CancellationError { }
        precondition(Probe.shared.installed.isEmpty && group.results.isEmpty)
    }
    static func singleRefresh() async throws {
        let context = fixture(custom: true)
        let result = try await RefreshAppOperation(context: context).execute(parentProgress: nil)
        precondition(result.expirationDate == ALTProvisioningProfile(100).expirationDate)
        precondition(result.appExtensions[0].expirationDate == ALTProvisioningProfile(200).expirationDate)
        precondition(Probe.shared.installed.count == 2 && context.sharedContext.pendingProfiles.isEmpty)
    }
}
'''


@unittest.skipUnless(SWIFTC, "swiftc is required to execute the production batch refresh operations")
class BatchRefreshTests(unittest.TestCase):
    def test_dates_persist_only_after_profile_installation(self):
        with tempfile.TemporaryDirectory(prefix="ss-batch-refresh-") as directory:
            source = Path(directory) / "BatchRefreshRegression.swift"
            binary = Path(directory) / "BatchRefreshRegression"
            source.write_text(production_source(), encoding="utf-8")
            command = [SWIFTC, "-swift-version", "5", "-parse-as-library", str(source), "-o", str(binary)]
            result = subprocess.run(command, capture_output=True, text=True, timeout=120)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
