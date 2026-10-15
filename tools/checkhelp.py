#!/usr/bin/env python3
"""checkhelp.py — fail the build if a help line would wrap (≥ 40 columns) or
the help would page (> 22 lines) in either edition."""
import re, sys
s = open(sys.argv[1]).read()
i = s.index("s_help:"); j = s.index("        .byte 0", i)
block = s[i:j]
ok = True
for tn in (False, True):
    lines, keep = [], True
    for l in block.splitlines():
        if l.startswith(".ifdef TN"): keep = tn; continue
        if l.startswith(".endif"): keep = True; continue
        m = re.search(r'\.byte "([^"]*)",EOL', l)
        if m and keep: lines.append(m.group(1))
    for t in lines:
        if len(t) >= 40: print(f"help line {len(t)} cols: {t}"); ok = False
    if len(lines) > 22: print(f"help is {len(lines)} lines ({'TN' if tn else 'generic'})"); ok = False
sys.exit(0 if ok else 1)
