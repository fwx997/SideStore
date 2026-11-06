"""Execute VPN preflight and transport wrappers with UIKit/device test doubles.

In particular, a background shortcut must neither open an app nor acquire a new
foreground/readiness requirement, even when the host happens to be visible.
"""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
SWIFTC = shutil.which("swiftc")


def declaration(source, signature):
    start = source.index(signature)
    end = source.index("{", start) + 1
    depth = 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end]


HARNESS = r'''
import Foundation

final class UIScene: Hashable {
    enum State { case foregroundActive, background }
    var activationState = State.foregroundActive
    static func == (lhs: UIScene, rhs: UIScene) -> Bool { lhs === rhs }
    func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
}
@MainActor final class UIApplication {
    enum State { case active, inactive, background }
    static let shared = UIApplication()
    var applicationState = State.active
    var connectedScenes: Set<UIScene> = [UIScene()]
    var opens: [URL] = []
    var acceptsURL = true
    var shouldSuspendOpen = false
    var onOpen: (() -> Void)?
    var pendingOpen: CheckedContinuation<Bool, Never>?
    func open(_ url: URL) async -> Bool {
        opens.append(url)
        if shouldSuspendOpen {
            return await withCheckedContinuation {
                pendingOpen = $0
                onOpen?()
            }
        }
        return acceptsURL
    }
}
final class ConnectionConfig {
    static let shared = ConnectionConfig()
    var useLocalVPN = true
    var overrideTunnelPeerIp = ""
}
struct Interface { let name: String; let ip: String }
final class FakeNetwork { var activeInterfaces: [Interface] = [] }
final class FakeCore {
    var calls = 0
    var networkChecks: [Bool] = []
    var readiness: Result<Bool, MinimuxerError> = .success(true)
    func isReady(withNetworkCheck: Bool) async -> Result<Bool, MinimuxerError> {
        calls += 1
        networkChecks.append(withNetworkCheck)
        return readiness
    }
}
final class FakeMinimuxer {
    let network = FakeNetwork()
    let core = FakeCore()
}
let minimuxer = FakeMinimuxer()
final class CellularRefreshManager {
    static let shared = CellularRefreshManager()
    var isEnabled = false
}
extension UserDefaults {
    var enableEMPforWireguard: Bool { bool(forKey: "test.wireguard") }
}
enum MinimuxerError: Error {
    case noVPN
    var asOperationError: OperationError { .noVPN(reason: "Low-level technical detail") }
}
enum TransportFailure: Error { case RwAfc, pairing }
func debugLog(_ message: String) {}
func withRemotePairingRetry<T>(_ operation: () async throws -> T) async throws -> T {
    try await operation()
}
struct AppOperation {}
protocol PipelineExecutionHandler { var allowsVPNAppHandoff: Bool { get } }
class UIViewController { var presentedViewController: UIViewController? }
final class ResignAltStoreViewController: UIViewController {}
typealias PresenterProvider = () -> UIViewController?
final class PipelineHandler: PipelineExecutionHandler {
    let isResignActive: Bool
    let allowsVPNAppHandoff: Bool
    private let presenterProvider: PresenterProvider?
    // PRODUCTION_HANDLER_INIT
}
final class AppManager {
    // PRODUCTION_HANDLER_FACTORY
}
final class RefreshGroup { var completed = false }
final class PipelineRunner {
    // PRODUCTION_PIPELINE_ENTRY
    private func performOperations(_ operations: [AppOperation], handler: PipelineExecutionHandler,
                                   group: RefreshGroup) async throws -> RefreshGroup {
        try await ensureMinimuxerReady()
        group.completed = true
        return group
    }
}

@main struct VPNRegression {
    @MainActor static func main() async throws {
        let defaults = UserDefaults.standard
        let keys = [VPNAppPreferences.autoOpenKey, VPNAppPreferences.destinationKey,
                    VPNAppPreferences.shortcutNameKey, VPNAppPreferences.customURLKey, "test.wireguard"]
        keys.forEach { defaults.removeObject(forKey: $0) }
        defer { keys.forEach { defaults.removeObject(forKey: $0) } }
        try preferences()
        detection()
        try await backgroundRefreshIsUnchanged()
        try await manualPreflight()
        try await sameOperationOpensOnce()
        try await overlappingOpenRequests()
        try await transportFailures()
        try await cancellation()
        print("PASS: preferences, VPN detection, foreground handoff, and unchanged background shortcut flow")
    }

    static func preferences() throws {
        let defaults = UserDefaults.standard
        precondition(VPNAppPreferences.automaticallyOpens())
        precondition(VPNAppPreferences.launchURL()?.absoluteString == "localdevvpn://")
        defaults.set(false, forKey: VPNAppPreferences.autoOpenKey)
        precondition(!VPNAppPreferences.automaticallyOpens())
        defaults.removeObject(forKey: VPNAppPreferences.autoOpenKey)
        defaults.set(VPNAppDestination.shortcut.rawValue, forKey: VPNAppPreferences.destinationKey)
        defaults.set("VPN & 手机 #1?", forKey: VPNAppPreferences.shortcutNameKey)
        let url = VPNAppPreferences.launchURL()!
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        precondition(url.scheme == "shortcuts" && items.count == 1 && items[0].value == "VPN & 手机 #1?")
        defaults.set(" \n ", forKey: VPNAppPreferences.shortcutNameKey)
        precondition(VPNAppPreferences.launchURL() == nil)
        defaults.set(VPNAppDestination.customURL.rawValue, forKey: VPNAppPreferences.destinationKey)
        defaults.set("localdevvpn://enable", forKey: VPNAppPreferences.customURLKey)
        precondition(VPNAppPreferences.launchURL()?.host == "enable")
        precondition(VPNAppPreferences.customLaunchURL("https://example.org") == nil)
        precondition(VPNAppPreferences.customLaunchURL("file:///private/test") == nil)
        precondition(VPNAppPreferences.customLaunchURL("invalid scheme://") == nil)
        defaults.removeObject(forKey: VPNAppPreferences.destinationKey)
    }

    @MainActor static func detection() {
        minimuxer.network.activeInterfaces = [.init(name: "en0", ip: "192.168.1.2"),
                                             .init(name: "utun0", ip: "fe80::1")]
        precondition(VPNAppManager.isLocalVPNMissing)
        minimuxer.network.activeInterfaces.append(.init(name: "utun6", ip: "10.7.0.2"))
        precondition(!VPNAppManager.isLocalVPNMissing)
        precondition(LocalVPNDetection.isTunnel(name: "ipsec0", address: "10.10.0.2", allowIPv6: false))
        precondition(!LocalVPNDetection.isTunnel(name: "utun0", address: "fe80::1", allowIPv6: true))
        precondition(LocalVPNDetection.isTunnel(name: "utun0", address: "fd00::2", allowIPv6: true))
        ConnectionConfig.shared.useLocalVPN = false
        minimuxer.network.activeInterfaces = []
        precondition(!VPNAppManager.isLocalVPNMissing)
        ConnectionConfig.shared.useLocalVPN = true
    }

    @MainActor static func backgroundRefreshIsUnchanged() async throws {
        let runner = PipelineRunner()
        let handler = AppManager().makePipelineHandler(presentingViewController: nil)
        precondition(!handler.allowsVPNAppHandoff)
        // UIKit visibility alone never makes a Shortcut interactive.
        for state in [UIApplication.State.active, .inactive, .background] {
            UIApplication.shared.applicationState = state
            for cellular in [true, false] {
                CellularRefreshManager.shared.isEnabled = cellular
                minimuxer.network.activeInterfaces = []
                let calls = minimuxer.core.calls
                let group = try await runner.perform([AppOperation()], handler: handler, group: RefreshGroup())
                precondition(group.completed)
                precondition(minimuxer.core.calls == calls + (cellular ? 0 : 1))
                precondition(UIApplication.shared.opens.isEmpty)
            }
        }
        CellularRefreshManager.shared.isEnabled = false
        minimuxer.core.readiness = .failure(.noVPN)
        do {
            _ = try await runner.perform([AppOperation()], handler: handler, group: RefreshGroup())
            preconditionFailure("A background failure must still propagate")
        } catch OperationError.noVPN { }
        precondition(UIApplication.shared.opens.isEmpty)
        minimuxer.core.readiness = .success(true)
        precondition(!VPNOperationContext.isInteractive)
    }

    @MainActor static func manualPreflight() async throws {
        let runner = PipelineRunner()
        let presenter = UIViewController()
        let handler = AppManager().makePipelineHandler(presentingViewController: presenter)
        precondition(handler.allowsVPNAppHandoff)
        // A manual request that has already moved to the background cannot launch.
        UIApplication.shared.applicationState = .background
        do { _ = try await runner.perform([], handler: handler, group: RefreshGroup()) }
        catch OperationError.noVPN { }
        precondition(UIApplication.shared.opens.isEmpty)
        UIApplication.shared.applicationState = .active
        UserDefaults.standard.set(false, forKey: VPNAppPreferences.autoOpenKey)
        do { _ = try await runner.perform([], handler: handler, group: RefreshGroup()) }
        catch OperationError.noVPN { }
        precondition(UIApplication.shared.opens.isEmpty)
        UserDefaults.standard.removeObject(forKey: VPNAppPreferences.autoOpenKey)
        // Required even when cellular refresh deliberately bypasses readiness.
        CellularRefreshManager.shared.isEnabled = true
        do {
            _ = try await runner.perform([], handler: handler, group: RefreshGroup())
            preconditionFailure("Missing VPN must stop before signing/transfer")
        } catch let error as OperationError {
            guard case .noVPN = error else { throw error }
            precondition(!error.rawDescription.contains("RwAfc"))
            precondition(error.rawDescription.contains("VPN is not connected"))
        }
        precondition(UIApplication.shared.opens.count == 1)
        precondition(UIApplication.shared.opens[0].scheme == "localdevvpn")
        // Return without enabling the VPN and immediately click again. A new
        // manual request must open the app without waiting for a wall-clock gate.
        UIApplication.shared.applicationState = .background
        UIApplication.shared.applicationState = .active
        do { _ = try await runner.perform([], handler: handler, group: RefreshGroup()) }
        catch OperationError.noVPN { }
        precondition(UIApplication.shared.opens.count == 2, "A new manual request must reopen immediately")
        precondition(!VPNOperationContext.isInteractive)
        minimuxer.network.activeInterfaces = [.init(name: "utun6", ip: "10.7.0.2")]
        let group = try await runner.perform([], handler: handler, group: RefreshGroup())
        precondition(group.completed && UIApplication.shared.opens.count == 2)
        ConnectionConfig.shared.useLocalVPN = false
        minimuxer.network.activeInterfaces = []
        let remote = try await runner.perform([], handler: handler, group: RefreshGroup())
        precondition(remote.completed && UIApplication.shared.opens.count == 2)
        ConnectionConfig.shared.useLocalVPN = true
        CellularRefreshManager.shared.isEnabled = false
        UserDefaults.standard.set(VPNAppDestination.customURL.rawValue, forKey: VPNAppPreferences.destinationKey)
        UserDefaults.standard.set("", forKey: VPNAppPreferences.customURLKey)
        let invalidOpened = await VPNAppManager.openSelectedApp()
        precondition(!invalidOpened && UIApplication.shared.opens.count == 2)
        UserDefaults.standard.removeObject(forKey: VPNAppPreferences.destinationKey)
        UIApplication.shared.acceptsURL = false
        let rejected = await VPNAppManager.openSelectedApp()
        precondition(!rejected)
        UIApplication.shared.acceptsURL = true
    }

    @MainActor static func expectMissingVPN() async throws {
        do {
            try await VPNAppManager.requireVPN()
            preconditionFailure("Expected missing VPN")
        } catch OperationError.noVPN { }
    }

    @MainActor static func sameOperationOpensOnce() async throws {
        let opens = UIApplication.shared.opens.count
        minimuxer.network.activeInterfaces = []
        try await VPNOperationContext.withOperation(isInteractive: true) {
            try await concurrentVPNChecks()
            UIApplication.shared.applicationState = .background
            UIApplication.shared.applicationState = .active
            try await expectMissingVPN()
            precondition(UIApplication.shared.opens.count == opens + 1, "One operation must not reopen after returning")
            // A nested background invocation must not inherit launch permission.
            try await VPNOperationContext.withOperation(isInteractive: false) {
                try await VPNAppManager.requireVPN()
                precondition(!VPNOperationContext.isInteractive)
            }
        }
        precondition(!VPNOperationContext.isInteractive)
        try await VPNOperationContext.withOperation(isInteractive: true) { try await expectMissingVPN() }
        precondition(UIApplication.shared.opens.count == opens + 2)
        UIApplication.shared.acceptsURL = false
        try await VPNOperationContext.withOperation(isInteractive: true) { try await expectMissingVPN() }
        UIApplication.shared.acceptsURL = true
        try await VPNOperationContext.withOperation(isInteractive: true) { try await expectMissingVPN() }
        precondition(UIApplication.shared.opens.count == opens + 4, "A rejected launch must not block the next request")
    }

    static func concurrentVPNChecks() async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<8 { group.addTask { try await expectMissingVPN() } }
            try await group.waitForAll()
        }
    }

    @MainActor static func overlappingOpenRequests() async throws {
        let app = UIApplication.shared
        let opens = app.opens.count
        let (events, signal) = AsyncStream<Void>.makeStream()
        var started = events.makeAsyncIterator()
        app.shouldSuspendOpen = true
        app.onOpen = { signal.yield(()) }
        let first = Task {
            try await VPNOperationContext.withOperation(isInteractive: true) { try await expectMissingVPN() }
        }
        _ = await started.next()
        try await VPNOperationContext.withOperation(isInteractive: true) { try await expectMissingVPN() }
        precondition(app.opens.count == opens + 1, "In-flight launches must remain serialized")
        app.pendingOpen?.resume(returning: true)
        app.pendingOpen = nil
        app.shouldSuspendOpen = false
        app.onOpen = nil
        signal.finish()
        try await first.value
        try await VPNOperationContext.withOperation(isInteractive: true) { try await expectMissingVPN() }
        precondition(app.opens.count == opens + 2, "Completing a launch must immediately allow a new request")
    }

    @MainActor static func transportFailures() async throws {
        let opens = UIApplication.shared.opens.count
        // Successful background transfers keep working, without a new preflight.
        let result = try await withDeviceConnection { 42 }
        precondition(result == 42)
        do {
            _ = try await withDeviceConnection { throw TransportFailure.RwAfc }
            preconditionFailure("Expected missing VPN")
        } catch OperationError.noVPN { }
        minimuxer.network.activeInterfaces = [.init(name: "utun6", ip: "10.7.0.2")]
        do {
            _ = try await withDeviceConnection { throw TransportFailure.RwAfc }
            preconditionFailure("Expected device transfer error")
        } catch OperationError.deviceConnectionFailed { }
        do { _ = try await withDeviceConnection { throw TransportFailure.pairing } }
        catch TransportFailure.pairing { }
        // Drop the tunnel during an interactive operation: report failure, never
        // leave cellular restoration to open another app midway through transfer.
        try await VPNOperationContext.withOperation(isInteractive: true) {
            do {
                _ = try await withDeviceConnection {
                    minimuxer.network.activeInterfaces = []
                    throw TransportFailure.RwAfc
                }
                preconditionFailure("Expected disconnect failure")
            } catch OperationError.noVPN { }
        }
        precondition(UIApplication.shared.opens.count == opens)
    }

    @MainActor static func cancellation() async throws {
        let opens = UIApplication.shared.opens.count
        do { _ = try await withDeviceConnection { throw CancellationError() } }
        catch is CancellationError { }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await VPNOperationContext.withOperation(isInteractive: true) {
                try await VPNAppManager.requireVPN()
            }
        }
        do { try await task.value; preconditionFailure("Expected cancellation") }
        catch is CancellationError { }
        precondition(UIApplication.shared.opens.count == opens)
    }
}
'''


def production_source():
    device = ROOT / "SideStore/Core/DeviceApi"
    wrapper = (device / "MinimuxerWrapper.swift").read_text(encoding="utf-8")
    runner = (ROOT / "SideStore/Core/Operations/PipelineRunner.swift").read_text(encoding="utf-8")
    harness = HARNESS.replace("// PRODUCTION_PIPELINE_ENTRY", declaration(runner, "func perform(_ operations:"))
    factory = (ROOT / "AltStore/Managing Apps/AppManager.swift").read_text(encoding="utf-8")
    handler = (ROOT / "SideStore/Handlers/PipelineHandler.swift").read_text(encoding="utf-8")
    harness = harness.replace("// PRODUCTION_HANDLER_INIT", declaration(handler, "init("))
    harness = harness.replace("// PRODUCTION_HANDLER_FACTORY", declaration(factory, "private func makePipelineHandler(").replace("private func", "func"))
    pieces = [harness, (device / "VPNAppPreferences.swift").read_text(encoding="utf-8"),
              (device / "VPNAppManager.swift").read_text(encoding="utf-8").replace("import UIKit", ""),
              (ROOT / "SideStore/Core/Operations/Errors/OperationError.swift").read_text(encoding="utf-8")]
    for signature in ("public func isMinimuxerReady()", "public func ensureMinimuxerReady()", "private func withDeviceConnection<T>"):
        pieces.append(declaration(wrapper, signature).replace("public func", "func"))
    return "\n".join(pieces)


@unittest.skipUnless(SWIFTC, "swiftc is required to execute VPN and background regression checks")
class VPNHandoffTests(unittest.TestCase):
    def test_foreground_handoff_preserves_background_shortcuts(self):
        with tempfile.TemporaryDirectory(prefix="ss-vpn-") as directory:
            source = Path(directory) / "VPNRegression.swift"
            binary = Path(directory) / "VPNRegression"
            source.write_text(production_source(), encoding="utf-8")
            result = subprocess.run([SWIFTC, "-swift-version", "5", "-parse-as-library", str(source), "-o", str(binary)],
                                    capture_output=True, text=True, timeout=120)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
