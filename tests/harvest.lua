-- Tes Harvest (Fist): panen pohon mateng saja, pungut sambil jalan, simpan ke box, replant.
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
    local fg = {}
    for y = 0, 9 do fg[y] = {}; for x = 0, 17 do fg[y][x] = 0 end end
    for x = 0, 17 do fg[9][x] = DIRT end
    world.name, world.w, world.h, world.fg = "FARM", 18, 10, fg
    fg[8][16] = BOX
    -- pohon x 2..10 di baris 8; ripe[x] = true/false
    local trees, ripe = {}, options.ripe or { [2] = true, [3] = true, [4] = false, [5] = true, [6] = true, [7] = false, [8] = true, [9] = true, [10] = false }
    for x, ready in pairs(ripe) do
        fg[8][x] = SEED
        trees[8 * world.w + x] = { p = ready and NOW - 500 or NOW - 30 }
    end
    fake.meta.up[world.displayPut] = { world, items, { ctx = true, trees = trees } }
    avatar.x, avatar.y, avatar.vx, avatar.vy, avatar.grounded = 13.5, 9, 0, 0, true
    local server = { [18] = 1, [SEED] = options.seeds or 0 }
    inventory.slots = {}
    for id, n in pairs(server) do if n > 0 then table.insert(inventory.slots, { id = id, n = n }) end end
    local drops, nextUid, boxRows = {}, 1, {}
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
        { "harvest", "Harvest" } }) do
        G[pair[2]] = module(pair[1])(G)
    end
    App.config = Core.defaults()
    App.config.harvesting.seedId = SEED
    App.config.harvesting.replant = options.replant or false
    App.config.points.farmBox = { world = "FARM", x = 16, y = 8, standX = 15, standY = 8 }
    G.Bridge.connect({ attempts = 1 })
    local r = App.runtime
    r.handlers.canPlace = function(item, x, y) return world.fg[y][x] == 0 end
    r.handlers.hit = function(x, y)
        if world.fg[y][x] == SEED then
            world.fg[y][x] = 0
            trees[y * world.w + x] = nil
            spawn(BLOCK, 3, x + 0.5, y + 0.5)
            spawn(SEED, 1, x + 0.5, y + 0.4)
        end
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
    return { G = G, S = S, App = App, world = world, server = server, drops = drops, boxRows = boxRows, avatar = avatar }
end
local function waitJob(sim, seconds)
    local stop = sim.S.now + seconds
    while sim.App.job and sim.S.now < stop do sim.S.run(1, 0.025) end
end
local function boxCount(sim, id)
    for _, row in ipairs(sim.boxRows) do if row[1] == id then return row[2] end end
    return 0
end

print("harvest.lua")
T.test("Harvest: cuma pohon mateng yang dipanen, yang tumbuh dibiarkan, hasil masuk box", function()
    local sim = setup()
    sim.G.Jobs.start("harvest")
    waitJob(sim, 400)
    sim.S.restore()
    T.eq(sim.App.lastError, nil, "tanpa error: " .. tostring(sim.App.lastError))
    for _, x in ipairs({ 4, 7, 10 }) do T.eq(sim.world.fg[8][x], SEED, "pohon tumbuh di x " .. x .. " tidak disentuh") end
    for _, x in ipairs({ 2, 3, 5, 6, 8, 9 }) do T.eq(sim.world.fg[8][x], 0, "pohon mateng x " .. x .. " dipanen") end
    T.eq(boxCount(sim, BLOCK), 18, "6 pohon x 3 blok di box")
    T.eq(boxCount(sim, SEED), 6, "seed hasil panen di box")
    T.eq(#sim.drops, 0, "tidak ada drop tertinggal")
    T.eq(sim.App.status:find("Selesai: 6 pohon dipanen", 1, true) ~= nil, true, sim.App.status)
    T.eq(sim.App.status:find("3 pohon masih tumbuh", 1, true) ~= nil, true, sim.App.status)
end)
T.test("Harvest + Replant: tile yang dipanen langsung ditanam lagi pakai seed hasil panen", function()
    local sim = setup({ replant = true })
    sim.G.Jobs.start("harvest")
    waitJob(sim, 400)
    sim.S.restore()
    T.eq(sim.App.lastError, nil, "tanpa error: " .. tostring(sim.App.lastError))
    local replanted = 0
    for _, x in ipairs({ 2, 3, 5, 6, 8, 9 }) do if sim.world.fg[8][x] == SEED then replanted = replanted + 1 end end
    T.eq(replanted >= 5, true, "minimal 5 dari 6 tile ditanam ulang: " .. replanted)
    T.eq(sim.App.status:find("ditanam ulang", 1, true) ~= nil, true, sim.App.status)
    T.eq(boxCount(sim, BLOCK), 18)
end)
T.test("Harvest: belum ada yang mateng -> selesai dengan sisa waktu, tidak memukul apa pun", function()
    local sim = setup({ ripe = { [3] = false, [4] = false } })
    sim.G.Jobs.start("harvest")
    waitJob(sim, 60)
    sim.S.restore()
    T.eq(sim.App.lastError, nil, tostring(sim.App.lastError))
    T.eq(sim.App.status:find("Belum ada pohon mateng", 1, true) ~= nil, true, sim.App.status)
    T.eq(sim.world.fg[8][3], SEED)
end)
T.test("Harvest: tanpa tanaman / box farm -> pesan setup jelas", function()
    local sim = setup()
    sim.App.config.harvesting.seedId = 0
    T.errors(function() sim.G.Jobs.start("harvest") end, "Scan world")
    sim.App.config.harvesting.seedId = SEED
    sim.App.config.points.farmBox = nil
    T.errors(function() sim.G.Jobs.start("harvest") end, "Display Box farm")
    sim.S.restore()
end)
T.test("Keluar world saat Harvest -> masuk lagi ke world farm, scan ulang, lanjut sampai selesai", function()
    local sim = setup()
    local entered = 0
    sim.world.enter = function(name)
        entered = entered + 1
        sim.world.name, sim.avatar.x, sim.avatar.vx = name, 14.5, 0
        return true
    end
    sim.G.Jobs.start("harvest")
    sim.S.run(3, 0.025) -- sebagian pohon sudah dipanen
    sim.world.name = "" -- keluar ke world picker
    waitJob(sim, 400)
    sim.S.restore()
    T.eq(sim.App.lastError, nil, "tanpa error: " .. tostring(sim.App.lastError))
    T.eq(entered, 1, "masuk lagi sekali")
    T.eq(sim.App.harvestRejoins, 1)
    for _, x in ipairs({ 2, 3, 5, 6, 8, 9 }) do T.eq(sim.world.fg[8][x], 0, "pohon mateng x " .. x .. " dipanen") end
    T.eq(boxCount(sim, BLOCK), 18, "semua hasil tetap masuk box")
end)
T.test("Keluar world saat Harvest dengan Rejoin mati -> berhenti", function()
    local sim = setup()
    sim.App.config.options.autoRejoin = false
    sim.world.enter = function() error("tidak boleh masuk") end
    sim.G.Jobs.start("harvest")
    sim.S.run(3, 0.025)
    sim.world.name = ""
    waitJob(sim, 60)
    sim.S.restore()
    T.eq(sim.App.job, nil)
    T.eq((sim.App.lastError or ""):find("world picker", 1, true) ~= nil, true, tostring(sim.App.lastError))
end)
T.test("Resume setelah pindah server: checkpoint Harvest -> masuk world farm dan panen", function()
    local sim = setup()
    local config = Core.validate(sim.App.config)
    sim.G.State.loadCheckpoint = function(name)
        if name == "harvest" then return { config = config, profile = "Default", data = { world = "FARM" } } end
    end
    sim.world.name = "LOBBY"
    sim.world.enter = function(name) sim.world.name, sim.avatar.x, sim.avatar.vx = name, 14.5, 0; return true end
    T.eq(sim.G.resumeHandlers[#sim.G.resumeHandlers](), true)
    waitJob(sim, 400)
    sim.S.restore()
    T.eq(sim.App.lastError, nil, "tanpa error: " .. tostring(sim.App.lastError))
    T.eq(boxCount(sim, BLOCK), 18)
end)
T.test("blockForSeed: seed 41 -> blok 40", function()
    local fake = T.fakeGame()
    T.eq(Core.blockForSeed(fake.items, 41), 40)
end)

print(string.format("\n%d lolos, %d gagal", T.passed, T.failed))
return T.failed
