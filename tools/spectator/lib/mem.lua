-- mem.lua - thin wrapper around the emulator's memory access
--
-- mGBA exposes emu:read8/16/32(address) on the full GBA bus.  We funnel every
-- read through here so a broken address is reported once, with context,
-- instead of spamming the console every frame.
return function(ctx)
  local M = {}
  local emu = ctx.emu
  local log = ctx.util

  local warned = {}

  local function warnOnce(addr, what)
    local key = what or "read"
    if warned[key] then return end
    warned[key] = true
    log.warn(string.format("memory %s failed at %s (game state not readable yet?)",
                           key, log.hex(addr)))
  end

  local function safe(fn, addr, what)
    local ok, value = pcall(fn, emu, addr)
    if not ok or value == nil then
      warnOnce(addr, what)
      return 0
    end
    return value
  end

  function M.read8(addr)  return safe(emu.read8, addr, "read8") end
  function M.read16(addr) return safe(emu.read16, addr, "read16") end
  function M.read32(addr) return safe(emu.read32, addr, "read32") end

  -- signed variants (s8/s16) for coordinates
  function M.reads8(addr)
    local v = M.read8(addr)
    if v >= 128 then v = v - 256 end
    return v
  end

  function M.reads16(addr)
    local v = M.read16(addr)
    if v >= 32768 then v = v - 65536 end
    return v
  end

  function M.write8(addr, value)  emu:write8(addr, value) end
  function M.write16(addr, value) emu:write16(addr, value) end
  function M.write32(addr, value) emu:write32(addr, value) end

  return M
end
