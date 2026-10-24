-- battle.lua - what the bot does in a battle.
--
-- Default policy: "FIGHT and take the first move", which is what mashing A
-- does on the battle menu, at a steady rhythm so every text box advances.
-- Deliberately simple and hard to break; lib/runner.lua exposes hooks so a
-- smarter policy (potion / switch / type matchups) can be dropped in.
return function(ctx)
  local M = {}
  local keys, state, log = ctx.keys, ctx.state, ctx.util
  local cfg = ctx.cfg

  -- 2 frames held + 5 released: the game registers a fresh press on each
  -- cycle, so text scrolls quickly without being a literal turbo spam.
  local CYCLE = 7
  local tick = 0
  local inBattle = false
  local battles = 0
  local lastReport = 0
  M.turns = 0

  function M.enter()
    inBattle = true
    battles = battles + 1
    tick = 0
    local info = state.battle()
    if info then
      log.info(string.format(
        "battle #%d: %s Lv%d (%d/%d hp) vs Lv%d (%d/%d hp)",
        battles, info.wild and "wild" or "trainer",
        info.player.level, info.player.hp, info.player.maxHp,
        info.enemy.level, info.enemy.hp, info.enemy.maxHp))
    else
      log.info("battle #" .. battles)
    end
  end

  function M.leave()
    if inBattle then
      keys.release()
      log.info("battle #" .. battles .. " over")
    end
    inBattle = false
  end

  function M.tick(frame)
    tick = tick + 1
    local phase = tick % CYCLE
    if phase <= 2 then
      keys.hold("A")
    else
      keys.release()
    end

    if frame - lastReport > 60 * 10 then
      lastReport = frame
      log.debug("battle: " .. state.describe())
    end
  end

  function M.count()
    return battles
  end

  M.hooks = {
    -- return a button name to press instead of A, or nil to accept the default
    chooseAction = nil,
  }

  return M
end
