"""Exercise capability requests and strict response handling without Apple credentials."""

from pathlib import Path
import importlib.util
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import shutil
import subprocess
import tempfile
import threading
import unittest


ROOT = Path(__file__).resolve().parents[2]
DEPENDENCY = ROOT / "Dependencies/SideSign"
PATCH = ROOT / "scripts/patches/sidesign-capabilities.patch"
SWIFTC = shutil.which("swiftc")
FIXTURES = Path(__file__).parent / "fixtures"
spec = importlib.util.spec_from_file_location("memory_fixture", Path(__file__).with_name("test_memory_entitlements.py"))
memory_fixture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(memory_fixture)


class CapabilityRedirectHandler(BaseHTTPRequestHandler):
    def do_PATCH(self):
        self.rfile.read(int(self.headers.get("Content-Length", "0")))
        self.server.paths.append(self.path)
        self.send_response(302)
        self.send_header("Location", f"http://localhost:{self.server.server_port}/unexpected-target")
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_GET(self):
        self.server.paths.append(self.path)
        self.send_response(500)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def log_message(self, format, *args):
        pass


class CapabilityPatchTests(unittest.TestCase):
    def test_capability_patch_applies_twice_and_composes_with_signer_fix(self):
        with tempfile.TemporaryDirectory() as directory:
            dep = memory_fixture.dependency_fixture(Path(directory), memory_fixture.original_signer())
            apply = memory_fixture.patches.apply_patch
            self.assertEqual(apply(dep, PATCH), "applied")
            capability = dep / "Sources/DeveloperPortal/Capabilities.swift"
            first = capability.read_bytes()
            self.assertEqual(apply(dep), "applied")
            self.assertEqual(apply(dep, PATCH), "already applied")
            self.assertEqual(capability.read_bytes(), first)

    def test_changed_portal_is_not_overwritten(self):
        with tempfile.TemporaryDirectory() as directory:
            dep = memory_fixture.dependency_fixture(Path(directory), memory_fixture.original_signer())
            path = dep / "Sources/DeveloperPortal/AppIDs.swift"
            before = path.read_text(encoding="utf-8").replace("for (feature, value) in appID.features", "for (feature, value) in upstreamChangedFeatures")
            path.write_text(before, encoding="utf-8", newline="\n")
            with self.assertRaisesRegex(RuntimeError, "no longer match"):
                memory_fixture.patches.apply_patch(dep, PATCH)
            self.assertEqual(path.read_text(encoding="utf-8"), before)
            self.assertFalse((dep / "Sources/DeveloperPortal/Capabilities.swift").exists())


@unittest.skipUnless(SWIFTC, "swiftc is required for production capability request regressions")
class CapabilityRequestTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.temporary.cleanup)
        directory = Path(cls.temporary.name)
        dep = memory_fixture.dependency_fixture(directory, memory_fixture.original_signer())
        memory_fixture.patches.apply_patch(dep, PATCH)
        source = (dep / "Sources/DeveloperPortal/AppIDs.swift").read_text(encoding="utf-8")
        update = memory_fixture.method(source, "func updateAppID(")
        (directory / "UpdateAppID.swift").write_text(
            "import Foundation\npublic extension DeveloperPortal {\n" + update + "\n}\n",
            encoding="utf-8",
        )
        cls.binary = directory / "capability-regression"
        command = [
            SWIFTC, "-swift-version", "6", "-parse-as-library",
            str(FIXTURES / "memory_capability_stubs.swift"),
            str(DEPENDENCY / "Sources/Models/Entitlement.swift"),
            str(dep / "Sources/Models/Feature.swift"),
            str(dep / "Sources/DeveloperPortal/Capabilities.swift"),
            str(directory / "UpdateAppID.swift"),
            str(FIXTURES / "memory_capability_main.swift"), "-o", str(cls.binary),
        ]
        result = subprocess.run(command, capture_output=True, text=True, encoding="utf-8", timeout=120)
        if result.returncode:
            raise AssertionError(result.stdout + result.stderr)

    def scenario(self, name):
        result = subprocess.run([str(self.binary), name], capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("PASS " + name, result.stdout)

    def test_normal_update_uses_v1_and_keeps_memory_out_of_legacy_request(self):
        self.scenario("request")

    def test_disabled_or_missing_request_never_enables_capability(self):
        self.scenario("disabled")

    def test_http_and_json_api_errors_are_rejected(self):
        self.scenario("responses")

    def test_failed_optional_capability_does_not_abort_ordinary_installation(self):
        self.scenario("optional")

    def test_cancelled_update_does_not_report_success(self):
        self.scenario("cancelled")

    def test_authenticated_patch_does_not_follow_a_cross_origin_redirect(self):
        server = ThreadingHTTPServer(("127.0.0.1", 0), CapabilityRedirectHandler)
        server.paths = []
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            result = subprocess.run(
                [str(self.binary), "redirect", str(server.server_port)],
                capture_output=True, text=True, timeout=30,
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual(server.paths, ["/services/v1/bundleIds/APPID12345"])
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=2)


if __name__ == "__main__":
    unittest.main()
