#!/bin/bash
# Build kernel, Enxerto bootloader, userspace, and package payload for Xperia XZ3 (akatsuki)
# Uses Enxerto bootloader (not edk2-sdm845) with DTB from live device tree
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

# Configuration
BOARD=akatsuki
KERNEL_CONFIG=DEVELOPMENT
DTB_SOURCE="$ROOT/xz3-live.dts"
DTB_OUT="$ROOT/dtb/akatsuki/dtb"
ADT_OUT="$ROOT/bootloader/enxerto/out-akatsuki.adt"
PAYLOAD_OUT="$ROOT/bootloader/enxerto/out/payload-akatsuki.bin"
KERNEL_PATH="$ROOT/work/hackios/xnu-src/xnu-8796.121.2/BUILD/obj/DEVELOPMENT_ARM64_BCM2837/mach.development.bcm2837"

# Build flags
export ADT_GAMUT=P3

# iOS 16.5 cmdline for dipper (adapted for akatsuki)
# Using dipper-xnu's cmdline structure but with akatsuki hardware
CMDLINE="debug=0x8 rd=md0 vtimer_intid=19 hv_wdt_pet=1 ufs_shared_pa=0x0000000000000000 battery_shared_pa=0x0000000000000000 cpus=8 sweetsmp=1 keepsyms=1 -noprogress nointr_consio=1 rd=ufsroot0 unentitled_ios_sim_launch=1 ignition_level=1 wdt_test=no_user_checkin ufsrw=1 rootrw=1 launchd_unsecure_cache=1 wdt=-1 sweetfb_hz=10 sweetecon=1 sweetfb_noconsole=1 sweetlog=1 sweettouch=1 sweetts=1 sweettouchdelay=20 sweetkeys=1 rpmhrsc=0x179e0000 rpmhtcs=0x179e0d00"

usage() {
    cat <<'EOF'
Usage: tools/build/build-akatsuki.sh [options]
  --kernel-only       Only build the kernel
  --bootloader-only   Only build Enxerto bootloader
  --userspace-only    Only build userspace
  --payload-only      Only build payload (requires kernel + userspace)
  --full              Build everything (default)
  --help              Show this help
EOF
}

MODE="full"
while [ "$#" -gt 0 ]; do
    case "$1" in
        --kernel-only) MODE="kernel"; shift ;;
        --bootloader-only) MODE="bootloader"; shift ;;
        --userspace-only) MODE="userspace"; shift ;;
        --payload-only) MODE="payload"; shift ;;
        --full) MODE="full"; shift ;;
        --help) usage; exit 0 ;;
        *) echo "Unknown option: $1"; usage; exit 1 ;;
    esac
done

# Compile DTB from live device tree
compile_dtb() {
    echo "=== Compiling DTB from live device tree ==="
    mkdir -p "$(dirname "$DTB_OUT")"
    dtc -I dts -O dtb -o "$DTB_OUT" "$DTB_SOURCE"
    echo "DTB compiled to $DTB_OUT"
}

# Build ADT using mkadt.py
build_adt() {
    echo "=== Building ADT for akatsuki ==="
    python3 tools/prepare/mkadt.py "$ADT_OUT" --board akatsuki --highmem --display-scale 3 --points 480x960
    echo "ADT built to $ADT_OUT"
}

# Build kernel via GitHub Actions (local build not supported for XNU)
build_kernel() {
    echo "=== Kernel build ==="
    echo "NOTE: XNU kernel must be built via GitHub Actions (macos-15 runner)"
    echo "Run: gh workflow run xnu.yml --ref akatsuki-port -f macos_version=15.3 -f kernel_config=DEVELOPMENT"
    echo "Then: gh run download <run-id> -n xnu-kernel -D work/hackios/xnu-src/xnu-8796.121.2/BUILD/obj/DEVELOPMENT_ARM64_BCM2837/"
    echo ""
    echo "Expected kernel at: $KERNEL_PATH"
    if [ ! -f "$KERNEL_PATH" ]; then
        echo "WARNING: Kernel not found locally. CI build required."
        return 1
    fi
    echo "Kernel found: $(ls -lh "$KERNEL_PATH")"
}

# Build Enxerto bootloader
build_bootloader() {
    echo "=== Building Enxerto bootloader for akatsuki ==="
    cd "$ROOT/bootloader/enxerto"
    DTB="$DTB_OUT" BOARD=akatsuki ./build.sh
    echo "Bootloader built: $ROOT/bootloader/enxerto/out/enxerto-boot.img"
}

# Build payload
build_payload() {
    echo "=== Building payload ==="
    if [ ! -f "$KERNEL_PATH" ]; then
        echo "ERROR: Kernel not found at $KERNEL_PATH"
        exit 1
    fi
    if [ ! -f "$ADT_OUT" ]; then
        echo "ERROR: ADT not found at $ADT_OUT"
        exit 1
    fi
    mkdir -p "$(dirname "$PAYLOAD_OUT")"
    python3 tools/build/mkpayload.py \
        "$KERNEL_PATH" \
        "$ADT_OUT" \
        "$PAYLOAD_OUT" \
        --cmdline "$CMDLINE"
    echo "Payload built: $PAYLOAD_OUT"
}

# Build final boot image
build_boot_image() {
    echo "=== Building final boot image ==="
    cd "$ROOT/bootloader/enxerto"
    DTB="$DTB_OUT" BOARD=akatsuki ./build.sh "$PAYLOAD_OUT"
    echo "Boot image: $ROOT/bootloader/enxerto/out/enxerto-boot.img"
}

# Main build flow
case "$MODE" in
    kernel)
        build_kernel
        ;;
    bootloader)
        compile_dtb
        build_adt
        build_bootloader
        ;;
    userspace)
        echo "=== Building userspace ==="
        export BUILD_TIMEZONE=Asia/Tokyo
        export BUILD_JOBS=8
        bash tools/build/build-userland.sh
        python3 tools/build/pack-darwin.py
        ;;
    payload)
        compile_dtb
        build_adt
        build_payload
        build_boot_image
        ;;
    full)
        compile_dtb
        build_adt
        build_kernel || true  # Don't fail if kernel needs CI
        build_bootloader
        echo ""
        echo "=== Next steps ==="
        echo "1. Build kernel via CI (see output above)"
        echo "2. Build userspace: bash tools/build/build-userland.sh && python3 tools/build/pack-darwin.py"
        echo "3. Build payload + boot image: $0 --payload-only"
        echo "4. Test boot: fastboot boot bootloader/enxerto/out/enxerto-boot.img"
        ;;
esac