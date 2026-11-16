-- loader.lua: paste ini ke executor.
-- Repo kita private, jadi script TIDAK diambil dari GitHub. Taruh dua file ini di folder
-- workspace executor (Delta: folder "workspace"):
--   GrowbloxHansel/main.lua    (hasil build: dist/main.lua)
--   GrowbloxHansel/WindUI.lua  (dari vendor/WindUI.lua)
local PATH = "GrowbloxHansel/main.lua"
assert(type(isfile) == "function" and type(readfile) == "function", "Executor tidak punya isfile/readfile.")
assert(isfile(PATH), "File " .. PATH .. " belum ada di workspace executor.")
local chunk, problem = loadstring(readfile(PATH), "Growblox Hansel")
assert(chunk, problem)
return chunk()
