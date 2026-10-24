-- keys.lua - button input.
--
-- mGBA's C.GBA_KEY values are bit *indices* (A = 0, B = 1, ...), while
-- setKeys() takes a bitmask, so every button is 1 << index.
return function(ctx)
  local M = {}

  local GBA_KEY = (C and C.GBA_KEY) or {
    A = 0, B = 1, SELECT = 2, START = 3,
    RIGHT = 4, LEFT = 5, UP = 6, DOWN = 7, R = 8, L = 9,
  }

  M.BUTTONS = GBA_KEY
  M.maskOf = {}
  for name, index in pairs(GBA_KEY) do
    M.maskOf[name] = 1 << index
  end

  local current = 0

  function M.set(mask)
    current = mask or 0
    ctx.emu:setKeys(current)
  end

  -- direction names coming from the pathfinder are lowercase ("up"), while
  -- button names are conventionally uppercase ("A"), so accept both
  function M.hold(name)
    if not name then M.set(0) return end
    M.set(M.maskOf[name] or M.maskOf[name:upper()] or 0)
  end

  function M.holdMask(mask)
    M.set(mask)
  end

  function M.release()
    M.set(0)
  end

  function M.current()
    return current
  end

  -- A "tap" is only registered by the game when the button is newly pressed,
  -- so callers must hold for a couple of frames and release for a few.
  local tapButton, tapFramesLeft = nil, 0
  function M.tap(name, frames)
    tapButton = name
    tapFramesLeft = (frames or 2) + 3
  end

  function M.tapPending()
    return tapButton ~= nil
  end

  function M.tickTap()
    if not tapButton then return false end
    tapFramesLeft = tapFramesLeft - 1
    if tapFramesLeft <= 0 then
      tapButton = nil
      M.set(0)
    else
      M.hold(tapButton)
    end
    return true
  end

  return M
end
