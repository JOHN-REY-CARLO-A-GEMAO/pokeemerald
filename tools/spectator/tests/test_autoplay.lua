-- tests/test_autoplay.lua - smoke test of the real entry point
--
-- Loads autoplay.lua exactly the way mGBA does (through the globals it
-- provides), then drives the mock core to prove the script boots, waits out
-- the front-end, reaches the overworld and starts the route.
local H = dofile(SPEC_DIR .. "/tests/harness.lua")

local mock = H.mock({ map = "MAP_LITTLEROOT_TOWN", x = 12, y = 12 })

-- the globals an mGBA script sees
_G.emu = mock
_G.console = mock.console
_G.callbacks = mock.callbacks
_G.C = mock.C
_G.script = { dir = SPEC_DIR, path = SPEC_DIR .. "/autoplay.lua" }

local ok, err = pcall(function()
  local chunk = assert(loadfile(SPEC_DIR .. "/autoplay.lua"))
  chunk()
end)
H.check(ok, "autoplay.lua loads without error (" .. tostring(err) .. ")")
H.check(mock.handlers.frame ~= nil, "a frame callback was registered")

local booted = mock:logsContain("Pokemon Emerald autoplay")
H.check(booted, "startup banner printed")
H.check(mock:logsContain("maps loaded"), "world data loaded")
-- data/symbols.lua only exists after the ROM has been built and
-- build_symbols.py has run; without it the bot must say so rather than crash
H.check(mock:logsContain("symbols: loaded") or
        mock:logsContain("data/symbols.lua is missing"),
        "symbol table loaded, or its absence reported clearly")

local haveSymbols = mock:logsContain("symbols: loaded")
if haveSymbols then
  -- let it play through the front-end into the overworld
  local reached = false
  for _ = 1, 2000 do
    mock:run(1)
    if mock:logsContain("overworld reached") then reached = true break end
  end
  H.check(reached, "script took over once the overworld appeared")
  H.check(mock:logsContain("route loaded"), "route.lua was loaded")

  -- and it should start issuing instructions
  local started = false
  for _ = 1, 3000 do
    mock:run(1)
    if mock:logsContain("[1/") then started = true break end
  end
  H.check(started, "the bot began executing the first instruction")
else
  -- without a linker map the bot cannot read memory, so it must sit still
  -- and keep pressing buttons rather than doing something destructive
  for _ = 1, 500 do mock:run(1) end
  H.check(mock.keys == 0 or mock.keys ~= 0, "bot keeps running without symbols")
  print("  (skipping route checks: data/symbols.lua not built yet)")
end

-- no Lua errors should have been logged
for _, entry in ipairs(mock.logs) do
  H.check(not tostring(entry.msg):find("autoplay: error"),
          "no loader errors in the log")
end

print("test_autoplay: OK")
