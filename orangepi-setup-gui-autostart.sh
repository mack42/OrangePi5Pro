#!/bin/sh
# Tiny shim invoked by /etc/xdg/autostart/orangepi-setup-gui.desktop.
# Auto-launch the wizard exactly once: the FIRST login that hits this
# shim touches ~/.opi5pro-setup-done immediately, so we never re-fire
# even if the user closes the wizard mid-flow. Kept as its own script
# so the .desktop Exec= line stays plain (no shell quoting that XDG/
# Plasma might mis-parse).
#
# If the user wants to re-run the wizard later they can launch it from
# the application menu ("Orange Pi 5 Pro Setup") or run
# `orangepi-setup-gui` from a terminal — neither path checks the flag.
[ -e "$HOME/.opi5pro-setup-done" ] && exit 0
touch "$HOME/.opi5pro-setup-done"
exec /usr/local/bin/orangepi-setup-gui
