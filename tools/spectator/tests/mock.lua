-- tests/mock.lua - a tiny fake GBA core so the bot can be tested without a ROM.
--
-- It implements just enough of mGBA's scripting API (emu:read8/16/32,
-- emu:setKeys, console:*, callbacks:add) plus a simplified world simulation:
-- the player walks tile by tile, ledges can be jumped, doors warp, map edges
-- follow connections, and a battle can be triggered to check the bot's
-- fighting rhythm.  It is deliberately slow (8 frames per tile) to mirror the
-- real game's timings.
local Mock = {}

local SPEC_DIR = SPEC_DIR or "tools/spectator"

local function loadLua(path)
  local chunk, err = loadfile(path)
  assert(chunk, "cannot load " .. path .. ": " .. tostring(err))
  return chunk()
end

--------------------------------------------------------------------- memory
local function newMemory()
  local mem = {}
  local m = {}

  function m:read8(addr)
    return mem[addr] or 0
  end

  function m:read16(addr)
    return (mem[addr] or 0) | ((mem[addr + 1] or 0) << 8)
  end

  function m:read32(addr)
    return (mem[addr] or 0) | ((mem[addr + 1] or 0) << 8)
      | ((mem[addr + 2] or 0) << 16) | ((mem[addr + 3] or 0) << 24)
  end

  function m:write8(addr, v)
    mem[addr] = v & 0xFF
  end

  function m:write16(addr, v)
    m:write8(addr, v & 0xFF)
    m:write8(addr + 1, (v >> 8) & 0xFF)
  end

  function m:write32(addr, v)
    m:write16(addr, v & 0xFFFF)
    m:write16(addr + 2, (v >> 16) & 0xFFFF)
  end

  return m
end

----------------------------------------------------------------------- mock
function Mock.new(opts)
  opts = opts or {}
  local world = loadLua(SPEC_DIR .. "/data/world.lua")

  local self = {
    world = world,
    mem = newMemory(),
    keys = 0,
    logs = {},
    handlers = {},
    frame = 0,
    mode = "frontend",
    frontendPresses = 0,
    facing = "down",
    moveProgress = 0,
    turnFrames = 0,
    warpTimer = nil,
    party = { { level = 8, hp = 30, maxHp = 30 } },
    flags = {},
    vars = {},
    battle = nil,        -- { frames=..., hpEnemy=..., wild=true }
    battlesFought = 0,
    script = { dir = SPEC_DIR },
  }

  -- addresses (arbitrary but distinct)
  self.ADDR = {
    gSaveBlock1Ptr = 0x03005D8C,
    gMain = 0x030022C0,
    gBattleMons = 0x02024000,
    gBattleTypeFlags = 0x020239F8,
    saveBlock1 = 0x02025734,
    CB2_Overworld = 0x08012345,
    CB2_BattleMain = 0x08054321,
    CB2_InitTitleScreen = 0x08099999,
  }

  self.mem:write32(self.ADDR.gSaveBlock1Ptr, self.ADDR.saveBlock1)

  ------------------------------------------------------------ player state
  self.player = { map = opts.map or "MAP_LITTLEROOT_TOWN",
                  x = opts.x or 12, y = opts.y or 12 }

  local function mapEntry(id)
    return world.maps[id]
  end

  local function writeState()
    local sb = self.ADDR.saveBlock1
    local map = mapEntry(self.player.map)
    self.mem:write16(sb + 0x00, self.player.x)
    self.mem:write16(sb + 0x02, self.player.y)
    if map then
      self.mem:write8(sb + 0x04, map.group)
      self.mem:write8(sb + 0x05, map.num)
    end
    self.mem:write8(sb + 0x234, #self.party)
    for i, mon in ipairs(self.party) do
      local base = sb + 0x238 + (i - 1) * 0x64
      self.mem:write32(base, 0)                  -- personality (unused)
      self.mem:write8(base + 0x54, mon.level)
      self.mem:write16(base + 0x56, mon.hp)
      self.mem:write16(base + 0x58, mon.maxHp)
    end
    for id, value in pairs(self.flags) do
      local byte = sb + 0x1270 + math.floor(id / 8)
      local cur = self.mem:read8(byte)
      if value then
        cur = cur | (1 << (id % 8))
      else
        cur = cur & ~(1 << (id % 8))
      end
      self.mem:write8(byte, cur)
    end
    for id, value in pairs(self.vars) do
      self.mem:write16(sb + 0x139C + id * 2, value)
    end
    -- screens
    local cb
    if self.mode == "overworld" then
      cb = self.ADDR.CB2_Overworld
    elseif self.mode == "battle" then
      cb = self.ADDR.CB2_BattleMain
    else
      cb = self.ADDR.CB2_InitTitleScreen
    end
    self.mem:write32(self.ADDR.gMain + 0x004, cb)
    local inBattle = self.mode == "battle" and 0x02 or 0x00
    self.mem:write8(self.ADDR.gMain + 0x439, inBattle)
    if self.battle then
      local bm = self.ADDR.gBattleMons
      self.mem:write16(bm + 0x00, 277)            -- species: Treecko
      self.mem:write16(bm + 0x0C, 33)             -- move 1: Tackle
      self.mem:write8(bm + 0x24, 35)
      self.mem:write16(bm + 0x28, self.party[1].hp)
      self.mem:write8(bm + 0x2A, self.party[1].level)
      self.mem:write16(bm + 0x2C, self.party[1].maxHp)
      local enemy = bm + 0x58
      self.mem:write16(enemy + 0x00, 263)         -- Zigzagoon
      self.mem:write16(enemy + 0x28, math.max(self.battle.hpEnemy, 0))
      self.mem:write8(enemy + 0x2A, self.battle.level or 3)
      self.mem:write16(enemy + 0x2C, self.battle.maxHp or 18)
      local flags = self.battle.wild and 0 or (1 << 3)
      self.mem:write32(self.ADDR.gBattleTypeFlags, flags)
    end
  end

  ------------------------------------------------------------- script API
  function self:read8(a) return self.mem:read8(a) end
  function self:read16(a) return self.mem:read16(a) end
  function self:read32(a) return self.mem:read32(a) end
  function self:write8(a, v) self.mem:write8(a, v) end
  function self:write16(a, v) self.mem:write16(a, v) end
  function self:write32(a, v) self.mem:write32(a, v) end
  function self:currentFrame() return self.frame end
  function self:setKeys(mask) self.keys = mask end
  function self:getKeys() return self.keys end
  function self:saveStateSlot(slot)
    self.lastSaveSlot = slot
    return true
  end

  self.console = {
    log = function(_, msg) self.logs[#self.logs + 1] = { level = "log", msg = msg } end,
    warn = function(_, msg) self.logs[#self.logs + 1] = { level = "warn", msg = msg } end,
    error = function(_, msg) self.logs[#self.logs + 1] = { level = "error", msg = msg } end,
  }

  self.callbacks = {
    add = function(_, name, fn)
      self.handlers[name] = fn
      return 1
    end,
  }

  self.C = {
    GBA_KEY = { A = 0, B = 1, SELECT = 2, START = 3, RIGHT = 4, LEFT = 5,
                UP = 6, DOWN = 7, R = 8, L = 9 },
  }

  ------------------------------------------------------------- simulation
  local DX = { up = 0, down = 0, left = -1, right = 1 }
  local DY = { up = -1, down = 1, left = 0, right = 0 }
  local KEY_OF = {}

  local function pressed(name)
    local index = self.C.GBA_KEY[name] or self.C.GBA_KEY[name:upper()]
    if not index then return false end
    return (self.keys & (1 << index)) ~= 0
  end

  local function standable(map, x, y)
    if not map then return false end
    if x < 0 or y < 0 or x >= map.w or y >= map.h then return false end
    local kind = world.tileKind(map, x, y)
    if kind and kind:sub(1, 6) == "ledge:" then return false end
    return not world.isWall(map, x, y)
  end

  local function doMove(dir)
    local map = mapEntry(self.player.map)
    if not map then return false end
    local tx, ty = self.player.x + DX[dir], self.player.y + DY[dir]

    -- ledge jump: the tile in front is a ledge facing our way
    local frontKind = world.tileKind(map, tx, ty)
    if frontKind == "ledge:" .. dir then
      local lx, ly = tx + DX[dir], ty + DY[dir]
      if standable(map, lx, ly) then
        self.player.x, self.player.y = lx, ly
        return true
      end
      return false
    end

    -- walking into a door tile warps you without ever standing on it
    local warpHere = world.warpAt(map, tx, ty)
    if warpHere and not standable(map, tx, ty) then
      if world.tileKind(map, tx, ty) == "door" then
        self.warpTimer = { frames = 6, warp = warpHere }
        return true
      end
      return false
    end

    if standable(map, tx, ty) then
      self.player.x, self.player.y = tx, ty
      local warp = world.warpAt(map, tx, ty)
      if warp then
        self.warpTimer = { frames = 6, warp = warp }
      end
      return true
    end

    -- map edge: follow a connection if there is one.  The neighbour is
    -- shifted by the connection offset, measured as coord - offset.
    if tx < 0 or ty < 0 or tx >= map.w or ty >= map.h then
      for _, conn in ipairs(map.conns or {}) do
        if conn.dir == dir then
          local dest = mapEntry(conn.to)
          if dest then
            local off = conn.off or 0
            local nx, ny
            if dir == "up" then nx, ny = self.player.x - off, dest.h - 1
            elseif dir == "down" then nx, ny = self.player.x - off, 0
            elseif dir == "left" then nx, ny = dest.w - 1, self.player.y - off
            else nx, ny = 0, self.player.y - off end
            if standable(dest, nx, ny) then
              self.player.map, self.player.x, self.player.y = conn.to, nx, ny
              return true
            end
          end
        end
      end
    end
    return false
  end

  -- advance the emulated machine by one frame
  function self:step()
    self.frame = self.frame + 1

    if self.mode == "frontend" then
      if pressed("A") or pressed("START") then
        if not self.wasPressed then self.frontendPresses = self.frontendPresses + 1 end
      end
      if self.frontendPresses >= 3 then
        self.mode = "overworld"
      end
    elseif self.mode == "overworld" then
      if self.warpTimer then
        self.warpTimer.frames = self.warpTimer.frames - 1
        if self.warpTimer.frames <= 0 then
          local warp = self.warpTimer.warp
          self.player.map = warp.to
          local dest = mapEntry(warp.to)
          if dest then
            self.player.x = warp.tx or self.player.x
            self.player.y = warp.ty or self.player.y
          end
          self.warpTimer = nil
        end
      else
        local moved = false
        local dir = nil
        for _, d in ipairs({ "up", "down", "left", "right" }) do
          if pressed(d) then dir = d break end
        end
        if dir then
          if self.facing ~= dir then
            self.facing = dir
            self.turnFrames = 3
            self.moveProgress = 0
          elseif self.turnFrames > 0 then
            self.turnFrames = self.turnFrames - 1
          else
            self.moveProgress = self.moveProgress + 1
            if self.moveProgress >= 8 then
              self.moveProgress = 0
              moved = doMove(dir)
            end
          end
        else
          self.moveProgress = 0
        end
        -- wild encounter every `encounterEvery` walking steps in grass
        if moved and self.encounterEvery then
          self.steps = (self.steps or 0) + 1
          if self.steps % self.encounterEvery == 0 and not self.battle then
            self:startBattle({ wild = true, hpEnemy = 18, maxHp = 18, level = 3 })
          end
        end
      end
    elseif self.mode == "battle" then
      if self.battle then
        self.battle.frames = self.battle.frames + 1
        if pressed("A") and not self.wasPressed then
          self.battle.hpEnemy = self.battle.hpEnemy - 12
          self.battle.presses = (self.battle.presses or 0) + 1
        end
        if self.battle.hpEnemy <= 0 and not self.battle.finished then
          self.battle.finished = true
          self.battle.finishTimer = 20
        end
        if self.battle.finishTimer then
          self.battle.finishTimer = self.battle.finishTimer - 1
          if self.battle.finishTimer <= 0 then
            self.battle = nil
            self.mode = "overworld"
          end
        end
      end
    end

    self.wasPressed = pressed("A")
    writeState()
  end

  function self:startBattle(cfg)
    self.battlesFought = self.battlesFought + 1
    self.battle = cfg or { wild = true, hpEnemy = 18, maxHp = 18, level = 3 }
    self.battle.frames = self.battle.frames or 0
    self.mode = "battle"
  end

  -- run n frames: emulate, then let the script think
  function self:run(n)
    for _ = 1, (n or 1) do
      self:step()
      local handler = self.handlers.frame
      if handler then handler() end
    end
  end

  function self:runUntil(predicate, maxFrames)
    for _ = 1, (maxFrames or 10000) do
      self:run(1)
      if predicate() then return true, self.frame end
    end
    return false, self.frame
  end

  function self:logsContain(pattern)
    for _, entry in ipairs(self.logs) do
      if entry.msg:find(pattern, 1, true) then return true, entry end
    end
    return false
  end

  function self:dumpLog()
    for _, entry in ipairs(self.logs) do
      print("  [" .. entry.level .. "] " .. entry.msg)
    end
  end

  writeState()
  return self
end

return Mock
