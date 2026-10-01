"""Run the production App Group mapping method with Swift test doubles.

Requires swiftc (macOS, Linux, or Windows). No Apple account or device is used.
"""

from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
OPERATION = ROOT / "SideStore/Core/Operations/PipelineOperations/FetchProvisioningProfilesOperation.swift"
SWIFTC = shutil.which("swiftc")

HARNESS = r'''
import Foundation

struct ALTAppID { let bundleIdentifier: String }
struct ALTApplication { let bundleIdentifier: String }
struct ALTTeam { let identifier: String }
struct UserDefaults {
    static var standard = UserDefaults()
    var autoFixAppGroupIDs = false
}
extension Bundle {
    static let baseAltStoreAppGroupID = "group.com.SideStore.SideStore"
}
enum GroupDecision {
    case correctAndProceed(String)
    case keepOriginal(String)
}
final class CustomizationHandler {
    var correct = false
    var lastOriginalGroup: String?
    func resolveAppGroupMismatch(originalGroup: String, correctedGroup: String) async throws -> GroupDecision {
        lastOriginalGroup = originalGroup
        return correct ? .correctAndProceed(correctedGroup) : .keepOriginal(originalGroup)
    }
}
final class Handler { let userCustomizationHandler = CustomizationHandler() }
final class Context {
    var targetBundleIdentifier = "com.kdt.LiveContainer2"
    let handler = Handler()
}
final class FetchProvisioningProfilesOperation {
    let context = Context()
// PRODUCTION_METHOD
}

func expect(_ actual: String, _ expected: String, _ label: String) {
    precondition(actual == expected, "\(label): expected \(expected), got \(actual)")
}

@main
struct RegressionMain {
    static func main() async throws {
        let operation = FetchProvisioningProfilesOperation()
        let team = ALTTeam(identifier: "ABCDE12345")
        let app = ALTApplication(bundleIdentifier: "com.kdt.LiveContainer2")
        let appID = ALTAppID(bundleIdentifier: "com.kdt.LiveContainer2.ABCDE12345")
        let base = "group.com.SideStore.SideStore"
        let shared = base + ".ABCDE12345"
        let cases: [(String, String)] = [
            (base, shared),
            (shared, shared),
            (shared + ".ABCDE12345", shared),
            (shared + ".ABCDE12345.ABCDE12345", shared),
            ("group.com.example.cache", "group.com.example.cache.ABCDE12345"),
            ("group.com.example.cache.ABCDE12345", "group.com.example.cache.ABCDE12345"),
            ("group.com.example.ABCDE12345.cache", "group.com.example.ABCDE12345.cache.ABCDE12345"),
            (base + ".OTHER12345", base + ".OTHER12345.ABCDE12345"),
            (base + ".ABCDE12345extra", base + ".ABCDE12345extra.ABCDE12345"),
            ("com.example.shared", "com.example.shared.ABCDE12345")
        ]
        for (input, expected) in cases {
            let actual = try await operation.adjustedGroupIdentifier(for: input, appID: appID, targetAppBundle: app, team: team)
            expect(actual, expected, input)
        }

        // Model installing LC2, caching its signed groups, and repeatedly resigning it.
        var cachedGroup = base
        for attempt in 1...10 {
            cachedGroup = try await operation.adjustedGroupIdentifier(for: cachedGroup, appID: appID, targetAppBundle: app, team: team)
            expect(cachedGroup, shared, "install/resign round \(attempt)")
        }

        // Existing case-mismatch decisions must still work in both UI modes.
        let caseGroup = "group.com.kdt.livecontainer2"
        let customization = operation.context.handler.userCustomizationHandler
        let kept = try await operation.adjustedGroupIdentifier(for: caseGroup, appID: appID, targetAppBundle: app, team: team)
        expect(kept, caseGroup + ".ABCDE12345", "keep original spelling")
        expect(customization.lastOriginalGroup ?? "", kept, "prompt group")
        customization.correct = true
        let corrected = try await operation.adjustedGroupIdentifier(for: caseGroup, appID: appID, targetAppBundle: app, team: team)
        expect(corrected, "group." + appID.bundleIdentifier, "correct spelling")
        UserDefaults.standard.autoFixAppGroupIDs = true
        let automatic = try await operation.adjustedGroupIdentifier(for: caseGroup, appID: appID, targetAppBundle: app, team: team)
        expect(automatic, "group." + appID.bundleIdentifier, "automatic spelling correction")
        print("App Group signing regressions passed")
    }
}
'''


@unittest.skipUnless(SWIFTC, "swiftc is required to execute the production Swift method")
class AppGroupSigningTests(unittest.TestCase):
    def run_regressions(self, debug):
        source = OPERATION.read_text(encoding="utf-8")
        match = re.search(
            r"^    func adjustedGroupIdentifier\([^\n]+\n.*?^    }",
            source,
            re.MULTILINE | re.DOTALL,
        )
        self.assertIsNotNone(match, "Production App Group mapping method was not found")
        harness = HARNESS.replace("// PRODUCTION_METHOD", match.group(0))
        with tempfile.TemporaryDirectory(prefix="lc-app-groups-") as directory:
            test_source = Path(directory) / "AppGroupSigningRegression.swift"
            executable = Path(directory) / "AppGroupSigningRegression.exe"
            test_source.write_text(harness, encoding="utf-8")
            command = [SWIFTC, "-swift-version", "5", "-parse-as-library"]
            if debug:
                command += ["-D", "DEBUG"]
            result = subprocess.run(command + [str(test_source), "-o", str(executable)], capture_output=True, text=True, timeout=120)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            result = subprocess.run([str(executable)], capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_release_app_group_mapping(self):
        self.run_regressions(debug=False)

    def test_debug_app_group_mapping(self):
        self.run_regressions(debug=True)


if __name__ == "__main__":
    unittest.main()
