--[[
  route.lua - the playthrough the bot follows.

  Each entry is one instruction; the runner (lib/runner.lua) executes them in
  order and re-plans around whatever the game throws at it (wild battles,
  NPCs stepping in the way, being warped by a cutscene).

  Instruction reference
    { travel     = "MAP_ROUTE101" }     walk to another map; the map graph is
                                        searched automatically, including doors,
                                        ladders, ledges and border crossings
    { goto_tile  = {x=10, y=8} }        walk to one tile on the current map
    { talk       = "Script_Name" }      find that NPC/sign script on the current
                                        map, walk next to it and press A
    { interact   = {x=7, y=14} }        stand next to a tile and press A
    { press      = "A", times = 3 }     mash a button
    { wait_flag  = "FLAG_X" }           wait until a story flag is set
    { wait_flag_clear = "FLAG_X" }      wait until a flag is cleared
    { wait_var   = "VAR_X", min = 2 }   wait for a story variable
    { wait_party = 1 }                  wait until n Pokémon are owned
    { wait_map   = "MAP_X" }            wait for a scripted warp
    { wait_frames = 60 }
    { save       = 1 }                  savestate checkpoint (slot 0-9)
    { log        = "text" }             write a line to the scripting console
    { call = function(ctx) ... end }    arbitrary Lua, return "done"/"working"

  Every instruction has a timeout (default 90 s of game time) and is retried
  a few times before the runner logs it and moves on, so a stale step cannot
  wedge the whole run.

  STATUS
  The engine handles the general case: overworld navigation, doors, ledges,
  border crossings, battles, text, flags/vars.  This route covers the game up
  to the first major milestone and is written against the scripts in *this*
  repository (which has Johto starters in Birch's lab, not the vanilla ones).
  Everything after Rustboro - gyms with puzzles, HMs (Cut/Surf/Strength),
  the Trick House, the Elite Four - needs more instructions added here; see
  README.md for how to extend it.
]]

return {
  ---------------------------------------------------------------- the intro
  -- The game opens inside the moving truck.  The whole intro (truck, mum,
  -- moving boxes, Birch's speech) is a cutscene: the runner keeps tapping A
  -- and waits until we are actually standing in Littleroot Town.
  { log = "waiting for the intro cutscene" },
  { wait_map = "MAP_LITTLEROOT_TOWN" },
  { wait_party = 0 }, -- no Pokémon yet: the run has really just begun

  ------------------------------------------------------- set the bedroom clock
  { log = "intro: setting the clock in the bedroom" },
  { travel = "MAP_LITTLEROOT_TOWN_BRENDANS_HOUSE_1F" },
  { travel = "MAP_LITTLEROOT_TOWN_BRENDANS_HOUSE_2F" },
  { interact = { x = 5, y = 1 } },          -- the wall clock
  { wait_frames = 40 },
  { travel = "MAP_LITTLEROOT_TOWN_BRENDANS_HOUSE_1F" },
  { wait_frames = 30 },
  { travel = "MAP_LITTLEROOT_TOWN" },

  ------------------------------------------------------ rescue Birch (Route 101)
  { log = "Route 101: rescuing Professor Birch" },
  -- Walking north out of town fires the rescue cutscene on the border tiles.
  { travel = "MAP_ROUTE101" },
  { wait_frames = 120 },
  { interact = { x = 7, y = 14 } },         -- Birch's bag -> choose a starter
  { wait_flag = "FLAG_SYS_POKEMON_GET" },   -- set by the bag script
  { wait_party = 1 },
  { wait_frames = 120 },                    -- the Zigzagoon fight resolves here

  ------------------------------------------------------------- back to town
  { log = "returning to Littleroot" },
  { travel = "MAP_LITTLEROOT_TOWN" },

  ------------------------------------------------------- rival on Route 103
  { log = "Route 103: first rival battle" },
  { travel = "MAP_OLDALE_TOWN" },
  { travel = "MAP_ROUTE103" },
  { talk = "Route103_EventScript_Rival" },
  { wait_frames = 90 },

  ------------------------------------------------------------ get the Pokédex
  { log = "getting the Pokédex from Birch" },
  { travel = "MAP_LITTLEROOT_TOWN" },
  { travel = "MAP_LITTLEROOT_TOWN_PROFESSOR_BIRCHS_LAB" },
  { talk = "LittlerootTown_ProfessorBirchsLab_EventScript_Birch" },
  { wait_flag = "FLAG_SYS_POKEDEX_GET" },
  { save = 1 },

  --------------------------------------------------- west towards Petalburg
  { log = "heading west to Petalburg City" },
  { travel = "MAP_LITTLEROOT_TOWN" },
  { travel = "MAP_OLDALE_TOWN" },
  { travel = "MAP_ROUTE102" },
  { travel = "MAP_PETALBURG_CITY" },
  { wait_frames = 120 },                    -- Wally tutorial cutscene

  ------------------------------------------- through the woods to Rustboro
  { log = "Route 104 and Petalburg Woods" },
  { travel = "MAP_ROUTE104" },
  { travel = "MAP_PETALBURG_WOODS" },
  { wait_frames = 120 },                    -- Team Aqua/Magma encounter
  { travel = "MAP_ROUTE104" },
  { travel = "MAP_RUSTBORO_CITY" },
  { save = 2 },

  { log = "reached Rustboro City - extend route.lua from here" },

  ---------------------------------------------------------------------------
  -- Where to take it next (add instructions above this line):
  --
  --   Rustboro Gym (Roxanne):
  --     { travel = "MAP_RUSTBORO_CITY_GYM" }
  --     walk the gym floor, beat the two trainers, then the leader
  --     { wait_flag = "FLAG_BADGE01_GET" }
  --
  --   Then Route 116 -> Rusturf Tunnel -> Dewford (boat from Mr. Briney),
  --   Brawly, Slateport, Mauville, and so on.  Each leg is just more
  --   { travel = ... } / { talk = ... } / { wait_flag = ... } lines.
  ---------------------------------------------------------------------------
}
