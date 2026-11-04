"""Execute production cellular coordination and shortcut-deadline failure paths."""

from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
SWIFTC = shutil.which("swiftc")
SOURCES = ROOT / "SideStore/Core/Shortcuts"

HARNESS = r'''
import Foundation

enum Failure: Error { case operation }
enum ShortcutOutcome: Sendable, Equatable { case success, error, cancel, reject, silent }

final class Fixture: @unchecked Sendable {
    let lock = NSLock()
    var pause = true
    var cellular: Bool? = true
    var foreground = true
    var ready = true
    var pending: String?
    var calls: [String] = []
    var urls: [URL] = []
    var outcomes: [ShortcutOutcome] = []
    var owned: CellularRefreshCoordinator!

    init(pending: String? = nil) {
        self.pending = pending
        owned = CellularRefreshCoordinator(environment: .init(
            shouldPause: { [unowned self] in self.lock.withLock { self.pause } },
            cellularAvailable: { [unowned self] in self.lock.withLock { self.cellular } },
            isForeground: { [unowned self] in self.lock.withLock { self.foreground } },
            openURL: { [unowned self] url in self.open(url) },
            endpointReady: { [unowned self] in self.lock.withLock { self.ready } },
            pendingID: { [unowned self] in self.lock.withLock { self.pending } },
            savePendingID: { [unowned self] id in self.lock.withLock { self.pending = id } },
            settings: { .init(offName: "Turn Off & Data", onName: "Turn On Data",
                               callbackScheme: "livecontainer2", offDelay: 0, onDelay: 0) }
        ), callbackTimeout: 0.04, ownerTimeout: 1, readyTimeout: 0.04)
    }

    func open(_ url: URL) -> Bool {
        let parts = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        precondition(parts.host == "x-callback-url" && parts.path == "/run-shortcut")
        let name = parts.queryItems!.first { $0.name == "name" }!.value!
        let outcome: ShortcutOutcome = lock.withLock {
            precondition(pending != nil, "Recovery must be durable BEFORE launching the disable action")
            calls.append(name)
            urls.append(url)
            return outcomes.isEmpty ? .success : outcomes.removeFirst()
        }
        if outcome == .reject { return false }
        if outcome == .silent { return true }
        let kind = outcome == .error ? "error" : outcome == .cancel ? "cancel" : "success"
        let callback = URL(string: parts.queryItems!.first { $0.name == "x-" + kind }!.value!)!
        precondition(callback.scheme == "livecontainer2")
        var wrong = URLComponents(url: callback, resolvingAgainstBaseURL: false)!
        wrong.scheme = "sidestore"
        precondition(!owned.handleCallback(wrong.url!))
        wrong.scheme = callback.scheme
        wrong.queryItems = [URLQueryItem(name: "token", value: UUID().uuidString)]
        precondition(!owned.handleCallback(wrong.url!))
        precondition(owned.handleCallback(callback)) // May arrive before openURL returns.
        precondition(!owned.handleCallback(callback), "Duplicate callback must be harmless")
        return true
    }

    func roundTrip() async throws {
        try await owned.withRestorationScope {
            try await owned.turnOffDataIfNeeded()
            try await owned.turnOnDataIfNeeded()
        }
    }
}

@main
struct CellularRegression {
    static func expect(_ expected: CellularRefreshError, _ operation: () async throws -> Void) async {
        do { try await operation(); preconditionFailure("Expected \(expected)") }
        catch { precondition(error as? CellularRefreshError == expected, "Unexpected error: \(error)") }
    }

    static func main() async throws {
        try await normalAndUnavailable()
        try await shortcutsAndReadiness()
        try await failuresAndCancellation()
        try await concurrentOperations()
        try await recoveryAndStaleCallbacks()
        try await deadlineResults()
        print("Cellular restoration and background deadline regressions passed")
    }

    static func normalAndUnavailable() async throws {
        let normal = Fixture()
        try await normal.roundTrip()
        precondition(normal.pending == nil && normal.calls == ["Turn Off & Data", "Turn On Data"])
        let wifi = Fixture()
        wifi.pause = false
        try await wifi.roundTrip()
        precondition(wifi.calls.isEmpty && wifi.pending == nil)
        let alreadyOff = Fixture()
        alreadyOff.cellular = false
        try await alreadyOff.roundTrip()
        precondition(alreadyOff.calls.isEmpty && alreadyOff.pending == nil)
        let noPath = Fixture()
        noPath.cellular = false
        noPath.ready = false
        await expect(.endpointNotReady) { try await noPath.roundTrip() }
        precondition(noPath.calls.isEmpty && noPath.pending == nil)
        let unknownPath = Fixture()
        unknownPath.cellular = nil
        await expect(.networkUnknown) { try await unknownPath.roundTrip() }
        precondition(unknownPath.calls.isEmpty && unknownPath.pending == nil)
        let background = Fixture()
        background.foreground = false
        await expect(.foregroundRequired) { try await background.roundTrip() }
        precondition(background.calls.isEmpty && background.pending == nil)
    }

    static func shortcutsAndReadiness() async throws {
        let rejected = Fixture()
        rejected.outcomes = [.reject]
        await expect(.shortcutRejected("Turn Off & Data")) { try await rejected.roundTrip() }
        precondition(rejected.calls.count == 1 && rejected.pending == nil)
        let failed = Fixture()
        failed.outcomes = [.error, .success]
        await expect(.shortcutFailed("Turn Off & Data")) { try await failed.roundTrip() }
        precondition(failed.calls.count == 2 && failed.pending == nil)
        let cancelled = Fixture()
        cancelled.outcomes = [.cancel, .success]
        await expect(.shortcutCancelled("Turn Off & Data")) { try await cancelled.roundTrip() }
        precondition(cancelled.calls.count == 2 && cancelled.pending == nil)
        let timedOut = Fixture()
        timedOut.outcomes = [.silent, .success]
        await expect(.shortcutTimedOut("Turn Off & Data")) { try await timedOut.roundTrip() }
        precondition(timedOut.calls.count == 2 && timedOut.pending == nil)
        let unready = Fixture()
        unready.ready = false
        await expect(.endpointNotReady) { try await unready.roundTrip() }
        precondition(unready.calls.count == 2 && unready.pending == nil)
    }

    static func failuresAndCancellation() async throws {
        let failed = Fixture()
        do {
            try await failed.owned.withRestorationScope {
                try await failed.owned.turnOffDataIfNeeded()
                throw Failure.operation
            }
            preconditionFailure("Expected operation failure")
        } catch Failure.operation { }
        precondition(failed.calls.count == 2 && failed.pending == nil)
        let cancelled = Fixture()
        let task = Task {
            try await cancelled.owned.withRestorationScope {
                try await cancelled.owned.turnOffDataIfNeeded()
                withUnsafeCurrentTask { $0?.cancel() }
                try Task.checkCancellation()
            }
        }
        do { try await task.value; preconditionFailure("Expected cancellation") }
        catch is CancellationError { }
        precondition(cancelled.calls.count == 2 && cancelled.pending == nil)
        let restorationFailed = Fixture()
        restorationFailed.outcomes = [.success, .reject]
        await expect(.recoveryRequired) { try await restorationFailed.roundTrip() }
        precondition(restorationFailed.calls.count == 2 && restorationFailed.pending != nil)
    }

    static func concurrentOperations() async throws {
        let fixture = Fixture()
        async let first: Void = fixture.roundTrip()
        async let second: Void = fixture.roundTrip()
        _ = try await (first, second)
        precondition(fixture.calls == ["Turn Off & Data", "Turn On Data", "Turn Off & Data", "Turn On Data"])
        precondition(fixture.pending == nil)
        let nested = Fixture()
        try await nested.owned.withRestorationScope {
            try await nested.owned.turnOffDataIfNeeded()
            try await nested.owned.withRestorationScope {
                try await nested.owned.turnOffDataIfNeeded()
            }
        }
        precondition(nested.calls.count == 2 && nested.pending == nil)
    }

    static func recoveryAndStaleCallbacks() async throws {
        let cold = Fixture(pending: "saved-before-process-exit")
        cold.foreground = false
        try await cold.owned.recoverPendingData()
        precondition(cold.calls.isEmpty && cold.pending != nil)
        cold.foreground = true
        try await cold.owned.recoverPendingData()
        try await cold.owned.recoverPendingData()
        precondition(cold.calls == ["Turn On Data"] && cold.pending == nil)
        let failed = Fixture(pending: "saved-failed")
        failed.outcomes = [.reject]
        await expect(.recoveryRequired) { try await failed.owned.recoverPendingData() }
        try await failed.owned.recoverPendingData()
        precondition(failed.calls == ["Turn On Data"] && failed.pending != nil)
        let finished = Fixture()
        try await finished.roundTrip()
        let parts = URLComponents(url: finished.urls[0], resolvingAgainstBaseURL: false)!
        let old = URL(string: parts.queryItems!.first { $0.name == "x-success" }!.value!)!
        precondition(!finished.owned.handleCallback(old))
        precondition(!finished.owned.handleCallback(URL(string: "livecontainer2://cellular-refresh/success?token=wrong")!))
        precondition(finished.calls.count == 2 && finished.pending == nil)
    }

    static func deadlineResults() async throws {
        let completedEarly = BackgroundRefreshWaiter()
        completedEarly.finish(.success(()))
        completedEarly.finish(.failure(Failure.operation))
        try await completedEarly.wait(timeout: 0.04, onTimeout: { preconditionFailure("Already completed") })
        let failedEarly = BackgroundRefreshWaiter()
        failedEarly.finish(.failure(Failure.operation))
        do { try await failedEarly.wait(timeout: 0.04, onTimeout: {}); preconditionFailure("Expected failure") }
        catch Failure.operation { }
        let pending = BackgroundRefreshWaiter()
        do { try await pending.wait(timeout: 0.01, onTimeout: {}); preconditionFailure("Must not claim success") }
        catch BackgroundRefreshPendingError.stillRunning { }
        pending.finish(.success(())) // Late completion must not resume twice.
        let lateFailure = BackgroundRefreshWaiter()
        do { try await lateFailure.wait(timeout: 0.01, onTimeout: {}); preconditionFailure("Must not claim success") }
        catch BackgroundRefreshPendingError.stillRunning { }
        lateFailure.finish(.failure(Failure.operation))
        let cancelled = BackgroundRefreshWaiter()
        let task = Task { try await cancelled.wait(timeout: 1, onTimeout: {}) }
        task.cancel()
        do { try await task.value; preconditionFailure("Expected cancellation") }
        catch is CancellationError { }
        cancelled.finish(.success(()))
    }
}
'''


@unittest.skipUnless(SWIFTC, "swiftc is required to execute the production cellular coordinator")
class CellularRefreshTests(unittest.TestCase):
    def test_callbacks_recovery_and_background_deadline(self):
        with tempfile.TemporaryDirectory(prefix="ss-cellular-") as directory:
            source = Path(directory) / "CellularRegression.swift"
            binary = Path(directory) / "CellularRegression"
            source.write_text(HARNESS, encoding="utf-8")
            command = [SWIFTC, "-swift-version", "5", "-parse-as-library"]
            production = [SOURCES / "CellularRefreshCoordinator.swift", SOURCES / "BackgroundRefreshWaiter.swift"]
            result = subprocess.run(command + [str(p) for p in production] + [str(source), "-o", str(binary)], capture_output=True, text=True, timeout=120)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
