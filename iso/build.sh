#!/usr/bin/env bash
#
# build.sh — assemble and build the Arch Silverblue ISO with archiso/mkarchiso.
#
# Runs inside the container defined by iso/Dockerfile (Arch, root, --privileged). It starts
# from the official `releng` profile, overlays our airootfs, injects the Silverblue tools at
# their final paths, builds a synthetic local pacman repo (for the hermetic update test), and
# invokes mkarchiso. The finished ISO lands in iso/output/.
set -euo pipefail

REPO=${SB_REPO_DIR:-/build}
PROFILE=${SB_PROFILE_DIR:-/tmp/silverblue-profile}
WORK=${SB_WORK_DIR:-/tmp/archiso-work}
OUT="$REPO/iso/output"
RELENG=${SB_RELENG_DIR:-/usr/share/archiso/configs/releng}

log() { printf '[build] %s\n' "$*"; }

require() {
    command -v "$1" >/dev/null 2>&1 || { printf 'missing tool: %s\n' "$1" >&2; exit 1; }
}

# --- Build a minimal pacman package (.PKGINFO + payload) without makepkg -------------------
# Args: name version arch destdir
make_pkg() {
    local name=$1 ver=$2 arch=$3 dest=$4
    local root
    root=$(mktemp -d)
    mkdir -p "$root/etc"
    printf '%s version %s\n' "$name" "$ver" > "$root/etc/silverblue-marker"
    {
        printf 'pkgname = %s\n' "$name"
        printf 'pkgver = %s-1\n' "$ver"
        printf 'pkgdesc = Arch Silverblue test marker package\n'
        printf 'arch = %s\n' "$arch"
        printf 'builddate = 0\n'
        printf 'size = 32\n'
    } > "$root/.PKGINFO"
    ( cd "$root" && bsdtar --zstd -cf "$dest/${name}-${ver}-1-${arch}.pkg.tar.zst" .PKGINFO etc )
    rm -rf "$root"
}

main() {
    require mkarchiso
    require bsdtar
    require repo-add

    log "Preparing profile from $RELENG"
    rm -rf "$PROFILE"
    cp -r "$RELENG" "$PROFILE"

    log "Overlaying iso/airootfs"
    cp -rT "$REPO/iso/airootfs" "$PROFILE/airootfs"

    # --- Inject the Silverblue tools at their installed paths -----------------------------
    log "Injecting Silverblue tools"
    local A="$PROFILE/airootfs"
    install -Dm0755 "$REPO/src/update-engine/silverblue-update" "$A/usr/bin/silverblue-update"
    install -Dm0644 "$REPO/src/bootloader/sdboot-helpers.sh"     "$A/usr/lib/silverblue/sdboot-helpers.sh"
    install -Dm0644 "$REPO/src/bootloader/grub-helpers.sh"       "$A/usr/lib/silverblue/grub-helpers.sh"
    install -Dm0755 "$REPO/src/init/silverblue-mark-good.sh"     "$A/usr/lib/silverblue/silverblue-mark-good.sh"
    install -Dm0755 "$REPO/src/init/silverblue-rollback.sh"      "$A/usr/lib/silverblue/silverblue-rollback.sh"
    install -Dm0644 "$REPO/src/init/silverblue-mark-good.service" "$A/usr/lib/systemd/system/silverblue-mark-good.service"
    install -Dm0644 "$REPO/src/init/silverblue-rollback.service"  "$A/usr/lib/systemd/system/silverblue-rollback.service"
    install -Dm0644 "$REPO/src/init/silverblue-rollback.target"   "$A/usr/lib/systemd/system/silverblue-rollback.target"
    install -Dm0644 "$REPO/src/init/silverblue-watchdog.conf"     "$A/etc/systemd/system.conf.d/silverblue-watchdog.conf"
    chmod 0755 "$A/usr/local/bin/silverblue-autoinstall.sh"

    # Ensure the executables are 0755 in the live ISO. mkarchiso applies file_permissions from
    # profiledef.sh; without an entry it may normalize files to 0644 (which would make the
    # enabled mark-good.service fail to exec). Inject entries into the existing array literal.
    sed -i '/^file_permissions=(/a \  ["/usr/bin/silverblue-update"]="0:0:755"\n  ["/usr/lib/silverblue/silverblue-mark-good.sh"]="0:0:755"\n  ["/usr/lib/silverblue/silverblue-rollback.sh"]="0:0:755"\n  ["/usr/local/bin/silverblue-autoinstall.sh"]="0:0:755"' \
        "$PROFILE/profiledef.sh"

    # --- Enable services in the live ISO --------------------------------------------------
    log "Enabling services"
    mkdir -p "$A/etc/systemd/system/multi-user.target.wants"
    ln -sf /usr/lib/systemd/system/silverblue-mark-good.service \
        "$A/etc/systemd/system/multi-user.target.wants/silverblue-mark-good.service"
    # The autoinstaller is driven by the QEMU harness over the serial autologin shell, so it
    # is NOT auto-enabled here (its service file remains for the optional fw_cfg-driven path).

    # --- Synthetic local package repo for the hermetic update test ------------------------
    log "Building synthetic local repo (silverblue-marker 1 -> 2)"
    local instdir="$A/opt/silverblue/install" repodir="$A/opt/silverblue/localrepo"
    mkdir -p "$instdir" "$repodir"
    make_pkg silverblue-marker 1 any "$instdir"
    make_pkg silverblue-marker 2 any "$repodir"
    ( cd "$repodir" && repo-add silverblue-local.db.tar.gz ./*.pkg.tar.zst >/dev/null )

    # --- Extra packages needed by the autoinstaller ---------------------------------------
    log "Adding packages to the ISO package list"
    {
        printf '%s\n' arch-install-scripts btrfs-progs dosfstools gptfdisk mkinitcpio efibootmgr
    } >> "$PROFILE/packages.x86_64"
    sort -u -o "$PROFILE/packages.x86_64" "$PROFILE/packages.x86_64"

    # --- Serial console on the live ISO ---------------------------------------------------
    # The headless QEMU harness reads the install over the serial port, so the live boot must
    # log to ttyS0. (The installed target sets this itself in its own boot entry.)
    log "Adding serial console to ISO boot entries"
    local f
    while IFS= read -r -d '' f; do
        sed -i -E 's|^(options[[:space:]].*)$|\1 console=ttyS0,115200 console=tty0|' "$f"
    done < <(find "$PROFILE" -path '*loader/entries/*.conf' -type f -print0)
    if [[ -d "$PROFILE/syslinux" ]]; then
        find "$PROFILE/syslinux" -name '*.cfg' -type f -exec \
            sed -i -E 's|^([[:space:]]*APPEND .*)$|\1 console=ttyS0,115200 console=tty0|' {} + || true
    fi

    # --- Build -----------------------------------------------------------------------------
    mkdir -p "$OUT" "$WORK"
    log "Running mkarchiso (this downloads packages; needs network + --privileged)"
    mkarchiso -v -w "$WORK" -o "$OUT" "$PROFILE"

    log "Done. ISO(s):"
    ls -lh "$OUT"/*.iso
}

main "$@"
