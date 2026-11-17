"""Jalankan tes Lua di luar Roblox: python3 tests/run.py (dari folder proyek)."""
import os, sys
from lupa import lua54

os.chdir(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
failed = 0
for name in ["tests/run.lua", "tests/smoke.lua", "tests/loader.lua", "tests/plant.lua", "tests/pnb.lua", "tests/scan.lua", "tests/harvest.lua", "tests/rotation.lua"]:
    print(f"== {name}")
    lua = lua54.LuaRuntime(unpack_returned_tuples=True)
    failed += int(lua.execute(open(name, encoding="utf-8").read()) or 0)
sys.exit(1 if failed else 0)
