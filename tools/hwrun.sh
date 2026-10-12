#!/bin/bash
# hwrun.sh NAME [WAIT] — on hardware: fresh ASH, launch h:NAME, report liveness.
cd "$(dirname "$0")/.."
A="python3 /home/carlos/devel/fpga/atari800_tang_nano20k_parallel/tools/atari.py"
$A reset >/dev/null; sleep 4
timeout 100 python3 deploy.py >/dev/null || { echo "deploy failed"; exit 1; }
python3 tools/sh.py --limit=3 "cd h:" >/dev/null
python3 tools/sh.py --wait=${2:-30} --limit=3 "$1" | tail -24
echo "--- RTCLOK:"; $A peek 0x12 3; sleep 1; $A peek 0x12 3
