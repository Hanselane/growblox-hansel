-- Tes Rotation: harvest sampai target blok -> PNB 1 tile samping -> replant -> ulang -> world berikutnya.
local T = dofile("tests/lib.lua")
local function module(name) return assert(loadfile("src/" .. name .. ".lua"))() end
local Core, Navigation = module("core"), module("navigation")
local BLOCK, SEED, DIRT, BOX, NOW = 40, 41, 2, 1422, 1700000000

local function setup(options)
    options = options or {}
    local S = T.scheduler()
    local fake = T.fakeGame()
    local world, avatar, inventory, items = fake.world, fake.avatar, fake.inventory, fake.items
    items[SEED].grow = 100
    items[BOX].solid = false
    -- pohon x 2..10 di baris 8; ripe[x] = true/false
    local trees, grids, boxRows = {}, {}, {}
    local function farm(ripe)
        local grid, list = {}, {}
        for y = 0, 9 do grid[y] = {}; for x = 0, 17 do grid[y][x] = 0 end end
        for x = 0, 17 do grid[9][x] = DIRT end
        grid[8][16] = BOX
        for x, ready in pairs(ripe) do
            grid[8][x] = SEED
            list[8 * 18 + x] = { p = ready and NOW - 500 or NOW - 30 }
        end
        return { fg = grid, trees = list, box = {} }
    end
    local all = {}
    for x = 2, 9 do all[x] = true end
    grids.FARM = farm(options.ripe or all)
    grids.FARM2 = farm(options.ripe2 or { [3] = true, [4] = true, [5] = true })
    local current = "FARM"
    local function load(name)
        current = name
        world.name, world.fg = name, grids[name].fg
        for k in pairs(trees) do trees[k] = nil end
        for k, v in pairs(grids[name].trees) do trees[k] = v end
        boxRows = grids[name].box
    end
    world.w, world.h = 18, 10
    load("FARM")
    grids.FARM.trees = trees
    fake.meta.up[world.displayPut] = { world, items, { ctx = true, trees = trees } }
    avatar.x, avatar.y, avatar.vx, avatar.vy, avatar.grounded = 13.5, 9, 0, 0, true
    local server = { [18] = 1, [SEED] = options.seeds or 0 }
    inventory.slots = {}
    for id, n in pairs(server) do if n > 0 then table.insert(inventory.slots, { id = id, n = n }) end end
    local drops, nextUid = {}, 1
    local function spawn(id, n, x, y) table.insert(drops, { uid = nextUid, id = id, n = n, x = x, y = y, readyAt = 0 }); nextUid = nextUid + 1 end
    world.dropList = function() return drops end
    world.takeDrop = function(uid, want)
        for _, drop in ipairs(drops) do
            if drop.uid == uid then
                if math.abs(drop.x - avatar.x) > 1.3 then return 0 end
                local amount = math.min(drop.n, want)
                server[drop.id] = (server[drop.id] or 0) + amount
                return amount
            end
        end
        return 0
    end
    world.dropTaken = function(uid, remaining)
        for i, drop in ipairs(drops) do
            if drop.uid == uid then drop.n = remaining; if remaining <= 0 then table.remove(drops, i) end; return end
        end
    end
    world.displays = { get = function(x, y) if x == 16 and y == 8 then return boxRows end end }
    world.enter = function(name)
        -- simpan data pohon world lama, muat world baru (tabel pohon yang sama diisi ulang)
        local saved = {}
        for k, v in pairs(trees) do saved[k] = v end
        grids[current].trees = saved
        for i = #drops, 1, -1 do table.remove(drops, i) end
        load(name)
        avatar.x, avatar.vx = 14.5, 0
        return true
    end
    world.call = function(method, x, y, id, _, _, amount)
        if method == "GetInventory" then
            local slots = {}
            for itemId, n in pairs(server) do if n > 0 then table.insert(slots, { itemId, n }) end end
            return { slots = slots, capacity = 16 }
        elseif method == "DisplayItem" and id ~= nil then
            assert(x == 16 and y == 8 and amount > 0 and amount <= (server[id] or 0), "deposit tidak valid")
            server[id] = server[id] - amount
            local found = false
            for _, row in ipairs(boxRows) do if row[1] == id then row[2] = row[2] + amount; found = true end end
            if not found then table.insert(boxRows, { id, amount }) end
            return true, {}
        end
    end
    fake.body.solidAt = function(x, y)
        local item = items[world.fg[y] and world.fg[y][x] or 0]
        return item ~= nil and item.solid == true
    end
    local App = { alive = true, token = 0, pending = 0, configuring = false, logs = {}, discoveryReport = {},
        status = "", profile = "Default", stats = { gems = 0, planted = 0, broken = 0 } }
    local files = {}
    local G = { App = App, task = S.task, Core = Core, Navigation = Navigation, exec = fake.exec, accountId = 123,
        resumeHandlers = {}, onConnected = {}, env = {} }
    G.registryKey = function() return nil end
    G.serverTime = function() return NOW end
    G.isInstance = function() return false end
    G.frozen = function() return false end
    G.accountOk = function() return true end
    G.focusedTextBox = function() return nil end
    G.setStatus = function(text) App.status = text; table.insert(App.logs, text) end
    G.notify = function() end
    G.fs = { isfile = function(p) return files[p] ~= nil end, readfile = function(p) return files[p] end,
        writefile = function(p, t) files[p] = t end, isfolder = function() return true end, makefolder = function() end,
        delfile = function(p) files[p] = nil end }
    G.json = { encode = function() return "{}" end, decode = function() return {} end }
    for _, pair in ipairs({ { "net", "Net" }, { "state", "State" }, { "bridge", "Bridge" }, { "actions", "Actions" },
        { "movement", "Movement" }, { "storage", "Storage" }, { "drops", "Drops" }, { "jobs", "Jobs" }, { "scan", "Scan" },
        { "pnb", "Pnb" }, { "harvest", "Harvest" }, { "rotation", "Rotation" } }) do
        G[pair[2]] = module(pair[1])(G)
    end
    App.config = Core.defaults()
    App.config.rotation.seedId = SEED
    App.config.rotation.blockTarget = options.target or 6
    App.config.rotation.worlds = options.worlds or { "FARM" }
    for _, name in ipairs(App.config.rotation.worlds) do
        App.config.rotation.boxes[name] = { world = name, x = 16, y = 8, standX = 15, standY = 8 }
    end
    G.Bridge.connect({ attempts = 1 })
    local r = App.runtime
    r.handlers.canPlace = function(item, x, y) return world.fg[y][x] == 0 end
    local hits = {}
    r.handlers.hit = function(x, y)
        if world.fg[y][x] == SEED then
            world.fg[y][x] = 0
            trees[y * world.w + x] = nil
            spawn(BLOCK, 3, x + 0.5, y + 0.5)
            spawn(SEED, 1, x + 0.5, y + 0.4)
        elseif world.fg[y][x] == BLOCK then
            local key = x .. ":" .. y
            hits[key] = (hits[key] or 0) + 1
            if hits[key] >= items[BLOCK].hits then
                hits[key] = nil
                world.fg[y][x] = 0
                spawn(SEED, 1, x + 0.5, y + 0.5) -- PNB: tiap blok pecah = 1 seed
            end
        end
    end
    r.handlers.setTile = function(layer, x, y, id)
        assert(server[id] and server[id] > 0, "place tanpa blok")
        world.fg[y][x] = id
        server[id] = server[id] - 1
    end
    r.handlers.plantSeed = function(id, x, y)
        assert((server[id] or 0) > 0, "tanam tanpa seed")
        server[id] = server[id] - 1
        world.fg[y][x] = id
        trees[y * world.w + x] = { p = NOW }
    end
    S.task.spawn(function()
        while App.alive do
            local dt = 0.025
            local target = (r.controls.dir() or 0) * 7.2
            if avatar.vx < target then avatar.vx = math.min(target, avatar.vx + 48 * dt)
            elseif avatar.vx > target then avatar.vx = math.max(target, avatar.vx - 48 * dt) end
            avatar.x = math.max(0.3, math.min(world.w - 0.3, avatar.x + avatar.vx * dt))
            for _, drop in ipairs(drops) do -- pickup bawaan game saat badan menyentuh drop
                if math.abs(drop.x - avatar.x) < 0.6 and not drop.taking then
                    local got = world.takeDrop(drop.uid, drop.n)
                    if got and got > 0 then world.dropTaken(drop.uid, drop.n - got); break end
                end
            end
            S.task.wait(dt)
        end
    end)
    return { G = G, S = S, App = App, world = world, server = server, drops = drops, grids = grids, avatar = avatar }
end

local function boxCount(sim, name, id)
    for _, row in ipairs(sim.grids[name].box) do if row[1] == id then return row[2] end end
    return 0
end
local function runUntil(sim, check, seconds)
    local stop = sim.S.now + seconds
    while sim.App.job and sim.S.now < stop and not check() do sim.S.run(1, 0.025) end
end

print("rotation.lua")
T.test("Rotation 1 world: harvest 6 blok -> PNB samping -> replant, ulang sampai semua pohon mateng habis", function()
    local sim = setup()
    sim.G.Jobs.start("rotation")
    runUntil(sim, function() return (sim.App.rotationLaps or 0) >= 1 end, 900)
    sim.G.Jobs.stop()
    sim.S.run(2, 0.025)
    sim.S.restore()
    T.eq(sim.App.lastError, nil, "tanpa error: " .. tostring(sim.App.lastError))
    for x = 0, 17 do
        if x ~= 16 then T.eq(sim.world.fg[8][x], SEED, "tile x " .. x .. " tertanam (bekas panen + sisa farm)") end
    end
    local report = tostring(sim.App.rotationWorlds and sim.App.rotationWorlds.FARM)
    T.eq(report:find("total dipanen 8, PNB 24 blok, ditanam ulang 9", 1, true) or report:find("total dipanen 8, PNB 24 blok, ditanam ulang 17", 1, true) ~= nil, true, report)
    T.eq(boxCount(sim, "FARM", SEED) > 0, true, "seed sisa masuk box")
    T.eq(sim.server[BLOCK] or 0, 0, "blok habis di-PNB")
    T.eq(boxCount(sim, "FARM", BLOCK), 0, "blok TIDAK pernah disimpan ke box")
end)
T.test("Rotation 2 world: pindah ke world berikutnya, lalu menunggu kalau semua belum mateng", function()
    local sim = setup({ worlds = { "FARM", "FARM2" } })
    sim.G.Jobs.start("rotation")
    runUntil(sim, function() return sim.App.status:find("belum ada pohon mateng", 1, true) ~= nil end, 1500)
    local status = sim.App.status
    sim.G.Jobs.stop()
    sim.S.run(2, 0.025)
    sim.S.restore()
    T.eq(sim.App.lastError, nil, "tanpa error: " .. tostring(sim.App.lastError))
    T.eq(sim.world.name, "FARM2")
    for _, x in ipairs({ 3, 4, 5 }) do T.eq(sim.grids.FARM2.fg[8][x], SEED, "FARM2 x " .. x .. " ditanam ulang") end
    T.eq(tostring(sim.App.rotationWorlds.FARM2):find("total dipanen 3", 1, true) ~= nil, true, tostring(sim.App.rotationWorlds.FARM2))
    T.eq(status:find("belum ada pohon mateng", 1, true) ~= nil, true, status)
end)
T.test("Replant: lubang di baris atas dulu, lalu bekas panen, lalu sisa farm", function()
    local items = T.fakeGame().items
    local fg = {}
    for y = 0, 9 do fg[y] = {}; for x = 0, 9 do fg[y][x] = 0 end end
    for x = 0, 9 do fg[5][x] = DIRT; fg[9][x] = DIRT end -- dua lantai: baris tanam y 4 dan y 8
    for x = 0, 9 do fg[4][x] = SEED; fg[8][x] = SEED end
    fg[4][2], fg[4][7] = 0, 0 -- lubang di baris atas
    fg[8][3], fg[8][4] = 0, 0 -- bekas panen
    fg[8][9] = 0 -- tile kosong lain di baris sekarang
    local sim = setup()
    local r = { world = { w = 10, h = 10, fg = fg }, items = items }
    local order = sim.G.Rotation.replantOrder(r, { { x = 3, y = 8 }, { x = 4, y = 8 } }, 8)
    sim.S.restore()
    local keys = {}
    for _, p in ipairs(order) do table.insert(keys, p.x .. ":" .. p.y) end
    T.eq(table.concat(keys, " "), "2:4 7:4 3:8 4:8 9:8")
end)
T.test("Error di tengah rotasi (pukul gagal sekali) -> ulangi world, tidak berhenti", function()
    local sim = setup()
    local hit, failed = sim.App.runtime.handlers.hit, false
    sim.App.runtime.handlers.hit = function(x, y)
        if not failed and x == 4 then failed = true; error("koneksi putus sesaat") end
        return hit(x, y)
    end
    sim.G.Jobs.start("rotation")
    runUntil(sim, function() return (sim.App.rotationLaps or 0) >= 1 end, 900)
    local job = sim.App.job
    sim.G.Jobs.stop()
    sim.S.run(2, 0.025)
    sim.S.restore()
    T.eq(job, "rotation", "rotasi masih jalan setelah error")
    T.eq(sim.App.rotationRetries, 1)
    T.eq(tostring(sim.App.rotationLastError):find("koneksi putus sesaat", 1, true) ~= nil, true, tostring(sim.App.rotationLastError))
    for x = 2, 9 do T.eq(sim.world.fg[8][x], SEED, "x " .. x .. " tetap selesai ditanam") end
end)
T.test("Resume rotation: lanjut dari world tersimpan", function()
    local sim = setup({ worlds = { "FARM", "FARM2" } })
    local config = Core.validate(sim.App.config)
    sim.G.State.loadCheckpoint = function(name)
        if name == "rotation" then return { config = config, profile = "Default", data = { worldIndex = 2 } } end
    end
    sim.G.Rotation.resume()
    sim.S.run(5, 0.025)
    local world = sim.world.name
    sim.G.Jobs.stop()
    sim.S.run(2, 0.025)
    sim.S.restore()
    T.eq(world, "FARM2", "langsung ke world ke-2")
    T.eq(sim.grids.FARM.fg[8][2], SEED, "FARM belum disentuh (pohon mateng masih ada)")
end)
T.test("Rotation: world tanpa Display Box -> pesan setup jelas", function()
    local sim = setup({ worlds = { "FARM", "FARM2" } })
    sim.App.config.rotation.boxes.FARM2 = nil
    T.errors(function() sim.G.Jobs.start("rotation") end, "FARM2")
    sim.S.restore()
end)
T.test("Profil: rotation tersimpan & tervalidasi", function()
    local out = Core.validate({ rotation = { worlds = { "farm1", "farm2" }, seedId = 41, blockTarget = 180,
        boxes = { farm1 = { x = 1, y = 2, standX = 2, standY = 2 } } } })
    T.eq(out.rotation.worlds[2], "FARM2"); T.eq(out.rotation.boxes.FARM1.x, 1); T.eq(out.rotation.blockTarget, 180)
    T.errors(function() Core.validate({ rotation = { blockTarget = 500 } }) end, "1-200")
end)

print(string.format("\n%d lolos, %d gagal", T.passed, T.failed))
return T.failed
