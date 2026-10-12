#!/usr/bin/env python3
"""Deploy ASH into the Atari's RAM over the PC link and start it.

No typing, no USR(): poke the image to $2000, point DOSVEC at it, mark the
machine "booted from disk" with BASIC off, then warm-reset. The OS warm
start runs JSR (DOSINI) -> an RTS we plant in page 6, finds no cartridge,
and jumps through DOSVEC into ASH's cold entry. Works from BASIC READY and
over a running ASH alike (ASH idles inside the OS keyboard handler, so
rewriting it is safe).

Usage: python3 deploy.py [--xex build/ash.xex]
"""
import argparse
import sys
import time

ATARI = "/home/carlos/devel/fpga/atari800_tang_nano20k_parallel"
sys.path.insert(0, f"{ATARI}/tools")
from atari_link import AtariLink  # noqa: E402

BOOTQ, DOSVEC, DOSINI, COLDST, BASICF = 0x09, 0x0A, 0x0C, 0x0244, 0x03F8
RTS_STUB = 0x06FF


def parse_xex(path):
    d = open(path, "rb").read()
    assert d[:2] == b"\xff\xff", "not a .xex"
    segs, run, i = [], None, 2
    while i < len(d):
        if d[i:i + 2] == b"\xff\xff":
            i += 2
        s = int.from_bytes(d[i:i + 2], "little")
        e = int.from_bytes(d[i + 2:i + 4], "little")
        i += 4
        data = d[i:i + e - s + 1]
        i += e - s + 1
        if (s, e) == (0x02E0, 0x02E1):
            run = int.from_bytes(data, "little")
        else:
            segs.append((s, data))
    return segs, run


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--xex", default="build/ash.xex")
    a = ap.parse_args()
    segs, entry = parse_xex(a.xex)
    with AtariLink() as l:
        for start, data in segs:
            for off in range(0, len(data), 256):
                l.poke(start + off, data[off:off + 256])
            rb = b"".join(l.peek(start + o, min(1024, len(data) - o))
                          for o in range(0, len(data), 1024))
            print(f"  ${start:04X}-${start + len(data) - 1:04X} "
                  f"{'OK' if rb == data else 'MISMATCH'}")
            if rb != data:
                sys.exit("verify failed - not starting")
        l.poke(RTS_STUB, b"\x60")
        l.poke(DOSINI, RTS_STUB.to_bytes(2, "little"))
        l.poke(DOSVEC, entry.to_bytes(2, "little"))
        l.poke(BOOTQ, b"\x01")
        l.poke(COLDST, b"\x00")
        l.poke(BASICF, b"\x01")
        l.reset(warm=True, keep=True)
        time.sleep(2.0)
        print("\n".join(r.rstrip() for r in l.screen().split("\n")[:8]))


if __name__ == "__main__":
    main()
