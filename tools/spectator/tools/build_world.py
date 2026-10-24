#!/usr/bin/env python3
"""
build_world.py - compile this repository's map data into a world the autoplay
bot can navigate.

The bot runs inside mGBA's Lua scripting sandbox, which cannot read the
repository.  So we pre-bake everything that never changes at runtime (map
geometry, doors, connections, NPC positions, story triggers, constant values)
into a single Lua table: data/world.lua.

Nothing here is guesswork: every number comes from
  - data/layouts/layouts.json + data/layouts/*/map.bin   (block geometry)
  - data/tilesets/*/metatile_attributes.bin              (tile behaviour)
  - data/maps/map_groups.json, data/maps/*/map.json      (maps, warps, NPCs)
  - include/constants/*.h                                (flags, vars, ...)

Usage:
    python3 tools/spectator/tools/build_world.py [-o data/world.lua] [-q]

Then:
    python3 tools/spectator/tools/build_symbols.py ../pokeemerald.map
"""

import argparse
import json
import os
import re
import struct
import sys

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", ".."))
HERE = os.path.join(REPO, "tools", "spectator")

# Block entry layout (see include/global.fieldmap.h / map_data.c):
#   bits 0-9   metatile id
#   bits 10-11 collision
#   bits 12-15 elevation
METATILE_MASK = 0x03FF
COLLISION_SHIFT = 10
COLLISION_MASK = 0x03

# Tile behaviours we care about at runtime.  Names match
# include/constants/metatile_behaviors.h.
LEDGE_BEHAVIOURS = {
    "MB_JUMP_EAST": "right",
    "MB_JUMP_WEST": "left",
    "MB_JUMP_NORTH": "up",
    "MB_JUMP_SOUTH": "down",
    "MB_JUMP_NORTHEAST": "upright",
    "MB_JUMP_NORTHWEST": "upleft",
    "MB_JUMP_SOUTHEAST": "downright",
    "MB_JUMP_SOUTHWEST": "downleft",
}

# Tiles that teleport you / lead somewhere even without playing a warp event.
AUTO_WARP_BEHAVIOURS = {
    "MB_NON_ANIMATED_DOOR",
    "MB_ANIMATED_DOOR",
    "MB_LADDER",
    "MB_UP_ESCALATOR",
    "MB_DOWN_ESCALATOR",
    "MB_EAST_ARROW_WARP",
    "MB_WEST_ARROW_WARP",
    "MB_NORTH_ARROW_WARP",
    "MB_SOUTH_ARROW_WARP",
    "MB_ESCALATOR",
}

# Terrain hints (used by the route runner to prefer clean tiles and to know
# where wild encounters are likely).
TERRAIN_BEHAVIOURS = {
    "MB_TALL_GRASS": "grass",
    "MB_LONG_GRASS": "grass",
    "MB_SHORT_GRASS": "grass",
    "MB_ASHGRASS": "grass",
    "MB_CAVE": "cave",
    "MB_DEEP_SAND": "sand",
    "MB_SAND": "sand",
    "MB_PUDDLE": "waterish",
    "MB_SHALLOW_WATER": "waterish",
    "MB_REFLECTION_UNDER_BRIDGE": "waterish",
}


# --------------------------------------------------------------------------
# constant parsing
# --------------------------------------------------------------------------
def strip_comments(text):
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    text = re.sub(r"//[^\n]*", "", text)
    return text


import ast

_BIN_OPS = {
    ast.Add: lambda a, b: a + b,
    ast.Sub: lambda a, b: a - b,
    ast.Mult: lambda a, b: a * b,
    ast.Div: lambda a, b: a // b,
    ast.LShift: lambda a, b: a << b,
    ast.RShift: lambda a, b: a >> b,
    ast.BitOr: lambda a, b: a | b,
    ast.BitAnd: lambda a, b: a & b,
    ast.BitXor: lambda a, b: a ^ b,
}
_UNARY_OPS = {ast.UAdd: lambda a: a, ast.USub: lambda a: -a}


def safe_eval(expr, names):
    """Evaluate a constant expression like (SYSTEM_FLAGS + 0x7) safely."""
    try:
        tree = ast.parse(expr.strip(), mode="eval")
    except SyntaxError:
        return None

    def walk(node):
        if isinstance(node, ast.Expression):
            return walk(node.body)
        if isinstance(node, ast.Constant) and isinstance(node.value, int):
            return node.value
        if isinstance(node, ast.Name):
            if node.id in names:
                return names[node.id]
            raise KeyError(node.id)
        if isinstance(node, ast.BinOp) and type(node.op) in _BIN_OPS:
            return _BIN_OPS[type(node.op)](walk(node.left), walk(node.right))
        if isinstance(node, ast.UnaryOp) and type(node.op) in _UNARY_OPS:
            return _UNARY_OPS[type(node.op)](walk(node.operand))
        raise ValueError(type(node).__name__)

    try:
        return walk(tree)
    except (KeyError, ValueError, ZeroDivisionError):
        return None


def scan_header(path, out, exprs):
    """Collect plain defines/enums into `out`, expression defines into `exprs`."""
    if not os.path.exists(path):
        return
    text = strip_comments(open(path, errors="replace").read())

    for m in re.finditer(r"^[ \t]*#define[ \t]+([A-Za-z_]\w*)[ \t]+(0x[0-9a-fA-F]+|\d+)\b",
                         text, re.M):
        out[m.group(1)] = int(m.group(2), 0)

    # enums (implicit numbering plus explicit "= value")
    for block in re.finditer(r"enum\s*\w*\s*\{(.*?)\}", text, re.S):
        value = 0
        for item in block.group(1).split(","):
            item = item.strip()
            if not item:
                continue
            name, _, val = item.partition("=")
            name = name.strip()
            if not re.match(r"^[A-Za-z_]\w*$", name):
                continue
            if val.strip():
                v = safe_eval(val, out)
                if v is not None:
                    value = v
            out[name] = value
            value += 1

    for m in re.finditer(r"^[ \t]*#define[ \t]+([A-Za-z_]\w*)[ \t]+(\([^\n]*)",
                         text, re.M):
        exprs.append((m.group(1), m.group(2).split("//")[0]))


def collect_constants(repo):
    """Resolve every constant in include/constants/*.h into one namespace.

    Constants reference each other across headers (SYSTEM_FLAGS is
    TRAINER_FLAGS_END + 1, which is TRAINER_FLAGS_START + MAX_TRAINERS_COUNT,
    which lives in opponents.h), so everything is collected first and the
    expressions are resolved in passes.
    """
    const_dir = os.path.join(repo, "include", "constants")
    paths = [os.path.join(const_dir, name)
             for name in sorted(os.listdir(const_dir)) if name.endswith(".h")]
    paths.append(os.path.join(repo, "include", "global.h"))

    values, exprs = {}, []
    for path in paths:
        scan_header(path, values, exprs)
    for _ in range(8):
        pending = False
        for name, expr in exprs:
            if name in values:
                continue
            v = safe_eval(expr, values)
            if v is not None:
                values[name] = v
            else:
                pending = True
        if not pending:
            break
    return values


class Constants:
    def __init__(self, repo):
        every = collect_constants(repo)
        self.all = every
        self.flags = {k: v for k, v in every.items() if k.startswith("FLAG_")}
        self.vars = {k: v for k, v in every.items() if k.startswith("VAR_")}
        self.behaviours = {k: v for k, v in every.items() if k.startswith("MB_")}
        self.trainers = {k: v for k, v in every.items() if k.startswith("TRAINER_")}
        self.fieldmap = every
        self.objects = {k: v for k, v in every.items()
                        if k.startswith("OBJ_EVENT_GFX_")}

    def const(self, name, table="flags"):
        if not name or name in ("0", ""):
            return None
        if name.lstrip("-").isdigit():
            return int(name)
        return getattr(self, table).get(name)


def parse_number(value):
    """map.json values are strings like '0x40' / '17' / 'FLAG_X'."""
    if isinstance(value, int):
        return value
    if value is None:
        return None
    v = value.strip()
    if not v:
        return None
    try:
        return int(v, 0)
    except ValueError:
        return None


# --------------------------------------------------------------------------
# tilesets
# --------------------------------------------------------------------------
def tileset_attributes_path(repo, tileset_name):
    """gTileset_General -> data/tilesets/primary/general/metatile_attributes.bin"""
    short = tileset_name.replace("gTileset_", "").lower()
    for kind in ("primary", "secondary"):
        path = os.path.join(repo, "data/tilesets", kind, short,
                            "metatile_attributes.bin")
        if os.path.exists(path):
            return path
    return None


def load_behaviour_table(repo, tileset_name, cache):
    if tileset_name in cache:
        return cache[tileset_name]
    path = tileset_attributes_path(repo, tileset_name)
    table = []
    if path:
        data = open(path, "rb").read()
        table = list(struct.unpack("<%dH" % (len(data) // 2), data))
    cache[tileset_name] = table
    return table


def behaviour_name(consts, behaviour_id):
    for name, value in consts.behaviours.items():
        if value == behaviour_id:
            return name
    return None


def behaviour_kind(consts, behaviour_id):
    """Classify a metatile behaviour into a small string the bot understands."""
    name = behaviour_name(consts, behaviour_id)
    if not name:
        return None
    if name in LEDGE_BEHAVIOURS:
        return "ledge:" + LEDGE_BEHAVIOURS[name]
    if name in AUTO_WARP_BEHAVIOURS:
        return "door"
    if name in TERRAIN_BEHAVIOURS:
        return TERRAIN_BEHAVIOURS[name]
    return None


# --------------------------------------------------------------------------
# main build
# --------------------------------------------------------------------------
def build(repo, quiet=False):
    def log(*a):
        if not quiet:
            print(*a)

    consts = Constants(repo)

    layouts_doc = json.load(open(os.path.join(repo, "data/layouts/layouts.json")))
    layouts = {l["id"]: l for l in layouts_doc["layouts"]}

    groups_doc = json.load(open(os.path.join(repo, "data/maps/map_groups.json")))
    group_order = groups_doc["group_order"]

    # (group, num) -> map id, and map id -> (group, num).
    # map_groups.json lists *directory* names; map.json's "id" is the MAP_* id
    # used by warps and connections, so translate as we go.
    map_index = {}
    map_ids = []

    attr_cache = {}
    world = {}
    landing = {}          # (map_id, warp_id) -> (x, y)
    skipped = []
    total_tiles = 0

    def map_path(map_id, *parts):
        return os.path.join(repo, "data/maps", map_id, *parts)

    # First pass: read map.json files
    raw = {}
    for group_id, group_name in enumerate(group_order):
        for num, dirname in enumerate(groups_doc[group_name]):
            p = map_path(dirname, "map.json")
            if not os.path.exists(p):
                skipped.append(dirname)
                continue
            doc = json.load(open(p))
            map_id = doc.get("id") or dirname
            raw[map_id] = doc
            map_index[map_id] = (group_id, num)
            # where does warp N of this map put you?  (its own coordinates)
            landing[map_id] = [(w["x"], w["y"]) for w in doc.get("warp_events", [])]

    # Second pass: build geometry
    for map_id, doc in raw.items():
        layout_id = doc.get("layout")
        layout = layouts.get(layout_id)
        if not layout:
            skipped.append(map_id)
            continue
        w, h = layout["width"], layout["height"]
        block_path = os.path.join(repo, layout["blockdata_filepath"])
        if not os.path.exists(block_path):
            skipped.append(map_id)
            continue
        blocks = struct.unpack("<%dH" % (w * h), open(block_path, "rb").read()[: w * h * 2])
        total_tiles += w * h

        prim = load_behaviour_table(repo, layout["primary_tileset"], attr_cache)
        sec = load_behaviour_table(repo, layout["secondary_tileset"], attr_cache)

        walls = ["."] * (w * h)
        special = []      # {x, y, kind}
        for y in range(h):
            for x in range(w):
                i = y * w + x
                block = blocks[i]
                metatile = block & METATILE_MASK
                collision = (block >> COLLISION_SHIFT) & COLLISION_MASK
                attrs = prim[metatile] if metatile < 512 else (
                    sec[metatile - 512] if metatile - 512 < len(sec) else 0)
                behaviour = attrs & 0xFF if attrs else 0
                kind = behaviour_kind(consts, behaviour) if behaviour else None

                if kind and kind.startswith("ledge:"):
                    # Ledges are one-way: blocked for every direction but one.
                    walls[i] = "#"
                    special.append({"x": x, "y": y, "kind": kind})
                elif collision != 0:
                    walls[i] = "#"
                if kind and kind != "grass" and not kind.startswith("ledge:"):
                    special.append({"x": x, "y": y, "kind": kind})

        warps = []
        for warp in doc.get("warp_events", []):
            try:
                wid = int(str(warp["dest_warp_id"]), 0)
            except (TypeError, ValueError):
                wid = None
            dest = warp["dest_map"]
            # landing coords come from the destination map's warp list
            dest_warps = landing.get(dest) or []
            if wid is not None and 0 <= wid < len(dest_warps):
                tx, ty = dest_warps[wid]
            else:
                tx, ty = (None, None)
            warps.append({
                "x": warp["x"], "y": warp["y"],
                "to": dest, "tw": wid,
                "tx": tx, "ty": ty,
            })

        conns = []
        for conn in doc.get("connections") or []:
            conns.append({
                "dir": conn["direction"],
                "to": conn["map"],
                "off": conn.get("offset", 0),
            })

        triggers = []
        for ce in doc.get("coord_events", []):
            var = ce.get("var")
            triggers.append({
                "x": ce["x"], "y": ce["y"],
                "var": consts.const(var, "vars"),
                "varName": var,
                "val": parse_number(ce.get("var_value")),
                "type": ce.get("type"),
                "script": ce.get("script"),
            })

        objects = []
        for obj in doc.get("object_events", []):
            ttype = obj.get("trainer_type")
            is_trainer = bool(ttype) and ttype != "TRAINER_TYPE_NONE"
            objects.append({
                "x": obj["x"], "y": obj["y"],
                "script": obj.get("script"),
                "flag": consts.const(obj.get("flag"), "flags"),
                "trainer": is_trainer,
                "gfx": obj.get("graphics_id"),
            })

        bg = []
        for b in doc.get("bg_events", []):
            bg.append({"x": b["x"], "y": b["y"], "script": b.get("script"),
                       "type": b.get("type")})

        group, num = map_index[map_id]
        entry = {
            "id": map_id,
            "name": doc.get("name"),
            "group": group,
            "num": num,
            "w": w, "h": h,
            "walls": "".join(walls),
            "warps": warps,
            "conns": conns,
            "triggers": triggers,
            "objects": objects,
            "bg": bg,
            "special": special,
        }
        world[map_id] = entry

    log("maps compiled: %d (skipped %d)" % (len(world), len(skipped)))
    log("total tiles: %d" % total_tiles)

    # ------------------------------------------------------------------
    # connectivity sanity check: flood fill the map graph
    # ------------------------------------------------------------------
    def neighbours(map_id):
        entry = world.get(map_id)
        if not entry:
            return []
        out = []
        for conn in entry["conns"]:
            if conn["to"] in world:
                out.append(conn["to"])
        for warp in entry["warps"]:
            if warp["to"] in world:
                out.append(warp["to"])
        return out

    def reachable(start):
        seen = {start}
        stack = [start]
        while stack:
            cur = stack.pop()
            for nxt in neighbours(cur):
                if nxt not in seen:
                    seen.add(nxt)
                    stack.append(nxt)
        return seen

    start_map = "MAP_LITTLEROOT_TOWN"
    seen = reachable(start_map) if start_map in world else set()
    missing = sorted(set(world) - seen)
    log("reachable from %s: %d/%d" % (start_map, len(seen), len(world)))
    if missing:
        log("  NOTE: %d maps are not reachable by walking (they need scripted "
            "warps such as boats, trucks or elevators):" % len(missing))
        log("  " + ", ".join(missing[:12]) + (" ..." if len(missing) > 12 else ""))

    # every warp should land somewhere real so routes can be planned
    dangling = []
    for map_id, entry in world.items():
        for warp in entry["warps"]:
            if warp["to"] == "MAP_DYNAMIC":
                continue
            if warp["to"] not in world:
                dangling.append((map_id, warp["x"], warp["y"], warp["to"]))
    if dangling:
        log("  NOTE: %d warps point outside the compiled world "
            "(e.g. MAP_DYNAMIC / dungeon shortcuts)" % len(dangling))

    return world, map_index, skipped, consts


# --------------------------------------------------------------------------
# Lua serialisation
# --------------------------------------------------------------------------
def lua_string(s):
    if s is None:
        return "nil"
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def lua_number(n):
    if n is None:
        return "nil"
    return str(n)


def emit_lua(world, consts, out_path):
    parts = []
    parts.append("-- GENERATED FILE - do not edit.  Rebuild with:")
    parts.append("--   python3 tools/spectator/tools/build_world.py")
    parts.append("--")
    parts.append("-- %d maps, compiled from this repository's map data."
                 % len(world))
    parts.append("local M = {")
    parts.append("  maps = {")

    for map_id in sorted(world):
        e = world[map_id]
        parts.append("    [%s] = {" % lua_string(map_id))
        parts.append("      id=%s, name=%s, group=%d, num=%d, w=%d, h=%d,"
                     % (lua_string(map_id), lua_string(e["name"]),
                        e["group"], e["num"], e["w"], e["h"]))
        parts.append("      walls=%s," % lua_string(e["walls"]))

        if e["warps"]:
            rows = []
            for wp in e["warps"]:
                rows.append("{x=%d,y=%d,to=%s,tw=%s,tx=%s,ty=%s}" % (
                    wp["x"], wp["y"], lua_string(wp["to"]),
                    lua_number(wp["tw"]), lua_number(wp["tx"]),
                    lua_number(wp["ty"])))
            parts.append("      warps={%s}," % ",".join(rows))

        if e["conns"]:
            rows = []
            for c in e["conns"]:
                rows.append("{dir=%s,to=%s,off=%d}" % (
                    lua_string(c["dir"]), lua_string(c["to"]), c["off"]))
            parts.append("      conns={%s}," % ",".join(rows))

        if e["triggers"]:
            rows = []
            for t in e["triggers"]:
                rows.append("{x=%d,y=%d,var=%s,val=%s,script=%s}" % (
                    t["x"], t["y"], lua_number(t["var"]), lua_number(t["val"]),
                    lua_string(t["script"])))
            parts.append("      triggers={%s}," % ",".join(rows))

        if e["objects"]:
            rows = []
            for o in e["objects"]:
                rows.append("{x=%d,y=%d,script=%s,flag=%s,trainer=%s}" % (
                    o["x"], o["y"], lua_string(o["script"]),
                    lua_number(o["flag"]), "true" if o["trainer"] else "false"))
            parts.append("      objects={%s}," % ",".join(rows))

        if e["special"]:
            rows = []
            for s in e["special"]:
                rows.append("{x=%d,y=%d,kind=%s}" % (
                    s["x"], s["y"], lua_string(s["kind"])))
            parts.append("      special={%s}," % ",".join(rows))

        parts.append("    },")

    parts.append("  },")

    # Story constants: routes name flags/vars symbolically (FLAG_..., VAR_...)
    # and the runner needs their numeric ids, which only exist in the headers.
    def emit_named_table(name, mapping, keep_prefix):
        rows = []
        for key in sorted(mapping):
            if not key.startswith(keep_prefix):
                continue
            rows.append("[%s]=%d" % (lua_string(key), mapping[key]))
        parts.append("  %s = {%s}," % (name, ",".join(rows)))

    emit_named_table("flags", consts.flags, "FLAG_")
    emit_named_table("vars", consts.vars, "VAR_")
    parts.append("}")
    parts.append("""
-- index helpers -----------------------------------------------------------
M.byGroupNum = {}
M.byName = {}
for id, m in pairs(M.maps) do
  M.byGroupNum[m.group * 1000 + m.num] = id
  if m.name then M.byName[m.name] = id end
end

function M.get(id) return M.maps[id] end

function M.byPos(group, num)
  return M.byGroupNum[group * 1000 + num]
end

-- tile helpers ------------------------------------------------------------
-- These run inside a per-frame loop, so lookups are memoised per map instead
-- of scanning the tables every time.
local wallGrid, kindIndex, warpIndex, objectIndex, scriptIndex = {}, {}, {}, {}, {}

local function buildIndexes(map)
  local id = map.id
  if kindIndex[id] then return end
  local kinds, warps, objects, scripts = {}, {}, {}, {}
  for _, s in ipairs(map.special or {}) do
    kinds[s.y * map.w + s.x] = s.kind
  end
  for _, wp in ipairs(map.warps or {}) do
    warps[wp.y * map.w + wp.x] = wp
  end
  for _, o in ipairs(map.objects or {}) do
    objects[o.y * map.w + o.x] = o
    if o.script then scripts[o.script] = o end
  end
  kindIndex[id], warpIndex[id] = kinds, warps
  objectIndex[id], scriptIndex[id] = objects, scripts
end

local WALL_BYTE = 35  -- '#'

function M.isWall(map, x, y)
  if not map then return true end
  if x < 0 or y < 0 or x >= map.w or y >= map.h then return true end
  return string.byte(map.walls, y * map.w + x + 1) == WALL_BYTE
end

function M.tileKind(map, x, y)
  if not map then return nil end
  buildIndexes(map)
  return kindIndex[map.id][y * map.w + x]
end

function M.warpAt(map, x, y)
  if not map then return nil end
  buildIndexes(map)
  return warpIndex[map.id][y * map.w + x]
end

function M.objectAt(map, x, y)
  if not map then return nil end
  buildIndexes(map)
  return objectIndex[map.id][y * map.w + x]
end

function M.objectByScript(map, script)
  if not map then return nil end
  buildIndexes(map)
  return scriptIndex[map.id][script]
end

return M
""")

    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    with open(out_path, "w") as f:
        f.write("\n".join(parts))
    return out_path


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("-o", "--out",
                    default=os.path.join(HERE, "data", "world.lua"))
    ap.add_argument("-q", "--quiet", action="store_true")
    args = ap.parse_args()

    world, _, _, consts = build(REPO, args.quiet)
    path = emit_lua(world, consts, args.out)
    size = os.path.getsize(path)
    if not args.quiet:
        print("wrote %s (%.1f KiB)" % (path, size / 1024.0))


if __name__ == "__main__":
    main()
