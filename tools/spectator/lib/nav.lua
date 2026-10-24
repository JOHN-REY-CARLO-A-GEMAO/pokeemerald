-- nav.lua - pathfinding inside a map, and route planning across maps.
--
-- Two levels:
--   nav.plan(mapId, from, to)        -> tile-by-tile steps inside one map
--   nav.travel(fromMapId, toMapId)   -> first hop towards another map
--
-- The across-map search is a BFS over the compiled world graph
-- (connections + warp events).  Only the *next* hop is committed to; the
-- runner re-reads its position after every hop, so drift (random encounters,
-- scripted warps, being shoved by an NPC) corrects itself.
return function(ctx)
  local M = {}
  local world = ctx.world
  local log = ctx.util

  local DIR_ORDER = { "up", "down", "left", "right" }
  local OPPOSITE = { up = "down", down = "up", left = "right", right = "left" }
  local DX = { up = 0, down = 0, left = -1, right = 1 }
  local DY = { up = -1, down = 1, left = 0, right = 0 }

  ---------------------------------------------------------------- tile rules
  local function kindAt(map, x, y)
    return world.tileKind(map, x, y)
  end

  -- Can the player stand on this tile?  Warp tiles are passable only when
  -- they are the destination (otherwise we would teleport mid-route).
  function M.standable(map, x, y, allowWarp)
    if not map then return false end
    if x < 0 or y < 0 or x >= map.w or y >= map.h then return false end
    local kind = kindAt(map, x, y)
    if kind and kind:sub(1, 6) == "ledge:" then return false end
    if world.isWall(map, x, y) then
      -- door/ladder tiles are sometimes marked solid; treat them as usable
      if allowWarp and kind == "door" then return true end
      return false
    end
    if not allowWarp and world.warpAt(map, x, y) then return false end
    return true
  end

  -- Is there a one-way ledge jump from (x,y) towards `dir`?  Ledges are
  -- blocked tiles you hop over: standing behind one and pushing the ledge's
  -- direction carries you two tiles forward.
  local JUMP_KIND = { down = "ledge:down", up = "ledge:up",
                      left = "ledge:left", right = "ledge:right" }
  local function jumpTarget(map, x, y, dir)
    local ax, ay = x + DX[dir], y + DY[dir]        -- the ledge itself
    if kindAt(map, ax, ay) ~= JUMP_KIND[dir] then return nil end
    local bx, by = x + DX[dir] * 2, y + DY[dir] * 2 -- landing tile
    if bx < 0 or by < 0 or bx >= map.w or by >= map.h then return nil end
    if world.isWall(map, bx, by) then return nil end
    return bx, by
  end

  ------------------------------------------------------------- tile search
  -- BFS over tiles.  Returns a list of steps: { {dir=..., jump=bool}, ... }
  -- or nil when unreachable.
  function M.plan(map, from, to, opts)
    opts = opts or {}
    if not map or not from or not to then return nil end
    local allowWarp = opts.allowWarp
    -- Coord-event (trigger) tiles normally *advance* the story, and they are
    -- often the only way through, so they are passable by default.  A caller
    -- can ask to avoid them (e.g. when a trigger would warp us away).
    local avoidTriggers = opts.avoidTriggers == true
    local w, h = map.w, map.h
    local startX, startY = from.x, from.y
    local goalX, goalY = to.x, to.y

    -- Refuse goals we could never stand on: the real engine blocks any tile
    -- whose collision bits are set, so walking "into" one only works for
    -- doors (handled by the runner as a bump, not a walk).
    if not M.standable(map, goalX, goalY, allowWarp) then return nil end

    local function blockedExtra(x, y)
      if avoidTriggers and map.triggers then
        for _, t in ipairs(map.triggers) do
          if t.x == x and t.y == y then return true end
        end
      end
      return false
    end

    local index = function(x, y) return y * w + x + 1 end
    local prev = {}
    local prevDir = {}
    local seen = { [index(startX, startY)] = true }
    local queue = { { startX, startY } }
    local head = 1
    local found = false

    while head <= #queue do
      local cx, cy = queue[head][1], queue[head][2]
      head = head + 1
      if cx == goalX and cy == goalY then found = true break end

      for _, dir in ipairs(DIR_ORDER) do
        local nx, ny = cx + DX[dir], cy + DY[dir]
        local isGoal = (nx == goalX and ny == goalY)
        local ok = isGoal
          or (M.standable(map, nx, ny, false) and not blockedExtra(nx, ny))
        -- stepping onto a warp tile is fine when it is the goal
        if ok and nx >= 0 and ny >= 0 and nx < w and ny < h then
          local k = index(nx, ny)
          if not seen[k] then
            seen[k] = true
            prev[k] = index(cx, cy)
            prevDir[k] = dir
            queue[#queue + 1] = { nx, ny }
          end
        end
      end

      -- ledge jumps
      for _, dir in ipairs(DIR_ORDER) do
        local bx, by = jumpTarget(map, cx, cy, dir)
        if bx then
          local k = index(bx, by)
          if not seen[k] then
            seen[k] = true
            prev[k] = index(cx, cy)
            prevDir[k] = dir .. "+jump"
            queue[#queue + 1] = { bx, by }
          end
        end
      end
    end

    if not found then return nil end

    local steps = {}
    local cur = index(goalX, goalY)
    local startIdx = index(startX, startY)
    while cur ~= startIdx do
      local dir = prevDir[cur]
      local jump = dir and dir:find("%+jump") ~= nil
      if jump then dir = dir:gsub("%+jump", "") end
      table.insert(steps, 1, { dir = dir, jump = jump })
      cur = prev[cur]
      if not cur then return nil end
    end
    return steps
  end

  -- Nearest reachable tile adjacent to `target` (for talking to NPCs and
  -- reading signs).
  function M.planAdjacent(map, from, target, opts)
    opts = opts or {}
    local best, bestSteps = nil, nil
    for _, dir in ipairs(DIR_ORDER) do
      local ax, ay = target.x + DX[dir], target.y + DY[dir]
      if ax >= 0 and ay >= 0 and ax < map.w and ay < map.h
         and M.standable(map, ax, ay, false) then
        local steps = M.plan(map, from, { x = ax, y = ay }, opts)
        if steps and (not bestSteps or #steps < #bestSteps) then
          best, bestSteps = { x = ax, y = ay, dir = dir }, steps
        end
      end
    end
    if best then
      best.steps = bestSteps
      -- `dir` points from the target towards the tile we stand on, so the
      -- player has to face the other way to look at the target
      best.facing = OPPOSITE[best.dir]
    end
    return best
  end

  ------------------------------------------------------- across the world
  local function neighboursOf(mapId)
    local map = world.maps[mapId]
    if not map then return {} end
    local out = {}
    for _, conn in ipairs(map.conns or {}) do
      if world.maps[conn.to] then
        out[#out + 1] = { kind = "conn", dir = conn.dir, to = conn.to,
                          off = conn.off }
      end
    end
    for _, warp in ipairs(map.warps or {}) do
      if world.maps[warp.to] then
        out[#out + 1] = { kind = "warp", to = warp.to, x = warp.x, y = warp.y,
                          tw = warp.tw, tx = warp.tx, ty = warp.ty }
      end
    end
    return out
  end

  M.neighbours = neighboursOf

  -- Shortest hop sequence from one map to another.  `blocked` optionally
  -- contains edge keys ("conn:TO:dir" / "warp:TO:x:y") to avoid.
  function M.mapRoute(fromMapId, toMapId, blocked)
    if fromMapId == toMapId then return {} end
    blocked = blocked or {}
    local prev, prevHop = {}, {}
    local seen = { [fromMapId] = true }
    local queue = { fromMapId }
    local head = 1
    local found = false

    while head <= #queue do
      local cur = queue[head]
      head = head + 1
      for _, hop in ipairs(neighboursOf(cur)) do
        local key
        if hop.kind == "conn" then
          key = "conn:" .. hop.to .. ":" .. hop.dir
        else
          key = "warp:" .. hop.to .. ":" .. hop.x .. ":" .. hop.y
        end
        if not blocked[key] and not seen[hop.to] then
          seen[hop.to] = true
          prev[hop.to] = cur
          prevHop[hop.to] = hop
          if hop.to == toMapId then found = true break end
          queue[#queue + 1] = hop.to
        end
      end
      if found then break end
    end

    if not found then return nil end
    local hops = {}
    local cur = toMapId
    while cur ~= fromMapId do
      table.insert(hops, 1, prevHop[cur])
      cur = prev[cur]
      if not cur then return nil end
    end
    return hops
  end

  -- Where do you land if you leave `mapId` towards `dir` at column/row `coord`?
  -- A map connection's `offset` shifts the neighbour along the shared edge;
  -- measuring the compiled maps shows the neighbour sits at coord - offset
  -- (verified against every offset connection in the game's map data).
  function M.crossing(mapId, dir, coord)
    local map = world.maps[mapId]
    if not map then return nil end
    for _, conn in ipairs(map.conns or {}) do
      if conn.dir == dir then
        local dest = world.maps[conn.to]
        if not dest then return nil end
        local nx, ny
        if dir == "up" or dir == "down" then
          nx = coord - (conn.off or 0)
          ny = (dir == "up") and dest.h - 1 or 0
        else
          ny = coord - (conn.off or 0)
          nx = (dir == "left") and dest.w - 1 or 0
        end
        if M.standable(dest, nx, ny, false) then
          return { mapId = conn.to, x = nx, y = ny }
        end
        return nil
      end
    end
    return nil
  end

  -- Every passable tile on the border of `map` in direction `dir`, ordered by
  -- walking distance from `from`.  Crossing points are verified by actually
  -- trying them, so we do not need to model connection offsets exactly.
  function M.borderTiles(map, dir, from)
    local out = {}
    local candidates = {}
    local function usable(x, y, coord)
      if world.isWall(map, x, y) then return false end
      if world.warpAt(map, x, y) then return false end
      -- only offer columns that land on walkable ground next door
      return M.crossing(map.id, dir, coord) ~= nil
    end
    if dir == "up" or dir == "down" then
      local y = (dir == "up") and 0 or (map.h - 1)
      for x = 0, map.w - 1 do
        if usable(x, y, x) then
          candidates[#candidates + 1] = { x = x, y = y }
        end
      end
    else
      local x = (dir == "left") and 0 or (map.w - 1)
      for y = 0, map.h - 1 do
        if usable(x, y, y) then
          candidates[#candidates + 1] = { x = x, y = y }
        end
      end
    end
    if from then
      table.sort(candidates, function(a, b)
        local da = math.abs(a.x - from.x) + math.abs(a.y - from.y)
        local db = math.abs(b.x - from.x) + math.abs(b.y - from.y)
        return da < db
      end)
    end
    return candidates
  end

  --------------------------------------------------- named place resolution
  -- Routes name a goal as MAP_* or a map's friendly name ("RustboroCity").
  function M.resolveMapId(name)
    if not name then return nil end
    if world.maps[name] then return name end
    if world.byName[name] then return world.byName[name] end
    local upper = "MAP_" .. name:gsub("([a-z])([A-Z])", "%1_%2"):upper()
    if world.maps[upper] then return upper end
    return nil
  end

  return M
end
