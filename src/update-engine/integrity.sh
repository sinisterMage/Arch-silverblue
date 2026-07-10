# shellcheck shell=bash
#
# integrity.sh — HMAC-authenticated checksum manifests for snapshots.
#
# Each update writes a manifest of SHA-256 hashes for the new snapshot's OS payload
# (SB_MANIFEST_PATHS, default /usr /boot — /etc and /var are deliberately excluded: a booted
# root legitimately mutates them, and manifests are only generated once, at update time).
# On systemd-boot the snapshot's kernel/initramfs copies on the ESP are the real boot payload,
# so they are recorded too, with an "esp:" path prefix.
#
# The manifest is authenticated with HMAC-SHA256 under a machine-local key. Key and manifests
# live on the Btrfs toplevel (subvolid=5) under $SB_STATE_SUBDIR — outside every snapshot, so
# they are shared across roots, survive rollbacks, and are not part of the object they verify.
# Threat model (see SECURITY.md): this detects offline tampering, bit-rot and accidental
# modification of non-running snapshots; an attacker with root can read the key and re-sign.
#
# The HMAC is built on coreutils sha256sum alone (standard RFC 2104 ipad/opad construction):
# openssl is not in the minimal package set, and `openssl dgst -hmac KEY` would leak the key
# to unprivileged users via world-readable /proc/<pid>/cmdline for the duration of the hash.
# Validated against RFC 4231 test vectors in the unit tests.
#
# Library contract: functions only; relies on the engine's log/err/vlog/sb_run and the
# SB_TOPLEVEL_MNT/SB_EFI_DIR/SB_ESP_SUBDIR/BOOTLOADER/DRY_RUN context.

# --- Dependency-injected command paths ------------------------------------------------------
: "${SHA256SUM:=sha256sum}"

# --- Configuration (override via environment) ----------------------------------------------
: "${SB_STATE_SUBDIR:=.silverblue}"       # state dir on the Btrfs toplevel, next to the snapshots
: "${SB_MANIFEST_PATHS:=/usr /boot}"      # snapshot paths covered by the manifest
: "${SB_VERIFY_ON_ROLLBACK:=warn}"        # rollback policy: warn | strict | off

integrity_state_dir()   { printf '%s/%s\n' "$SB_TOPLEVEL_MNT" "$SB_STATE_SUBDIR"; }
integrity_key_path()    { printf '%s/hmac.key\n' "$(integrity_state_dir)"; }
integrity_manifest_path() { printf '%s/manifests/%s.manifest\n' "$(integrity_state_dir)" "$1"; }

# Write raw bytes for a hex string to stdout (raw bytes must never sit in a bash variable:
# command substitution strips NULs).
_hex_to_raw() {
    local hex=$1 i esc=""
    for (( i = 0; i < ${#hex}; i += 2 )); do esc+="\\x${hex:i:2}"; done
    printf '%b' "$esc"
}

# hmac_sha256 <hex-key> — HMAC-SHA256 of stdin, hex digest on stdout (RFC 2104).
hmac_sha256() {
    local keyhex=$1 i b ipad="" opad="" inner
    # Keys longer than the 64-byte SHA-256 block are hashed down first.
    if (( ${#keyhex} > 128 )); then
        keyhex=$(_hex_to_raw "$keyhex" | "$SHA256SUM" | cut -d' ' -f1)
    fi
    while (( ${#keyhex} < 128 )); do keyhex+="00"; done
    for (( i = 0; i < 128; i += 2 )); do
        b=$(( 16#${keyhex:i:2} ))
        ipad+=$(printf '\\x%02x' $(( b ^ 0x36 )))
        opad+=$(printf '\\x%02x' $(( b ^ 0x5c )))
    done
    inner=$({ printf '%b' "$ipad"; cat; } | "$SHA256SUM" | cut -d' ' -f1)
    { printf '%b' "$opad"; _hex_to_raw "$inner"; } | "$SHA256SUM" | cut -d' ' -f1
}

# Create the machine-local HMAC key on first use (0600, dir 0700, on the toplevel subvolume).
ensure_hmac_key() {
    local dir key_file
    dir=$(integrity_state_dir)
    key_file="$dir/hmac.key"
    [[ -f "$key_file" ]] && return 0
    if $DRY_RUN; then log "DRY: generate HMAC key $key_file"; return 0; fi
    mkdir -p "$dir" "$dir/manifests"
    chmod 0700 "$dir"
    (umask 077; od -An -tx1 -N32 /dev/urandom | tr -d ' \n' > "$key_file.tmp")
    mv -f "$key_file.tmp" "$key_file"
    vlog "generated HMAC key at $key_file"
}

# manifest_walk <snap-root> [esp-snap-dir] — hash every regular file under SB_MANIFEST_PATHS
# (paths recorded relative to the snapshot root) plus the snapshot's ESP kernel dir when
# given (recorded with an esp: prefix). Sorted under LC_ALL=C so the order is byte-stable
# across environments (the installer writes the initial manifest from the live ISO, but it
# is verified on the installed system, whose locale collates differently).
manifest_walk() {
    local root=$1 esp_dir=${2:-} p
    for p in $SB_MANIFEST_PATHS; do
        [[ -d "$root$p" ]] || continue
        (cd "$root" && find ".$p" -xdev -type f -print0 | LC_ALL=C sort -z | xargs -0 -r "$SHA256SUM")
    done
    if [[ -n "$esp_dir" && -d "$esp_dir" ]]; then
        (cd "$esp_dir" && find . -maxdepth 1 -type f -print0 | LC_ALL=C sort -z | xargs -0 -r "$SHA256SUM") \
            | sed 's|  \./|  esp:|'
    fi
}

# The snapshot's per-snapshot kernel dir on the ESP — only systemd-boot copies kernels there
# (GRUB reads them from the subvolume's /boot, which the manifest already covers).
_esp_dir_for() {
    local snap=$1
    if [[ "${BOOTLOADER:-}" == systemd-boot ]]; then
        printf '%s/%s/%s\n' "$SB_EFI_DIR" "${SB_ESP_SUBDIR:-silverblue}" "$snap"
    fi
}

# generate_manifest <snap> — write + HMAC-sign the manifest for a snapshot.
generate_manifest() {
    local snap=$1
    local root="$SB_TOPLEVEL_MNT/$snap"
    local dir mfile hfile esp_dir key
    if $DRY_RUN; then log "DRY: generate integrity manifest for $snap"; return 0; fi
    [[ -d "$root" ]] || { err "no such snapshot to manifest: $snap"; return 1; }
    ensure_hmac_key || return 1
    dir="$(integrity_state_dir)/manifests"
    mkdir -p "$dir"
    mfile=$(integrity_manifest_path "$snap")
    hfile="$mfile.hmac"
    esp_dir=$(_esp_dir_for "$snap")
    key=$(<"$(integrity_key_path)")
    if ! (umask 077; manifest_walk "$root" "$esp_dir" > "$mfile.tmp"); then
        rm -f "$mfile.tmp"
        err "manifest generation failed for $snap"
        return 1
    fi
    (umask 077; hmac_sha256 "$key" < "$mfile.tmp" > "$hfile.tmp")
    mv -f "$mfile.tmp" "$mfile"
    mv -f "$hfile.tmp" "$hfile"
    vlog "manifest: $(wc -l < "$mfile") files recorded for $snap"
}

# verify_manifest <snap> — recompute and compare. Returns 0 (ok), 1 (tampered: bad HMAC,
# or modified/missing/extra files), 2 (no manifest — e.g. a pre-feature snapshot).
verify_manifest() {
    local snap=$1
    local root="$SB_TOPLEVEL_MNT/$snap"
    local mfile hfile esp_dir key want have drift n
    mfile=$(integrity_manifest_path "$snap")
    hfile="$mfile.hmac"
    if [[ ! -f "$mfile" || ! -f "$hfile" ]]; then
        log "SILVERBLUE-VERIFY-ABSENT snap=$snap"
        return 2
    fi
    [[ -d "$root" ]] || { err "no such snapshot: $snap"; return 1; }
    if [[ ! -f "$(integrity_key_path)" ]]; then
        err "HMAC key missing; cannot authenticate manifest for $snap"
        log "SILVERBLUE-VERIFY-FAIL snap=$snap"
        return 1
    fi
    key=$(<"$(integrity_key_path)")
    want=$(<"$hfile")
    have=$(hmac_sha256 "$key" < "$mfile")
    if [[ "$have" != "$want" ]]; then
        err "manifest HMAC mismatch for $snap (the manifest itself was modified)"
        log "SILVERBLUE-VERIFY-FAIL snap=$snap"
        return 1
    fi
    esp_dir=$(_esp_dir_for "$snap")
    # One diff catches everything: modified files (hash changed), missing files (only in the
    # manifest) and extra files (only on disk). '<' = recorded at update time, '>' = disk now.
    drift=$(diff "$mfile" <(manifest_walk "$root" "$esp_dir") || true)
    if [[ -n "$drift" ]]; then
        err "integrity drift for $snap ('<' recorded at update time, '>' on disk now):"
        printf '%s\n' "$drift" | grep '^[<>]' | head -20 >&2
        n=$(printf '%s\n' "$drift" | grep -c '^[<>]')
        (( n > 20 )) && err "... $n drift lines total"
        log "SILVERBLUE-VERIFY-FAIL snap=$snap"
        return 1
    fi
    log "SILVERBLUE-VERIFY-OK snap=$snap"
    return 0
}

# delete_manifest <snap> — drop the manifest pair when its snapshot is discarded.
delete_manifest() {
    local snap=$1 mfile
    [[ -n "$snap" ]] || return 0
    mfile=$(integrity_manifest_path "$snap")
    [[ -f "$mfile" || -f "$mfile.hmac" ]] || return 0
    sb_run rm -f -- "$mfile" "$mfile.hmac"
}
