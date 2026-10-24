-- tests/test_state.lua - decoding of game state from memory
local H = dofile(SPEC_DIR .. "/tests/harness.lua")

local mock = H.mock({ map = "MAP_LITTLEROOT_TOWN", x = 12, y = 12 })
mock.mode = "overworld"
mock:step()

local ctx = H.context(mock)
local state = ctx.state

H.check(state.ready(), "SaveBlock1 pointer resolved")
H.check(state.mode() == "overworld", "mode is overworld")
H.check(ctx.state.callbackName() == "CB2_Overworld", "callback2 resolves by symbol")

local x, y = state.pos()
H.check(x == 12 and y == 12, "player position decoded")

H.check(state.mapId() == "MAP_LITTLEROOT_TOWN", "map decoded from map group/number")
H.check(state.map().w == 20, "map geometry attached")

H.check(state.partyCount() == 1, "party count decoded")
local mon = state.party()[1]
H.check(mon.level == 8 and mon.hp == 30 and mon.maxHp == 30, "party stats decoded")
H.check(not mon.fainted, "healthy mon is not fainted")
H.check(state.firstHealthy() ~= nil, "first healthy mon found")

-- flags and vars -----------------------------------------------------------
local flagId = ctx.constants.flags.FLAG_ADVENTURE_STARTED
H.check(flagId ~= nil, "FLAG_ADVENTURE_STARTED exists in the constant table")
H.check(state.flag(flagId) == false, "flag starts clear")
mock.flags[flagId] = true
mock:step()
H.check(state.flag(flagId) == true, "flag reads back as set")

local varId = ctx.constants.vars.VAR_LITTLEROOT_TOWN_STATE
H.check(varId ~= nil, "VAR_LITTLEROOT_TOWN_STATE exists")
mock.vars[varId] = 3
mock:step()
H.check(state.var(varId) == 3, "story variable reads back")

-- battles -----------------------------------------------------------------
mock:startBattle({ wild = true, hpEnemy = 18, maxHp = 18, level = 3 })
mock:step()
H.check(state.mode() == "battle", "battle detected from gMain.inBattle")
local b = state.battle()
H.check(b ~= nil, "battle struct readable")
H.check(b.wild == true, "wild battle recognised")
H.check(b.enemy.hp == 18 and b.enemy.maxHp == 18 and b.enemy.level == 3,
        "enemy stats decoded")
H.check(b.player.level == 8, "player active mon decoded")
H.check(b.player.moves[1].id == 33, "move slot decoded")

mock.battle.wild = false
mock:step()
H.check(state.battle().wild == false, "trainer battle recognised")

-- a fainted party is reported ---------------------------------------------
mock.battle = nil
mock.mode = "overworld"
mock.party[1].hp = 0
mock:step()
H.check(state.partyFainted(), "fainted party detected")
mock.party[1].hp = 30
mock:step()

local line = state.describe()
H.check(line:find("MAP_LITTLEROOT_TOWN", 1, true) ~= nil,
        "status line mentions the map")

print("test_state: OK")
