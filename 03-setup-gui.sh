#!/usr/bin/env bash
# 03-setup-gui.sh — KDE/kdialog wrapper around the same setup steps as
# 03-setup.sh. Auto-launched once on first Plasma login via
# /etc/xdg/autostart/orangepi-setup-gui.desktop. Re-runnable from the
# application launcher ("Orange Pi 5 Pro Setup") or by running
# `orangepi-setup-gui` from a terminal.
#
# Desktop image only — the minimal image keeps the TTY-based 03-setup.sh
# (run as `orangepi-setup`) since it has no Plasma session.
#
# Privileged actions go through pkexec (Polkit's graphical sudo); the
# user is prompted for their password a couple of times across the wizard.
# armbian-install (NVMe migration) is intrinsically a curses TUI, so we
# spawn it inside a konsole with sudo — that's the only step the user has
# to navigate through outside the kdialog flow.

set -u

# Refuse to run as root — we want HOME and the kdialog session of the
# regular user. pkexec/sudo are used for privileged steps only.
if [[ "$(id -u)" == "0" ]]; then
    kdialog --error "Run this wizard as your regular user, not root." 2>/dev/null \
        || echo "Run as a regular user; the wizard sudos when needed." >&2
    exit 1
fi

# Need a Plasma/KDE session to talk to the user.
if ! command -v kdialog >/dev/null; then
    echo "kdialog not found — this wizard needs a KDE/Plasma session." >&2
    exit 1
fi

flag="$HOME/.opi5pro-setup-done"

title="Orange Pi 5 Pro Setup"
ask()   { kdialog --title "$title" --yesno "$1"; }
info()  { kdialog --title "$title" --msgbox "$1"; }
note()  { kdialog --title "$title" --passivepopup "$1" 4 >/dev/null 2>&1; }

# --- Welcome ---
info "Welcome to your Orange Pi 5 Pro!

A few one-time setup steps. You can re-run this wizard any time from
the application launcher (\"$title\") or by running:

    orangepi-setup-gui

You'll be prompted for your password for the privileged steps."

# --- 1. Auto-start UI on boot ---
current_target="$(systemctl get-default 2>/dev/null || echo unknown)"
if [[ "$current_target" == "graphical.target" ]]; then
    if ! ask "The system is set to boot directly into Plasma desktop.

Keep it that way?

(Choose No to boot to a text console instead — useful for headless / server use.)"; then
        pkexec systemctl set-default multi-user.target \
            && info "Will boot to text console on next reboot.

Start the GUI manually with:  sudo systemctl start sddm"
    fi
else
    if ask "Boot directly into Plasma desktop on every boot?

(Currently set to boot to a text console; you'd have to start Plasma manually.)"; then
        pkexec systemctl set-default graphical.target \
            && info "Will boot to graphical login (SDDM) on next reboot."
    fi
fi

# --- 2. NVMe migration ---
nvme_present="$(lsblk -dno NAME,TYPE 2>/dev/null | awk '$2=="disk" && $1 ~ /^nvme/ {print $1}' | head -1)"
if [[ -n "$nvme_present" ]]; then
    if ask "An NVMe SSD was detected at /dev/$nvme_present.

Migrate your root filesystem to it?

(Faster boot, faster apps. Highly recommended if you have one plugged in.
This step will open a terminal for the migration tool.)"; then
        if ask "Also write u-boot to SPI flash, so the board boots without an SD card afterwards?

YES → pure-NVMe operation. You can eject the SD card after.
NO  → keep u-boot on SD; only the rootfs goes to NVMe."; then
            spi_msg="\"Boot from SPI - root on NVMe\""
        else
            spi_msg="\"Boot from SD - root on NVMe\"  (or eMMC if you prefer)"
        fi
        info "Next, a terminal will open and run armbian-install.

When prompted, choose:

    $spi_msg

Press OK to launch."
        # Konsole with --hold keeps the window open after the command
        # exits so the user can see armbian-install's final message.
        konsole --hold -e bash -c "sudo armbian-install; echo; echo 'Migration complete. Close this terminal when ready.'"
    fi
fi

# --- 3. HDMI overscan workaround ---
if grep -q "video=HDMI-A-1" /boot/armbianEnv.txt 2>/dev/null; then
    note "HDMI overscan workaround already applied. Skipping."
else
    if ask "Some TVs crop the edges of the HDMI image. Plasma compensates automatically, but the kernel boot console (text screen, Ctrl+Alt+F2) does not.

The PROPER fix is on your TV: set HDMI input to 'Just Scan' / 'PC mode' / '1:1' / 'Full Pixel' (name varies).

The WORKAROUND below adds  video=HDMI-A-1:1880x1040@60  to the kernel cmdline — fixes the cropping at the cost of ~80px of effective resolution.

Apply the workaround?

(Skip if your monitor maps pixels 1:1.)"; then
        pkexec sed -i 's|^extraargs=\(.*\)$|extraargs=\1 video=HDMI-A-1:1880x1040@60|' /boot/armbianEnv.txt \
            && info "Workaround applied to /boot/armbianEnv.txt.

Reboot to take effect.

If 1880x1040 isn't right for your TV, edit that file manually."
    fi
fi

# --- Done ---
touch "$flag"
info "Setup complete!

If you changed the boot target, migrated to NVMe, or applied the overscan workaround — reboot now to apply."
