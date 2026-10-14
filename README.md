# ASH — the Atari SHell

A Unix-style command line for the Atari 8-bit (XL/XE, 64 KB) that replaces the
DOS menu: browse disks and launch `.xex` programs directly. No DOS is loaded —
ASH reads DOS 2.x / MyDOS directories and files sector by sector over SIO.

```
ASH 1.0 - the Atari SHell
d1:/$ ls
neondrop.xex* candy.xex*   readme.txt
d1:/$ file neondrop.xex
neondrop.xex: atari executable
  $2000-$3f75
  $4800-$5607
  $02e0-$02e1 run $2047
d1:/$ neondrop
loading neondrop.xex
```

<p align="center">
<img src="docs/ash-1.jpg" width="700" alt="ASH on the Tang Nano 20K Atari: df, cp from the HDD and from h:, mkdir, ls -l of a MyDOS subdirectory, cat"><br>
<em>Copying files between the hard drive (d4:), the SD card folder (h:) and a floppy, into a new directory.</em>
</p>
<p align="center">
<img src="docs/ash-2.jpg" width="700" alt="ASH: copying a game from h: to d1:, file showing its segments, mv, lock/unlock, rm with wildcards, rmdir"><br>
<em>A game copied onto the disk and inspected with <code>file</code>; rename, lock, wildcard delete and rmdir.</em>
</p>

## Commands

| | |
|---|---|
| `ls [-l] [path]` | list (`*` = executable, `/` = MyDOS subdirectory; `-l` sizes + free sectors) |
| `cd path` / `d2:` / `h:` | change drive/dir: `d1:`–`d4:`, `h:`, `..`, `/`, `games/sub` |
| `pwd`, `cat`, `xxd`, `file` | where am I, show text (paged), hex dump, identify / list xex segments |
| `run file`, or just `name` | load and run; a bare name tries `name`, `.xex`, `.com`, `.exe` |
| `df` | drives present, density, free sectors; H: file count |
| `cp src dst` | copy between any disks and `h:`; `dst` may be a directory |
| `rm`, `mv` | delete (wildcards on disks), rename or move |
| `mkdir`, `rmdir` | MyDOS subdirectories |
| `lock`, `unlock` | write-protect files |
| `format dn:` | quick-format a disk as empty DOS 2 (asks first) |
| `edit file` | full-screen text editor (below) |
| `peek adr [len]`, `poke adr b..` | memory (hex) |
| `theme green\|amber\|blue\|white`, `history`, `clear`, `echo`, `basic`, `reboot`, `ver`, `help` | |

Line editor: TAB completes file names (lists choices when ambiguous), ↑/↓
recall the last 8 commands, Ctrl-U kills the line, Ctrl-L clears, BREAK
cancels. RESET at the prompt returns to ASH instantly.

Devices: `d1:`–`d4:` are any DOS 2.0/2.5/MyDOS disk (SD or DD, MyDOS
subdirectories and 16-bit sector links). `h:` is the Tang Nano board's SD
folder `/HDD` (SIO device $72) — so programs can be copied from the PC
(`atari.py send GAME.XEX HDD/GAME.XEX`) and run without making a disk.

## The editor

`edit FILE` opens (or creates) a text file, on a disk or on `h:`. Arrows
move, typing inserts, Backspace and Ctrl-Delete delete, Shift-Delete or
Ctrl-K kills a line, Tab indents to the next multiple of 4, Ctrl-A / Ctrl-E
go to the start / end of the line, **Ctrl-S saves, Ctrl-Q quits** (it warns
once if there are unsaved changes). Long lines scroll sideways. Files keep
their line-ending style: a Unix file stays Unix, new files use ATASCII.
16 KB of text.

## The D: device

ASH installs a read/write `D:` handler (`$0700-$1BFF`, below DOS 2.5's
MEMLO) that stays resident for BASIC and for launched programs: `OPEN`,
`LOAD`/`SAVE`, `LIST "D:X.LST"`, `ENTER`, XIO rename/delete/lock/unlock,
`XIO 42` mkdir and `XIO 254` quick-format all work, with wildcards and
`DIR>` / `DIR/` paths. Disks must be 720-sector DOS 2 format (SD or DD);
other layouts (big MyDOS, SpartaDOS) are readable but not writable. RESET
keeps `D:` alive.

Note: `.BAS` files written by BASIC's `SAVE` are tokenized, not text —
`cat` shows binary; use `LIST "D:NAME.LST"` for a text listing.

## ASH-TN: the Tang Nano 20K build

`make tn` builds `ash-tn.xex` (and `make release` adds `ASH-TN.XEX` /
`ASH-TN.ATR`): the same shell plus a page-6 **mailbox** (`$0640`, see
`tn.s`) through which the PC drives it over the board's PC link with no
keystroke injection, plus two commands: `pc` (is the PC program there? — if
not: *make sure the board is powered via usb and ashterm is running on the
pc*) and `getw` (used by `get`). On the PC:

```
python3 tools/ashterm.py                 # terminal: ASH's own prompt, exact output, Ctrl-C aborts
python3 tools/ashterm.py -c "ls -l" -c "cat readme.txt"
python3 tools/ashterm.py get d1:game.xex ~/game.xex   # any disk, h:, MyDOS subdir
python3 tools/ashterm.py put ~/game.xex d1:           # via h:, then cp
```
`ashterm` tells you what to check when it can't work: no board connected
and powered via USB, board up but ASH-TN not running, or the shell busy in
a pager / the editor / a launched program. Protocol: the PC pokes a
command line and sets `MB_CMDREQ`; ASH runs it (echoed on the TV, never
paged), mirrors the output to `$6A00` with a running length, and reports
status 1 (ok) / 2 (error, with the code) / 3 (a program was launched).

## On a real Atari

Disk access is plain SIO through the OS, so any Atari drive or SIO2SD /
SDrive / FujiNet works, at standard speed. `h:` is the Tang Nano board's
SD-folder device; ASH probes it at boot and hides it when it isn't there.
Tested on the board's XL/XE (64 KB); a 400/800 should work but is untested.
Writable disks are 720-sector SD or DD; ED and big MyDOS disks are read-only.

## How it works

- `$2000-$55FF` shell, `$5600-$65FF` buffers, `$6600+` editor text / BASIC.
  BASIC is switched off (the `basic` command turns it back on).
- The resident kernel at `$0700-$1BFF` streams files (DOS 2 / MyDOS sector
  chains or `h:`), runs the XEX loader (INITAD / RUNAD, first-segment
  default) and holds the `D:` file manager with its buffers. That's inside
  DOS 2.5's own footprint, so anything that loads under DOS loads under
  ASH, and launched programs can use `D:`. After a launch RESET cold-boots.

## Building & using

```
make                                   # build/ash.xex, build/boot.bin
python3 tools/mkatr.py -o ASH.ATR --shell build/ash.xex --boot build/boot.bin \
        game1.xex "Long Name.xex=GAME2.XEX" readme.txt      # [--dd] for 180K
```
Boot `ASH.ATR` on D1: (OSD → D1: → Attach → Boot to OS), or load
`build/ash.xex` as an executable. `mkatr.py --list X.ATR` lists any DOS 2/MyDOS ATR.

Dev tools: `deploy.py` (inject into a running Atari over the PC link and
warm-start it), `tools/sh.py` (type commands, dump the screen),
`tools/emu.py` (py65 rig: CIO dispatched through HATABS so the real D:
handler runs, writable ATRs + H: folder served, `--esc` key scripts — runs
the boot path, listings, file ops, the editor and launches deterministically),
`tools/test_fms.py` (the D: handler through CIO, SD + DD, fsck after every
step), `mkatr.py --fsck DISK.ATR` (DOS 2 structure checker),
`tools/hwrun.sh` (launch `h:NAME` on hardware, liveness check).
