#!/usr/bin/env bash
#
# silverblue-rollback.sh — arm a rollback to the previous snapshot and reboot.
#
# Invoked by silverblue-rollback.service, which is started via the OnFailure= handler of
# silverblue-mark-good.service when a boot fails its post-boot health check.

set -uo pipefail

ENGINE=${SB_ENGINE:-/usr/bin/silverblue-update}
[[ -x "$ENGINE" ]] || ENGINE=silverblue-update

printf 'SILVERBLUE-ROLLBACK-ARMING\n'
if "$ENGINE" --rollback; then
    printf 'SILVERBLUE-ROLLBACK-ARMED\n'
else
    printf 'SILVERBLUE-ROLLBACK-FAILED (no previous snapshot?)\n' >&2
fi

# Reboot into the previous root. Honor SB_NO_REBOOT for testing the script in isolation.
if [[ -z "${SB_NO_REBOOT:-}" ]]; then
    systemctl reboot
fi
