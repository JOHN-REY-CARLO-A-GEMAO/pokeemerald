-- state.lua - reads the parts of game state the bot cares about.
--
-- Every offset below is copied from this repository's headers, so the numbers
-- stay honest if the ROM is rebuilt from this tree:
--
--   struct SaveBlock1   include/global.h
--     0x00 pos.x/pos.y            (struct Coords16)
--     0x04 location               (struct WarpData: mapGroup, mapNum, warpId, pad, x, y)
--     0x234 playerPartyCount
--     0x238 playerParty[6]        (struct Pokemon)
--     0x1270 flags[]
--     0x139C vars[]
--   struct Pokemon      include/pokemon.h
--     0x50 status, 0x54 level, 0x56 hp, 0x58 maxHP
--   struct BattlePokemon include/pokemon.h
--     0x00 species, 0x0C moves[4], 0x24 pp[4], 0x28 hp, 0x2A level, 0x2C maxHP
--   struct Main         include/main.h
--     0x004 callback2, 0x439 inBattle:1
return function(ctx)
  local M = {}
  local mem = ctx.mem
  local sym = ctx.sym
  local world = ctx.world
  local log = ctx.util

  local S1_POS = 0x00
  local S1_LOCATION = 0x04
  local S1_PARTY_COUNT = 0x234
  local S1_PARTY = 0x238
  local S1_FLAGS = 0x1270
  local S1_VARS = 0x139C

  local MON_LEVEL, MON_HP, MON_MAXHP = 0x54, 0x56, 0x58

  local B_MOVES, B_PP, B_HP, B_LEVEL, B_MAXHP = 0x0C, 0x24, 0x28, 0x2A, 0x2C
  local BATTLEMON_SIZE = 0x58

  local MAIN_CALLBACK2 = 0x004
  local MAIN_INBATTLE = 0x439

  local sb1Cache = nil
  local function sb1()
    if sb1Cache then return sb1Cache end
    local ptrAddr = sym.firstAddr("gSaveBlock1Ptr", "gSaveBlock1")
    if not ptrAddr then return nil end
    local base = mem.read32(ptrAddr)
    -- gSaveBlock1Ptr is a pointer; gSaveBlock1 is the buffer itself
    if base < 0x02000000 or base > 0x02040000 then
      base = ptrAddr
    end
    if base == 0 then return nil end
    sb1Cache = base
    return base
  end

  function M.resetCache()
    sb1Cache = nil
  end

  function M.ready()
    return sb1() ~= nil
  end

  -- ---------------------------------------------------------------- world
  function M.pos()
    local base = sb1()
    if not base then return nil end
    return mem.reads16(base + S1_POS), mem.reads16(base + S1_POS + 2)
  end

  function M.location()
    local base = sb1()
    if not base then return nil end
    local group = mem.reads8(base + S1_LOCATION)
    local num = mem.reads8(base + S1_LOCATION + 1)
    return group, num
  end

  function M.mapId()
    local group, num = M.location()
    if not group then return nil end
    return world.byPos(group, num)
  end

  function M.map()
    local id = M.mapId()
    return id and world.maps[id] or nil
  end

  -- ---------------------------------------------------------------- party
  function M.partyCount()
    local base = sb1()
    if not base then return 0 end
    return mem.read8(base + S1_PARTY_COUNT)
  end

  function M.party()
    local base = sb1()
    local out = {}
    if not base then return out end
    local count = M.partyCount()
    for i = 0, math.min(count, 6) - 1 do
      local addr = base + S1_PARTY + i * 0x64
      local hp = mem.read16(addr + MON_HP)
      local maxHp = mem.read16(addr + MON_MAXHP)
      out[#out + 1] = {
        index = i,
        level = mem.read8(addr + MON_LEVEL),
        hp = hp,
        maxHp = maxHp,
        fainted = hp == 0,
      }
    end
    return out
  end

  function M.firstHealthy()
    for _, mon in ipairs(M.party()) do
      if not mon.fainted then return mon end
    end
    return nil
  end

  function M.partyFainted()
    local party = M.party()
    if #party == 0 then return false end
    for _, mon in ipairs(party) do
      if not mon.fainted then return false end
    end
    return true
  end

  -- ------------------------------------------------------------ flags/vars
  function M.flag(id)
    local base = sb1()
    if not base or not id then return nil end
    local byte = mem.read8(base + S1_FLAGS + math.floor(id / 8))
    return (byte >> (id % 8)) & 1 == 1
  end

  function M.var(id)
    local base = sb1()
    if not base or not id then return nil end
    return mem.read16(base + S1_VARS + id * 2)
  end

  function M.varByName(name)
    local id = (ctx.constants and ctx.constants.vars or {})[name]
    if id == nil then return nil end
    return M.var(id), id
  end

  -- ---------------------------------------------------------------- battle
  function M.battle()
    local addr = sym.addr("gBattleMons")
    if not addr then return nil end
    local function mon(battler)
      local base = addr + battler * BATTLEMON_SIZE
      local moves = {}
      for i = 0, 3 do
        local move = mem.read16(base + B_MOVES + i * 2)
        moves[#moves + 1] = { id = move, pp = mem.read8(base + B_PP + i) }
      end
      return {
        species = mem.read16(base),
        hp = mem.read16(base + B_HP),
        maxHp = mem.read16(base + B_MAXHP),
        level = mem.read8(base + B_LEVEL),
        moves = moves,
      }
    end
    local flags = mem.read32(sym.addr("gBattleTypeFlags") or 0)
    return {
      player = mon(0),
      enemy = mon(1),
      wild = (flags & (1 << 3)) == 0,   -- BATTLE_TYPE_TRAINER == 1 << 3
      double = (flags & 1) ~= 0,        -- BATTLE_TYPE_DOUBLE  == 1 << 0
    }
  end

  -- ------------------------------------------------------------ screen mode
  -- "battle", "overworld", "frontend", "other:<name>" or "boot"
  function M.mode()
    if not M.ready() then return "boot" end
    local mainAddr = sym.addr("gMain")
    if not mainAddr then return "unknown" end

    local inBattleByte = mem.read8(mainAddr + MAIN_INBATTLE)
    if (inBattleByte & 0x02) ~= 0 then return "battle" end

    local cbAddr = mem.read32(mainAddr + MAIN_CALLBACK2)
    local name = sym.nameOf(cbAddr) or ""
    if name == "" then return "other:nil" end
    if name:find("Battle") then return "battle" end
    if name:find("Overworld") then return "overworld" end
    if name:find("Title") or name:find("Intro") or name:find("MainMenu")
       or name:find("Copyright") or name:find("GameFreak")
       or name:find("Birch") or name:find("NamingScreen")
       or name:find("OakSpeech") or name:find("MainMenu") then
      return "frontend"
    end
    return "other:" .. name
  end

  function M.callbackName()
    local mainAddr = sym.addr("gMain")
    if not mainAddr then return nil end
    return sym.nameOf(mem.read32(mainAddr + MAIN_CALLBACK2))
  end

  -- ------------------------------------------------------------- reporting
  function M.describe()
    local mapId = M.mapId() or "?"
    local x, y = M.pos()
    local mon = M.firstHealthy()
    local battle = M.mode() == "battle" and M.battle() or nil
    local parts = { mapId .. "@" .. tostring(x) .. "," .. tostring(y) }
    if mon then
      parts[#parts + 1] = string.format("lead Lv%d %d/%d", mon.level, mon.hp, mon.maxHp)
    else
      parts[#parts + 1] = "no pokemon"
    end
    if battle then
      parts[#parts + 1] = string.format("battle vs Lv%d %d/%d%s",
        battle.enemy.level, battle.enemy.hp, battle.enemy.maxHp,
        battle.wild and " wild" or "")
    end
    return table.concat(parts, " | ")
  end

  M.offsets = {
    S1_LOCATION = S1_LOCATION,
    S1_FLAGS = S1_FLAGS,
    S1_VARS = S1_VARS,
  }

  return M
end
