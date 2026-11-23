"""Execute production distribution, certificate import, and flock helpers with synthetic data."""
from pathlib import Path
import os
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
OPERATIONS = ROOT / "SideStore/Core/Operations"
FIXTURES = Path(__file__).parent / "fixtures"
SWIFTC = shutil.which("swiftc")


def method(source, declaration):
    start = source.index(declaration)
    opening = source.index("{", start)
    depth, end = 1, opening + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end].replace("private func", "func", 1)


@unittest.skipUnless(SWIFTC, "swiftc is required for production combined-app regressions")
class CombinedDistributionTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.temporary.cleanup)
        directory = Path(cls.temporary.name)
        certificate = (ROOT / "SideStore/Core/Certificates/CertificateManager.swift").read_text(encoding="utf-8")
        extracted = "import Foundation\nextension CertificateHarness {\n"
        extracted += method(certificate, "public func getSignableCertificate(").replace("public func", "func", 1)
        extracted += "\n" + method(certificate, "private func loadEmbeddedCertificate(").replace("let targetBundle = Bundle.main", "let targetBundle = self.bundle")
        extracted += "\n}\n"
        download = (OPERATIONS / "StandaloneOperations/DownloadAppOperation.swift").read_text(encoding="utf-8")
        extracted += "extension VersionHarness {\n" + method(download, "private func verifyCombinedVersion(") + "\n}\n"
        (directory / "Extracted.swift").write_text(extracted, encoding="utf-8")
        cls.binary = directory / ("combined-tests.exe" if os.name == "nt" else "combined-tests")
        command = [SWIFTC, "-swift-version", "6", "-parse-as-library",
                   str(OPERATIONS / "CombinedAppDistribution.swift"),
                   str(OPERATIONS / "CompanionSigningLock.swift"),
                   str(directory / "Extracted.swift"),
                   str(FIXTURES / "combined_distribution_main.swift"), "-o", str(cls.binary)]
        result = subprocess.run(command, capture_output=True, text=True, timeout=120)
        if result.returncode:
            raise AssertionError(result.stdout + result.stderr)

    def scenario(self, name):
        result = subprocess.run([str(self.binary), name], capture_output=True, text=True, timeout=25)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_self_identity_and_update_never_reuse_running_payload(self): self.scenario("routing")
    def test_complete_host_and_companion_executables_are_required(self): self.scenario("package")
    def test_two_app_update_cannot_remove_sideinstaller(self): self.scenario("missing-sideinstaller")
    def test_lost_extensions_or_mismatched_versions_are_rejected(self): self.scenario("extensions")
    def test_only_https_distribution_url_is_accepted(self): self.scenario("url")
    def test_catalog_version_and_build_must_match_download(self): self.scenario("version")
    def test_cached_custom_info_cannot_replace_distribution_metadata(self): self.scenario("metadata")
    def test_background_identifiers_rebase_without_double_team_suffix(self): self.scenario("background-identifiers")
    def test_failed_or_cancelled_install_does_not_consume_bootstrap(self): self.scenario("receipt")
    def test_bootstrap_password_is_bound_to_exact_certificate_and_cleared_after_import(self): self.scenario("password")
    def test_embedded_private_key_uses_handoff_password_when_anisette_differs(self): self.scenario("certificate")
    @unittest.skipIf(os.name == "nt", "POSIX flock integration requires macOS or Linux")
    def test_nested_leases_hold_until_last_release_and_crash_releases_lock(self): self.scenario("lock")


if __name__ == "__main__":
    unittest.main()
