-- util.lua - logging and small helpers
return function(ctx)
  local M = {}

  local LEVELS = { debug = 1, info = 2, warn = 3, error = 4 }
  local minLevel = LEVELS[ctx.cfg.logLevel or "info"] or 2

  local function emit(level, msg)
    if (LEVELS[level] or 2) < minLevel then return end
    local line = "[autoplay] " .. msg
    if level == "error" then
      ctx.console:error(line)
    elseif level == "warn" then
      ctx.console:warn(line)
    else
      ctx.console:log(line)
    end
  end

  M.debug = function(msg) emit("debug", msg) end
  M.info = function(msg) emit("info", msg) end
  M.warn = function(msg) emit("warn", msg) end
  M.error = function(msg) emit("error", msg) end

  -- print regardless of log level (used for the periodic status line)
  M.say = function(msg) ctx.console:log("[autoplay] " .. msg) end

  function M.hex(v)
    if v == nil then return "nil" end
    return string.format("0x%08X", v)
  end

  function M.clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
  end

  function M.round(v)
    return math.floor(v + 0.5)
  end

  local DIRS = {
    up    = { dx = 0, dy = -1 },
    down  = { dx = 0, dy = 1 },
    left  = { dx = -1, dy = 0 },
    right = { dx = 1, dy = 0 },
  }
  M.DIRS = DIRS

  return M
end
