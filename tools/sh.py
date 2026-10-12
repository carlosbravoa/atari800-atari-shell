#!/usr/bin/env python3
"""Type commands into ASH on the Atari and print the screen afterwards.

  sh.py "ls -l" "cd h:" ...       one command per argument (RETURN appended)
  sh.py --raw "abc<TAB>"          keystrokes only; <TAB> <UP> <DOWN> <RET> <BS> <BRK>
Each character is its own short type session, so doubled letters survive.
"""
import re
import sys
import time

ATARI = "/home/carlos/devel/fpga/atari800_tang_nano20k_parallel"
sys.path.insert(0, f"{ATARI}/tools")
from atari_link import AtariLink  # noqa: E402

# HID usage codes for keys that aren't plain ASCII (mod bit0 = Ctrl)
SPECIAL = {"TAB": (0x2B, 0), "UP": (0x2F, 1), "DOWN": (0x30, 1), "CLR": (0x2D, 1),
           "RET": (0x28, 0), "BS": (0x2A, 0), "BRK": (0x48, 0), "ESC": (0x29, 0)}


def keys(l, text):
    for tok in re.split(r"(<[A-Z]+>)", text):
        if tok.startswith("<") and tok[1:-1] in SPECIAL:
            hid, mod = SPECIAL[tok[1:-1]]
            l.key(hid, mod)
            time.sleep(0.08)
        else:
            for ch in tok:
                for attempt in range(5):
                    try:
                        l.type_key(ch)
                        break
                    except Exception:
                        time.sleep(1.0)


def settle(l, quiet=0.8, limit=60):
    """Wait until the screen stops changing."""
    last, t0, same = None, time.time(), time.time()
    while time.time() - t0 < limit:
        try:
            s = l.screen()
        except Exception:          # firmware busy serving SIO: try again
            time.sleep(0.5)
            continue
        if s != last:
            last, same = s, time.time()
        elif time.time() - same > quiet:
            break
        time.sleep(0.25)
    return last


def main():
    args = sys.argv[1:]
    raw, wait, limit = False, 0.0, 60
    while args and args[0].startswith("--"):
        k, _, v = args.pop(0).partition("=")
        if k == "--wait":
            wait = float(v)           # hands off the link while SIO runs
        elif k == "--raw":
            raw = True
        elif k == "--limit":
            limit = float(v)          # give up waiting for a still screen

    with AtariLink() as l:
        for a in args:
            keys(l, a if raw else a + "\n")
            time.sleep(wait)
            settle(l, limit=limit)
        print("\n".join(r.rstrip() for r in settle(l, limit=limit).split("\n")).rstrip())


if __name__ == "__main__":
    main()
