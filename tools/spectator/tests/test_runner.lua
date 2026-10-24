-- tests/test_runner.lua - end-to-end route execution against the mock core
local H = dofile(SPEC_DIR .. "/tests/harness.lua")

local CFG = {
  logLevel = "warn",
  stuckFrames = 40,
  warpWaitFrames = 180,
  taskTimeoutFrames = 60 * 90,
  maxRetries = 2,
  autoAdvance = true,
  onFailure = "skip",
}

local function newRun(opts)
  local mock = H.mock(opts)
  mock.mode = "overworld"
  mock:step()
  local ctx = H.context(mock, CFG)
  return mock, ctx
end

local function runRoute(route, opts, maxFrames)
  local mock, ctx = newRun(opts)
  ctx.runner.load(route)
  local ok = H.pump(ctx, mock, maxFrames or 40000)
  return mock, ctx, ok
end

-- 1. walk to a neighbouring map through a connection ----------------------
do
  local mock, ctx, ok = runRoute({ { travel = "MAP_ROUTE101" } },
                                 { map = "MAP_LITTLEROOT_TOWN", x = 12, y = 12 })
  H.check(mock.player.map == "MAP_ROUTE101",
          "walked north out of Littleroot onto Route 101")
  H.check(ok, "travel task completed")
  local st = ctx.runner.status()
  H.check(st.finished and not st.failure, "run finished without failure")
end

-- 2. enter a building through its door warp ------------------------------
do
  local mock = runRoute({ { travel = "MAP_LITTLEROOT_TOWN_PROFESSOR_BIRCHS_LAB" } },
                        { map = "MAP_LITTLEROOT_TOWN", x = 12, y = 12 })
  H.check(mock.player.map == "MAP_LITTLEROOT_TOWN_PROFESSOR_BIRCHS_LAB",
          "walked into Professor Birch's lab through the door")
end

-- 3. and back out again ---------------------------------------------------
do
  local mock = runRoute({ { travel = "MAP_LITTLEROOT_TOWN" } },
                        { map = "MAP_LITTLEROOT_TOWN_PROFESSOR_BIRCHS_LAB",
                          x = 7, y = 12 })
  H.check(mock.player.map == "MAP_LITTLEROOT_TOWN",
          "took the lab door back into town")
end

-- 4. keep playing through wild battles ------------------------------------
do
  local mock, ctx, ok = runRoute({ { travel = "MAP_ROUTE101" } },
                                 { map = "MAP_LITTLEROOT_TOWN", x = 12, y = 12 })
  -- (battles are triggered separately below; this checks the plain path)
  H.check(mock.battlesFought == 0, "no battles were needed for a safe walk")

  local mock2 = H.mock({ map = "MAP_LITTLEROOT_TOWN", x = 12, y = 12 })
  mock2.mode = "overworld"
  mock2.encounterEvery = 3      -- force an encounter every 3 steps
  mock2:step()
  local ctx2 = H.context(mock2, CFG)
  ctx2.runner.load({ { travel = "MAP_ROUTE101" } })
  local done = H.pump(ctx2, mock2, 40000)
  H.check(mock2.battlesFought >= 2, "wild battles interrupted the walk")
  H.check(mock2.player.map == "MAP_ROUTE101",
          "the route resumed and still reached Route 101")
  H.check(done, "route finished despite the battles")
end

-- 5. a long multi-map journey -------------------------------------------
do
  local mock, ctx, ok = runRoute({ { travel = "MAP_RUSTBORO_CITY" } },
                                 { map = "MAP_LITTLEROOT_TOWN", x = 12, y = 12 },
                                 120000)
  H.check(mock.player.map == "MAP_RUSTBORO_CITY",
          "walked all the way to Rustboro City")
  H.check(ok, "long route completed")
  print(string.format("  (took %d frames / %.1f game-minutes)",
                      mock.frame, mock.frame / 3600))
end

-- 6. talking to an NPC ----------------------------------------------------
do
  local mock, ctx, ok = runRoute(
    { { travel = "MAP_LITTLEROOT_TOWN" },
      { talk = "LittlerootTown_EventScript_Boy" } },
    { map = "MAP_LITTLEROOT_TOWN", x = 12, y = 12 })
  H.check(ok, "talk route completed")
  local npc = ctx.world.objectByScript(
    ctx.world.maps.MAP_LITTLEROOT_TOWN, "LittlerootTown_EventScript_Boy")
  local dist = math.abs(mock.player.x - npc.x) + math.abs(mock.player.y - npc.y)
  H.check(dist == 1, "ended up standing next to the NPC")
  H.check(ctx.runner.status().stats.talks == 1, "talk instruction counted")
end

-- 7. waits: flags and party count ---------------------------------------
do
  local mock, ctx = newRun({ map = "MAP_LITTLEROOT_TOWN", x = 12, y = 12 })
  mock.party = {}
  mock:step()
  local flagId = ctx.constants.flags.FLAG_ADVENTURE_STARTED
  ctx.runner.load({
    { wait_flag = "FLAG_ADVENTURE_STARTED" },
    { wait_party = 1 },
  })
  local finished = H.pump(ctx, mock, 4000)
  H.check(not finished, "waits keep the run blocked while unmet")
  mock.flags[flagId] = true
  mock.party = { { level = 5, hp = 20, maxHp = 20 } }
  finished = H.pump(ctx, mock, 4000)
  H.check(finished, "waits release once the condition is met")
end

-- 8. a broken instruction is reported, not hung on ----------------------
do
  local mock, ctx = newRun({ map = "MAP_LITTLEROOT_TOWN", x = 12, y = 12 })
  ctx.runner.load({ { goto_tile = { x = 0, y = 0 } }, { wait_frames = 2 } })
  local finished = H.pump(ctx, mock, 4000)
  H.check(finished, "unreachable instruction does not hang the run")
  local found = mock:logsContain("giving up")
  H.check(found, "unreachable tile is reported in the log")
end

-- 9. an unknown map name fails loudly ------------------------------------
do
  local mock, ctx = newRun({ map = "MAP_LITTLEROOT_TOWN", x = 12, y = 12 })
  ctx.runner.load({ { travel = "MAP_NOT_A_REAL_PLACE" } })
  H.pump(ctx, mock, 200)
  local found = mock:logsContain("unknown map")
  H.check(found, "unknown travel target is reported")
end

print("test_runner: OK")
