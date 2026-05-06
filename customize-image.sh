#!/bin/bash
#
# Armbian customize-image.sh — runs inside the rootfs chroot during build.
# Copied into framework/userpatches/customize-image.sh by 02-build-resolute.sh
# when invoked with --desktop. Bakes everything needed for a working desktop
# image into the rootfs:
#
#   1. KDE Plasma + GPU diagnostic tools
#   2. HW video decode (librockchip-mpp + woodyst/rockchip-vaapi + libva-utils)
#   3. OrangePi5Pro repo + first-TTY-login auto-run hook for orangepi-setup
#
# Default boot target stays multi-user.target so first boot lands at TTY for
# armbian-firstrun (set root password, create user); orangepi-setup auto-runs
# afterwards and offers to flip default to graphical.target.

set -e
export DEBIAN_FRONTEND=noninteractive

# --- 1. KDE Plasma + GPU diagnostic tools ---
# DO NOT pass --no-install-recommends here. kubuntu-desktop's recommends
# include xwayland / xserver-xorg-core that KWin-Wayland and any X11 desktop
# session need. Without them: SDDM greeter shows but user sessions blank.
apt-get update
apt-get install -y \
    kubuntu-desktop konsole mesa-utils vulkan-tools \
    xserver-xorg-core xwayland \
    git ca-certificates curl

systemctl set-default multi-user.target

# --- 2. HW video decode stack (librockchip-mpp + rockchip-vaapi + libva-utils) ---
apt-get install -y \
    build-essential cmake meson ninja-build pkg-config \
    libdrm-dev libva-dev libva-drm2 libv4l-dev libudev-dev libssl-dev \
    nasm yasm

mkdir -p /tmp/hwvideo && cd /tmp/hwvideo

# librockchip-mpp
git clone --depth=1 https://github.com/rockchip-linux/mpp.git
( cd mpp && mkdir -p build && cd build && \
  cmake -DCMAKE_INSTALL_PREFIX=/usr/local -DCMAKE_BUILD_TYPE=Release -DBUILD_TEST=OFF .. && \
  make -j"$(nproc)" && \
  make install )
ldconfig

# woodyst/rockchip-vaapi
git clone --depth=1 https://github.com/woodyst/rockchip-vaapi.git
( cd rockchip-vaapi && \
  PKG_CONFIG_PATH=/usr/local/lib/pkgconfig make && \
  make install )

# libva-utils for vainfo
git clone --depth=1 https://github.com/intel/libva-utils.git
( cd libva-utils && \
  meson setup build --prefix=/usr/local && \
  ninja -C build install )
ldconfig

cd / && rm -rf /tmp/hwvideo

# Set LIBVA_DRIVER_NAME system-wide
mkdir -p /etc/profile.d
cat > /etc/profile.d/rockchip-vaapi.sh <<'PROF'
export LIBVA_DRIVER_NAME=rockchip
PROF

# --- 3. Bake in OrangePi5Pro repo + first-TTY-login auto-run hook ---
git clone --depth=1 https://github.com/mack42/OrangePi5Pro.git /usr/local/share/OrangePi5Pro
ln -sf /usr/local/share/OrangePi5Pro/03-setup.sh /usr/local/bin/orangepi-setup

# Auto-run orangepi-setup on the first interactive login on a real TTY (not
# SSH). Set the flag file FIRST so the hook never re-prompts on subsequent
# logins, even if the user Ctrl-C's mid-prompt or the script errors out.
# Re-invoke manually any time with: orangepi-setup
cat > /etc/profile.d/orangepi-firstrun.sh <<'PROF'
#!/bin/sh
case "$(tty 2>/dev/null)" in
    /dev/tty[0-9]*)
        if [ "$(id -u)" -ne 0 ] && [ ! -e "$HOME/.opi5pro-setup-done" ]; then
            # Disable console blanking + DPMS so the user actually sees the
            # prompts. Otherwise the monitor times out into power-save during
            # the brief gap after armbian-firstrun completes and the user
            # thinks the system hung.
            setterm -blank 0 -powersave off -powerdown 0 2>/dev/null || true
            touch "$HOME/.opi5pro-setup-done"
            clear
            echo "============================================================"
            echo "  Orange Pi 5 Pro — first-login setup helper"
            echo "  Re-run later any time with: orangepi-setup"
            echo "============================================================"
            sleep 2
            /usr/local/bin/orangepi-setup || true
        fi
        ;;
esac
PROF
chmod +x /etc/profile.d/orangepi-firstrun.sh

# Belt-and-suspenders: also disable console blanking globally so even non-hook
# TTYs don't power-save during long-running operations.
if [ -f /boot/armbianEnv.txt ]; then
    if ! grep -q "consoleblank=0" /boot/armbianEnv.txt; then
        sed -i 's|^extraargs=\(.*\)$|extraargs=\1 consoleblank=0|' /boot/armbianEnv.txt
    fi
fi

# --- 4. motd reminder until setup is done ---
# Shows a banner on every login (text or SSH) reminding the user to run
# orangepi-setup, suppressed once any user's home contains .opi5pro-setup-done
# (which the profile.d hook touches on first launch, and which 03-setup.sh
# can also touch explicitly on successful completion).
mkdir -p /etc/update-motd.d
cat > /etc/update-motd.d/99-orangepi-setup <<'MOTD'
#!/bin/sh
# Suppress if any user's home has the setup-done flag.
for f in /home/*/.opi5pro-setup-done /root/.opi5pro-setup-done; do
    [ -f "$f" ] && exit 0
done
cat <<EOF

+--------------------------------------------------------------------+
|  Orange Pi 5 Pro — first-time setup not yet completed.             |
|                                                                    |
|  Run:    orangepi-setup                                            |
|                                                                    |
|  Six prompts: Install/auto-start Plasma, migrate root to NVMe,     |
|  put u-boot in SPI flash, install hardware video decode, and       |
|  optionally compensate for HDMI overscan.                          |
+--------------------------------------------------------------------+

EOF
MOTD
chmod +x /etc/update-motd.d/99-orangepi-setup

apt-get clean
exit 0
