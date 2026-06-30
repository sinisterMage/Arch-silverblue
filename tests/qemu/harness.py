#!/usr/bin/env python3
"""Serial-console driver for the Arch Silverblue QEMU integration test.

Invoked by run.sh (which exports the SB_* environment below). It runs three QEMU phases
against one persistent virtual disk:

  1. install  — boot the ISO; the fw_cfg-gated autoinstaller lays down Arch Silverblue and
                powers off. We wait for SILVERBLUE-INSTALL-OK.
  2. happy    — boot the disk; assert the first boot marked the root good; run one update
                cycle (hermetic by default); reboot; assert the new root booted and was
                marked good.
  3. rollback — boot the disk; run an update with a single boot-counting try, corrupt the
                new root's kernel (on the ESP for systemd-boot, inside the subvolume for GRUB),
                reboot; assert the system fell back to the previous (good) root.

Each scenario prints PASS/FAIL; the process exits 0 only if all pass (CI-friendly).
Only the Python standard library is used.
"""

import os
import re
import sys
import threading
import time

ISO = os.environ["SB_ISO"]
DISK = os.environ["SB_DISK"]
FW_CODE = os.environ["SB_FW_CODE"]
FW_VARS = os.environ["SB_FW_VARS"]
ACCEL = os.environ.get("SB_ACCEL", "tcg")
CPU = os.environ.get("SB_CPU", "qemu64")
NET = os.environ.get("SB_NET", "0")
BOOTLOADER = os.environ.get("SB_BOOTLOADER", "systemd-boot")
WORK = os.environ.get("SB_WORK", ".")

# TCG is much slower than KVM, so scale timeouts accordingly.
SLOW = ACCEL != "kvm"
T_INSTALL = 3600 if SLOW else 1200
T_BOOT = 600 if SLOW else 300
T_CMD = 600 if SLOW else 180
T_UPDATE = 1200 if SLOW else 300


class ConsoleError(Exception):
    pass


class Console:
    """Drives one QEMU instance over its serial stdio with an expect()/send() API."""

    def __init__(self, name, extra_args):
        import subprocess

        self.name = name
        self.buf = ""
        self.pos = 0
        self.lock = threading.Lock()
        self.logpath = os.path.join(WORK, "serial-%s.log" % name)
        self.logf = open(self.logpath, "w", encoding="utf-8", errors="replace")
        args = self._base_args() + extra_args
        self.logf.write("# qemu: %s\n" % " ".join(args))
        self.logf.flush()
        self.proc = subprocess.Popen(
            args, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT, bufsize=0,
        )
        self.reader = threading.Thread(target=self._read_loop, daemon=True)
        self.reader.start()

    def _base_args(self):
        return [
            "qemu-system-x86_64",
            "-machine", "q35,accel=%s" % ACCEL,
            "-cpu", CPU,
            "-m", "2048", "-smp", "2",
            "-drive", "if=pflash,format=raw,readonly=on,file=%s" % FW_CODE,
            "-drive", "if=pflash,format=raw,file=%s" % FW_VARS,
            "-drive", "file=%s,if=virtio,format=qcow2" % DISK,
            "-netdev", "user,id=net0",
            "-device", "virtio-net-pci,netdev=net0",
            # NOTE: no i6300esb watchdog. systemd cannot stop the emulated i6300esb on a clean
            # reboot ("watchdog did not stop!"), so it stays armed and resets the VM during the
            # next boot menu, causing a reboot loop. The target still ships RuntimeWatchdogSec
            # (inert here without a watchdog device); the happy/rollback scenarios rely on
            # boot-counting, not the watchdog, so dropping it does not reduce their coverage.
            "-rtc", "base=utc",
            "-display", "none", "-serial", "stdio", "-monitor", "none",
        ]

    def _read_loop(self):
        while True:
            chunk = self.proc.stdout.read(1)
            if not chunk:
                break
            text = chunk.decode("utf-8", errors="replace")
            with self.lock:
                self.buf += text
            self.logf.write(text)
            self.logf.flush()
            sys.stdout.write(text)
            sys.stdout.flush()

    def expect(self, patterns, timeout):
        """Wait until one of the regex patterns appears in newly-read output.

        Returns (index, before_text). Raises ConsoleError on timeout or QEMU exit.
        """
        if isinstance(patterns, str):
            patterns = [patterns]
        compiled = [re.compile(p) for p in patterns]
        deadline = time.time() + timeout
        while True:
            with self.lock:
                window = self.buf[self.pos:]
            best = None
            for i, rx in enumerate(compiled):
                m = rx.search(window)
                if m and (best is None or m.start() < best[1]):
                    best = (i, m.start(), m.end())
            if best is not None:
                idx, start, end = best
                before = window[:start]
                with self.lock:
                    self.pos += end
                return idx, before
            if self.proc.poll() is not None and not self._has_more():
                raise ConsoleError(
                    "%s: qemu exited (rc=%s) waiting for %r"
                    % (self.name, self.proc.returncode, patterns)
                )
            if time.time() > deadline:
                raise ConsoleError(
                    "%s: timeout after %ss waiting for %r" % (self.name, timeout, patterns)
                )
            time.sleep(0.2)

    def _has_more(self):
        with self.lock:
            return self.pos < len(self.buf)

    def send(self, line):
        self.proc.stdin.write((line + "\n").encode())
        self.proc.stdin.flush()

    def wait_exit(self, timeout):
        try:
            self.proc.wait(timeout=timeout)
            return True
        except Exception:
            return False

    def close(self):
        try:
            if self.proc.poll() is None:
                self.proc.terminate()
                self.proc.wait(timeout=15)
        except Exception:
            try:
                self.proc.kill()
            except Exception:
                pass
        try:
            self.logf.close()
        except Exception:
            pass


# --- High-level guest interactions --------------------------------------------------------

_MARK = [0]


def _next_marker():
    _MARK[0] += 1
    return "SBM%d" % _MARK[0]


def _emit(marker):
    # Print `marker` so the typed command's echo does NOT contain it literally (the embedded
    # quotes split the token), but the command's OUTPUT line does. This sidesteps prompt
    # theming/escape codes entirely: command output is plain text, prompts are not matched.
    return 'echo "SB""%s"' % marker[2:]


def wait_login(con, timeout=T_BOOT):
    """Wait until an autologin root shell is accepting commands.

    Works regardless of prompt theming/escape codes (grml-zsh on the live ISO, bash on the
    target) because it matches a sentinel we print, not the prompt. The repeated Enter also
    advances a systemd-boot menu left up by a failed (corrupt-kernel) boot.
    """
    deadline = time.time() + timeout
    while True:
        marker = _next_marker()
        con.send(_emit(marker))
        try:
            con.expect([marker], timeout=8)
            return
        except ConsoleError:
            if con.proc.poll() is not None:
                raise
            if time.time() > deadline:
                raise ConsoleError("%s: timed out waiting for login shell" % con.name)


def sh(con, command, timeout=T_CMD):
    """Run a shell command; return the text printed before its end sentinel."""
    marker = _next_marker()
    con.send("%s; %s" % (command, _emit(marker)))
    _, before = con.expect([marker], timeout)
    return before


def get_subvol(con):
    out = sh(con, "cat /proc/cmdline")
    m = re.search(r"rootflags=subvol=(root-\S+)", out)
    if not m:
        raise ConsoleError("could not find rootflags=subvol in /proc/cmdline:\n%s" % out)
    return m.group(1).split(",")[0]


def run_update(con, tries=None):
    prefix = ("SB_TRIES=%d " % tries) if tries else ""
    out = sh(con, prefix + "silverblue-update", timeout=T_UPDATE)
    if "==> Done." not in out:
        raise ConsoleError("silverblue-update did not complete cleanly:\n%s" % out)
    m = re.search(r"new root\s*:\s*(root-\S+)", out)
    if not m:
        raise ConsoleError("could not parse new snapshot name from update output:\n%s" % out)
    return m.group(1)


def assert_markgood(con):
    # Wait for the unit to settle, then confirm it marked the boot good.
    sh(con,
       "for i in $(seq 1 90); do "
       "systemctl is-active --quiet silverblue-mark-good.service && break; "
       "systemctl is-failed --quiet silverblue-mark-good.service && break; "
       "sleep 1; done",
       timeout=180)
    out = sh(con, "journalctl -u silverblue-mark-good.service -b --no-pager")
    if "SILVERBLUE-MARKGOOD-OK" not in out or "SILVERBLUE-MARKGOOD-FAIL" in out:
        raise ConsoleError("mark-good did not report OK:\n%s" % out)


# --- Scenarios ----------------------------------------------------------------------------

def phase_install():
    con = Console("install", ["-cdrom", ISO])
    try:
        # The live ISO autologins root on the serial console (grml zsh). Wait for the shell to
        # accept commands, then drive the installer directly.
        wait_login(con, timeout=T_BOOT)
        con.send(
            "SB_SCENARIO=install SB_NET=%s SB_BOOTLOADER=%s bash /usr/local/bin/silverblue-autoinstall.sh"
            % (NET, BOOTLOADER)
        )
        idx, _ = con.expect(
            [r"SILVERBLUE-INSTALL-OK snap=(root-\S+)",
             r"SILVERBLUE-INSTALL-FAIL",
             r"SILVERBLUE-INSTALL-SKIP"],
            timeout=T_INSTALL,
        )
        if idx != 0:
            raise ConsoleError("install did not succeed")
        with con.lock:
            text = con.buf
        snap = re.search(r"SILVERBLUE-INSTALL-OK snap=(root-\S+)", text).group(1)
        con.wait_exit(timeout=120)
        return snap
    finally:
        con.close()


def phase_happy(initial_snap):
    con = Console("happy", [])
    try:
        wait_login(con)
        assert_markgood(con)
        print("\n[happy] initial root %s marked good" % initial_snap)

        new_snap = run_update(con)
        print("[happy] update produced new root %s; rebooting" % new_snap)
        con.send("sync; systemctl reboot")

        wait_login(con)
        booted = get_subvol(con)
        if booted != new_snap:
            raise ConsoleError("expected to boot %s after update, booted %s" % (new_snap, booted))
        assert_markgood(con)
        print("[happy] booted updated root %s and marked it good" % booted)

        con.send("poweroff")
        con.wait_exit(timeout=120)
        return True
    finally:
        con.close()


def phase_rollback():
    con = Console("rollback", [])
    try:
        wait_login(con)
        good = get_subvol(con)
        print("\n[rollback] current good root: %s" % good)

        bad_snap = run_update(con, tries=1)
        if bad_snap == good:
            raise ConsoleError("update did not create a distinct snapshot")
        print("[rollback] bad update staged as %s; corrupting its kernel" % bad_snap)
        if BOOTLOADER == "grub":
            # GRUB loads the kernel from inside the snapshot's Btrfs subvolume (it reads Btrfs
            # natively), not from a per-snapshot copy on the ESP. Reach it via the Btrfs
            # top-level (subvolid=5) and zero it there.
            sh(con,
               "d=$(findmnt -no SOURCE / | sed 's/\\[.*//'); "
               "mkdir -p /mnt/sbtop && mount -o subvolid=5 \"$d\" /mnt/sbtop && "
               "truncate -s 0 /mnt/sbtop/%s/boot/vmlinuz-linux && sync && umount /mnt/sbtop"
               % bad_snap)
        else:
            # systemd-boot only reads FAT, so each snapshot's kernel is copied onto the ESP.
            sh(con, "truncate -s 0 /efi/silverblue/%s/vmlinuz-linux; sync" % bad_snap)

        con.send("systemctl reboot")
        # systemd-boot tries the corrupt entry (tries=1 -> 0), fails, and falls back. wait_login
        # sends Enter each iteration, advancing any paused boot menu to the fallback entry.
        wait_login(con, timeout=T_BOOT * 2)
        landed = get_subvol(con)
        if landed == bad_snap:
            raise ConsoleError("system booted the corrupt root %s instead of rolling back" % bad_snap)
        if landed != good:
            raise ConsoleError("rolled back to %s, expected the previous good root %s" % (landed, good))
        print("[rollback] fell back to previous good root %s" % landed)

        con.send("poweroff")
        con.wait_exit(timeout=120)
        return True
    finally:
        con.close()


def main():
    results = []
    try:
        snap = phase_install()
        results.append(("install", True, "installed %s" % snap))
    except ConsoleError as e:
        results.append(("install", False, str(e)))
        return report(results)

    for name, fn, arg in (("happy", phase_happy, snap), ("rollback", phase_rollback, None)):
        try:
            fn(arg) if arg is not None else fn()
            results.append((name, True, "ok"))
        except ConsoleError as e:
            results.append((name, False, str(e)))

    return report(results)


def report(results):
    print("\n================ QEMU TEST SUMMARY ================")
    ok = True
    for name, passed, detail in results:
        print("  %-9s %s  %s" % (name, "PASS" if passed else "FAIL", detail))
        ok = ok and passed
    print("===================================================")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
