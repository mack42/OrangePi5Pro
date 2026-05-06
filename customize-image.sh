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

# --- 3. Bake in OrangePi5Pro repo + Plasma kdialog setup wizard ---
# Two front-ends share the same six-prompt setup flow:
#   - 03-setup.sh (TTY) → /usr/local/bin/orangepi-setup
#     For SSH / minimal-image / power-user re-runs.
#   - 03-setup-gui.sh (kdialog) → /usr/local/bin/orangepi-setup-gui
#     Auto-launches once on first Plasma login (most users).
git clone --depth=1 https://github.com/mack42/OrangePi5Pro.git /usr/local/share/OrangePi5Pro
ln -sf /usr/local/share/OrangePi5Pro/03-setup.sh                  /usr/local/bin/orangepi-setup
ln -sf /usr/local/share/OrangePi5Pro/03-setup-gui.sh              /usr/local/bin/orangepi-setup-gui
ln -sf /usr/local/share/OrangePi5Pro/orangepi-setup-gui-autostart.sh /usr/local/bin/orangepi-setup-gui-autostart

# Plasma autostart: the .desktop in /etc/xdg/autostart/ fires once per
# user login. The autostart shim is the FIRST gate — it checks/touches
# ~/.opi5pro-setup-done so the wizard auto-launches exactly once, even
# if the user closes it mid-flow. Manual re-runs go through the
# application launcher entry (no flag check, no auto-fire).
mkdir -p /etc/xdg/autostart /usr/share/applications
install -m 0644 /usr/local/share/OrangePi5Pro/orangepi-setup-gui.desktop \
    /etc/xdg/autostart/orangepi-setup-gui.desktop
install -m 0644 /usr/local/share/OrangePi5Pro/orangepi-setup-gui-launcher.desktop \
    /usr/share/applications/orangepi-setup-gui.desktop

# Belt-and-suspenders: also disable console blanking globally so even non-hook
# TTYs don't power-save during long-running operations.
if [ -f /boot/armbianEnv.txt ]; then
    if ! grep -q "consoleblank=0" /boot/armbianEnv.txt; then
        sed -i 's|^extraargs=\(.*\)$|extraargs=\1 consoleblank=0|' /boot/armbianEnv.txt
    fi
fi

# --- 4. motd: replace Armbian banner with Orange Pi 5 Pro branding ---
# Armbian ships /etc/update-motd.d/10-armbian-header which prints a big
# "ARMBIAN" banner on login. Replace it with our own header so the system
# identifies as "Orange Pi 5 Pro" instead. Keep the dynamic info Armbian
# normally prints (kernel, IPs, load) by sourcing /etc/armbian-release for
# the version line and reusing standard tools for the rest.
mkdir -p /etc/update-motd.d
cat > /etc/update-motd.d/10-armbian-header <<'HEADER'
#!/bin/sh
# Orange Pi 5 Pro branded motd header (overrides Armbian default).
distro="Ubuntu 26.04 (Resolute Raccoon)"
[ -r /etc/os-release ] && . /etc/os-release && distro="${PRETTY_NAME:-$distro}"
kernel="$(uname -r)"
host="$(hostname)"
upt="$(uptime -p 2>/dev/null | sed 's/^up //')"
ip4="$(hostname -I 2>/dev/null | awk '{print $1}')"

cat <<EOF

  ____                              ____  _   ____    ____
 / __ \\ _ __ __ _ _ __   __ _  ___ |  _ \\(_) | ___|  |  _ \\ _ __ ___
| |  | | '__/ _\` | '_ \\ / _\` |/ _ \\| |_) | | |___ \\  | |_) | '__/ _ \\
| |__| | | | (_| | | | | (_| |  __/|  __/| |  ___) | |  __/| | | (_) |
 \\____/|_|  \\__,_|_| |_|\\__, |\\___||_|   |_| |____/  |_|   |_|  \\___/
                        |___/

  Welcome to Orange Pi 5 Pro — Rockchip RK3588S

  System    : ${distro}
  Kernel    : ${kernel}
  Hostname  : ${host}
  IPv4      : ${ip4:-<not assigned>}
  Uptime    : ${upt:-just booted}

EOF
HEADER
chmod +x /etc/update-motd.d/10-armbian-header

# Suppress Armbian's other branded motd fragments that re-introduce the
# "Armbian" name (tips, sysinfo headers). Keep the dynamic ones (load,
# updates) but drop any that print Armbian-specific copy.
for f in /etc/update-motd.d/30-armbian-sysinfo /etc/update-motd.d/35-armbian-tips; do
    [ -f "$f" ] && chmod -x "$f"
done

# --- 5. motd reminder until setup is done ---
# Shows a banner on every login (text or SSH) reminding the user to run
# orangepi-setup, suppressed once any user's home contains .opi5pro-setup-done
# (which 03-setup.sh touches on successful completion).
cat > /etc/update-motd.d/99-orangepi-setup <<'MOTD'
#!/bin/sh
# Suppress if any user's home has the setup-done flag.
for f in /home/*/.opi5pro-setup-done /root/.opi5pro-setup-done; do
    [ -f "$f" ] && exit 0
done
cat <<EOF
+--------------------------------------------------------------------+
|  First-time setup not yet completed.                               |
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
