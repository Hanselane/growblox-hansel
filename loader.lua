-- Growblox Hansel loader v0.4.1. File ini DIBUAT OTOMATIS oleh build.mjs dari loader.template.lua.
-- Cara pakai di executor:
--   loadstring(game:HttpGet("<BASE>loader.lua"))()
local BASE = "https://raw.githubusercontent.com/Hanselane/growblox-hansel/main/"
local RELEASE = "fa7f99fc6311016f264c"
local FILES = {
    main = { path = "releases/fa7f99fc6311016f264c/main.lua", size = 244582, sum = 2457933270 },
    windui = { path = "releases/windui-0e4a423c92d91599087e.lua", size = 1350010, sum = 1511812659 },
}

local env = getgenv and getgenv() or _G
local running = env.GrowbloxHanselApp
if running and running.alive and (running.job or (running.pending or 0) > 0) then
    error("Stop task yang lagi jalan dulu, baru load ulang.", 0)
end

-- Adler-32, harus sama persis dengan versi di build.mjs.
local function adler32(text)
    local a, b = 1, 0
    for i = 1, #text, 4096 do
        local bytes = { text:byte(i, math.min(i + 4095, #text)) }
        for j = 1, #bytes do
            a = (a + bytes[j]) % 65521
            b = (b + a) % 65521
        end
    end
    return b * 65536 + a
end
local function valid(text, file)
    return type(text) == "string" and #text == file.size and adler32(text) == file.sum
end

local CACHE = "GrowbloxHansel/cache/" .. RELEASE
local canCache = type(isfile) == "function" and type(readfile) == "function"
    and type(writefile) == "function" and type(makefolder) == "function" and type(isfolder) == "function"

-- Ambil satu file: dari cache kalau ada dan masih valid, kalau nggak download dari GitHub.
local function fetch(name)
    local file, cached = FILES[name], CACHE .. "/" .. name .. ".lua"
    if canCache and isfile(cached) then
        local text = readfile(cached)
        if valid(text, file) then return text, "cache" end
    end
    local ok, text = pcall(function() return game:HttpGet(BASE .. file.path) end)
    assert(ok, "Download " .. name .. " gagal: " .. tostring(text))
    assert(valid(text, file), "File " .. name .. " hasil download tidak cocok (rusak atau belum ter-update). Coba lagi sebentar.")
    if canCache then
        pcall(function()
            for _, folder in ipairs({ "GrowbloxHansel", "GrowbloxHansel/cache", CACHE }) do
                if not isfolder(folder) then makefolder(folder) end
            end
            writefile(cached, text)
        end)
    end
    return text, "download"
end

-- Download dua file bersamaan, maksimal 45 detik.
local results, finished = {}, 0
for name in pairs(FILES) do
    task.spawn(function()
        results[name] = { pcall(fetch, name) }
        finished = finished + 1
    end)
end
local deadline = os.clock() + 45
while finished < 2 do
    assert(os.clock() < deadline, "Download timeout (45 detik). Cek koneksi lalu coba lagi.")
    task.wait(0.05)
end
for name, result in pairs(results) do
    if not result[1] then error(tostring(result[2]), 0) end
end

local windui, problem = loadstring(results.windui[2], "WindUI")
assert(windui, problem)
env.GrowbloxHanselWindUI = windui()
-- Auto-resume setelah pindah server memakai salinan loader INI (path permanen per versi), bukan
-- main/loader.lua. Path main bisa kena cache GitHub 5 menit dan memuat versi lama.
env.GrowbloxHanselLoaderURL = BASE .. "releases/loader-aad8371e8db69ecd84d0.lua"
env.GrowbloxHanselLoaderDebug = "Rilis " .. RELEASE .. ": main " .. results.main[3] .. ", WindUI " .. results.windui[3]

local chunk
chunk, problem = loadstring(results.main[2], "Growblox Hansel")
assert(chunk, problem)
return chunk()
