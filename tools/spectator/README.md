# Emerald autoplay — a bot that plays the game in mGBA while you watch

A Lua script for the [mGBA](https://mgba.io) emulator that plays this
repository's Pokémon Emerald ROM on its own: it reads the game's own memory to
know where it is and what is happening, walks across the world map, opens
doors, jumps ledges, fights battles and follows a scripted story route.

Everything it knows about the game is generated from **this repository** — map
geometry from `data/maps` + `data/layouts`, story flags and variables from
`include/constants`, and RAM addresses from the `.map` file `make` produces.
Nothing is hardcoded to a specific vanilla build, so it follows your tree,
including its modifications (this tree, for example, hands out Johto starters in
Birch's lab).

```
tools/spectator/
├── autoplay.lua          entry point: load this one in mGBA
├── route.lua             the playthrough — the file you edit to go further
├── setup.sh              regenerate the generated data
├── lib/
│   ├── util.lua          logging
│   ├── mem.lua           safe memory reads
│   ├── sym.lua           symbol lookup (name → address, address → name)
│   ├── state.lua         decodes position, party, flags, battles, screen mode
│   ├── keys.lua          button presses
│   ├── nav.lua           pathfinding + the world graph
│   ├── walk.lua          steps tile by tile, verified against the position
│   ├── battle.lua        what to do in a battle
│   └── runner.lua        executes route.lua
├── data/world.lua        GENERATED (map data, ~1.4 MB)
├── data/symbols.lua      GENERATED (from pokeemerald.map)
├── tools/build_world.py  map data → data/world.lua
├── tools/build_symbols.py  pokeemerald.map → data/symbols.lua
└── tests/                a fake GBA core + 7 test suites, no ROM needed
```

## Quick start

1. **Build the ROM.** It has to be built with debug symbols so a `.map` file
   exists (`make` does this by default; keep `pokeemerald.map`).

2. **Generate the data files.**

   ```sh
   ./tools/spectator/setup.sh
   ```

3. **Start a fresh save.** Delete or rename `pokeemerald.sav` next to the ROM
   if you want to watch from the very beginning (otherwise the bot presses A
   through the main menu and continues whatever save is there).

4. **Open the ROM in mGBA** (0.10 or newer) and load the script:
   `Tools → Scripting… → File → Load script… → tools/spectator/autoplay.lua`

The Scripting window becomes a live log:

```
[autoplay] Pokemon Emerald autoplay
[autoplay] world: 518 maps loaded, symbols: loaded
[autoplay] overworld reached - starting the route
[autoplay] [1/24] wait map MAP_LITTLEROOT_TOWN
[autoplay] [5/24] travel MAP_LITTLEROOT_TOWN_BRENDANS_HOUSE_1F
[autoplay] overworld | MAP_LITTLEROOT_TOWN@12,12 | lead Lv5 20/20 | task 5/24 travel ...
```

Press `Tab` in mGBA to fast-forward and watch it play the boring parts at 4×
speed. Stop the script in the Scripting window at any time to take control.

## Honest status

| Part | State |
| --- | --- |
| Reading game state (position, map, party, flags, vars, battles, screen) | done, tested |
| Walking: pathfinding, doors, ladders, ledges, map connections | done, tested |
| Cross-map travel (shortest route over 518 maps) | done, tested |
| Battles | fights with the first move (A-mash); survives interruptions, wild encounters and trainers |
| Route coverage | **the opening**: intro, Littleroot, Route 101 rescue + starter, Route 103 rival, Pokédex, Petalburg, Route 104, Petalburg Woods, Rustboro |
| Rest of the game (gyms, HMs, caves, Elite Four) | **not written yet** — the engine can do it, the route needs the lines |

So this is a working, tested autoplayer with a route that covers the first
stretch of the game, not a finished any%-speedrun route for all eight gyms.
The interesting engineering — cross-map navigation, doors, ledges, story
triggers, interruption recovery — is done and covered by tests, so extending
the route is mostly data entry, described below.

## Editing the route

`route.lua` is a list of instructions, executed in order. Each has a timeout
(90 s of game time by default) and is retried before being skipped, so a stale
line cannot wedge the run.

```lua
{ travel    = "MAP_ROUTE101" }      -- walk there; the route is planned for you
{ goto_tile = {x = 10, y = 8} }     -- one tile on the current map
{ talk      = "Route103_EventScript_Rival" }  -- walk up to that NPC and press A
{ interact  = {x = 7, y = 14} }     -- face a tile (a bag, a sign, a clock) and press A
{ press     = "A", times = 3 }      -- mash a button
{ wait_flag = "FLAG_SYS_POKEMON_GET" }
{ wait_var  = "VAR_ROUTE101_STATE", min = 3 }
{ wait_party = 1 }
{ wait_map  = "MAP_LITTLEROOT_TOWN" }
{ wait_frames = 60 }
{ save      = 1 }                   -- savestate checkpoint (slot 0-9)
{ log       = "starting the Rustboro gym" }
{ call = function(ctx) return "done" end }
```

Practical tips:

* `travel` accepts the map id (`MAP_RUSTBORO_CITY`) or a friendly name
  (`RustboroCity`).
* To find a script name, look in `data/maps/<Map>/map.json` (`"script"` fields)
  or `data/maps/<Map>/scripts.inc`.
* To write a leg of the story, find the flag or variable the script sets
  (`setflag …` / `setvar …` in `scripts.inc`) and use it with `wait_flag` /
  `wait_var`; that is a much more reliable anchor than sleeping for N frames.
* `tools/spectator/tests/test_route.lua` lints the route: every map, script,
  flag and variable you mention must exist in the tree, so typos fail loudly.

## How it works

1. **`build_world.py`** compiles 518 maps into one Lua table: a per-tile
   walkability grid from each layout's `map.bin` (collision bits) plus metatile
   behaviours from the tilesets, so ledges, doors, arrow warps, ladders,
   tall grass and stairs are all known. It also records every warp and where it
   lands, every map connection with its offset, every NPC, every story trigger,
   and the numeric value of every `FLAG_*` / `VAR_*` in the headers.
2. **`build_symbols.py`** reads `pokeemerald.map` and keeps the RAM symbols
   (`gSaveBlock1Ptr`, `gMain`, `gBattleMons`, …) plus the `CB1_*`/`CB2_*`
   function addresses used to identify the current screen.
3. At runtime **`state.lua`** reads `SaveBlock1` for the position, map, party and
   flags/vars, `gMain.inBattle` and `gMain.callback2` to tell whether the game is
   in the overworld, in a battle, on the title screen or inside a menu.
4. **`nav.lua`** runs a BFS over tiles (with one-way ledge edges) for movement
   inside a map, and a BFS over the map graph for travel between maps. Only the
   next *waypoint* is committed to; the plan is re-checked against the real
   position after every hop, so random encounters, NPCs and scripted warps
   cannot desynchronise it.
5. **`walk.lua`** holds a direction and watches the player's tile coordinates
   change, rather than sleeping for a fixed number of frames.
6. **`runner.lua`** drives the instructions, and **`battle.lua`** takes over
   whenever `gMain.inBattle` is set.

Some details that took reading the engine source to get right:

* Doors have their collision bits set, so you cannot stand on them. The bot
  walks to the tile in front and pushes into the door, which is also how the
  game triggers the warp.
* Facing direction matters for talking to NPCs and opening doors, and the
  sign of the adjacency direction is easy to get backwards.
* Map connections shift the neighbour by `offset`; measuring every offset
  connection in the tree shows the neighbour's coordinate is
  `coord - offset`, which is what the planner uses to pick a border tile that
  actually leads somewhere walkable.
* Arriving somewhere leaves you standing on the warp tile, so leaving again
  needs one step off the pad first.

## Tests

No ROM or emulator needed — `tests/mock.lua` is a small fake GBA core (memory,
keys, callbacks) with a simplified world simulation that walks tile by tile,
jumps ledges, opens doors, follows connections and can start wild battles.

```sh
pip install lupa
python3 tools/spectator/tests/run_tests.py
```

```
test_nav     pathfinding, ledges, map graph, unreachable maps, NPC adjacency
test_state   SaveBlock1/party/flags/vars/battle decoding, screen detection
test_walk    stepping, key holding, blocked detection, ledge jumps
test_runner  doors in and out, wild battles mid-route, Littleroot→Rustboro
             in one run, waits, graceful failure
test_route   lints route.lua against the compiled world
test_autoplay  boots the real entry point and plays into the overworld
test_symbols   linker-map parsing and symbol resolution
```

## Troubleshooting

**"data/symbols.lua is missing"** — run `./tools/spectator/setup.sh` after
building the ROM. Without a linker map the bot cannot read game state and will
only press buttons.

**"cannot open …/lib/util.lua"** — load `tools/spectator/autoplay.lua` itself so
the relative paths resolve, not a copy of it somewhere else.

**It stands in front of a door and gives up** — that map's door tile is not
classified as a door. Check `data/world.lua` for that map's `special` list, or
send it a `{ goto_tile = ... }` followed by `{ press = "A" }`.

**It walks into the first town and stops** — the route ran out of instructions
(this is expected past Rustboro); add more lines to `route.lua`.

**Wrong house / wrong rival** — the intro picks the default (male) character, so
the route uses Brendan's house. For a female save, swap
`LittlerootTown_BrendansHouse_1F/_2F` for `LittlerootTown_MaysHouse_1F/_2F`.

**Nothing happens at all** — check the Scripting window for the banner. If it
says the script failed to load, the path is wrong. mGBA 0.10+ is required.

## Notes and limits

* Only the overworld, battles and menus are automated. Name entry, the Pokédex
  menus and the options screen are handled by pressing A, which accepts the
  defaults.
* The battle policy is deliberately simple (fight, first move). `battle.lua`
  has a `hooks.chooseAction` slot for something smarter — switching on low HP,
  using a potion, picking a super-effective move — if you want to extend it.
* mGBA cannot run scripts headless, so the emulator window is the show; the
  Scripting pane is the commentary.
* Nothing here writes to the ROM. It only presses buttons and (optionally)
  savestates, exactly like a very patient player.
