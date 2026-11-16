-- Jalankan: python3 tests/run.py  (pakai Lua 5.4 lewat lupa, di luar Roblox)
local T = dofile("tests/lib.lua")

local function module(name)
    local chunk = assert(loadfile("src/" .. name .. ".lua"))
    return chunk()
end
local Core = module("core")

-- Rangkai modul dengan G palsu, mirip yang dilakukan main.lua.
local function setup(options)
    options = options or {}
    local S = T.scheduler()
    local game = T.fakeGame(options)
    local App = { alive = true, token = 0, pending = 0, configuring = false, logs = {}, discoveryReport = {},
        status = "", profile = "Default", stats = { gems = 0 } }
    local G = { App = App, task = S.task, Core = Core, exec = game.exec, accountId = 123, VERSION = "test" }
    G.registryKey = function() return nil end
    G.serverTime = function() return 1000 end
    G.isInstance = function() return false end
    G.frozen = function() return false end
    G.accountOk = function() return true end
    G.Net = module("net")(G)
    G.Bridge = module("bridge")(G)
    G.Actions = module("actions")(G)
    App.config = Core.defaults()
    return G, game, S
end

print("core.lua")
T.test("worldName dinormalisasi jadi huruf besar", function() T.eq(Core.worldName("  ndjd "), "NDJD") end)
T.test("worldName menolak format door WORLD:ID", function() T.errors(function() Core.worldName("NDJD:1") end, "Nama world") end)
T.test("validate mengisi setting yang hilang dengan bawaan", function()
    local out = Core.validate({ version = 1, options = { actionTimeout = 12 } })
    T.eq(out.options.actionTimeout, 12, "actionTimeout")
    T.eq(out.options.collectRange, 1.5, "collectRange bawaan")
    T.eq(out.options.autoCollect, false, "autoCollect bawaan")
end)
T.test("validate menolak setting di luar batas", function()
    T.errors(function() Core.validate({ options = { collectRange = 9 } }) end, "collectRange")
end)
T.test("validate menolak box tanpa posisi berdiri", function()
    T.errors(function() Core.validate({ points = { seedBox = { world = "A", x = 1, y = 2 } } }) end, "Posisi berdiri")
end)
T.test("validate menolak world farm dobel", function()
    T.errors(function() Core.validate({ planting = { worlds = { "a", "A" } } }) end, "dobel")
end)
T.test("profil hasil validate bisa divalidasi ulang (idempoten)", function()
    local once = Core.validate({ blockId = 40, points = { pnb = { world = "x", x = 5, y = 9 } } })
    local twice = Core.validate(once)
    T.eq(twice.points.pnb.world, "X"); T.eq(twice.blockId, 40)
end)
T.test("seedId pakai blockId + 1", function()
    T.eq(Core.seedId({ [40] = {}, [41] = { kind = "seed" } }, 40), 41)
end)
T.test("retryable cuma untuk error 'belum siap'", function()
    T.eq(Core.retryable("Could not identify one active Growblox world table (found 0)."), true, "found 0")
    T.eq(Core.retryable("Could not identify one active Growblox world table (found 2)."), false, "found 2")
end)

print("bridge.lua")
T.test("discover menemukan world, avatar, backpack, item, handler", function()
    local G, game, S = setup()
    local r = G.Bridge.discover()
    S.restore()
    T.eq(r.world, game.world, "world"); T.eq(r.body, game.body, "body"); T.eq(r.inventory, game.inventory, "inventory")
    T.eq(r.items, game.items, "items"); T.eq(r.ready, true, "ready")
    T.eq(r.handlers.plantSeed ~= nil, true, "plantSeed")
end)
T.test("connect mencoba lagi saat world belum dimuat (found 0), lalu berhasil", function()
    local G, game, S = setup()
    game.worldCopies = 0
    local retries = 0
    S.task.spawn(function()
        G.Bridge.connect({ attempts = 5, delay = 1, onRetry = function() retries = retries + 1 end })
    end)
    S.run(1.5)               -- percobaan 1 & 2 gagal: world belum ada
    T.eq(G.App.runtime, nil, "belum tersambung")
    game.worldCopies = 1      -- world selesai loading
    S.run(3)
    S.restore()
    T.eq(G.App.runtime ~= nil, true, "tersambung setelah retry")
    T.eq(retries >= 1, true, "ada retry")
end)
T.test("connect TIDAK mengulang kalau world ketemu dua (error beneran)", function()
    local G, game, S = setup()
    game.worldCopies = 2
    local retries = 0
    local ok, err = pcall(G.Bridge.connect, { attempts = 5, delay = 1, onRetry = function() retries = retries + 1 end })
    S.restore()
    T.eq(ok, false, "gagal"); T.eq(retries, 0, "tanpa retry")
    T.eq(tostring(err):find("found 2", 1, true) ~= nil, true, "pesan found 2")
end)
T.test("connect menunggu avatar siap", function()
    local G, game, S = setup({ avatarReady = false })
    S.task.spawn(function() G.Bridge.connect({ attempts = 5, delay = 1 }) end)
    S.run(1.5)
    T.eq(G.App.runtime, nil, "avatar belum siap = belum tersambung")
    game.avatar.active = true
    S.run(3)
    S.restore()
    T.eq(G.App.runtime ~= nil, true, "tersambung setelah avatar siap")
end)
T.test("worldCheck: world salah = stop, world picker = recoverable", function()
    local G, game, S = setup()
    G.Bridge.connect({ attempts = 1 })
    S.restore()
    T.errors(function() G.Bridge.worldCheck("LAIN") end, "World berubah")
    game.world.name = ""
    local ok, err = pcall(G.Bridge.worldCheck, "NDJD")
    T.eq(ok, false); T.eq(type(err) == "table" and err.recoverable, true, "recoverable")
end)

print("actions.lua")
T.test("refreshInventory menyamakan tas lokal dengan server", function()
    local G, game, S = setup()
    G.Bridge.connect({ attempts = 1 })
    game.world.serverSlots = { { 40, 80 }, { 41, 5 } } -- server: 80 cane, 5 seed; tool fist tidak dikirim
    G.Actions.refreshInventory()
    S.restore()
    T.eq(game.inventory:count(40), 80, "cane"); T.eq(game.inventory:count(41), 5, "seed")
    T.eq(game.inventory:count(18), 1, "tool tetap ada")
end)
T.test("farmableBlocks cuma berisi blok yang bisa di-PNB", function()
    local G, game, S = setup()
    G.Bridge.connect({ attempts = 1 })
    local list = G.Actions.farmableBlocks()
    S.restore()
    T.eq(#list, 1, "jumlah"); T.eq(list[1].name, "Sugar Cane")
end)

print("net.lua")
T.test("Stop menghentikan job lewat token", function()
    local G, _, S = setup()
    local token = G.Net.beginJob("pnb")
    G.Net.checkpoint(token) -- masih jalan
    G.Net.stopJob()
    S.restore()
    T.errors(function() G.Net.checkpoint(token) end, "Stopped")
end)
T.test("beginJob ditolak kalau masih ada request pending", function()
    local G, _, S = setup()
    G.App.pending = 1
    S.restore()
    T.errors(function() G.Net.beginJob("pnb") end, "request")
end)

print("state.lua")
T.test("writeJSON aman + session tersimpan dan terbaca lagi", function()
    local G, _, S = setup()
    S.restore()
    local files, folders = {}, {}
    G.fs = { isfile = function(p) return files[p] ~= nil end, readfile = function(p) return files[p] end,
        writefile = function(p, t) files[p] = t end, isfolder = function(p) return folders[p] end,
        makefolder = function(p) folders[p] = true end, delfile = function(p) files[p] = nil end }
    -- JSON palsu: cukup serialisasi tabel Lua.
    local function ser(v)
        if type(v) == "table" then
            local parts = {}
            for k, x in pairs(v) do table.insert(parts, "[" .. ser(k) .. "]=" .. ser(x)) end
            table.sort(parts)
            return "{" .. table.concat(parts, ",") .. "}"
        elseif type(v) == "string" then return string.format("%q", v) end
        return tostring(v)
    end
    G.json = { encode = ser, decode = function(s) return load("return " .. s)() end }
    local State = module("state")(G)
    G.App.config.blockId, G.App.profile = 40, "Farm A"
    T.eq(State.saveSession(), true, "simpan pertama")
    T.eq(State.saveSession(), false, "tanpa perubahan = tidak ditulis ulang")
    T.eq(files["GrowbloxHansel/accounts/123/session.json.pending"], nil, "file .pending dibersihkan")
    G.App.config, G.App.profile = Core.defaults(), "x"
    State.restoreSession()
    T.eq(G.App.config.blockId, 40, "blockId pulih"); T.eq(G.App.profile, "Farm A", "profil pulih")
    State.saveCheckpoint("pnb", { phase = "break" })
    T.eq(State.loadCheckpoint("pnb").data.phase, "break", "checkpoint")
    State.clearCheckpoint("pnb")
    T.eq(State.loadCheckpoint("pnb"), nil, "checkpoint terhapus")
end)

print(string.format("\n%d lolos, %d gagal", T.passed, T.failed))
return T.failed
