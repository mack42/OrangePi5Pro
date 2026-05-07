#!/bin/bash
# customize-image-npu.sh — RK3588 NPU enablement for the Orange Pi 5 Pro,
# sourced from inside the chroot by both customize-image.sh (desktop) and
# customize-image-minimal.sh (CLI). Standalone — must NOT depend on
# variables from the caller.
#
# Stack
# -----
#   1. Kernel module: w568w/rknpu-module v0.9.8 (vendor rknpu driver,
#      mainline-friendly out-of-tree port). Packaged via DKMS so it
#      auto-rebuilds on kernel updates.
#   2. Userspace: librknnrt.so 2.3.2 from airockchip/rknn-toolkit2 — the
#      AI runtime that the rest of the rknn ecosystem (Python toolkit,
#      Frigate's rknn detector, RKLLM, YOLO models, etc.) depends on.
#   3. DT overlay: rk3588-rknpu-opi5pro.dtbo — disables the mainline
#      rocket DT nodes (rknn_core_*) and inserts a single vendor-style
#      rknpu node that the DKMS module binds to. Adapted from
#      schwankner/talos-rk3588-npu's Turing-RK1 overlay (same SoC).
#   4. Module loading: blacklist `rocket` (in-tree mainline NPU driver,
#      Linux 6.18+) — vendor rknpu and rocket are mutually exclusive,
#      they fight over the same hardware. We use rknpu because it
#      supports the full rknn-toolkit2 model zoo (YOLO, RKLLM, etc.);
#      rocket today only handles MobileNet-class models.
#   5. Auto-load `rknpu` at boot via /etc/modules-load.d/.
#
# Why bake into both flavors: NPU is non-disruptive (no GPU regression
# since we're already on mainline + panthor) and useful headless or with
# Plasma. ~30-50 MB of disk for kernel headers + DKMS sources +
# librknnrt — small relative to either image.

set -e

# --- 1. Build deps + kernel headers ---
apt-get install -y --no-install-recommends \
    dkms build-essential device-tree-compiler

# Find the linux-image-* package installed in the chroot and install its
# matching headers package. Armbian names them linux-{image,headers}-
# {branch}-{family}, e.g. linux-image-current-rockchip64. uname -r in a
# chroot doesn't reflect the target kernel — use dpkg-query instead.
kpkg="$(dpkg-query -W -f='${Package}\n' 'linux-image-*' 2>/dev/null | grep -vE 'dbg|tools' | head -1)"
if [ -n "$kpkg" ]; then
    hpkg="${kpkg/linux-image-/linux-headers-}"
    apt-get install -y --no-install-recommends "$hpkg" \
        || echo "WARN: failed to install $hpkg — DKMS build will likely fail."
fi

# --- 2. DKMS rknpu module ---
git clone --depth=1 https://github.com/w568w/rknpu-module.git /tmp/rknpu-module
mkdir -p /usr/src/rknpu-0.9.8
cp -r /tmp/rknpu-module/. /usr/src/rknpu-0.9.8/
rm -rf /tmp/rknpu-module
dkms add rknpu/0.9.8

# Build/install for every kernel version present in /lib/modules. In
# practice that's exactly one (the freshly-baked image's kernel). The
# loop tolerates per-kver build failures so a partial install (e.g. an
# older kernel missing headers) doesn't abort the whole image build.
for kver in $(ls /lib/modules 2>/dev/null); do
    dkms build rknpu/0.9.8 -k "$kver"   || echo "WARN: dkms build failed for $kver"
    dkms install rknpu/0.9.8 -k "$kver" || echo "WARN: dkms install failed for $kver"
done

# --- 3. DT overlay for RK3588 / OPi 5 Pro ---
# Adapted from schwankner/talos-rk3588-npu/boards/turing-rk1/overlays/
# rknpu.dts (Turing RK1 = same SoC as OPi 5 Pro). We disable the
# mainline rocket per-core nodes and add a single vendor-compatible
# rknpu node spanning all three NPU cores.
mkdir -p /usr/src/orangepi5pro-overlays
cat > /usr/src/orangepi5pro-overlays/rk3588-rknpu-opi5pro.dts <<'OVERLAY'
// SPDX-License-Identifier: GPL-2.0-only
//
// DT overlay: replace mainline rocket (rknn_core_*) DT nodes with a
// single vendor-compatible rknpu node so the w568w/rknpu-module driver
// binds. Targets RK3588 (OPi 5 Pro). Adapted from Talos / Turing RK1.

/dts-v1/;
/plugin/;

#include <dt-bindings/interrupt-controller/arm-gic.h>
#include <dt-bindings/power/rk3588-power.h>

/ {
    compatible = "rockchip,rk3588";
};

/* Disable mainline rocket per-core nodes. Keep rknn_mmu_0/1/2 enabled
 * so PM domain consumer accounting matches the vanilla DTB. The rknpu
 * node references them via iommus phandles. */
&rknn_core_0 { status = "disabled"; };
&rknn_core_1 { status = "disabled"; };
&rknn_core_2 { status = "disabled"; };

&{/} {
    rknpu: npu@fdab0000 {
        compatible = "rockchip,rk3588-rknpu", "rockchip,rknpu";
        reg = <0x0 0xfdab0000 0x0 0x9000>,
              <0x0 0xfdac0000 0x0 0x9000>,
              <0x0 0xfdad0000 0x0 0x9000>;
        reg-names = "rknpu_core0", "rknpu_core1", "rknpu_core2";

        interrupts = <GIC_SPI 110 IRQ_TYPE_LEVEL_HIGH 0>,
                     <GIC_SPI 111 IRQ_TYPE_LEVEL_HIGH 0>,
                     <GIC_SPI 112 IRQ_TYPE_LEVEL_HIGH 0>;
        interrupt-names = "npu_irq0", "npu_irq1", "npu_irq2";

        clocks = <&scmi_clk SCMI_CLK_NPU>;
        clock-names = "clk_npu";

        resets = <&cru SRST_A_RKNN_NODDR>;
        reset-names = "srst_a";

        power-domains = <&power RK3588_PD_NPUTOP>,
                        <&power RK3588_PD_NPU1>,
                        <&power RK3588_PD_NPU2>;
        power-domain-names = "nputop", "npu1", "npu2";

        iommus = <&rknn_mmu_0>, <&rknn_mmu_1>, <&rknn_mmu_2>;

        operating-points-v2 = <&npu_opp_table>;

        npu-supply = <&vdd_npu_s0>;
        sram-supply = <&vdd_npu_s0>;

        status = "okay";
    };
};
OVERLAY

# Compile the overlay against the running chroot's kernel headers.
# Output to Armbian's standard overlay dir.
overlay_dir=/boot/dtb/rockchip/overlay
mkdir -p "$overlay_dir"

# Need to preprocess for the #include / dt-bindings — use cpp + dtc.
header_dir=""
if [ -n "$kpkg" ] && [ -d "/usr/src/$(echo "$kpkg" | sed 's/^linux-image-/linux-headers-/')" ]; then
    header_dir="/usr/src/$(echo "$kpkg" | sed 's/^linux-image-/linux-headers-/')"
elif ls -d /usr/src/linux-headers-* 2>/dev/null | head -1 >/dev/null; then
    header_dir="$(ls -d /usr/src/linux-headers-* | head -1)"
fi

if [ -n "$header_dir" ]; then
    cpp -nostdinc -undef -x assembler-with-cpp \
        -I "$header_dir/include" \
        -o /tmp/rk3588-rknpu-opi5pro.dts.preprocessed \
        /usr/src/orangepi5pro-overlays/rk3588-rknpu-opi5pro.dts
    dtc -@ -I dts -O dtb \
        -o "$overlay_dir/rk3588-rknpu-opi5pro.dtbo" \
        /tmp/rk3588-rknpu-opi5pro.dts.preprocessed
    rm -f /tmp/rk3588-rknpu-opi5pro.dts.preprocessed
else
    echo "WARN: no kernel headers found; skipping DT overlay compile."
fi

# --- 4. Enable the overlay in armbianEnv.txt ---
if [ -f /boot/armbianEnv.txt ]; then
    if grep -q '^user_overlays=' /boot/armbianEnv.txt; then
        if ! grep -q 'rk3588-rknpu-opi5pro' /boot/armbianEnv.txt; then
            sed -i 's|^user_overlays=\(.*\)$|user_overlays=\1 rk3588-rknpu-opi5pro|' /boot/armbianEnv.txt
        fi
    else
        echo 'user_overlays=rk3588-rknpu-opi5pro' >> /boot/armbianEnv.txt
    fi
fi

# --- 5. Blacklist rocket; auto-load rknpu ---
mkdir -p /etc/modprobe.d /etc/modules-load.d
cat > /etc/modprobe.d/blacklist-rocket.conf <<'BLACK'
# RK3588 has two NPU drivers available:
#   - mainline `rocket` (drivers/accel/rocket/, in Linux 6.18+) — ABI
#     incompatible with rknn-toolkit2; supports only MobileNet-class
#     models via Mesa Teflon delegate today.
#   - vendor `rknpu` (out-of-tree DKMS, github.com/w568w/rknpu-module)
#     — full rknn-toolkit2 ecosystem (YOLO, RKLLM, Frigate, etc.).
# We ship rknpu. Blacklist rocket so it doesn't bind to the same
# hardware on boot.
blacklist rocket
BLACK

echo "rknpu" > /etc/modules-load.d/orangepi-rknpu.conf

# --- 6. librknnrt.so userspace runtime ---
# v2.3.2 (April 2025) from airockchip/rknn-toolkit2. Stable across 2.x.x
# releases, ABI-compatible with rknpu module 0.9.8/0.9.10.
curl -fsSL --retry 3 \
    https://github.com/airockchip/rknn-toolkit2/raw/v2.3.2/rknpu2/runtime/Linux/librknn_api/aarch64/librknnrt.so \
    -o /usr/lib/librknnrt.so
chmod 0644 /usr/lib/librknnrt.so
ldconfig

echo "RKNPU stack installed: DKMS module 0.9.8, librknnrt 2.3.2, overlay rk3588-rknpu-opi5pro."
