"""Reuse verified app builds, optionally rebuilding SideStore from current source."""

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
    rebuild_sidestore = os.environ.get("REBUILD_SIDESTORE", "false") == "true"
    run_id = os.environ["REUSE_BUILD_RUN"]
    if not run_id.isdigit():
        raise ValueError("The reused run must be a numeric Actions run ID")
    base = "/repos/" + os.environ["GITHUB_REPOSITORY"] + "/actions/runs/" + run_id
    run = api(base)
    jobs = api(base + "/jobs?per_page=100")["jobs"]
    steps = [step for job in jobs for step in job.get("steps", []) if step["conclusion"] == "success"]
    required = {"Test SideInstaller and siboot", "Build complete SideInstaller and Minis bootstrap"}
    if not rebuild_sidestore:
        required.update({"Test SideStore signing, recovery, and background refresh", "Build SideStore"})
    if not required.issubset({step["name"] for step in steps}):
        raise ValueError("The reused application builds and native regressions did not all pass")
    artifacts = api(base + "/artifacts?per_page=100")["artifacts"]
    installer = next(item for item in artifacts if item["name"] == "SideInstaller-and-siboot")
    installer_path = Path("SideInstaller-build/build/SideInstaller.ipa")
    download_artifact(installer, installer_path)
    with zipfile.ZipFile(installer_path) as archive:
        commit = archive.read("CertificateReuseBuild/source-commit.txt").decode().strip()
        if commit != os.environ["EXPECTED_SIDEINSTALLER"] or archive.testzip():
            raise ValueError("The reused installer belongs to a different source revision")
    reused_paths = [installer_path]
    reused_ids = [installer["id"]]
    if not rebuild_sidestore:
        store = next(item for item in artifacts if item["name"].startswith("SideStore-") and item["name"].endswith(".ipa"))
        store_path = Path("SideStore.ipa")
        download_artifact(store, store_path)
        version = validate_store(store_path, run["head_sha"])
        # Host-only corrections must not conceal changes to application code.
        subprocess.run(["git", "diff", "--exit-code", run["head_sha"], "HEAD", "--", "AltStore", "SideStore", "Shared",
                        "Dependencies", "Makefile", "xcconfigs", "scripts/patches", "scripts/apply_signing_patches.py"], check=True)
        with Path(os.environ["GITHUB_ENV"]).open("a") as environment:
            environment.write("SIDESTORE_VERSION=" + version + "\n")
        reused_paths.append(store_path)
        reused_ids.append(store["id"])
    receipt = {"run_id": int(run_id), "mode": "rebuild-sidestore" if rebuild_sidestore else "host-only",
               "sidestore_source": os.environ["GITHUB_SHA"] if rebuild_sidestore else run["head_sha"],
               "sideinstaller_source": commit, "verified_steps": sorted(required), "artifacts": reused_ids,
               "sha256": {str(path): hashlib.sha256(path.read_bytes()).hexdigest() for path in reused_paths}}
    Path("reused-build.json").write_text(json.dumps(receipt, indent=2))
    print("Reused verified application artifacts:", receipt["mode"], commit)


def validate_store(store_path, source_commit):
    with zipfile.ZipFile(store_path) as archive:
        if archive.testzip():
            raise ValueError("The reused SideStore IPA is corrupt")
        info = plistlib.loads(archive.read("Payload/SideStore.app/Info.plist"))
        version = info["CFBundleShortVersionString"]
        if source_commit[:8] not in version:
            raise ValueError("The SideStore source version differs from the original successful build")
    return version


if __name__ == "__main__":
    main()
