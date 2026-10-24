-- tests/test_walk.lua - tile stepping verified against the mock core
local H = dofile(SPEC_DIR .. "/tests/harness.lua")

local mock = H.mock({ map = "MAP_LITTLEROOT_TOWN", x = 12, y = 12 })
mock.mode = "overworld"
mock:step()
local ctx = H.context(mock, { stuckFrames = 40 })
local walk, nav, state = ctx.walk, ctx.nav, ctx.state
local town = ctx.world.maps.MAP_LITTLEROOT_TOWN

-- a normal walk ------------------------------------------------------------
local steps = nav.plan(town, { x = 12, y = 12 }, { x = 12, y = 2 })
H.check(steps ~= nil, "planned a walk north")
walk.setPath(steps)

local arrived = false
for _ = 1, 600 do
  mock:step()
  if walk.tick() == "arrived" then arrived = true break end
end
H.check(arrived, "walker reports arrival")
local x, y = state.pos()
H.check(x == 12 and y == 2, "walker landed on the target tile")

-- holding a direction actually presses the button -------------------------
walk.setPath(nav.plan(town, { x = 12, y = 2 }, { x = 13, y = 2 }))
mock:step()
walk.tick()
H.check(mock.keys ~= 0, "a direction key is held while walking")
for _ = 1, 200 do mock:step(); if walk.tick() == "arrived" then break end end
H.check(mock.keys == 0, "keys are released on arrival")

-- walking into a wall is reported as blocked, not retried forever ---------
local mock2 = H.mock({ map = "MAP_LITTLEROOT_TOWN", x = 5, y = 4 })
mock2.mode = "overworld"
mock2:step()
local ctx2 = H.context(mock2, { stuckFrames = 20 })
ctx2.walk.setPath({ { dir = "down" } })     -- (5,5) is a house wall
local result = "moving"
for _ = 1, 200 do
  mock2:step()
  result = ctx2.walk.tick()
  if result == "blocked" then break end
end
H.check(result == "blocked", "blocked movement is detected")
local px, py = ctx2.state.pos()
H.check(px == 5 and py == 4, "player did not move into the wall")

-- a ledge can be jumped ---------------------------------------------------
-- find a map + tile pair where a ledge is directly south of open ground
local found = nil
for mapId, map in pairs(ctx.world.maps) do
  for _, s in ipairs(map.special or {}) do
    if s.kind == "ledge:down" then
      local above = { x = s.x, y = s.y - 1 }
      local below = { x = s.x, y = s.y + 1 }
      if above.y >= 0 and below.y < map.h
         and nav.standable(map, above.x, above.y, false)
         and nav.standable(map, below.x, below.y, false) then
        found = { map = map, id = mapId, above = above, below = below }
        break
      end
    end
  end
  if found then break end
end
H.check(found ~= nil, "found a jumpable ledge somewhere in the world")

if found then
  local mock3 = H.mock({ map = found.id, x = found.above.x, y = found.above.y })
  mock3.mode = "overworld"
  mock3:step()
  local ctx3 = H.context(mock3, { stuckFrames = 30 })
  local planned = ctx3.nav.plan(found.map, found.above, found.below)
  H.check(planned ~= nil, "planner found a route across the ledge")
  H.check(planned[1].jump == true or #planned > 1,
          "ledge is either jumped or walked around")
  ctx3.walk.setPath(planned)
  local landed = false
  for _ = 1, 400 do
    mock3:step()
    if ctx3.walk.tick() == "arrived" then landed = true break end
  end
  H.check(landed, "walked/jumped to the ledge landing tile")
  local lx, ly = ctx3.state.pos()
  H.check(lx == found.below.x and ly == found.below.y, "landed past the ledge")
end

print("test_walk: OK")
