-- runner.lua - executes a route (see route.lua).
--
-- A route is a list of instructions.  Each one becomes a small "task" closure
-- that is ticked once per overworld frame until it reports done/failed, e.g.
--
--   { travel = "MAP_OLDALE_TOWN" }         walk there (map graph + pathfinding)
--   { goto_tile = {x = 10, y = 8} }        walk to one tile
--   { talk = "Script_Name" }               walk up to an NPC and press A
--   { interact = {x = 5, y = 9} }          face a tile (sign) and press A
--   { press = "A", times = 3 }             mash a button
--   { wait_flag = "FLAG_X" }               block until a story flag is set
--   { wait_var = "VAR_X", min = 2 }        block until a story variable passes
--   { wait_party = 1 }                     block until n Pokemon are owned
--   { wait_map = "MAP_X" }                 block until a scripted warp lands
--   { wait_frames = 60 }
--   { save = 1 }                           savestate checkpoint to a slot
--   { call = function(ctx) ... end }        escape hatch
--
-- If something goes wrong the task times out, is retried, and finally
-- reported instead of hanging forever.
return function(ctx)
  local M = {}
  local state, nav, walk, keys, world, log =
    ctx.state, ctx.nav, ctx.walk, ctx.keys, ctx.world, ctx.util
  local cfg = ctx.cfg

  local route = {}
  local pc = 1
  local task = nil
  local taskName = ""
  local taskFrames = 0
  local taskRetries = 0
  local finished = false
  local failure = nil
  local frame = 0

  local blockedHops = {}     -- edge key -> frame when it may be used again
  local stats = { instructions = 0, travels = 0, talks = 0, battles = 0 }

  local TIMEOUT = cfg.taskTimeoutFrames or (60 * 90)   -- 90 s per instruction
  local MAX_RETRIES = cfg.maxRetries or 3

  local function curMap()
    local id = state.mapId()
    return id, id and world.maps[id] or nil
  end

  local function pos()
    local x, y = state.pos()
    if not x then return nil end
    return { x = x, y = y }
  end

  ---------------------------------------------------------------- tasks
  local function taskGotoTile(tx, ty, opts)
    local phase, attempts, tapFrames = "plan", 0, 0
    return function()
      local _, map = curMap()
      local p = pos()
      if not map or not p then return "working" end
      if p.x == tx and p.y == ty then
        walk.cancel()
        return "done"
      end

      if phase == "tap" then
        tapFrames = tapFrames - 1
        if tapFrames <= 0 then
          keys.release()
          phase = "plan"
        else
          keys.hold("A")
        end
        return "working"
      end

      if phase == "plan" then
        attempts = attempts + 1
        local steps = nav.plan(map, p, { x = tx, y = ty }, opts)
        if not steps then
          if attempts > 4 then
            return "failed", string.format("no path from %d,%d to %d,%d",
                                           p.x, p.y, tx, ty)
          end
          phase, tapFrames = "tap", 8
          return "working"
        end
        walk.setPath(steps, "goto")
        phase = "walk"
      end

      local r = walk.tick()
      if r == "arrived" then
        local p2 = pos()
        if p2 and p2.x == tx and p2.y == ty then return "done" end
        phase = "plan"
        if attempts > 8 then return "failed", "stopped short of target tile" end
      elseif r == "blocked" or r == "idle" then
        -- "idle" means the walk was interrupted (battle, warp): re-plan
        keys.release()
        attempts = attempts + 1
        if attempts > 8 then
          local p2 = pos()
          return "failed", string.format("blocked at %d,%d",
                                         p2 and p2.x or -1, p2 and p2.y or -1)
        end
        phase = "plan"
      end
      return "working"
    end
  end

  local function edgeBlocked(key, duration)
    blockedHops[key] = frame + (duration or 60 * 20)
  end

  local function isBlocked(key)
    local until_ = blockedHops[key]
    return until_ ~= nil and until_ > frame
  end

  local function taskTravel(targetId)
    local phase = "pick"
    local plan, seq, planIdx = nil, nil, 1
    local hop, hopFrom = nil, nil
    local triedCols = {}
    local waitFrames = 0
    local bumpDir = nil

    local function activeBlocks()
      local blocked = {}
      for k in pairs(blockedHops) do
        if isBlocked(k) then blocked[k] = true end
      end
      return blocked
    end

    -- Commit to a whole waypoint sequence once, instead of asking for the
    -- next hop every time: re-deciding per hop makes the bot ping-pong
    -- between two maps when several routes are equally short.
    local function replan(mapId)
      local hops = nav.mapRoute(mapId, targetId, activeBlocks())
      if not hops then
        blockedHops = {}
        hops = nav.mapRoute(mapId, targetId, nil)
      end
      if not hops then return false end
      plan, seq, planIdx = hops, { mapId }, 1
      for i, hop in ipairs(hops) do seq[i + 1] = hop.to end
      log.debug("plan: " .. table.concat(seq, " -> "))
      return true
    end

    -- Finish the current hop whenever the map changes, no matter which phase
    -- noticed it (a border crossing can complete while we are still walking).
    local function reconcile(mapId)
      if not hopFrom or mapId == hopFrom then return false end
      if hop and mapId == hop.to then
        planIdx = planIdx + 1
        log.debug("reached " .. mapId)
      else
        log.debug(string.format("unexpected map %s (wanted %s)", mapId,
                                tostring(hop and hop.to)))
        seq = nil
      end
      hop, hopFrom = nil, nil
      phase = "pick"
      triedCols = {}
      return true
    end

    return function()
      local mapId, map = curMap()
      if not map then return "working" end
      if mapId == targetId then
        walk.cancel()
        stats.travels = stats.travels + 1
        return "done"
      end
      if reconcile(mapId) then return "working" end
      local p = pos()
      if not p then return "working" end

      if phase == "pick" then
        if seq and seq[planIdx] ~= mapId then
          log.debug(string.format("off-plan: expected %s but in %s",
            tostring(seq[planIdx]), mapId))
        end
        if not seq or seq[planIdx] ~= mapId then
          if not replan(mapId) then
            return "failed", "no route from " .. mapId .. " to " .. targetId
          end
          triedCols = {}
        end
        hop = plan[planIdx]
        hopFrom = mapId
        if not hop then
          -- sequence says we should be there already; re-evaluate
          phase = "pick"
          seq = nil
          return "working"
        end
        log.debug(string.format("hop %s -> %s (%s)%s", mapId, hop.to, hop.kind,
          hop.kind == "conn" and (" dir=" .. hop.dir) or
          string.format(" at %d,%d", hop.x, hop.y)))

        if hop.kind == "warp" then
          if p.x == hop.x and p.y == hop.y then
            for _, dir in ipairs({ "up", "down", "left", "right" }) do
              local dx = (dir == "left" and -1) or (dir == "right" and 1) or 0
              local dy = (dir == "up" and -1) or (dir == "down" and 1) or 0
              if nav.standable(map, p.x + dx, p.y + dy, false) then
                walk.setPath({ { dir = dir } }, "step-off")
                phase = "stepOff"
                return "working"
              end
            end
          end
          if not nav.standable(map, hop.x, hop.y, false) then
            local adj = nav.planAdjacent(map, p, { x = hop.x, y = hop.y })
            if not adj then
              edgeBlocked("warp:" .. hop.to .. ":" .. hop.x .. ":" .. hop.y)
              seq = nil
              return "working"
            end
            bumpDir = adj.facing
            walk.setPath(adj.steps, "door")
            phase = "toBump"
          else
            local steps = nav.plan(map, p, { x = hop.x, y = hop.y },
                                   { allowWarp = true })
            if not steps then
              edgeBlocked("warp:" .. hop.to .. ":" .. hop.x .. ":" .. hop.y)
              seq = nil
              return "working"
            end
            walk.setPath(steps, "warp")
            phase = "toWarp"
          end
        else
          phase = "chooseCol"
        end
      end

      if phase == "chooseCol" then
        local chosen = nil
        log.debug(string.format("chooseCol %s at %d,%d in %s", hop.dir, p.x, p.y, mapId))
        for _, c in ipairs(nav.borderTiles(map, hop.dir, p)) do
          local key = c.x .. "," .. c.y
          if not triedCols[key] then
            triedCols[key] = true
            local steps = nav.plan(map, p, c)
            if steps then
              chosen = { tile = c, steps = steps }
              break
            end
          end
        end
        if not chosen then
          log.debug(string.format("no walkable border column for %s from %d,%d in %s (%d candidates)",
            hop.dir, p.x, p.y, mapId, #nav.borderTiles(map, hop.dir, p)))
          edgeBlocked("conn:" .. hop.to .. ":" .. hop.dir)
          seq = nil
          phase = "pick"
          return "working"
        end
        walk.setPath(chosen.steps, "border")
        phase = "toBorder"
      end

      if phase == "stepOff" then
        local r = walk.tick()
        if r == "arrived" or r == "blocked" or r == "idle" then
          keys.release()
          phase = "pick"
        end
        return "working"
      end

      if phase == "toBump" then
        local r = walk.tick()
        if r == "arrived" or r == "blocked" then
          phase, waitFrames = "bump", 0
        elseif r == "idle" then
          phase = "pick"
        end
        return "working"
      end

      if phase == "bump" then
        waitFrames = waitFrames + 1
        keys.hold(bumpDir)
        local newId = state.mapId()
        if newId ~= mapId then
          keys.release()
          return "working"
        end
        if waitFrames % 24 == 0 then
          keys.release()
          keys.hold("A")
        end
        if waitFrames > (cfg.warpWaitFrames or 180) then
          keys.release()
          log.warn(string.format("door at %d,%d did not open", hop.x, hop.y))
          edgeBlocked("warp:" .. hop.to .. ":" .. hop.x .. ":" .. hop.y)
          seq = nil
          phase = "pick"
        end
        return "working"
      end

      if phase == "toWarp" then
        local r = walk.tick()
        if r == "arrived" then
          keys.release()
          phase, waitFrames = "waitWarp", 0
        elseif r == "blocked" then
          keys.release()
          edgeBlocked("warp:" .. hop.to .. ":" .. hop.x .. ":" .. hop.y)
          seq = nil
          phase = "pick"
        elseif r == "idle" then
          phase = "pick"
        end
        return "working"
      end

      if phase == "waitWarp" then
        waitFrames = waitFrames + 1
        local newId = state.mapId()
        if newId ~= mapId then return "working" end
        if waitFrames > (cfg.warpWaitFrames or 180) then
          log.warn("warp at " .. hop.x .. "," .. hop.y .. " did not trigger")
          edgeBlocked("warp:" .. hop.to .. ":" .. hop.x .. ":" .. hop.y)
          seq = nil
          phase = "pick"
        end
        return "working"
      end

      if phase == "toBorder" then
        local r = walk.tick()
        if r == "arrived" then
          phase, waitFrames = "crossing", 0
        elseif r == "blocked" or r == "idle" then
          keys.release()
          phase = "chooseCol"
        end
        return "working"
      end

      if phase == "crossing" then
        waitFrames = waitFrames + 1
        keys.hold(hop.dir)
        local newId = state.mapId()
        if newId ~= mapId then
          keys.release()
          return "working"
        end
        if waitFrames > 90 then
          keys.release()
          phase = "chooseCol"
        end
        return "working"
      end

      return "working"
    end
  end

  local function taskTalk(script)
    local phase, ph, adj = "find", 0, nil
    return function()
      local mapId, map = curMap()
      if not map then return "working" end
      local obj = world.objectByScript(map, script)
      if not obj then
        return "failed", "'" .. script .. "' is not in " .. mapId
      end

      if phase == "find" then
        local p = pos()
        adj = nav.planAdjacent(map, p, obj)
        if not adj then return "failed", "cannot walk up to " .. script end
        walk.setPath(adj.steps, "talk")
        phase = "walk"
      elseif phase == "walk" then
        local r = walk.tick()
        if r == "arrived" or r == "blocked" then
          keys.release()
          phase, ph = "face", 0
        elseif r == "idle" then
          phase = "find"
        end
      elseif phase == "face" then
        ph = ph + 1
        if ph <= 4 then
          keys.hold(adj.facing)       -- turn towards the NPC/sign
        elseif ph <= 8 then
          keys.hold("A")             -- then talk
        else
          keys.release()
          phase = "settle"
          ph = 0
          stats.talks = stats.talks + 1
        end
      elseif phase == "settle" then
        ph = ph + 1
        if ph > 30 then return "done" end
      end
      return "working"
    end
  end

  local function taskInteract(tx, ty)
    local phase, ph, adj = "find", 0, nil
    return function()
      local _, map = curMap()
      if not map then return "working" end
      if phase == "find" then
        local p = pos()
        if p.x == tx and p.y == ty then return "failed", "standing on it" end
        adj = nav.planAdjacent(map, p, { x = tx, y = ty })
        if not adj then return "failed", "cannot reach tile " .. tx .. "," .. ty end
        walk.setPath(adj.steps, "interact")
        phase = "walk"
      elseif phase == "walk" then
        local r = walk.tick()
        if r == "arrived" or r == "blocked" then
          keys.release()
          phase, ph = "face", 0
        elseif r == "idle" then
          phase = "find"
        end
      elseif phase == "face" then
        ph = ph + 1
        if ph <= 4 then keys.hold(adj.facing)
        elseif ph <= 8 then keys.hold("A")
        else keys.release(); phase, ph = "settle", 0 end
      elseif phase == "settle" then
        ph = ph + 1
        if ph > 40 then return "done" end
      end
      return "working"
    end
  end

  local function taskPress(button, times, gap)
    local n, ph = 0, 0
    gap = gap or 8
    return function()
      if n >= (times or 1) then
        keys.release()
        return "done"
      end
      ph = ph + 1
      if ph <= 2 then
        keys.hold(button)
      elseif ph >= gap then
        keys.release()
        n = n + 1
        ph = 0
      else
        keys.release()
      end
      return "working"
    end
  end

  local function taskWaitFrames(n)
    local t = 0
    return function()
      t = t + 1
      if t >= n then return "done" end
      return "working"
    end
  end

  -- waits that keep tapping A so cutscene text keeps moving
  local function makeWaiter(check, label)
    local t, tapPhase = 0, 0
    return function()
      t = t + 1
      if check() then
        keys.release()
        return "done"
      end
      if cfg.autoAdvance ~= false then
        tapPhase = tapPhase + 1
        if tapPhase % 24 <= 2 then keys.hold("A") else keys.release() end
      end
      if t % 600 == 0 then log.debug("still waiting for " .. label) end
      return "working"
    end
  end

  ------------------------------------------------------------ dispatch
  local function makeTask(instr)
    if instr.travel then
      local id = nav.resolveMapId(instr.travel)
      if not id then return nil, "unknown map '" .. tostring(instr.travel) .. "'" end
      return taskTravel(id), "travel " .. id
    elseif instr.goto_tile then
      local t = instr.goto_tile
      return taskGotoTile(t.x, t.y, instr.opts), "goto " .. t.x .. "," .. t.y
    elseif instr.talk then
      return taskTalk(instr.talk), "talk " .. instr.talk
    elseif instr.interact then
      local t = instr.interact
      return taskInteract(t.x, t.y), "interact " .. t.x .. "," .. t.y
    elseif instr.press then
      return taskPress(instr.press, instr.times, instr.gap),
        "press " .. instr.press .. " x" .. tostring(instr.times or 1)
    elseif instr.wait_frames then
      return taskWaitFrames(instr.wait_frames), "wait " .. instr.wait_frames .. "f"
    elseif instr.wait_flag then
      local id = (ctx.constants.flags or {})[instr.wait_flag]
      if not id then return nil, "unknown flag '" .. instr.wait_flag .. "'" end
      return makeWaiter(function() return state.flag(id) == true end,
                        instr.wait_flag), "wait flag " .. instr.wait_flag
    elseif instr.wait_flag_clear then
      local id = (ctx.constants.flags or {})[instr.wait_flag_clear]
      if not id then return nil, "unknown flag '" .. instr.wait_flag_clear .. "'" end
      return makeWaiter(function() return state.flag(id) ~= true end,
                        instr.wait_flag_clear), "wait !" .. instr.wait_flag_clear
    elseif instr.wait_var then
      local name = instr.wait_var
      local id = (ctx.constants.vars or {})[name]
      if not id then return nil, "unknown var '" .. name .. "'" end
      local min = instr.min or 1
      local max = instr.max
      local eq = instr.eq
      return makeWaiter(function()
        local v = state.var(id)
        if eq ~= nil then return v == eq end
        if max ~= nil then return v > min and v < max end
        return v >= min
      end, name), "wait var " .. name
    elseif instr.wait_party then
      return makeWaiter(function()
        return state.partyCount() >= instr.wait_party
      end, "party>=" .. instr.wait_party), "wait party " .. instr.wait_party
    elseif instr.wait_map then
      local id = nav.resolveMapId(instr.wait_map) or instr.wait_map
      return makeWaiter(function()
        local cur = state.mapId()
        return cur ~= nil and cur == id
      end, instr.wait_map), "wait map " .. id
    elseif instr.save then
      return function()
        ctx.emu:saveStateSlot(instr.save)
        log.info("checkpoint saved to slot " .. tostring(instr.save))
        return "done"
      end, "save slot " .. tostring(instr.save)
    elseif instr.log then
      return function() log.say(instr.log); return "done" end, "log"
    elseif instr.call then
      local fn = instr.call
      return function() return fn(ctx, state, walk, keys) end, "call"
    else
      return nil, "unknown instruction"
    end
  end

  local function advance()
    pc = pc + 1
    task = nil
    taskFrames = 0
    taskRetries = 0
  end

  ---------------------------------------------------------------- public
  function M.load(list)
    route = list or {}
    pc = 1
    task = nil
    finished = #route == 0
    log.info(string.format("route loaded: %d instructions", #route))
  end

  function M.tick(f)
    if f then frame = f end
    if finished then return end
    if pc > #route then
      finished = true
      log.say("route finished - the run is complete")
      return
    end

    if not task then
      local instr = route[pc]
      local t, name = makeTask(instr)
      if not t then
        log.error(string.format("instruction %d: %s", pc, name))
        pc = pc + 1
        if pc > #route then finished = true end
        return
      end
      task, taskName = t, name
      taskFrames = 0
      stats.instructions = stats.instructions + 1
      log.say(string.format("[%d/%d] %s", pc, #route, name))
    end

    taskFrames = taskFrames + 1
    local r, why = task()
    if r == "done" then
      advance()
    elseif r == "failed" then
      walk.cancel()
      taskRetries = taskRetries + 1
      if taskRetries > MAX_RETRIES then
        log.warn(string.format("giving up on [%d] %s: %s", pc, taskName,
                               why or "unknown"))
        if cfg.onFailure == "abort" then
          finished = true
          failure = taskName .. ": " .. (why or "?")
        else
          advance()
        end
      else
        log.debug(string.format("retrying [%d] %s (%s)", pc, taskName, why or ""))
        task = nil            -- rebuild the task from scratch
      end
    elseif taskFrames > TIMEOUT then
      walk.cancel()
      taskRetries = taskRetries + 1
      log.warn(string.format("timeout on [%d] %s", pc, taskName))
      if taskRetries > MAX_RETRIES then
        if cfg.onFailure == "abort" then
          finished = true
          failure = "timeout: " .. taskName
        else
          advance()
        end
      else
        task = nil
      end
    end
  end

  function M.status()
    return {
      pc = pc, total = #route, task = taskName,
      finished = finished, failure = failure, stats = stats,
    }
  end

  function M.isFinished()
    return finished
  end

  function M.cancel()
    walk.cancel()
    keys.release()
  end

  return M
end
