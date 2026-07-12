# Multi-core RK3588 NPU on a *mainline* kernel (all 3 cores) — with the vendor rknpu driver

**TL;DR:** On a mainline kernel, the vendor `rknpu` driver only ever ran NPU core 0. The blocker is an interaction between mainline `rockchip-iommu`'s runtime-PM ordering and the NPU's per-core power domains — not anything in this driver. I got all three cores working (verified: correct output on `core_mask` 0x1/0x2/0x4/0x7, ~558 inf/s at 0x7 vs ~385 single-core) with **no in-tree kernel patch** — just a change in this module plus a devicetree overlay. Patch + overlay below.

Context: Orange Pi 5 Pro (RK3588), mainline **6.18**, `rknpu-module` 0.9.8, `librknnrt` 2.3.2. This is the RKNN/`librknnrt` stack — separate from the mainline "rocket" DRM-accel driver (which already does 3 cores but uses Mesa Teflon / TF-Lite, not `.rknn`).

## The problem

The RK3588 NPU has three cores, each with its own MMU bank and its **own power domain** (`PD_NPU0`/`NPUTOP`, `PD_NPU1`, `PD_NPU2`). To drive all three through one translation domain, the natural devicetree is a single `rockchip,iommu` node whose `reg` lists all the banks. That node probes fine (all banks `ioremap`'d). But the moment the NPU driver attaches:

```
Internal error: synchronous external abort
pc : rk_iommu_enable_stall+0x3c/0x1c8
      rk_iommu_enable+0x58/0x398
      rk_iommu_resume+0x34/0x50
```
genpd at fault: `NPUTOP on, NPU1 off, NPU2 off`.

## Root cause

The single mainline `rk_iommu` that manages all NPU MMU banks is a **`DL_FLAG_PM_RUNTIME` device-link supplier** of the NPU platform device. The driver core therefore resumes the IOMMU in `really_probe()`'s `pm_runtime_get_suppliers()` — **before `rknpu_probe()` runs** — and `rk_iommu_enable()` unconditionally programs *every* bank. Core 1/2's banks are in `PD_NPU1`/`PD_NPU2`, still powered off at that instant, so the APB access is a bus abort. (Core 0 survives because its two MMU instances share `PD_NPUTOP`.)

Nothing inside `rknpu_probe()` can prevent this — by the time probe runs, the faulting resume has already happened.

The obvious alternative — three separate `iommus` phandles — is worse: mainline `rk_iommu`'s `of_xlate` is **last-wins**, so the NPU binds to only the last IOMMU and the other cores run with their MMU in **bypass**, emitting IOVAs as raw physical addresses (silent memory corruption, not a fault).

## The fix (module + overlay only)

Two pieces:

1. **Devicetree overlay** — fold all NPU MMU banks into a *single* IOMMU node (`reg = <fdab9000 .. fdaba000 .. fdaca000 .. fdada000 ..>`, 0x100 each), disable the per-core MMU nodes. Mainline `rockchip-iommu` programs every `reg` bank of one node with the same page table (`num_mmu = #reg entries`), so all three cores share one DMA domain — no bypass.

2. **Driver patch** — the only module hook that runs *before* the driver core resumes the IOMMU supplier is `module_init`. So in `rknpu_init()` (before `platform_driver_register()`), pre-attach and power `PD_NPU0/1/2` **and** hold the core1/core2 bus clocks (`aclk/hclk_npu1/2` — `rk_iommu` only ungates its own NPU0 clocks). `rknpu_probe()` then borrows those handles. `.core_mask` is restored to `0x7` behind a **runtime coverage gate** (`rknpu_effective_core_mask`) that checks whether the bound IOMMU's `reg` actually spans the core1/core2 banks — if not (e.g. a single-core DT), it clamps to core 0. So the patched driver is safe under *any* devicetree.

## Verification (Orange Pi 5 Pro, mainline 6.18.38, fresh flash, no manual steps)

- All three MMUs attached, none bypassed — `core_mask` 0x1, 0x2, 0x4, and 0x7 each classify MobileNet v1 to the correct class over 500+ loops. Running core-1-only and core-2-only correctly is the proof their MMUs translate.
- No `rk_iommu` faults under stress; ~50 °C.
- Throughput at 800 MHz: **~558 inf/s at `core_mask` 0x7** vs ~385 single-core/auto (gain scales with model size / parallelism).
- dmesg: `pre-powered NPU core power domains before driver bind (npu0=ok npu1=ok npu2=ok)`.

## Caveats

- The coverage gate keys on the two hard-coded core1/core2 MMU base addresses (`0xfdaca000` / `0xfdada000`) — RK3588-specific, which is fine since `core_mask > 1` is RK3588-only anyway.
- This is a workaround for how mainline `rockchip-iommu` models power domains vs. the vendor single-node topology; it is not a kernel fix. (Mainline's own path for multi-core NPU is the separate `rocket` driver, which structures each core as its own device.)

Files in this repo:
- Driver patch: [`npu-patches/rknpu-multicore.patch`](../npu-patches/rknpu-multicore.patch)
- Overlay (standalone reference): [`npu-patches/rk3588-rknpu-mc-4bank.dts`](../npu-patches/rk3588-rknpu-mc-4bank.dts). In the built image the same overlay ships as `rk3588-rknpu-opi5pro` via `customize-image-npu.sh`.

Shipped in the Orange Pi 5 Pro image as of **v1.9.0**. Happy to send this upstream to [`w568w/rknpu-module`](https://github.com/w568w/rknpu-module) as a PR.
