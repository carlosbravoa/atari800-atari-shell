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

## Commands

| | |
|---|---|
| `ls [-l] [path]` | list (`*` = executable, `/` = MyDOS subdirectory; `-l` sizes + free sectors) |
| `cd path` / `d2:` / `h:` | change drive/dir: `d1:`–`d4:`, `h:`, `..`, `/`, `games/sub` |
| `pwd`, `cat`, `xxd`, `file` | where am I, show text (paged), hex dump, identify / list xex segments |
| `run file`, or just `name` | load and run; a bare name tries `name`, `.xex`, `.com`, `.exe` |
| `df` | drives present, density, free sectors; H: file count |
| `rm`, `mv` | delete / rename on `h:` (disks are read-only from ASH) |
| `peek adr [len]`, `poke adr b..` | memory (hex) |
| `theme green\|amber\|blue\|white`, `history`, `clear`, `echo`, `basic`, `reboot`, `ver`, `help` | |

Line editor: TAB completes file names (lists choices when ambiguous), ↑/↓
recall the last 8 commands, Ctrl-U kills the line, Ctrl-L clears, BREAK
cancels. RESET at the prompt returns to ASH instantly.

Devices: `d1:`–`d4:` are any DOS 2.0/2.5/MyDOS disk (SD or DD, MyDOS
subdirectories and 16-bit sector links). `h:` is the Tang Nano board's SD
folder `/HDD` (SIO device $72) — so programs can be copied from the PC
(`atari.py send GAME.XEX HDD/GAME.XEX`) and run without making a disk.

## How it works

- `$2000-$3FFF` shell, `$4000-$4FFF` buffers. BASIC is switched off.
- A 421-byte resident kernel at `$0700-$08FF` (+ sector buffer `$0900-$09FF`)
  streams files and runs the XEX loader (INITAD / RUNAD, first-segment
  default). That's inside DOS 2.5's own footprint, so anything that loads
  under DOS loads under ASH. After a launch RESET does a cold boot.
- Programs that need a DOS (`D:` file I/O at run time) won't find one.

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
`tools/emu.py` (py65 rig: CIO/SIO trapped, ATRs + H: folder served — runs
the boot path, listings and launches deterministically, checks loaded
segments), `tools/hwrun.sh` (launch `h:NAME` on hardware, liveness check).
