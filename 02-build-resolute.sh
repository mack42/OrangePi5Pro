#!/usr/bin/env bash
# Build Armbian Ubuntu 26.04 (resolute) for Orange Pi 5 Pro. Run this AFTER
# booting the 24.04 image produced by 01-build-noble.sh, NOT directly on stock
# Orange Pi vendor Ubuntu 22.04 — that kernel lacks CONFIG_BINFMT_MISC and the
# rust-coreutils chroot panic workaround can't deploy qemu-user-static.
#
# Usage:
#   ./02-build-resolute.sh                  # minimal CLI image (default)
#   ./02-build-resolute.sh --desktop        # with KDE Plasma + SDDM
#   DESKTOP=yes ./02-build-resolute.sh      # same via env var
#   BRANCH=vendor ./02-build-resolute.sh    # use Rockchip BSP (no GPU accel — see issue #1)
#
# Defaults to BRANCH=current (mainline ~6.18 kernel) for working GPU
# acceleration via panthor + Mesa panvk. Set BRANCH=vendor in the environment
# only if you specifically need the Rockchip BSP (NPU access, vendor MPP video
# accel) — the result will be Plasma-usable but software-rendered only.
#
# A small patch (apply-uutils-shim.sh) swaps rust-coreutils symlinks for a
# qemu-user-static shim during the build and restores them before image
# creation. The final image ships clean uutils.
#
# Output: ~/armbian-build/framework/output/images/Armbian-*_resolute_*.img.xz

set -euo pipefail

DESKTOP="${DESKTOP:-no}"
BRANCH="${BRANCH:-current}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --desktop)    DESKTOP=yes; shift ;;
        --no-desktop) DESKTOP=no; shift ;;
        --branch=*)   BRANCH="${1#*=}"; shift ;;
        -h|--help)
            sed -n '2,16p' "$0" | sed 's/^# \?//'
            exit 0 ;;
        *) echo "Unknown arg: $1" >&2; exit 1 ;;
    esac
done

config_file="/boot/config-$(uname -r)"
if [[ -r "$config_file" ]] && grep -qE '^# CONFIG_BINFMT_MISC is not set' "$config_file"; then
    echo "ERROR: this kernel was built without CONFIG_BINFMT_MISC."
    echo "       The 26.04 build will fail. Boot Armbian noble first (Step 1 in README)."
    exit 1
fi

if ! mountpoint -q /proc/sys/fs/binfmt_misc/; then
    sudo modprobe binfmt_misc || true
fi

# Resolve the directory containing this script *before* changing dir, so we
# can find sibling files (apply-uutils-shim.sh, customize-image.sh) regardless
# of how the script was invoked.
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

WORK="${WORK:-$HOME/armbian-build}"
mkdir -p "$WORK"
cd "$WORK"

if [[ ! -d framework ]]; then
    git clone --depth=1 https://github.com/armbian/build.git framework
fi

# Apply the rust-coreutils chroot-panic workaround (idempotent).
FRAMEWORK_DIR="${WORK}/framework" "${script_dir}/apply-uutils-shim.sh"

# Note: Armbian's framework doesn't yet have resolute desktop environment
# configs (only bookworm / noble / jammy do as of May 2026), so --desktop
# can't go through BUILD_DESKTOP=yes (errors with "kde-plasma does not exist
# for resolute"). Instead we drop a userpatches/customize-image.sh from this
# repo (alongside this script) that apt-installs kubuntu-desktop + the rest
# inside the chroot during build.
userpatches="${WORK}/framework/userpatches"
mkdir -p "$userpatches"
if [[ "$DESKTOP" == "yes" ]]; then
    echo ">>> Building image with KDE Plasma + HW video decode (MPP+rockchip-vaapi) baked in."
    echo ">>> Expect ~45-60 min and ~2 GB output."
    echo ">>> First boot lands at TTY: armbian-firstrun runs (set root password, create user),"
    echo ">>> then the kdialog wizard auto-launches in Plasma for NVMe / overscan / etc."
    src="${script_dir}/customize-image.sh"
else
    echo ">>> Building MINIMAL image (CLI). Expect ~8-15 min and ~300 MB output."
    echo ">>> First boot lands at TTY: armbian-firstrun runs, then motd reminds the user"
    echo ">>> to run 'orangepi-setup' for the post-boot wizard."
    src="${script_dir}/customize-image-minimal.sh"
fi
if [[ ! -f "$src" ]]; then
    echo "ERROR: $src not found in repo." >&2
    exit 1
fi
cp "$src" "$userpatches/customize-image.sh"
chmod +x "$userpatches/customize-image.sh"

cd "${WORK}/framework"
exec ./compile.sh \
    BOARD=orangepi5pro \
    BRANCH="$BRANCH" \
    RELEASE=resolute \
    BUILD_MINIMAL=yes \
    BUILD_DESKTOP=no \
    KERNEL_CONFIGURE=no \
    COMPRESS_OUTPUTIMAGE=sha,xz \
    EXPERT=yes
