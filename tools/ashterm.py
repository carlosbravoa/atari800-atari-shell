#!/usr/bin/env python3
"""ashterm — drive ASH-TN on the Tang Nano Atari over the PC link, no keystrokes.

ASH-TN keeps a mailbox in page 6 (see tn.s): we poke a command line, the
shell runs it as if typed and mirrors its output into RAM, which we peek.
Exact output, no typing cadence, and the shell can ping us (`pc`).

  ashterm                      interactive: a prompt that shows ASH's own path
  ashterm -c "ls -l" [-c ...]  run commands, print their output, exit
  ashterm get SRC [DST]        copy a file from the Atari (any disk, h:, MyDOS
                               subdir) to the PC through the RAM window
  ashterm put FILE [DST]       send a file to h: (the SD /HDD folder), then
                               `cp` it to DST on the Atari (default: stays on h:)

Exit status 1 on a failed command. Errors say what to check: the board on
USB, ASH-TN running, or the shell being busy (pager / editor / a program).
"""
import argparse
import os
import sys
import time

ATARI = "/home/carlos/devel/fpga/atari800_tang_nano20k_parallel"
sys.path.insert(0, f"{ATARI}/tools")
from atari_link import AtariLink, LinkError  # noqa: E402

MB = 0x0640
MB_CMDREQ, MB_STATUS, MB_ERR, MB_CIOERR = 0x643, 0x644, 0x645, 0x646
MB_OUT, MB_CAP, MB_LEN, MB_SEQ = 0x647, 0x649, 0x64B, 0x64D
MB_PING, MB_PONG, MB_ABORT, MB_RAM, MB_MORE = 0x64E, 0x64F, 0x650, 0x651, 0x653
MB_CMD, MB_PROMPT = 0x660, 0x6B0
RAMWIN = 0x8000
EOL = 0x9B

NO_BOARD = ("no Atari on the USB link: make sure the board is powered via USB-C "
            "(Linux: `sudo modprobe ftdi_sio` if /dev/ttyUSB* is missing)")
NO_ASH = ("the board answers but ASH-TN is not running on it: deploy "
          "build/ash-tn.xex or boot ASH-TN.ATR, then retry")
BUSY = ("ASH is not at its prompt (a pager, the editor, or a running program "
        "on the Atari): finish that on the Atari and retry")


class AshError(Exception):
    pass


def atascii(b):
    out = []
    for c in b:
        if c == EOL:
            out.append("\n")
        elif 0x20 <= c < 0x7D:
            out.append(chr(c))
        elif 0xA0 <= c < 0xFD:
            out.append(chr(c & 0x7F))
        elif c in (0x7E, 0x7F, 0x1B):
            pass
        else:
            out.append(".")
    return "".join(out)


class Ash:
    def __init__(self):
        try:
            self.l = AtariLink()
        except LinkError as e:
            raise AshError(NO_BOARD + f"\n({e})")
        self.hdr = None
        if not self.alive():
            raise AshError(NO_ASH)

    def close(self):
        self.l.close()

    def _io(self, fn, *args, tries=40):
        """Link calls time out while the firmware is inside an SIO transaction
        (ASH reading a disk); wait it out and retry."""
        for i in range(tries):
            try:
                return fn(*args)
            except LinkError:
                if i == tries - 1:
                    raise AshError("the link stopped answering (" + BUSY + ")")
                time.sleep(0.15)

    def rpeek(self, a, n):
        return self._io(self.l.peek, a, n)

    def poke(self, a, data):
        return self._io(self.l.poke, a, data)

    def peek(self, a, n):
        """A stable read: the link can serve stale bytes, so read until two agree."""
        last = None
        for _ in range(6):
            cur = self.rpeek(a, n)
            if cur == last:
                return cur
            last = cur
        return last

    def alive(self):
        try:
            self.hdr = self.l.peek(MB, 0x20)
        except LinkError:
            try:                                   # the first call after idle often misses
                self.hdr = self.l.peek(MB, 0x20)
            except LinkError:
                return False
        return self.hdr[:2] == b"AS"

    def prompt(self):
        p = self.peek(MB_PROMPT, 32)
        return atascii(p.split(b"\0")[0])

    def pong(self, hdr):
        if hdr[MB_PING - MB] != hdr[MB_PONG - MB]:
            self.poke(MB_PONG, bytes([hdr[MB_PING - MB]]))

    def run(self, line, sink=None, timeout=120):
        """Run one command; stream its output to sink(text). Returns (status, err, cioerr)."""
        hdr = self.peek(MB, 0x20)
        if hdr[:2] != b"AS":
            raise AshError(NO_ASH)
        if hdr[MB_STATUS - MB] == 0 or hdr[MB_CMDREQ - MB]:
            raise AshError(BUSY)
        data = line.encode("latin1")[:79] + b"\0"
        self.poke(MB_CMD, data)
        seq = hdr[MB_SEQ - MB]
        self.poke(MB_CMDREQ, b"\x01")
        out = self.rpeek(MB_OUT, 2)
        base = int.from_bytes(out, "little")
        got, t0, started = 0, time.time(), False
        while True:
            hdr = self.peek(MB, 0x20)
            self.pong(hdr)
            n = int.from_bytes(hdr[MB_LEN - MB:MB_LEN - MB + 2], "little")
            st = hdr[MB_STATUS - MB]
            if st == 0 or hdr[MB_SEQ - MB] != seq:
                started = True
            if n > got:
                chunk = self.rpeek(base + got, min(n - got, 1024))
                if sink:
                    sink(atascii(chunk))
                got += len(chunk)
                continue
            if started and st != 0 and hdr[MB_SEQ - MB] != seq:
                return st, hdr[MB_ERR - MB], hdr[MB_CIOERR - MB]
            if st == 3:
                return 3, 0, 0
            if time.time() - t0 > timeout:
                raise AshError("timed out waiting for ASH (" + BUSY + ")")
            if not started and time.time() - t0 > 5:
                raise AshError(BUSY)
            time.sleep(0.05)

    def get(self, src, dst, progress=None):
        data = bytearray()
        cmd = f"getw {src}"
        while True:
            msgs = []
            st, err, cio = self.run(cmd, sink=msgs.append)
            if st != 1:
                raise AshError("".join(msgs).strip() or f"getw failed ({err}/{cio})")
            hdr = self.peek(MB, 0x20)
            n = int.from_bytes(hdr[MB_RAM - MB:MB_RAM - MB + 2], "little")
            for off in range(0, n, 1024):
                data += self.rpeek(RAMWIN + off, min(1024, n - off))
            if progress:
                progress(len(data))
            if not hdr[MB_MORE - MB]:
                break
            cmd = "getw"
        open(dst, "wb").write(data)
        return len(data)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("-c", action="append", default=[], metavar="CMD", help="run this command and exit")
    ap.add_argument("op", nargs="?", choices=["get", "put"])
    ap.add_argument("args", nargs="*")
    a = ap.parse_args()
    try:
        ash = Ash()
    except AshError as e:
        sys.exit(f"ashterm: {e}")
    rc = 0
    try:
        if a.op == "get":
            if not a.args:
                sys.exit("usage: ashterm get SRC [DST]")
            src = a.args[0]
            dst = a.args[1] if len(a.args) > 1 else os.path.basename(src.split(":")[-1].split("/")[-1])
            n = ash.get(src, dst, progress=lambda k: print(f"\r{k} bytes", end="", flush=True))
            print(f"\r{dst}: {n} bytes        ")
        elif a.op == "put":
            if not a.args:
                sys.exit("usage: ashterm put FILE [DST]")
            path = a.args[0]
            name = os.path.basename(path).upper()
            ash.l.send(open(path, "rb").read(), f"HDD/{name}")
            print(f"h:{name.lower()} <- {path}")
            if len(a.args) > 1:
                st, *_ = ash.run(f"cp h:{name.lower()} {a.args[1]}", sink=lambda t: print(t, end=""))
                rc = 0 if st == 1 else 1
        elif a.c:
            for cmd in a.c:
                st, err, cio = ash.run(cmd, sink=lambda t: print(t, end="", flush=True))
                if st == 3:
                    print("(program launched; ASH is no longer running)")
                    break
                if st != 1:
                    rc = 1
        else:
            print("ASH-TN terminal — Ctrl-D or 'exit' to leave; the Atari keeps running")
            while True:
                try:
                    line = input(f"{ash.prompt()}$ ")
                except (EOFError, KeyboardInterrupt):
                    print()
                    break
                if line.strip() in ("exit", "quit"):
                    break
                if not line.strip():
                    continue
                try:
                    st, err, cio = ash.run(line, sink=lambda t: print(t, end="", flush=True))
                except KeyboardInterrupt:
                    ash.l.poke(MB_ABORT, b"\x01")
                    print("\n(abort sent)")
                    continue
                if st == 3:
                    print("(program launched; ASH is no longer running)")
                    break
    except AshError as e:
        sys.exit(f"ashterm: {e}")
    finally:
        ash.close()
    sys.exit(rc)


if __name__ == "__main__":
    main()
