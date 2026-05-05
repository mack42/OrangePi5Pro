#!/usr/bin/env bash
# Build Armbian Ubuntu 26.04 (resolute) for Orange Pi 5 Pro. Run this AFTER
# booting the 24.04 image produced by 01-build-noble.sh, NOT directly on stock
# Orange Pi vendor Ubuntu 22.04 — that kernel lacks CONFIG_BINFMT_MISC and the
# rust-coreutils chroot panic workaround can't deploy qemu-user-static.
#
# Defaults to BRANCH=current (mainline 6.18+ kernel) for working GPU
# acceleration via the panthor + Mesa panvk drivers. Set BRANCH=vendor in the
# environment if you specifically need the Rockchip BSP (NPU access, vendor
# MPP video accel) — the result will be Plasma-usable but software-rendered
# only, since the BSP's built-in mali_kbase claims the GPU and prevents
# panfrost/panthor from binding. See https://github.com/mack42/OrangePi5Pro/issues/1
#
# A small patch (apply-uutils-shim.sh) swaps rust-coreutils symlinks for a
# qemu-user-static shim during the build and restores them before image
# creation. The final image ships clean uutils.
#
# Output: ~/armbian-build/framework/output/images/Armbian-*_resolute_*.img.xz

set -euo pipefail

BRANCH="${BRANCH:-current}"

config_file="/boot/config-$(uname -r)"
if [[ -r "$config_file" ]] && grep -qE '^# CONFIG_BINFMT_MISC is not set' "$config_file"; then
    echo "ERROR: this kernel was built without CONFIG_BINFMT_MISC."
    echo "       The 26.04 build will fail. Boot Armbian noble first (Step 1 in README)."
    exit 1
fi

if ! mountpoint -q /proc/sys/fs/binfmt_misc/; then
    sudo modprobe binfmt_misc || true
fi

WORK="${WORK:-$HOME/armbian-build}"
mkdir -p "$WORK"
cd "$WORK"

if [[ ! -d framework ]]; then
    git clone --depth=1 https://github.com/armbian/build.git framework
fi

# Apply the rust-coreutils chroot-panic workaround (idempotent).
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FRAMEWORK_DIR="${WORK}/framework" "${script_dir}/apply-uutils-shim.sh"

cd framework

exec ./compile.sh \
    BOARD=orangepi5pro \
    BRANCH="$BRANCH" \
    RELEASE=resolute \
    BUILD_MINIMAL=yes \
    BUILD_DESKTOP=no \
    KERNEL_CONFIGURE=no \
    COMPRESS_OUTPUTIMAGE=sha,xz \
    EXPERT=yes
