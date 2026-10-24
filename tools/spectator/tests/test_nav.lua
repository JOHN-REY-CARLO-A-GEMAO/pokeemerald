-- tests/test_nav.lua - pathfinding and world-graph tests against real map data
local H = dofile(SPEC_DIR .. "/tests/harness.lua")
local world = H.getWorld()
local ctx = { cfg = {}, console = { log = print, warn = print, error = print },
              emu = {}, C = {}, world = world }
ctx.util = H.load("lib/util.lua")(ctx)
local nav = H.load("lib/nav.lua")(ctx)

-- name resolution ---------------------------------------------------------
H.check(nav.resolveMapId("MAP_LITTLEROOT_TOWN") == "MAP_LITTLEROOT_TOWN",
        "resolve exact map id")
H.check(nav.resolveMapId("LittlerootTown") == "MAP_LITTLEROOT_TOWN",
        "resolve friendly name")
H.check(nav.resolveMapId("RustboroCity") == "MAP_RUSTBORO_CITY",
        "resolve CamelCase to MAP_ id")

-- single-map pathfinding --------------------------------------------------
local town = world.maps.MAP_LITTLEROOT_TOWN
H.check(town ~= nil, "Littleroot Town is compiled")

-- the door tile is solid, so a plain plan refuses it and the runner instead
-- walks to the tile in front of the door and bumps into it
H.check(nav.plan(town, { x = 12, y = 12 }, { x = 7, y = 16 }) == nil,
        "a solid door tile is not a walkable goal")
local doorFront = nav.planAdjacent(town, { x = 12, y = 12 }, { x = 7, y = 16 })
H.check(doorFront ~= nil, "found a tile in front of the lab door")
local steps = doorFront.steps
H.check(steps ~= nil and #steps > 0, "found a path to the tile in front of the lab door")
local ok, why, ex, ey = H.validatePath("MAP_LITTLEROOT_TOWN",
                                       { x = 12, y = 12 }, steps)
H.check(ok, "path is walkable (" .. tostring(why) .. ")")
H.check(math.abs(ex - 7) + math.abs(ey - 16) == 1,
        "path ends next to the door")

-- walls are not walkable --------------------------------------------------
H.check(not nav.standable(town, 0, 0, false), "border tree tile is solid")
H.check(nav.standable(town, 12, 12, false), "open ground is walkable")

-- path avoids warp tiles it is not aiming for -----------------------------
local door = world.warpAt(town, 7, 16)
H.check(door ~= nil and door.to == "MAP_LITTLEROOT_TOWN_PROFESSOR_BIRCHS_LAB",
        "lab door warp is compiled with its destination")
H.check(not nav.standable(town, 7, 16, false), "door tile is avoided by default")
H.check(nav.standable(town, 7, 16, true), "door tile is usable when targeted")

-- map graph ---------------------------------------------------------------
local routeTo101 = nav.mapRoute("MAP_LITTLEROOT_TOWN", "MAP_ROUTE101")
H.check(routeTo101 ~= nil and #routeTo101 == 1, "Route 101 is one hop away")
H.check(routeTo101[1].kind == "conn" and routeTo101[1].dir == "up",
        "the hop is the northern connection")

local borders = nav.borderTiles(town, "up", { x = 12, y = 12 })
H.check(#borders >= 1, "northern border has crossing tiles")
H.check(borders[1].y == 0, "border tiles sit on the top row")

local petalburg = nav.mapRoute("MAP_LITTLEROOT_TOWN", "MAP_PETALBURG_CITY")
H.check(petalburg ~= nil and #petalburg >= 3, "Petalburg is several hops away")
local last = petalburg[#petalburg]
H.check(last.to == "MAP_PETALBURG_CITY", "route ends at Petalburg")

local rustboro = nav.mapRoute("MAP_LITTLEROOT_TOWN", "MAP_RUSTBORO_CITY")
H.check(rustboro ~= nil and #rustboro >= 5, "Rustboro is reachable on foot")

local nowhere = nav.mapRoute("MAP_LITTLEROOT_TOWN", "MAP_SOOTOPOLIS_CITY")
H.check(nowhere == nil, "Sootopolis is correctly reported unreachable on foot")

-- blocked edges are excluded from the search ------------------------------
local blocked = { ["conn:MAP_ROUTE101:up"] = true }
local alt = nav.mapRoute("MAP_LITTLEROOT_TOWN", "MAP_ROUTE101", blocked)
H.check(alt == nil or alt[1].kind ~= "conn" or alt[1].dir ~= "up",
        "blocked connection is not reused")

-- talking targets ---------------------------------------------------------
local obj = world.objectByScript(town, "LittlerootTown_EventScript_Boy")
H.check(obj ~= nil, "found an NPC by script name")
local adj = nav.planAdjacent(town, { x = 12, y = 12 }, obj)
H.check(adj ~= nil and adj.steps ~= nil, "found a tile to talk from")
H.check(math.abs(adj.x - obj.x) + math.abs(adj.y - obj.y) == 1,
        "talking tile is adjacent to the NPC")

print("test_nav: OK")
