-- sym.lua - symbol table helpers
--
-- tools/build_symbols.py turns pokeemerald.map into data/symbols.lua:
--   { abs = { name = address, ... }, cb = { addr, "name", addr, "name", ... } }
--
-- `abs` is every RAM symbol (so routes can reach globals by name) and `cb`
-- is a flat, address-sorted list of function symbols used to answer "which
-- screen is the game on right now?" by resolving gMain.callback2.
return function(ctx)
  local M = {}
  local data = ctx.symbols or {}
  local abs = data.abs or {}
  local cb = data.cb or {}

  -- name -> address, or nil
  function M.addr(name)
    return abs[name]
  end

  -- first symbol in `set` that exists (handles renamed globals across forks)
  function M.firstAddr(...)
    for _, name in ipairs({ ... }) do
      if abs[name] then return abs[name], name end
    end
    return nil
  end

  -- resolve a function address to its symbol name (binary search)
  function M.nameOf(addr)
    if not addr then return nil end
    local lo, hi = 1, math.floor(#cb / 2)
    local best = nil
    while lo <= hi do
      local mid = math.floor((lo + hi) / 2)
      local entry = cb[(mid - 1) * 2 + 1]
      if entry == addr then
        return cb[(mid - 1) * 2 + 2]
      elseif entry < addr then
        best = mid
        lo = mid + 1
      else
        hi = mid - 1
      end
    end
    -- callback2 sometimes points just past the entry point (thumb +1 or into
    -- a thin wrapper), so fall back to the closest symbol below the address
    if best then
      local symAddr = cb[(best - 1) * 2 + 1]
      if addr - symAddr <= 0x40 then
        return cb[(best - 1) * 2 + 2]
      end
    end
    return nil
  end

  function M.isLoaded()
    return next(abs) ~= nil
  end

  return M
end
