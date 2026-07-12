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

# Drop in Talos's rknpu_mem.c — upstream w568w doesn't ship this file
# at all (the memory-allocation ioctl backends rknpu_mem_create_ioctl,
# rknpu_mem_destroy_ioctl, rknpu_mem_sync_ioctl are *declared* but
# never *defined* upstream). Without it, modpost fails with three
# "undefined symbol" errors. Talos wrote a from-scratch ~700-line
# implementation for mainline (IOVA cursor, dma_alloc_noncontiguous,
# fallbacks for missing rk-dma-heap). GPL-2.0 same as the rest. Sourced
# from this repo's npu-patches/ dir, copied during chroot build.
install -m 0644 /usr/local/share/OrangePi5Pro/npu-patches/rknpu_mem.c \
    /usr/src/rknpu-0.9.8/src/rknpu_mem.c

# Drop in our reworked rknpu_devfreq.c — enables real voltage-coordinated
# DVFS on mainline. Changes vs upstream w568w (see npu-patches/ and the
# upstream PR draft): (1) a single devm_pm_opp_set_config() that probes
# the DT for rknpu-supply vs npu-supply and clk_npu vs scmi_clk so it
# binds whichever this DT uses; (2) a built-in conservative RK3588 OPP
# table registered via dev_pm_opp_add_dynamic when the DT carries no
# operating-points-v2; (3) clk_bulk_prepare_enable() around
# dev_pm_opp_set_rate() so the NPU housekeeping clocks (pclk_npu_root ->
# pclk_npu_grf, pvtm) are running when TF-A's SCMI CLK_NPU set_rate
# programs the NPU PVTPLL over APB — without them held the EL3 access
# hard-wedges the whole SoC. The overlay below lists those pclks in the
# NPU clock bulk so the driver holds them whenever the NPU is powered.
install -m 0644 /usr/local/share/OrangePi5Pro/npu-patches/rknpu_devfreq.c \
    /usr/src/rknpu-0.9.8/src/rknpu_devfreq.c

# Vendor the devfreq governor header. rknpu_devfreq.c includes
# <linux/devfreq-governor.h>, which is drivers/devfreq/governor.h in the
# kernel tree and is NOT shipped in any distro kernel-headers package
# (this is the sole reason the previous build had to stub DVFS out with
# RKNPU_NO_DEVFREQ). Every symbol it declares (devfreq_add_governor,
# devfreq_remove_governor, update_devfreq) IS exported by the kernel —
# only the header is missing. Verbatim copy of governor.h @ v6.18,
# GPL-2.0, force-found ahead of the (absent) system one via the existing
# -I$(src)/src/include/compat include path.
# -D: create the compat/linux/ dir if it doesn't exist yet — this install
# runs before the mkdir further down (which sets it up for rk-dma-heap.h).
install -D -m 0644 /usr/local/share/OrangePi5Pro/npu-patches/devfreq-governor.h \
    /usr/src/rknpu-0.9.8/src/include/compat/linux/devfreq-governor.h

# Patch rknpu_debugger.c: NULL-guard rknpu_dev->vdd in rknpu_volt_show —
# reading the debugfs `volt` node oopses the kernel when the OPP core
# hasn't bound a regulator yet (same class of bug as the GET_VOLT ioctl
# guard below).
sed -i 's@^\(\s*\)current_volt = regulator_get_voltage(rknpu_dev->vdd);@\1current_volt = rknpu_dev->vdd ? regulator_get_voltage(rknpu_dev->vdd) : 0;@' \
    /usr/src/rknpu-0.9.8/src/rknpu_debugger.c
grep -q 'rknpu_dev->vdd ? regulator_get_voltage' /usr/src/rknpu-0.9.8/src/rknpu_debugger.c \
    || { echo "ERROR: rknpu_volt_show NULL-guard patch did not apply" >&2; exit 1; }

# Patch rknpu_gem.c: rknpu_gem_sync_ioctl uses rknpu_dev->fake_dev
# unconditionally, but the field is only declared under
# CONFIG_ROCKCHIP_RKNPU_DRM_GEM. In our DMA_HEAP build this function is
# dead code (it's a DRM ioctl handler, never reached when no DRM device
# exists), but the compiler still type-checks it. Swap the references
# to rknpu_dev->dev (which always exists) so the file compiles. This
# is a known upstream w568w gap that Talos patches similarly.
sed -i 's/rknpu_dev->fake_dev/rknpu_dev->dev/g' /usr/src/rknpu-0.9.8/src/rknpu_gem.c

# Patch rknpu_drv.c: the RKNPU_GET_VOLT ioctl derefs rknpu_dev->vdd without
# a NULL check, which oopses the kernel on this board. probe() acquires the
# supply with devm_regulator_get_optional(dev, "rknpu") — that looks for a DT
# property named `rknpu-supply`, but the mainline rk3588s DT names it
# `npu-supply`. The lookup returns -ENODEV, probe() sets ->vdd = NULL and
# carries on (it's an *optional* regulator), and then the ioctl handler
# dereferences it. Every other consumer of ->vdd guards with `if
# (rknpu_dev->vdd)`; only the ioctl path doesn't. Any process that can open
# /dev/rknpu can panic the kernel with a single ioctl, so this must land
# alongside the udev rule below that opens the node up to the render group.
sed -i 's@^\(\s*\)args->value = regulator_get_voltage(rknpu_dev->vdd);@\1args->value = rknpu_dev->vdd ? regulator_get_voltage(rknpu_dev->vdd) : 0;@' \
    /usr/src/rknpu-0.9.8/src/rknpu_drv.c
grep -q 'rknpu_dev->vdd ? regulator_get_voltage' /usr/src/rknpu-0.9.8/src/rknpu_drv.c \
    || { echo "ERROR: RKNPU_GET_VOLT NULL-guard patch did not apply" >&2; exit 1; }

# Patch rknpu_drv.c: the batched-ioctl wrapper clobbers MEM_CREATE's results.
# w568w's misc ioctl handler copies user args into a local `kdata` union,
# dispatches, then unconditionally copies kdata back on any _IOC_READ ioctl.
# But the RKNPU_MEM_* handlers take the raw user pointer and write their own
# results (obj_addr / dma_addr) directly — so the blanket copy-back then
# overwrites them with the stale *input* snapshot (obj_addr=0, dma_addr=0).
# librknnrt consequently issues RKNPU_MEM_SYNC with obj_addr=0 and
# RKNPU_SUBMIT with task_obj_addr=0, both -> EINVAL, and NO model can run.
# Restrict the copy-back to the only two handlers actually dispatched via
# &kdata (ACTION and SUBMIT). Verified: mobilenet inference goes from
# 0 (EINVAL) to ~111 inferences/s after this.
python3 <<'PYPATCH'
path = "/usr/src/rknpu-0.9.8/src/rknpu_drv.c"
with open(path) as f:
    src = f.read()
old = "\tif (ret == 0 && (dir & _IOC_READ)) {\n"
new = ("\tif (ret == 0 && (dir & _IOC_READ) &&\n"
       "\t    (_IOC_NR(cmd) == RKNPU_ACTION || _IOC_NR(cmd) == RKNPU_SUBMIT)) {\n")
if old not in src:
    raise SystemExit("ERROR: rknpu_drv.c ioctl copy-back block not found — upstream changed?")
with open(path, "w") as f:
    f.write(src.replace(old, new, 1))
print("patched rknpu_drv.c: ioctl copy-back restricted to ACTION/SUBMIT")
PYPATCH

# Patch rknpu_drv.c / rknpu_job.c / include/rknpu_drv.h: apply the verified
# multi-core NPU fix (npu-patches/rknpu-multicore.patch). It restores the
# RK3588 config .core_mask to 0x7 (all three cores) behind a RUNTIME coverage
# gate — rknpu_effective_core_mask() auto-limits to core 0 unless the bound
# IOMMU's reg banks actually span the core1/core2 MMU banks (0xfdaca000 /
# 0xfdada000), i.e. the 4-bank overlay below is active — and pre-powers the
# NPU core power domains + core1/core2 bus clocks in rknpu_init() (module
# load) so the shared mainline rk_iommu can program cores 1/2's MMU banks
# without a synchronous external abort. The gate makes the driver SAFE under
# ANY overlay: single-IOMMU DT -> core 0 only; 4-bank DT -> full 0x7.
# Verified on OPi 5 Pro hardware (all three cores translate; MobileNet class
# 156 at masks 0x1/0x2/0x4/0x7; ~558 inf/s at 0x7).
#
# The patch's first hunk rewrites the exact pre-image line
#   .core_mask = 0x1, /* single-IOMMU DT: core0 only */
# (the tree state it was generated against). Pristine w568w ships
# `.core_mask = 0x7,`, so first normalize that line to the patch's expected
# pre-image; the VERBATIM patch then rewrites it to
#   .core_mask = 0x7, /* effective mask gated at probe by IOMMU coverage */
# i.e. the shipped driver is multi-core, gated safe. Only rk3588 uses 0x7,
# so the normalizing sed is unambiguous.
sed -i 's@^\(\s*\)\.core_mask = 0x7,@\1.core_mask = 0x1, /* single-IOMMU DT: core0 only */@' \
    /usr/src/rknpu-0.9.8/src/rknpu_drv.c
grep -q '\.core_mask = 0x1, /\* single-IOMMU' /usr/src/rknpu-0.9.8/src/rknpu_drv.c \
    || { echo "ERROR: could not establish multi-core patch pre-image (rk3588 .core_mask line)" >&2; exit 1; }

echo "=== applying multi-core NPU patch (npu-patches/rknpu-multicore.patch) ==="
patch -p1 -d /usr/src/rknpu-0.9.8/src \
    < /usr/local/share/OrangePi5Pro/npu-patches/rknpu-multicore.patch \
    || { echo "ERROR: rknpu-multicore.patch FAILED to apply cleanly" >&2; exit 1; }

# Assert the multi-core end-state landed — fail the build loudly otherwise.
grep -q '\.core_mask = 0x7, /\* effective mask gated' /usr/src/rknpu-0.9.8/src/rknpu_drv.c \
    || { echo "ERROR: multi-core .core_mask (0x7) missing after patch" >&2; exit 1; }
grep -q 'rknpu_effective_core_mask' /usr/src/rknpu-0.9.8/src/rknpu_drv.c \
    || { echo "ERROR: rknpu_effective_core_mask coverage gate missing after patch" >&2; exit 1; }
grep -q 'rknpu_preinit_power_domains' /usr/src/rknpu-0.9.8/src/rknpu_drv.c \
    || { echo "ERROR: rknpu_preinit_power_domains missing after patch" >&2; exit 1; }
echo "multi-core NPU patch applied: .core_mask=0x7 gated by rknpu_effective_core_mask"

# Patch rknpu_drv.c: probe() bails with -ENOMEM if rk_dma_heap_find
# returns NULL for "rk-dma-heap-cma" (the BSP-only heap doesn't exist
# on mainline, so our stub always returns NULL — the driver never
# reaches probe-success and /dev/rknpu is never created). Convert the
# fatal check into a warning so probe completes and Talos's vendored
# rknpu_mem.c handles the missing heap at runtime via its IOVA-cursor
# fallback. dmesg before this patch:
#   RKNPU fdab0000.npu: RKNPU: failed to find cma heap
#   RKNPU fdab0000.npu: probe with driver RKNPU failed with error -12
python3 <<'PYPATCH'
path = "/usr/src/rknpu-0.9.8/src/rknpu_drv.c"
with open(path) as f:
    src = f.read()
old = (
    '\trknpu_dev->heap = rk_dma_heap_find("rk-dma-heap-cma");\n'
    '\tif (!rknpu_dev->heap) {\n'
    '\t\tLOG_DEV_ERROR(dev, "failed to find cma heap\\n");\n'
    '\t\tret = -ENOMEM;\n'
    '\t\tgoto err_remove_drv;\n'
    '\t}\n'
    '\trk_dma_heap_set_dev(dev);'
)
new = (
    '\trknpu_dev->heap = rk_dma_heap_find("rk-dma-heap-cma");\n'
    '\tif (!rknpu_dev->heap)\n'
    '\t\tdev_info(dev, "no cma heap; using mainline fallback at runtime\\n");\n'
    '\telse\n'
    '\t\trk_dma_heap_set_dev(dev);'
)
if old not in src:
    raise SystemExit("ERROR: rknpu_drv.c CMA-heap probe block not found — upstream changed?")
with open(path, "w") as f:
    f.write(src.replace(old, new))
print("patched rknpu_drv.c: CMA heap missing is now non-fatal at probe")
PYPATCH

# Patch Kbuild: add src/rknpu_mem.o to the obj list (we dropped in its
# .c above; upstream declares but never defines it). Append after
# src/rknpu_iommu.o, an existing entry. rknpu_devfreq.o stays in the
# build — DVFS is now enabled (we vendored the missing governor header
# above), so we do NOT drop it and do NOT define RKNPU_NO_DEVFREQ.
sed -i '0,/src\/rknpu_iommu\.o/{s@src/rknpu_iommu\.o@& src/rknpu_mem.o@}' \
    /usr/src/rknpu-0.9.8/Kbuild

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
// DT overlay: multi-core RK3588 NPU for the w568w/rknpu-module driver.
//
// Same as rk3588-rknpu-opi5pro.dts (single vendor rknpu node replacing the
// mainline rocket nodes) EXCEPT the IOMMU topology: instead of binding the
// NPU to core0's MMU only, fold ALL FOUR NPU MMU banks into the single
// rknn_mmu_0 iommu node.  Mainline rockchip-iommu programs every "reg" bank
// of one node with the same page table (num_mmu = #reg entries), so all
// three cores translate through one DMA domain — no core is left on a
// bypassed MMU.  The driver detects the 4-bank node at probe and lifts its
// core mask from 0x1 to 0x7 (see rknpu_effective_core_mask in rknpu_drv.c).
//
// Power/clock safety: rknpu_power_on() enables the full clock bulk (incl.
// aclk/hclk for NPU1/NPU2) and syncs all three power domains via the genpd
// virtual devices BEFORE its pm_runtime_get_sync(dev), which is what
// resumes the iommu (device-link supplier) and programs the banks.  So the
// core1/core2 MMU banks are only ever touched powered + clocked.

/dts-v1/;
/plugin/;

#include <dt-bindings/interrupt-controller/arm-gic.h>
#include <dt-bindings/power/rk3588-power.h>
#include <dt-bindings/clock/rockchip,rk3588-cru.h>

/ {
    compatible = "rockchip,rk3588";
};

/* Disable mainline rocket per-core nodes. */
&rknn_core_0 { status = "disabled"; };
&rknn_core_1 { status = "disabled"; };
&rknn_core_2 { status = "disabled"; };

/* Core1/core2 MMU banks are folded into rknn_mmu_0 below; their standalone
 * nodes must be disabled or their probes would claim the same MMIO regions
 * (devm_ioremap_resource -EBUSY) and last-wins of_xlate could rebind the
 * NPU to a bank-1-only IOMMU. */
&rknn_mmu_1 { status = "disabled"; };
&rknn_mmu_2 { status = "disabled"; };

/* One iommu device managing every NPU MMU bank:
 *   fdab9000 / fdaba000 : core0 (two MMU instances, already both in the
 *                         mainline node — proof multi-bank works)
 *   fdaca000            : core1
 *   fdada000            : core2
 * Each bank's fault IRQ is the line it shares with its NPU core (110/111/
 * 112); both rk_iommu and rknpu request them IRQF_SHARED.  The node keeps
 * its own aclk/iface (ACLK_NPU0/HCLK_NPU0) and NPUTOP power domain: banks
 * in NPU1/NPU2 domains are powered/clocked by the rknpu node's held clock
 * bulk + genpd refs whenever they are programmed (see header comment). */
&rknn_mmu_0 {
    reg = <0x0 0xfdab9000 0x0 0x100>,
          <0x0 0xfdaba000 0x0 0x100>,
          <0x0 0xfdaca000 0x0 0x100>,
          <0x0 0xfdada000 0x0 0x100>;
    interrupts = <GIC_SPI 110 IRQ_TYPE_LEVEL_HIGH 0>,
                 <GIC_SPI 111 IRQ_TYPE_LEVEL_HIGH 0>,
                 <GIC_SPI 112 IRQ_TYPE_LEVEL_HIGH 0>;
};

&{/} {
    npu_opp: opp-table-npu {
        compatible = "operating-points-v2";

        /* RK3588 NPU OPPs. Voltages are rounded UP from Rockchip's BSP
         * worst-bin values (300-600 MHz: 675 mV, 700: 700, 800: 750,
         * 900: 800, 1000: 850 mV) for margin, and never below the
         * 800 mV the rail already runs at. vdd_npu_s0's own DT
         * constraints (550-950 mV) cap everything. dev_pm_opp_set_rate
         * raises the regulator to opp-microvolt BEFORE the clock on the
         * way up, so a high clock is never applied at low voltage.
         * Validated on OPi 5 Pro: stable + correct (MobileNet class 156)
         * at every step 300->1000 MHz; 1000 MHz @ 950 mV = 3.7x the
         * 200 MHz throughput, <52 C. */
        opp-300000000 { opp-hz = /bits/ 64 <300000000>; opp-microvolt = <800000 800000 950000>; };
        opp-400000000 { opp-hz = /bits/ 64 <400000000>; opp-microvolt = <800000 800000 950000>; };
        opp-500000000 { opp-hz = /bits/ 64 <500000000>; opp-microvolt = <825000 825000 950000>; };
        opp-600000000 { opp-hz = /bits/ 64 <600000000>; opp-microvolt = <850000 850000 950000>; };
        opp-700000000 { opp-hz = /bits/ 64 <700000000>; opp-microvolt = <875000 875000 950000>; };
        opp-800000000 { opp-hz = /bits/ 64 <800000000>; opp-microvolt = <900000 900000 950000>; };
        opp-900000000 { opp-hz = /bits/ 64 <900000000>; opp-microvolt = <925000 925000 950000>; };
        opp-1000000000 { opp-hz = /bits/ 64 <1000000000>; opp-microvolt = <950000 950000 950000>; };
    };

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

        /* clk_npu (SCMI) is the NPU compute clock, but each core's
         * register interface is clocked by aclk_npuN/hclk_npuN — and on
         * mainline those clocks belong to the *iommu* nodes, not the NPU
         * node. devm_clk_bulk_get_all() on this node therefore only grabbed
         * clk_npu, leaving the bus clocks to gate whenever the per-core
         * iommu was runtime-suspended. Result: reads of the core register
         * block (e.g. the HW-version register at offset 0) returned 0, so
         * librknnrt misdetected the SoC as RK3566/68 and refused to load any
         * RK3588 model. Listing the six bus clocks here makes power_on's
         * clk_bulk_prepare_enable() hold them on for the whole powered
         * window. clk_npu must stay first — the driver reports FREQ from
         * clks[0].
         *
         * The pclk/pvtm group (PCLK_NPU_ROOT, PCLK_NPU_GRF, the two PVTM
         * clocks, HCLK_NPU_ROOT) is the DVFS-safety set. TF-A's SCMI
         * CLK_NPU set_rate programs the NPU PVTPLL through the NPU GRF
         * over APB; mainline gates pclk_npu_root as unused at boot, and
         * an EL3 APB access through a gated pclk hard-wedges the whole
         * SoC — so ANY NPU frequency change hangs the machine unless
         * these are held (reproduced on OPi 5 Pro: raw set_rate to
         * 300 MHz wedged it; holding these + set_rate is stable to
         * 1000 MHz). Listing them here makes the driver's own
         * clk_bulk_prepare_enable() in power_on hold them whenever the
         * NPU is powered, which is exactly when a set_rate can occur. */
        clocks = <&scmi_clk SCMI_CLK_NPU>,
                 <&cru ACLK_NPU0>, <&cru ACLK_NPU1>, <&cru ACLK_NPU2>,
                 <&cru HCLK_NPU0>, <&cru HCLK_NPU1>, <&cru HCLK_NPU2>,
                 <&cru PCLK_NPU_ROOT>, <&cru PCLK_NPU_GRF>,
                 <&cru PCLK_NPU_PVTM>, <&cru CLK_NPU_PVTM>,
                 <&cru CLK_CORE_NPU_PVTM>, <&cru HCLK_NPU_ROOT>;
        clock-names = "clk_npu", "aclk0", "aclk1", "aclk2",
                      "hclk0", "hclk1", "hclk2",
                      "pclk", "pclk_grf", "pclk_pvtm", "clk_pvtm",
                      "clk_core_pvtm", "hclk_root";

        /* The mainline rknn_core_0 node this overlay merges into carries
         * assigned-clock-rates = <200000000> on SCMI_CLK_NPU, which
         * of_clk_set_defaults applies on EVERY driver bind (of_clk.c
         * only calls clk_set_rate when the rate is non-zero). Once the
         * NPU has been raised above 200 MHz, a module reload would then
         * issue an SCMI CLK_NPU rate change at bind time — before the
         * driver has enabled its clock bulk — with pclk_npu_root/grf
         * potentially gated, and hard-wedge the SoC. Overriding the rate
         * to <0> makes of_clk_set_defaults skip the clock entirely: the
         * NPU keeps whatever rate firmware left (cold boot: the TF-A
         * default) until devfreq raises it through the safe, pclk-held
         * path. */
        assigned-clocks = <&scmi_clk SCMI_CLK_NPU>;
        assigned-clock-rates = <0>;

        power-domains = <&power RK3588_PD_NPUTOP>,
                        <&power RK3588_PD_NPU1>,
                        <&power RK3588_PD_NPU2>;
        /* Driver attaches per-core PM domains via dev_pm_domain_attach_by_name
         * (rknpu_drv.c) using the strings "npu0"/"npu1"/"npu2". */
        power-domain-names = "npu0", "npu1", "npu2";

        /* Single iommu phandle -> the 4-bank rknn_mmu_0 node above.
         * of_xlate binds the NPU to that one iommu device; rk_iommu
         * programs all four banks with the same page table, so cores
         * 0/1/2 all translate through the same DMA domain. */
        iommus = <&rknn_mmu_0>;

        operating-points-v2 = <&npu_opp>;

        /* Same rail under both names. The driver's own vdd lookup and
         * the RKNPU_GET_VOLT ioctl use "rknpu" (vendor-style); the OPP
         * regulator binding in rknpu_devfreq.c probes both "rknpu" and
         * "npu" and uses whichever resolves. Providing both aliases
         * keeps every consumer happy. */
        npu-supply = <&vdd_npu_s0>;
        rknpu-supply = <&vdd_npu_s0>;
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

# --- 4b. NPU DVFS: pin the production frequency at boot ---
# The rknpu devfreq path is voltage-coordinated (dev_pm_opp_set_rate
# raises vdd_npu_s0 to the OPP voltage before the clock on the way up)
# and the driver holds the NPU pclk/pvtm clocks while powered (overlay
# above), so writing a target rate to the devfreq debugfs node is safe
# and stays pinned (the rknpu_ondemand governor forwards whatever was
# last requested; job submission never changes it). We pin 800 MHz @
# 900 mV — ~3.5x the 200 MHz boot default on MobileNet, 50 mV under the
# rail ceiling, thermally trivial. Bump NPU_FREQ_HZ to 1000000000 for
# max throughput (validated stable @ 950 mV) if you don't mind running
# at the regulator max.
#
# This is applied POST-boot (oneshot after multi-user), never at boot
# before the driver is ready — a high clock must not be programmed while
# the pclks are still gated during early boot.
install -m 0644 /usr/local/share/OrangePi5Pro/orangepi-npu-performance.service \
    /etc/systemd/system/orangepi-npu-performance.service
systemctl enable orangepi-npu-performance.service || \
    ln -sf /etc/systemd/system/orangepi-npu-performance.service \
        /etc/systemd/system/multi-user.target.wants/orangepi-npu-performance.service

# Optional belt-and-suspenders: a tiny module that holds the NPU pclk/
# pvtm clocks enabled independently of the driver. With the overlay's
# clock list the driver already holds them whenever the NPU is powered
# (verified: set_rate to 1000 MHz is stable with this module absent), so
# this is redundant — but the systemd unit modprobes it (non-fatal) as a
# second guarantee that a frequency raise can never wedge the SoC due to
# runtime-PM timing. Built as a plain out-of-tree module (not DKMS; it
# has no ABI surface and is trivial to rebuild).
kver_hold="$(ls /lib/modules 2>/dev/null | head -1)"
if [ -n "$kver_hold" ] && [ -d "/lib/modules/$kver_hold/build" ]; then
    holddir="$(mktemp -d)"
    install -m 0644 /usr/local/share/OrangePi5Pro/npu-patches/npu_pclk_hold.c \
        "$holddir/npu_pclk_hold.c"
    printf 'obj-m := npu_pclk_hold.o\n' > "$holddir/Kbuild"
    if make -C "/lib/modules/$kver_hold/build" M="$holddir" modules >/dev/null 2>&1; then
        install -D -m 0644 "$holddir/npu_pclk_hold.ko" \
            "/lib/modules/$kver_hold/updates/npu_pclk_hold.ko"
        depmod -a "$kver_hold" || true
        echo "npu_pclk_hold.ko installed for $kver_hold"
    else
        echo "WARN: npu_pclk_hold.ko build failed — driver still holds pclks via overlay; safety-net absent."
    fi
    rm -rf "$holddir"
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

# misc_register() creates /dev/rknpu as 0600 root:root, so librknnrt.so
# (which opens /dev/rknpu by name) gets EACCES for any non-root caller.
# Hand it to the render group — Armbian already puts the first user in
# both video and render.
# librknnrt also allocates NPU buffers from the mainline DMA-BUF heaps
# (it opens /dev/dma_heap/system directly), and those nodes are likewise
# created 0600 root:root. Hand the heaps to render too, else non-root
# inference dies at "Failed to open DMA heap: /dev/dma_heap/system".
cat > /etc/udev/rules.d/99-rknpu.rules <<'UDEV'
KERNEL=="rknpu", MODE="0660", GROUP="render"
SUBSYSTEM=="dma_heap", MODE="0660", GROUP="render"
UDEV
chmod 0644 /etc/udev/rules.d/99-rknpu.rules

# --- 6. librknnrt.so userspace runtime ---
# v2.3.2 (April 2025) from airockchip/rknn-toolkit2. Stable across 2.x.x
# releases, ABI-compatible with rknpu module 0.9.8/0.9.10.
curl -fsSL --retry 3 \
    https://github.com/airockchip/rknn-toolkit2/raw/v2.3.2/rknpu2/runtime/Linux/librknn_api/aarch64/librknnrt.so \
    -o /usr/lib/librknnrt.so
chmod 0644 /usr/lib/librknnrt.so
ldconfig

# --- 7. rknn_server (connected-mode inference / RKNN-Toolkit2 profiling) ---
# Lets a host PC run/profile models on this board over adb/network via
# RKNN-Toolkit2. Shipped but NOT auto-started (it's a dev/debug tool).
for f in rknn_server start_rknn.sh restart_rknn.sh; do
    curl -fsSL --retry 3 \
        "https://github.com/airockchip/rknn-toolkit2/raw/v2.3.2/rknpu2/runtime/Linux/rknn_server/aarch64/usr/bin/$f" \
        -o "/usr/bin/$f" && chmod 0755 "/usr/bin/$f" \
        || echo "WARN: failed to fetch $f"
done

# --- 8. NPU benchmark + sample model (orangepi-npu-benchmark) ---
# Dependency-free throughput probe: loads librknnrt + a MobileNet v1 model,
# runs N inferences on zeroed input, reports latency/throughput. Also the
# quickest way to confirm the NPU runtime path end to end.
mkdir -p /usr/local/share/rknn-benchmark
curl -fsSL --retry 3 \
    https://github.com/airockchip/rknn-toolkit2/raw/v2.3.2/rknpu2/examples/rknn_mobilenet_demo/model/RK3588/mobilenet_v1.rknn \
    -o /usr/local/share/rknn-benchmark/mobilenet_v1.rknn
curl -fsSL --retry 3 \
    https://github.com/airockchip/rknn-toolkit2/raw/v2.3.2/rknpu2/runtime/Linux/librknn_api/include/rknn_api.h \
    -o /tmp/rknn_api.h
install -m 0644 /usr/local/share/OrangePi5Pro/npu-patches/npu_benchmark.c /tmp/npu_benchmark.c
if gcc -O2 -I/tmp -o /usr/local/bin/orangepi-npu-benchmark /tmp/npu_benchmark.c -lrknnrt -lm; then
    chmod 0755 /usr/local/bin/orangepi-npu-benchmark
    echo "NPU benchmark installed: orangepi-npu-benchmark"
else
    echo "WARN: orangepi-npu-benchmark failed to compile"
fi
rm -f /tmp/npu_benchmark.c /tmp/rknn_api.h

echo "RKNPU stack installed: DKMS module 0.9.8, librknnrt 2.3.2, overlay rk3588-rknpu-opi5pro."
