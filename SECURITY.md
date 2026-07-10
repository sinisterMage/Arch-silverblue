# Security Policy

## Reporting a vulnerability

Please report security issues **privately** via GitHub's "Report a vulnerability" flow on the
repository's **Security** tab
(<https://github.com/sinisterMage/Arch-silverblue/security/advisories/new>) rather than opening a
public issue. We'll acknowledge the report and work with you on a fix and disclosure timeline.

## Supported versions

Arch Silverblue is rolling: only the latest `main` is supported. There are no backports.

## Security posture — known, by-design behavior

The items below are intentional and specific to the **test/appliance** image. Please don't file
them as new vulnerabilities; if you can escalate one *beyond* what's described here, that's a
report we want.

- **The bundled autoinstaller is a test installer, not a hardened one.**
  `iso/airootfs/usr/local/bin/silverblue-autoinstall.sh` targets `/dev/vda`, wipes it
  unconditionally, and provisions a **passwordless root** with serial-console autologin. It is
  gated behind a QEMU `fw_cfg` blob (`ConditionPathExists=…/opt/silverblue/scenario/raw`), so it
  never runs on a normal/interactive boot or on real hardware.
- **The interactive installer (`silverblue-install`) is separate from the test appliance.**
  It only runs when the user invokes it, requires typing `ERASE` before any destructive step,
  requires a root password (no passwordless accounts on interactive targets), and never
  installs the test-only artifacts (no autologin drop-in, no `[silverblue-local]` repo). It is
  still a *minimal* installer: no LUKS, no Secure Boot — see
  [docs/installing.md](docs/installing.md) for its scope.
- **The offline test repo trusts unsigned packages.** The synthetic `[silverblue-local]` repo
  baked into the ISO for the hermetic update test uses `SigLevel = Optional TrustAll`. Derivatives
  that ship their own repositories should **sign them** and avoid `TrustAll` (see
  [DERIVING.md](DERIVING.md)).
- **The update engine disables the pacman sandbox inside the chroot.** `silverblue-update` runs
  `pacman -Syu --disable-sandbox` while upgrading the snapshot in a deep `arch-chroot` (a
  documented workaround for that environment). Signature verification of the official Arch repos
  still applies.
- **Snapshots are not a security boundary.** Btrfs snapshots and auto-rollback protect
  integrity/availability of the system root, not confidentiality. `/home` (`@home`) is shared
  across snapshots and is deliberately **not** rolled back, so data written there persists across
  a rollback.
- **Integrity manifests use a machine-local HMAC key — know what that buys.** Each update
  writes an HMAC-SHA256-signed manifest of the snapshot's `/usr` + `/boot` (and its ESP kernel
  copies under systemd-boot), stored with the key on the Btrfs toplevel outside every snapshot
  (see [docs/update-flow.md](docs/update-flow.md)). This **detects**: offline tampering with a
  non-running snapshot, bit-rot, and accidental modification — including modified, missing, and
  planted-extra files. It does **not** defend against an attacker who gains root on the running
  system: they can read `hmac.key` (root-only, 0600) and re-sign whatever they changed. Known
  scope limits, by design: `/etc` and `/var` are runtime-mutable and not covered; file metadata
  (modes/ownership) and symlink targets are not recorded; snapshots are never made read-only
  (every snapshot must remain bootable read-write, so a Btrfs `ro` property would brick the
  fallback); verification runs before rollbacks and on demand, not at boot, and the default
  rollback policy is `warn` (proceed loudly) so an unattended failure can never boot-loop —
  set `VERIFY_ON_ROLLBACK="strict"` if you prefer refusal over availability.
