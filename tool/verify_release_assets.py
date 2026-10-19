"""Confirm the draft contains every complete package before making it public."""

import hashlib
import json
from pathlib import Path
import sys


def main():
    directory = Path(sys.argv[1])
    release = json.loads(Path(sys.argv[2]).read_text(encoding="utf-8"))
    expected = {
        "Monogatari-Android-arm64.apk",
        "Monogatari-Android-armv7.apk",
        "Monogatari-Android-x64.apk",
        "Monogatari-Android.aab",
        "Monogatari-Windows-x64.zip",
        "Monogatari-iOS-unsigned.ipa",
        "SHA256SUMS.txt",
    }
    assets = {asset["name"]: asset for asset in release["assets"]}
    for name in sorted(expected):
        file = directory / name
        asset = assets.get(name)
        if asset is None or asset.get("state") != "uploaded":
            raise ValueError(f"Release is missing a completed asset: {name}")
        if file.stat().st_size != asset["size"] or asset["size"] <= 0:
            raise ValueError(f"Uploaded size differs: {name}")
        with file.open("rb") as stream:
            digest = "sha256:" + hashlib.file_digest(stream, "sha256").hexdigest()
        if asset.get("digest") and asset["digest"] != digest:
            raise ValueError(f"Uploaded checksum differs: {name}")
    print(f"Verified {len(expected)} complete release assets.")


if __name__ == "__main__":
    main()
