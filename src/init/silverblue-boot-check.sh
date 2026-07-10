#!/usr/bin/env bash
#
# silverblue-boot-check.sh — post-boot health check entry point for OpenRC and dinit.
#
# systemd installs never run this: there the mark-good service's TimeoutStartSec= and
# OnFailure= provide the timeout and the failure->rollback dispatch. OpenRC and dinit have
# no equivalent, so their service definitions detach this wrapper, which self-manages both:
# wait for the boot to settle, run the health check under a hard timeout, and on any failure
# (including a hang) hand over to the rollback script.
#
# Sourceable for tests: it only runs boot_check_main (and enables strict mode) when executed
# directly.

boot_check_main() {
    local libdir=${SB_LIB_DIR:-/usr/lib/silverblue}
    local delay=${SB_MARKGOOD_DELAY:-15}
    local limit=${SB_MARKGOOD_TIMEOUT:-120}

    # Neither OpenRC nor dinit has an "is the system settled" notion (systemd's
    # After=multi-user.target); a short grace delay approximates it.
    sleep "$delay"

    if timeout "$limit" "$libdir/silverblue-mark-good.sh"; then
        return 0
    fi
    printf 'SILVERBLUE-MARKGOOD-FAIL-DISPATCH\n'
    exec "$libdir/silverblue-rollback.sh"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    set -uo pipefail
    boot_check_main "$@"
fi
