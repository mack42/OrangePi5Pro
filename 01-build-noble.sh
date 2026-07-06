#!/usr/bin/env bash
# Build Armbian Ubuntu 24.04 (noble) for Orange Pi 5 Pro using the vendor
# kernel. Run this from the stock Orange Pi vendor Ubuntu 22.04 system —
# noble uses GNU coreutils, which sidesteps the rust-coreutils chroot panic
# that blocks a direct 26.04 build on this kernel. See README.md.
#
# Output: ~/armbian-build/framework/output/images/Armbian-*_noble_*.img.xz

set -euo pipefail

WORK="${WORK:-$HOME/armbian-build}"
mkdir -p "$WORK"
cd "$WORK"

if [[ ! -d framework ]]; then
    git clone --depth=1 https://github.com/armbian/build.git framework
fi

cd framework

# Armbian's build framework picks up ANY userpatches/customize-image.sh
# regardless of the release target. If a previous --desktop run of
# 02-build-resolute.sh left one behind, it would silently inject KDE
# Plasma into this "minimal" noble build. Scrub it.
rm -f userpatches/customize-image.sh

exec ./compile.sh \
    BOARD=orangepi5pro \
    BRANCH=vendor \
    RELEASE=noble \
    BUILD_MINIMAL=yes \
    BUILD_DESKTOP=no \
    KERNEL_CONFIGURE=no \
    COMPRESS_OUTPUTIMAGE=sha,xz \
    EXPERT=yes
