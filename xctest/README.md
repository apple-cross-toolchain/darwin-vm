# Preparing an XCTest ramdisk

`prepare_ramdisk.sh` creates a copy of a restore ramdisk that can run an
unhosted, device-arm64 XCTest bundle. It installs the matching XCTest runtime
from Xcode's Restore Developer Disk Image, adds a small `xctest` host and Swift
Foundation shim, and reserves a fixed-size executable slot for a test harness
to fill before boot.

The preparation step requires macOS, Xcode, and its matching Restore DDI. Base
firmware can be extracted on macOS or Linux as described by the repository's
main README and `LINUX.md`.

## Create the image

First extract firmware with `get_files.sh`. For example, the tested non-SPTM
iPhone 12 configuration is:

```sh
DEVNAME=iPhone13,2 \
URL='https://updates.cdn-apple.com/2026SpringFCS/fullrestores/122-75946/B3FDFDC5-1A50-4B12-ACA7-CB28486FB561/iPhone13,2,iPhone13,3_26.5_23F77_Restore.ipsw' \
./get_files.sh
```

Then create an XCTest-enabled copy:

```sh
./xctest/prepare_ramdisk.sh \
  --ramdisk firmware/ramdisk.dmg \
  --hashes firmware/all_hashes \
  --output-dir firmware/xctest
```

The script derives the active Restore DDI from
`/Library/Developer/DeveloperDiskImages/iOS_DDI/Restore/BuildManifest.plist`.
Pass `--ddi` to select another image explicitly. It refuses to overwrite an
existing output directory and accepts `--slot-size` when the default 4 MiB
test slot is not appropriate.

The output directory contains:

- `ramdisk.dmg`: the prepared APFS image;
- `ramdisk.tc`: a base trust cache containing the installed XCTest runtime;
- `slot.json`: the raw slot offset and size, placeholder digest, guest paths,
  input hashes, and DDI/Xcode/SDK provenance.

The manifest also binds `bootkc`, `dtree`, and optional SPTM/TXM inputs, so a
consumer can reject a mixed firmware set before boot.

## Running a test

A test harness can verify the manifest, replace the slot extent in a temporary
copy of `ramdisk.dmg` with an ad-hoc-signed arm64 XCTest bundle executable, add
its CDHash to a copy of `ramdisk.tc`, and boot the image with darwin-vm's QEMU.
The bundle and executable paths to invoke inside the guest are recorded in
`slot.json`.

The prepared image is intended for one unhosted XCTest bundle. Hosted tests,
UI tests, nested frameworks, and additional bundle resources require a more
complete guest environment.

Run the slot utility tests with:

```sh
python3 xctest/test_slot_test.py
```

Firmware is IPSW-derived and the XCTest runtime comes from Xcode. Neither is
part of this repository; follow the applicable Apple licenses when storing or
transferring generated images.
