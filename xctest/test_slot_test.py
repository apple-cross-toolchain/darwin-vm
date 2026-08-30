#!/usr/bin/env python3

import hashlib
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path


_MODULE_PATH = Path(__file__).with_name("test_slot.py")
_SPEC = importlib.util.spec_from_file_location("test_slot", _MODULE_PATH)
test_slot = importlib.util.module_from_spec(_SPEC)
assert _SPEC.loader
_SPEC.loader.exec_module(test_slot)


class TestSlotTest(unittest.TestCase):
    def test_create_and_locate_version_two_manifest(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            slot = root / "slot"
            image = root / "ramdisk.dmg"
            trust_cache = root / "ramdisk.tc"
            manifest = root / "slot.json"
            ddi = root / "ddi.dmg"
            test_slot.create(slot, 4096)
            image.write_bytes(bytes(4096) + slot.read_bytes() + bytes(4096))
            trust_cache.write_bytes(b"trust")
            ddi.write_bytes(b"ddi")

            test_slot.locate(
                image,
                slot,
                manifest,
                "/AppleInternal/Test.xctest/Test",
                "/AppleInternal/Test.xctest",
                "arm64",
                {"ramdisk": image, "trust_cache": trust_cache},
                {"device": "iPhone13,2"},
                {"ddi": ddi},
            )

            data = json.loads(manifest.read_text())
            self.assertEqual(data["version"], 2)
            self.assertEqual(data["offset"], 4096)
            self.assertEqual(data["architecture"], "arm64")
            self.assertEqual(
                data["input_sha256"]["ramdisk"],
                hashlib.sha256(image.read_bytes()).hexdigest(),
            )
            self.assertEqual(data["provenance"]["ddi"]["filename"], "ddi.dmg")

    def test_create_rejects_unaligned_size(self):
        with tempfile.TemporaryDirectory() as temporary:
            with self.assertRaisesRegex(SystemExit, "multiple of 4096"):
                test_slot.create(Path(temporary) / "slot", 4095)

    def test_locate_rejects_duplicate_pattern(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            slot = root / "slot"
            image = root / "image"
            test_slot.create(slot, 4096)
            image.write_bytes(slot.read_bytes() * 2)
            with self.assertRaisesRegex(SystemExit, "not unique"):
                test_slot.locate(
                    image,
                    slot,
                    root / "manifest",
                    "/Test.xctest/Test",
                    "/Test.xctest",
                    "arm64",
                    {},
                    {},
                    {},
                )

    def test_locate_rejects_unaligned_extent(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            slot = root / "slot"
            image = root / "image"
            test_slot.create(slot, 4096)
            image.write_bytes(b"x" + slot.read_bytes())
            with self.assertRaisesRegex(SystemExit, "not block-aligned"):
                test_slot.locate(
                    image,
                    slot,
                    root / "manifest",
                    "/Test.xctest/Test",
                    "/Test.xctest",
                    "arm64",
                    {},
                    {},
                    {},
                )


if __name__ == "__main__":
    unittest.main()
