-- Tes Place & Break: world palsu dengan server yang memproses place, hit, drop, dan pickup.
local T = dofile("tests/lib.lua")
local function module(name) return assert(loadfile("src/" .. name .. ".lua"))() end
local Core, Navigation = module("core"), module("navigation")

local BLOCK, SEED, DIRT = 40, 41, 2

local function setup(options)
    options = options or {}
    local S = T.scheduler()
    local fake = T.fakeGame()
    local world, avatar, inventory, items = fake.world, fake.avatar, fake.inventory, fake.items
    local fg = {}
    for y = 0, 13 do fg[y] = {}; for x = 0, 19 do fg[y][x] = 0 end end
    for x = 0, 19 do fg[10][x] = DIRT end
    for key, value in pairs(options.extra or {}) do
        local x, y = key:match("(%d+):(%d+)")
        fg[tonumber(y)][tonumber(x)] = value
    end
    world.name, world.w, world.h, world.fg = "PNBW", 20, 14, fg
    avatar.x, avatar.y, avatar.vx, avatar.vy, avatar.grounded = 10.5, 10, 0, 0, true
    local server = { [BLOCK] = options.blocks or 3, [18] = 1 }
    inventory.slots = {}
    for id, n in pairs(server) do table.insert(inventory.slots, { id = id, n = n }) end

    local drops, nextUid, hits = {}, 1, {}
    local function spawn(id, n, x, y) table.insert(drops, { uid = nextUid, id = id, n = n, x = x, y = y, readyAt = 0 }); nextUid = nextUid + 1 end
    for _, d in ipairs(options.floor or {}) do spawn(d.id, d.n, d.x, d.y) end
    world.dropList = function() return drops end
    world.takeDrop = function(uid, want)
        for _, drop in ipairs(drops) do
            if drop.uid == uid then
                if math.abs(drop.x - avatar.x) > 3.2 then return 0 end -- server: kejauhan
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
    world.call = function(method)
        if method == "GetInventory" then
            local slots = {}
            for id, n in pairs(server) do if n > 0 then table.insert(slots, { id, n }) end end
            return { slots = slots, capacity = 16 }
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
    G.json = { encode = function() return "{}" end, decode = function() return {} end }
    for _, name in ipairs({ "net", "state", "bridge", "actions", "movement", "storage", "drops", "jobs" }) do
        local key = name == "net" and "Net" or name == "state" and "State" or name == "bridge" and "Bridge"
            or name == "actions" and "Actions" or name == "movement" and "Movement" or name == "storage" and "Storage"
            or name == "drops" and "Drops" or "Jobs"
        G[key] = module(name)(G)
    end
    G.Pnb = module("pnb")(G)
    App.config = Core.defaults()
    App.config.blockId = BLOCK
    App.config.pnb.tiles = options.tiles or { { dx = -1, dy = -1 }, { dx = 1, dy = -1 } }
    App.config.pnb.autoStock = options.autoStock or false
    if options.stock then App.config.points.stock = options.stock end
    G.Bridge.connect({ attempts = 1 })
    local r = App.runtime
    r.handlers.canPlace = function(item, x, y) return world.fg[y][x] == 0 end
    r.handlers.setTile = function(layer, x, y, id)
        assert(server[id] and server[id] > 0, "place tanpa blok")
        world.fg[y][x] = id
        server[id] = server[id] - 1
    end
    r.handlers.hit = function(x, y)
        local key = x .. ":" .. y
        hits[key] = (hits[key] or 0) + 1
        if hits[key] >= items[world.fg[y][x]].hits then
            hits[key] = nil
            world.fg[y][x] = 0
            spawn(SEED, 1, x + 0.5, y + 0.5) -- tiap blok pecah menjatuhkan 1 seed
        end
    end
    S.task.spawn(function()
        while App.alive do
            local dt = 0.025
            local target = (r.controls.dir() or 0) * 7.2
            if avatar.vx < target then avatar.vx = math.min(target, avatar.vx + 48 * dt)
            elseif avatar.vx > target then avatar.vx = math.max(target, avatar.vx - 48 * dt) end
            avatar.x = math.max(0.3, math.min(world.w - 0.3, avatar.x + avatar.vx * dt))
            S.task.wait(dt)
        end
    end)
    return { G = G, S = S, App = App, world = world, server = server, drops = drops, avatar = avatar }
end

local function waitJob(sim, seconds)
    local stop = sim.S.now + seconds
    while sim.App.job and sim.S.now < stop do sim.S.run(1, 0.025) end
end

print("pnb.lua")
T.test("validatePNBTiles: tolak kotak tengah, di luar 5x5, dan dobel", function()
    T.errors(function() Core.validatePNBTiles({ { dx = 0, dy = 0 } }) end, "tengah")
    T.errors(function() Core.validatePNBTiles({ { dx = 3, dy = 0 } }) end, "5x5")
    T.errors(function() Core.validatePNBTiles({ { dx = 1, dy = 1 }, { dx = 1, dy = 1 } }) end, "dobel")
    T.eq(#Core.validatePNBTiles({ { dx = -2, dy = 2 }, { dx = 2, dy = -2 } }), 2)
end)
T.test("profil lama tanpa bagian pnb tetap terbaca dengan bawaan 1 tile di atas kepala", function()
    local out = Core.validate({ blockId = 40 })
    T.eq(#out.pnb.tiles, 1); T.eq(out.pnb.tiles[1].dy, -1); T.eq(out.pnb.autoStock, false)
end)

T.test("PNB 2 tile: place, pecahkan, pungut seed, berhenti saat blok habis", function()
    local sim = setup({ blocks = 3 })
    sim.G.Jobs.start("pnb")
    waitJob(sim, 120)
    sim.S.restore()
    T.eq(sim.App.job, nil, "selesai")
    T.eq(sim.App.lastError, nil, "tanpa error: " .. tostring(sim.App.lastError))
    T.eq(sim.App.stats.broken, 3, "3 blok dipecah")
    T.eq(sim.server[SEED], 3, "3 seed dipungut")
    T.eq(#sim.drops, 0, "lantai bersih")
    T.eq(sim.App.status:find("blok di tas habis", 1, true) ~= nil, true, sim.App.status)
    T.eq(sim.App.config.points.pnb.x, 10, "posisi PNB = tempat berdiri"); T.eq(sim.App.config.points.pnb.y, 9)
end)

T.test("Auto take stock: ambil blok dari lantai lalu lanjut PNB", function()
    local sim = setup({ blocks = 2, autoStock = true, stock = { world = "PNBW", x = 3, y = 9 },
        floor = { { id = BLOCK, n = 4, x = 3.5, y = 9.5 }, { id = BLOCK, n = 3, x = 3.7, y = 9.5 } } })
    sim.G.Jobs.start("pnb")
    waitJob(sim, 300)
    sim.S.restore()
    T.eq(sim.App.lastError, nil, "tanpa error: " .. tostring(sim.App.lastError))
    T.eq(sim.App.stats.broken, 9, "2 + 7 blok dari stock")
    T.eq(sim.App.status:find("stock blok di lantai habis", 1, true) ~= nil, true, sim.App.status)
    T.eq(math.abs(sim.avatar.x - 10.5) < 0.3, true, "balik ke posisi PNB")
end)

T.test("Karakter terdorong dari spot: jalan balik dan PNB lanjut", function()
    local sim = setup({ blocks = 4 })
    sim.G.Jobs.start("pnb")
    sim.S.run(3, 0.025)
    sim.avatar.x = sim.avatar.x + 1.4 -- didorong 1,4 tile ke kanan
    waitJob(sim, 120)
    sim.S.restore()
    T.eq(sim.App.lastError, nil, "tanpa error: " .. tostring(sim.App.lastError))
    T.eq(sim.App.stats.broken, 4, "semua blok tetap dipecah")
    T.eq((sim.App.pnbRecoveries or 0) >= 1, true, "ada pemulihan")
end)
T.test("Tile yang terisi blok lain dilewati, tile lain tetap jalan", function()
    local sim = setup({ blocks = 2, extra = { ["9:8"] = DIRT } }) -- tile kiri atas sudah ada Dirt
    sim.G.Jobs.start("pnb")
    waitJob(sim, 120)
    sim.S.restore()
    T.eq(sim.App.lastError, nil, "tanpa error: " .. tostring(sim.App.lastError))
    T.eq(sim.App.stats.broken, 2); T.eq(sim.world.fg[8][9], DIRT, "Dirt tidak disentuh")
end)

T.test("Semua tile terhalang: berhenti dengan pesan jelas", function()
    local sim = setup({ blocks = 2, tiles = { { dx = -1, dy = -1 } }, extra = { ["9:8"] = DIRT } })
    sim.G.Jobs.start("pnb")
    waitJob(sim, 60)
    sim.S.restore()
    T.eq((sim.App.lastError or ""):find("terhalang", 1, true) ~= nil, true, tostring(sim.App.lastError))
end)

T.test("Auto drop seed tanpa hasil rekaman: berhenti dengan petunjuk", function()
    local sim = setup({ blocks = 3 })
    sim.App.config.pnb.autoDrop = true
    sim.App.config.points.seedDrop = { world = "PNBW", x = 15, y = 9 }
    sim.App.config.options.seedThreshold = 1
    sim.G.Jobs.start("pnb")
    waitJob(sim, 120)
    sim.S.restore()
    T.eq((sim.App.lastError or ""):find("Rekam aksi drop", 1, true) ~= nil, true, tostring(sim.App.lastError))
end)

T.test("Perekam mencatat panggilan game lalu memulihkan fungsi asli", function()
    local sim = setup()
    local originalCall = sim.world.call
    sim.G.Pnb.record(1)
    sim.world.call("DropItem", SEED, 5)
    sim.world.call("DropItem", SEED, 5)
    sim.S.run(1.5)
    sim.S.restore()
    T.eq(sim.world.call, originalCall, "world.call dipulihkan")
    local text = table.concat(sim.App.recordReport, "\n")
    T.eq(text:find('world.call("DropItem", 41, 5) x2', 1, true) ~= nil, true, text)
end)

T.test("gridText: Y di tengah, # untuk tile terpilih", function()
    local sim = setup()
    sim.S.restore()
    local lines = {}
    for line in sim.G.Pnb.gridText():gmatch("[^\n]+") do table.insert(lines, line) end
    T.eq(#lines, 5); T.eq(lines[3]:find("[Y]", 1, true) ~= nil, true)
    T.eq(lines[2], "[  ] [#] [  ] [#] [  ]", lines[2])
end)

print(string.format("\n%d lolos, %d gagal", T.passed, T.failed))
return T.failed
