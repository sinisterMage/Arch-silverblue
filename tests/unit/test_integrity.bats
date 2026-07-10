#!/usr/bin/env bats
# integrity.sh: HMAC-SHA256 correctness (RFC 4231 vectors), key management, manifest
# generate/verify round trips, tamper detection, and manifest cleanup on snapshot discard.
#
# Everything runs on tmpdirs — fake snapshot directories stand in for Btrfs subvolumes
# (the manifest code only reads files; it never needs real snapshots or root).

load helper

setup() {
    load_engine
    TMP="$(mktemp -d)"
    SB_TOPLEVEL_MNT="$TMP/top"
    BOOTLOADER=grub          # no ESP dir involved unless a test opts in
    SB_MANIFEST_PATHS="/usr /boot"
    DRY_RUN=false

    # A fake snapshot with some OS payload.
    SNAP=root-20260101-000000
    mkdir -p "$SB_TOPLEVEL_MNT/$SNAP/usr/bin" "$SB_TOPLEVEL_MNT/$SNAP/boot"
    printf 'binary-one\n' > "$SB_TOPLEVEL_MNT/$SNAP/usr/bin/one"
    printf 'binary-two\n' > "$SB_TOPLEVEL_MNT/$SNAP/usr/bin/two"
    printf 'kernel\n'     > "$SB_TOPLEVEL_MNT/$SNAP/boot/vmlinuz-linux"
}

teardown() { rm -rf "$TMP"; }

# --- HMAC correctness -------------------------------------------------------------------------

@test "hmac_sha256 matches RFC 4231 test case 1" {
    key=0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b
    run bash -c 'source '"$SB_REPO"'/src/update-engine/silverblue-update;
        printf "Hi There" | { hmac_sha256 '"$key"'; }'
    [ "$output" = "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7" ]
}

@test "hmac_sha256 matches RFC 4231 test case 2" {
    key=4a656665   # "Jefe"
    run bash -c 'source '"$SB_REPO"'/src/update-engine/silverblue-update;
        printf "what do ya want for nothing?" | { hmac_sha256 '"$key"'; }'
    [ "$output" = "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843" ]
}

# --- Key management ---------------------------------------------------------------------------

@test "ensure_hmac_key creates a 0600 key in a 0700 dir and reuses it" {
    ensure_hmac_key
    key_file="$SB_TOPLEVEL_MNT/.silverblue/hmac.key"
    [ -f "$key_file" ]
    [ "$(stat -c %a "$key_file")" = "600" ]
    [ "$(stat -c %a "$SB_TOPLEVEL_MNT/.silverblue")" = "700" ]
    first=$(cat "$key_file")
    [ "${#first}" -eq 64 ]
    ensure_hmac_key
    [ "$(cat "$key_file")" = "$first" ]
}

# --- Generate / verify round trips ------------------------------------------------------------

@test "generate then verify passes" {
    generate_manifest "$SNAP"
    run verify_manifest "$SNAP"
    [ "$status" -eq 0 ]
    [[ "$output" == *"SILVERBLUE-VERIFY-OK snap=$SNAP"* ]]
}

@test "verify without a manifest reports ABSENT (rc 2)" {
    run verify_manifest "$SNAP"
    [ "$status" -eq 2 ]
    [[ "$output" == *"SILVERBLUE-VERIFY-ABSENT snap=$SNAP"* ]]
}

@test "a modified file fails verification" {
    generate_manifest "$SNAP"
    printf 'tampered\n' > "$SB_TOPLEVEL_MNT/$SNAP/usr/bin/one"
    run verify_manifest "$SNAP"
    [ "$status" -eq 1 ]
    [[ "$output" == *"SILVERBLUE-VERIFY-FAIL snap=$SNAP"* ]]
    [[ "$output" == *usr/bin/one* ]]
}

@test "a missing file fails verification" {
    generate_manifest "$SNAP"
    rm "$SB_TOPLEVEL_MNT/$SNAP/usr/bin/two"
    run verify_manifest "$SNAP"
    [ "$status" -eq 1 ]
}

@test "an extra file fails verification" {
    generate_manifest "$SNAP"
    printf 'implant\n' > "$SB_TOPLEVEL_MNT/$SNAP/usr/bin/backdoor"
    run verify_manifest "$SNAP"
    [ "$status" -eq 1 ]
    [[ "$output" == *backdoor* ]]
}

@test "a tampered manifest (bad HMAC) fails verification" {
    generate_manifest "$SNAP"
    mfile="$SB_TOPLEVEL_MNT/.silverblue/manifests/$SNAP.manifest"
    sed -i 's/usr\/bin\/one/usr\/bin\/oNe/' "$mfile"
    run verify_manifest "$SNAP"
    [ "$status" -eq 1 ]
    [[ "$output" == *"HMAC mismatch"* ]]
}

@test "a corrupted .hmac file fails verification" {
    generate_manifest "$SNAP"
    printf 'deadbeef\n' > "$SB_TOPLEVEL_MNT/.silverblue/manifests/$SNAP.manifest.hmac"
    run verify_manifest "$SNAP"
    [ "$status" -eq 1 ]
}

@test "systemd-boot manifests cover the snapshot's ESP kernel copies" {
    BOOTLOADER=systemd-boot
    SB_EFI_DIR="$TMP/efi"
    SB_ESP_SUBDIR=silverblue
    mkdir -p "$SB_EFI_DIR/silverblue/$SNAP"
    printf 'esp-kernel\n' > "$SB_EFI_DIR/silverblue/$SNAP/vmlinuz-linux"
    generate_manifest "$SNAP"
    grep -q "esp:vmlinuz-linux" "$SB_TOPLEVEL_MNT/.silverblue/manifests/$SNAP.manifest"
    run verify_manifest "$SNAP"
    [ "$status" -eq 0 ]
    printf 'evil-kernel\n' > "$SB_EFI_DIR/silverblue/$SNAP/vmlinuz-linux"
    run verify_manifest "$SNAP"
    [ "$status" -eq 1 ]
}

@test "dry-run generate_manifest touches nothing" {
    DRY_RUN=true
    run generate_manifest "$SNAP"
    [ "$status" -eq 0 ]
    [ ! -e "$SB_TOPLEVEL_MNT/.silverblue" ]
}

# --- Cleanup on snapshot discard ---------------------------------------------------------------

@test "discard_snapshot deletes the manifest pair" {
    PATH="$SB_REPO/tests/unit/mocks:$PATH"
    generate_manifest "$SNAP"
    mfile="$SB_TOPLEVEL_MNT/.silverblue/manifests/$SNAP.manifest"
    [ -f "$mfile" ]
    discard_snapshot "$SNAP"
    [ ! -f "$mfile" ]
    [ ! -f "$mfile.hmac" ]
}

@test "delete_manifest is a no-op when nothing exists" {
    run delete_manifest "$SNAP"
    [ "$status" -eq 0 ]
}

# --- Rollback verification policy --------------------------------------------------------------
# verified_rollback_target prints the chosen snapshot on stdout; warnings go to stderr, so a
# plain command substitution captures exactly the decision.

policy_snaps() {
    mkdir -p "$SB_TOPLEVEL_MNT"/root-20260102-000000 "$SB_TOPLEVEL_MNT"/root-20260103-000000
    CURRENT_SUBVOL=root-20260103-000000
}

@test "previous_snapshots lists non-current snapshots newest first" {
    policy_snaps
    run previous_snapshots
    [ "${lines[0]}" = root-20260102-000000 ]
    [ "${lines[1]}" = "$SNAP" ]
}

@test "warn policy proceeds with the target even when verification fails" {
    verify_manifest() { return 1; }
    SB_VERIFY_ON_ROLLBACK=warn
    out=$(verified_rollback_target root-x 2>"$TMP/err")
    [ "$out" = root-x ]
    grep -q 'SILVERBLUE-VERIFY-WARN snap=root-x' "$TMP/err"
}

@test "strict policy falls through to an older verified snapshot" {
    policy_snaps
    SB_VERIFY_ON_ROLLBACK=strict
    verify_manifest() { [[ "$1" == "$SNAP" ]]; }   # only the oldest verifies
    out=$(verified_rollback_target root-20260102-000000 2>/dev/null)
    [ "$out" = "$SNAP" ]
}

@test "strict policy accepts a manifest-less snapshot with a note" {
    policy_snaps
    SB_VERIFY_ON_ROLLBACK=strict
    verify_manifest() { return 2; }
    out=$(verified_rollback_target root-20260102-000000 2>/dev/null)
    [ "$out" = root-20260102-000000 ]
}

@test "strict policy fails before arming when nothing verifies" {
    policy_snaps
    SB_VERIFY_ON_ROLLBACK=strict
    verify_manifest() { return 1; }
    run verified_rollback_target root-20260102-000000
    [ "$status" -eq 1 ]
}

@test "off policy skips verification entirely" {
    SB_VERIFY_ON_ROLLBACK=off
    verify_manifest() { return 1; }
    out=$(verified_rollback_target root-x)
    [ "$out" = root-x ]
}

# --- CLI parsing --------------------------------------------------------------------------------

@test "parse_args: --verify alone and with a snapshot" {
    parse_args --verify
    [ "$DO_VERIFY" = true ]
    [ -z "$VERIFY_TARGET" ]
    DO_VERIFY=false
    parse_args --verify root-20260101-000000
    [ "$DO_VERIFY" = true ]
    [ "$VERIFY_TARGET" = root-20260101-000000 ]
}

@test "parse_args: --generate-manifest requires and takes a snapshot" {
    parse_args --generate-manifest root-20260101-000000
    [ "$DO_GEN_MANIFEST" = root-20260101-000000 ]
    run parse_args --generate-manifest
    [ "$status" -eq 1 ]
}

@test "parse_args: unknown arguments still die" {
    run parse_args --bogus
    [ "$status" -eq 1 ]
}
