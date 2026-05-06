#!/usr/bin/env bash
# Patch Armbian's build framework with the fixes needed for a working
# Ubuntu 26.04 image on the Orange Pi 5 Pro:
#
# 1) DEPLOY shim (lib/functions/rootfs/create-cache.sh):
#    Replace /usr/bin/* uutils symlinks with a shell shim routing through
#    qemu-aarch64-static, so chroot operations don't hit the rust-coreutils
#    auxv panic on Rockchip vendor BSP kernels.
#
# 2) RESTORE shim (lib/functions/main/rootfs-image.sh):
#    Reverse the swap before image creation so the final image ships clean
#    uutils with no runtime emulation overhead.
#
# 3) BOOT-DELAY (lib/functions/rootfs/distro-agnostic.sh):
#    Append `rootwait rootdelay=10` to the kernel cmdline via armbianEnv.txt.
#    First-boot SD enumeration on RK3588 is racy; without this, initramfs
#    can hit "cannot mount root fs" on the first boot before the SD
#    controller finishes settling.
#
# 4) QEMU-PKG-RENAME (host pkg list + chroot installs):
#    Ubuntu 26.04 dropped the `qemu-user-static` package; the static binaries
#    moved into `qemu-user`, with binfmt registration in `qemu-user-binfmt`.
#    Armbian's framework still hardcodes `qemu-user-static`, which fails
#    `apt-get install` with "Package has no installation candidate". Rewrite
#    the package name to `qemu-user-binfmt` (which Depends: qemu-user, so we
#    get the binaries too) in every spot the framework references it.
#
# All four are idempotent. Override location with FRAMEWORK_DIR env var.
set -euo pipefail

FRAMEWORK_DIR="${FRAMEWORK_DIR:-$HOME/armbian-build/framework}"
cd "$FRAMEWORK_DIR"

deploy_target=lib/functions/rootfs/create-cache.sh
restore_target=lib/functions/main/rootfs-image.sh
bootdelay_target=lib/functions/rootfs/distro-agnostic.sh
qemu_pkg_targets=(
    lib/functions/host/prepare-host.sh
    lib/functions/rootfs/create-cache.sh
    lib/functions/rootfs/qemu-static.sh
)

deploy_needle='	create_sources_list_and_deploy_repo_key "image-early" "${RELEASE}" "${SDCARD}/"'
restore_needle='	LOG_SECTION="undeploy_qemu_binary_from_chroot_image" do_with_logging undeploy_qemu_binary_from_chroot "${SDCARD}" "image"'
bootdelay_needle='			run_host_command_logged echo "fdtfile=${BOOT_FDT_FILE}" ">>" "${SDCARD}/boot/armbianEnv.txt"'

# --- 1) DEPLOY ---
if grep -q 'uutils-qemu-shim' "$deploy_target"; then
    echo "deploy: already patched"
else
    awk -v needle="$deploy_needle" '
        $0 == needle && !done {
            print "\t# --- BEGIN uutils-shim (rust-coreutils chroot panic workaround) ---"
            print "\t# On aarch64 hosts whose kernel auxv handling does not satisfy rustix,"
            print "\t# every uutils binary panics when launched through chroot. Replace the"
            print "\t# /usr/bin/* symlinks pointing at /lib/cargo/bin/coreutils/* with a small"
            print "\t# shell shim that routes through qemu-user-static; qemu provides its own"
            print "\t# auxv so rustix is happy. /bin/sh itself is not uutils so the shim runs"
            print "\t# natively. Reversed in rootfs-image.sh before image creation."
            print "\tdisplay_alert \"Shimming rust-coreutils via qemu-user-static\" \"${SDCARD}\" \"info\""
            print "\tDEBIAN_FRONTEND=noninteractive apt-get install -y -qq qemu-user-static >/dev/null 2>&1 || true"
            print "\tif [[ -x /usr/bin/qemu-aarch64-static ]]; then"
            print "\t\trun_host_command_logged cp /usr/bin/qemu-aarch64-static \"${SDCARD}/usr/bin/qemu-aarch64-static\""
            print "\t\tcat > \"${SDCARD}/usr/bin/.uutils-qemu-shim\" <<'\''UUTILS_SHIM_EOF'\''"
            print "#!/bin/sh"
            print "arg0=${0##*/}"
            print "exec /usr/bin/qemu-aarch64-static /lib/cargo/bin/coreutils/\"$arg0\" \"$@\""
            print "UUTILS_SHIM_EOF"
            print "\t\tchmod +x \"${SDCARD}/usr/bin/.uutils-qemu-shim\""
            print "\t\twhile IFS= read -r _cmd; do"
            print "\t\t\tln -sfn .uutils-qemu-shim \"${SDCARD}/usr/bin/${_cmd}\""
            print "\t\tdone < <(find \"${SDCARD}/usr/bin/\" -maxdepth 1 -lname \"../lib/cargo/bin/coreutils/*\" -printf \"%f\\n\" 2>/dev/null)"
            print "\telse"
            print "\t\tdisplay_alert \"qemu-aarch64-static not available\" \"build will likely panic in chroot\" \"wrn\""
            print "\tfi"
            print "\t# --- END uutils-shim ---"
            print ""
            done = 1
        }
        { print }
    ' "$deploy_target" > "${deploy_target}.new"

    grep -q 'uutils-qemu-shim' "${deploy_target}.new" || { echo "deploy patch failed: needle not matched in ${deploy_target}" >&2; rm -f "${deploy_target}.new"; exit 1; }
    mv "${deploy_target}.new" "$deploy_target"
    echo "deploy: patched"
fi

# --- 2) RESTORE ---
if grep -q 'uutils-shim-restore' "$restore_target"; then
    echo "restore: already patched"
else
    awk -v needle="$restore_needle" '
        $0 == needle && !done {
            print "\t# --- BEGIN uutils-shim-restore ---"
            print "\t# Undo the rust-coreutils -> qemu-shim swap so the final image ships the"
            print "\t# original uutils symlinks. Safe here: all chroot operations are done,"
            print "\t# so restored uutils binaries (which would panic in chroot) wont be invoked."
            print "\tif [[ -e \"${SDCARD}/usr/bin/.uutils-qemu-shim\" ]]; then"
            print "\t\tdisplay_alert \"Restoring rust-coreutils symlinks\" \"${SDCARD}\" \"info\""
            print "\t\twhile IFS= read -r _cmd; do"
            print "\t\t\tln -sfn \"../lib/cargo/bin/coreutils/${_cmd}\" \"${SDCARD}/usr/bin/${_cmd}\""
            print "\t\tdone < <(find \"${SDCARD}/usr/bin/\" -maxdepth 1 -lname \".uutils-qemu-shim\" -printf \"%f\\n\" 2>/dev/null)"
            print "\t\trm -f \"${SDCARD}/usr/bin/.uutils-qemu-shim\" \"${SDCARD}/usr/bin/qemu-aarch64-static\""
            print "\tfi"
            print "\t# --- END uutils-shim-restore ---"
            print ""
            done = 1
        }
        { print }
    ' "$restore_target" > "${restore_target}.new"

    grep -q 'uutils-shim-restore' "${restore_target}.new" || { echo "restore patch failed: needle not matched in ${restore_target}" >&2; rm -f "${restore_target}.new"; exit 1; }
    mv "${restore_target}.new" "$restore_target"
    echo "restore: patched"
fi

# --- 3) BOOT-DELAY ---
if grep -q 'rk3588-boot-delay' "$bootdelay_target"; then
    echo "boot-delay: already patched"
else
    awk -v needle="$bootdelay_needle" '
        { print }
        seen && $0 ~ /^\t\tfi$/ && !done {
            print ""
            print "\t\t# --- BEGIN rk3588-boot-delay ---"
            print "\t\t# Append rootwait + rootdelay to the kernel cmdline. Without this the"
            print "\t\t# RK3588 SD controller can lose a race with initramfs root mount on the"
            print "\t\t# very first boot, dropping the user at (initramfs) with \"cannot mount\""
            print "\t\t# root fs\". Subsequent boots are usually fine, but baking these in makes"
            print "\t\t# the first boot reliable too."
            print "\t\tif [[ -f \"${SDCARD}/boot/armbianEnv.txt\" ]]; then"
            print "\t\t\tif grep -q \"^extraargs=\" \"${SDCARD}/boot/armbianEnv.txt\"; then"
            print "\t\t\t\tsed -i \"s|^extraargs=\\(.*\\)$|extraargs=\\1 rootwait rootdelay=10|\" \"${SDCARD}/boot/armbianEnv.txt\""
            print "\t\t\telse"
            print "\t\t\t\techo \"extraargs=rootwait rootdelay=10\" >> \"${SDCARD}/boot/armbianEnv.txt\""
            print "\t\t\tfi"
            print "\t\t\tdisplay_alert \"Boot-delay applied to armbianEnv.txt\" \"rootwait rootdelay=10\" \"info\""
            print "\t\tfi"
            print "\t\t# --- END rk3588-boot-delay ---"
            seen = 0; done = 1
        }
        $0 == needle { seen = 1 }
    ' "$bootdelay_target" > "${bootdelay_target}.new"

    grep -q 'rk3588-boot-delay' "${bootdelay_target}.new" || { echo "boot-delay patch failed: needle not matched in ${bootdelay_target}" >&2; rm -f "${bootdelay_target}.new"; exit 1; }
    mv "${bootdelay_target}.new" "$bootdelay_target"
    echo "boot-delay: patched"
fi

# --- 4) QEMU-PKG-RENAME ---
# Rewrite hardcoded `qemu-user-static` package references to
# `qemu-user-binfmt` (the Ubuntu 26.04 replacement that Depends: qemu-user,
# so we still get the static aarch64 binary). Display strings and binary
# paths (qemu-aarch64-static) are intentionally not touched. Idempotent:
# uses word-boundary match and re-runs are no-ops once renamed.
for f in "${qemu_pkg_targets[@]}"; do
    if [[ ! -f "$f" ]]; then
        echo "qemu-pkg: skipping missing $f"
        continue
    fi
    # Only rewrite when the package name appears as a standalone token
    # (preceded/followed by quote, space, or end-of-line) — leaves comments
    # and display_alert strings alone.
    if grep -qE '(^|[ "'"'"'])qemu-user-static([ "'"'"']|$)' "$f"; then
        sed -i -E 's/(^|[ "'"'"'])qemu-user-static([ "'"'"']|$)/\1qemu-user-binfmt\2/g' "$f"
        echo "qemu-pkg: patched $f"
    else
        echo "qemu-pkg: $f already clean"
    fi
done
