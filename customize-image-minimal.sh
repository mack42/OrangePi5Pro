#!/bin/bash
#
# Armbian customize-image.sh — MINIMAL variant. Runs inside the rootfs
# chroot during build. Copied into framework/userpatches/customize-image.sh
# by 02-build-resolute.sh when invoked WITHOUT --desktop.
#
# Bakes the bare-minimum first-run UX into a CLI/headless image:
#   1. OrangePi5Pro repo + `orangepi-setup` symlink (the TTY wizard)
#   2. Orange Pi 5 Pro branded motd header (replaces Armbian default)
#   3. motd reminder telling the user to run `orangepi-setup`
#   4. consoleblank=0 baked into armbianEnv.txt so prompt text stays visible
#
# Does NOT install Plasma, HW video decode, kdialog wizard, or the boot-
# time auto-flip to graphical.target — those belong only to the desktop
# image. The minimal image stays at multi-user.target forever (correct
# for headless / server use).

set -e
export DEBIAN_FRONTEND=noninteractive

# --- 1. Bake in OrangePi5Pro repo + TTY orangepi-setup symlink ---
apt-get update
apt-get install -y --no-install-recommends git ca-certificates
git clone --depth=1 https://github.com/mack42/OrangePi5Pro.git /usr/local/share/OrangePi5Pro
ln -sf /usr/local/share/OrangePi5Pro/03-setup.sh /usr/local/bin/orangepi-setup

# --- 1a. RK3588 NPU stack (DKMS rknpu + librknnrt + DT overlay) ---
# Shared with the desktop image. See customize-image-npu.sh for the why.
# Tolerate failure (NPU is "nice to have" — see customize-image.sh).
bash /usr/local/share/OrangePi5Pro/customize-image-npu.sh || \
    echo "WARN: NPU stack install failed — image will boot without NPU support."

# --- 2. Disable kernel console blanking globally ---
# 03-setup.sh disables blanking via setterm at runtime, but TTY logins
# *before* the script runs can still go dark on slow boots. Belt-and-
# suspenders.
if [ -f /boot/armbianEnv.txt ]; then
    if ! grep -q "consoleblank=0" /boot/armbianEnv.txt; then
        sed -i 's|^extraargs=\(.*\)$|extraargs=\1 consoleblank=0|' /boot/armbianEnv.txt
    fi
fi

# --- 3. motd: replace Armbian banner with Orange Pi 5 Pro branding ---
# Same header the desktop image uses, kept consistent across flavors.
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

  Welcome to Orange Pi 5 Pro — Rockchip RK3588S  (minimal image)

  System    : ${distro}
  Kernel    : ${kernel}
  Hostname  : ${host}
  IPv4      : ${ip4:-<not assigned>}
  Uptime    : ${upt:-just booted}

EOF
HEADER
chmod +x /etc/update-motd.d/10-armbian-header

# Suppress Armbian's other branded motd fragments.
for f in /etc/update-motd.d/30-armbian-sysinfo /etc/update-motd.d/35-armbian-tips; do
    [ -f "$f" ] && chmod -x "$f"
done

# --- 4. motd: setup reminder until orangepi-setup is run ---
cat > /etc/update-motd.d/99-orangepi-setup <<'MOTD'
#!/bin/sh
# Suppress once any user's home (or root's) has the setup-done flag.
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
