#!/usr/bin/env python3
"""
test_symbols.py - checks the linker-map parser in tools/build_symbols.py
against a synthetic .map file shaped like the ones `make` produces.
"""

import os
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.abspath(os.path.join(HERE, "..", "tools")))

import build_symbols  # noqa: E402

SAMPLE_MAP = """\
Archive member included to satisfy reference by file (symbol)

build/src/main.o
                              build/src/agb.o (AgbMain)

Memory Configuration

Linker script and memory map

LOAD build/src/agb.o

.text           0x08000000      0x1c0
                0x08000000                AgbMain
                0x08000040                CB2_Overworld
                0x08000100                CB2_BattleMain
                0x08000180                CB1_Overworld
                0x080001a0                SomeInternalHelper

.bss            0x03005d8c        0x4 build/src/save.o
                0x03005d8c                gSaveBlock1Ptr
                0x03005d90                gSaveBlock2Ptr

.bss            0x030022c0      0x440 build/src/main.o
                0x030022c0                gMain

.bss            0x02024000     0x1000 build/src/battle_main.o
                0x02024000                gBattleMons
                0x020239f8                gBattleTypeFlags

.rodata         0x08200000      0x100 build/src/data.o
                0x08200000                gSomeRomTable

.text           0x08000200       0x40 build/src/save.o
                0x08000200                SaveGame
"""


def test_parse_and_classify():
    with tempfile.TemporaryDirectory() as tmp:
        path = os.path.join(tmp, "pokeemerald.map")
        with open(path, "w") as f:
            f.write(SAMPLE_MAP)

        text = build_symbols.build(path, quiet=True)

        # RAM symbols are exported, ROM data is not
        assert '["gSaveBlock1Ptr"] = 0x03005D8C' in text, "SaveBlock1 pointer missing"
        assert '["gMain"] = 0x030022C0' in text
        assert '["gBattleMons"] = 0x02024000' in text
        assert "gSomeRomTable" not in text, "ROM data should not be in abs"

        # callback symbols: CB1_/CB2_ plus the entry point, nothing else
        assert "CB2_Overworld" in text
        assert "CB2_BattleMain" in text
        assert "CB1_Overworld" in text
        assert "AgbMain" in text
        assert "SomeInternalHelper" not in text, "internal functions should be filtered"

        # the cb table must be address-sorted for the binary search
        addrs = []
        for line in text.splitlines():
            for token in line.split(","):
                token = token.strip()
                if token.startswith("0x") and len(token) == 10:
                    addrs.append(int(token, 16))
        cb_addrs = [a for a in addrs if 0x08000000 <= a < 0x0A000000]
        assert cb_addrs == sorted(cb_addrs), "callback table is not sorted"


def test_roundtrip_into_lua():
    """The generated file must be valid Lua and answer lookups."""
    try:
        import lupa
    except ImportError:
        print("  (skipping lua roundtrip: lupa not installed)")
        return

    with tempfile.TemporaryDirectory() as tmp:
        path = os.path.join(tmp, "pokeemerald.map")
        out = os.path.join(tmp, "symbols.lua")
        with open(path, "w") as f:
            f.write(SAMPLE_MAP)
        with open(out, "w") as f:
            f.write(build_symbols.build(path, quiet=True))

        lua = lupa.LuaRuntime(unpack_returned_tuples=True)
        lua.execute('package.path = package.path')  # no-op, keeps lupa happy
        data = lua.execute("return assert(loadfile(%r))()" % out)
        abs_table = data["abs"]
        assert abs_table["gSaveBlock1Ptr"] == 0x03005D8C
        assert abs_table["gMain"] == 0x030022C0

        # exercise the same binary search sym.lua uses
        cb = data["cb"]
        lua.globals()["cb"] = cb
        name = lua.execute("""
            local function nameOf(addr)
              local lo, hi = 1, math.floor(#cb / 2)
              local best = nil
              while lo <= hi do
                local mid = math.floor((lo + hi) / 2)
                local entry = cb[(mid - 1) * 2 + 1]
                if entry == addr then return cb[(mid - 1) * 2 + 2]
                elseif entry < addr then best = mid; lo = mid + 1
                else hi = mid - 1 end
              end
              if best then return cb[(best - 1) * 2 + 2] end
              return nil
            end
            return nameOf(0x08000040), nameOf(0x08000000), nameOf(0x08000100)
        """)
        assert name == ("CB2_Overworld", "AgbMain", "CB2_BattleMain"), name


def main():
    test_parse_and_classify()
    print("  ok - linker map parsing and classification")
    test_roundtrip_into_lua()
    print("  ok - generated symbols.lua loads and resolves addresses")
    print("test_symbols: OK")


if __name__ == "__main__":
    main()
