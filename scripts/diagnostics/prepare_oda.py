"""Download the same public library payload used by the app, without logging it."""
import base64
import hashlib
import io
import json
from pathlib import Path
import sys
import urllib.request
import zipfile

PAYLOAD_SHA256 = "a2f9aeef4cc31efda69ecdceeadd0f1bbd04199e6339b880636c14a3ecba2b96"


def main():
    with urllib.request.urlopen("https://zzz.haus/oda.json", timeout=30) as response:
        metadata = json.load(response)
    payload = base64.b64decode(metadata["l"], validate=True)
    # The published metadata digest is stale. Pin the inspected payload instead
    # of copying the application's behavior of accepting any digest mismatch.
    actual = hashlib.sha256(payload).hexdigest()
    assert actual == PAYLOAD_SHA256, "The ODA payload changed since this diagnostic was prepared"
    target = Path(sys.argv[1])
    target.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(io.BytesIO(payload)) as archive:
        for name in ["libCoreADI.so", "libstoreservicescore.so"]:
            (target / name).write_bytes(archive.read(name))
    print("Verified pinned ODA payload SHA-256:", actual)


if __name__ == "__main__":
    main()
