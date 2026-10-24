-- tests/harness.lua - shared helpers for the Lua tests
local H = {}

H.SPEC_DIR = SPEC_DIR
H.world = nil

function H.check(cond, msg)
  if not cond then
    error("CHECK FAILED: " .. (msg or "?"), 2)
  end
  print("  ok - " .. (msg or "check"))
end

function H.load(rel)
  local chunk, err = loadfile(H.SPEC_DIR .. "/" .. rel)
  assert(chunk, "cannot load " .. rel .. ": " .. tostring(err))
  return chunk()
end

function H.getWorld()
  if not H.world then H.world = H.load("data/world.lua") end
  return H.world
end

function H.mock(opts)
  return H.load("tests/mock.lua").new(opts)
end

-- symbol table matching the mock core's addresses
function H.symbolsFor(mock)
  local A = mock.ADDR
  return {
    abs = {
      gSaveBlock1Ptr = A.gSaveBlock1Ptr,
      gMain = A.gMain,
      gBattleMons = A.gBattleMons,
      gBattleTypeFlags = A.gBattleTypeFlags,
    },
    -- must be sorted by address
    cb = {
      A.CB2_Overworld, "CB2_Overworld",
      A.CB2_BattleMain, "CB2_BattleMain",
      A.CB2_InitTitleScreen, "CB2_InitTitleScreen",
    },
  }
end

function H.context(mock, cfg)
  local ctx = {
    cfg = cfg or {},
    emu = mock,
    console = mock.console,
    C = mock.C,
  }
  ctx.util = H.load("lib/util.lua")(ctx)
  ctx.world = H.getWorld()
  ctx.symbols = H.symbolsFor(mock)
  ctx.constants = { flags = ctx.world.flags or {}, vars = ctx.world.vars or {} }
  ctx.mem = H.load("lib/mem.lua")(ctx)
  ctx.sym = H.load("lib/sym.lua")(ctx)
  ctx.state = H.load("lib/state.lua")(ctx)
  ctx.keys = H.load("lib/keys.lua")(ctx)
  ctx.nav = H.load("lib/nav.lua")(ctx)
  ctx.walk = H.load("lib/walk.lua")(ctx)
  ctx.battle = H.load("lib/battle.lua")(ctx)
  ctx.runner = H.load("lib/runner.lua")(ctx)
  return ctx
end

-- walk a planned path symbolically across world data to prove it is legal
function H.validatePath(mapId, from, steps)
  local world = H.getWorld()
  local map = world.maps[mapId]
  local DIRS = { up = { 0, -1 }, down = { 0, 1 }, left = { -1, 0 }, right = { 1, 0 } }
  local x, y = from.x, from.y
  for i, step in ipairs(steps) do
    local dx, dy = DIRS[step.dir][1], DIRS[step.dir][2]
    if step.jump then dx, dy = dx * 2, dy * 2 end
    x, y = x + dx, y + dy
    if x < 0 or y < 0 or x >= map.w or y >= map.h then
      return false, "step " .. i .. " leaves the map at " .. x .. "," .. y
    end
    if world.isWall(map, x, y) then
      local kind = world.tileKind(map, x, y)
      -- door/ladder tiles are marked solid in the block data but you can
      -- still step onto them (that is how you enter) - only the goal tile
      -- is allowed to be one of those
      local isWarp = world.warpAt(map, x, y) ~= nil
      local isLast = (i == #steps)
      local isLedge = kind and kind:sub(1, 6) == "ledge:"
      if isLedge or (isWarp and isLast) then
        -- fine
      else
        return false, "step " .. i .. " walks into a wall at " .. x .. "," .. y
      end
    end
  end
  return true, nil, x, y
end

-- the main loop autoplay.lua runs, factored out so tests can drive it
function H.pump(ctx, mock, maxFrames, onFrame)
  local walk, battle, runner, state = ctx.walk, ctx.battle, ctx.runner, ctx.state
  local inBattle = false
  for _ = 1, (maxFrames or 1000) do
    mock:step()
    local mode = state.mode()
    if mode == "battle" then
      if not inBattle then
        walk.cancel()
        battle.enter()
        inBattle = true
      end
      battle.tick(mock.frame)
    else
      if inBattle then
        battle.leave()
        inBattle = false
        walk.recover()
      end
      if mode == "overworld" then runner.tick(mock.frame) end
    end
    if onFrame then onFrame(mock, ctx) end
    if runner.isFinished() then return true end
  end
  return false
end

return H
