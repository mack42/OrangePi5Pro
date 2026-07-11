#!/usr/bin/env bash
# Build Armbian Ubuntu 26.04 (resolute) for Orange Pi 5 Pro. Run this AFTER
# booting the 24.04 image produced by 01-build-noble.sh, NOT directly on stock
# Orange Pi vendor Ubuntu 22.04 — that kernel lacks CONFIG_BINFMT_MISC and the
# rust-coreutils chroot panic workaround can't deploy qemu-user-static.
#
# Usage:
#   ./02-build-resolute.sh                  # minimal CLI image (default)
#   ./02-build-resolute.sh --desktop        # with KDE Plasma + SDDM
#   ./02-build-resolute.sh --both           # both images (minimal, then desktop)
#   VERSION=v1.8.0 ./02-build-resolute.sh --both   # both, release-named
#   DESKTOP=yes ./02-build-resolute.sh      # same as --desktop via env var
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
BOTH="${BOTH:-no}"
BRANCH="${BRANCH:-current}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --desktop)    DESKTOP=yes; shift ;;
        --no-desktop) DESKTOP=no; shift ;;
        --both)       BOTH=yes; shift ;;
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

# Work around two bugs in current Armbian framework (>= 26.08-trunk) that
# abort our build. Both are idempotent. Remove once upstream fixes land.
#
#   1. A debug-only `run_host_command_logged ls -lahtR <apt-dir>` aborts the
#      whole build: modern apt creates a lists/auxfiles subdir that makes
#      `ls -R` print "not listing already-listed directory" and exit 2, and
#      run_host_command_logged treats any non-zero as fatal. Drop the -R so
#      the (non-recursive) diagnostic can't fail. Two copies exist.
#   2. extensions/armbian-config.sh auto-installs armbian-config in a
#      post-customize hook; that install fails against the current configng
#      repo and it's not needed for our image. Make the hook a no-op.
fw="${WORK}/framework"
sed -i 's@\(run_host_command_logged \)ls -lahtR@\1ls -laht@g' \
    "${fw}/lib/functions/host/host-utils.sh" \
    "${fw}/lib/functions/rootfs/apt-install.sh"
if ! grep -q 'armbian-config install skipped' "${fw}/extensions/armbian-config.sh" 2>/dev/null; then
    perl -0pi -e 's/(function post_armbian_repo_customize_image__install_armbian-config\(\) \{\n)\tchroot_sdcard_apt_get_install "armbian-config"\n/$1\t# armbian-config install skipped (custom image; install fails vs configng repo)\n\treturn 0\n/' \
        "${fw}/extensions/armbian-config.sh"
fi

# Note: Armbian's framework doesn't yet have resolute desktop environment
# configs (only bookworm / noble / jammy do as of May 2026), so --desktop
# can't go through BUILD_DESKTOP=yes (errors with "kde-plasma does not exist
# for resolute"). Instead we drop a userpatches/customize-image.sh from this
# repo (alongside this script) that apt-installs kubuntu-desktop + the rest
# inside the chroot during build.
userpatches="${WORK}/framework/userpatches"
mkdir -p "$userpatches"
imgdir="${WORK}/framework/output/images"

# build_variant <desktop:yes|no> — drop in the right customize hook, run the
# Armbian build, and rename the output to opi5pro[-$VERSION]-{desktop,minimal}.
# Armbian names every image *_minimal (we pass BUILD_MINIMAL=yes; the desktop
# content comes from our customize hook, which the framework's naming can't
# see), so we rename to reflect the real variant. INSTALL_HEADERS=yes so
# customize-image-npu.sh can DKMS-build rknpu and compile the DT overlay.
build_variant() {
    local desktop="$1" src variant base build_marker newimg
    if [[ "$desktop" == "yes" ]]; then
        echo ">>> Building image with KDE Plasma + HW video decode (MPP+rockchip-vaapi) baked in."
        echo ">>> Expect ~45-60 min and ~940 MB output."
        echo ">>> First boot lands at TTY: armbian-firstrun runs (set root password, create user),"
        echo ">>> then the kdialog wizard auto-launches in Plasma for NVMe / overscan / etc."
        src="${script_dir}/customize-image.sh"
        variant="desktop"
    else
        echo ">>> Building MINIMAL image (CLI). Expect ~8-15 min and ~440 MB output."
        echo ">>> First boot lands at TTY: armbian-firstrun runs, then motd reminds the user"
        echo ">>> to run 'orangepi-setup' for the post-boot wizard."
        src="${script_dir}/customize-image-minimal.sh"
        variant="minimal"
    fi
    [[ -f "$src" ]] || { echo "ERROR: $src not found in repo." >&2; exit 1; }

    # Defensively drop any prior customize-image.sh so a previous run (or the
    # other variant in a --both run) can't leak into this build.
    rm -f "$userpatches/customize-image.sh"
    cp "$src" "$userpatches/customize-image.sh"
    chmod +x "$userpatches/customize-image.sh"

    cd "${WORK}/framework"
    build_marker="$(mktemp)"
    ./compile.sh \
        BOARD=orangepi5pro \
        BRANCH="$BRANCH" \
        RELEASE=resolute \
        BUILD_MINIMAL=yes \
        BUILD_DESKTOP=no \
        KERNEL_CONFIGURE=no \
        INSTALL_HEADERS=yes \
        COMPRESS_OUTPUTIMAGE=sha,xz \
        EXPERT=yes

    # Rename to a short, correctly-labelled artifact (+ regenerated .sha256, + .img.txt).
    # Set VERSION=v1.8.0 (etc.) in the environment to embed a release tag.
    newimg="$(find "$imgdir" -maxdepth 1 -name 'Armbian-unofficial_*_minimal.img.xz' -newer "$build_marker" 2>/dev/null | head -1)"
    rm -f "$build_marker"
    if [[ -n "$newimg" ]]; then
        base="opi5pro${VERSION:+-${VERSION}}-${variant}"
        mv -f "$newimg" "${imgdir}/${base}.img.xz"
        [[ -f "${newimg%.img.xz}.img.txt" ]] && mv -f "${newimg%.img.xz}.img.txt" "${imgdir}/${base}.img.txt"
        rm -f "${newimg}.sha"   # stale: references the old filename
        ( cd "$imgdir" && sha256sum "${base}.img.xz" > "${base}.img.xz.sha256" )
        echo ">>> Image ready: ${imgdir}/${base}.img.xz"
    else
        echo ">>> WARN: build finished but no fresh ${variant} image found in ${imgdir}" >&2
    fi
}

if [[ "$BOTH" == "yes" ]]; then
    build_variant no    # minimal first (smaller/faster; warms the rootfs cache)
    build_variant yes   # then desktop
else
    build_variant "$DESKTOP"
fi
