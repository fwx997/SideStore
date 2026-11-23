"""Exercise artifact reuse without a network or a build runner."""

from contextlib import ExitStack
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import unittest
from unittest import mock
import zipfile


SCRIPT = Path(__file__).resolve().parents[1] / "reuse_combined_artifacts.py"
SPEC = importlib.util.spec_from_file_location("reuse_combined_artifacts", SCRIPT)
REUSE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(REUSE)
SI_COMMIT = "d" * 40
OLD_SS_COMMIT = "a" * 40
NEW_SS_COMMIT = "b" * 40
SI_STEPS = {"Test SideInstaller and siboot", "Build complete SideInstaller and Minis bootstrap"}
SS_STEPS = {"Test SideStore signing, recovery, and background refresh", "Build SideStore"}


class ReuseCombinedArtifactsTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="combined-reuse-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.installer = self.root / "original-si.ipa"
        self.store = self.root / "original-ss.ipa"
        self.write_installer(SI_COMMIT)
        with zipfile.ZipFile(self.store, "w") as archive:
            archive.writestr("Payload/SideStore.app/Info.plist", plistlib.dumps({
                "CFBundleShortVersionString": "0.7.0+" + OLD_SS_COMMIT[:8],
            }))
        self.downloaded = []

    def write_installer(self, commit):
        with zipfile.ZipFile(self.installer, "w") as archive:
            archive.writestr("CertificateReuseBuild/source-commit.txt", commit)
            archive.writestr("CertificateReuseBuild/siboot-aarch64", b"verified-bootstrap-fixture")

    def run_reuse(self, rebuild=False, steps=None, git_failure=False):
        successful = SI_STEPS | SS_STEPS if steps is None else steps
        artifacts = [
            {"id": 1, "name": "SideInstaller-and-siboot"},
            {"id": 2, "name": "SideStore-original.ipa"},
        ]

        def api(path):
            if "/jobs?" in path:
                return {"jobs": [{"steps": [{"name": name, "conclusion": "success"} for name in successful]}]}
            if "/artifacts?" in path:
                return {"artifacts": artifacts}
            return {"head_sha": OLD_SS_COMMIT}

        def download(artifact, destination):
            self.downloaded.append(artifact["id"])
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(self.installer if artifact["id"] == 1 else self.store, destination)

        environment = {
            "REUSE_BUILD_RUN": "123", "GITHUB_REPOSITORY": "test/repo", "GITHUB_SHA": NEW_SS_COMMIT,
            "EXPECTED_SIDEINSTALLER": SI_COMMIT, "GITHUB_ENV": str(self.root / "github-env"),
            "REBUILD_SIDESTORE": "true" if rebuild else "false",
        }
        previous = Path.cwd()
        os.chdir(self.root)
        try:
            with ExitStack() as stack:
                stack.enter_context(mock.patch.dict(os.environ, environment))
                stack.enter_context(mock.patch.object(REUSE, "api", side_effect=api))
                stack.enter_context(mock.patch.object(REUSE, "download_artifact", side_effect=download))
                git = stack.enter_context(mock.patch.object(REUSE.subprocess, "run"))
                if git_failure:
                    git.side_effect = subprocess.CalledProcessError(1, ["git", "diff"])
                REUSE.main()
                return json.loads(Path("reused-build.json").read_text()), git.call_count
        finally:
            os.chdir(previous)

    def test_rebuild_preserves_the_new_store_and_reuses_only_installer(self):
        current_store = self.root / "SideStore.ipa"
        current_store.write_bytes(b"fresh-side-store-build")
        receipt, git_calls = self.run_reuse(rebuild=True, steps=SI_STEPS)
        self.assertEqual(self.downloaded, [1])
        self.assertEqual(current_store.read_bytes(), b"fresh-side-store-build")
        self.assertFalse((self.root / "github-env").exists())
        self.assertEqual(git_calls, 0)
        self.assertEqual(receipt["sidestore_source"], NEW_SS_COMMIT)
        self.assertEqual(receipt["mode"], "rebuild-sidestore")
        self.assertEqual(receipt["artifacts"], [1])
        copied = self.root / "SideInstaller-build/build/SideInstaller.ipa"
        self.assertEqual(copied.read_bytes(), self.installer.read_bytes())

    def test_rebuild_requires_successful_installer_rust_tests(self):
        with self.assertRaisesRegex(ValueError, "did not all pass"):
            self.run_reuse(rebuild=True, steps={"Build complete SideInstaller and Minis bootstrap"})
        self.assertEqual(self.downloaded, [])

    def test_rebuild_rejects_a_different_installer_source(self):
        self.write_installer("e" * 40)
        with self.assertRaisesRegex(ValueError, "different source revision"):
            self.run_reuse(rebuild=True)
        self.assertFalse((self.root / "reused-build.json").exists())

    def test_default_mode_keeps_both_artifact_and_source_guards(self):
        receipt, git_calls = self.run_reuse()
        self.assertEqual(self.downloaded, [1, 2])
        self.assertEqual(git_calls, 1)
        self.assertEqual(receipt["sidestore_source"], OLD_SS_COMMIT)
        self.assertIn(OLD_SS_COMMIT[:8], (self.root / "github-env").read_text())
        with self.assertRaises(subprocess.CalledProcessError):
            self.run_reuse(git_failure=True)


if __name__ == "__main__":
    unittest.main()
