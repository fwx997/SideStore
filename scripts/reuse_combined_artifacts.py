"""Reuse successful app builds after a host-only compilation correction."""

import hashlib
import json
import os
from pathlib import Path
import plistlib
import subprocess
import urllib.request
import zipfile


def api(path):
    request = urllib.request.Request("https://api.github.com" + path, headers={
        "Authorization": "Bearer " + os.environ["GH_TOKEN"],
        "Accept": "application/vnd.github+json",
    })
    with urllib.request.urlopen(request, timeout=60) as response:
        return json.load(response)


def download_artifact(artifact, destination):
    # gh downloads artifacts without forwarding its API token to blob storage.
    temporary = Path("build/reused") / str(artifact["id"])
    temporary.mkdir(parents=True, exist_ok=True)
    subprocess.run(["gh", "run", "download", os.environ["REUSE_BUILD_RUN"], "--repo", os.environ["GITHUB_REPOSITORY"],
                    "--name", artifact["name"], "--dir", str(temporary)], check=True)
    files = list(temporary.rglob("*.ipa"))
    if len(files) != 1:
        raise ValueError("The reused artifact must contain one IPA")
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_bytes(files[0].read_bytes())


def main():
    run_id = os.environ["REUSE_BUILD_RUN"]
    if not run_id.isdigit():
        raise ValueError("The reused run must be a numeric Actions run ID")
    base = "/repos/" + os.environ["GITHUB_REPOSITORY"] + "/actions/runs/" + run_id
    run = api(base)
    jobs = api(base + "/jobs?per_page=100")["jobs"]
    steps = [step for job in jobs for step in job.get("steps", []) if step["conclusion"] == "success"]
    required = {"Test SideStore signing, recovery, and background refresh", "Test SideInstaller and siboot",
                "Build SideStore", "Build complete SideInstaller and Minis bootstrap"}
    if not required.issubset({step["name"] for step in steps}):
        raise ValueError("The reused application builds and native regressions did not all pass")
    artifacts = api(base + "/artifacts?per_page=100")["artifacts"]
    installer = next(item for item in artifacts if item["name"] == "SideInstaller-and-siboot")
    store = next(item for item in artifacts if item["name"].startswith("SideStore-") and item["name"].endswith(".ipa"))
    installer_path = Path("SideInstaller-build/build/SideInstaller.ipa")
    store_path = Path("SideStore.ipa")
    download_artifact(installer, installer_path)
    download_artifact(store, store_path)
    with zipfile.ZipFile(installer_path) as archive:
        commit = archive.read("CertificateReuseBuild/source-commit.txt").decode().strip()
        if commit != os.environ["EXPECTED_SIDEINSTALLER"] or archive.testzip():
            raise ValueError("The reused installer belongs to a different source revision")
    with zipfile.ZipFile(store_path) as archive:
        if archive.testzip():
            raise ValueError("The reused SideStore IPA is corrupt")
        info = plistlib.loads(archive.read("Payload/SideStore.app/Info.plist"))
        version = info["CFBundleShortVersionString"]
        if run["head_sha"][:8] not in version:
            raise ValueError("The SideStore source version differs from the original successful build")
    # This workflow-only correction must not conceal changes to application code.
    subprocess.run(["git", "diff", "--exit-code", run["head_sha"], "HEAD", "--", "AltStore", "SideStore", "Shared",
                    "Dependencies", "Makefile", "xcconfigs", "scripts/patches", "scripts/apply_signing_patches.py"], check=True)
    with Path(os.environ["GITHUB_ENV"]).open("a") as environment:
        environment.write("SIDESTORE_VERSION=" + version + "\n")
    receipt = {"run_id": int(run_id), "sidestore_source": run["head_sha"], "sideinstaller_source": commit,
               "verified_steps": sorted(required), "artifacts": [store["id"], installer["id"]],
               "sha256": {str(path): hashlib.sha256(path.read_bytes()).hexdigest() for path in (store_path, installer_path)}}
    Path("reused-build.json").write_text(json.dumps(receipt, indent=2))
    print("Reused successful application builds:", version, commit)


if __name__ == "__main__":
    main()
