# Ubuntu 26.04 on Orange Pi 5 Pro

A working recipe to build and run **Ubuntu 26.04 LTS (Resolute Raccoon)** on the Orange Pi 5 Pro (Rockchip RK3588S), using Armbian's build framework with the **mainline (`current`)** Linux kernel for working GPU acceleration.

As of May 2026 there is no off-the-shelf 26.04 image for this board. [Joshua Riek's `ubuntu-rockchip`](https://github.com/Joshua-Riek/ubuntu-rockchip) was archived on 29 April 2026, [Armbian's downloads page for the 5 Pro](https://www.armbian.com/orange-pi-5-pro/) only ships Debian Trixie, and Orange Pi's official downloads top out at 24.04. So we build it ourselves.

## Just want the image?

Skip everything below and grab a prebuilt 26.04 image from the [latest release page](https://github.com/mack42/OrangePi5Pro/releases/latest) — flash it with [balenaEtcher](https://etcher.balena.io/) and you're done. SHA-256 is in the matching `.sha` file. Continue reading only if you want to rebuild it yourself or understand why it's needed.

## Why this is two builds plus a patch

Ubuntu 26.04 ships **`rust-coreutils` (uutils)** as the default coreutils. The uutils binaries use `rustix`, which crashes during startup with:

```
thread 'main' panicked at rustix/.../auxv.rs:269:
called `Result::unwrap()` on an `Err` value: ()
```

…whenever launched through `chroot` on certain Rockchip vendor kernels. Tested on both `6.1.43-rockchip-rk3588` (stock OPi vendor) and `6.1.115-vendor-rk35xx` (Armbian vendor); both panic. The very first chroot operation in Armbian's build (linking `armbian-archive-keyring.gpg` into `/usr/share/keyrings/`) hits this and the build dies.

Two layers of problem stack on top of that:

1. **Stock OPi 22.04 kernel doesn't have `CONFIG_BINFMT_MISC` at all** — not built-in, no module on disk:
   ```
   $ grep BINFMT_MISC /boot/config-$(uname -r)
   # CONFIG_BINFMT_MISC is not set
   ```
   So you can't even register `qemu-aarch64` for binfmt-misc routing. Armbian's build can't shim around the uutils panic.
2. **Even on Armbian's 6.1.115 vendor kernel** (which has `CONFIG_BINFMT_MISC=m`), Armbian's build framework explicitly skips qemu setup on native-arch builds (`if dpkg-architecture -e "${ARCH}"; then return 0`), so `qemu-aarch64-static` is never deployed into the chroot, and uutils panics anyway.

The recipe therefore needs two components:

1. **A 24.04 (noble) stepping-stone image** so we can boot a kernel with `CONFIG_BINFMT_MISC` available. Noble itself uses GNU coreutils, so Step 1 of the build doesn't hit the uutils panic.
2. **A small patch (`apply-uutils-shim.sh`)** for the resolute build that swaps the `/usr/bin/*` uutils symlinks for a tiny shell shim routing through `qemu-aarch64-static`, then restores the original symlinks after all chroot operations are done. The final 26.04 image ships clean uutils — no qemu emulation at runtime.

So the recipe is:

1. **Build Armbian Ubuntu 24.04 (noble)** on the stock Orange Pi vendor system. (~3-5 h cold; ~3 min with caches)
2. **Flash 24.04 to microSD, boot from it.**
3. **Build Armbian Ubuntu 26.04 (resolute)** from the booted 24.04 system. `02-build-resolute.sh` applies the patch automatically and defaults to `BRANCH=current` (~8-15 min total — Armbian's CI publishes a prebuilt mainline kernel deb).
4. Flash 26.04 wherever you want it (microSD, USB SSD, eMMC).

## Prerequisites

- Orange Pi 5 Pro (16 GB RAM strongly recommended; 4/8 GB will work, slower)
- A microSD card or USB SSD ≥ 4 GB (≥ 16 GB recommended)
- ~50 GB free disk on the build host
- Stock Orange Pi vendor Ubuntu 22.04 image as starting point (other hosts work but the recipe assumes this)

## Step 1 — Build Armbian noble (24.04) on the stock OPi system

SSH to your Orange Pi 5 Pro running the stock OPi vendor Ubuntu 22.04, then:

```bash
sudo apt-get update
sudo apt-get install -y git docker.io
sudo usermod -aG docker "$USER"        # log out / back in OR run: newgrp docker
git clone https://github.com/mack42/OrangePi5Pro.git
cd OrangePi5Pro
./01-build-noble.sh
```

Output lands at:

```
~/armbian-build/framework/output/images/Armbian-*_Orangepi5pro_noble_vendor_*.img.xz
```

Plus a matching `.txt` build manifest and `.sha` checksum.

## Step 2 — Flash and boot the 24.04 image

Copy the `.img.xz` to your workstation and flash to a microSD.

**On Windows: use [balenaEtcher](https://etcher.balena.io/).** This is the only tool I've gotten to produce a bootable card from this `.img.xz` reliably. Drag the `.img.xz` in, pick the SD, write. Done.

**Avoid Rufus and Raspberry Pi Imager on Windows.** Rufus's ISO/DD detection silently mangles the GPT (the card boots but the kernel sees only the whole-disk device with no partitions). Raspberry Pi Imager wrote a card that wouldn't enumerate the rootfs at the initramfs stage. Both wasted real time during development.

**On Linux**, `dd` directly works fine (it reads `.xz` via pipe):
```bash
xz -dc Armbian-*_noble_*.img.xz | sudo dd of=/dev/sdX bs=4M status=progress conv=fsync
```

Insert the microSD into the OPi and power-cycle. Don't touch eMMC — your stock 22.04 stays untouched as a fallback. The 5 Pro's u-boot prefers microSD over eMMC.

First boot prompts for a root password and then to create a regular user. If the very first boot stalls at `(initramfs)` saying it can't find the rootfs, power-cycle once — first-boot scripts can lose a race with SD enumeration on the very first attempt; the second boot is reliable.

## Step 3 — Build Armbian resolute (26.04) from the noble system

SSH into the booted 24.04 system, then:

```bash
sudo apt-get update
sudo apt-get install -y git docker.io qemu-user-static binfmt-support
sudo usermod -aG docker "$USER" && newgrp docker
git clone https://github.com/mack42/OrangePi5Pro.git
cd OrangePi5Pro
./02-build-resolute.sh
```

`02-build-resolute.sh` clones Armbian's build framework, applies `apply-uutils-shim.sh` (idempotent — the deploy/restore patch described above), and invokes `compile.sh` with **`BRANCH=current`** by default. Armbian's CI publishes prebuilt `current` kernel debs (~6.18.x mainline-rockchip64), so the first run downloads the kernel from `ghcr.io` instead of compiling — total build time around 8-15 min on this hardware. (If you set `BRANCH=vendor` instead, see the GPU caveat below — and note the kernel will compile from source if not in the remote cache.)

Output:

```
~/armbian-build/framework/output/images/Armbian-*_Orangepi5pro_resolute_current_*.img.xz
```

Verify it's actually 26.04:

```bash
xz -dkc <image>.img.xz | sudo dd of=/tmp/work.img bs=4M status=none
LOOP=$(sudo losetup -fP --show /tmp/work.img)
sudo mount -o ro "${LOOP}p1" /mnt
grep VERSION /mnt/etc/os-release
sudo umount /mnt && sudo losetup -d "$LOOP"
```

## Step 4 — Flash 26.04

Same flashing procedure as Step 2, just point at the resolute `.img.xz`.

If you want 26.04 on **eMMC** (replacing your stock OPi 22.04), boot the SD-card 26.04 image first, log in, then run Armbian's `armbian-install` to mirror to eMMC. Test boot from microSD before committing to eMMC — flashing eMMC is a one-way trip without serial recovery tools.

## GPU acceleration / kernel branch choice

This is the most important practical decision and it's why the recipe defaults to `BRANCH=current`. Tracked in detail in [issue #1](https://github.com/mack42/OrangePi5Pro/issues/1).

| Branch | Kernel | GPU | When to use |
|---|---|---|---|
| `current` (default) | mainline-rockchip64 ~6.18 | ✅ panthor + Mesa panvk: `Mali-G610 MC4` accelerated EGL/GLX, real Vulkan via `panvk` | Desktop, browsers, anything that benefits from HW accel |
| `vendor` | Rockchip BSP 6.1.115 | ❌ software (`llvmpipe`) only — kernel's built-in `mali_kbase` claims the GPU and prevents panfrost/panthor from binding | Only if you need NPU access or vendor MPP video decode |

**Limitations on `current`:**
- OpenGL Core profile capped at **3.1** (Mesa 26.0.3 panthor still maturing). OpenGL ES 3.1 works, Vulkan 1.4 works.
- Mainline `rkvdec2` for HW video decode is improving but not all codecs work yet.
- The 5 Pro is community-tier (CSC) in Armbian — no active board maintainer; some peripherals not validated upstream.

## Caveats

- These recipes use `BUILD_MINIMAL=yes BUILD_DESKTOP=no`. To build a desktop image, swap to `BUILD_DESKTOP=yes BUILD_MINIMAL=no DESKTOP_ENVIRONMENT=xfce` (or `gnome`). Or install your DE of choice on the minimal image post-boot (e.g. `sudo apt install kubuntu-desktop` for KDE Plasma).
- Each system's Armbian build cache is independent. The first build on a fresh host pulls a ~2 GB Docker base image and clones a kernel tree (~1-2 GB). Subsequent builds reuse those.

## Troubleshooting

### `rust-coreutils ... auxv.rs:269 panicked` during keyring setup

Means the patch wasn't applied. Either you're on a host without `CONFIG_BINFMT_MISC` (do Step 1 first; `02-build-resolute.sh` will refuse to run on such a kernel) or you ran `compile.sh` directly without `apply-uutils-shim.sh`. Re-run `./02-build-resolute.sh`, which applies the patch idempotently before invoking `compile.sh`.

Confirm the kernel:

```bash
grep BINFMT_MISC "/boot/config-$(uname -r)"
```

`# CONFIG_BINFMT_MISC is not set` → boot the noble image first.

### First boot stalls at `(initramfs)` with "Cannot find UUID..."

Power-cycle once. First-boot resize sometimes loses a race with SD enumeration. If it persists across multiple boots:

1. Pull the microSD, mount on another machine, edit `/boot/armbianEnv.txt` and append `rootwait` and `rootdelay=10` to the `extraargs=` line.
2. Or re-flash with balenaEtcher (Windows) or `dd` (Linux). See Step 2 — Rufus and Pi Imager have both produced unbootable cards from this image during development.

### `pgrep -af compile.sh` returns nothing mid-build

The build died. The last ~100 lines of `~/armbian-build/build.log` say why. Common causes:
- Out-of-disk: the kernel build alone needs ~10 GB, image creation another ~10 GB.
- Docker daemon not reachable (re-check `systemctl status docker`).
- Network blip during apt fetch (just rerun the script — caches mostly survive).

### Kernel build is unbearably slow

Should only happen if you set `BRANCH=vendor` (or Armbian doesn't have a prebuilt deb for your `BRANCH=current` config in their `ghcr.io` cache). Cortex-A76 at 2.35 GHz × 4 + A55 × 4 is roughly half a low-end x86 desktop. Allow 1.5-3 hours for a kernel compile from source. Re-builds reuse the kernel deb from `output/debs/` and finish in ~7-10 minutes regardless.

If you have an x86 host, build there instead — same `compile.sh`, same flags; binfmt-misc + qemu-aarch64 are auto-routed cross-arch on x86 and the resolute build works in one shot (no stepping stone, no patch). The patch in this repo is only needed when host and target are both aarch64.

### GPU isn't accelerated, OpenGL renderer says `llvmpipe`

You built (or downloaded) the `BRANCH=vendor` image. The Rockchip BSP kernel claims the Mali-G610 via its in-tree `mali_kbase` driver, blocking panfrost/panthor from binding. Rebuild with `BRANCH=current` (now the default in `02-build-resolute.sh`), or download the `current` image from the latest release. See [issue #1](https://github.com/mack42/OrangePi5Pro/issues/1) for the full diagnosis.

## What this repo is not

- A maintained distro. It's a build recipe; the binaries inherit Armbian's CSC support tier (none).
- A guarantee that every peripheral works.
- An in-place upgrade tool. Don't `do-release-upgrade` your stock Orange Pi system — it ends badly with vendor BSPs.
