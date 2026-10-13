#!/usr/bin/env python3
"""test_fms.py — exercise ASH's D: file manager through CIO, like BASIC would.

Boots the shell in the emulator (which installs D:), then performs file
operations via CIO calls on scratch ATRs and checks results plus a full
fsck after every step. SD and DD.   python3 tools/test_fms.py
"""
import os
import random
import sys
import tempfile

sys.path.insert(0, os.path.dirname(__file__))
import mkatr  # noqa: E402
from emu import CIOV, Machine, Stop  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
XEX = os.path.join(HERE, "../build/ash.xex")
NAME, BUF = 0x0600, 0x6000
fails = 0


def blank_atr(path, dd=False, fmt=True):
    d = mkatr.Disk(dd)
    img, _ = d.finish()
    if not fmt:                       # raw zeros, as a new OSD blank disk
        img = img[:16] + bytes(len(img) - 16)
    open(path, "wb").write(img)


class Rig:
    def __init__(self, atr):
        self.atr = atr
        self.mc = Machine({1: atr}, None, b"")
        for s, d in Machine.load_xex(XEX):
            if s != 0x02E0:
                self.mc.m[s:s + len(d)] = d
        try:
            self.mc.run(0x2000)       # ASH starts, installs D:, waits for keys
        except Stop:
            pass

    def cio(self, x, cmd, name=None, aux1=0, data=b"", n=0, a=0):
        m = self.mc.m
        io = 0x340 + x
        m[io + 2] = cmd
        if name is not None:
            nb = name.encode() + b"\x9b"
            m[NAME:NAME + len(nb)] = nb
            m[io + 4:io + 6] = NAME.to_bytes(2, "little")
        if data or n:
            m[BUF:BUF + len(data)] = data
            m[io + 4:io + 6] = BUF.to_bytes(2, "little")
            m[io + 8:io + 10] = (len(data) or n).to_bytes(2, "little")
        m[io + 10] = aux1
        m[io + 11] = 0
        y, a = self.mc.call(CIOV, a=a, x=x)
        return y

    def write(self, name, data, mode=8):
        y = self.cio(0x10, 3, name, mode)
        if y >= 128:
            return y
        if data:
            y = self.cio(0x10, 0x0B, data=data)
            if y >= 128:
                self.cio(0x10, 12)
                return y
        return self.cio(0x10, 12)

    def read(self, name, n=65000):
        y = self.cio(0x10, 3, name, 4)
        if y >= 128:
            return y
        m = self.mc.m
        self.cio(0x10, 7, n=n)
        got = int.from_bytes(m[0x348:0x34A], "little") if False else int.from_bytes(m[0x358:0x35A], "little")
        self.cio(0x10, 12)
        return bytes(m[BUF:BUF + got])

    def listing(self, spec="D1:*.*"):
        y = self.cio(0x10, 3, spec, 6)
        if y >= 128:
            return y
        lines = []
        while True:
            y = self.cio(0x10, 5, n=40)
            if y >= 128:
                break
            got = int.from_bytes(self.mc.m[0x358:0x35A], "little")
            lines.append(bytes(self.mc.m[BUF:BUF + got - 1]).decode("latin1"))
        self.cio(0x10, 12)
        return lines

    def xio(self, cmd, name):
        return self.cio(0x20, cmd, name)

    def fsck(self, tag):
        path = self.atr + ".chk"
        self.mc.disks[1].save(path)
        p = mkatr.fsck(path)
        os.remove(path)
        check(not p, f"{tag}: fsck {p}")
        return path

    def free(self):
        d = self.mc.disks[1]
        v = d.read(360)
        return v[3] | (v[4] << 8)


def check(ok, what):
    global fails
    if not ok:
        fails += 1
        print("FAIL", what)


def suite(dd):
    tag = "DD" if dd else "SD"
    tmp = tempfile.mkdtemp()
    atr = os.path.join(tmp, "t.atr")
    blank_atr(atr, dd, fmt=False)
    r = Rig(atr)
    check(r.xio(254, "D1:") == 1, f"{tag} format blank")
    r.fsck(f"{tag} format")
    check(r.free() == 707, f"{tag} free after format {r.free()}")
    rnd = random.Random(7)
    files = {}
    for i, size in enumerate([0, 1, 124, 125, 126, 253, 254, 255, 1000, 5000, 20000]):
        data = bytes(rnd.randrange(256) for _ in range(size))
        nm = f"F{i}.DAT"
        y = r.write(f"D1:{nm}", data)
        check(y == 1, f"{tag} write {nm} -> {y}")
        files[nm] = data
    r.fsck(f"{tag} writes")
    for nm, data in files.items():
        got = r.read(f"D1:{nm}")
        check(got == data, f"{tag} readback {nm} ({len(data)} bytes): {got if isinstance(got, int) else len(got)}")
    # overwrite smaller, append
    check(r.write("D1:F10.DAT", b"short") == 1, f"{tag} overwrite")
    check(r.read("D1:F10.DAT") == b"short", f"{tag} overwrite readback")
    check(r.write("D1:F10.DAT", b"+more" * 60, mode=9) == 1, f"{tag} append")
    check(r.read("D1:F10.DAT") == b"short" + b"+more" * 60, f"{tag} append readback")
    check(r.write("D1:F0.DAT", b"x", mode=9) == 1, f"{tag} append to empty")
    check(r.read("D1:F0.DAT") == b"x", f"{tag} append-to-empty readback")
    r.fsck(f"{tag} overwrite/append")
    # listing
    ls = r.listing()
    check(isinstance(ls, list) and len(ls) == len(files) + 1 and ls[-1].endswith("FREE SECTORS"),
          f"{tag} listing {ls}")
    check(ls[0].startswith("  F0      DAT 001"), f"{tag} listing format {ls[0]!r}")
    # rename with wildcard, lock, delete
    check(r.xio(32, "D1:F1.DAT,G1.DAT") == 1, f"{tag} rename")
    check(r.read("D1:G1.DAT") == files["F1.DAT"], f"{tag} renamed readback")
    check(r.xio(32, "D1:F2.*,*.BIN") == 1, f"{tag} rename wildcard")
    check(r.read("D1:F2.BIN") == files["F2.DAT"], f"{tag} wildcard rename readback")
    check(r.xio(35, "D1:G1.DAT") == 1, f"{tag} lock")
    check(r.xio(33, "D1:G1.DAT") == 167, f"{tag} delete locked refused")
    check(r.write("D1:G1.DAT", b"no") == 167, f"{tag} overwrite locked refused")
    check(r.xio(36, "D1:G1.DAT") == 1, f"{tag} unlock")
    free0 = r.free()
    check(r.xio(33, "D1:F9.DAT") == 1, f"{tag} delete")
    want = -(-5000 // (253 if dd else 125))
    check(r.free() == free0 + want, f"{tag} delete frees {want} sectors ({free0} -> {r.free()})")
    check(r.read("D1:F9.DAT") == 170, f"{tag} deleted file gone")
    check(r.xio(33, "D1:F?.DAT") == 1, f"{tag} delete wildcard")
    r.fsck(f"{tag} rename/lock/delete")
    # directories
    check(r.xio(42, "D1:SUB") == 1, f"{tag} mkdir")
    check(r.write("D1:SUB>IN.TXT", b"inside") == 1, f"{tag} write in subdir")
    check(r.read("D1:SUB/IN.TXT") == b"inside", f"{tag} read in subdir")
    check(r.xio(42, "D1:SUB/DEEP") == 1, f"{tag} nested mkdir")
    check(r.write("D1:SUB/DEEP/X.Y", b"deep") == 1, f"{tag} write nested")
    check(r.read("D1:SUB/DEEP/X.Y") == b"deep", f"{tag} read nested")
    check(r.xio(33, "D1:SUB") == 167, f"{tag} rmdir non-empty refused")
    r.fsck(f"{tag} dirs")
    check(r.xio(33, "D1:SUB/DEEP/X.Y") == 1 and r.xio(33, "D1:SUB/DEEP") == 1, f"{tag} rmdir nested")
    check(r.xio(33, "D1:SUB/IN.TXT") == 1 and r.xio(33, "D1:SUB") == 1, f"{tag} rmdir")
    r.fsck(f"{tag} rmdir")
    # errors
    check(r.write("D1:BAD NAME!", b"") == 165 or r.write("D1:B!D", b"") == 165, f"{tag} bad name")
    check(r.read("D1:NOPE.XXX") == 170, f"{tag} not found")
    check(r.cio(0x10, 3, "D7:X", 4) == 160, f"{tag} bad drive")
    # fill the disk
    big = bytes(range(256)) * 200
    y, k = 1, 0
    while y == 1 and k < 20:
        y = r.write(f"D1:FILL{k}", big)
        k += 1
    check(y == 162, f"{tag} disk full -> {y}")
    r.cio(0x10, 12)
    p = r.fsck(f"{tag} full")
    # everything survives a reload through the plain reader
    return tmp


if __name__ == "__main__":
    for dd in (False, True):
        suite(dd)
    print("all FMS tests passed" if not fails else f"{fails} failure(s)")
    sys.exit(1 if fails else 0)
