"""Run production refresh receipts/execution with controlled database and app callbacks."""

from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
SOURCES = ROOT / "SideStore/Core/Shortcuts"
SWIFTC = shutil.which("swiftc")

ADAPTERS = r'''
import Foundation

enum CellularRefreshError: Error { case busy }
enum CompanionSigningLock { enum Failure: Error { case busy } }
enum OperationError: Error { case noInstalledApps }
enum Fault: LocalizedError {
    case expected
    var errorDescription: String? { "续签失败：\"配对\"\nnetwork unavailable" }
}

actor Gate {
    var released = false
    var waiting: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if released { return }
        await withCheckedContinuation { waiting.append($0) }
    }
    func release() {
        released = true
        let old = waiting
        waiting.removeAll()
        for continuation in old { continuation.resume() }
    }
}

final class InstalledApp {
    static func fetchAppsForRefreshingAll(in context: FakeContext) -> [InstalledApp] { Fixture.current.apps }
}
final class FakeContext {
    func perform<T>(_ operation: () -> T) async -> T { operation() }
}
final class FakeContainer { func newBackgroundContext() -> FakeContext { FakeContext() } }
final class DatabaseManager {
    static let shared = DatabaseManager()
    let persistentContainer = FakeContainer()
    func start() async throws {
        let fixture = Fixture.current
        if let gate = fixture.databaseGate { await gate.wait() }
        fixture.markDatabaseReturned()
    }
}
final class CellularRefreshManager {
    static let shared = CellularRefreshManager()
    func checkBackgroundRefreshAllowed() async throws { }
}
final class FakeOperation { let progress = Progress(totalUnitCount: 1) }
final class AppManager {
    static let shared = AppManager()
    func backgroundRefresh(_ apps: [InstalledApp], presentsNotifications: Bool, ignoresServerNotFoundError: Bool,
                           completionHandler: @escaping (Result<[String: Result<InstalledApp, Error>], Error>) -> Void) throws -> FakeOperation {
        precondition(!ignoresServerNotFoundError, "A failed VPN connection must remain an error")
        if Fixture.current.factoryFails { throw Fault.expected }
        Fixture.current.dispatched(completionHandler)
        return FakeOperation()
    }
}

final class Fixture: @unchecked Sendable {
    static var current = Fixture()
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let lock = NSLock()
    var apps = [InstalledApp()]
    var databaseGate: Gate?
    var factoryFails = false
    private var databaseReturned = false
    private var callbacks: [(Result<[String: Result<InstalledApp, Error>], Error>) -> Void] = []
    var dispatchCount: Int { lock.withLock { callbacks.count } }
    var didReturnDatabase: Bool { lock.withLock { databaseReturned } }
    func markDatabaseReturned() { lock.withLock { databaseReturned = true } }
    func dispatched(_ callback: @escaping (Result<[String: Result<InstalledApp, Error>], Error>) -> Void) {
        lock.withLock { callbacks.append(callback) }
    }
    func complete(_ result: Result<[String: Result<InstalledApp, Error>], Error>) {
        let callback = lock.withLock { callbacks.last! }
        callback(result)
    }
    deinit { try? FileManager.default.removeItem(at: root) }
}

enum ShortcutRefreshEnvironment {
    static func store() throws -> ShortcutRefreshResultStore {
        try ShortcutRefreshResultStore(group: Fixture.current.root, hostBundleID: "test.physical.host")
    }
}

final class CompletionProbe: @unchecked Sendable {
    let lock = NSLock()
    private var values: [NSError?] = []
    func finish(_ error: NSError?) { lock.withLock { values.append(error) } }
    var count: Int { lock.withLock { values.count } }
}
'''

MAIN = r'''
@available(macOS 13.0, *)
@main struct RefreshResultRegression {
    static func eventually(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition() {
            precondition(ContinuousClock.now < deadline, "Expected callback did not arrive")
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    static func execution(_ id: String, probe: CompletionProbe, milliseconds: Int = 2000) throws -> ShortcutRefreshExecution {
        try ShortcutRefreshExecution(requestID: id, progress: Progress(totalUnitCount: 1), presentsNotifications: false,
                                     deadline: .now + .milliseconds(milliseconds), completion: probe.finish)
    }

    static func receiptSemantics() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let timestamp = Date()
        let store = try ShortcutRefreshResultStore(group: root, hostBundleID: "test.one", now: { timestamp })
        let id = UUID().uuidString
        try store.begin(requestID: id, message: "waiting")
        precondition(store.query(requestID: id).status == "pending")
        let success = ShortcutRefreshResult.success(requestID: id, message: "已完成\n\"all\"")
        try store.finish(success)
        try store.finish(.failure(Fault.expected, requestID: id))
        try store.finish(.pending(requestID: id, message: "late XPC interruption"))
        precondition(store.query(requestID: id) == success, "A late observer replaced the real final result")
        let confirmed = try store.query(requestID: id).checkedForShortcut(returnErrorsAsResult: false)
        precondition(confirmed.succeeded, "A transport error hid the persisted success")
        let failedID = UUID().uuidString
        try store.begin(requestID: failedID, message: "waiting")
        try store.finish(.failure(Fault.expected, requestID: failedID))
        try store.finish(.pending(requestID: failedID, message: "late XPC interruption"))
        precondition(store.query(requestID: failedID).status == "failed", "Transport state replaced the actual failure")
        let restarted = try ShortcutRefreshResultStore(group: root, hostBundleID: "test.one")
        precondition(restarted.query(requestID: id) == success, "Process restart lost a completed receipt")
        let other = try ShortcutRefreshResultStore(group: root, hostBundleID: "test.two")
        precondition(other.query(requestID: id).status == "unknown", "Read another physical host's receipt")
        for invalid in ["../../escape", "", " " + id, "{" + id + "}"] {
            let result = store.query(requestID: invalid)
            precondition(result.status == "unknown" && !result.canDisconnectVPN)
            do { try store.begin(requestID: invalid, message: "bad"); preconditionFailure("Accepted an invalid request ID") }
            catch { }
        }
        let expired = try ShortcutRefreshResultStore(group: root, hostBundleID: "test.one", now: { timestamp.addingTimeInterval(90_000) })
        precondition(expired.query(requestID: id).status == "unknown", "Expired result was reported as fresh success")
        let data = Data(success.json.utf8)
        let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        precondition(object["requestID"] as? String == id && object["message"] as? String == success.message)
        precondition(object["succeeded"] as? Bool == true && object["canDisconnectVPN"] as? Bool == true)
        let badFile = root.appendingPathComponent("LiveContainer/SideStoreRefreshResults/test.one/\(id).json")
        var bad = try JSONSerialization.jsonObject(with: Data(contentsOf: badFile)) as! [String: Any]
        bad["hostBundleID"] = "test.two"
        try JSONSerialization.data(withJSONObject: bad).write(to: badFile, options: .atomic)
        precondition(store.query(requestID: id).status == "unknown", "Mismatched host metadata was trusted")
    }

    static func transportSemantics() {
        let id = UUID().uuidString
        let pending = ShortcutRefreshResult.pendingError(message: "still running")
        let wrapped = NSError(domain: "AppIntents", code: 1, userInfo: [NSUnderlyingErrorKey: pending,
            NSLocalizedDescriptionKey: "wrapped execution"])
        let result = ShortcutRefreshResult.failure(ShortcutRefreshResult.transportError(wrapped), requestID: id)
        precondition(result.status == "pending" && !result.succeeded && !result.canDisconnectVPN)
        let failure = ShortcutRefreshResult.failure(Fault.expected, requestID: id)
        precondition(failure.status == "failed" && !failure.succeeded && failure.canDisconnectVPN)
        let unknown = ShortcutRefreshResult.failure(ShortcutRefreshResult.unknownError(message: "lost receipt"), requestID: id)
        precondition(unknown.status == "unknown" && !unknown.canDisconnectVPN)
        for output in [result, failure, unknown] {
            precondition((try! output.checkedForShortcut(returnErrorsAsResult: true)) == output)
            do {
                _ = try output.checkedForShortcut(returnErrorsAsResult: false)
                preconditionFailure("Default shortcut behavior continued after an unconfirmed result")
            } catch {
                let classified = ShortcutRefreshResult.failure(error, requestID: id)
                precondition(classified.status == output.status && classified.message == output.message)
            }
        }
    }

    static func completedOperation() async throws {
        Fixture.current = Fixture()
        let id = UUID().uuidString
        let probe = CompletionProbe()
        let operation = try execution(id, probe: probe)
        operation.start()
        let wait = Task { try await operation.wait() }
        try await eventually { Fixture.current.dispatchCount == 1 }
        Fixture.current.complete(.success(["app": .success(InstalledApp())]))
        try await wait.value
        let result = try ShortcutRefreshEnvironment.store().query(requestID: id)
        precondition(result.status == "success" && result.canDisconnectVPN && probe.count == 1)
        Fixture.current.complete(.failure(Fault.expected))
        precondition(probe.count == 1 && (try! ShortcutRefreshEnvironment.store()).query(requestID: id) == result)
    }

    static func lateFailureAfterDeadline() async throws {
        Fixture.current = Fixture()
        let id = UUID().uuidString
        let probe = CompletionProbe()
        let operation = try execution(id, probe: probe, milliseconds: 150)
        operation.start()
        let wait = Task { try await operation.wait() }
        try await eventually { Fixture.current.dispatchCount == 1 }
        do { try await wait.value; preconditionFailure("Deadline reported success") }
        catch { precondition(ShortcutRefreshResult.failure(error, requestID: id).status == "pending") }
        precondition(probe.count == 0, "Wait deadline was sent as the actual operation result")
        precondition((try! ShortcutRefreshEnvironment.store()).query(requestID: id).status == "pending")
        Fixture.current.complete(.success(["app": .failure(Fault.expected)]))
        let restarted = try ShortcutRefreshEnvironment.store()
        let result = restarted.query(requestID: id)
        precondition(result.status == "failed" && result.canDisconnectVPN && result.message == Fault.expected.localizedDescription)
        precondition(probe.count == 1 && Fixture.current.dispatchCount == 1, "Query or timeout restarted the refresh")
        precondition(restarted.query(requestID: UUID().uuidString).status == "unknown")
    }

    static func startupExpiry() async throws {
        Fixture.current = Fixture()
        let fixture = Fixture.current
        let gate = Gate()
        fixture.databaseGate = gate
        let id = UUID().uuidString
        let probe = CompletionProbe()
        let operation = try execution(id, probe: probe, milliseconds: 25)
        operation.start()
        do { try await operation.wait(); preconditionFailure("Blocked startup reported success") }
        catch BackgroundRefreshPendingError.notStarted { }
        let result = try ShortcutRefreshEnvironment.store().query(requestID: id)
        precondition(result.status == "failed" && result.canDisconnectVPN && probe.count == 1)
        await gate.release()
        try await eventually { fixture.didReturnDatabase }
        precondition(fixture.dispatchCount == 0, "Expired database startup dispatched a new refresh")
    }

    static func cancelledWaiter() async throws {
        Fixture.current = Fixture()
        let id = UUID().uuidString
        let probe = CompletionProbe()
        let operation = try execution(id, probe: probe)
        operation.start()
        let wait = Task { try await operation.wait() }
        try await eventually { Fixture.current.dispatchCount == 1 }
        wait.cancel()
        do { try await wait.value; preconditionFailure("Cancellation returned success") }
        catch is CancellationError { }
        let pending = try ShortcutRefreshEnvironment.store().query(requestID: id)
        precondition(pending.status == "pending" && !pending.canDisconnectVPN && probe.count == 0)
        Fixture.current.complete(.success(["app": .success(InstalledApp())]))
        precondition((try! ShortcutRefreshEnvironment.store()).query(requestID: id).status == "success" && probe.count == 1)
    }

    static func busyRequestIsolation() async throws {
        Fixture.current = Fixture()
        let firstID = UUID().uuidString
        let secondID = UUID().uuidString
        let first = try execution(firstID, probe: CompletionProbe())
        first.start()
        let wait = Task { try await first.wait() }
        try await eventually { Fixture.current.dispatchCount == 1 }
        do { _ = try execution(secondID, probe: CompletionProbe()); preconditionFailure("Accepted overlapping shortcut refreshes") }
        catch { precondition(ShortcutRefreshResult.failure(error, requestID: secondID).status == "pending") }
        let store = try ShortcutRefreshEnvironment.store()
        precondition(!store.query(requestID: secondID).canDisconnectVPN)
        Fixture.current.complete(.success(["app": .success(InstalledApp())]))
        try await wait.value
        precondition(store.query(requestID: firstID).status == "success")
        precondition(store.query(requestID: secondID).status == "pending", "Busy request stole another operation's success")
        precondition(Fixture.current.dispatchCount == 1)
    }

    static func noAppsAndFactoryFailure() async throws {
        Fixture.current = Fixture()
        Fixture.current.apps = []
        let emptyID = UUID().uuidString
        let empty = try execution(emptyID, probe: CompletionProbe())
        empty.start()
        try await empty.wait()
        precondition(Fixture.current.dispatchCount == 0 && (try! ShortcutRefreshEnvironment.store()).query(requestID: emptyID).succeeded)
        Fixture.current = Fixture()
        Fixture.current.factoryFails = true
        let failedID = UUID().uuidString
        let probe = CompletionProbe()
        let failed = try execution(failedID, probe: probe)
        failed.start()
        do { try await failed.wait(); preconditionFailure("Factory failure returned success") }
        catch Fault.expected { }
        try await eventually { probe.count == 1 }
        precondition((try! ShortcutRefreshEnvironment.store()).query(requestID: failedID).status == "failed")
    }

    static func main() async throws {
        try receiptSemantics()
        transportSemantics()
        try await completedOperation()
        try await lateFailureAfterDeadline()
        try await startupExpiry()
        try await cancelledWaiter()
        try await busyRequestIsolation()
        try await noAppsAndFactoryFailure()
        print("Refresh result, storage, timeout, cancellation and request isolation regressions passed")
    }
}
'''


@unittest.skipUnless(SWIFTC, "swiftc is required to execute production refresh receipt logic")
class ShortcutRefreshResultTests(unittest.TestCase):
    def test_real_callbacks_receipts_and_cleanup_policy(self):
        execution = (SOURCES / "ShortcutRefreshExecution.swift").read_text(encoding="utf-8")
        start = execution.index("@available(iOS 17.0, tvOS 17.0, macOS 13.0, *)\nfinal class ShortcutRefreshExecution")
        end = execution.index("@available(iOS 17.0, tvOS 17.0, macOS 13.0, *)\n@objc(SSBackgroundRefreshBridge)")
        with tempfile.TemporaryDirectory(prefix="ss-refresh-result-") as directory:
            harness = Path(directory) / "RefreshResultRegression.swift"
            binary = Path(directory) / "RefreshResultRegression"
            harness.write_text(ADAPTERS + execution[start:end] + MAIN, encoding="utf-8")
            production = [SOURCES / "ShortcutRefreshResult.swift", SOURCES / "BackgroundRefreshWaiter.swift"]
            compile_result = subprocess.run([SWIFTC, "-swift-version", "5", "-parse-as-library", *map(str, production), str(harness), "-o", str(binary)], capture_output=True, text=True, timeout=120)
            self.assertEqual(compile_result.returncode, 0, compile_result.stdout + compile_result.stderr)
            run_result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=30)
            self.assertEqual(run_result.returncode, 0, run_result.stdout + run_result.stderr)


if __name__ == "__main__":
    unittest.main()
