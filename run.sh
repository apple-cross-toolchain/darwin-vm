#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
FIRMWARE_DIR="${SCRIPT_DIR}/firmware"
QEMU="${SCRIPT_DIR}/qemu-sptm/build/qemu-system-aarch64"
# Keep serial input/output enabled while suppressing noisy IOKit logs.
BOOT_ARGS="rd=md0 serial=19 -v -noprogress wdt=-1 wlan-olyhal-abort trm_enabled=0 hidrm_enabled=0"
TTY_STATE=""

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

fix_tty() {
    if [[ -n "${TTY_STATE}" ]]; then
        stty "${TTY_STATE}" 2>/dev/null || true
    fi
}

setup_tty() {
    if [[ -t 0 ]]; then
        TTY_STATE="$(stty -g)"
        trap 'fix_tty' EXIT
    fi
}

validate_inputs() {
    local firmware_file
    local sptm="${FIRMWARE_DIR}/sptm"
    local txm="${FIRMWARE_DIR}/txm"

    if [[ ! -f "${QEMU}" || ! -x "${QEMU}" ]]; then
        die "QEMU executable not found: ${QEMU} (build qemu-sptm first)"
    fi

    for firmware_file in bootkc dtree ramdisk.tc ramdisk.dmg; do
        firmware_file="${FIRMWARE_DIR}/${firmware_file}"
        if [[ ! -f "${firmware_file}" || ! -r "${firmware_file}" ]]; then
            die "firmware file not found or unreadable: ${firmware_file}"
        fi
    done

    if [[ -f "${sptm}" && -f "${txm}" ]]; then
        if [[ ! -r "${sptm}" || ! -r "${txm}" ]]; then
            die "SPTM and TXM firmware must be readable"
        fi
    elif [[ -e "${sptm}" || -L "${sptm}" || -e "${txm}" || -L "${txm}" ]]; then
        die "SPTM and TXM firmware must either both be present or both be absent"
    fi
}

boot_qemu() {
    local -a args=(
        -M darwin
        -bootkc   "${FIRMWARE_DIR}/bootkc"
        -dtree    "${FIRMWARE_DIR}/dtree"
        -tc       "${FIRMWARE_DIR}/ramdisk.tc"
        -ramdisk  "${FIRMWARE_DIR}/ramdisk.dmg"
        -args     "${BOOT_ARGS}"
        -nographic
        -serial mon:stdio
        -m 8G
    )

    if [[ -f "${FIRMWARE_DIR}/sptm" ]]; then
        args+=(
            -sptm     "${FIRMWARE_DIR}/sptm"
            -txm      "${FIRMWARE_DIR}/txm"
        )
    fi

    args+=("$@")
    "${QEMU}" "${args[@]}"
}

main() {
    setup_tty
    validate_inputs
    boot_qemu "$@"
}

main "$@"
