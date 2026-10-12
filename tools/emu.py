#!/usr/bin/env python3
"""emu.py — run ASH on a py65 6502 with CIO/SIO trapped (no OS ROM needed).

The PC-side regression rig: drives D1:-D4: from ATR files and H: from a
host folder, types a key script, captures the screen output, and stops when
a launched program reaches its run address (reporting whether every loaded
segment landed intact).

  emu.py [--d1 X.ATR] [--d4 Y.ATR] [--hdir DIR] [--boot] "ls" "run game" ...
"""
import argparse
import os
import sys

from py65.devices.mpu6502 import MPU

sys.path.insert(0, os.path.dirname(__file__))
import mkatr  # noqa: E402

CIOV, SIOV, COLDSV = 0xE456, 0xE459, 0xE477
EOL = 0x9B


class Stop(Exception):
    pass


class Machine:
    def __init__(self, drives, hdir=None, keys=b""):
        self.mpu = MPU()
        self.m = self.mpu.memory
        self.drives = {}                 # unit -> (ss, sec, raw-bytes)
        for unit, path in drives.items():
            ss, sec = mkatr.read_atr(path)
            self.drives[unit] = (ss, sec)
        self.hdir = hdir
        self.hfiles = {}                 # handle -> [bytes, pos]
        self.keys = list(keys)
        self.out = bytearray()
        self.watch = None                # (run address, segments) after launch
        for a in (CIOV, SIOV, COLDSV):
            self.m[a] = 0x60

    # -- memory helpers
    def w16(self, a):
        return self.m[a] | (self.m[a + 1] << 8)

    def load_xex(self, path):
        d = open(path, "rb").read()
        segs, i = [], 2
        while i < len(d):
            if d[i:i + 2] == b"\xff\xff":
                i += 2
            s = int.from_bytes(d[i:i + 2], "little")
            e = int.from_bytes(d[i + 2:i + 4], "little")
            segs.append((s, d[i + 4:i + 5 + e - s]))
            i += 5 + e - s
        return segs

    def rts(self, y=1, a=None):
        mpu = self.mpu
        if a is not None:
            mpu.a = a & 0xFF
        mpu.y = y
        mpu.p = (mpu.p & ~(mpu.NEGATIVE | mpu.ZERO)) | (mpu.NEGATIVE if y & 0x80 else 0)
        lo = self.m[0x100 + ((mpu.sp + 1) & 0xFF)]
        hi = self.m[0x100 + ((mpu.sp + 2) & 0xFF)]
        mpu.sp = (mpu.sp + 2) & 0xFF
        mpu.pc = ((hi << 8) | lo) + 1

    # -- CIO: E: output, K: input
    def cio(self):
        x = self.mpu.x
        cmd = self.m[0x342 + x]
        if cmd == 0x0B:
            self.out.append(self.mpu.a)
            self.rts()
        elif cmd == 0x07:
            if not self.keys:
                raise Stop("keys exhausted")
            self.rts(a=self.keys.pop(0))
        else:                            # open/close: fine
            self.rts()

    # -- SIO: disks and H:
    def sio(self):
        m = self.m
        dev = m[0x300] + m[0x301] - 1
        cmd, buf, n = m[0x302], self.w16(0x304), self.w16(0x308)
        aux1, aux2 = m[0x30A], m[0x30B]
        if 0x31 <= dev <= 0x34:
            unit = dev - 0x30
            if unit not in self.drives:
                return self.rts(138)
            ss, sec = self.drives[unit]
            if cmd == 0x53:
                m[buf:buf + 4] = bytes([0x10 | (0x20 if ss == 256 else 0), 0xFF, 0xE0, 0])
                return self.rts(1)
            if cmd == 0x52:
                s = aux1 | (aux2 << 8)
                data = sec(s)
                if len(data) != n:
                    return self.rts(143)     # wrong frame size = checksum error
                m[buf:buf + n] = data
                return self.rts(1)
            return self.rts(139)
        if dev == 0x72 and self.hdir:
            return self.hdev(cmd, aux1, aux2, buf, n)
        return self.rts(138)

    def hdev(self, cmd, aux1, aux2, buf, n):
        m, h = self.m, aux2 & 3
        if cmd == 0x4F:
            name = bytes(m[buf:buf + 64]).split(b"\0")[0].decode().upper()
            if aux1 == 6:
                lines = b""
                for f in sorted(os.listdir(self.hdir)):
                    p = os.path.join(self.hdir, f)
                    if os.path.isfile(p):
                        lines += f.upper().ljust(14).encode() + str(os.path.getsize(p)).encode() + b"\x9b"
                self.hfiles[h] = [lines + b"END OF DIRECTORY\x9b", 0]
                return self.rts(1)
            for f in os.listdir(self.hdir):
                if f.upper() == name:
                    self.hfiles[h] = [open(os.path.join(self.hdir, f), "rb").read(), 0]
                    return self.rts(1)
            return self.rts(144)
        if cmd == 0x53:
            d, p = self.hfiles.get(h, [b"", 0])
            av = min(len(d) - p, 65535)
            m[buf:buf + 4] = bytes([1, 1 | (2 if av == 0 else 0), av & 255, av >> 8])
            return self.rts(1)
        if cmd == 0x52:
            d, p = self.hfiles[h]
            if p + n > len(d):
                return self.rts(144)
            m[buf:buf + n] = d[p:p + n]
            self.hfiles[h][1] = p + n
            return self.rts(1)
        if cmd == 0x43:
            self.hfiles.pop(h, None)
            return self.rts(1)
        if cmd == 0x58:
            arg = bytes(m[buf:buf + 64]).split(b"\0")[0].decode().upper()
            p = lambda f: os.path.join(self.hdir, f)
            if aux1 == 33 and os.path.exists(p(arg)):
                os.remove(p(arg))
                return self.rts(1)
            if aux1 == 32 and "," in arg:
                old, new = arg.split(",", 1)
                if os.path.exists(p(old)):
                    os.rename(p(old), p(new))
                    return self.rts(1)
            return self.rts(144)
        return self.rts(139)

    def run(self, pc, steps=50_000_000):
        mpu = self.mpu
        mpu.pc = pc
        for _ in range(steps):
            p = mpu.pc
            if p == CIOV:
                self.cio()
            elif p == SIOV:
                self.sio()
            elif p == COLDSV:
                raise Stop("COLDSV (load error / reboot)")
            elif self.watch and p == self.watch[0]:
                raise Stop(f"reached run address ${p:04X}")
            else:
                mpu.step()
        raise Stop("step limit")

    def screen(self):
        s = []
        for c in self.out:
            if c == EOL:
                s.append("\n")
            elif c == 0x7E:
                s.append("\b")
            elif c == 0x7D:
                s.append("[CLR]\n")
            elif c == 0x9C:
                s.append("[DEL]")
            elif 0x20 <= c < 0x7B:
                s.append(chr(c))
            elif 0xA0 <= c < 0xFB:
                s.append(chr(c & 0x7F))
            else:
                s.append(f"[{c:02X}]")
        return "".join(s)


def main():
    ap = argparse.ArgumentParser()
    for u in range(1, 5):
        ap.add_argument(f"--d{u}")
    ap.add_argument("--hdir")
    ap.add_argument("--xex", default=os.path.join(os.path.dirname(__file__), "../build/ash.xex"))
    ap.add_argument("--boot", action="store_true", help="boot D1: through its boot sector")
    ap.add_argument("--expect", help="xex whose segments must be in RAM at the run address")
    ap.add_argument("cmds", nargs="*")
    a = ap.parse_args()
    drives = {u: getattr(a, f"d{u}") for u in range(1, 5) if getattr(a, f"d{u}")}
    keys = b"".join(c.encode("latin1").replace(b"\t", b"\x7f") + b"\x9b" for c in a.cmds)
    mc = Machine(drives, a.hdir, keys)
    m = mc.m
    m[0x0A:0x0C] = b"\x00\x00"
    if a.boot:
        ss, sec = mc.drives[1]
        boot = sec(1) + sec(2)
        m[0x0700:0x0800] = boot
        m[0x01FF], m[0x01FE] = 0x01, 0xFF    # return to $0200 = BRK if it RTSes
        mc.mpu.sp = 0xFD
        entry = 0x0706
    else:
        for s, d in mc.load_xex(a.xex):
            if s != 0x02E0:
                m[s:s + len(d)] = d
        entry = 0x2000
    if a.expect:
        segs = mc.load_xex(a.expect)
        run = next((int.from_bytes(d, "little") for s, d in segs if s == 0x2E0), segs[0][0])
        mc.watch = (run, segs)
    try:
        mc.run(entry)
    except Stop as e:
        why = str(e)
    print(mc.screen())
    print(f"--- stop: {why}")
    if a.expect and why.startswith("reached"):
        bad = [s for s, d in mc.watch[1] if s not in (0x2E0, 0x2E2) and bytes(m[s:s + len(d)]) != d]
        print("segments intact" if not bad else f"MISMATCH at {[hex(b) for b in bad]}")


if __name__ == "__main__":
    main()
