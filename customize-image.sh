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
# mesa-vulkan-drivers ships the PanVK ICD (/usr/share/vulkan/icd.d) — without
# it vulkan-tools is present but every Vulkan app fails "no ICD". PanVK gives
# the Mali-G610 a working Vulkan 1.x driver on the panthor kernel stack.
apt-get install -y \
    kubuntu-desktop konsole mesa-utils vulkan-tools mesa-vulkan-drivers \
    xserver-xorg-core xwayland \
    git ca-certificates curl

systemctl set-default multi-user.target

# --- 1b. Brave browser (chromium-based, native arm64 deb, VAAPI HW decode) ---
# Add Brave's official APT repo and install. Ubuntu's snap-based Firefox
# is sluggish on RK3588 hardware; Brave's deb is responsive and works
# with the rockchip-vaapi we build in section 2 (browser flags needed
# at first run — orangepi-setup-gui can be extended to set those later).
install -d -m 0755 /usr/share/keyrings /etc/apt/sources.list.d
curl -fsSL https://brave-browser-apt-release.s3.brave.com/brave-browser-archive-keyring.gpg \
    -o /usr/share/keyrings/brave-browser-archive-keyring.gpg
chmod 0644 /usr/share/keyrings/brave-browser-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/brave-browser-archive-keyring.gpg arch=arm64] https://brave-browser-apt-release.s3.brave.com/ stable main" \
    > /etc/apt/sources.list.d/brave-browser-release.list
apt-get update
apt-get install -y brave-browser

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

# --- 3. Bake in OrangePi5Pro repo + orangepi-setup symlink ---
# v1.6+ flow: the user goes through the entire setup on TTY (firstrun
# + orangepi-setup), then reboots once into the final state (Plasma or
# multi-user, based on what they chose at the prompt). The kdialog
# wizard is kept around as a manually-launchable utility from the
# application menu, but is NOT in /etc/xdg/autostart anymore — it
# previously fired half-finished on first Plasma login and confused
# everyone. See section 3b for SDDM gating.
git clone --depth=1 https://github.com/mack42/OrangePi5Pro.git /usr/local/share/OrangePi5Pro
ln -sf /usr/local/share/OrangePi5Pro/03-setup.sh     /usr/local/bin/orangepi-setup
ln -sf /usr/local/share/OrangePi5Pro/03-setup-gui.sh /usr/local/bin/orangepi-setup-gui

# Application-launcher entry only — re-launchable from the K menu by
# someone who specifically wants the GUI version. NOT auto-started.
mkdir -p /usr/share/applications
install -m 0644 /usr/local/share/OrangePi5Pro/orangepi-setup-gui-launcher.desktop \
    /usr/share/applications/orangepi-setup-gui.desktop

# --- 3a. RK3588 NPU stack (DKMS rknpu + librknnrt + DT overlay) ---
# Shared with the minimal image. See customize-image-npu.sh for the why.
# Tolerate failure: NPU is "nice to have" — a DKMS compile error or a
# missing dt-binding shouldn't abort the entire image build. Failure
# leaves the image without NPU support but otherwise functional.
bash /usr/local/share/OrangePi5Pro/customize-image-npu.sh || \
    echo "WARN: NPU stack install failed — image will boot without NPU support."

# --- 3a2. Make armbian-firstlogin take the "no DM" branch ---
# armbian-firstlogin auto-detects sddm/lightdm/gdm3 (lines ~685-696
# of /usr/lib/armbian/armbian-firstlogin in the v1.x.x package) and
# takes a DM-specific branch that:
#   1. Creates an autologin sddm.conf.d so the user is auto-logged-in
#      to Plasma without a password prompt (security regression).
#   2. Prints "Now starting desktop environment via sddm..."
#   3. Runs `systemctl enable --now sddm` (silently no-op'd by our
#      gate in section 3b, but the user can't tell that).
#   4. exit 1's out before showing motd or a clean prompt.
#
# Net effect on the user: a confusing frozen screen on tty1 with no
# clue what to do next. The "no DM detected" else-branch is what we
# actually want — it `clear`s the screen, runs motd (which shows our
# orangepi-setup reminder), and exits cleanly so the login shell drops
# to a normal prompt.
#
# Patch: make the sddm/lightdm/gdm3 file-existence checks always
# evaluate false, forcing the no-DM branch. Idempotent.
fl=/usr/lib/armbian/armbian-firstlogin
if grep -q '\[\[ -f /usr/bin/sddm \]\]' "$fl"; then
    sed -i 's@\[\[ -f /usr/bin/sddm \]\]@false \&\& [[ -f /usr/bin/sddm ]]@' "$fl"
    sed -i 's@\[\[ -f /usr/sbin/lightdm \]\]@false \&\& [[ -f /usr/sbin/lightdm ]]@' "$fl"
    sed -i 's@\[\[ -f /usr/sbin/gdm3 \]\]@false \&\& [[ -f /usr/sbin/gdm3 ]]@' "$fl"
fi

# --- 3b. Block SDDM until orangepi-setup completes ---
# armbian-firstlogin runs `systemctl enable --now sddm` unconditionally
# at the end of its TTY user-creation prompts. Without intervention the
# user lands in Plasma immediately after firstrun — but at that point
# the kdialog wizard would race armbian-firstlogin's still-running
# session, the user has no idea what's going on, and on reboot the
# system is back at TTY (because default.target is still multi-user)
# with no clear instruction.
#
# v1.6+ design: keep the user on TTY through the entire flow.
#   1. firstrun TTY prompts → user created
#   2. firstlogin tries to start sddm, blocked by our condition
#   3. user sees motd "Run: orangepi-setup", runs it
#   4. orangepi-setup touches /etc/.opi5pro-setup-done-system on success
#   5. user reboots ONCE
#   6. sddm condition now passes; if user picked "auto-start Plasma",
#      03-setup.sh has already flipped default.target to graphical.
#
# A drop-in is cleaner than masking sddm: enable status is preserved,
# the unit just refuses to activate while the condition is false. No
# error spam in the journal — condition mismatches are silent.
mkdir -p /etc/systemd/system/sddm.service.d
cat > /etc/systemd/system/sddm.service.d/orangepi-wait-setup.conf <<'WAIT'
# Orange Pi 5 Pro: don't start SDDM until orangepi-setup has completed.
# Removed (unblocked) by 03-setup.sh on successful run.
[Unit]
ConditionPathExists=/etc/.opi5pro-setup-done-system
WAIT

# --- 3c. motd tip: how to start Plasma when at TTY post-setup ---
# Fires only when (a) sddm exists, (b) sddm isn't currently running,
# AND (c) the system flag is set (so it only appears AFTER setup is
# done — pre-setup it would be redundant with the orangepi-setup
# reminder). Helps users who chose "no" to auto-start, or who
# Ctrl+Alt+F1'd out of Plasma and want to bring it back manually.
cat > /etc/update-motd.d/97-orangepi-plasma-tip <<'TIP'
#!/bin/sh
[ -x /usr/bin/sddm ] || exit 0
[ -e /etc/.opi5pro-setup-done-system ] || exit 0
systemctl is-active sddm.service >/dev/null 2>&1 && exit 0
cat <<EOF
  Plasma desktop is not running.
  Start it now:                 sudo systemctl start sddm
  Boot into Plasma every time:  sudo systemctl set-default graphical.target

EOF
TIP
chmod +x /etc/update-motd.d/97-orangepi-plasma-tip

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
