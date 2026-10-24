-- tests/test_route.lua - lints route.lua against the compiled world
--
-- Every instruction the route uses must be a known instruction, and every
-- named map / NPC script / flag / variable must actually exist in this
-- repository's data.  This catches typos and renamed scripts before a run
-- wastes ten minutes walking into a wall.
local H = dofile(SPEC_DIR .. "/tests/harness.lua")
local world = H.getWorld()
local route = H.load("route.lua")

local KNOWN = {
  travel = true, goto_tile = true, talk = true, interact = true, press = true,
  wait_flag = true, wait_flag_clear = true, wait_var = true, wait_party = true,
  wait_map = true, wait_frames = true, save = true, log = true, call = true,
  opts = true, min = true, max = true, eq = true, times = true, gap = true,
}

H.check(type(route) == "table" and #route > 0, "route.lua returns a list")

-- collect every object script name in the world
local scripts = {}
for _, map in pairs(world.maps) do
  for _, obj in ipairs(map.objects or {}) do
    if obj.script then scripts[obj.script] = map.id end
  end
  for _, trig in ipairs(map.triggers or {}) do
    if trig.script then scripts[trig.script] = map.id end
  end
end

local counts = {}
local function resolveMap(name)
  if world.maps[name] then return name end
  -- same rule the runner uses
  local upper = "MAP_" .. name:gsub("([a-z])([A-Z])", "%1_%2"):upper()
  if world.maps[upper] then return upper end
  return nil
end

for i, instr in ipairs(route) do
  H.check(type(instr) == "table", "instruction " .. i .. " is a table")
  for key in pairs(instr) do
    H.check(KNOWN[key], string.format("instruction %d uses a known key (%s)", i, key))
    counts[key] = (counts[key] or 0) + 1
  end

  if instr.travel then
    H.check(resolveMap(instr.travel) ~= nil,
            string.format("instruction %d travel target exists (%s)", i, instr.travel))
  end
  if instr.wait_map then
    H.check(resolveMap(instr.wait_map) ~= nil,
            string.format("instruction %d wait_map exists (%s)", i, instr.wait_map))
  end
  if instr.talk then
    H.check(scripts[instr.talk] ~= nil,
            string.format("instruction %d talk script exists (%s)", i, instr.talk))
  end
  if instr.wait_flag then
    H.check((world.flags or {})[instr.wait_flag] ~= nil,
            string.format("instruction %d flag exists (%s)", i, instr.wait_flag))
  end
  if instr.wait_flag_clear then
    H.check((world.flags or {})[instr.wait_flag_clear] ~= nil,
            string.format("instruction %d flag exists (%s)", i, instr.wait_flag_clear))
  end
  if instr.wait_var then
    H.check((world.vars or {})[instr.wait_var] ~= nil,
            string.format("instruction %d var exists (%s)", i, instr.wait_var))
  end
  if instr.interact then
    local t = instr.interact
    H.check(t.x and t.y, string.format("instruction %d interact has x/y", i))
  end
end

-- the route should actually start at the beginning of the game
H.check(counts.log ~= nil, "route logs its progress")
print(string.format("test_route: %d instructions (travel x%d, talk x%d) OK",
                    #route, counts.travel or 0, counts.talk or 0))
