"""Exercise the production signer and SideStore routing/cache methods.

The signing backend is a test double: it records emitted XML as the executable's
signature, including an injected dropped-entitlement failure. No real Apple
credentials, device identifiers, or provisioning profiles are used.
"""

from pathlib import Path
import importlib.util
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
DEPENDENCY = ROOT / "Dependencies/SideSign"
SIGNER = "Sources/CodeSigning/CodeSignerAPI.swift"
SWIFTC = shutil.which("swiftc")
FIXTURES = Path(__file__).parent / "fixtures"
spec = importlib.util.spec_from_file_location("signing_patches", ROOT / "scripts/apply_signing_patches.py")
patches = importlib.util.module_from_spec(spec)
spec.loader.exec_module(patches)


def original_signer() -> str:
    result = subprocess.run(
        ["git", "-C", str(DEPENDENCY), "show", "HEAD:" + SIGNER],
        capture_output=True, text=True, encoding="utf-8", check=True,
    )
    return result.stdout


def dependency_fixture(directory: Path, source: str) -> Path:
    dependency = directory / "SideSign"
    signer = dependency / SIGNER
    signer.parent.mkdir(parents=True)
    signer.write_text(source, encoding="utf-8", newline="\n")
    return dependency


def method(source: str, declaration: str) -> str:
    start = source.index(declaration)
    opening = source.index("{", start)
    depth = 1
    end = opening + 1
    while depth:
        if source[end] == "{":
            depth += 1
        elif source[end] == "}":
            depth -= 1
        end += 1
    return source[start:end].replace("private func", "func", 1)


class SigningPatchTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.original = original_signer()

    def test_patch_is_idempotent(self):
        with tempfile.TemporaryDirectory() as directory:
            dependency = dependency_fixture(Path(directory), self.original)
            self.assertEqual(patches.apply_patch(dependency), "applied")
            first = (dependency / SIGNER).read_bytes()
            self.assertEqual(patches.apply_patch(dependency), "already applied")
            self.assertEqual((dependency / SIGNER).read_bytes(), first)

    def test_incompatible_dependency_is_not_overwritten(self):
        changed = self.original.replace(
            "let applicationEntitlements = app.entitlements",
            "let applicationEntitlements = changedUpstreamAPI()",
        )
        self.assertNotEqual(changed, self.original)
        with tempfile.TemporaryDirectory() as directory:
            dependency = dependency_fixture(Path(directory), changed)
            before = (dependency / SIGNER).read_bytes()
            with self.assertRaisesRegex(RuntimeError, "no longer match"):
                patches.apply_patch(dependency)
            self.assertEqual((dependency / SIGNER).read_bytes(), before)

    def test_missing_submodule_reports_required_setup(self):
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaisesRegex(RuntimeError, "Initialize"):
                patches.apply_patch(Path(directory))


@unittest.skipUnless(SWIFTC, "swiftc is required for production Swift signing regressions")
class MemorySigningTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.temporary.cleanup)
        directory = Path(cls.temporary.name)
        dependency = dependency_fixture(directory, original_signer())
        patches.apply_patch(dependency)

        signer = (dependency / SIGNER).read_text(encoding="utf-8")
        # CodeSignKit is replaced by the XML-recording backend in the fixture.
        (directory / "Signer.swift").write_text(signer.replace("import CodeSignKit\n", ""), encoding="utf-8")
        memory = dependency / "Sources/CodeSigning/MemoryEntitlements.swift"
        operation_root = ROOT / "SideStore/Core/Operations"
        operations = operation_root / "PipelineOperations"
        defaults = (operation_root / "OperationEntitlements.swift").read_text(encoding="utf-8")
        (directory / "Defaults.swift").write_text(defaults.replace("import SideSign\n", ""), encoding="utf-8")
        routing = (operations / "ResignAppOperation.swift").read_text(encoding="utf-8")
        cache = (operations / "CacheResignedMetadataOperation.swift").read_text(encoding="utf-8")
        profiles = (operations / "FetchProvisioningProfilesOperation.swift").read_text(encoding="utf-8")
        extracted = "import Foundation\nfinal class RoutingOperation {\nlet context = TestContext()\n"
        extracted += method(routing, "private func requestedEntitlements(") + "\n"
        extracted += method(routing, "private func cachedEntitlements(") + "\n}\n"
        extracted += "final class MetadataOperation {\n"
        extracted += method(cache, "private func cacheEntitlements(") + "\n"
        extracted += method(cache, "private func cleanupStaleFiles(") + "\n}\n"
        extracted += "final class FeatureOperation {\nlet context = TestContext()\n"
        extracted += "func debugLog(_ message: String) {}\nfunc verboseLog(_ message: String) {}\n"
        extracted += method(profiles, "func updateFeatures(") + "\n}\n"
        (directory / "Operations.swift").write_text(extracted, encoding="utf-8")
        cls.binary = directory / "signing-regression"
        result = subprocess.run(
            [SWIFTC, "-swift-version", "6", "-parse-as-library",
             str(FIXTURES / "memory_signing_stubs.swift"), str(memory),
             str(DEPENDENCY / "Sources/Models/Entitlement.swift"),
             str(DEPENDENCY / "Sources/Models/Feature.swift"), str(directory / "Defaults.swift"),
             str(directory / "Signer.swift"), str(directory / "Operations.swift"),
             str(FIXTURES / "memory_signing_main.swift"), "-o", str(cls.binary)],
            capture_output=True, text=True, encoding="utf-8", timeout=120,
        )
        if result.returncode:
            raise AssertionError(result.stdout + result.stderr)

    def run_scenario(self, scenario: str):
        result = subprocess.run(
            [str(self.binary), scenario], capture_output=True, text=True, timeout=30,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("PASS " + scenario, result.stdout)

    def test_original_package_and_legacy_signer_api(self):
        self.run_scenario("original")

    def test_custom_request_survives_signing_a_stripped_cached_app(self):
        self.run_scenario("cached")

    def test_disable_and_remove_override_previous_enabled_request(self):
        self.run_scenario("disabled")

    def test_main_extension_and_actual_signature_cache_are_independent(self):
        self.run_scenario("targets")

    def test_five_refreshes_preserve_selected_memory_request(self):
        self.run_scenario("refresh")

    def test_bundle_rename_and_cached_choices_route_to_correct_executable(self):
        self.run_scenario("routing")

    def test_missing_final_entitlement_fails_before_success(self):
        self.run_scenario("lost")

    def test_string_and_number_values_are_rejected_before_signing(self):
        self.run_scenario("invalid")

    def test_default_install_uses_production_boolean_defaults_and_profile_grants(self):
        self.run_scenario("defaults")

    def test_default_values_do_not_override_disabled_or_deleted_choices(self):
        self.run_scenario("default-choices")

    def test_profile_authorization_is_required_for_each_executable(self):
        self.run_scenario("profile-boundary")

    def test_refresh_removes_memory_when_profile_grant_is_lost(self):
        self.run_scenario("revoked-grant")

    def test_signer_cannot_inject_an_unapproved_memory_entitlement(self):
        self.run_scenario("injected")

    def test_profile_features_use_team_capabilities_and_main_app_choices(self):
        self.run_scenario("features")


if __name__ == "__main__":
    unittest.main()
