-- Tes Planting ujung ke ujung: world palsu dengan fisika jalan sederhana, server palsu untuk tas dan Display Box.
local T = dofile("tests/lib.lua")

local function module(name) return assert(loadfile("src/" .. name .. ".lua"))() end
local Core, Navigation = module("core"), module("navigation")

-- Bangun world datar: lantai Dirt di y = 10, baris tanam di y = 9.
local function grid(width, extra)
    local fg = {}
    for y = 0, 13 do fg[y] = {}; for x = 0, width - 1 do fg[y][x] = 0 end end
    for x = 0, width - 1 do fg[10][x] = 2 end
    for key, value in pairs(extra or {}) do
        local x, y = key:match("(%d+):(%d+)")
        fg[tonumber(y)][tonumber(x)] = value
    end
    return fg
end

local function setup(options)
    options = options or {}
    local S = T.scheduler()
    local fake = T.fakeGame()
    local world, avatar, inventory, items = fake.world, fake.avatar, fake.inventory, fake.items
    local SEED, BOX = 41, 1422
    local grids = {
        STOCK = grid(20, { ["5:9"] = BOX }),
        FARM1 = grid(options.farmWidth or 16, options.farmExtra),
    }
    local boxes = { STOCK = { ["5:9"] = { { SEED, options.boxSeeds or 100 } } } }
    world.name, world.w, world.h, world.fg = "STOCK", 20, 14, grids.STOCK
    avatar.x, avatar.y, avatar.vx, avatar.vy, avatar.grounded = 2.5, 10, 0, 0, true
    local server = { [40] = 50, [18] = 1, [SEED] = options.bagSeeds or 6 }
    inventory.slots = {}
    for id, n in pairs(server) do table.insert(inventory.slots, { id = id, n = n }) end
    world.call = function(method, x, y, id)
        if method == "GetInventory" then
            local slots = {}
            for itemId, n in pairs(server) do if n > 0 then table.insert(slots, { itemId, n }) end end
            return { slots = slots, capacity = 16 }
        elseif method == "DisplayItem" and id == nil then
            local rows = boxes[world.name][x .. ":" .. y]
            local take = math.min(rows[1][2], 200 - (server[SEED] or 0))
            rows[1][2] = rows[1][2] - take
            if rows[1][2] == 0 then table.remove(rows, 1) end
            server[SEED] = (server[SEED] or 0) + take
            return true, { taken = { { SEED, take } } }
        end
    end
    world.displays = { get = function(x, y) return boxes[world.name] and boxes[world.name][x .. ":" .. y] end }
    world.enter = function(name)
        world.name, world.fg = name, grids[name]
        world.w = #grids[name][0] + 1
        avatar.x, avatar.y, avatar.vx = 1.5, 10, 0
        return true
    end
    items[BOX].solid = false
    fake.body.solidAt = function(x, y)
        local item = items[world.fg[y] and world.fg[y][x] or 0]
        return item ~= nil and item.solid == true
    end

    local App = { alive = true, token = 0, pending = 0, configuring = false, logs = {}, discoveryReport = {},
        status = "", profile = "Default", stats = { gems = 0, planted = 0 } }
    local files = {}
    local G = { App = App, task = S.task, Core = Core, Navigation = Navigation, exec = fake.exec, accountId = 123,
        resumeHandlers = {}, onConnected = {}, env = {} }
    G.registryKey = function() return nil end
    G.serverTime = function() return 1000 end
    G.isInstance = function() return false end
    G.frozen = function() return false end
    G.accountOk = function() return true end
    G.focusedTextBox = function() return nil end
    G.setStatus = function(text) App.status = text; table.insert(App.logs, text) end
    G.notify = function() end
    G.fs = { isfile = function(p) return files[p] ~= nil end, readfile = function(p) return files[p] end,
        writefile = function(p, t) files[p] = t end, isfolder = function() return true end, makefolder = function() end,
        delfile = function(p) files[p] = nil end }
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
    G.Net = module("net")(G)
    G.State = module("state")(G)
    G.Bridge = module("bridge")(G)
    G.Actions = module("actions")(G)
    G.Movement = module("movement")(G)
    G.Storage = module("storage")(G)
    G.Jobs = module("jobs")(G)
    G.Plant = module("plant")(G)
    App.config = Core.defaults()
    App.config.planting = { seedId = SEED, storageWorld = "STOCK", worlds = { "FARM1" } }
    App.config.points.plantBox = { world = "STOCK", x = 5, y = 9, standX = 4, standY = 9 }
    G.Bridge.connect({ attempts = 1 })
    local r = App.runtime
    r.handlers.canPlace = function(item, x, y) return options.denied == nil or not options.denied[x] end
    r.handlers.plantSeed = function(id, x, y)
        assert(server[id] and server[id] > 0, "tanam tanpa seed")
        world.fg[y][x] = id
        inventory:remove(id, 1)
        if not (options.serverRejects and options.serverRejects[x]) then server[id] = server[id] - 1
        else S.task.spawn(function() S.task.wait(0.1); world.fg[y][x] = 0 end) end -- server membatalkan
    end

    -- Fisika: kecepatan mendekati arah x 7,2 tile/detik dengan percepatan 48.
    S.task.spawn(function()
        while App.alive do
            local dt = 0.025
            local target = (r.controls.dir() or 0) * 7.2
            local change = 48 * dt
            if avatar.vx < target then avatar.vx = math.min(target, avatar.vx + change)
            elseif avatar.vx > target then avatar.vx = math.max(target, avatar.vx - change) end
            avatar.x = math.max(0.3, math.min(world.w - 0.3, avatar.x + avatar.vx * dt))
            S.task.wait(dt)
        end
    end)
    return { G = G, S = S, App = App, world = world, server = server, boxes = boxes, grids = grids, files = files, SEED = SEED }
end

local function waitJob(sim, seconds)
    local stop = sim.S.now + seconds
    while sim.App.job and sim.S.now < stop do sim.S.run(1, 0.025) end
end

local function planted(sim, y, from, to)
    local n = 0
    for x = from, to do if sim.grids.FARM1[y][x] == sim.SEED then n = n + 1 end end
    return n
end

print("plant.lua")
T.test("farmRows: satu lantai = satu baris, arah ke kanan", function()
    local rows = Core.farmRows({ w = 8, h = 14, fg = grid(8) }, { [0] = { solid = false }, [2] = { solid = true } })
    T.eq(#rows, 1); T.eq(rows[1].y, 9); T.eq(rows[1].left, 0); T.eq(rows[1].right, 7); T.eq(rows[1].direction, 1)
end)
T.test("parseWorlds: rapikan nama, buang duplikat", function()
    local list = Core.parseWorlds(" farm1, FARM2;farm1 ")
    T.eq(#list, 2); T.eq(list[1], "FARM1"); T.eq(list[2], "FARM2")
end)
T.test("checkSetup menolak storage world yang juga farm", function()
    local config = Core.defaults()
    config.planting = { seedId = 41, storageWorld = "A", worlds = { "A" } }
    config.points.plantBox = { world = "A", x = 1, y = 1, standX = 1, standY = 1 }
    T.errors(function() Core.checkSetup(config, "plant", { [41] = { kind = "seed" } }) end, "different")
end)

T.test("Planting penuh: isi ulang seed dari box, tanam seluruh baris, checkpoint dihapus", function()
    local sim = setup({ bagSeeds = 6, boxSeeds = 100, farmWidth = 16 })
    sim.G.Jobs.start("plant")
    waitJob(sim, 300)
    sim.S.restore()
    T.eq(sim.App.job, nil, "job selesai")
    T.eq(sim.App.status:find("Finished planting all configured farms", 1, true) ~= nil, true, "status: " .. sim.App.status)
    T.eq(planted(sim, 9, 0, 15), 16, "semua 16 tile tertanam")
    T.eq(sim.App.stats.planted, 16, "statistik")
    local rows = sim.boxes.STOCK["5:9"]
    local taken = 100 - (rows[1] and rows[1][2] or 0)
    T.eq(taken > 0, true, "seed diambil dari box")
    T.eq(sim.server[sim.SEED], 6 + taken - 16, "seed di tas = awal + ambil - tanam")
    T.eq(sim.G.State.loadCheckpoint("plant"), nil, "checkpoint dihapus")
end)

T.test("Box seed kosong: berhenti dengan pesan, bukan error", function()
    local sim = setup({ bagSeeds = 3, boxSeeds = 0, farmWidth = 10 })
    sim.boxes.STOCK["5:9"] = {}
    sim.G.Jobs.start("plant")
    waitJob(sim, 200)
    sim.S.restore()
    T.eq(sim.App.job, nil, "job berhenti")
    T.eq(sim.App.status:find("seed storage box is empty", 1, true) ~= nil, true, "status: " .. sim.App.status)
    T.eq(planted(sim, 9, 0, 9), 3, "3 seed di tas tertanam")
end)

T.test("Tile yang ditolak server di-skip, sisanya tetap ditanam", function()
    local sim = setup({ bagSeeds = 40, farmWidth = 12, serverRejects = { [6] = true } })
    sim.G.Jobs.start("plant")
    waitJob(sim, 300)
    sim.S.restore()
    T.eq(sim.App.job, nil, "job selesai")
    T.eq(sim.App.lastError, nil, "tanpa error: " .. tostring(sim.App.lastError))
    T.eq(sim.grids.FARM1[9][6], 0, "tile 6 kosong")
    T.eq(planted(sim, 9, 0, 11), 11, "11 tile lain tertanam")
end)

T.test("Tile tanpa izin (canPlace false) dilewati", function()
    local sim = setup({ bagSeeds = 40, farmWidth = 10, denied = { [3] = true, [4] = true } })
    sim.G.Jobs.start("plant")
    waitJob(sim, 300)
    sim.S.restore()
    T.eq(sim.App.lastError, nil, "tanpa error: " .. tostring(sim.App.lastError))
    T.eq(planted(sim, 9, 0, 9), 8, "8 tile tertanam")
end)

T.test("Stop di tengah jalan menghentikan task dan menghapus checkpoint", function()
    local sim = setup({ bagSeeds = 40, farmWidth = 16 })
    sim.G.Jobs.start("plant")
    sim.S.run(4, 0.025)
    T.eq(sim.App.job, "plant", "masih jalan")
    sim.G.Jobs.stop()
    sim.S.run(2, 0.025)
    sim.S.restore()
    T.eq(sim.App.job, nil, "berhenti")
    T.eq(sim.G.State.loadCheckpoint("plant"), nil, "checkpoint dihapus")
end)

T.test("Checkpoint rusak ditolak saat resume", function()
    local sim = setup()
    sim.S.restore()
    sim.G.State.saveCheckpoint("plant", { worldIndex = 9, phase = "farm", skipped = {} })
    T.errors(function() sim.G.Plant.readResume() end, "Invalid saved planting progress")
    sim.G.State.saveCheckpoint("plant", { worldIndex = 1, phase = "pickupPending", skipped = {} })
    T.errors(function() sim.G.Plant.resume() end, "withdrawal was interrupted")
end)

T.test("Resume melanjutkan dari world dan baris yang tersimpan", function()
    local sim = setup({ bagSeeds = 40, farmWidth = 12 })
    for x = 0, 5 do sim.grids.FARM1[9][x] = sim.SEED end -- setengah sudah tertanam sebelumnya
    sim.G.State.saveCheckpoint("plant", { worldIndex = 1, phase = "farm", skipped = {}, deferred = {} })
    sim.G.Plant.resume()
    waitJob(sim, 300)
    sim.S.restore()
    T.eq(sim.App.lastError, nil, "tanpa error: " .. tostring(sim.App.lastError))
    T.eq(planted(sim, 9, 0, 11), 12, "baris penuh")
    T.eq(sim.App.stats.planted, 6, "cuma 6 seed baru")
end)

print(string.format("\n%d lolos, %d gagal", T.passed, T.failed))
return T.failed
