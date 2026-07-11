# Ubuntu 26.04 on Orange Pi 5 Pro

A working recipe to build and run **Ubuntu 26.04 LTS (Resolute Raccoon)** on the Orange Pi 5 Pro (Rockchip RK3588S), using Armbian's build framework with the **mainline (`current`)** Linux kernel for working GPU acceleration.

Currently there is no off-the-shelf 26.04 image for this board. [Joshua Riek's `ubuntu-rockchip`](https://github.com/Joshua-Riek/ubuntu-rockchip) was archived on 29 April 2026, [Armbian's downloads page for the 5 Pro](https://www.armbian.com/orange-pi-5-pro/) only ships Debian Trixie, and Orange Pi's official downloads top out at 24.04. So we build it ourselves.

## Just want the image?

Skip everything below and grab a prebuilt 26.04 image from the [latest release page](https://github.com/mack42/OrangePi5Pro/releases/latest):

- **`*_desktop.img.xz`** (~770 MB) — KDE Plasma + SDDM + HW video decode + `orangepi-setup` auto-prompt baked in. The "just works" option.
- **`*_minimal.img.xz`** (~300 MB) — CLI only, headless / server use. Run `orangepi-setup` post-boot for Plasma + setup.

Flash with [balenaEtcher](https://etcher.balena.io/) on any OS, or `xz -dc *.img.xz | sudo dd of=/dev/sdX bs=4M status=progress` on Linux/macOS — see [Step 2](#step-2--flash-and-boot-the-2404-image) below for full per-OS commands and the SHA-256 verify step. Continue reading only if you want to rebuild it yourself or understand why it's needed.

## Files in this repo

| File | Purpose |
|---|---|
| `01-build-noble.sh` | Builds the 24.04 stepping-stone image. Run on the stock OPi vendor 22.04 system. |
| `02-build-resolute.sh` | Builds the 26.04 image. Run on the booted noble system. `--desktop` flag bakes Plasma + HW video decode + Orange Pi 5 Pro branding. Set `VERSION=v1.7.0` to name the output `opi5pro-v1.7.0-{desktop,minimal}.img.xz`. Applies small idempotent workarounds for current Armbian-framework bugs (a debug `ls -R` that aborts the build, and the `armbian-config` auto-install). |
| `apply-uutils-shim.sh` | Patches Armbian's framework with: (1) deploy uutils→qemu-shim, (2) restore before image creation, (3) rk3588 boot-delay (`rootwait rootdelay=10`), (4) rewrite hardcoded `qemu-user-static` package name to `qemu-user-binfmt` for Ubuntu 26.04 hosts. Idempotent. Called automatically by `02-build-resolute.sh`. |
| `customize-image.sh` | Runs inside the chroot during a `--desktop` build. Installs `kubuntu-desktop`, builds `librockchip-mpp` + `woodyst/rockchip-vaapi` + `libva-utils` from source, replaces the Armbian motd header with Orange Pi 5 Pro branding, drops a setup-reminder motd, installs the kdialog wizard autostart entry, and sources `customize-image-npu.sh` for the NPU stack. Copied into `framework/userpatches/` by `02-build-resolute.sh --desktop`. |
| `customize-image-minimal.sh` | Minimal-flavor counterpart. Clones the repo, symlinks `orangepi-setup`, replaces the Armbian motd header with Orange Pi 5 Pro branding, drops the setup-reminder motd, and sources `customize-image-npu.sh`. Copied into `framework/userpatches/` by `02-build-resolute.sh` (no flag). |
| `customize-image-npu.sh` | Sourced by both customize scripts inside the chroot. Builds the `w568w/rknpu-module` DKMS package (with the fixes in `npu-patches/` for dma-buf import, the ioctl result-clobber, `RKNPU_GET_VOLT` NULL-deref, and core bus-clock wiring), downloads `librknnrt.so` 2.3.2 + `rknn_server`, compiles and installs an OPi-5-Pro DT overlay (single-IOMMU, core-0), ships udev rules that expose `/dev/rknpu` + `/dev/dma_heap` to the `render` group, and installs `orangepi-npu-benchmark` + a MobileNet sample model. Result: **real model inference works out of the box** (~110 inferences/s, non-root). |
| `03-setup.sh` | TTY post-boot helper. Six prompts: install Plasma / auto-start UI / migrate to NVMe / SPI bootloader / install HW video / fix HDMI overscan. Run as `orangepi-setup` from either image, or `./03-setup.sh` from a clone. Re-runnable. |
| `03-setup-gui.sh` | KDE/kdialog wrapper around the same flow for the desktop image. Auto-launches once on first Plasma login (Plasma + HW video are baked in, so it's a 3-question wizard: autostart toggle, NVMe migration, HDMI overscan). Run as `orangepi-setup-gui` from the application launcher or terminal. |
| `orangepi-setup-gui.desktop` | Plasma autostart entry. Shipped to `/etc/xdg/autostart/` on the desktop image; runs `orangepi-setup-gui` once on first KDE login if `~/.opi5pro-setup-done` is missing. |
| `orangepi-setup-gui-launcher.desktop` | Application launcher entry. Shipped to `/usr/share/applications/` on the desktop image so the wizard is re-launchable from the menu without the flag check. |
| `04-release.sh` | Publishes a GitHub release for the built images: tags it, (re)generates checksums, uploads the `opi5pro-<version>-{desktop,minimal}.img.xz` assets, and attaches notes. Idempotent — re-run to add the minimal image to a release that already has the desktop one. Needs `gh` authenticated. Usage: `./04-release.sh v1.7.0 --notes notes.md`. |
| `README.md` | This file. |

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

Copy the `.img.xz` to your workstation and flash to a microSD using the instructions for your OS below. **balenaEtcher** is the cross-platform safe choice; it accepts `.img.xz` directly and uses raw DD writes — the only tool I've gotten to produce a bootable card reliably across this whole project.

### Linux

```bash
# Identify the SD card device first — DO NOT skip this step or you can wipe a real disk.
lsblk
# Look for the card (usually /dev/sda, /dev/sdb, or /dev/mmcblk0). Confirm by size.

# Decompress and write in one pipe (safe for .img.xz):
xz -dc Armbian-unofficial_*_resolute_current_*.img.xz | sudo dd of=/dev/sdX bs=4M status=progress conv=fsync
sync
```
Replace `sdX` with your card's device. **Triple-check the device** — `dd` will overwrite without warning.

### macOS

Easiest: install [balenaEtcher](https://etcher.balena.io/) (drag in the `.img.xz`, pick the SD, write).

CLI alternative if you prefer Terminal:
```bash
# Identify the SD card device:
diskutil list
# Look for /dev/diskN where N is the SD card. Confirm by size.

# Unmount (do NOT eject):
diskutil unmountDisk /dev/diskN

# Write — note the 'r' prefix on rdiskN for raw / faster write:
xz -dc Armbian-unofficial_*_resolute_current_*.img.xz | sudo dd of=/dev/rdiskN bs=4m status=progress

# Eject when done:
diskutil eject /dev/diskN
```
Replace `diskN`/`rdiskN` with your card's identifier.

### Windows

**Use [balenaEtcher](https://etcher.balena.io/).** Download, install, point at the `.img.xz`, pick the SD, click Flash. Etcher decompresses on the fly and writes raw — works reliably.

**Avoid Rufus and Raspberry Pi Imager on Windows for these images.** During development, Rufus's ISO/DD detection silently mangled the GPT (the card boots but the kernel sees only the whole-disk device, no partitions). Raspberry Pi Imager wrote a card that wouldn't enumerate the rootfs at the initramfs stage. Both wasted real time. balenaEtcher worked first try, every time.

(If you absolutely must use the command line, install [Win32DiskImager](https://sourceforge.net/projects/win32diskimager/) and decompress the `.img.xz` first with [7-Zip](https://www.7-zip.org/), then point Win32DiskImager at the resulting raw `.img`.)

### Verify the SHA-256

The release page ships a matching `.sha` file. Verify before flashing:

```bash
# Linux / macOS:
sha256sum -c Armbian-unofficial_*.img.xz.sha   # Linux
shasum -a 256 -c Armbian-unofficial_*.img.xz.sha   # macOS
```
Windows PowerShell: `Get-FileHash Armbian-...img.xz -Algorithm SHA256`. Compare to the value in the `.sha` file.

### Boot

Insert the microSD into the OPi and power-cycle. Don't touch eMMC — your stock 22.04 stays untouched as a fallback. The 5 Pro's u-boot prefers microSD over eMMC.

First boot prompts for a root password and then to create a regular user. If the very first boot stalls at `(initramfs)` saying it can't find the rootfs, power-cycle once — first-boot scripts can lose a race with SD enumeration on the very first attempt; the second boot is reliable.

## Step 3 — Build Armbian resolute (26.04) from the noble system

SSH into the booted 24.04 system, then:

```bash
sudo apt-get update
sudo apt-get install -y git docker.io qemu-user qemu-user-binfmt binfmt-support
sudo usermod -aG docker "$USER" && newgrp docker
git clone https://github.com/mack42/OrangePi5Pro.git
cd OrangePi5Pro

# Minimal CLI image (~8-15 min, ~300 MB):
./02-build-resolute.sh

# OR — KDE Plasma desktop image with HW video decode + auto-prompt baked in
# (~30-45 min, ~770 MB, all dependencies handled by customize-image.sh):
./02-build-resolute.sh --desktop
```

`02-build-resolute.sh` clones Armbian's build framework, applies `apply-uutils-shim.sh` (idempotent — the deploy/restore patch described above), and invokes `compile.sh` with **`BRANCH=current`** by default. Armbian's CI publishes prebuilt `current` kernel debs (~6.18.x mainline-rockchip64), so the first run downloads the kernel from `ghcr.io` instead of compiling — keeping the minimal build under ~15 min. (Override with `BRANCH=vendor` only if you specifically need the BSP — see the GPU caveat below.)

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

Same flashing procedure as **Step 2** (Linux / macOS / Windows commands above), just point at the resolute `.img.xz`. **balenaEtcher** on Windows; `xz -dc | sudo dd ...` on Linux / macOS Terminal.

## Step 5 — Post-boot setup

Both images land you at a **TTY login** for `armbian-firstrun` (set root password, create your user, set timezone/locale).

### Desktop image — Plasma kdialog wizard

After firstrun, `armbian-firstlogin` starts SDDM and the desktop image lands you in Plasma. A boot-time service (`orangepi-graphical-default.service`) flips `default.target` to `graphical.target` automatically once firstlogin is complete, so **every reboot lands in Plasma from then on**. (You can opt out via the wizard or with `sudo systemctl set-default multi-user.target` for headless / server use.)

A **kdialog setup wizard** auto-launches once on first Plasma login (or run it manually from the application launcher / `orangepi-setup-gui`):

- Auto-start Plasma on every boot — the new default; choose No to disable
- Migrate root filesystem to NVMe — opens a terminal running `armbian-install`
- Put u-boot in SPI flash (asked only if NVMe migration is yes)
- HDMI overscan workaround (skip if your monitor maps pixels 1:1)

The autostart shim touches `~/.opi5pro-setup-done` immediately on first launch so the wizard auto-fires *exactly once* — closing it without finishing won't trigger it on the next login. Re-run manually any time from the application launcher (**"Orange Pi 5 Pro Setup"**) or by running `orangepi-setup-gui` in a terminal — neither path checks the flag. Plasma + HW video decode are baked into the image, so those prompts are skipped.

You can also run the TTY version (`orangepi-setup`) over SSH or from the text console — both front-ends share the same flag.

If you ever land at TTY (e.g., you opted out of auto-start), the motd tip shows you how to bring Plasma back up:

```
  Plasma desktop is not running.
  Start it now:                 sudo systemctl start sddm
  Boot into Plasma every time:  sudo systemctl set-default graphical.target
```

### Minimal image — TTY `orangepi-setup`

After firstrun, log in at the text console. The motd shows an Orange Pi 5 Pro reminder:

```
+--------------------------------------------------------------------+
|  First-time setup not yet completed.                               |
|                                                                    |
|  Run:    orangepi-setup                                            |
|                                                                    |
|  Six prompts: Install/auto-start Plasma, migrate root to NVMe,     |
|  put u-boot in SPI flash, install hardware video decode, and       |
|  optionally compensate for HDMI overscan.                          |
+--------------------------------------------------------------------+
```

Type `orangepi-setup` and answer the prompts. The minimal image has the script pre-installed at `/usr/local/share/OrangePi5Pro/`.

If for any reason the script isn't on the image, you can clone and run it manually:

```bash
git clone https://github.com/mack42/OrangePi5Pro.git
cd OrangePi5Pro
./03-setup.sh
```

`03-setup.sh` (a.k.a. `orangepi-setup` on the desktop image) walks through six prompts and applies your answers:

1. **Install KDE Plasma desktop?** — skipped if already there. Adds ~2 GB.
2. **Auto-start the UI on boot?** — toggles between `graphical.target` (boots into SDDM/Plasma) and `multi-user.target` (boots to text console).
3. **Migrate root filesystem to NVMe?** — calls Armbian's `armbian-install` to copy the running rootfs onto an NVMe SSD if one's plugged in.
4. **Put u-boot in SPI flash?** — only asked if (3) is yes. Choose YES for **pure-NVMe operation, no SD card needed after**. Choose NO to keep u-boot on the SD card and treat NVMe as just the rootfs.
5. **Install hardware video decode?** — builds [`librockchip-mpp`](https://github.com/rockchip-linux/mpp) + [`woodyst/rockchip-vaapi`](https://github.com/woodyst/rockchip-vaapi) from source, drops a VA-API driver into `/usr/lib/aarch64-linux-gnu/dri/rockchip_drv_video.so` so Firefox / Brave / mpv can hardware-decode H.264 / HEVC / VP9 / AV1 via the RK3588 VPU. Takes 15-25 min on this hardware. **Skipped automatically if installed already — desktop image variant has it baked in.**
6. **Compensate for HDMI overscan?** — only relevant if your TV crops the edges of the text console. The proper fix is on the TV (look for "Just Scan" / "PC mode" / "Pixel Perfect"). The workaround here adds `video=HDMI-A-1:1880x1040@60` to the kernel cmdline in `armbianEnv.txt`, costing ~80 px of effective resolution. Skip if your monitor maps pixels 1:1.

Each step is independent — answer "no" to skip. The script is re-runnable: change your mind later, run it again.

### NVMe boot configurations

The OPi 5 Pro's RK3588S boot ROM doesn't read u-boot directly from NVMe; u-boot has to come from SPI flash, eMMC, microSD, or USB. So you have three working setups:

| Setup | u-boot location | Rootfs location | Tradeoffs |
|---|---|---|---|
| **Pure NVMe** *(answer YES to step 4)* | SPI flash | NVMe | Cleanest. SD card can be removed. SPI write is one-way without [rkdeveloptool maskrom recovery](https://opensource.rock-chips.com/wiki_Rkdeveloptool). |
| **SD bootloader + NVMe rootfs** *(answer NO to step 4)* | microSD (small) | NVMe | Easy to recover (just edit/replace SD). SD slot stays occupied. |
| **eMMC bootloader + NVMe rootfs** *(advanced — choose in armbian-install)* | eMMC | NVMe | No SD slot used. Replaces stock OPi 22.04 on eMMC — irreversible without reflash. |

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

- `02-build-resolute.sh` defaults to a minimal CLI image. Pass `--desktop` for an image with KDE Plasma + SDDM + HW video decode baked in, or run `orangepi-setup` (a.k.a. `03-setup.sh`) post-boot from a minimal image — both reach the same end state.
- Each system's Armbian build cache is independent. The first build on a fresh host pulls a ~2 GB Docker base image and clones a kernel tree (~1-2 GB). Subsequent builds reuse those.
- HW video decode on mainline 6.18 isn't packaged in resolute apt; the desktop image build (`customize-image.sh`) compiles `librockchip-mpp` + `woodyst/rockchip-vaapi` + `libva-utils` from source and lands a working VA-API driver. Verified with `vainfo`: the rockchip driver loads, all four codec families (H.264 / HEVC / VP9 / AV1) decode-capable. Firefox / Brave / mpv pick this up automatically once VA-API flags are enabled. See [issue #1](https://github.com/mack42/OrangePi5Pro/issues/1) for the full investigation, including ffmpeg-vaapi limitations.
- After flashing the desktop image, log in at the TTY (`armbian-firstrun` runs there to set root password / create your user). After firstrun, the next interactive TTY login auto-launches `orangepi-setup` exactly once; from there you opt into Plasma autostart, NVMe migration, etc. Re-invoke any time with `orangepi-setup`.

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
