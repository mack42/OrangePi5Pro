#!/usr/bin/env bash
# 03-setup.sh — post-boot setup helper for Ubuntu 26.04 on Orange Pi 5 Pro.
#
# Run this from inside the booted system after first login. Asks five
# questions and applies the answers:
#
#   1. Install KDE Plasma desktop now? (skipped if already installed)
#   2. Auto-start the UI on boot? (graphical.target vs multi-user.target)
#   3. Migrate root filesystem to NVMe? (calls armbian-install)
#   4. Put u-boot in SPI flash so the system boots without microSD?
#   5. Install hardware video decode (rockchip-vaapi + librockchip-mpp)?
#   6. Compensate for HDMI overscan (TV crops the text console)?
#
# Re-runnable. Each section is independent — answer "no" to any prompt to skip
# that step.

set -euo pipefail

if [[ "$(id -u)" == "0" ]]; then
    echo "Run as a regular user; the script will sudo when it needs to." >&2
    exit 1
fi

# Disable console blanking + DPMS while we're prompting. Some monitors
# blank during the slow ones (NVMe migration sub-prompt, HW video build);
# the cursor stays lit but the prompt text is invisible until the user
# wiggles the mouse, which is confusing.
setterm -blank 0 -powersave off -powerdown 0 2>/dev/null || true

ask() {
    # ask "Question?" default(y|n)  -> sets ANSWER to y or n
    local prompt="$1" default="${2:-n}" reply
    local hint
    if [[ "$default" == "y" ]]; then hint="[Y/n]"; else hint="[y/N]"; fi
    read -r -p "$prompt $hint " reply || true
    reply="${reply:-$default}"
    case "${reply,,}" in
        y|yes) ANSWER=y ;;
        *)     ANSWER=n ;;
    esac
}

echo "=== Orange Pi 5 Pro post-boot setup ==="
echo

# ------------------------------------------------------------------------
# 1. Install KDE Plasma
# ------------------------------------------------------------------------
if dpkg -l kubuntu-desktop 2>/dev/null | grep -q '^ii'; then
    echo "[1/5] KDE Plasma already installed — skipping."
else
    ask "[1/5] Install KDE Plasma desktop now?" n
    if [[ "$ANSWER" == "y" ]]; then
        echo ">>> Installing kubuntu-desktop + konsole (15-45 min)..."
        sudo apt-get update
        sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
            kubuntu-desktop konsole mesa-utils vulkan-tools
    fi
fi

# ------------------------------------------------------------------------
# 2. Default boot target (graphical UI vs CLI)
# ------------------------------------------------------------------------
current_target="$(systemctl get-default 2>/dev/null || echo unknown)"
echo
echo "[2/5] Current default boot target: $current_target"

if dpkg -l kubuntu-desktop 2>/dev/null | grep -q '^ii'; then
    if [[ "$current_target" == "graphical.target" ]]; then
        ask "      Auto-start the UI on boot? (currently yes)" y
    else
        ask "      Auto-start the UI on boot? (currently no)" n
    fi
    if [[ "$ANSWER" == "y" ]]; then
        sudo systemctl set-default graphical.target
        echo "      → Will boot to graphical login (SDDM) on next reboot."
    else
        sudo systemctl set-default multi-user.target
        echo "      → Will boot to text console on next reboot. Start GUI manually with 'startx'/'sudo systemctl start sddm'."
    fi
else
    echo "      → No desktop installed; skipping (system stays at text console)."
fi

# ------------------------------------------------------------------------
# 3. Migrate to NVMe
# ------------------------------------------------------------------------
echo
nvme_present="$(lsblk -dno NAME,TYPE | awk '$2=="disk" && $1 ~ /^nvme/ {print $1}' | head -1)"
if [[ -z "$nvme_present" ]]; then
    echo "[3/5] No NVMe drive detected — skipping migration."
else
    echo "[3/5] NVMe detected: /dev/$nvme_present"
    ask "      Migrate root filesystem to NVMe? (uses armbian-install)" n
    if [[ "$ANSWER" == "y" ]]; then
        echo
        echo ">>> Pre-prompt for question 4 (SPI bootloader) before launching armbian-install."
        ask "[4/5] Also write u-boot to SPI flash so the board boots without an SD card?
      Choose YES for pure-NVMe operation. Choose NO to keep u-boot on SD" n
        spi_choice="$ANSWER"

        echo
        if [[ "$spi_choice" == "y" ]]; then
            echo ">>> When armbian-install opens, choose:"
            echo "      \"Boot from SPI - root on NVMe\""
        else
            echo ">>> When armbian-install opens, choose:"
            echo "      \"Boot from SD - root on NVMe\"   (or eMMC if you prefer)"
        fi
        echo
        read -r -p "      Press ENTER to launch armbian-install..." _
        sudo armbian-install
        echo
        echo "      Migration step complete. If armbian-install asked you to reboot, do so now."
    else
        echo "      → Skipping NVMe migration. Re-run this script later if you change your mind."
    fi
fi

# ------------------------------------------------------------------------
# 5. Hardware video decode (rockchip-vaapi + librockchip-mpp)
# ------------------------------------------------------------------------
echo
echo "[5/5] Hardware video decode (rockchip-vaapi)"
echo "      Builds librockchip-mpp + woodyst/rockchip-vaapi from source so"
echo "      Firefox / Brave / mpv can hardware-decode H.264 / HEVC / VP9 /"
echo "      AV1 via the RK3588 VPU. Takes 15-25 min on this hardware."
echo

if [[ -e /usr/lib/aarch64-linux-gnu/dri/rockchip_drv_video.so ]] && command -v vainfo >/dev/null; then
    echo "      Already installed — running vainfo to confirm it still works."
    LIBVA_DRIVER_NAME=rockchip vainfo --display drm --device /dev/dri/renderD128 2>&1 | head -15
else
    ask "      Install HW video decode now?" n
    if [[ "$ANSWER" == "y" ]]; then
        echo ">>> Installing build deps..."
        sudo apt-get update
        sudo apt-get install -y --no-install-recommends \
            build-essential cmake meson ninja-build pkg-config \
            libdrm-dev libva-dev libv4l-dev libudev-dev libssl-dev \
            nasm yasm git ca-certificates

        builddir="$HOME/.opi5pro-build"
        rm -rf "$builddir" && mkdir -p "$builddir"

        # 1. librockchip-mpp
        echo ">>> Building librockchip-mpp..."
        git clone --depth=1 https://github.com/rockchip-linux/mpp.git "$builddir/mpp"
        ( cd "$builddir/mpp" && mkdir -p build && cd build && \
          cmake -DCMAKE_INSTALL_PREFIX=/usr/local -DCMAKE_BUILD_TYPE=Release -DBUILD_TEST=OFF .. && \
          make -j"$(nproc)" && \
          sudo make install ) || { echo "MPP build failed" >&2; exit 1; }
        sudo ldconfig

        # 2. rockchip-vaapi
        echo ">>> Building woodyst/rockchip-vaapi..."
        git clone --depth=1 https://github.com/woodyst/rockchip-vaapi.git "$builddir/rockchip-vaapi"
        ( cd "$builddir/rockchip-vaapi" && \
          PKG_CONFIG_PATH=/usr/local/lib/pkgconfig make && \
          sudo make install ) || { echo "rockchip-vaapi build failed" >&2; exit 1; }

        # 3. libva-utils for vainfo (only if missing)
        if ! command -v vainfo >/dev/null; then
            echo ">>> Building libva-utils (vainfo)..."
            git clone --depth=1 https://github.com/intel/libva-utils.git "$builddir/libva-utils"
            ( cd "$builddir/libva-utils" && \
              meson setup build --prefix=/usr/local && \
              sudo ninja -C build install ) || { echo "libva-utils build failed" >&2; exit 1; }
            sudo ldconfig
        fi

        # 4. Set LIBVA_DRIVER_NAME system-wide
        echo ">>> Configuring system-wide LIBVA_DRIVER_NAME=rockchip..."
        echo "LIBVA_DRIVER_NAME=rockchip" | sudo tee /etc/environment.d/99-rockchip-vaapi.conf >/dev/null 2>&1 || true
        # /etc/environment.d may not be picked up everywhere — also drop a profile.d shim
        sudo tee /etc/profile.d/rockchip-vaapi.sh >/dev/null <<'PROF_EOF'
export LIBVA_DRIVER_NAME=rockchip
PROF_EOF

        # 5. Verify
        echo
        echo ">>> Verification:"
        LIBVA_DRIVER_NAME=rockchip vainfo --display drm --device /dev/dri/renderD128 2>&1 | head -20

        echo
        echo "      Browser configuration tips:"
        echo "      Firefox: about:config → set the following to true:"
        echo "          media.hardware-video-decoding.enabled"
        echo "          media.ffmpeg.vaapi.enabled"
        echo "          media.rdd-ffmpeg.enabled"
        echo "      Brave / Chromium: chrome://flags → enable 'Hardware-accelerated video decode'"
        echo "          Or launch with: --enable-features=VaapiVideoDecoder --use-gl=angle --ignore-gpu-blocklist"
        echo
        echo "      Log out and back in (or reboot) so applications pick up LIBVA_DRIVER_NAME."
    else
        echo "      → Skipping HW video decode. Re-run this script later to install."
    fi
fi

# ------------------------------------------------------------------------
# 6. HDMI overscan compensation (TTY console)
# ------------------------------------------------------------------------
echo
echo "[6/6] HDMI overscan compensation"
echo "      Some TVs crop ~20px around the edges when receiving an HDMI signal."
echo "      Plasma's KWin compensates automatically; the kernel TTY (boot console"
echo "      / Ctrl+Alt+F2) does not, so text near edges gets cut off."
echo
echo "      The PROPER fix is on your TV: set HDMI input to 'Just Scan' / 'PC mode'"
echo "      / 'Screen Fit' / '1:1' / 'Full Pixel' (name varies). That eliminates"
echo "      cropping with no resolution loss."
echo "      The WORKAROUND below adds a video= cmdline that forces the framebuffer"
echo "      to 1880x1040 — fixes the cropping at the cost of ~80px of effective"
echo "      resolution. Skip this if your TV / monitor doesn't have overscan."
echo

if grep -q "video=HDMI-A-1" /boot/armbianEnv.txt 2>/dev/null; then
    echo "      Already applied — armbianEnv.txt has video=HDMI-A-1 in extraargs."
else
    ask "      Apply the overscan workaround (1880x1040 framebuffer) now?" n
    if [[ "$ANSWER" == "y" ]]; then
        sudo sed -i 's|^extraargs=\(.*\)$|extraargs=\1 video=HDMI-A-1:1880x1040@60|' /boot/armbianEnv.txt
        echo "      → /boot/armbianEnv.txt extraargs updated. Reboot to apply."
        echo "      → If 1880x1040 isn't right for your TV, edit the line manually."
    fi
fi

echo
echo "=== Setup complete ==="
# Per-user flag: suppresses the motd reminder for *this* user on next login.
touch "$HOME/.opi5pro-setup-done"
# System-wide flag: unblocks SDDM (the desktop image's
# /etc/systemd/system/sddm.service.d/orangepi-wait-setup.conf has a
# ConditionPathExists on this) and silences any other system-level
# "setup not done" gates. Touching it costs nothing on the minimal
# image, and on the desktop image it's the lever that lets Plasma
# start on the next boot if the user chose graphical.target above.
sudo touch /etc/.opi5pro-setup-done-system

echo
echo "Reboot now to apply your choices:  sudo reboot"
echo
if [[ "$(systemctl get-default 2>/dev/null)" == "graphical.target" ]]; then
    echo "Next boot will land you in Plasma."
else
    echo "Next boot will land you at the text console. Start Plasma manually with"
    echo "  sudo systemctl start sddm"
    echo "or flip the default permanently with"
    echo "  sudo systemctl set-default graphical.target"
fi
