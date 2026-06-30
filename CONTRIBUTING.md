# Contributing to Arch Silverblue

Thanks for helping out! This guide covers the dev setup, the test loop, and the few conventions
that keep the code testable and easy to rebrand.

> Rebranding/forking into your own distro is a different workflow — see **[DERIVING.md](DERIVING.md)**.
> You almost never need to edit `src/` to derive; you edit `config/distro.conf`.

## Prerequisites

The dev host needs only **Docker** and **QEMU**. `shellcheck` and `bats` are pulled on demand via
`nix shell`, so no Arch tooling is required on the host (Arch tooling runs inside the build
container and the QEMU guest). `systemd-analyze` (present on most Linux hosts) is used by
`verify-units`.

- For the fast inner loop: [Nix](https://nixos.org/download) (for `shellcheck`/`bats`).
- For ISO builds and the integration test: `docker` + `qemu-system-x86_64` + `qemu-img`.

## Dev loop

| Command | What it does | Needs |
|---------|--------------|-------|
| `make test` | `lint` + `test-unit` + `verify-units` — the fast inner loop | nix, systemd-analyze |
| `make build-iso` | Build the bootable ISO via Docker (also writes `iso/output/SHA256SUMS`) | docker (`--privileged`) + network |
| `make test-qemu` | Boot the ISO in QEMU; run the happy-path + rollback tests | qemu (KVM or TCG) |
| `make ci` | `test` + `build-iso` + `test-qemu` (full pipeline) | all of the above |

Run **`make test` before every change** — it is fast and needs no docker/qemu.

Targeted runs:

```bash
nix shell nixpkgs#bats --command bats tests/unit          # all unit tests
nix shell nixpkgs#bats --command bats tests/unit/test_rollback.bats   # one file
bash tests/qemu/run.sh                                     # integration (systemd-boot, default)
bash tests/qemu/run.sh --bootloader grub                  # integration against GRUB
bash tests/qemu/run.sh --net                              # update cycle over real pacman -Syu
```

## Conventions

These are load-bearing — please follow them:

- **shellcheck-clean.** Every shell script must pass `shellcheck -x` with zero findings. New
  scripts go in the `SHELL_FILES` list in the [`Makefile`](Makefile) so `make lint` covers them.
- **Scripts are sourceable.** The engine and the init scripts only run their `main`/`*_main`
  (and enable strict mode) when executed directly, guarded by
  `if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then set -euo pipefail; main "$@"; fi`. This lets the
  bats tests `source` them and call individual functions in isolation. Keep new entry-point
  scripts sourceable the same way.
- **Dependency-inject external commands.** The engine reaches `btrfs`, `bootctl`, `arch-chroot`,
  etc. through overridable variables (`BTRFS`, `BOOTCTL`, `ARCH_CHROOT`, `GRUB_EDITENV`, …) and
  reads config from `SB_*` env vars, so tests can mock them. Prefer adding **pure, unit-testable
  functions** over inlining effectful logic.
- **`SILVERBLUE-*` markers are a contract.** The uppercase progress markers (e.g.
  `SILVERBLUE-MARKGOOD-OK`, `SILVERBLUE-ROLLBACK-ARMED`) are grepped literally by the QEMU
  harness, and the build's `render()` deliberately leaves them untouched. Don't rename them.
- **Keep `src/` generic.** The source tree keeps the upstream `silverblue` names; all
  rebranding happens at build/install time from `config/distro.conf` (see DERIVING.md). Don't
  hardcode brand-specific strings into `src/`.

## CI

Every push and pull request runs `make test`. Pushes to `main` and tags also build the ISO and
upload it with its `SHA256SUMS`. The QEMU integration job is manual (`workflow_dispatch`) because
GitHub runners have no KVM and the TCG fallback is slow. See
[`.github/workflows/ci.yml`](.github/workflows/ci.yml).

## Pull requests

- Keep changes focused and explain the "why".
- Add or update tests for behavior changes; ensure `make test` is green.
- For anything that touches the boot/update/rollback path, note whether you ran `make test-qemu`
  (and against which `--bootloader`).
