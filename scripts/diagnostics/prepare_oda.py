"""Download the same public library payload used by the app, without logging it."""
import base64
import hashlib
import io
import json
from pathlib import Path
import sys
import urllib.request
import zipfile


def main():
    with urllib.request.urlopen("https://zzz.haus/oda.json", timeout=30) as response:
        metadata = json.load(response)
    payload = base64.b64decode(metadata["l"], validate=True)
    assert hashlib.sha256(payload).hexdigest() == metadata["s"]
    target = Path(sys.argv[1])
    target.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(io.BytesIO(payload)) as archive:
        for name in ["libCoreADI.so", "libstoreservicescore.so"]:
            (target / name).write_bytes(archive.read(name))
    print("Verified ODA payload SHA-256:", metadata["s"])


if __name__ == "__main__":
    main()
