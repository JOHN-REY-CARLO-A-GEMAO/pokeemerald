#!/usr/bin/env python3
"""
run_tests.py - run the autoplay Lua test-suite.

The bot's logic (pathfinding, walking, route execution, game-state decoding)
runs against tests/mock.lua, a small fake GBA core, so it can be tested here
without a ROM or an emulator.

    pip install lupa
    python3 tools/spectator/tests/run_tests.py
"""

import glob
import os
import sys
import traceback

try:
    import lupa
except ImportError:
    sys.exit("run_tests.py needs lupa:  pip install lupa")

HERE = os.path.abspath(os.path.dirname(__file__))
SPEC_DIR = os.path.abspath(os.path.join(HERE, ".."))


def run_test(path):
    lua = lupa.LuaRuntime(unpack_returned_tuples=True)
    lua.globals().SPEC_DIR = SPEC_DIR
    with open(path) as f:
        source = f.read()
    lua.execute(source)


def run_python_test(path):
    """Run a *_test.py file (checks against the Python tooling)."""
    namespace = {"__name__": "__main__", "__file__": path}
    with open(path) as f:
        code = compile(f.read(), path, "exec")
    exec(code, namespace)


def main():
    tests = sorted(glob.glob(os.path.join(HERE, "test_*.lua")))
    tests += sorted(glob.glob(os.path.join(HERE, "test_*.py")))
    if not tests:
        sys.exit("no tests found")

    failed = 0
    for path in tests:
        name = os.path.basename(path)
        print("== %s" % name)
        try:
            if path.endswith(".py"):
                run_python_test(path)
            else:
                run_test(path)
        except Exception:
            failed += 1
            print("   FAIL")
            traceback.print_exc()
    print("")
    if failed:
        print("%d/%d test file(s) FAILED" % (failed, len(tests)))
        return 1
    print("all %d test file(s) passed" % len(tests))
    return 0


if __name__ == "__main__":
    sys.exit(main())
