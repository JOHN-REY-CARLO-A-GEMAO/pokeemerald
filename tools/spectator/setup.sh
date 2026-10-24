#!/bin/sh
# setup.sh - regenerate the two data files the bot needs.
#
#   1. data/world.lua    every map's geometry, doors, NPCs and story triggers,
#                        compiled from this repo's map data.
#   2. data/symbols.lua  the RAM addresses of the globals the bot reads,
#                        extracted from the linker map made by `make`.
#
# Run this after every rebuild of the ROM (addresses move when the ROM changes).
set -e
cd "$(dirname "$0")/../.."

echo "== compiling world data from map/layout data"
python3 tools/spectator/tools/build_world.py

echo
echo "== extracting symbols from the linker map"
if ! python3 tools/spectator/tools/build_symbols.py; then
  echo
  echo "Could not find a linker map. Build the ROM first:"
  echo "    make            # produces pokeemerald.gba and pokeemerald.map"
  echo "then run this script again."
  exit 1
fi

echo
echo "Done. In mGBA open Tools > Scripting > File > Load script and pick:"
echo "    tools/spectator/autoplay.lua"
