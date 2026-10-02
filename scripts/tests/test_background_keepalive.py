"""Exercise the production keepalive coordinator without audio, GPS, or a device."""

from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
SWIFTC = shutil.which("swiftc")
SERVICES = ROOT / "SideStore/Core/BackgroundServices"

HARNESS = r'''
import Foundation

final class UserDefaults {
    static let standard = UserDefaults()
    var isBackgroundServiceEnabled = true
    var backgroundServiceMode = BackgroundServiceMode.audio
}

class FakeService: BackgroundService, @unchecked Sendable {
    var isRunning = false
    var starts = 0
    func start() -> Bool { starts += 1; isRunning = true; return true }
    func stop() { isRunning = false }
}
final class BackgroundAudioService: FakeService, @unchecked Sendable {
    static let shared = BackgroundAudioService()
}
final class BackgroundLocationService: FakeService, @unchecked Sendable {
    static let shared = BackgroundLocationService()
}

enum ExpectedFailure: Error { case failed }

@main
struct KeepaliveRegression {
    @MainActor static func expectIdle() {
        precondition(!BackgroundAudioService.shared.isRunning)
        precondition(!BackgroundLocationService.shared.isRunning)
    }

    @MainActor static func main() async throws {
        let audio = BackgroundAudioService.shared
        let location = BackgroundLocationService.shared
        precondition(!BackgroundServiceManager.ensureBackgroundServicesStarted())
        BackgroundServiceManager.setEnabled(true)
        BackgroundServiceManager.switchTo(mode: .location)
        expectIdle()
        precondition(audio.starts == 0 && location.starts == 0)
        BackgroundServiceManager.switchTo(mode: .audio)

        let first = BackgroundServiceManager.beginTask()
        let second = BackgroundServiceManager.beginTask()
        precondition(audio.isRunning && audio.starts == 1)
        BackgroundServiceManager.endTask(first)
        BackgroundServiceManager.endTask(first) // Duplicate completion must be harmless.
        BackgroundServiceManager.endTask(UUID())
        precondition(audio.isRunning)
        BackgroundServiceManager.endTask(second)
        expectIdle()
        precondition(!BackgroundServiceManager.ensureBackgroundServicesStarted())

        BackgroundServiceManager.setEnabled(false)
        let disabledTask = BackgroundServiceManager.beginTask()
        expectIdle()
        BackgroundServiceManager.setEnabled(true)
        precondition(audio.isRunning)
        BackgroundServiceManager.switchTo(mode: .location)
        precondition(!audio.isRunning && location.isRunning)
        BackgroundServiceManager.setEnabled(false)
        expectIdle()
        BackgroundServiceManager.endTask(disabledTask)
        BackgroundServiceManager.setEnabled(true)
        expectIdle()

        let reinstall = BackgroundServiceManager.beginTask()
        BackgroundServiceManager.stop()
        let overlapping = BackgroundServiceManager.beginTask()
        BackgroundServiceManager.setEnabled(true)
        BackgroundServiceManager.switchTo(mode: .audio)
        precondition(!BackgroundServiceManager.ensureBackgroundServicesStarted())
        expectIdle()
        BackgroundServiceManager.endTask(reinstall)
        BackgroundServiceManager.endTask(overlapping)
        let nextTask = BackgroundServiceManager.beginTask()
        precondition(audio.isRunning)
        BackgroundServiceManager.endTask(nextTask)
        expectIdle()

        // Use the actual pipeline acquisition/defer in success, failure, and cancellation paths.
        try await pipelineScope { }
        await drainCleanup()
        expectIdle()
        do {
            try await pipelineScope { throw ExpectedFailure.failed }
            preconditionFailure("Expected task failure")
        } catch ExpectedFailure.failed { }
        await drainCleanup()
        expectIdle()
        let cancelled = Task { try await pipelineScope { try Task.checkCancellation() } }
        cancelled.cancel()
        do {
            try await cancelled.value
            preconditionFailure("Expected cancellation")
        } catch is CancellationError { }
        await drainCleanup()
        expectIdle()

        // Background fetch and a foreground pipeline must share one service lifetime.
        var finishFetch: (() -> Void)?
        BackgroundTaskManager.shared.performExtendedBackgroundTask { result, completion in
            precondition((try? result.get()) != nil)
            finishFetch = completion
        }
        let pipeline = BackgroundServiceManager.beginTask()
        finishFetch?()
        finishFetch?()
        await drainCleanup()
        precondition(audio.isRunning)
        BackgroundServiceManager.endTask(pipeline)
        expectIdle()
        print("Background keepalive lifetime regressions passed")
    }

    static func pipelineScope(_ operation: () async throws -> Void) async throws {
        // PIPELINE_SCOPE
        try await operation()
    }

    static func drainCleanup() async {
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
}
'''


@unittest.skipUnless(SWIFTC, "swiftc is required to execute the production coordinator")
class BackgroundKeepaliveTests(unittest.TestCase):
    def test_task_lifetimes(self):
        pipeline = (ROOT / "SideStore/Core/Operations/PipelineRunner.swift").read_text(encoding="utf-8")
        start = pipeline.index("        let keepaliveTask =")
        end = pipeline.index("        let backgroundTaskID =", start)
        harness = HARNESS.replace("        // PIPELINE_SCOPE", pipeline[start:end])
        sources = [SERVICES / "BackgroundService.swift", ROOT / "AltStore/Components/BackgroundTaskManager.swift"]
        with tempfile.TemporaryDirectory(prefix="ss-keepalive-") as directory:
            source = Path(directory) / "KeepaliveRegression.swift"
            binary = Path(directory) / "KeepaliveRegression"
            source.write_text(harness, encoding="utf-8")
            command = [SWIFTC, "-swift-version", "5", "-parse-as-library"]
            result = subprocess.run(command + [str(p) for p in sources] + [str(source), "-o", str(binary)], capture_output=True, text=True, timeout=120)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
