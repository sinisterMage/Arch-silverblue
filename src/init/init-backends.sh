# shellcheck shell=bash
#
# init-backends.sh — init-system abstraction for the health-check / rollback machinery.
#
# Sourced by silverblue-mark-good.sh, silverblue-rollback.sh and the update engine so that
# "is this boot healthy?" and "reboot / drop to emergency" are expressed once per init system
# instead of hardcoding systemctl. Shipped backends: systemd, OpenRC, dinit.
#
# Health semantics per backend (no init has a perfect analog of another, so each check maps
# to that init's native notion of "the boot completed and nothing critical failed"):
#
#   systemd   `is-system-running` in {running, starting, initializing} is healthy; `degraded`
#             is healthy iff every unit in SB_CRITICAL_UNITS is active; anything else fails.
#   openrc    the current runlevel is `default`, `rc-status --crashed` lists nothing (our own
#             service filtered out defensively), and every service in SB_CRITICAL_OPENRC
#             reports started via `rc-service <svc> status`.
#   dinit     `dinitctl status $SB_DINIT_BOOT_SERVICE` reports STARTED and no line of
#             `dinitctl list` carries a failed marker. (dinitctl output is not a stable API;
#             the patterns are deliberately tolerant.)
#
# There is no OnFailure=/TimeoutStartSec= equivalent on OpenRC/dinit: those integrations run
# silverblue-boot-check.sh, which self-manages the timeout and failure->rollback dispatch.
# The systemd watchdog drop-in has no analog either — on OpenRC/dinit, hang protection comes
# from bootloader boot-counting / GRUB recordfail only.
#
# Library contract: functions only (safe to source from bats). Command paths are dependency-
# injected for tests; logging falls back to local no-ops when the engine's helpers are absent
# (silverblue-rollback.sh sources this file without the engine).

# --- Dependency-injected command paths (override in tests / unusual layouts) ---------------
: "${SYSTEMCTL:=systemctl}"
: "${RC_STATUS:=rc-status}"
: "${RC_SERVICE:=rc-service}"
: "${DINITCTL:=dinitctl}"
: "${OPENRC_SHUTDOWN:=openrc-shutdown}"
: "${OPENRC:=openrc}"
: "${REBOOT_CMD:=reboot}"

# --- Configuration (override via environment) ----------------------------------------------
: "${SB_INIT:=}"                                   # force a backend: systemd | openrc | dinit
: "${SB_RUN_DIR:=/run}"                            # probe root for detection (tests point at a tmpdir)
: "${SB_CRITICAL_UNITS:=local-fs.target sysinit.target}"   # systemd units that must be active when degraded
: "${SB_CRITICAL_OPENRC:=localmount}"              # openrc services that must be started
: "${SB_DINIT_BOOT_SERVICE:=boot}"                 # dinit service that anchors "boot completed"
: "${SB_MARKGOOD_NAME:=silverblue-mark-good}"      # our own service name (filtered from crash lists)

# Logging fallbacks so this library is sourceable without the engine.
if ! declare -F log >/dev/null; then log() { printf '%s\n' "$*" >&2; }; fi
if ! declare -F err >/dev/null; then err() { printf 'error: %s\n' "$*" >&2; }; fi
if ! declare -F vlog >/dev/null; then vlog() { :; }; fi

# Print the running init system: "systemd", "openrc" or "dinit". SB_INIT wins; otherwise
# probe the runtime directories each init creates. Fails (with an error) when none matches.
detect_init() {
    if [[ -n "$SB_INIT" ]]; then printf '%s\n' "$SB_INIT"; return 0; fi
    if [[ -d "$SB_RUN_DIR/systemd/system" ]]; then printf 'systemd\n'; return 0; fi
    if [[ -d "$SB_RUN_DIR/openrc" ]]; then printf 'openrc\n'; return 0; fi
    if [[ -d "$SB_RUN_DIR/dinit" ]] || command -v "$DINITCTL" >/dev/null 2>&1; then
        printf 'dinit\n'
        return 0
    fi
    err "could not detect init system (set SB_INIT=systemd|openrc|dinit)"
    return 1
}

# Print the init system a (non-running) root tree at $1 was built for: static file probe,
# used by the update engine to pick the right validation for a new snapshot.
detect_root_init() {
    local root=$1
    if [[ -x "$root/usr/lib/systemd/systemd" ]]; then
        printf 'systemd\n'
    elif [[ -x "$root/usr/bin/openrc" || -x "$root/sbin/openrc-run" || -x "$root/usr/bin/openrc-run" ]]; then
        printf 'openrc\n'
    elif [[ -x "$root/usr/bin/dinit" || -x "$root/sbin/dinit" ]]; then
        printf 'dinit\n'
    else
        printf 'unknown\n'
    fi
}

# Returns 0 if the current boot is healthy according to the running init system.
init_health_check() {
    local init
    init=$(detect_init) || return 1
    vlog "init system: $init"
    case "$init" in
        systemd) _systemd_health ;;
        openrc)  _openrc_health ;;
        dinit)   _dinit_health ;;
        *)       err "unsupported init system: $init"; return 1 ;;
    esac
}

_systemd_health() {
    local state u
    state=$("$SYSTEMCTL" is-system-running 2>/dev/null || true)
    vlog "system state: ${state:-unknown}"
    case "$state" in
        running|starting|initializing)
            return 0
            ;;
        degraded)
            for u in $SB_CRITICAL_UNITS; do
                if [[ "$("$SYSTEMCTL" is-active "$u" 2>/dev/null || true)" != active ]]; then
                    err "critical unit not active: $u"
                    return 1
                fi
            done
            return 0
            ;;
        *)
            err "unexpected system state: ${state:-unknown}"
            return 1
            ;;
    esac
}

_openrc_health() {
    local runlevel crashed svc
    runlevel=$("$RC_STATUS" -r 2>/dev/null || true)
    vlog "openrc runlevel: ${runlevel:-unknown}"
    if [[ "$runlevel" != default ]]; then
        err "unexpected runlevel: ${runlevel:-unknown}"
        return 1
    fi
    # A backgrounded oneshot must never self-trip the check, so filter our own name.
    crashed=$("$RC_STATUS" --crashed 2>/dev/null | grep -vF "$SB_MARKGOOD_NAME" | grep -v '^[[:space:]]*$' || true)
    if [[ -n "$crashed" ]]; then
        err "crashed services: $(printf '%s' "$crashed" | tr '\n' ' ')"
        return 1
    fi
    for svc in $SB_CRITICAL_OPENRC; do
        if ! "$RC_SERVICE" "$svc" status >/dev/null 2>&1; then
            err "critical service not started: $svc"
            return 1
        fi
    done
    return 0
}

_dinit_health() {
    local boot_status failed
    boot_status=$("$DINITCTL" status "$SB_DINIT_BOOT_SERVICE" 2>/dev/null || true)
    if ! printf '%s\n' "$boot_status" | grep -q 'STARTED'; then
        err "dinit boot service '$SB_DINIT_BOOT_SERVICE' not started"
        return 1
    fi
    failed=$("$DINITCTL" list 2>/dev/null | grep -iF 'failed' | grep -vF "$SB_MARKGOOD_NAME" || true)
    if [[ -n "$failed" ]]; then
        err "dinit reports failed services: $(printf '%s' "$failed" | tr '\n' ' ')"
        return 1
    fi
    return 0
}

# Reboot via the running init system's native mechanism.
init_reboot() {
    local init
    init=$(detect_init 2>/dev/null) || init=""
    case "$init" in
        systemd)
            "$SYSTEMCTL" reboot
            ;;
        openrc)
            if command -v "$OPENRC_SHUTDOWN" >/dev/null 2>&1; then
                "$OPENRC_SHUTDOWN" -r now
            else
                "$REBOOT_CMD"
            fi
            ;;
        dinit|*)
            # dinit installs reboot as a symlink to its shutdown utility, and a plain
            # `reboot` is the portable last resort for anything unrecognized.
            "$REBOOT_CMD"
            ;;
    esac
}

# Best-effort transition to a single-user/emergency environment for operator intervention.
# Never reboots: the caller reaches this exactly when rebooting would loop into the same
# failing root, so on inits without a usable emergency mode we only warn.
init_emergency() {
    local init
    init=$(detect_init 2>/dev/null) || init=""
    case "$init" in
        systemd)
            "$SYSTEMCTL" emergency
            ;;
        openrc)
            if command -v "$OPENRC" >/dev/null 2>&1; then
                "$OPENRC" single
            else
                err "no emergency mode available (openrc not found); manual intervention required"
            fi
            ;;
        dinit)
            if ! "$DINITCTL" start recovery 2>/dev/null; then
                err "no emergency mode available (dinit recovery service failed); manual intervention required"
            fi
            ;;
        *)
            err "no emergency mode available (unknown init); manual intervention required"
            ;;
    esac
    return 0
}
