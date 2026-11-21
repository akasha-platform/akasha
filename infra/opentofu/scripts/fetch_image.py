"""Download a pinned VM base image to the laptop cache and check its SHA-512 (ADR-0033).

    uv run --locked python infra/opentofu/scripts/fetch_image.py debian13

Reads infra/opentofu/live/l0-host/images.json, downloads the image (Debian redirects to a
mirror) into ~/.cache/akasha/images/ and keeps it only when size and SHA-512 match the pinned
values; a mismatch deletes the download and fails. OpenTofu then uploads the checked local file
to the host. An existing file is checked again instead of being downloaded.
"""

import hashlib
import json
import os
import sys
import tempfile
import urllib.request
from pathlib import Path

PINS = Path(__file__).resolve().parent.parent / "live" / "l0-host" / "images.json"
CACHE = Path.home() / ".cache" / "akasha" / "images"
CHUNK = 1 << 20


def fail(message: str) -> None:
    print(f"fetch_image: {message}", file=sys.stderr)
    sys.exit(1)


def sha512_of(path: Path) -> str:
    digest = hashlib.sha512()
    with path.open("rb") as handle:
        while chunk := handle.read(CHUNK):
            digest.update(chunk)
    return digest.hexdigest()


def check(path: Path, pin: dict) -> bool:
    return path.stat().st_size == pin["size"] and sha512_of(path) == pin["sha512"]


def main() -> None:
    if len(sys.argv) != 2:
        fail("usage: fetch_image.py <image name from images.json>")
    pins = json.loads(PINS.read_text())
    pin = pins.get(sys.argv[1])
    if pin is None:
        fail(f"unknown image '{sys.argv[1]}'; known: {', '.join(sorted(pins))}")
    if not pin["url"].startswith("https://"):
        fail("only https:// URLs are accepted")
    CACHE.mkdir(parents=True, exist_ok=True)
    target = CACHE / pin["file"]
    if target.exists():
        if check(target, pin):
            print(f"ok: {target} matches the pinned SHA-512")
            return
        fail(f"{target} exists but does NOT match the pin; delete it and run again")
    with tempfile.NamedTemporaryFile(dir=CACHE, delete=False) as partial:
        tmp = Path(partial.name)
    try:
        print(f"downloading {pin['url']} ({pin['size']} bytes)")
        with urllib.request.urlopen(pin["url"], timeout=60) as response, tmp.open("wb") as out:
            while chunk := response.read(CHUNK):
                out.write(chunk)
        if not check(tmp, pin):
            fail("size or SHA-512 does NOT match the pin: download deleted")
        os.replace(tmp, target)
        print(f"ok: {target} matches the pinned SHA-512")
    finally:
        tmp.unlink(missing_ok=True)


if __name__ == "__main__":
    main()
