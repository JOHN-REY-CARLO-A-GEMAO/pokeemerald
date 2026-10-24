--[[
  autoplay.lua - a self-playing robot for Pokemon Emerald (pokeemerald).

  Load it in mGBA with  Tools -> Scripting... -> File -> Load script.
  It plays the game on its own: it starts the save, walks the route in
  route.lua using real map data, fights battles, and keeps the console in the
  Scripting window up to date so you can watch what it is thinking.

  Everything it knows about the game comes from two generated files:
    data/world.lua    compiled from this repo's map data (build_world.py)
    data/symbols.lua  extracted from pokeemerald.map       (build_symbols.py)

  See README.md for setup, the route format and the hard limits.
]]

local CONFIG = {
  ---------------------------------------------------------------- behaviour
  logLevel = "info",        -- "debug" | "info" | "warn" | "error"
  statusEverySeconds = 10,  -- console status line interval
  autoAdvance = true,       -- tap A through cutscene text while waiting
  onFailure = "skip",       -- "skip" the broken instruction or "abort" the run
  maxRetries = 3,
  taskTimeoutFrames = 60 * 90,
  stuckFrames = 40,         -- frames of no movement before "blocked"
  warpWaitFrames = 180,     -- frames to wait for a door/warp to fire
  saveSlots = true,         -- allow { save = n } checkpoints in the route
  startNewGame = false,     -- true = pick NEW GAME at the main menu
  routeFile = "route.lua",  -- which route to play

  ------------------------------------------------------------------- engine
  speedMode = "normal",     -- cosmetic only; use Tab in mGBA for fast-forward
}

--------------------------------------------------------------------- loader
local SCRIPT_DIR = (script and script.dir) or "."

local function loadLua(relPath)
  local path = SCRIPT_DIR .. "/" .. relPath
  local chunk, err = loadfile(path)
  if not chunk then
    error("autoplay: cannot open " .. path .. "\n  " .. tostring(err) ..
          "\n  (load the script from tools/spectator/autoplay.lua so the " ..
          "relative paths resolve)")
  end
  local ok, value = pcall(chunk)
  if not ok then
    error("autoplay: error while loading " .. path .. "\n  " .. tostring(value))
  end
  return value
end

------------------------------------------------------------------ bootstrap
local ctx = {
  cfg = CONFIG,
  emu = emu,
  console = console,
  C = C,
}

ctx.util = loadLua("lib/util.lua")(ctx)

local okWorld, world = pcall(loadLua, "data/world.lua")
if okWorld and type(world) == "table" then
  ctx.world = world
else
  error("autoplay: data/world.lua is missing or broken.\n" ..
        "  Run:  python3 tools/spectator/tools/build_world.py")
end

local okSyms, symbols = pcall(loadLua, "data/symbols.lua")
if okSyms and type(symbols) == "table" then
  ctx.symbols = symbols
else
  ctx.symbols = { abs = {}, cb = {} }
  ctx.util.error("data/symbols.lua is missing - the bot cannot read game " ..
                 "state.\n  Run:  python3 tools/spectator/tools/build_symbols.py " ..
                 "pokeemerald.map")
end

ctx.constants = {
  flags = world.flags or {},
  vars = world.vars or {},
}

ctx.mem = loadLua("lib/mem.lua")(ctx)
ctx.sym = loadLua("lib/sym.lua")(ctx)
ctx.state = loadLua("lib/state.lua")(ctx)
ctx.keys = loadLua("lib/keys.lua")(ctx)
ctx.nav = loadLua("lib/nav.lua")(ctx)
ctx.walk = loadLua("lib/walk.lua")(ctx)
ctx.battle = loadLua("lib/battle.lua")(ctx)
ctx.runner = loadLua("lib/runner.lua")(ctx)

local util, state, keys = ctx.util, ctx.state, ctx.keys
local walk, battle, runner = ctx.walk, ctx.battle, ctx.runner

------------------------------------------------------------------- helpers
local frame = 0
local inBattle = false
local lastStatus = 0
local frontendTap = 0
local started = false

local function banner()
  util.say("=========================================================")
  util.say(" Pokemon Emerald autoplay")
  util.say(string.format(" world: %d maps loaded, symbols: %s",
    (function()
      local n = 0
      for _ in pairs(world.maps) do n = n + 1 end
      return n
    end)(),
    ctx.sym.isLoaded() and "loaded" or "MISSING"))
  util.say(" watching: " .. (CONFIG.autoAdvance and "auto-advancing text" or "passive"))
  util.say(" stop the script in Tools > Scripting to take over")
  util.say("=========================================================")
end

-- Front-end screens (logos, intro, title, main menu): press buttons on a
-- slow, human-ish rhythm until the overworld takes over.
local function tickFrontend()
  frontendTap = frontendTap + 1
  if frontendTap % 45 <= 2 then
    -- every third cycle press START so the title screen opens its menu
    if math.floor(frontendTap / 45) % 3 == 2 then
      keys.hold("START")
    else
      keys.hold("A")
    end
  else
    keys.release()
  end
end

local function tickStatus()
  if frame - lastStatus < 60 * CONFIG.statusEverySeconds then return end
  lastStatus = frame
  local st = runner.status()
  local mode = state.mode()
  util.say(string.format("%s | %s | task %d/%d %s",
    mode, state.describe(), st.pc, st.total, st.task or "-"))
end

---------------------------------------------------------------------- loop
local function tick()
  frame = frame + 1

  local mode = state.mode()

  if mode == "boot" then
    keys.release()
    return
  end

  if mode == "battle" then
    if not inBattle then
      walk.cancel()
      battle.enter()
      inBattle = true
      started = true
    end
    battle.tick(frame)
    tickStatus()
    return
  end

  if inBattle then
    battle.leave()
    inBattle = false
    walk.recover()
  end

  if mode == "overworld" then
    if not started then
      started = true
      util.say("overworld reached - starting the route")
      local ok, route = pcall(loadLua, CONFIG.routeFile)
      if ok and type(route) == "table" then
        runner.load(route)
      else
        util.error("route.lua missing or broken: " .. tostring(route))
      end
    end
    runner.tick(frame)
    tickStatus()
  elseif mode == "frontend" then
    tickFrontend()
    tickStatus()
  else
    -- some menu, naming screen, trade screen, credits...
    keys.release()
    tickStatus()
  end
end

banner()
callbacks:add("frame", tick)
