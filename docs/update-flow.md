# Arch Silverblue — Update & Rollback Flow

Arch Silverblue makes system updates **atomic** and **auto-rolling-back** while keeping the
running system **fully mutable**. There is no read-only `/usr`, no overlayfs, and no immutable
root — atomicity comes entirely from Btrfs copy-on-write snapshots.

Each update builds a *new* root in a fresh snapshot, boots it *once*, and only promotes it to
the permanent default after a post-boot health check passes. If that boot fails or hangs, the
bootloader falls back to the previous root.

## On-disk layout

This is the layout both installers create — the interactive `silverblue-install` (see
[installing.md](installing.md)) and the unattended QEMU test appliance.

```
GPT disk (e.g. /dev/vda)
├─ p1  ESP  (FAT32, mounted at /efi)        kernels for systemd-boot live here per-snapshot
└─ p2  Btrfs pool (single device, one UUID)
       ├─ root-20260615-120000   ← a complete bootable root (/usr /etc /var /boot ...)
       ├─ root-20260628-093000   ← newer per-update snapshot
       └─ @home                  ← shared /home, never snapshotted (survives rollback)
```

Only one thing changes between boot entries: the kernel command line selects the root
subvolume.

```
root=UUID=<pool-uuid> rootflags=subvol=root-YYYYMMDD-HHMMSS rootfstype=btrfs rw
```

`/boot` lives **inside** each `root-*` subvolume, so every snapshot carries its own kernel and
initramfs. Because **systemd-boot can only read the FAT ESP**, each update copies the new
snapshot's kernel/initramfs out to `/efi/silverblue/<snap>/`. **GRUB can read Btrfs** so it
points directly at the subvolume's `/boot`; but GRUB cannot *write* Btrfs, so its writable
`grubenv` lives on the ESP at `/efi/grub/grubenv`.

## The eight-step update flow

```
                              silverblue-update
                                     │
  ┌──────────────────────────────────┼───────────────────────────────────────────────┐
  │                                   ▼                                                 │
  │  (1) SNAPSHOT            btrfs subvolume snapshot /  →  root-<TS>                    │
  │        running root ───────────────────────────────────► new writable subvolume    │
  │                                   │                                                 │
  │                                   ▼                                                 │
  │  (2) UPGRADE            arch-chroot root-<TS>  pacman -Syu                           │
  │        in the clone ───────────────────┐                                            │
  │                                   ┌─────┴─────┐                                      │
  │                              success         failure ──► discard snapshot, exit ≠0  │
  │                                   ▼               (no partial snapshot is left)      │
  │  (3) VALIDATE          ≥1 kernel + ≥1 initramfs under root-<TS>/boot                 │
  │        the new root    systemd-analyze verify <critical unit> ──► fail ► discard     │
  │                                   │                                                 │
  │                                   ▼                                                 │
  │  (4) REGISTER          systemd-boot: copy kernel→ESP, write root-<TS>+3.conf         │
  │        a boot entry    grub:        regenerate grub.cfg menuentry                    │
  │                                   │                                                 │
  │                                   ▼                                                 │
  │  (5) MANIFEST           sha256 every file under /usr + /boot (and the ESP kernel     │
  │        the new root     copies), HMAC-sign it, store it OUTSIDE the snapshot          │
  │                                   │                                                 │
  │                                   ▼                                                 │
  │  (6) SET NEXT BOOT      newest entry boots next; permanent default UNCHANGED         │
  │        (one boot only) systemd-boot: newest version sorts first                     │
  │                        grub:        next_entry one-shot in grubenv                   │
  │                                   │                                                 │
  │                                   ▼                                                 │
  │  (7) KEEP FALLBACK      previous root stays registered; prune to at most 3 snapshots │
  │        & prune                    │                                                 │
  └───────────────────────────────────┼─────────────────────────────────────────────────┘
                                      ▼
                                   reboot
                                      │
                                      ▼
  (8) POST-BOOT  ── silverblue-mark-good.service runs the health check ─────────────────┐
                                      │                                                  │
                              ┌───────┴────────┐                                         │
                          healthy            unhealthy / timeout / hang                  │
                              │                        │                                 │
                              ▼                        ▼                                 │
                  mark good (permanent       OnFailure → silverblue-rollback             │
                  default = new root):       → silverblue-update --rollback → reboot;    │
                  systemd-boot bless /        boot counting + watchdog also force a      │
                  grub saved_entry            fall back to the previous root  ───────────┘
```

### Step detail

1. **Snapshot.** `btrfs subvolume snapshot / <toplevel>/root-<TS>` clones the running root
   (copy-on-write, instant). The live system is never modified by the update.
2. **Upgrade.** `arch-chroot` into the clone and run `pacman -Syu`. Any download/package error
   trips the engine's `EXIT` trap, which deletes the half-built snapshot — no partial state is
   ever left behind.
3. **Validate.** Require at least one `vmlinuz-*` and one `initramfs-*.img` under the new
   `/boot`, and verify the critical service definitions inside the new root
   (`systemd-analyze verify` on systemd roots, `dinitcheck` on dinit roots). Failure discards
   the snapshot.
4. **Register.** Create a new bootloader entry with a human-readable label (e.g.
   `Arch Silverblue 2026-06-28 09:30`). systemd-boot entries carry a `+3` boot-counting suffix.
5. **Manifest.** Hash every file under the manifest paths (default `/usr` and `/boot` —
   `/etc` and `/var` are runtime-mutable and excluded by design) plus, on systemd-boot, the
   snapshot's kernel copies on the ESP. The manifest is authenticated with HMAC-SHA256 under
   a machine-local key; key and manifests live on the Btrfs toplevel, **outside every
   snapshot**. Verified before rollbacks and on demand (see *Integrity manifests* below).
6. **Set next boot.** The new entry becomes the *next* boot target without touching the
   permanent default — for systemd-boot the newest `version` sorts first; for GRUB the one-shot
   `next_entry` is set while `saved_entry` (the old default) is preserved.
7. **Keep fallback & prune.** The previous root remains a registered fallback entry. At most
   three snapshots are kept; the oldest are pruned (subvolume + ESP kernels + boot entry +
   integrity manifest, deleted in lockstep).
8. **Post-boot.** `silverblue-mark-good.service` health-checks the boot. On success it makes
   the new root the permanent default (`systemd-bless-boot good` / GRUB `saved_entry`) and
   prunes. On failure, timeout, or hang, the boot is never marked good and the system falls
   back to the previous root.

## Why auto-rollback actually triggers

Boot counting alone does **not** reboot a running-but-broken or hung system — it only abandons
a depleted entry on the *next* power cycle. Arch Silverblue closes that gap with three
complementary mechanisms:

| Failure mode                     | What recovers it                                            |
|----------------------------------|-------------------------------------------------------------|
| Health check fails cleanly       | `OnFailure=silverblue-rollback.target` → `--rollback` + reboot |
| Userspace hangs                  | `RuntimeWatchdogSec` (a hardware watchdog) resets the machine |
| New kernel won't load            | systemd-boot boot counting demotes the entry; previous boots |

After any of these reboots, the new entry's tries are exhausted / its one-shot consumed, so the
previous (good, counter-less) root is selected. On GRUB the one-shot boot arms the `recordfail`
tripwire (cleared by mark-good) and keeps a **finite** menu timeout, so an unattended machine
always keeps booting rather than holding the menu; the first two failure modes roll back
automatically on GRUB too. The third does not: a kernel that fails to *load* leaves stock GRUB
waiting at its menu with the previous root one keypress away — unattended recovery from an
unloadable kernel is a systemd-boot (boot counting) feature.

### Init systems

The health check and rollback dispatch are init-system independent (`init-backends.sh`):
systemd uses the unit pipeline above (`OnFailure=`, `TimeoutStartSec=`); OpenRC and dinit
derivatives run the same health check via `*-boot-check.sh`, which self-manages the settle
delay, the 120s timeout and the failure→rollback hand-off. One caveat: the watchdog row in
the table above is **systemd-only** — on OpenRC/dinit, hang protection comes from boot
counting / `recordfail` alone. See [DERIVING.md](../DERIVING.md) for the `INIT_SYSTEM` knob.

## Integrity manifests

Every update (and the initial install) records an HMAC-SHA256-authenticated manifest of the
new snapshot's OS payload — default `/usr` + `/boot`, plus the snapshot's kernel copies on
the ESP under systemd-boot. Key (`hmac.key`, root-only) and manifests live on the Btrfs
toplevel next to the snapshots, outside every snapshot, and a snapshot's manifest is deleted
with it when pruned.

Verification runs at two points — **never** at boot, and nothing is ever mounted read-only,
so the mutable model is untouched:

- **Before a rollback.** `SB_VERIFY_ON_ROLLBACK` controls the policy (bake the default via
  `VERIFY_ON_ROLLBACK` in `config/distro.conf`):
  - `warn` (default): a mismatch logs `SILVERBLUE-VERIFY-WARN` loudly and proceeds — on the
    unattended failure path, refusing to roll back would turn one bad update into a boot loop.
  - `strict`: candidates are tried newest-first and the first one that verifies wins; if none
    does, the rollback is refused *before* any boot state changes (a snapshot predating
    manifests is accepted with a note, so pre-feature systems stay recoverable).
  - `off`: no verification.
- **On demand**, via the CLI below.

A mismatch on the *running* root is advisory only: a live root is mutable by design, so e.g.
a manual `pacman -S` legitimately changes `/usr`. After such intentional changes, re-stamp
the snapshot with `--generate-manifest`.

What this defends against — and what it doesn't — is spelled out in
[SECURITY.md](../SECURITY.md).

## Manual control

```
silverblue-update                          # snapshot → upgrade → validate → register → manifest → next boot
silverblue-update --dry-run                # print the full plan, change nothing
silverblue-update --rollback               # boot the previous snapshot on next reboot (verified first)
silverblue-update --verify                 # verify every snapshot that is not the running root
silverblue-update --verify <snap>          # verify one snapshot
silverblue-update --generate-manifest <snap>   # re-stamp a snapshot after intentional changes
```

## ZFS (future work, not implemented)

The same flow maps onto ZFS boot environments: `zfs snapshot`/`zfs clone` for step 1, a clone
promoted per update, and `zfsbootmenu` or `org.zfsbootmenu:commandline` for entry selection.
This is documented as a stretch goal only; the implementation targets Btrfs.
