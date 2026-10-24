-- walk.lua - executes a tile path by holding the d-pad.
--
-- Movement is verified against the player's real tile coordinates instead of
-- being timed.  The game moves the player at ~1 tile per 16 frames; we hold a
-- direction and advance our step counter whenever the tile actually changes.
-- "Blocked" means the tile did not change for cfg.stuckFrames frames while we
-- were pushing, which covers walls, NPCs stepping in the way and dialogs.
return function(ctx)
  local M = {}
  local state, keys = ctx.state, ctx.keys
  local cfg = ctx.cfg

  local path, index = nil, 1
  local lastX, lastY = nil, nil
  local stuck = 0
  local state_ = "idle"   -- idle | moving | arrived | blocked

  local STUCK_FRAMES = cfg.stuckFrames or 40

  function M.setPath(steps, label)
    path = steps
    index = 1
    stuck = 0
    lastX, lastY = state.pos()
    state_ = (steps and #steps > 0) and "moving" or "arrived"
    M.label = label
    if state_ == "arrived" then keys.release() end
  end

  function M.busy()
    return state_ == "moving"
  end

  function M.result()
    return state_
  end

  function M.cancel()
    path = nil
    index = 1
    state_ = "idle"
    keys.release()
  end

  function M.stepsLeft()
    if not path then return 0 end
    return #path - index + 1
  end

  -- Called every frame while the overworld is active.
  function M.tick()
    if state_ ~= "moving" then return state_ end
    if not path or index > #path then
      state_ = "arrived"
      keys.release()
      return state_
    end

    local x, y = state.pos()
    if not x then return state_ end

    if lastX ~= nil and (x ~= lastX or y ~= lastY) then
      -- one step completed (ledge jumps count as a single step too)
      index = index + 1
      stuck = 0
      lastX, lastY = x, y
      if index > #path then
        state_ = "arrived"
        keys.release()
        return state_
      end
    else
      stuck = stuck + 1
      if stuck > STUCK_FRAMES then
        state_ = "blocked"
        keys.release()
        return state_
      end
    end

    keys.hold(path[index].dir)
    return state_
  end

  -- reset the stuck detector (used after a battle or dialog interruption)
  function M.recover()
    stuck = 0
    lastX, lastY = state.pos()
  end

  return M
end
