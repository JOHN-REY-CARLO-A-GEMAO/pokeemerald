#!/usr/bin/env python3
"""
build_symbols.py - turn a pokeemerald linker map into data/symbols.lua.

The bot needs to know *where* this particular ROM keeps its globals.  Addresses
are not hardcoded: they are read out of the .map file that `make` produces next
to the ROM, so the bot keeps working when the ROM is rebuilt from this tree
(or from any fork that still produces a .map).

    make                      # builds pokeemerald.gba and pokeemerald.map
    python3 tools/spectator/tools/build_symbols.py pokeemerald.map

What lands in data/symbols.lua:
  abs : every RAM symbol (EWRAM / IWRAM / IO / OAM), name -> address
        e.g. gSaveBlock1Ptr, gMain, gBattleMons
  cb  : address-sorted function symbols used to answer "which screen is the
        game on?" by resolving gMain.callback2 (CB2_Overworld, CB2_BattleMain,
        CB2_InitTitleScreen, ...)
"""

import argparse
import os
import re
import sys

HERE = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))

RAM_RANGES = (
    (0x02000000, 0x02040000),   # EWRAM
    (0x03000000, 0x03008000),   # IWRAM
    (0x04000000, 0x04000400),   # IO registers
    (0x05000000, 0x05000400),   # palette
    (0x06000000, 0x06018000),   # VRAM
    (0x07000000, 0x07000400),   # OAM
)
ROM_RANGES = (
    (0x08000000, 0x0A000000),
)

SYMBOL_LINE = re.compile(r"^\s+(0x[0-9a-fA-F]{8,16})\s+([A-Za-z_$][\w.$]*)\s*$")
ABS_DEF = re.compile(r"^\s*([A-Za-z_$][\w.$]*)\s*=\s*(0x[0-9a-fA-F]+)\s*$")


def in_ranges(addr, ranges):
    return any(lo <= addr < hi for lo, hi in ranges)


def parse_map(path):
    """Returns {name: address} for every symbol the linker printed."""
    syms = {}
    with open(path, errors="replace") as f:
        for line in f:
            m = SYMBOL_LINE.match(line)
            if m:
                addr = int(m.group(1), 16)
                name = m.group(2)
                if name not in syms or addr < syms[name]:
                    syms[name] = addr
                continue
            m = ABS_DEF.match(line)
            if m:
                addr = int(m.group(2), 16)
                syms.setdefault(m.group(1), addr)
    return syms


def lua_quote(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def build(path, include_all_rom=False, quiet=False):
    syms = parse_map(path)
    if not quiet:
        print("parsed %d symbols from %s" % (len(syms), os.path.basename(path)))

    abs_syms = {}
    cb_syms = {}
    for name, addr in syms.items():
        if in_ranges(addr, RAM_RANGES):
            abs_syms[name] = addr
        elif in_ranges(addr, ROM_RANGES):
            if include_all_rom or re.match(r"^(CB1_|CB2_)", name) or name in (
                    "AgbMain", "Main", "AgbMainLoop", "GameMain", "CheckForFlashMemory"):
                cb_syms[name] = addr

    # callback2 sometimes points at a Thumb function entry (odd address)
    pairs = sorted(cb_syms.items(), key=lambda kv: kv[1])

    if not quiet:
        print("  RAM symbols: %d   callback symbols: %d" % (len(abs_syms), len(pairs)))
        required = ["gSaveBlock1Ptr", "gMain", "gBattleMons", "gBattleTypeFlags"]
        missing = [r for r in required if r not in abs_syms]
        if missing:
            print("  WARNING: missing expected symbols: " + ", ".join(missing))
            print("  The ROM probably was not built from this tree; the bot may "
                  "not be able to read game state.")
        else:
            print("  all required symbols found")

    parts = []
    parts.append("-- GENERATED FILE - do not edit.")
    parts.append("-- Built from %s by tools/spectator/tools/build_symbols.py"
                 % os.path.basename(path))
    parts.append("return {")
    parts.append("  abs = {")
    for name in sorted(abs_syms):
        parts.append("    [%s] = 0x%08X," % (lua_quote(name), abs_syms[name]))
    parts.append("  },")
    parts.append("  cb = {")
    # flat, address-sorted: addr, name, addr, name, ...
    row = []
    for name, addr in pairs:
        row.append("0x%08X,%s" % (addr, lua_quote(name)))
    for i in range(0, len(row), 6):
        parts.append("    " + ",".join(row[i:i + 6]) + ",")
    parts.append("  },")
    parts.append("}")
    return "\n".join(parts) + "\n"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("mapfile", nargs="?",
                    help="pokeemerald.map (default: pokeemerald.map, then build/*.map)")
    ap.add_argument("-o", "--out", default=os.path.join(HERE, "data", "symbols.lua"))
    ap.add_argument("--all-rom", action="store_true",
                    help="include every ROM symbol (bigger file, useful for debugging)")
    ap.add_argument("-q", "--quiet", action="store_true")
    args = ap.parse_args()

    candidates = []
    if args.mapfile:
        candidates.append(args.mapfile)
    else:
        root = os.path.abspath(os.path.join(HERE, "..", ".."))
        for name in sorted(os.listdir(root)):
            if name.endswith(".map"):
                candidates.append(os.path.join(root, name))
        build_dir = os.path.join(root, "build")
        if os.path.isdir(build_dir):
            for name in sorted(os.listdir(build_dir)):
                if name.endswith(".map"):
                    candidates.append(os.path.join(build_dir, name))

    path = next((c for c in candidates if os.path.exists(c)), None)
    if not path:
        sys.exit("build_symbols: no .map file found.\n"
                 "  Build the ROM first (make), then run:\n"
                 "    python3 tools/spectator/tools/build_symbols.py pokeemerald.map")

    text = build(path, args.all_rom, args.quiet)
    os.makedirs(os.path.dirname(args.out), exist_ok=True)
    with open(args.out, "w") as f:
        f.write(text)
    if not args.quiet:
        print("wrote %s (%.1f KiB)" % (args.out,
                                       os.path.getsize(args.out) / 1024.0))


if __name__ == "__main__":
    main()
