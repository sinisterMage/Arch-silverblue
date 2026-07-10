#!/usr/bin/env bats
# init-backends.sh: init detection plus per-backend health, reboot and emergency dispatch.
#
# The library only defines functions, so we source it and drive it with stubbed init tools
# (bash functions shadow command lookup, the same technique as the other suites). Command
# paths that could hit real host binaries are pointed at nonexistent paths per test.

load helper

setup() {
    TMP="$(mktemp -d)"
    CMD_LOG="$TMP/cmd.log"
    : > "$CMD_LOG"
    # shellcheck source=/dev/null
    source "$SB_REPO/src/init/init-backends.sh"
}

teardown() { rm -rf "$TMP"; }

# --- Stubs (active only when the matching backend is selected via SB_INIT) -----------------

systemctl() {
    case "$1" in
        is-system-running) printf '%s\n' "${FAKE_STATE-running}" ;;
        is-active)         [[ "$2" == "${FAKE_INACTIVE_UNIT:-}" ]] && printf 'inactive\n' || printf 'active\n' ;;
        *)                 printf 'systemctl %s\n' "$*" >> "$CMD_LOG" ;;
    esac
}

rc-status() {
    case "$1" in
        -r)        printf '%s\n' "${FAKE_RUNLEVEL-default}" ;;
        --crashed) printf '%s' "${FAKE_CRASHED-}" ;;
    esac
}

rc-service() { [[ "$1" == "${FAKE_STOPPED_SVC:-}" ]] && return 1 || return 0; }

dinitctl() {
    case "$1" in
        status) printf 'Service: %s\n    State: %s\n' "$2" "${FAKE_BOOT_STATE-STARTED}" ;;
        list)   printf '%s\n' "${FAKE_DINIT_LIST-}" ;;
        start)  printf 'dinitctl %s\n' "$*" >> "$CMD_LOG"; return "${FAKE_DINIT_START_RC:-0}" ;;
    esac
}

# --- Detection ------------------------------------------------------------------------------

@test "SB_INIT override wins over probing" {
    SB_INIT=openrc
    run detect_init
    [ "$status" -eq 0 ]
    [ "$output" = "openrc" ]
}

@test "detects systemd from /run/systemd/system" {
    SB_RUN_DIR="$TMP/run"
    mkdir -p "$TMP/run/systemd/system"
    run detect_init
    [ "$output" = "systemd" ]
}

@test "detects openrc from /run/openrc" {
    SB_RUN_DIR="$TMP/run"
    mkdir -p "$TMP/run/openrc"
    run detect_init
    [ "$output" = "openrc" ]
}

@test "detects dinit from /run/dinit" {
    SB_RUN_DIR="$TMP/run"
    mkdir -p "$TMP/run/dinit"
    run detect_init
    [ "$output" = "dinit" ]
}

@test "falls back to dinit when dinitctl is available" {
    SB_RUN_DIR="$TMP/run"
    mkdir -p "$TMP/run"
    run detect_init   # the dinitctl stub above satisfies command -v
    [ "$output" = "dinit" ]
}

@test "fails when no init system is detectable" {
    SB_RUN_DIR="$TMP/run"
    mkdir -p "$TMP/run"
    DINITCTL="$TMP/no-such-dinitctl"
    run detect_init
    [ "$status" -eq 1 ]
}

@test "detect_root_init probes a root tree statically" {
    mkdir -p "$TMP/sd/usr/lib/systemd" "$TMP/rc/usr/bin" "$TMP/di/usr/bin" "$TMP/none"
    touch "$TMP/sd/usr/lib/systemd/systemd" "$TMP/rc/usr/bin/openrc" "$TMP/di/usr/bin/dinit"
    chmod +x "$TMP/sd/usr/lib/systemd/systemd" "$TMP/rc/usr/bin/openrc" "$TMP/di/usr/bin/dinit"
    [ "$(detect_root_init "$TMP/sd")" = systemd ]
    [ "$(detect_root_init "$TMP/rc")" = openrc ]
    [ "$(detect_root_init "$TMP/di")" = dinit ]
    [ "$(detect_root_init "$TMP/none")" = unknown ]
}

# --- systemd health (dispatch through init_health_check) ------------------------------------

@test "systemd: running is healthy" {
    SB_INIT=systemd FAKE_STATE=running
    run init_health_check
    [ "$status" -eq 0 ]
}

@test "systemd: degraded with a critical unit down is unhealthy" {
    SB_INIT=systemd FAKE_STATE=degraded FAKE_INACTIVE_UNIT=local-fs.target
    run init_health_check
    [ "$status" -eq 1 ]
}

# --- openrc health ---------------------------------------------------------------------------

@test "openrc: default runlevel, nothing crashed, criticals up -> healthy" {
    SB_INIT=openrc
    run init_health_check
    [ "$status" -eq 0 ]
}

@test "openrc: non-default runlevel is unhealthy" {
    SB_INIT=openrc FAKE_RUNLEVEL=single
    run init_health_check
    [ "$status" -eq 1 ]
}

@test "openrc: a crashed service is unhealthy" {
    SB_INIT=openrc FAKE_CRASHED='some-daemon'
    run init_health_check
    [ "$status" -eq 1 ]
    [[ "$output" == *some-daemon* ]]
}

@test "openrc: our own service in the crashed list is filtered out" {
    SB_INIT=openrc FAKE_CRASHED='silverblue-mark-good'
    run init_health_check
    [ "$status" -eq 0 ]
}

@test "openrc: a stopped critical service is unhealthy" {
    SB_INIT=openrc FAKE_STOPPED_SVC=localmount
    run init_health_check
    [ "$status" -eq 1 ]
}

# --- dinit health ----------------------------------------------------------------------------

@test "dinit: boot STARTED and clean list -> healthy" {
    SB_INIT=dinit
    run init_health_check
    [ "$status" -eq 0 ]
}

@test "dinit: boot service not started is unhealthy" {
    SB_INIT=dinit FAKE_BOOT_STATE='STOPPED'
    run init_health_check
    [ "$status" -eq 1 ]
}

@test "dinit: a failed service in the list is unhealthy" {
    SB_INIT=dinit FAKE_DINIT_LIST='[     ] some-daemon (failed)'
    run init_health_check
    [ "$status" -eq 1 ]
}

# --- reboot dispatch -------------------------------------------------------------------------

@test "init_reboot uses systemctl on systemd" {
    SB_INIT=systemd
    run init_reboot
    grep -qx 'systemctl reboot' "$CMD_LOG"
}

@test "init_reboot prefers openrc-shutdown on openrc" {
    SB_INIT=openrc
    openrc-shutdown() { printf 'openrc-shutdown %s\n' "$*" >> "$CMD_LOG"; }
    run init_reboot
    grep -qx 'openrc-shutdown -r now' "$CMD_LOG"
}

@test "init_reboot falls back to reboot when openrc-shutdown is absent" {
    SB_INIT=openrc
    OPENRC_SHUTDOWN="$TMP/no-such-openrc-shutdown"
    REBOOT_CMD=fake-reboot
    fake-reboot() { printf 'reboot\n' >> "$CMD_LOG"; }
    run init_reboot
    grep -qx 'reboot' "$CMD_LOG"
}

@test "init_reboot uses plain reboot on dinit" {
    SB_INIT=dinit
    REBOOT_CMD=fake-reboot
    fake-reboot() { printf 'reboot\n' >> "$CMD_LOG"; }
    run init_reboot
    grep -qx 'reboot' "$CMD_LOG"
}

# --- emergency dispatch (must never reboot) --------------------------------------------------

@test "init_emergency uses systemctl emergency on systemd" {
    SB_INIT=systemd
    run init_emergency
    grep -qx 'systemctl emergency' "$CMD_LOG"
    ! grep -q reboot "$CMD_LOG"
}

@test "init_emergency goes single-user on openrc" {
    SB_INIT=openrc
    OPENRC=fake-openrc
    fake-openrc() { printf 'openrc %s\n' "$*" >> "$CMD_LOG"; }
    run init_emergency
    [ "$status" -eq 0 ]
    grep -qx 'openrc single' "$CMD_LOG"
}

@test "init_emergency only warns when openrc has no emergency path" {
    SB_INIT=openrc
    OPENRC="$TMP/no-such-openrc"
    run init_emergency
    [ "$status" -eq 0 ]
    [[ "$output" == *"manual intervention required"* ]]
    [ ! -s "$CMD_LOG" ]
}

@test "init_emergency starts the dinit recovery service" {
    SB_INIT=dinit
    run init_emergency
    [ "$status" -eq 0 ]
    grep -qx 'dinitctl start recovery' "$CMD_LOG"
}

@test "init_emergency only warns when dinit recovery fails" {
    SB_INIT=dinit FAKE_DINIT_START_RC=1
    run init_emergency
    [ "$status" -eq 0 ]
    [[ "$output" == *"manual intervention required"* ]]
}
