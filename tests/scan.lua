-- Tes World Scan: hitung pohon (mateng/tumbuh), floating, blok, isi Display Box, dan cari tabel pohon.
local T = dofile("tests/lib.lua")
local function module(name) return assert(loadfile("src/" .. name .. ".lua"))() end
local Core, Navigation = module("core"), module("navigation")
local SEED, BLOCK, NOW = 41, 40, 1700000000

local function setup(options)
    options = options or {}
    local fake = T.fakeGame()
    local world, items = fake.world, fake.items
    items[SEED].grow = 100
    world.w, world.h, world.fg = 12, 8, {}
    for y = 0, 7 do world.fg[y] = {}; for x = 0, 11 do world.fg[y][x] = 0 end end
    for x = 0, 11 do world.fg[7][x] = 2 end -- lantai dirt
    world.fg[6][1], world.fg[6][2], world.fg[6][3] = SEED, SEED, SEED
    world.fg[6][8] = 1422
    local boxRows = { { BLOCK, 120 } }
    world.displays = { get = function(x, y) if x == 8 and y == 6 then return boxRows end end }
    world.dropList = function()
        return { { uid = 1, id = BLOCK, n = 30, x = 5.5, y = 6.5 }, { uid = 2, id = BLOCK, n = 12, x = 6.5, y = 6.5 },
            { uid = 3, id = 112, n = 7, x = 4.5, y = 6.5 }, { uid = 4, id = SEED, n = 2, x = 8.5, y = 6.5, display = true } }
    end
    -- pohon: 1,6 dan 2,6 mateng; 3,6 tumbuh (sisa 80 detik)
    local planted = { [1] = NOW - 500, [2] = NOW - 100, [3] = NOW - 20 }
    local trees = {}
    for x, p in pairs(planted) do
        if options.layout == "yx" then
            trees[6] = trees[6] or {}
            trees[6][x] = { plantedAt = p, stage = 2 }
        else
            trees[6 * world.w + x] = { p = p }
        end
    end
    -- update 17 Nov: tabel pohon ada di dalam tabel konteks, bukan langsung di upvalue
    fake.meta.up[world.displayPut] = { world, items, { cfg = true, trees = trees } }
    local App = { alive = true, token = 0, pending = 0, configuring = false, logs = {}, discoveryReport = {},
        status = "", profile = "Default", stats = { gems = 0, planted = 0, broken = 0 } }
    local G = { App = App, Core = Core, Navigation = Navigation, exec = fake.exec, accountId = 123, task = T.scheduler().task,
        resumeHandlers = {}, onConnected = {}, env = {} }
    G.registryKey = function() return nil end
    G.serverTime = function() return NOW end
    G.isInstance = function() return false end
    G.frozen = function() return false end
    G.accountOk = function() return true end
    G.focusedTextBox = function() return nil end
    G.setStatus = function(text) App.status = text end
    G.notify = function() end
    G.Net = module("net")(G)
    G.Bridge = module("bridge")(G)
    G.Scan = module("scan")(G)
    App.config = Core.defaults()
    G.Bridge.connect({ attempts = 1 })
    return { G = G, App = App, world = world, trees = trees }
end

print("scan.lua")
T.test("World Scan: pohon mateng/tumbuh dari tabel di dalam tabel konteks (layout Clarissv y*w+x)", function()
    local sim = setup()
    local text = table.concat(sim.G.Scan.run(), "\n")
    T.eq(text:find("Sugar Cane Seed (41): 3 pohon, 2 mateng, 1 tumbuh, semua mateng dalam 1m 20d", 1, true) ~= nil, true, text)
    T.eq(text:find("sidik jari: layout y*w+x, field waktu tanam 'p'", 1, true) ~= nil, true, text)
end)
T.test("World Scan: layout [y][x] dengan nama field lain tetap terbaca", function()
    local sim = setup({ layout = "yx" })
    local text = table.concat(sim.G.Scan.run(), "\n")
    T.eq(text:find("3 pohon, 2 mateng, 1 tumbuh", 1, true) ~= nil, true, text)
    T.eq(text:find("layout [y][x], field waktu tanam 'plantedAt'", 1, true) ~= nil, true, text)
    T.eq(text:find("plantedAt=", 1, true) ~= nil, true, "contoh entri pohon tercatat: " .. text)
end)
T.test("World Scan: floating, blok, Display Box", function()
    local sim = setup()
    local text = table.concat(sim.G.Scan.run(), "\n")
    T.eq(text:find("Sugar Cane (40): 42", 1, true) ~= nil, true, "floating dijumlah: " .. text)
    T.eq(text:find("(1 drop bertanda display tidak dihitung)", 1, true) ~= nil, true, text)
    T.eq(text:find("Dirt (2): 12", 1, true) ~= nil, true, "blok: " .. text)
    T.eq(text:find("8,6: Sugar Cane (40) 120", 1, true) ~= nil, true, "isi box: " .. text)
end)
T.test("World Scan: tabel pohon tidak ada -> status tidak terbaca, alasan dicatat", function()
    local sim = setup()
    for k in pairs(sim.trees) do sim.trees[k] = nil end
    local text = table.concat(sim.G.Scan.run(), "\n")
    T.eq(text:find("3 status tidak terbaca", 1, true) ~= nil, true, text)
    T.eq(text:find("tabel pohon tidak ketemu", 1, true) ~= nil, true, text)
end)

print(string.format("\n%d lolos, %d gagal", T.passed, T.failed))
return T.failed
