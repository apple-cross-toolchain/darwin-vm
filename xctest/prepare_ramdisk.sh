#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd -P)"

RAMDISK=""
HASHES=""
OUTPUT_DIR=""
DDI=""
BOOTKC=""
DEVICE_TREE=""
SPTM=""
TXM=""
SLOT_SIZE=$((4 * 1024 * 1024))

usage() {
    cat <<'EOF'
usage: prepare_ramdisk.sh \
  --ramdisk firmware/ramdisk.dmg \
  --hashes firmware/all_hashes \
  --output-dir firmware/xctest \
  [--ddi /path/to/iOS_DDI/Restore/image.dmg] \
  [--bootkc firmware/bootkc] \
  [--device-tree firmware/dtree] \
  [--sptm firmware/sptm --txm firmware/txm] \
  [--slot-size bytes]

Creates:
  <output-dir>/ramdisk.dmg  XCTest-enabled ramdisk with a fixed test slot
  <output-dir>/ramdisk.tc   base trust cache including the XCTest runtime
  <output-dir>/slot.json    slot location, input hashes, and provenance
EOF
}

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --ramdisk)
            RAMDISK="$2"
            shift 2
            ;;
        --hashes)
            HASHES="$2"
            shift 2
            ;;
        --output-dir)
            OUTPUT_DIR="$2"
            shift 2
            ;;
        --ddi)
            DDI="$2"
            shift 2
            ;;
        --slot-size)
            SLOT_SIZE="$2"
            shift 2
            ;;
        --bootkc)
            BOOTKC="$2"
            shift 2
            ;;
        --device-tree)
            DEVICE_TREE="$2"
            shift 2
            ;;
        --sptm)
            SPTM="$2"
            shift 2
            ;;
        --txm)
            TXM="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            usage >&2
            die "unknown argument: $1"
            ;;
    esac
done

[[ "$(uname)" == "Darwin" ]] || die "the test ramdisk must be prepared on macOS"
[[ -f "${RAMDISK}" ]] || die "ramdisk not found: ${RAMDISK}"
[[ -f "${HASHES}" ]] || die "hash list not found: ${HASHES}"
[[ -n "${OUTPUT_DIR}" ]] || die "--output-dir is required"
[[ "${SLOT_SIZE}" =~ ^[0-9]+$ && "${SLOT_SIZE}" -gt 0 ]] || \
    die "--slot-size must be a positive multiple of 4096"
(( SLOT_SIZE % 4096 == 0 )) || die "--slot-size must be a positive multiple of 4096"

FIRMWARE_DIR="$(cd -- "$(dirname -- "${RAMDISK}")" && pwd -P)"
BOOTKC="${BOOTKC:-${FIRMWARE_DIR}/bootkc}"
DEVICE_TREE="${DEVICE_TREE:-${FIRMWARE_DIR}/dtree}"
[[ -f "${BOOTKC}" ]] || die "boot kernel collection not found: ${BOOTKC}"
[[ -f "${DEVICE_TREE}" ]] || die "device tree not found: ${DEVICE_TREE}"

if [[ -z "${SPTM}" && -z "${TXM}" ]]; then
    if [[ -f "${FIRMWARE_DIR}/sptm" && -f "${FIRMWARE_DIR}/txm" ]]; then
        SPTM="${FIRMWARE_DIR}/sptm"
        TXM="${FIRMWARE_DIR}/txm"
    elif [[ -e "${FIRMWARE_DIR}/sptm" || -e "${FIRMWARE_DIR}/txm" ]]; then
        die "firmware directory contains only one of SPTM and TXM"
    fi
fi
if [[ -n "${SPTM}" && -z "${TXM}" ]] || [[ -z "${SPTM}" && -n "${TXM}" ]]; then
    die "SPTM and TXM must both be set or both be omitted"
fi
if [[ -n "${SPTM}" ]]; then
    [[ -f "${SPTM}" ]] || die "SPTM image not found: ${SPTM}"
    [[ -f "${TXM}" ]] || die "TXM image not found: ${TXM}"
fi

if [[ -z "${DDI}" ]]; then
    DDI_ROOT="/Library/Developer/DeveloperDiskImages/iOS_DDI/Restore"
    DDI_MANIFEST="${DDI_ROOT}/BuildManifest.plist"
    [[ -f "${DDI_MANIFEST}" ]] || die "pass --ddi explicitly (Restore BuildManifest.plist not found)"
    DDI_NAME="$(/usr/libexec/PlistBuddy \
        -c 'Print :BuildIdentities:0:Manifest:PersonalizedDMG:Info:Path' \
        "${DDI_MANIFEST}" 2>/dev/null || true)"
    [[ -n "${DDI_NAME}" ]] || die "pass --ddi explicitly (could not identify the Restore DDI)"
    DDI="${DDI_ROOT}/${DDI_NAME}"
fi
[[ -f "${DDI}" ]] || die "Developer Disk Image not found: ${DDI}"

OUTPUT_PARENT="$(dirname -- "${OUTPUT_DIR}")"
OUTPUT_NAME="$(basename -- "${OUTPUT_DIR}")"
mkdir -p "${OUTPUT_PARENT}"
OUTPUT_PARENT="$(cd -- "${OUTPUT_PARENT}" && pwd -P)"
[[ "${OUTPUT_NAME}" != "." && "${OUTPUT_NAME}" != ".." ]] || die "invalid --output-dir"
OUTPUT_DIR="${OUTPUT_PARENT}/${OUTPUT_NAME}"
[[ ! -e "${OUTPUT_DIR}" && ! -L "${OUTPUT_DIR}" ]] || die "refusing to overwrite ${OUTPUT_DIR}"

STAGING_DIR="$(mktemp -d "${OUTPUT_PARENT}/.${OUTPUT_NAME}.XXXXXX")"
OUTPUT_RAMDISK="${STAGING_DIR}/ramdisk.dmg"
OUTPUT_TRUST_CACHE="${STAGING_DIR}/ramdisk.tc"
OUTPUT_SLOT_MANIFEST="${STAGING_DIR}/slot.json"

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/darwin-vm-xctest-ramdisk.XXXXXX")"
RAMDISK_MOUNT="${WORK_DIR}/ramdisk"
DDI_MOUNT="${WORK_DIR}/ddi"
GUEST_RUNNER_PATH="/AppleInternal/DarwinVMTestRunner"
GUEST_RUNNER_MOUNT="${RAMDISK_MOUNT}${GUEST_RUNNER_PATH}"
mkdir "${RAMDISK_MOUNT}" "${DDI_MOUNT}"

cleanup() {
    hdiutil detach "${RAMDISK_MOUNT}" >/dev/null 2>&1 || true
    hdiutil detach "${DDI_MOUNT}" >/dev/null 2>&1 || true
    if mount | grep -Fq " on ${RAMDISK_MOUNT} " || mount | grep -Fq " on ${DDI_MOUNT} "; then
        printf 'warning: leaving preparation directories in place because a disk image is still mounted\n' >&2
        return
    fi
    rm -rf "${WORK_DIR}"
    if [[ -n "${STAGING_DIR}" && -d "${STAGING_DIR}" ]]; then
        rm -rf "${STAGING_DIR}"
    fi
}
trap cleanup EXIT

SDKROOT="$(xcrun --sdk iphoneos --show-sdk-path)"
HOST_BINARY="${WORK_DIR}/xctest"
SHIM_BINARY="${WORK_DIR}/libswiftFoundation.dylib"

xcrun --sdk iphoneos clang \
    -fobjc-arc \
    -target arm64-apple-ios16.0 \
    -isysroot "${SDKROOT}" \
    -Wl,-rpath,/System/Developer/Library/Frameworks \
    -Wl,-rpath,/System/Developer/Library/PrivateFrameworks \
    -Wl,-rpath,/System/Developer/usr/lib \
    -Wl,-sectcreate,__TEXT,__info_plist,"${SCRIPT_DIR}/xctest_host-Info.plist" \
    -framework Foundation \
    "${SCRIPT_DIR}/xctest_host.m" \
    -o "${HOST_BINARY}"
codesign -f -s - "${HOST_BINARY}"

xcrun --sdk iphoneos clang \
    -target arm64-apple-ios16.0 \
    -isysroot "${SDKROOT}" \
    -dynamiclib \
    -Wl,-install_name,/usr/lib/swift/libswiftFoundation.dylib \
    -Wl,-compatibility_version,1.0.0 \
    -Wl,-current_version,120.100.0 \
    -Wl,-reexport_framework,Foundation \
    "${SCRIPT_DIR}/swift_foundation_shim.c" \
    -o "${SHIM_BINARY}"
codesign -f -s - "${SHIM_BINARY}"

cp "${RAMDISK}" "${OUTPUT_RAMDISK}"
hdiutil attach -readonly -owners on -nobrowse -mountpoint "${DDI_MOUNT}" "${DDI}" >/dev/null
hdiutil attach -owners on -nobrowse -mountpoint "${RAMDISK_MOUNT}" "${OUTPUT_RAMDISK}" >/dev/null

runtime_paths=(
    Library/Frameworks/XCTest.framework
    Library/Frameworks/XCUIAutomation.framework
    Library/Frameworks/Testing.framework
    Library/Frameworks/_Testing_Foundation.framework
    Library/PrivateFrameworks/XCTestCore.framework
    Library/PrivateFrameworks/XCTestSupport.framework
    usr/lib/libXCTestSwiftSupport.dylib
    usr/lib/lib_TestingInterop.dylib
)

for destination in \
    "${RAMDISK_MOUNT}/System/Developer/Library/Frameworks/XCTest.framework" \
    "${RAMDISK_MOUNT}/usr/lib/swift/libswiftFoundation.dylib" \
    "${GUEST_RUNNER_MOUNT}"; do
    [[ ! -e "${destination}" && ! -L "${destination}" ]] || \
        die "ramdisk is already prepared: ${destination#${RAMDISK_MOUNT}}"
done

runtime_size_kb=0
for relative_path in "${runtime_paths[@]}"; do
    source_path="${DDI_MOUNT}/${relative_path}"
    [[ -e "${source_path}" ]] || die "DDI runtime file not found: ${relative_path}"
    path_size_kb="$(du -sk "${source_path}" | awk '{print $1}')"
    runtime_size_kb=$((runtime_size_kb + path_size_kb))
done
available_kb="$(df -Pk "${RAMDISK_MOUNT}" | awk 'END {print $4}')"
required_kb=$((runtime_size_kb + SLOT_SIZE / 1024 + 8192))
if (( available_kb < required_kb )); then
    die "ramdisk has ${available_kb} KiB free but preparation needs about ${required_kb} KiB; use a smaller --slot-size"
fi

for relative_path in "${runtime_paths[@]}"; do
    source_path="${DDI_MOUNT}/${relative_path}"
    destination_path="${RAMDISK_MOUNT}/System/Developer/${relative_path}"
    sudo mkdir -p "$(dirname "${destination_path}")"
    sudo ditto "${source_path}" "${destination_path}"
done

sudo mkdir -p \
    "${RAMDISK_MOUNT}/System/Developer/Library/Xcode/Agents" \
    "${RAMDISK_MOUNT}/usr/lib" \
    "${RAMDISK_MOUNT}/usr/lib/swift" \
    "${GUEST_RUNNER_MOUNT}/Test.xctest"
sudo cp "${HOST_BINARY}" "${RAMDISK_MOUNT}/System/Developer/Library/Xcode/Agents/xctest"
sudo cp "${SHIM_BINARY}" "${RAMDISK_MOUNT}/usr/lib/swift/libswiftFoundation.dylib"
sudo cp "${SCRIPT_DIR}/test_bundle-Info.plist" \
    "${GUEST_RUNNER_MOUNT}/Test.xctest/Info.plist"

SLOT_SOURCE="${WORK_DIR}/test-slot.bin"
python3 "${SCRIPT_DIR}/test_slot.py" create \
    --output "${SLOT_SOURCE}" \
    --size "${SLOT_SIZE}"
sudo cp "${SLOT_SOURCE}" \
    "${GUEST_RUNNER_MOUNT}/Test.xctest/Test"

sudo chmod 755 \
    "${RAMDISK_MOUNT}/System/Developer/Library/Xcode/Agents/xctest" \
    "${GUEST_RUNNER_MOUNT}/Test.xctest/Test"
sudo chown -R root:wheel "${RAMDISK_MOUNT}/bin" "${RAMDISK_MOUNT}/System"
if [[ -d "${RAMDISK_MOUNT}/libexec" ]]; then
    sudo chown -R root:wheel "${RAMDISK_MOUNT}/libexec"
fi
sudo chown -R root:wheel \
    "${RAMDISK_MOUNT}/usr/lib/swift/libswiftFoundation.dylib" \
    "${GUEST_RUNNER_MOUNT}"

RUNTIME_HASHES="${WORK_DIR}/runtime-hashes"
cp "${HASHES}" "${RUNTIME_HASHES}"
while IFS= read -r -d '' candidate; do
    if file "${candidate}" | grep -q 'Mach-O'; then
        found_architecture=false
        for runtime_architecture in arm64 arm64e; do
            if lipo "${candidate}" -verify_arch "${runtime_architecture}" >/dev/null 2>&1; then
                cdhash="$(codesign -d --verbose=4 --arch "${runtime_architecture}" \
                    "${candidate}" 2>&1 | sed -n 's/^CDHash=//p')"
                [[ -n "${cdhash}" ]] || die "could not read ${runtime_architecture} CDHash: ${candidate}"
                printf '%s\n' "${cdhash}" >> "${RUNTIME_HASHES}"
                found_architecture=true
            fi
        done
        [[ "${found_architecture}" == true ]] || die "runtime Mach-O has no arm64 slice: ${candidate}"
    fi
done < <(find \
    "${RAMDISK_MOUNT}/System/Developer" \
    "${RAMDISK_MOUNT}/usr/lib/swift/libswiftFoundation.dylib" \
    -type f -print0)
sort -u "${RUNTIME_HASHES}" -o "${RUNTIME_HASHES}"
"${PROJECT_DIR}/build_tc.py" "${RUNTIME_HASHES}" "${OUTPUT_TRUST_CACHE}"

hdiutil detach "${RAMDISK_MOUNT}" >/dev/null
hdiutil detach "${DDI_MOUNT}" >/dev/null

manifest_arguments=(
    --architecture arm64
    --input "bootkc=${BOOTKC}"
    --input "device_tree=${DEVICE_TREE}"
    --input "ramdisk=${OUTPUT_RAMDISK}"
    --input "trust_cache=${OUTPUT_TRUST_CACHE}"
    --provenance-file "ddi=${DDI}"
    --provenance "sdk_version=$(xcrun --sdk iphoneos --show-sdk-version)"
    --provenance "xcode_version=$(xcodebuild -version | paste -sd ' ' -)"
)
if [[ -n "${SPTM}" ]]; then
    manifest_arguments+=(
        --input "sptm=${SPTM}"
        --input "txm=${TXM}"
    )
fi
if [[ -f "${FIRMWARE_DIR}/info" ]]; then
    manifest_arguments+=(
        --provenance "device=$(sed -n '1p' "${FIRMWARE_DIR}/info")"
        --provenance "ipsw_url=$(sed -n '2p' "${FIRMWARE_DIR}/info")"
    )
fi

python3 "${SCRIPT_DIR}/test_slot.py" locate "${manifest_arguments[@]}" \
    --image "${OUTPUT_RAMDISK}" \
    --slot "${SLOT_SOURCE}" \
    --manifest "${OUTPUT_SLOT_MANIFEST}" \
    --guest-path "${GUEST_RUNNER_PATH}/Test.xctest/Test" \
    --bundle-path "${GUEST_RUNNER_PATH}/Test.xctest"

chmod 755 "${STAGING_DIR}"
[[ ! -e "${OUTPUT_DIR}" && ! -L "${OUTPUT_DIR}" ]] || die "output directory appeared during preparation: ${OUTPUT_DIR}"
mv "${STAGING_DIR}" "${OUTPUT_DIR}"
STAGING_DIR=""
printf 'Prepared XCTest ramdisk in %s\n' "${OUTPUT_DIR}"
