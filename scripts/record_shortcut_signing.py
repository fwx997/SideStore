"""Keep optional Shortcuts signing failures explicit in the delivered receipt."""

import argparse
import hashlib
import json
from pathlib import Path


def record(root, outcome):
    unsigned = root / "unsigned"
    entries = json.loads((unsigned / "receipt.json").read_text(encoding="utf-8"))
    signed = root / "signed"
    receipts = []
    for entry in entries:
        name = entry["filename"]
        if Path(name).name != name or not name.endswith(".shortcut"):
            raise ValueError("Unexpected shortcut filename")
        source = unsigned / name
        if hashlib.sha256(source.read_bytes()).hexdigest() != entry["unsigned_sha256"]:
            raise ValueError("The prepared shortcut changed before signing")
        destination = signed / name
        available = outcome == "success" and destination.is_file() and destination.stat().st_size > 0
        result = dict(entry, importable=available, signing_status="signed" if available else "unavailable")
        if available:
            result["signed_sha256"] = hashlib.sha256(destination.read_bytes()).hexdigest()
        else:
            destination.unlink(missing_ok=True)
            result["reason"] = "macOS Shortcuts signing did not finish; use the manual editing instructions. iCloud login may be required."
        receipts.append(result)
    receipt = {"signing_outcome": outcome, "shortcuts": receipts,
               "all_importable": bool(receipts) and all(item["importable"] for item in receipts)}
    (root / "receipt.json").write_text(json.dumps(receipt, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    if not receipt["all_importable"]:
        print("::warning::Shortcut files remain unsigned. They are not directly importable; use manual editing instructions.")
    return receipt


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    parser.add_argument("outcome", choices=("success", "failure", "cancelled", "skipped"))
    args = parser.parse_args()
    record(args.directory, args.outcome)
