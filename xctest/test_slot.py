#!/usr/bin/env python3
"""Creates and locates the fixed APFS test-executable slot."""

import argparse
import hashlib
import json
import mmap
from pathlib import Path


_BLOCK_SIZE = 4096
_SEED = b"darwin-vm-xctest-slot-v1"


def create(output: Path, size: int) -> None:
    if size <= 0 or size % _BLOCK_SIZE:
        raise SystemExit(f"slot size must be a positive multiple of {_BLOCK_SIZE}")
    with output.open("wb") as slot:
        for block in range(size // _BLOCK_SIZE):
            digest = hashlib.sha256(_SEED + block.to_bytes(8, "little")).digest()
            slot.write((digest * (_BLOCK_SIZE // len(digest)))[:_BLOCK_SIZE])


def locate(
    image_path: Path,
    slot_path: Path,
    manifest_path: Path,
    guest_path: str,
    bundle_path: str,
    architecture: str,
    input_paths: dict[str, Path],
    provenance: dict[str, str],
    provenance_files: dict[str, Path],
) -> None:
    slot = slot_path.read_bytes()
    with image_path.open("rb") as image_file:
        with mmap.mmap(image_file.fileno(), 0, access=mmap.ACCESS_READ) as image:
            offset = image.find(slot)
            if offset < 0:
                raise SystemExit(
                    "test slot is fragmented or missing from the APFS image; "
                    "retry with a smaller --slot-size",
                )
            if image.find(slot, offset + 1) >= 0:
                raise SystemExit("test slot pattern is not unique")
    if offset % _BLOCK_SIZE:
        raise SystemExit("test slot extent is not block-aligned")

    file_provenance = {
        name: {
            "filename": path.name,
            "sha256": _sha256(path),
        }
        for name, path in sorted(provenance_files.items())
    }
    manifest = {
        "architecture": architecture,
        "bundle_path": bundle_path,
        "guest_path": guest_path,
        "input_sha256": {
            name: _sha256(path)
            for name, path in sorted(input_paths.items())
        },
        "offset": offset,
        "placeholder_sha256": hashlib.sha256(slot).hexdigest(),
        "provenance": {
            **dict(sorted(provenance.items())),
            **file_provenance,
        },
        "size": len(slot),
        "version": 2,
    }
    manifest_path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as input_file:
        for chunk in iter(lambda: input_file.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _key_value(value: str, value_type: type = str) -> tuple[str, object]:
    key, separator, content = value.partition("=")
    if not separator or not key or not content:
        raise argparse.ArgumentTypeError("expected NAME=VALUE")
    return key, value_type(content)


def main() -> None:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)

    create_parser = subparsers.add_parser("create")
    create_parser.add_argument("--output", type=Path, required=True)
    create_parser.add_argument("--size", type=int, required=True)

    locate_parser = subparsers.add_parser("locate")
    locate_parser.add_argument("--image", type=Path, required=True)
    locate_parser.add_argument("--slot", type=Path, required=True)
    locate_parser.add_argument("--manifest", type=Path, required=True)
    locate_parser.add_argument("--guest-path", required=True)
    locate_parser.add_argument("--bundle-path", required=True)
    locate_parser.add_argument("--architecture", choices=("arm64",), required=True)
    locate_parser.add_argument("--input", action="append", default=[], type=lambda value: _key_value(value, Path))
    locate_parser.add_argument("--provenance", action="append", default=[], type=_key_value)
    locate_parser.add_argument(
        "--provenance-file",
        action="append",
        default=[],
        type=lambda value: _key_value(value, Path),
    )

    args = parser.parse_args()
    if args.command == "create":
        create(args.output, args.size)
    else:
        locate(
            args.image,
            args.slot,
            args.manifest,
            args.guest_path,
            args.bundle_path,
            args.architecture,
            dict(args.input),
            dict(args.provenance),
            dict(args.provenance_file),
        )


if __name__ == "__main__":
    main()
