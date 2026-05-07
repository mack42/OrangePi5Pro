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

# Find the actual Armbian kernel package installed in the chroot and
# install its matching headers package. Armbian uses
# linux-{image,headers}-{branch}-{family} where branch ∈ {current, edge,
# legacy, vendor} and family is rockchip64 here. There's also a
# linux-image-armbian meta-package that's installed alongside but has no
# corresponding linux-headers-armbian — match the real package, not the
# meta. uname -r in a chroot doesn't reflect the target kernel either.
kpkg="$(dpkg-query -W -f='${Package}\n' 2>/dev/null \
    | grep -E '^linux-image-(current|edge|legacy|vendor)-rockchip64$' \
    | head -1)"
if [ -z "$kpkg" ]; then
    echo "WARN: could not find linux-image-{current,edge,legacy,vendor}-rockchip64 — skipping NPU install."
    exit 0
fi
hpkg="${kpkg/linux-image-/linux-headers-}"

# Headers should already be installed via INSTALL_HEADERS=yes in the
# compile.sh invocation (see 02-build-resolute.sh). Verify, with
# fallbacks: try apt-get (works if a local repo is configured), then
# search the chroot for a sideloaded .deb.
if ! dpkg-query -W -f='${Status}\n' "$hpkg" 2>/dev/null | grep -q '^install ok installed$'; then
    if ! apt-get install -y --no-install-recommends "$hpkg" 2>/dev/null; then
        hdeb="$(find / -xdev -maxdepth 6 -name "${hpkg}_*.deb" 2>/dev/null | head -1)"
        if [ -n "$hdeb" ]; then
            echo "Installing headers from local deb: $hdeb"
            dpkg -i "$hdeb" || apt-get -f install -y --no-install-recommends || true
        fi
    fi
fi
if ! dpkg-query -W -f='${Status}\n' "$hpkg" 2>/dev/null | grep -q '^install ok installed$'; then
    echo "WARN: $hpkg not installed — skipping NPU stack (DKMS would fail without headers)."
    exit 0
fi
echo "Kernel headers ready: $hpkg"

# --- 2. DKMS rknpu module ---
git clone --depth=1 https://github.com/w568w/rknpu-module.git /tmp/rknpu-module
mkdir -p /usr/src/rknpu-0.9.8
cp -r /tmp/rknpu-module/. /usr/src/rknpu-0.9.8/
rm -rf /tmp/rknpu-module

# Patch Kbuild to (a) drop rknpu_devfreq.o and (b) define
# RKNPU_NO_DEVFREQ globally. Armbian-current's kernel headers don't
# install linux/devfreq-governor.h (CONFIG_PM_DEVFREQ may be enabled
# but the governor header just isn't shipped in the headers package),
# so rknpu_devfreq.c fails to compile. rknpu_devfreq.h has inline
# stubs for all six devfreq functions, but they're only used when
# RKNPU_NO_DEVFREQ is defined — otherwise the function prototypes
# get declared, the .o is required, and linking fails with
# "undefined symbol: rknpu_devfreq_*". So we drop the .o AND set the
# define so stubs kick in everywhere callers reference these
# functions. Loses DVFS (NPU runs at fixed clock rate); functional
# inference is unaffected.
sed -i 's@src/rknpu_devfreq\.o@@g' /usr/src/rknpu-0.9.8/Kbuild
echo '# Force devfreq-stub path (no devfreq-governor.h in Armbian-current)' \
    >> /usr/src/rknpu-0.9.8/Kbuild
echo 'ccflags-y += -DRKNPU_NO_DEVFREQ' >> /usr/src/rknpu-0.9.8/Kbuild

# Switch the driver from DRM_GEM mode to DMA_HEAP mode so it registers
# as a misc device at /dev/rknpu — that's what librknnrt.so 2.3.2 opens.
# In DRM_GEM mode the driver instead creates only /dev/dri/renderD* /
# /dev/dri/card*, which librknnrt can't talk to.
#
# These two macros are *mutually exclusive* — rknpu_submit_ioctl has
# incompatible signatures under each — so the right move is to:
#   1. Strip upstream's -DCONFIG_ROCKCHIP_RKNPU_DRM_GEM from Kbuild
#   2. Add  -DCONFIG_ROCKCHIP_RKNPU_DMA_HEAP
#   3. Force-include a header that #undefs DRM_GEM after autoconf.h has
#      run (a bare -U in ccflags is processed before -include linux/
#      kconfig.h and gets overridden if the kernel config happens to
#      have the same symbol — belt-and-suspenders).
#   4. Drop a stub for linux/rk-dma-heap.h — Rockchip BSP-only header
#      not present in mainline; without it the DMA_HEAP code path
#      fails to compile. Stub returns sane "unavailable" values; heap
#      allocation degrades gracefully at runtime.
# All of this matches the production stack in schwankner/talos-rk3588-npu.

sed -i '/^ccflags-y += -DCONFIG_ROCKCHIP_RKNPU_DRM_GEM$/d' /usr/src/rknpu-0.9.8/Kbuild
echo 'ccflags-y += -DCONFIG_ROCKCHIP_RKNPU_DMA_HEAP' >> /usr/src/rknpu-0.9.8/Kbuild

# Force-include header — undef DRM_GEM after autoconf.h.
mkdir -p /usr/src/rknpu-0.9.8/src/include/compat/linux
cat > /usr/src/rknpu-0.9.8/src/include/compat/rknpu_build_config.h <<'CFGHDR'
/* SPDX-License-Identifier: GPL-2.0 */
/* Force-included via ccflags-y to override autoconf.h-set DRM_GEM. */
#ifdef CONFIG_ROCKCHIP_RKNPU_DRM_GEM
#undef CONFIG_ROCKCHIP_RKNPU_DRM_GEM
#endif
#ifndef CONFIG_ROCKCHIP_RKNPU_DMA_HEAP
#define CONFIG_ROCKCHIP_RKNPU_DMA_HEAP 1
#endif
CFGHDR
echo 'ccflags-y += -include $(src)/src/include/compat/rknpu_build_config.h' \
    >> /usr/src/rknpu-0.9.8/Kbuild

# rk-dma-heap.h compat stub — Rockchip BSP API, absent from mainline.
# All functions return safe "unavailable" sentinels so the DMA_HEAP path
# compiles and degrades to "no heap" at runtime. /dev/rknpu is still
# created via misc_register regardless of heap availability.
cat > /usr/src/rknpu-0.9.8/src/include/compat/linux/rk-dma-heap.h <<'DMAHDR'
/* SPDX-License-Identifier: GPL-2.0 */
#ifndef _LINUX_RK_DMA_HEAP_H
#define _LINUX_RK_DMA_HEAP_H
#include <linux/dma-buf.h>
#include <linux/device.h>
#include <linux/errno.h>
#include <linux/err.h>
struct rk_dma_heap;
static inline struct rk_dma_heap *rk_dma_heap_find(const char *name) { return NULL; }
static inline int rk_dma_heap_set_dev(struct device *heap_dev) { return -ENODEV; }
static inline struct dma_buf *
rk_dma_heap_buffer_alloc(struct rk_dma_heap *heap, size_t len,
                         unsigned int fd_flags, unsigned int heap_flags,
                         const char *name) { return ERR_PTR(-ENODEV); }
static inline void rk_dma_heap_buffer_free(struct dma_buf *dmabuf) {}
static inline int
rk_dma_heap_bufferfd_alloc(struct rk_dma_heap *heap, size_t len,
                           unsigned int fd_flags, unsigned int heap_flags,
                           const char *name) { return -ENODEV; }
static inline int
rk_dma_heap_alloc_contig_pages(struct rk_dma_heap *heap, size_t len,
                               unsigned int heap_flags, struct page **pages) { return -ENODEV; }
static inline void
rk_dma_heap_free_contig_pages(struct page **pages, size_t len) {}
static inline int rk_dma_heap_cma_setup(void) { return 0; }
#endif /* _LINUX_RK_DMA_HEAP_H */
DMAHDR

dkms add rknpu/0.9.8

# Build/install for every kernel version present in /lib/modules. In
# practice that's exactly one (the freshly-baked image's kernel). The
# loop tolerates per-kver build failures so a partial install (e.g. an
# older kernel missing headers) doesn't abort the whole image build.
# On build failure, dump make.log so the actual compile error is visible
# in the build log (otherwise the chroot is destroyed and the diagnostic
# is gone).
for kver in $(ls /lib/modules 2>/dev/null); do
    if ! dkms build rknpu/0.9.8 -k "$kver"; then
        echo "WARN: dkms build failed for $kver — full make.log:"
        cat "/var/lib/dkms/rknpu/0.9.8/build/make.log" 2>/dev/null | tail -200 || true
        echo "===== END make.log ====="
        continue
    fi
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
#include <dt-bindings/clock/rockchip,rk3588-cru.h>

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
        /* Names must match w568w/rknpu-module's of-property lookups
         * (rknpu_drv.c — irqs[].name = "npu0_irq" for multi-core RK3588). */
        interrupt-names = "npu0_irq", "npu1_irq", "npu2_irq";

        clocks = <&scmi_clk SCMI_CLK_NPU>;
        clock-names = "clk_npu";

        power-domains = <&power RK3588_PD_NPUTOP>,
                        <&power RK3588_PD_NPU1>,
                        <&power RK3588_PD_NPU2>;
        /* Driver attaches per-core PM domains via dev_pm_domain_attach_by_name
         * (rknpu_drv.c) using the strings "npu0"/"npu1"/"npu2". */
        power-domain-names = "npu0", "npu1", "npu2";

        iommus = <&rknn_mmu_0>, <&rknn_mmu_1>, <&rknn_mmu_2>;

        npu-supply = <&vdd_npu_s0>;
        sram-supply = <&vdd_npu_s0>;

        status = "okay";
    };
};
OVERLAY

# Compile the overlay against the running chroot's kernel headers.
# Output to Armbian's standard overlay dir.
# Armbian's u-boot boot.cmd loads `overlays=` (kernel-provided) from
# /boot/dtb/rockchip/overlay/, but `user_overlays=` (us) from
# /boot/overlay-user/. Wrong path = u-boot silently skips the overlay
# and the rknpu driver can't bind because the DT compatible never
# changes from the upstream rockchip,rk3588-rknn-core to the vendor
# rockchip,rk3588-rknpu we declare.
overlay_dir=/boot/overlay-user
mkdir -p "$overlay_dir"

# Need to preprocess for the #include / dt-bindings — use cpp + dtc.
# Armbian's headers deb installs source/headers under
# /usr/src/linux-headers-${KVER}-${BRANCH}-${FAMILY}, e.g.
# /usr/src/linux-headers-6.18.27-current-rockchip64. Glob and pick one.
header_dir="$(ls -d /usr/src/linux-headers-* 2>/dev/null | head -1)"
if [ -n "$header_dir" ] && [ -d "$header_dir/include" ]; then
    # cpp+dtc failure must NOT take down the whole image build — wrap
    # everything so a syntax error / missing dt-binding here just skips
    # overlay install with a WARN.
    if cpp -nostdinc -undef -x assembler-with-cpp \
            -I "$header_dir/include" \
            -o /tmp/rk3588-rknpu-opi5pro.dts.preprocessed \
            /usr/src/orangepi5pro-overlays/rk3588-rknpu-opi5pro.dts \
        && dtc -@ -I dts -O dtb \
            -o "$overlay_dir/rk3588-rknpu-opi5pro.dtbo" \
            /tmp/rk3588-rknpu-opi5pro.dts.preprocessed; then
        echo "DT overlay compiled: $overlay_dir/rk3588-rknpu-opi5pro.dtbo"
    else
        echo "WARN: DT overlay compile failed — NPU module will load but with no DT node to bind to."
    fi
    rm -f /tmp/rk3588-rknpu-opi5pro.dts.preprocessed
else
    echo "WARN: no kernel headers tree found at /usr/src/linux-headers-* — DT overlay not compiled."
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
