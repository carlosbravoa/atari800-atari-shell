#!/usr/bin/env python3
"""mkatr.py — build DOS 2-format ATR disks for ASH (and list any DOS 2/MyDOS ATR).

  mkatr.py -o ASH.ATR [--dd] [--shell build/ash.xex --boot build/boot.bin] FILE[=NAME.EXT] ...
  mkatr.py --list DISK.ATR

With --shell/--boot the disk boots straight into ASH: the boot sector loads
the raw shell image from sectors 4.. (marked used in the VTOC, outside any
file, the way DOS.SYS boots). Files are written as standard DOS 2.0 files
(file-numbered sector links), so DOS 2.x / MyDOS read the disk as well.
720 sectors, SD (128-byte, 90K) or DD (256-byte, 180K).
"""
import argparse
import os
import re
import sys

NSEC = 720
VTOC = 360
DIR0 = 361


def dos_name(path, override=None):
    if override:
        base, _, ext = override.upper().partition(".")
    else:
        base, ext = os.path.splitext(os.path.basename(path))
        ext = ext[1:]
    clean = lambda s, n: re.sub(r"[^A-Z0-9]", "", s.upper())[:n]
    base, ext = clean(base, 8), clean(ext, 3)
    if not base or base[0].isdigit():
        base = ("F" + base)[:8]
    return base, ext


def xex_main_image(path):
    """The shell's single MAIN segment (load address must be $2000)."""
    d = open(path, "rb").read()
    assert d[:2] == b"\xff\xff", f"{path}: not a .xex"
    s = int.from_bytes(d[2:4], "little")
    e = int.from_bytes(d[4:6], "little")
    assert s == 0x2000, f"{path}: first segment at ${s:04X}, expected $2000"
    return d[6:6 + e - s + 1]


class Disk:
    def __init__(self, dd=False):
        self.ss = 256 if dd else 128
        self.sec = {n: bytearray(128 if n <= 3 else self.ss)
                    for n in range(1, NSEC + 1)}
        self.used = set(range(0, 4)) | set(range(VTOC, DIR0 + 8))
        self.dirn = 0

    def alloc(self):
        for n in range(4, NSEC):            # DOS 2 uses 1-719
            if n not in self.used:
                self.used.add(n)
                return n
        sys.exit("disk full")

    def put_boot(self, boot, image):
        b = bytearray(boot[:256])
        nimg = -(-len(image) // self.ss)
        assert 4 + nimg <= VTOC, "shell image too big for the boot area"
        b[9] = nimg
        b[10] = 0x00 if self.ss == 256 else 0x80
        self.sec[1][:] = b[:128]
        self.sec[2][:] = b[128:256]
        for i in range(nimg):
            n = 4 + i
            chunk = image[i * self.ss:(i + 1) * self.ss]
            self.sec[n][:len(chunk)] = chunk
            self.used.add(n)
        return nimg

    def add_file(self, data, name, ext):
        if self.dirn >= 64:
            sys.exit("directory full (64 files)")
        fno = self.dirn
        per = self.ss - 3
        chunks = [data[i:i + per] for i in range(0, len(data), per)] or [b""]
        secs = [self.alloc() for _ in chunks]
        for i, (n, c) in enumerate(zip(secs, chunks)):
            nxt = secs[i + 1] if i + 1 < len(secs) else 0
            s = self.sec[n]
            s[:len(c)] = c
            s[self.ss - 3] = (fno << 2) | (nxt >> 8)
            s[self.ss - 2] = nxt & 0xFF
            s[self.ss - 1] = len(c)
        d = self.sec[DIR0 + fno // 8]
        o = (fno % 8) * 16
        d[o] = 0x42
        d[o + 1:o + 3] = len(secs).to_bytes(2, "little")
        d[o + 3:o + 5] = secs[0].to_bytes(2, "little")
        d[o + 5:o + 13] = name.ljust(8).encode()
        d[o + 13:o + 16] = ext.ljust(3).encode()
        self.dirn += 1
        return len(secs)

    def finish(self):
        v = self.sec[VTOC]
        v[0] = 2
        v[1:3] = (707).to_bytes(2, "little")
        free = 0
        for n in range(NSEC):
            if n not in self.used:
                v[10 + n // 8] |= 0x80 >> (n % 8)
                free += 1
        v[3:5] = free.to_bytes(2, "little")
        body = b"".join(bytes(self.sec[n]) for n in range(1, NSEC + 1))
        paras = len(body) // 16
        hdr = bytearray(16)
        hdr[0:2] = (0x0296).to_bytes(2, "little")
        hdr[2:4] = (paras & 0xFFFF).to_bytes(2, "little")
        hdr[4:6] = self.ss.to_bytes(2, "little")
        hdr[6] = paras >> 16
        return bytes(hdr) + body, free


# ---- reading (for --list and tests) -------------------------------------------
def read_atr(path):
    d = open(path, "rb").read()
    assert d[:2] == b"\x96\x02", f"{path}: not an ATR"
    ss = int.from_bytes(d[4:6], "little")
    body = d[16:]
    full = ss == 256 and len(body) % 256 == 0     # boot sectors padded to 256

    def sec(n):
        if ss == 128 or n <= 3:
            o = (n - 1) * (256 if full else 128)
            return body[o:o + 128]
        o = (n - 1) * 256 if full else 384 + (n - 4) * 256
        return body[o:o + 256]
    return ss, sec


def list_dir(sec, start=DIR0, indent=""):
    for s in range(start, start + 8):
        b = sec(s)
        for i in range(8):
            e = b[i * 16:i * 16 + 16]
            if e[0] == 0:
                return
            if e[0] & 0x80 or not e[0] & 0x40:
                continue
            nm = e[5:13].decode("latin1").rstrip()
            ex = e[13:16].decode("latin1").rstrip()
            cnt = int.from_bytes(e[1:3], "little")
            st = int.from_bytes(e[3:5], "little")
            kind = "dir" if e[0] & 0x10 else "   "
            print(f"{indent}{e[0]:02x} {kind} {cnt:5d} @{st:<5d} {nm}{'.' + ex if ex else ''}")
            if e[0] & 0x10:
                list_dir(sec, st, indent + "    ")


def read_file(sec, ss, start, link16=False):
    out, n = bytearray(), start
    while n:
        b = sec(n)
        cnt = b[ss - 1]
        out += b[:cnt]
        hi = b[ss - 3] if link16 else b[ss - 3] & 3
        n = (hi << 8) | b[ss - 2]
    return bytes(out)


def fsck(path):
    """Check a DOS 2 / MyDOS-small disk: chains, file numbers, counts, VTOC.
    Returns a list of problems (empty = clean). Sectors marked used that no
    file owns are allowed only as one run starting at 4 (a boot image)."""
    ss, sec = read_atr(path)
    probs, owner = [], {}
    v = sec(VTOC)
    if v[0] != 2:
        return [f"VTOC dos byte {v[0]} (not DOS 2)"]

    def own(n, who):
        if not 1 <= n <= 720:
            probs.append(f"{who}: sector {n} out of range")
        elif n in owner:
            probs.append(f"{who}: sector {n} also used by {owner[n]}")
        else:
            owner[n] = who

    def walk(start, path):
        for i in range(64):
            b = sec(start + i // 8)
            e = b[(i % 8) * 16:(i % 8) * 16 + 16]
            if e[0] == 0:
                return
            if e[0] & 0x80:
                continue
            nm = (e[5:13].decode("latin1").rstrip() + "." + e[13:16].decode("latin1").rstrip()).rstrip(".")
            who = path + nm
            cnt = int.from_bytes(e[1:3], "little")
            st = int.from_bytes(e[3:5], "little")
            if e[0] & 0x10:
                for k in range(8):
                    own(st + k, who + "/")
                walk(st, who + "/")
                continue
            if not e[0] & 0x40:
                continue
            if e[0] & 0x01:
                probs.append(f"{who}: still open for write")
            n, k, seen = st, 0, set()
            while n:
                if n in seen or k > 2000:
                    probs.append(f"{who}: chain loops")
                    break
                seen.add(n)
                own(n, who)
                d = sec(n)
                if (d[ss - 3] >> 2) != i and not e[0] & 0x04:
                    probs.append(f"{who}: sector {n} file number {d[ss - 3] >> 2} != {i}")
                if d[ss - 1] > ss - 3:
                    probs.append(f"{who}: sector {n} count {d[ss - 1]}")
                hi = d[ss - 3] if e[0] & 0x04 else d[ss - 3] & 3
                n = (hi << 8) | d[ss - 2]
                k += 1
            if k != cnt:
                probs.append(f"{who}: {k} sectors in chain, entry says {cnt}")
    walk(DIR0, "")
    nbits = 721 if int.from_bytes(v[1:3], "little") > 707 else 720   # MyDOS uses 720 too
    used = {n for n in range(nbits) if not v[10 + n // 8] & (0x80 >> (n % 8))}
    reserved = set(range(0, 4)) | set(range(VTOC, DIR0 + 8))
    for n in sorted(set(owner) - used):
        probs.append(f"sector {n} ({owner[n]}) is free in the VTOC")
    orphan = sorted(used - set(owner) - reserved)
    run = list(range(4, 4 + len(orphan)))
    if orphan and orphan != run:
        probs.append(f"{len(orphan)} used sectors no file owns: {orphan[:12]}")
    free = int.from_bytes(v[3:5], "little")
    if free != nbits - len(used):
        probs.append(f"VTOC free count {free} != bitmap {nbits - len(used)}")
    return probs


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("files", nargs="*")
    ap.add_argument("-o", "--out")
    ap.add_argument("--dd", action="store_true", help="256-byte sectors (180K)")
    ap.add_argument("--shell", help="ash.xex: make the disk boot into ASH")
    ap.add_argument("--boot", help="boot.bin (with --shell)")
    ap.add_argument("--list", metavar="ATR")
    ap.add_argument("--fsck", metavar="ATR")
    a = ap.parse_args()

    if a.fsck:
        p = fsck(a.fsck)
        print("\n".join(p) if p else f"{a.fsck}: clean")
        sys.exit(1 if p else 0)

    if a.list:
        ss, sec = read_atr(a.list)
        v = sec(VTOC)
        print(f"{a.list}: {ss}-byte sectors, VTOC dos={v[0]} "
              f"total={int.from_bytes(v[1:3], 'little')} free={int.from_bytes(v[3:5], 'little')}")
        list_dir(sec)
        return
    if not a.out:
        ap.error("-o is required (or --list)")

    disk = Disk(a.dd)
    if a.shell:
        assert a.boot, "--shell needs --boot"
        n = disk.put_boot(open(a.boot, "rb").read(), xex_main_image(a.shell))
        print(f"boot: ASH image in sectors 4-{3 + n}")
    seen = set()
    for spec in a.files:
        path, _, override = spec.partition("=")
        name, ext = dos_name(path, override or None)
        if (name, ext) in seen:
            sys.exit(f"duplicate name {name}.{ext} (use FILE=NAME.EXT)")
        seen.add((name, ext))
        cnt = disk.add_file(open(path, "rb").read(), name, ext)
        print(f"  {name}.{ext:3s} {cnt:4d} sectors  <- {path}")
    img, free = disk.finish()
    open(a.out, "wb").write(img)
    print(f"{a.out}: {len(img)} bytes, {free} free sectors")


if __name__ == "__main__":
    main()
