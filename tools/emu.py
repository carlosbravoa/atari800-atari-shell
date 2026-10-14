#!/usr/bin/env python3
"""emu.py — run ASH on a py65 6502 with CIO/SIO emulated (no OS ROM needed).

The PC-side regression rig. D1:-D4: are ATR images (writable, in memory;
--save writes them back), H: is a host folder, E:/K: are a captured screen
and a key script. CIO is a real dispatcher: devices other than E:/K: go
through HATABS to the 6502 handler, so ASH's own D: file manager is what
runs. Stops when a launched program reaches its run address (reporting
whether its segments landed intact).

  emu.py [--d1 X.ATR] [--d4 Y.ATR] [--hdir DIR] [--boot] [--save] "ls" ...
"""
import argparse
import os
import sys

from py65.devices.mpu6502 import MPU
from py65.memory import ObservableMemory

sys.path.insert(0, os.path.dirname(__file__))
import mkatr  # noqa: E402

CIOV, SIOV, COLDSV = 0xE456, 0xE459, 0xE477
HATABS = 0x031A
SENT = 0xFFF0                    # return address that ends a nested call
EOL = 0x9B


class Stop(Exception):
    pass


class Disk:
    """Writable ATR in memory (sector numbers 1..n)."""

    def __init__(self, path):
        self.path = path
        d = open(path, "rb").read()
        self.hdr = bytearray(d[:16])
        self.ss = int.from_bytes(d[4:6], "little")
        body = d[16:]
        self.full = self.ss == 256 and len(body) % 256 == 0
        self.sec = {}
        n, o = 1, 0
        while o < len(body):
            size = 128 if (self.ss == 128 or n <= 3) else 256
            step = 256 if (self.full and n <= 3) else size
            self.sec[n] = bytearray(body[o:o + size])
            o += step
            n += 1

    def read(self, n):
        return bytes(self.sec[n])

    def save(self, path=None):
        out = bytearray(self.hdr)
        for n in sorted(self.sec):
            s = self.sec[n]
            out += s + (bytes(128) if self.full and n <= 3 else b"")
        open(path or self.path, "wb").write(out)


MB = 0x0640                      # ASH-TN mailbox (see tn.s)
MB_CMDREQ, MB_STATUS, MB_LEN, MB_PING, MB_PONG, MB_CMD = 0x643, 0x644, 0x64B, 0x64E, 0x64F, 0x660
MB_OUT, MB_RAM, MB_MORE = 0x647, 0x651, 0x653


class Cart:
    """Williams 32K (.car type 22): a read of $D500+n maps bank n at $A000 and
    enables the cart; a read of $D508 disables it. The cart logic only resets
    on a firmware power-cycle, never on an Atari RESET."""

    def __init__(self, path):
        d = open(path, "rb").read()
        assert d[:4] == b"CART" and int.from_bytes(d[4:8], "big") == 22, "not a Williams 32K .car"
        self.banks = [d[16 + i * 8192:16 + (i + 1) * 8192] for i in range(4)]
        self.enabled, self.bank = True, 0

    def attach(self, mem):
        mem.subscribe_to_read(range(0xA000, 0xC000), self.read)
        mem.subscribe_to_read(range(0xD500, 0xD510), self.ctl)

    def read(self, a):
        return self.banks[self.bank][a - 0xA000] if self.enabled else None

    def ctl(self, a):
        if a & 8:
            self.enabled = False
        else:
            self.enabled, self.bank = True, a & 3
        return 0xFF

    def vector(self, mem, off):               # $BFFA run / $BFFE init
        return self.banks[0][off] | (self.banks[0][off + 1] << 8)


class Machine:
    def __init__(self, drives, hdir=None, keys=b"", mbcmds=None, cart=None, sdroot=None):
        self.cart = cart
        self.sdroot = sdroot              # a host folder standing in for the SD card
        self.fwreq = None                 # deferred firmware action (cart/boot/xex)
        self.cartname = "-"
        if cart:
            self.mpu = MPU(memory=ObservableMemory())
            cart.attach(self.mpu.memory)
        else:
            self.mpu = MPU()
        self.m = self.mpu.memory
        self.mbcmds = list(mbcmds or [])  # ASH-TN: commands to post via the mailbox
        self.mbout = []                   # (command, output bytes) collected
        self.nopong = False               # simulate "no PC program answering pings"
        self.disks = {u: Disk(p) for u, p in drives.items()}
        self.hdir = hdir
        self.hfiles = {}
        self.keys = list(keys)
        self.out = bytearray()
        self.watch = None
        self.iocb = {}                   # IOCB index -> 'E', 'K' or handler table address
        for a in (CIOV, SIOV, COLDSV):
            self.m[a] = 0x60
        self.m[0x58:0x5A] = (0xBC40).to_bytes(2, "little")   # SAVMSC: GR.0 screen

    def w16(self, a):
        return self.m[a] | (self.m[a + 1] << 8)

    @staticmethod
    def load_xex(path):
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
        mpu.y = y & 0xFF
        mpu.p = (mpu.p & ~(mpu.NEGATIVE | mpu.ZERO)) | (mpu.NEGATIVE if y & 0x80 else 0)
        lo = self.m[0x100 + ((mpu.sp + 1) & 0xFF)]
        hi = self.m[0x100 + ((mpu.sp + 2) & 0xFF)]
        mpu.sp = (mpu.sp + 2) & 0xFF
        mpu.pc = ((hi << 8) | lo) + 1

    # -- nested 6502 call (handler entry points)
    def call(self, addr, a=0, x=0):
        mpu, m = self.mpu, self.m
        save = (mpu.pc, mpu.a, mpu.x, mpu.sp)
        ret = SENT - 1
        m[0x100 + mpu.sp] = ret >> 8
        mpu.sp = (mpu.sp - 1) & 0xFF
        m[0x100 + mpu.sp] = ret & 0xFF
        mpu.sp = (mpu.sp - 1) & 0xFF
        mpu.pc, mpu.a, mpu.x = addr, a, x
        self.loop(until=SENT)
        y, a = mpu.y, mpu.a
        mpu.pc, _, mpu.x, mpu.sp = save[0], save[1], save[2], save[3]
        return y, a

    # -- CIO
    def cio(self):
        m, x = self.m, self.mpu.x
        io = 0x340 + x
        cmd = m[io + 2]
        dev = self.iocb.get(x)
        if cmd == 3:                                   # OPEN
            name = self.str_at(self.w16(io + 4))
            letter = name[:1].upper()
            unit = int(name[1]) if len(name) > 2 and name[1].isdigit() and name[2] == ":" else 1
            if letter in ("E", "K"):
                self.iocb[x] = letter
                return self.rts(1)
            tab = self.find_handler(letter)
            if tab is None:
                return self.rts(130)
            m[io + 1] = unit
            y, _ = self.hcall(tab, 0, x)
            if y < 128:
                self.iocb[x] = tab
            return self.rts(y)
        if cmd == 12:                                  # CLOSE
            if isinstance(dev, int):
                y, _ = self.hcall(dev, 1, x)
                self.iocb.pop(x, None)
                return self.rts(y)
            self.iocb.pop(x, None)
            return self.rts(1)
        if dev == "E" or (dev is None and x == 0):
            if cmd in (0x0B, 0x09):
                self.out.append(self.mpu.a)
            return self.rts(1)
        if dev == "K":
            if cmd in (5, 7):
                if not self.keys:
                    raise Stop("keys exhausted")
                k = self.keys.pop(0)
                m[0x2FC] = 0 if self.keys else 0xFF      # CH: another key pending?
                return self.rts(1, a=k)
            return self.rts(1)
        if cmd >= 14:                                  # XIO
            tab = dev
            if tab is None:
                name = self.str_at(self.w16(io + 4))
                tab = self.find_handler(name[:1].upper())
                m[io + 1] = int(name[1]) if len(name) > 2 and name[1].isdigit() else 1
                if tab is None:
                    return self.rts(130)
            y, _ = self.hcall(tab, 5, x)
            return self.rts(y)
        if not isinstance(dev, int):
            return self.rts(133)
        n = self.w16(io + 8)
        buf = self.w16(io + 4)
        if cmd in (7, 5):                              # GET chars / record
            if n == 0:
                y, a = self.hcall(dev, 2, x)
                return self.rts(y, a=a)
            got = 0
            y = 1
            while got < n:
                y, a = self.hcall(dev, 2, x)
                if y >= 128:
                    break
                m[buf + got] = a
                got += 1
                if cmd == 5 and a == EOL:
                    break
            m[io + 8:io + 10] = got.to_bytes(2, "little")
            return self.rts(y, a=a if got else 0)
        if cmd in (0x0B, 0x09):                        # PUT chars / record
            if n == 0:
                y, _ = self.hcall(dev, 3, x, a=self.mpu.a)
                return self.rts(y)
            y = 1
            for i in range(n):
                c = m[buf + i]
                y, _ = self.hcall(dev, 3, x, a=c)
                if y >= 128 or (cmd == 9 and c == EOL):
                    break
            return self.rts(y)
        if cmd == 13:
            y, _ = self.hcall(dev, 4, x)
            return self.rts(y)
        return self.rts(132)

    def find_handler(self, letter):
        for i in range(0, 36, 3):
            if self.m[HATABS + i] == ord(letter):
                return self.w16(HATABS + i + 1)
        return None

    def hcall(self, tab, k, x, a=0):
        m = self.m
        io = 0x340 + x
        m[0x20:0x2C] = m[io:io + 12]                   # ZIOCB
        m[0x2E] = x
        y, a = self.call(self.w16(tab + 2 * k) + 1, a=a, x=x)
        m[io + 3] = y
        return y, a

    def str_at(self, a):
        s = bytearray()
        while self.m[a] not in (EOL, 0) and len(s) < 120:
            s.append(self.m[a])
            a += 1
        return s.decode("latin1")

    # -- SIO
    def sio(self):
        m = self.m
        dev = m[0x300] + m[0x301] - 1
        cmd, buf, n = m[0x302], self.w16(0x304), self.w16(0x308)
        aux1, aux2 = m[0x30A], m[0x30B]
        if 0x31 <= dev <= 0x34:
            d = self.disks.get(dev - 0x30)
            if d is None:
                return self.rts(138)
            s = aux1 | (aux2 << 8)
            if cmd == 0x53:
                m[buf:buf + 4] = bytes([0x10 | (0x20 if d.ss == 256 else 0), 0xFF, 0xE0, 0])
                return self.rts(1)
            if s not in d.sec:
                return self.rts(144)
            if len(d.sec[s]) != n:
                return self.rts(143)
            if cmd == 0x52:
                m[buf:buf + n] = d.sec[s]
                return self.rts(1)
            if cmd in (0x50, 0x57):
                d.sec[s][:] = m[buf:buf + n]
                return self.rts(1)
            return self.rts(139)
        if dev == 0x72 and self.hdir:
            return self.hdev(cmd, aux1, aux2, buf, n)
        return self.rts(138)

    def hdev(self, cmd, aux1, aux2, buf, n):
        m, h = self.m, aux2 & 3
        p = lambda f: os.path.join(self.hdir, f)
        if cmd == 0x4F:
            name = bytes(m[buf:buf + 64]).split(b"\0")[0].decode().upper()
            if aux1 == 6:
                lines = b""
                for f in sorted(os.listdir(self.hdir)):
                    if os.path.isfile(p(f)):
                        lines += f.upper().ljust(14).encode() + str(os.path.getsize(p(f))).encode() + b"\x9b"
                self.hfiles[h] = [lines + b"END OF DIRECTORY\x9b", 0, None]
                return self.rts(1)
            if aux1 in (8, 9):
                self.hfiles[h] = [bytearray(), 0, name]
                return self.rts(1)
            for f in os.listdir(self.hdir):
                if f.upper() == name:
                    self.hfiles[h] = [open(p(f), "rb").read(), 0, None]
                    return self.rts(1)
            return self.rts(144)
        if cmd == 0x53:
            d, pos, _ = self.hfiles.get(h, [b"", 0, None])
            av = min(len(d) - pos, 65535)
            m[buf:buf + 4] = bytes([1, 1 | (2 if av == 0 else 0), av & 255, av >> 8])
            return self.rts(1)
        if cmd == 0x52:
            d, pos, _ = self.hfiles[h]
            if pos + n > len(d):
                return self.rts(144)
            m[buf:buf + n] = d[pos:pos + n]
            self.hfiles[h][1] = pos + n
            return self.rts(1)
        if cmd == 0x57:
            self.hfiles[h][0] += bytes(m[buf:buf + n])
            return self.rts(1)
        if cmd == 0x43:
            f = self.hfiles.pop(h, None)
            if f and f[2]:
                open(p(f[2]), "wb").write(f[0])
            return self.rts(1)
        if cmd == 0x58 and aux1 >= 40:
            return self.sdxio(aux1, h, buf)
        if cmd == 0x58:
            arg = bytes(m[buf:buf + 64]).split(b"\0")[0].decode().upper()
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

    def mailbox(self):
        """The PC side of the ASH-TN mailbox, in miniature: answer pings, post
        the next command when ASH is idle, collect output; Stop when done."""
        m = self.m
        if m[MB_PING] != m[MB_PONG] and not self.nopong:
            m[MB_PONG] = m[MB_PING]
        if m[MB_CMDREQ] or m[MB_STATUS] == 0:
            return
        if self.mbout and self.mbout[-1][1] is None:      # previous command finished
            out = self.w16(MB_OUT)
            n = self.w16(MB_LEN)
            self.mbout[-1] = (self.mbout[-1][0], bytes(m[out:out + n]), m[MB_STATUS], m[0x645])
        if not self.mbcmds:
            self.idle = getattr(self, "idle", 0) + 1
            if self.idle > 800:                     # ~3 M instructions with nothing to do
                raise Stop("mailbox idle")
            return
        self.idle = 0
        c = self.mbcmds.pop(0).encode("latin1")
        m[MB_CMD:MB_CMD + len(c) + 1] = c + b"\0"
        self.mbout.append((c.decode("latin1"), None))
        m[MB_CMDREQ] = 1

    # -- the phase-2 control XIOs (specs/ash-tn-proposal.md, byte-level table)
    def sdxio(self, fn, h, buf):
        m = self.m
        frame = bytes(m[buf:buf + 64])
        path = frame.split(b"\0")[0].decode("latin1")
        if self.sdroot is None:
            return self.rts(144)
        host = lambda p: os.path.join(self.sdroot, p.lstrip("/"))
        if fn == 40:                                   # LIST
            start = frame[62] | (frame[63] << 8)
            if not os.path.isdir(host(path)):
                return self.rts(144)
            names = sorted(os.listdir(host(path)), key=str.lower)
            lines, used = [], 0
            for name in names[start:]:
                full = host(os.path.join(path, name))
                if os.path.isdir(full):
                    line = f"d {'':8s} {name[:27]}"
                else:
                    line = f"f {os.path.getsize(full):8d} {name[:27]}"
                if used + len(line) + 1 + 5 > 1024:
                    lines.append("MORE")
                    break
                lines.append(line)
                used += len(line) + 1
            else:
                lines.append("END")
            self.hfiles[h] = [b"\x9b".join(l.encode("latin1") for l in lines) + b"\x9b", 0, None]
            return self.rts(1)
        if fn == 47:                                   # OPENR
            if not os.path.isfile(host(path)):
                return self.rts(144)
            self.hfiles[h] = [open(host(path), "rb").read(), 0, None]
            return self.rts(1)
        if fn == 41:                                   # MOUNT "<n>path" (deferred)
            n, p = path[0], path[1:]
            if n not in "1234" or not os.path.isfile(host(p)):
                return self.rts(144)
            if p.lower().endswith(".xex"):
                self.fwreq = f"firmware: mount_xex + cold_boot_xex {p}"
            else:
                self.disks[int(n)] = Disk(host(p))
            return self.rts(1)
        if fn == 42:                                   # UNMOUNT
            if path[:1] not in "1234":
                return self.rts(144)
            self.disks.pop(int(path[0]), None)
            return self.rts(1)
        if fn == 43:                                   # CART (deferred)
            if not os.path.isfile(host(path)):
                return self.rts(144)
            self.fwreq = f"firmware: load_cartridge + cold boot {path}"
            return self.rts(1)
        if fn == 44:                                   # BOOT (deferred)
            self.fwreq = f"firmware: {'cold' if path[:1] == 'C' else 'warm'} boot"
            return self.rts(1)
        if fn == 45:                                   # STATUS listing
            lines = [f"d{u}: {os.path.basename(self.disks[u].path) if u in self.disks else '-'}" for u in range(1, 5)]
            lines += [f"cart: {self.cartname}", "xex: 0", "boot: ash", "END"]
            self.hfiles[h] = [b"\x9b".join(l.encode("latin1") for l in lines) + b"\x9b", 0, None]
            return self.rts(1)
        return self.rts(144)

    def loop(self, until=None, steps=200_000_000):
        mpu = self.mpu
        for i in range(steps):
            p = mpu.pc
            if p == until:
                return
            if self.fwreq and i % 20000 == 0:        # the firmware's main loop acts on it
                raise Stop(self.fwreq)
            if i % 10000 == 0:                       # RTCLOK: ~1 jiffy per 10k instructions
                m = self.m
                m[0x14] = (m[0x14] + 1) & 0xFF
                if m[0x14] == 0:
                    m[0x13] = (m[0x13] + 1) & 0xFF
            if not self.keys and i % 4096 == 0 and self.m[MB] == ord("A") and self.m[MB + 1] == ord("S"):
                self.mailbox()
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

    def run(self, pc):
        self.mpu.pc = pc
        self.loop()

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


def build(a, keys):
    drives = {u: getattr(a, f"d{u}") for u in range(1, 5) if getattr(a, f"d{u}")}
    cart = Cart(a.cart) if a.cart else None
    mc = Machine(drives, a.hdir, keys, a.mb, cart, a.sdroot)
    mc.nopong = a.no_pong
    m = mc.m
    m[0x2FC] = 0 if keys else 0xFF
    if cart:
        mc.mpu.sp = 0xFD
        mc.call(cart.vector(m, 0x1FFE))           # init: plants the copier
        entry = cart.vector(m, 0x1FFA)            # run: the copier
    elif a.boot:
        d = mc.disks[1]
        m[0x0700:0x0800] = d.read(1) + d.read(2)
        mc.mpu.sp = 0xFD
        entry = 0x0706
    else:
        for s, d in mc.load_xex(a.xex):
            if s != 0x02E0:
                m[s:s + len(d)] = d
        entry = 0x2000
    return mc, entry


def main():
    ap = argparse.ArgumentParser()
    for u in range(1, 5):
        ap.add_argument(f"--d{u}")
    ap.add_argument("--hdir")
    ap.add_argument("--sdroot", help="host folder served as the SD card through the phase-2 XIOs")
    ap.add_argument("--xex", default=os.path.join(os.path.dirname(__file__), "../build/ash.xex"))
    ap.add_argument("--boot", action="store_true", help="boot D1: through its boot sector")
    ap.add_argument("--cart", help="boot this ASH.CAR as the OS would (init vector, then run vector)")
    ap.add_argument("--reset", action="store_true", help="after the launched program starts, press RESET (JSR (DOSINI)) and report")
    ap.add_argument("--expect", help="xex whose segments must be in RAM at the run address")
    ap.add_argument("--save", action="store_true", help="write modified disks back")
    ap.add_argument("--esc", action="store_true", help=r"decode \xNN escapes in cmds (key codes)")
    ap.add_argument("--mb", action="append", default=[], help="ASH-TN: post this command via the mailbox (after the keys)")
    ap.add_argument("--no-pong", action="store_true", help="ASH-TN: never answer the shell's pings")
    ap.add_argument("cmds", nargs="*")
    a = ap.parse_args()
    cmds = [c.encode("latin1").decode("unicode_escape") for c in a.cmds] if a.esc else a.cmds
    keys = b"".join(c.encode("latin1").replace(b"\t", b"\x7f") + b"\x9b" for c in cmds)
    mc, entry = build(a, keys)
    cart, m = mc.cart, mc.m
    if a.expect:
        segs = mc.load_xex(a.expect)
        run = next((int.from_bytes(d, "little") for s, d in segs if s == 0x2E0), segs[0][0])
        mc.watch = (run, segs)
    try:
        mc.run(entry)
    except Stop as e:
        why = str(e)
    print(mc.screen())
    for c, out, *st in mc.mbout:
        print(f"--- mailbox: {c!r} -> status {st[0] if st else '?'} err {st[1] if st else '?'}")
        print(out.decode("latin1").replace("\x9b", "\n") if out is not None else "(unfinished)")
    print(f"--- stop: {why}")
    if a.expect and why.startswith("reached"):
        bad = [s for s, d in mc.watch[1] if s not in (0x2E0, 0x2E2) and bytes(mc.m[s:s + len(d)]) != d]
        print("segments intact" if not bad else f"MISMATCH at {[hex(b) for b in bad]}")
        if cart:
            print(f"cart enabled while the program runs: {cart.enabled}")
        if a.reset and cart:
            dosini = mc.w16(0x0C)
            print(f"RESET: COLDST={m[0x244]}, DOSINI=${dosini:04X}")
            mc.watch = None
            try:
                mc.call(dosini)
                why2 = "returned"
            except Stop as e:
                why2 = str(e)
            print(f"after DOSINI: {why2}; cart enabled: {cart.enabled}, bank {cart.bank}, GINTLK={m[0x3FA]}")
    if a.save:
        for d in mc.disks.values():
            d.save()


if __name__ == "__main__":
    main()
