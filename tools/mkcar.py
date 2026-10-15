#!/usr/bin/env python3
"""mkcar.py — pack ASH into a Williams 32K cartridge image (.car type 22).

  mkcar.py -o ASH.CAR build/cart0.bin build/ash-cart.xex

Bank 0 = cart0.bin (8 KB: copier + vectors), banks 1-3 = the .xex's MAIN
segment ($2000-$67FF, zero-padded). 16-byte CAR header:
"CART", type (big-endian), checksum of the data (big-endian), 0.
"""
import argparse

BANK = 8192


def xex_main(path):
    d = open(path, "rb").read()
    assert d[:2] == b"\xff\xff"
    s = int.from_bytes(d[2:4], "little")
    e = int.from_bytes(d[4:6], "little")
    assert s == 0x2000, f"image must load at $2000 (got ${s:04X})"
    body = d[6:6 + e - s + 1]
    assert len(body) <= 3 * BANK, f"image {len(body)} bytes > 3 banks"
    return body


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("-o", required=True)
    ap.add_argument("bank0")
    ap.add_argument("xex")
    a = ap.parse_args()
    b0 = open(a.bank0, "rb").read()
    assert len(b0) == BANK, f"bank 0 is {len(b0)} bytes"
    img = xex_main(a.xex)
    data = b0 + img.ljust(3 * BANK, b"\0")
    hdr = b"CART" + (22).to_bytes(4, "big") + (sum(data) & 0xFFFFFFFF).to_bytes(4, "big") + bytes(4)
    open(a.o, "wb").write(hdr + data)
    print(f"{a.o}: {len(hdr) + len(data)} bytes, image {len(img)} bytes in banks 1-3")


if __name__ == "__main__":
    main()
