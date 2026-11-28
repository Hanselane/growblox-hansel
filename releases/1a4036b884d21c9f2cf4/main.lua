-- Growblox Hansel v0.7.3. File ini HASIL BUILD; edit src/, lalu jalankan: node build.mjs
local __VERSION = "0.7.3"
local __modules = {}

-- ===== src/core.lua =====
__modules["core"] = (function(...)
-- core.lua: logika MURNI. Tidak menyentuh game, file, atau UI, jadi bisa dites di luar Roblox.
-- Banyak fungsi diadaptasi dari Claris Growblox Autofarm (Clarissv), core.lua.
local Core = {}

Core.CONFIG_VERSION = 1
Core.POINTS = { "pnb", "blockBox", "seedBox", "farmBox", "plantBox", "stock", "seedDrop" }
-- Titik yang berupa TEMPAT BERDIRI (bukan box), jadi tidak butuh standX/standY.
Core.STAND_POINTS = { pnb = true }
Core.COLLECT_FILTERS = { "all", "gems", "crop" }

-- Angka yang boleh diatur user: { minimum, maksimum, bawaan }.
Core.LIMITS = {
    placeDelay = { 0.15, 2, 0.2 }, punchDelay = { 0.22, 2, 0.24 },
    collectDelay = { 0, 5, 0.1 }, actionTimeout = { 5, 30, 10 },
    moveTimeout = { 5, 90, 30 }, seedThreshold = { 1, 200, 200 },
    collectRange = { 0.5, 5, 2 },
}
Core.BOOLS = { antiAFK = true, autoRejoin = true, autoCollect = false, autoReconnect = true, respawnStore = true, fastHarvest = true, autoUpdate = true }

local function finite(n)
    return type(n) == "number" and n == n and math.abs(n) < math.huge -- n == n menolak NaN
end
local function integer(n, min, max)
    return finite(n) and n == math.floor(n) and n >= min and n <= max
end
Core.finite, Core.integer = finite, integer

function Core.defaults()
    local options = { collectFilter = "all" }
    for key, limit in pairs(Core.LIMITS) do options[key] = limit[3] end
    for key, value in pairs(Core.BOOLS) do options[key] = value end
    return {
        version = Core.CONFIG_VERSION, blockId = 0, points = {}, options = options,
        planting = { seedId = 0, storageWorld = "", worlds = {} },
        harvesting = { method = "fist", seedId = 0, replant = false, worlds = {} },
        -- Rotation: list world farm sendiri (terpisah dari Planting), Display Box per world.
        rotation = { worlds = {}, seedId = 0, blockTarget = 180, boxes = {}, seedLimit = 190, seedStore = 100 },
        -- PNB: tiles = kotak yang di-place & break, relatif ke posisi berdiri (dx kanan, dy bawah).
        pnb = { tiles = { { dx = 0, dy = -1 } }, autoStock = false, autoDrop = false },
    }
end

-- Validasi daftar tile PNB: dalam kotak 5x5 (dx, dy -2..2), bukan kotak tengah, tanpa duplikat.
function Core.validatePNBTiles(tiles)
    assert(type(tiles) == "table", "Daftar tile PNB rusak.")
    local out, seen = {}, {}
    for index, tile in ipairs(tiles) do
        assert(type(tile) == "table" and integer(tile.dx, -2, 2) and integer(tile.dy, -2, 2), "Tile PNB di luar kotak 5x5.")
        assert(not (tile.dx == 0 and tile.dy == 0), "Kotak tengah adalah posisi karakter.")
        local key = tile.dx .. ":" .. tile.dy
        assert(not seen[key], "Tile PNB dobel: " .. key)
        seen[key] = true
        out[index] = { dx = tile.dx, dy = tile.dy }
    end
    return out
end
-- Urutan tile tetap (atas ke bawah, kiri ke kanan) supaya place/break selalu dengan urutan sama.
function Core.sortPNBTiles(tiles)
    table.sort(tiles, function(a, b) return a.dy < b.dy or a.dy == b.dy and a.dx < b.dx end)
    return tiles
end

function Core.worldName(value)
    assert(type(value) == "string", "Isi nama world.")
    local name = value:match("^%s*(.-)%s*$"):upper()
    assert(#name > 0 and #name <= 48 and name:match("^[%w_%-]+$"),
        "Nama world 1-48 karakter: huruf, angka, _ atau -.")
    return name
end

function Core.profileName(value)
    assert(type(value) == "string", "Isi nama profil.")
    local name = value:match("^%s*(.-)%s*$")
    assert(#name > 0 and #name <= 48 and name:match("^[%w _%-]+$"),
        "Nama profil 1-48 karakter: huruf, angka, spasi, _ atau -.")
    return name
end

-- Beda dari Clarissv: key yang HILANG diisi nilai bawaan, bukan ditolak.
-- Jadi profil lama tetap bisa dibaca walaupun nanti kita nambah setting baru.
-- Key yang ADA tapi isinya salah tetap ditolak.
function Core.validate(input)
    assert(type(input) == "table", "Profil rusak.")
    assert(input.version == nil or input.version == Core.CONFIG_VERSION, "Versi profil tidak didukung.")
    local out = Core.defaults()

    if input.blockId ~= nil then
        assert(integer(input.blockId, 0, 65535), "ID blok di profil tidak valid.")
        out.blockId = input.blockId
    end

    local options = input.options or {}
    assert(type(options) == "table", "Bagian options di profil rusak.")
    for key, limit in pairs(Core.LIMITS) do
        local value = options[key]
        if value ~= nil then
            assert(finite(value) and value >= limit[1] and value <= limit[2], "Setting tidak valid: " .. key)
            if key == "seedThreshold" then assert(value == math.floor(value), "seedThreshold harus bilangan bulat.") end
            out.options[key] = value
        end
    end
    for key in pairs(Core.BOOLS) do
        if options[key] ~= nil then
            assert(type(options[key]) == "boolean", "Setting tidak valid: " .. key)
            out.options[key] = options[key]
        end
    end
    if options.collectFilter ~= nil then
        local ok = false
        for _, name in ipairs(Core.COLLECT_FILTERS) do if options.collectFilter == name then ok = true end end
        assert(ok, "Filter auto collect tidak valid.")
        out.options.collectFilter = options.collectFilter
    end

    local points = input.points or {}
    assert(type(points) == "table", "Bagian points di profil rusak.")
    for _, key in ipairs(Core.POINTS) do
        local point = points[key]
        -- stock/seedDrop versi lama = titik lantai tanpa box; dibuang, set ulang di samping Display Box.
        if (key == "seedDrop" or key == "stock") and type(point) == "table" and point.standX == nil then point = nil end
        if point ~= nil then
            assert(type(point) == "table", "Titik tersimpan rusak: " .. key)
            local copy = { world = Core.worldName(point.world) }
            assert(integer(point.x, 0, 65535) and integer(point.y, 0, 65535), "Tile tidak valid: " .. key)
            copy.x, copy.y = point.x, point.y
            if not Core.STAND_POINTS[key] then -- box butuh posisi berdiri di depannya
                assert(integer(point.standX, 0, 65535) and integer(point.standY, 0, 65535),
                    "Posisi berdiri hilang: " .. key)
                copy.standX, copy.standY = point.standX, point.standY
            end
            out.points[key] = copy
        end
    end

    if input.planting ~= nil then
        local planting = input.planting
        assert(type(planting) == "table", "Bagian planting di profil rusak.")
        out.planting = Core.validatePlanting({ seedId = planting.seedId or 0,
            storageWorld = planting.storageWorld or "", worlds = planting.worlds or {} })
    end

    if input.pnb ~= nil then
        assert(type(input.pnb) == "table", "Bagian pnb di profil rusak.")
        if input.pnb.tiles ~= nil then out.pnb.tiles = Core.validatePNBTiles(input.pnb.tiles) end
        for _, key in ipairs({ "autoStock", "autoDrop" }) do
            if input.pnb[key] ~= nil then
                assert(type(input.pnb[key]) == "boolean", "Setting PNB tidak valid: " .. key)
                out.pnb[key] = input.pnb[key]
            end
        end
    end

    local harvesting = input.harvesting or {}
    if harvesting.method ~= nil then
        assert(harvesting.method == "fist" or harvesting.method == "tractor", "Cara panen tidak valid.")
        out.harvesting.method = harvesting.method
    end
    if harvesting.seedId ~= nil then
        assert(integer(harvesting.seedId, 0, 1000000), "Seed panen tidak valid.")
        out.harvesting.seedId = harvesting.seedId
    end
    if input.rotation ~= nil then
        local rot = input.rotation
        assert(type(rot) == "table", "Bagian rotation di profil rusak.")
        if rot.worlds ~= nil then
            assert(type(rot.worlds) == "table", "List world rotasi rusak.")
            local seen = {}
            for index, value in ipairs(rot.worlds) do
                local name = Core.worldName(value)
                assert(not seen[name], "World rotasi dobel: " .. name)
                seen[name], out.rotation.worlds[index] = true, name
            end
            assert(#out.rotation.worlds <= 50, "Maksimal 50 world rotasi.")
        end
        if rot.seedId ~= nil then
            assert(integer(rot.seedId, 0, 1000000), "Seed rotasi tidak valid.")
            out.rotation.seedId = rot.seedId
        end
        if rot.blockTarget ~= nil then
            assert(integer(rot.blockTarget, 1, 200), "Target blok rotasi 1-200.")
            out.rotation.blockTarget = rot.blockTarget
        end
        if rot.seedLimit ~= nil then
            assert(integer(rot.seedLimit, 1, 200), "Batas seed rotasi 1-200.")
            out.rotation.seedLimit = rot.seedLimit
        end
        if rot.seedStore ~= nil then
            assert(integer(rot.seedStore, 1, 200), "Jumlah seed disimpan 1-200.")
            out.rotation.seedStore = rot.seedStore
        end
        if rot.boxes ~= nil then
            assert(type(rot.boxes) == "table", "Display Box rotasi rusak.")
            for name, point in pairs(rot.boxes) do
                name = Core.worldName(name)
                assert(type(point) == "table" and integer(point.x, 0, 65535) and integer(point.y, 0, 65535)
                    and integer(point.standX, 0, 65535) and integer(point.standY, 0, 65535), "Display Box rotasi rusak: " .. name)
                out.rotation.boxes[name] = { world = name, x = point.x, y = point.y, standX = point.standX, standY = point.standY }
            end
        end
    end
    if harvesting.worlds ~= nil then
        assert(type(harvesting.worlds) == "table", "List world harvest rusak.")
        local seen = {}
        for index, value in ipairs(harvesting.worlds) do
            local name = Core.worldName(value)
            assert(not seen[name], "World harvest dobel: " .. name)
            seen[name], out.harvesting.worlds[index] = true, name
        end
        assert(#out.harvesting.worlds <= 50, "Maksimal 50 world harvest.")
    end
    if harvesting.replant ~= nil then
        assert(type(harvesting.replant) == "boolean", "Setting replant tidak valid.")
        out.harvesting.replant = harvesting.replant
    end
    return out
end

-- Seed dari sebuah blok. Growblox: seedId tertulis di definisi item, atau blockId + 1.
-- Kebalikan seedId: blok hasil panen dari sebuah seed (biasanya id seed - 1).
function Core.blockForSeed(items, seedId)
    for _, id in ipairs({ seedId - 1 }) do
        local ok, seed = pcall(Core.seedId, items, id)
        if ok and seed == seedId then return id end
    end
    for id, item in pairs(items) do
        if type(id) == "number" and item.kind ~= "seed" then
            local ok, seed = pcall(Core.seedId, items, id)
            if ok and seed == seedId then return id end
        end
    end
    error("Blok hasil panen untuk seed " .. tostring(seedId) .. " tidak ditemukan.")
end

function Core.seedId(items, blockId)
    local item = items[blockId]
    assert(item, "Blok yang dipilih tidak ada di data game.")
    local id = item.seedId or blockId + 1
    assert(items[id] and items[id].kind == "seed", "Blok ini tidak punya seed.")
    return id
end

-- Blok yang bisa di-PNB: blok biasa yang punya hit, bukan background/lock/door/display.
function Core.farmable(item)
    return type(item) == "table" and (item.kind == nil or item.kind == "block") and not item.background
        and not item.lock and not item.area and not item.display and not item.displayOne
        and not item.entrance and not item.door and not item.idOnly and not item.vip
        and type(item.hits) == "number" and item.hits > 0
end

-- Pesan error "belum siap" boleh dicoba lagi. Error lain berarti ada yang salah, jadi berhenti.
-- Dipakai bridge.connect buat memperbaiki bug Clarissv (connect cuma dicoba sekali).
Core.RETRYABLE = {
    "found 0",                -- world belum dimuat (loading / world picker)
    "character is not ready", -- avatar belum muncul
    "world picker",
}
function Core.retryable(message)
    message = tostring(message)
    for _, pattern in ipairs(Core.RETRYABLE) do
        if message:find(pattern, 1, true) then return true end
    end
    return false
end

---------------------------------------------------------------- planting
-- Bagian di bawah ini disalin dari Clarissv core.lua v0.1.43 (parseWorlds, validatePlanting,
-- storageCount, itemCount, plantingTile, farmRows, plantingTiles, rowHasPlantingSpace, checkSetup).

-- "FARM1, farm2; FARM3" -> { "FARM1", "FARM2", "FARM3" }. Duplikat dibuang, urutan dijaga.
function Core.parseWorlds(value)
    assert(type(value) == "string", "Enter farm worlds separated by commas.")
    local worlds, seen = {}, {}
    for part in value:gmatch("[^,;\r\n]+") do
        if part:match("%S") then
            local name = Core.worldName(part)
            if not seen[name] then table.insert(worlds, name); seen[name] = true end
        end
    end
    assert(#worlds <= 50, "Use at most 50 farm worlds.")
    return worlds
end

function Core.validatePlanting(input)
    if input == nil then return Core.defaults().planting end
    assert(type(input) == "table" and integer(input.seedId, 0, 65535)
        and type(input.storageWorld) == "string" and type(input.worlds) == "table", "Invalid planting settings.")
    local out = { seedId = input.seedId, storageWorld = input.storageWorld == "" and "" or Core.worldName(input.storageWorld), worlds = {} }
    local seen = {}
    for index, value in pairs(input.worlds) do
        assert(integer(index, 1, #input.worlds), "Invalid farm world list.")
        local name = Core.worldName(value)
        assert(not seen[name], "Duplicate farm world: " .. name)
        seen[name], out.worlds[index] = true, name
    end
    assert(#out.worlds <= 50, "Use at most 50 farm worlds.")
    return out
end

-- Isi Display Box: baris { itemId, jumlah }. Box wajib khusus satu item (plus companion).
function Core.storageCount(rows, itemId, companionId)
    local total = 0
    for _, row in pairs(rows or {}) do
        assert(type(row) == "table" and (row[1] == itemId or (companionId ~= nil and row[1] == companionId)),
            "This storage box contains a different item. Use a box dedicated to the selected item.")
        assert(integer(row[2], 0, 4294967295), "Invalid storage count.")
        if row[1] == itemId then total = total + row[2] end
    end
    return total
end

function Core.itemCount(rows, itemId)
    assert(type(rows) == "table", "Display contents are unavailable.")
    local total = 0
    for _, row in pairs(rows) do
        assert(type(row) == "table" and integer(row[1], 0, 65535)
            and integer(row[2], 0, 4294967295), "Invalid display contents.")
        if row[1] == itemId then total = total + row[2] end
    end
    return total
end

-- Tile bisa ditanam: kosong, dan tile di bawahnya padat atau platform.
function Core.plantingTile(world, items, x, y)
    if x < 0 or x >= world.w or y < 0 or y >= world.h - 1 then return false end
    if not world.fg[y] or world.fg[y][x] ~= 0 then return false end
    local below = items[world.fg[y + 1] and world.fg[y + 1][x] or 0]
    return below ~= nil and (below.solid == true or below.platform == true)
end

-- Baris farm = deretan tile berpijak di y yang sama. Kalau ada >= 2 baris selebar >= 3 tile,
-- baris pendek (box, batu pijakan) diabaikan. Arah zigzag: baris ganjil kanan, genap kiri.
function Core.farmRows(world, items)
    local rows = {}
    for y = 0, world.h - 2 do
        local row = { y = y, count = 0 }
        for x = 0, world.w - 1 do
            local below = items[world.fg[y + 1] and world.fg[y + 1][x] or 0]
            if below and (below.solid == true or below.platform == true) then
                local tile = items[world.fg[y] and world.fg[y][x] or 0]
                if not tile or not tile.solid or tile.kind == "seed" then
                    row.left, row.right, row.count = row.left or x, x, row.count + 1
                end
            end
        end
        if row.count > 0 then table.insert(rows, row) end
    end
    local wide = {}
    for _, row in ipairs(rows) do if row.count >= 3 then table.insert(wide, row) end end
    if #wide >= 2 then rows = wide end
    for index, row in ipairs(rows) do row.direction = index % 2 == 1 and 1 or -1 end
    return rows
end

function Core.plantingTiles(world, items, rows)
    local tiles = {}
    for index, row in ipairs(rows or Core.farmRows(world, items)) do
        local direction = index % 2 == 1 and 1 or -1
        local first, last = direction == 1 and row.left or row.right, direction == 1 and row.right or row.left
        for x = first, last, direction do
            if Core.plantingTile(world, items, x, row.y) then table.insert(tiles, { x = x, y = row.y }) end
        end
    end
    return tiles
end

function Core.rowHasPlantingSpace(world, items, row, skipped)
    for x = row.left, row.right do
        if not (skipped and skipped[x .. ":" .. row.y]) and Core.plantingTile(world, items, x, row.y) then return true end
    end
    return false
end

-- Syarat sebelum task boleh mulai. Mode lain ditambah bareng fiturnya.
function Core.checkSetup(config, mode, items)
    if mode == "rotation" then
        assert(#config.rotation.worlds > 0, "Isi list world farm rotasi.")
        return true
    end
    if mode == "harvest" then
        assert(#config.harvesting.worlds > 0, "Isi list world harvest.")
        return true
    end
    if mode == "plant" then
        local p = Core.validatePlanting(config.planting)
        assert(items[p.seedId] and items[p.seedId].kind == "seed", "Choose a seed on the Planting tab.")
        assert(p.storageWorld ~= "" and config.points.plantBox, "Save the planting seed Display Box and storage world first.")
        assert(config.points.plantBox.world:upper() == p.storageWorld, "The saved seed Display Box must be in the entered storage world.")
        assert(#p.worlds > 0, "Enter at least one dirt farm world.")
        return true
    end
    if mode == "pnb" then
        assert(config.blockId > 0 and Core.farmable(items[config.blockId]), "Pilih blok yang bisa di-PNB.")
        assert(#config.pnb.tiles > 0, "Pilih minimal satu tile PNB.")
        local spot = config.points.pnb
        assert(spot, "Posisi PNB belum ada.")
        for _, key in ipairs({ "stock", "seedDrop" }) do
            local point = config.points[key]
            assert(not point or point.world == spot.world, "Posisi " .. key .. " harus di world yang sama dengan PNB.")
        end
        if config.pnb.autoStock then assert(config.points.stock, "Set stock position (berdiri di samping Display Box) dulu, atau matikan Auto take stock.") end
        if config.pnb.autoDrop then assert(config.points.seedDrop, "Set seed drop position (berdiri di samping Display Box) dulu, atau matikan Auto drop seed.") end
        return true
    end
    error("Unknown farming task: " .. tostring(mode))
end

return Core

end)()

-- ===== src/navigation.lua =====
__modules["navigation"] = (function(...)
-- navigation.lua: perencana rute jalan/lompat 2D. Logika murni, tidak menyentuh game.
-- Disalin utuh dari Clarissv src/navigation.lua (v0.1.43).
-- Pure 2D walking/jumping planner. Coordinates use the game's downward Y axis.
local Navigation = {}

function Navigation.steer(dx, vx, braking)
    if math.abs(dx) < 0.06 then return 0 end
    if vx * dx > 0 and math.abs(dx) <= vx * vx / (2 * (braking or 17)) + 0.04 then return 0 end
    return dx > 0 and 1 or -1
end

function Navigation.dropSteer(state, step)
    local target = step.x + 0.5
    if state.y <= step.fromY + 1.02 then
        target = step.outsideX
        local side = step.outsideX > step.fromX + 0.5 and 1 or -1
        -- Leave the edge slowly enough to reverse in the air before the next row.
        if (state.vx or 0) * side > 1.4 then return 0 end
    end
    return Navigation.steer(target - state.x, state.vx or 0, state.grounded and 48 or 17)
end

function Navigation.straightRuns(route)
    local runs = {}
    for _, step in ipairs(route) do
        local last = runs[#runs]
        local direction = step.x - step.fromX
        if last and not last.jump and not step.jump and not last.drop and not step.drop and step.y == step.fromY
            and last.y == last.fromY and last.y == step.y and last.x == step.fromX
            and last.x - last.fromX == direction * #last.edges
            and math.abs(direction) == 1 then
            last.x, last.duration = step.x, last.duration + step.duration
            table.insert(last.edges, step)
        else
            table.insert(runs, {x = step.x, y = step.y, fromX = step.fromX, fromY = step.fromY,
                jump = step.jump, drop = step.drop, outsideX = step.outsideX, duration = step.duration, edges = {step}})
        end
    end
    return runs
end

function Navigation.rowEnd(map, start, direction)
    local x = start.x
    while true do
        local nextX = x + direction
        if nextX < 0 or nextX >= map.w or map.solid(nextX, start.y)
            or map.danger and (map.danger(nextX, start.y) or map.danger(nextX, start.y + 1))
            or not (map.solid(nextX, start.y + 1) or map.platform and map.platform(nextX, start.y + 1)) then break end
        x = nextX
    end
    return x
end

function Navigation.plan(map, start, goal, options)
    options = options or {}
    local speed, gravity = map.speed or 7.2, map.gravity or 55
    local jumpSpeed = map.jumpSpeed or 19.8997487421324
    local minX = math.max(0, math.min(start.x, goal.x) - 12)
    local maxX = math.min(map.w - 1, math.max(start.x, goal.x) + 12)
    local minY = math.max(0, math.min(start.y, goal.y) - 5)
    local maxY = math.min(map.h - 2, math.max(start.y, goal.y) + 12)
    if options.fullWorld then minX, maxX, minY, maxY = 0, map.w - 1, 0, map.h - 2 end
    local solids, supports, stands = {}, {}, {}
    local function key(x, y) return y * map.w + x end
    local function solid(x, y)
        if x < 0 or x >= map.w or y >= map.h then return true end
        if y < 0 then return false end
        local k = key(x, y)
        if solids[k] == nil then solids[k] = map.solid(x, y) and true or false end
        return solids[k]
    end
    local function danger(x, y) return map.danger and map.danger(x, y) end
    local function support(x, y)
        if x < 0 or x >= map.w or y < 0 or y >= map.h then return false end
        local k = key(x, y)
        if supports[k] == nil then
            supports[k] = not danger(x, y) and (solid(x, y) or (map.platform and map.platform(x, y))) and true or false
        end
        return supports[k]
    end
    local function fits(x, feet)
        for tx = math.floor(x - 0.299), math.floor(x + 0.299) do
            for ty = math.floor(feet - 0.949), math.floor(feet - 0.002) do
                if solid(tx, ty) or danger(tx, ty) then return false end
            end
        end
        return true
    end
    local function standable(x, y)
        if x < minX or x > maxX or y < minY or y > maxY then return false end
        local k = key(x, y)
        if stands[k] == nil then stands[k] = fits(x + 0.5, y + 1) and support(x, y + 1) end
        return stands[k]
    end
    if not standable(goal.x, goal.y) then return nil, "The saved standing tile has no accessible support or headroom." end
    if not standable(start.x, start.y) then return nil, "Wait until the avatar is standing on a floor or platform." end
    local function travel(from, to, jumping)
        local x, feet, vx, vy = from.x + 0.5, from.y + 1, 0, jumping and -jumpSpeed or 0
        local targetX, dt = to.x + 0.5, 0.025
        -- A farm's open columns can extend all the way to its bottom floor.
        -- Keep the simulation long enough to reach that landing surface.
        local steps = math.ceil((2.5 + math.max(0, to.y - from.y) / 24) / dt)
        for step = 1, steps do
            local direction = Navigation.steer(targetX - x, vx)
            local desired = direction * speed
            local acceleration = direction == 0 and 17 or 22
            if vx < desired then vx = math.min(desired, vx + acceleration * dt)
            else vx = math.max(desired, vx - acceleration * dt) end
            local nx = x + vx * dt
            if fits(nx, feet) then x = nx else vx = 0 end
            vy = math.min(24, vy + gravity * dt)
            local nextFeet = feet + vy * dt
            local onLaunchFloor = false
            if vy >= 0 then
                for row = math.ceil(feet - 0.001), math.floor(nextFeet + 0.001) do
                    if support(math.floor(x - 0.299), row) or support(math.floor(x + 0.299), row) then
                        if math.abs(x - targetX) < 0.35 and row == to.y + 1 then return step * dt end
                        if not jumping and row == from.y + 1 then
                            feet, vy, onLaunchFloor = row, 0, true
                            break
                        end
                        return nil -- Landed on an intermediate surface; plan it as a separate hop.
                    end
                end
            end
            if onLaunchFloor then -- Walk off the current ledge before simulating its fall.
            elseif fits(x, nextFeet) then feet = nextFeet
            elseif vy < 0 then
                -- A 25 ms step can overshoot the narrow clearance between a
                -- ceiling and a platform. Resolve the head against the crossed
                -- ceiling surface instead of leaving the feet below the ledge.
                local ceiling
                for row = math.floor(feet - 0.949), math.floor(nextFeet - 0.949), -1 do
                    for column = math.floor(x - 0.299), math.floor(x + 0.299) do
                        if solid(column, row) or danger(column, row) then ceiling = row; break end
                    end
                    if ceiling then break end
                end
                if not ceiling then return nil end
                feet, vy = ceiling + 1.9491, 0
            else return nil end
            if feet > maxY + 2 then return nil end
        end
    end
    local function platformDrop(from, to, side)
        local x, feet, vx, vy = from.x + 0.5, from.y + 1, 0, 0
        local outsideX, targetX = x + side * 0.9, to.x + 0.5
        local grounded, landed, dt, direction = true, false, 0.005, 0
        local waypoint = {x = to.x, fromX = from.x, fromY = from.y, outsideX = outsideX}
        for step = 1, math.ceil((3 + (to.y - from.y) / 24) / dt) do
            if (step - 1) % 5 == 0 then
                direction = Navigation.dropSteer({x = x, y = feet, vx = vx, grounded = grounded}, waypoint)
            end
            local desired = direction * speed
            local acceleration = direction == 0 and (grounded and 48 or 17) or (grounded and 36 or 22)
            if vx < desired then vx = math.min(desired, vx + acceleration * dt)
            else vx = math.max(desired, vx - acceleration * dt) end
            local nextX = x + vx * dt
            if fits(nextX, feet) then x = nextX else vx = 0 end
            vy = math.min(24, vy + gravity * dt)
            local nextFeet, supported = feet + vy * dt, false
            for row = math.ceil(feet - 0.001), math.floor(nextFeet + 0.001) do
                if support(math.floor(x - 0.299), row) or support(math.floor(x + 0.299), row) then
                    if row ~= from.y + 1 and row ~= to.y + 1 then return nil end
                    feet, vy, supported = row - 0.001, 0, true
                    if row == to.y + 1 then landed = true end
                    break
                end
            end
            grounded = supported
            if not supported then
                if not fits(x, nextFeet) then return nil end
                feet = nextFeet
            end
            if landed and math.abs(x - targetX) < 0.16 and math.abs(vx) < 0.8 then return step * dt, outsideX end
            if feet > to.y + 1.3 then return nil end
        end
    end
    local function estimate(x, y) return (math.abs(x - goal.x) + math.abs(y - goal.y) * 0.6) / speed end
    local initial = {x = start.x, y = start.y, cost = 0, score = estimate(start.x, start.y)}
    local open, best, closed = {initial}, {[key(start.x, start.y)] = initial}, {}
    local expansions = 0
    while #open > 0 and expansions < (options.maxNodes or 1600) do
        local selected = 1
        for index = 2, #open do if open[index].score < open[selected].score then selected = index end end
        local node = table.remove(open, selected)
        local nodeKey = key(node.x, node.y)
        if not closed[nodeKey] then
            if node.x == goal.x and node.y == goal.y then
                local route = {}
                while node.parent do
                    table.insert(route, 1, {x = node.x, y = node.y, jump = node.jump,
                        drop = node.drop, outsideX = node.outsideX,
                        fromX = node.parent.x, fromY = node.parent.y, duration = node.duration})
                    node = node.parent
                end
                return route
            end
            closed[nodeKey], expansions = true, expansions + 1
            if options.step and expansions % 64 == 0 then options.step() end
            local function offer(x, y, jumping, dropSide)
                if not standable(x, y) then return end
                local destinationKey = key(x, y)
                local edgeKey = nodeKey .. ":" .. destinationKey .. ":" .. tostring(jumping)
                if closed[destinationKey] or (options.banned and options.banned[edgeKey]) then return end
                local duration, outsideX
                if dropSide then duration, outsideX = platformDrop(node, {x = x, y = y}, dropSide)
                elseif not jumping and y == node.y then duration = 1 / speed
                else duration = travel(node, {x = x, y = y}, jumping) end
                if not duration then return end
                local cost = node.cost + duration + (jumping and 0.12 or 0)
                if not best[destinationKey] or cost < best[destinationKey].cost then
                    local nextNode = {x = x, y = y, cost = cost, score = cost + estimate(x, y),
                        parent = node, jump = jumping, drop = dropSide ~= nil, outsideX = outsideX, duration = duration}
                    best[destinationKey] = nextNode
                    table.insert(open, nextNode)
                end
            end
            if map.platform and map.platform(node.x, node.y + 1) and not solid(node.x, node.y + 1) then
                for _, side in ipairs({-1, 1}) do
                    local outside = node.x + side
                    if outside >= 0 and outside < map.w and not support(outside, node.y + 1)
                        and not solid(outside, node.y) and not danger(outside, node.y) then
                        for y = node.y + 1, maxY do
                            if standable(node.x, y) then offer(node.x, y, false, side); break end
                            if solid(node.x, y) then break end
                        end
                    end
                end
            end
            for _, dx in ipairs({-1, 1}) do
                for dy = 0, maxY - node.y do
                    if standable(node.x + dx, node.y + dy) then offer(node.x + dx, node.y + dy, false); break end
                    if solid(node.x + dx, node.y + dy) then break end
                end
            end
            for dx = -4, 4 do
                for dy = -3, 3 do
                    if dx ~= 0 or dy ~= 0 then offer(node.x + dx, node.y + dy, true) end
                end
            end
        end
    end
    return nil, "No walking/jumping route reaches the saved spot. Check door access and stepping platforms."
end

function Navigation.pickupOverlap(state, drop)
    -- Native loose-drop collection tests horizontal distance and body overlap.
    -- state.y is the avatar's feet, not the center of its standing tile.
    return math.abs(drop.x - state.x) < 0.6
        and drop.y + 0.3 > state.y - 0.95 and drop.y - 0.3 < state.y
end

function Navigation.pickupGoal(map, state, drop, options)
    options = options or {}
    local search = {fullWorld = true, maxNodes = math.min(12000, map.w * map.h), step = options.step}
    local start = {x = math.floor(state.x), y = math.floor(state.y - 0.01)}
    local centerX, centerY = math.floor(drop.x), math.floor(drop.y)
    local candidates = {}
    for y = centerY - 1, centerY + 2 do
        for x = centerX - 1, centerX + 1 do
            if x >= 0 and x < map.w and y >= 0 and y < map.h - 1
                and math.abs(drop.x - (x + 0.5)) <= 1.25
                and drop.y >= y - 1.5 and drop.y <= y + 1.25
                and (not options.nativeOnly or Navigation.pickupOverlap({x = x + 0.5, y = y + 1}, drop))
                and not map.solid(x, y) and not (map.danger and map.danger(x, y))
                and not (map.danger and map.danger(x, y + 1))
                and (map.solid(x, y + 1) or (map.platform and map.platform(x, y + 1))) then
                local distance = math.abs(drop.x - (x + 0.5)) + math.abs(drop.y - (y + 0.5))
                table.insert(candidates, {x = x, y = y, score = distance})
            end
        end
    end
    table.sort(candidates, function(a, b) return a.score < b.score end)
    local reason
    for _, goal in ipairs(candidates) do
        local route, message = Navigation.plan(map, start, goal, search)
        if route then return {x = goal.x, y = goal.y} end
        reason = message
    end
    return nil, "No reachable floor or platform is close to this harvested drop."
        .. (#candidates == 0 and " No safe supported pickup tile is in range." or " " .. tostring(reason))
end

return Navigation

end)()

-- ===== src/net.lua =====
__modules["net"] = (function(...)
-- net.lua: token Stop, jeda yang bisa dibatalkan, dan request ke server dengan batas waktu.
-- Diadaptasi dari Clarissv main.lua (checkpoint, pause, beginRequest, awaitRequest, bounded).
return function(G)
    local App, task = G.App, G.task
    local Net = {}

    -- Tiap job dapat nomor token. Stop = token naik, jadi semua loop yang pegang
    -- token lama langsung gagal di checkpoint() dan berhenti dengan rapi.
    function Net.checkpoint(token)
        assert(App.alive and App.job and token == App.token, "Stopped.")
        assert(G.accountOk(), "Akun Roblox berubah. Reload script.")
    end

    -- Jeda dalam potongan maks 0,05 detik, sambil cek Stop di tiap potongan.
    function Net.pause(seconds, token)
        local deadline = os.clock() + seconds
        repeat
            if token then Net.checkpoint(token) end
            task.wait(math.min(0.05, math.max(0, deadline - os.clock())))
        until os.clock() >= deadline
    end

    -- Jalankan fn di thread terpisah. App.pending > 0 = ada request yang belum selesai,
    -- dan selama itu task baru tidak boleh mulai (lihat Net.idle).
    function Net.beginRequest(fn, ...)
        local args = table.pack(...)
        local request = { done = false }
        App.pending = App.pending + 1
        task.spawn(function()
            request.result = table.pack(pcall(fn, table.unpack(args, 1, args.n)))
            App.pending = App.pending - 1
            request.done = true
        end)
        return request
    end

    function Net.awaitRequest(request, deadline, token)
        while not request.done do
            if token then Net.checkpoint(token) end
            assert(App.alive, "Script di-unload.")
            assert(os.clock() < deadline, "Request ke server timeout.")
            task.wait(0.05)
        end
        if not request.result[1] then error(request.result[2], 0) end
        return table.unpack(request.result, 2, request.result.n)
    end

    -- Panggil fn(...) dan tunggu maksimal `seconds` detik.
    function Net.bounded(fn, seconds, token, ...)
        return Net.awaitRequest(Net.beginRequest(fn, ...), os.clock() + seconds, token)
    end

    function Net.idle()
        assert(App.alive, "Script sudah di-unload.")
        -- Auto Collect (saat idle) sedang mungut: minta berhenti & tunggu sebentar (maks 3 detik).
        if App.autoCollecting then
            App.autoCollectHold = true
            local deadline = os.clock() + 3
            while App.autoCollecting and os.clock() < deadline do task.wait(0.05) end
            App.autoCollectHold = false
        end
        assert(not App.job and not App.configuring and App.pending == 0,
            "Stop task yang jalan dan tunggu request selesai dulu.")
    end

    -- Mulai job baru: token naik, jadi job lama (kalau ada) ikut berhenti.
    function Net.beginJob(name)
        Net.idle()
        App.token = App.token + 1
        App.job, App.jobToken, App.lastError = name, App.token, nil
        return App.token
    end
    function Net.stopJob()
        App.token = App.token + 1
        App.job, App.jobToken = nil, nil
    end

    return Net
end

end)()

-- ===== src/state.lua =====
__modules["state"] = (function(...)
-- state.lua: semua yang disimpan ke file. Folder dipisah per akun Roblox.
-- Diadaptasi dari Clarissv main.lua (writeJSON yang aman, session, checkpoint resume).
return function(G)
    local App, Core, fs, json = G.App, G.Core, G.fs, G.json
    local State = {}

    State.ROOT = "GrowbloxHansel/accounts/" .. tostring(G.accountId)
    State.PROFILE_DIR = State.ROOT .. "/profiles"
    local SESSION = State.ROOT .. "/session.json"

    local function exists(path) return type(fs.isfile) == "function" and fs.isfile(path) == true end
    State.exists = exists

    local function folders()
        assert(G.accountOk(), "Akun Roblox berubah. Reload script.")
        assert(type(fs.readfile) == "function" and type(fs.writefile) == "function"
            and type(fs.isfolder) == "function" and type(fs.makefolder) == "function",
            "Executor tidak punya readfile/writefile/makefolder.")
        local path = ""
        for part in State.PROFILE_DIR:gmatch("[^/]+") do
            path = path == "" and part or path .. "/" .. part
            if not fs.isfolder(path) then fs.makefolder(path) end
        end
    end

    function State.readJSON(path)
        if not exists(path) then return nil end
        local ok, value = pcall(json.decode, fs.readfile(path))
        assert(ok and type(value) == "table", "File rusak: " .. path)
        return value
    end

    -- Tulis aman: tulis ke .pending dulu dan cek, simpan versi lama ke .bak, baru timpa file asli.
    -- Kalau executor crash di tengah, minimal salah satu versi masih utuh.
    function State.writeJSON(path, value)
        folders()
        local text = json.encode(value)
        local staged = path .. ".pending"
        fs.writefile(staged, text)
        assert(fs.readfile(staged) == text, "Gagal verifikasi file yang disimpan.")
        if exists(path) then fs.writefile(path .. ".bak", fs.readfile(path)) end
        fs.writefile(path, text)
        assert(fs.readfile(path) == text, "Gagal menyimpan. Versi lama ada di .bak.")
        if type(fs.delfile) == "function" then pcall(fs.delfile, staged) end
    end

    -- Session = config + profil yang lagi dipakai. Dipulihkan otomatis saat script dimuat.
    function State.saveSession()
        local config, profile = Core.validate(App.config), Core.profileName(App.profile)
        local signature = json.encode({ config = config, profile = profile })
        if signature == App.sessionSignature then return false end -- tidak ada perubahan
        State.writeJSON(SESSION, { version = 1, userId = G.accountId, config = config, profile = profile })
        App.sessionSignature = signature
        return true
    end
    function State.restoreSession()
        local record = State.readJSON(SESSION)
        if not record then return false end
        assert(record.version == 1 and record.userId == G.accountId, "Session milik akun lain atau versi lain.")
        App.config, App.profile = Core.validate(record.config), Core.profileName(record.profile)
        return true
    end

    function State.saveProfile(name)
        name = Core.profileName(name)
        State.writeJSON(State.PROFILE_DIR .. "/" .. name .. ".json", Core.validate(App.config))
        App.profile = name
        return name
    end
    function State.loadProfile(name)
        name = Core.profileName(name)
        local record = State.readJSON(State.PROFILE_DIR .. "/" .. name .. ".json")
        assert(record, "Profil tidak ditemukan: " .. name)
        App.config, App.profile = Core.validate(record), name
        return name
    end

    -- Checkpoint task (buat resume setelah pindah server). Satu file per task.
    -- maxAge: checkpoint yang lebih tua dari ini dianggap basi (isi tas/box bisa sudah berubah).
    function State.saveCheckpoint(name, data)
        State.writeJSON(State.ROOT .. "/" .. name .. "-resume.json", { version = 1, active = true,
            userId = G.accountId, updatedAt = os.time(), config = Core.validate(App.config),
            profile = App.profile, data = data })
    end
    function State.loadCheckpoint(name, maxAge)
        local record = State.readJSON(State.ROOT .. "/" .. name .. "-resume.json")
        if not record or not record.active then return nil end
        assert(record.version == 1 and record.userId == G.accountId, "Checkpoint " .. name .. " milik akun lain.")
        assert(Core.finite(record.updatedAt) and os.time() - record.updatedAt < (maxAge or 21600),
            "Checkpoint " .. name .. " sudah basi. Cek tas dan box, lalu mulai ulang.")
        record.config = Core.validate(record.config)
        return record
    end
    function State.clearCheckpoint(name)
        local path = State.ROOT .. "/" .. name .. "-resume.json"
        if not exists(path) then return end
        if type(fs.delfile) == "function" then fs.delfile(path)
        else State.writeJSON(path, { version = 1, active = false }) end
    end

    return State
end

end)()

-- ===== src/bridge.lua =====
__modules["bridge"] = (function(...)
-- bridge.lua: SATU-SATUNYA modul yang mencari objek game di memori.
-- Modul lain cuma pakai hasilnya: Bridge.runtime() -> { world, body, controls, inventory, items, handlers, ... }
-- Kalau Growblox update dan script tiba-tiba "found 0", yang diperbaiki cukup file ini.
--
-- Cara kerja discover() diadaptasi dari Clarissv main.lua (discover, resolveRegistry,
-- resolveItems, treeGrowthHooks, findWorldPicker, findRespawn). Objek game dikenali dari
-- "sidik jari": kombinasi nama fungsi/field yang cuma dimiliki objek itu.
return function(G)
    local App, Core, Net, X, task = G.App, G.Core, G.Net, G.exec, G.task
    local Bridge = {}

    local function report(line) table.insert(App.discoveryReport, line) end

    ---------------------------------------------------------------- alat bantu scan
    local function newScan()
        return { values = {}, names = {}, work = 0, steps = 0, yields = 0, reads = 0, lastYield = os.clock() }
    end
    -- Kasih napas ke game tiap ~6 ms supaya scan memori yang besar tidak bikin freeze.
    local function scanStep(scan, stage)
        assert(App.alive, "Script di-unload saat connect.")
        App.startupStage = stage
        scan.work, scan.steps = scan.work + 1, scan.steps + 1
        if scan.work >= 8192 or os.clock() - scan.lastYield >= 0.006 then
            task.wait()
            assert(App.alive, "Script di-unload saat connect.")
            scan.work, scan.lastYield, scan.yields = 0, os.clock(), scan.yields + 1
        end
    end
    -- Isi "upvalue" sebuah fungsi = variabel luar yang dipakai fungsi itu.
    -- Dipakai untuk membuktikan fungsi A "milik" objek world B.
    local function upvalues(fn, scan)
        if scan and scan.values[fn] then return scan.values[fn] end
        local result
        if type(X.getupvalues) == "function" then
            local ok, values = pcall(X.getupvalues, fn)
            if ok and type(values) == "table" then result = values end
        end
        if not result and type(X.getupvalue) == "function" then
            result = {}
            for index = 1, 100 do
                local ok, first, second = pcall(X.getupvalue, fn, index)
                if not ok or first == nil then break end
                if second ~= nil then result[index] = second else result[index] = first end
            end
        end
        result = result or {}
        if scan then scan.values[fn], scan.reads = result, scan.reads + 1 end
        return result
    end
    local function functionName(fn, scan)
        if scan and scan.names[fn] ~= nil then return scan.names[fn] or nil end
        local name
        if type(X.debugInfo) == "function" then
            local ok, value = pcall(X.debugInfo, fn, "n")
            if ok and value and value ~= "" then name = value end
        end
        if not name and type(X.getinfo) == "function" then
            local ok, info = pcall(X.getinfo, fn)
            if ok and type(info) == "table" then name = info.name end
        end
        if scan then scan.names[fn] = name or false end
        return name
    end
    -- Fungsi "milik" world kalau upvalue-nya memegang tabel world itu (cara Clarissv).
    -- Cadangan v0.2.2 (update Growblox 17 Nov 2026): upvalue berupa tabel KONTEKS yang menyimpan
    -- world di salah satu field-nya (misal ctx.world). Cadangan v0.2.1: tabel lain yang memegang grid sama.
    local ownership = { direct = 0, nested = 0, grid = 0 }
    -- Field mana di tabel `value` yang berisi world? Dibaca mentah (tanpa metamethod), maks 256 field,
    -- dan hasilnya di-cache per tabel supaya tabel besar (misal daftar item) tidak dibaca berulang.
    local function holdsWorld(value, world, scan)
        local cache = scan and scan.holds
        if cache and cache[value] ~= nil then return cache[value] or nil end
        local found, n = nil, 0
        local ok = pcall(function()
            for key, field in next, value do
                n = n + 1
                if n > 256 then break end
                if field == world then found = key; break end
            end
        end)
        if not ok then found = nil end
        if cache then cache[value] = found or false end
        return found
    end
    local function owns(fn, world, scan)
        local nested, viaGrid = false, false
        for _, value in pairs(upvalues(fn, scan)) do
            if value == world then ownership.direct = ownership.direct + 1; return true end
            if type(value) == "table" then
                if not nested and holdsWorld(value, world, scan) ~= nil then nested = true end
                if not viaGrid and type(world.fg) == "table" and rawget(value, "fg") == world.fg then viaGrid = true end
            end
        end
        if nested then ownership.nested = ownership.nested + 1; return true end
        if viaGrid then ownership.grid = ownership.grid + 1; return true end
        return false
    end
    -- Ringkasan upvalue satu fungsi untuk diagnostics.
    local function describeUpvalues(fn, world, scan)
        local parts = {}
        for _, value in pairs(upvalues(fn, scan)) do
            local kind = type(value)
            if kind == "table" then
                local key = holdsWorld(value, world, scan)
                if value == world then kind = "WORLD"
                elseif key ~= nil then kind = "table(world di ." .. tostring(key) .. ")"
                elseif rawget(value, "fg") ~= nil then kind = rawget(value, "fg") == world.fg and "table(fg sama)" or "table(fg beda)"
                elseif type(rawget(value, "backpackNow")) == "function" then kind = "table(mirip world)"
                else
                    local names, n = {}, 0
                    pcall(function()
                        for k in next, value do
                            n = n + 1
                            if n > 6 then break end
                            table.insert(names, tostring(k))
                        end
                    end)
                    kind = "table{" .. table.concat(names, ",") .. (n > 6 and ",..." or "") .. "}"
                end
            end
            table.insert(parts, kind)
            if #parts >= 12 then break end
        end
        return #parts > 0 and table.concat(parts, ", ") or "kosong"
    end
    local function readField(value, key)
        local ok, field = pcall(function() return value[key] end)
        if ok then return field end
    end
    Bridge.upvalues = upvalues -- dipakai modul lain (misal FPS booster nanti)

    ---------------------------------------------------------------- registry & item
    local function registryMap(candidate, scan)
        if type(candidate) ~= "table" then return nil end
        local function matches(value) return type(value) == "table" and rawget(value, "RnyflzPbj74") ~= nil end
        if matches(candidate) then return candidate end
        for _, getMeta in ipairs({ getmetatable, X.getrawmetatable }) do
            if type(getMeta) == "function" then
                local ok, meta = pcall(getMeta, candidate)
                if ok and type(meta) == "table" and matches(rawget(meta, "__index")) then return rawget(meta, "__index") end
            end
        end
        if type(rawget(candidate, "WaitForChild")) == "function" and type(rawget(candidate, "FindFirstChild")) == "function" then
            for _, method in ipairs({ "WaitForChild", "FindFirstChild" }) do
                for _, value in pairs(upvalues(rawget(candidate, method), scan)) do
                    if matches(value) then return value end
                end
            end
        end
    end

    local function resolveRegistry(scan)
        local key = G.registryKey()
        if key ~= nil then
            for _, container in ipairs(X.sharedTables or {}) do
                if type(container.value) == "table" then
                    local map = registryMap(rawget(container.value, key), scan)
                    if map then return map, container.label end
                end
            end
        end
        return nil, "unavailable; Qz attribute: " .. (key ~= nil and "present" or "missing")
    end

    -- Tabel definisi item dikenali dari 5 item yang pasti ada: Blank, Dirt, Door, Fist, Display Box.
    local function itemDefinitions(candidate)
        if type(candidate) ~= "table" then return nil end
        local function entry(id, name)
            local value = rawget(candidate, id)
            if type(value) == "table" and rawget(value, "name") == name then return value end
        end
        local blank, dirt, fist = entry(0, "Blank"), entry(2, "Dirt"), entry(18, "Fist")
        local door, display = entry(12, "Door"), entry(1422, "Display Box")
        if blank and rawget(blank, "solid") == false
            and dirt and rawget(dirt, "solid") == true and type(rawget(dirt, "hits")) == "number"
            and fist and rawget(fist, "kind") == "tool"
            and door and rawget(door, "door") == true
            and display and rawget(display, "display") == true then return candidate end
    end

    local function resolveItems(world, registry, scan)
        local found, sources, seen = {}, {}, {}
        local function consider(candidate, source)
            local items = itemDefinitions(candidate)
            if items and not seen[items] then
                seen[items] = true
                table.insert(found, items)
                sources[items] = source
            end
        end
        -- Paling dipercaya: tabel item yang dipegang fungsi-fungsi milik world aktif.
        for _, value in pairs(world) do
            scanStep(scan, "Mencari definisi item")
            if type(value) == "function" then
                for _, captured in pairs(upvalues(value, scan)) do consider(captured, "upvalue fungsi world") end
            end
        end
        for _, fn in ipairs(scan.owned) do
            scanStep(scan, "Mencari definisi item")
            for _, captured in pairs(upvalues(fn, scan)) do consider(captured, "upvalue fungsi world") end
        end
        assert(#found <= 1, "Definisi item ambigu: ada " .. #found .. " tabel milik world aktif.")
        if #found == 1 then return found[1], sources[found[1]] end
        if registry then
            local items = itemDefinitions(rawget(registry, "RnyflzPbj74"))
            if items then return items, "tabel registry" end
        end
        for _, object in ipairs(scan.tables) do
            scanStep(scan, "Mencari definisi item")
            consider(object, "tabel GC")
        end
        assert(#found == 1, #found > 1 and "Definisi item ambigu di GC." or "Definisi item tidak ditemukan.")
        return found[1], sources[found[1]]
    end

    local function inventoryObject(candidate)
        return type(candidate) == "table" and type(rawget(candidate, "slots")) == "table"
            and type(readField(candidate, "count")) == "function" and type(readField(candidate, "room")) == "function"
            and type(readField(candidate, "add")) == "function" and type(readField(candidate, "remove")) == "function"
    end

    ---------------------------------------------------------------- hook pohon & UI kecil
    -- Cari fungsi "pohon sudah matang?" dan "sisa waktu tumbuh". Dipakai fitur harvest/plant nanti.
    local function treeGrowthHooks(world, items, handlers, scan)
        if type(world.ride) ~= "function" or type(handlers.setTree) ~= "function" then return nil end
        local rideTables, ripe, trees, gear = {}, nil, nil, nil
        for _, value in pairs(upvalues(world.ride, scan)) do
            if type(value) == "table" and value ~= world and value ~= items then rideTables[value] = true end
            if type(value) == "table" and type(rawget(value, "onWear")) == "function"
                and type(rawget(value, "isWorn")) == "function" and owns(value.onWear, world, scan) then
                if gear and gear ~= value then return nil end
                gear = value
            end
            if type(value) == "function" and functionName(value, scan) == "treeRipe" then
                for _, captured in pairs(upvalues(value, scan)) do
                    if captured == items then
                        if ripe and ripe ~= value then return nil end
                        ripe = value
                    end
                end
            end
        end
        for _, value in pairs(upvalues(handlers.setTree, scan)) do
            if rideTables[value] then
                if trees and trees ~= value then return nil end
                trees = value
            end
        end
        if not trees or not ripe then return nil end
        local equipment
        if gear then
            local worn, wearTables = nil, {}
            for _, value in pairs(upvalues(gear.onWear, scan)) do if type(value) == "table" then wearTables[value] = true end end
            for _, value in pairs(upvalues(gear.isWorn, scan)) do
                if type(value) == "table" and wearTables[value] and value ~= world and value ~= items then
                    if worn and worn ~= value then return nil end
                    worn = value
                end
            end
            if worn then equipment = { wear = gear.onWear, feet = function() return rawget(worn, "feet") end } end
        end
        local isRipe = function(x, y, id)
            local tree = trees[y * world.w + x]
            if type(tree) ~= "table" or type(tree.p) ~= "number" then return nil end
            return ripe(id, tree)
        end
        local remaining = function(x, y, id)
            local tree, item = trees[y * world.w + x], items[id]
            if type(tree) ~= "table" or type(tree.p) ~= "number" or not item then return nil end
            return math.max(0, tree.p + (item.grow or 0) - G.serverTime())
        end
        return isRipe, equipment, remaining
    end

    local function findWorldPicker(world, entries, scan)
        if type(world.enter) ~= "function" then return nil end
        local found
        for _, fn in ipairs(entries) do
            scanStep(scan, "Mencari world picker")
            local adapter, panel, hud, input
            for _, value in pairs(upvalues(fn, scan)) do
                if type(value) == "table" and rawget(value, "enter") == world.enter then adapter = value end
                if type(value) == "function" and functionName(value, scan) == "hud" then hud = value end
                if G.isInstance(value) then
                    if value:IsA("GuiObject") and value:FindFirstChild("recent", true)
                        and value:FindFirstChild("WorldName", true) then panel = value end
                    if value:IsA("TextBox") then input = value end
                end
            end
            if adapter and panel and hud then
                if found and found.panel ~= panel then return nil end
                found = { panel = panel, complete = function()
                    panel.Visible = false
                    hud()
                    if input then input:ReleaseFocus() end
                end }
            end
        end
        return found
    end

    local function findRespawn(world, menus, scan)
        if type(rawget(world, "respawn")) == "function" then return world.respawn, "method world" end
        local found
        for _, candidate in ipairs(menus) do
            scanStep(scan, "Mencari respawn")
            if type(rawget(candidate, "respawn")) == "function" and type(rawget(world, "enter")) == "function"
                and rawget(candidate, "enter") == world.enter and type(rawget(candidate, "currentWorld")) == "function"
                and owns(candidate.currentWorld, world, scan) then
                if found and found ~= candidate.respawn then return nil, "ambigu" end
                found = candidate.respawn
            end
        end
        return found, found and "adapter menu" or "tidak tersedia"
    end

    ---------------------------------------------------------------- discover
    -- Satu kali scan memori. Gagal = error dengan pesan yang jelas (dibaca Core.retryable).
    function Bridge.discover()
        assert(type(X.getgc) == "function", "Executor harus punya getgc(true).")
        local scan, startedAt = newScan(), os.clock()
        App.discoveryReport = {}
        ownership.direct, ownership.nested, ownership.grid = 0, 0, 0
        scan.holds = {}
        App.startupStage = "Membaca objek game"
        task.wait()
        local registry, registrySource = resolveRegistry(scan)
        local registryKey = G.registryKey()
        local worlds, physics, controls, huds, backpacks, menus, entries = {}, {}, {}, {}, {}, {}, {}
        scan.tables, scan.functions, scan.owned = {}, {}, {}

        for _, object in pairs(X.getgc(true)) do
            scanStep(scan, "Mengindeks world dan kontrol")
            if type(object) == "table" then
                table.insert(scan.tables, object)
                if not registry then
                    local map = registryMap(object, scan)
                        or (registryKey ~= nil and registryMap(rawget(object, registryKey), scan))
                    if map then registry, registrySource = map, "GC" end
                end
                -- Sidik jari world: 4 field ini sekaligus cuma ada di objek world aktif.
                if type(rawget(object, "backpackNow")) == "function" and type(rawget(object, "displayPut")) == "function"
                    and type(rawget(object, "useDoor")) == "function" and type(rawget(object, "fg")) == "table" then
                    table.insert(worlds, object)
                end
                -- Sidik jari fisika avatar: ukuran badan H = 0.95, HW = 0.3.
                if type(rawget(object, "state")) == "function" and type(rawget(object, "solidAt")) == "function"
                    and rawget(object, "H") == 0.95 and rawget(object, "HW") == 0.3 then
                    table.insert(physics, object)
                end
                if type(rawget(object, "dir")) == "function" and type(rawget(object, "jumping")) == "function"
                    and type(rawget(object, "punchPressed")) == "function" and type(rawget(object, "setScale")) == "function"
                    and type(rawget(object, "place")) == "function" and type(rawget(object, "edit")) == "function" then
                    table.insert(controls, object)
                end
                if type(rawget(object, "setGems")) == "function" and type(rawget(object, "addGems")) == "function"
                    and type(rawget(object, "setWorld")) == "function" and type(rawget(object, "isTyping")) == "function" then
                    table.insert(huds, object)
                end
                if inventoryObject(object) then table.insert(backpacks, object) end
                if type(rawget(object, "respawn")) == "function" then table.insert(menus, object) end
            elseif type(object) == "function" then
                table.insert(scan.functions, object)
                if functionName(object, scan) == "enter" then table.insert(entries, object) end
            end
        end

        report("Registry: " .. registrySource)
        report("World tables: " .. #worlds .. "; avatar controllers: " .. #physics .. "; touch controls: " .. #controls)
        assert(#worlds == 1, "Could not identify one active Growblox world table (found " .. #worlds .. ").")
        local world = worlds[1]
        local issues = {}

        local gemHud
        for _, candidate in ipairs(huds) do
            if not gemHud or (type(rawget(candidate, "onMessage")) == "function" and owns(candidate.onMessage, world, scan)) then
                gemHud = candidate
            end
        end

        local body
        for _, candidate in ipairs(physics) do
            if owns(candidate.state, world, scan) then
                if body then body = nil; table.insert(issues, "Lebih dari satu avatar cocok."); break end
                body = candidate
            end
        end
        if not body then table.insert(issues, "Hook state avatar tidak ada.") end
        if #controls ~= 1 then table.insert(issues, "Touch controller: ketemu " .. #controls .. ", harusnya 1.") end

        -- Backpack: utamakan objek inventory yang dipegang world.backpackNow.
        local inventory
        for _, candidate in pairs(upvalues(world.backpackNow, scan)) do
            if inventoryObject(candidate) then inventory = candidate end
        end
        if not inventory then
            local ok, snapshot = pcall(world.backpackNow)
            local matches = {}
            if ok and type(snapshot) == "table" then
                local counts = {}
                for _, slot in pairs(snapshot) do counts[slot[1]] = (counts[slot[1]] or 0) + slot[2] end
                for _, candidate in ipairs(backpacks) do
                    local same, seen = true, {}
                    for _, slot in pairs(candidate.slots) do
                        if counts[slot.id] ~= slot.n then same = false; break end
                        seen[slot.id] = true
                    end
                    for id in pairs(counts) do if not seen[id] then same = false end end
                    if same then table.insert(matches, candidate) end
                end
            end
            if #matches == 1 then inventory = matches[1] end
        end
        assert(inventory, "Backpack tidak ditemukan.")

        -- Handler farming (place/break/tanam) = fungsi yang dimiliki world dengan nama tertentu.
        local handlers, ambiguous = {}, {}
        for _, fn in ipairs(scan.functions) do
            scanStep(scan, "Mencari handler game")
            if owns(fn, world, scan) then
                table.insert(scan.owned, fn)
                local name = functionName(fn, scan)
                if name == "setTile" or name == "hit" or name == "canPlace" or name == "plantSeed" or name == "setTree" then
                    if handlers[name] or ambiguous[name] then handlers[name], ambiguous[name] = nil, true
                    else handlers[name] = fn end
                end
            end
        end
        for _, name in ipairs({ "setTile", "hit", "canPlace" }) do
            if not handlers[name] then table.insert(issues, (ambiguous[name] and "Ambigu" or "Tidak ada") .. " handler: " .. name) end
        end

        local items, itemSource = resolveItems(world, registry, scan)
        local respawn, respawnSource = findRespawn(world, menus, scan)
        local treeRipe, harvestGear, treeRemaining = treeGrowthHooks(world, items, handlers, scan)
        -- Detail tambahan saat ada hook hilang, untuk melacak perubahan di game.
        if #issues > 0 then
            if physics[1] then report("Upvalue avatar.state: " .. describeUpvalues(physics[1].state, world, scan)) end
            report("Upvalue world.displayPut: " .. describeUpvalues(world.displayPut, world, scan))
            local named = {}
            for _, fn in ipairs(scan.functions) do
                local name = functionName(fn, scan)
                if name == "setTile" or name == "plantSeed" or name == "canPlace" then
                    named[name] = (named[name] or 0) + 1
                    if name == "setTile" and named[name] == 1 then report("Upvalue setTile: " .. describeUpvalues(fn, world, scan)) end
                end
            end
            report(string.format("Fungsi bernama di GC: setTile %d, canPlace %d, plantSeed %d",
                named.setTile or 0, named.canPlace or 0, named.plantSeed or 0))
            report("World name: " .. tostring(world.name) .. "; w/h: " .. tostring(world.w) .. "/" .. tostring(world.h))
        end
        report("Kepemilikan: langsung " .. ownership.direct .. ", lewat konteks " .. ownership.nested .. ", lewat grid " .. ownership.grid)
        local runtime = { world = world, body = body, controls = controls[1], inventory = inventory, items = items,
            handlers = handlers, issues = issues, ready = #issues == 0, gemHud = gemHud,
            picker = findWorldPicker(world, entries, scan), respawn = respawn,
            treeRipe = treeRipe, harvestGear = harvestGear, treeRemaining = treeRemaining,
            ownedFunctions = scan.owned } -- dipakai World Scan untuk mencari tabel pohon

        report("Item definitions: " .. itemSource)
        report("Hooks: " .. (#issues == 0 and "ready" or table.concat(issues, " ")))
        report("Planting hook: " .. (handlers.plantSeed and "ready" or ambiguous.plantSeed and "ambiguous" or "unavailable"))
        report("Tree growth hook: " .. (treeRipe and "ready" or ("unavailable (world.ride " .. type(world.ride)
            .. ", setTree " .. (handlers.setTree and "ada" or ambiguous.setTree and "ambigu" or "tidak ada")
            .. "); pakai World Scan di world farm")))
        report("Respawn: " .. respawnSource .. "; world picker: " .. (runtime.picker and "ready" or "unavailable"))
        report(string.format("Discovery: %d yields, %d upvalue reads, %.2fs", scan.yields, scan.reads, os.clock() - startedAt))
        App.startupStage = "Tersambung"
        return runtime
    end

    ---------------------------------------------------------------- connect + retry
    -- PERBAIKAN dari Clarissv: di sana connect cuma dicoba sekali saat startup, jadi kalau
    -- world belum selesai loading habis pindah server ("found 0"), auto-resume mati.
    -- Di sini error "belum siap" dicoba ulang. Error lain langsung dilempar.
    function Bridge.connect(options)
        options = options or {}
        local attempts, delay = options.attempts or 8, options.delay or 4
        local lastError
        for attempt = 1, attempts do
            local ok, result = pcall(Bridge.discover)
            if ok then
                -- World ketemu, tapi tunggu avatar benar-benar siap sebelum dianggap tersambung.
                local body = result.body
                local inWorld = result.world.name ~= nil and result.world.name ~= "" and not Bridge.pickerOpen(result)
                if inWorld and (not body or Bridge.avatarReady(result)) then
                    App.runtime, App.connectionError = result, nil
                    App.connectAttempts = attempt
                    return result
                end
                -- allowPicker: tetap tersambung walau masih di world picker / karakter belum muncul,
                -- asal hook masuk world ada. Dipakai saat melanjutkan task setelah mental/pindah server:
                -- task-nya sendiri yang masuk ke world tujuan.
                if options.allowPicker and type(result.world.enter) == "function" then
                    App.runtime, App.connectionError = result, nil
                    App.connectAttempts = attempt
                    result.connectedInPicker = not inWorld
                    return result
                end
                result = inWorld and "Your character is not ready yet." or "Still in the world picker. Enter a world first."
            end
            lastError = tostring(result)
            App.connectionError = lastError
            if not Core.retryable(lastError) or attempt == attempts then break end
            if options.onRetry then options.onRetry(attempt, attempts, lastError) end
            for _ = 1, math.floor(delay / 0.25) do
                assert(App.alive, "Script di-unload saat menunggu world.")
                task.wait(0.25)
            end
        end
        App.runtime = nil
        error(lastError, 0)
    end

    ---------------------------------------------------------------- cek kondisi
    -- Status avatar yang aman dibaca: nil kalau karakter belum ada / sedang hilang (keluar world,
    -- mati, respawn). Membaca status saat itu bisa error ("attempt to index nil"); di sini ditangkap.
    function Bridge.avatarState(r)
        if not r or not r.body then return nil end
        local ok, state = pcall(r.body.state)
        if ok and type(state) == "table" then return state end
        return nil
    end
    function Bridge.avatarReady(r)
        local state = Bridge.avatarState(r)
        return state ~= nil and state.active and not state.dead and true or false
    end

    function Bridge.runtime()
        assert(App.runtime, App.connectionError or "Belum tersambung ke game. Pakai Reconnect di Settings.")
        return App.runtime
    end
    function Bridge.pickerOpen(r)
        if not r or not r.picker then return false end
        local ok, visible = pcall(function() return r.picker.panel.Visible end)
        return ok and visible == true
    end
    -- Error "recoverable" boleh dipulihkan otomatis (misal masuk ulang world). Error biasa = stop.
    function Bridge.recoverable(message, worldName, reason)
        return setmetatable({ message = message, world = worldName, reason = reason, recoverable = true },
            { __tostring = function(value) return value.message end })
    end
    function Bridge.position()
        local r = Bridge.runtime()
        assert(r.body, "Hook avatar tidak ada. Copy diagnostics di Settings.")
        local state = Bridge.avatarState(r)
        if not state or not state.active or state.dead then
            error(Bridge.recoverable("Menunggu avatar siap.", r.world and r.world.name, "avatar"), 0)
        end
        return state
    end
    -- Dipanggil sebelum aksi penting: masih di world yang benar, avatar hidup, tidak di-freeze.
    function Bridge.worldCheck(name, token)
        if token then Net.checkpoint(token) end
        local r = Bridge.runtime()
        local current = type(r.world) == "table" and r.world.name or nil
        if current == nil or current == "" or Bridge.pickerOpen(r) then
            error(Bridge.recoverable("Keluar ke world picker.", name, "worldPicker"), 0)
        end
        -- Mental ke world lain: bisa dipulihkan (task masuk lagi ke world-nya), bukan stop.
        if name ~= nil and current ~= name then
            error(Bridge.recoverable("Pindah ke world " .. tostring(current) .. " (seharusnya " .. name .. ").", name, "worldChanged"), 0)
        end
        assert(not G.frozen(), "Karakter di-freeze.")
        if r.body and not Bridge.avatarReady(r) then
            error(Bridge.recoverable("Menunggu avatar siap.", name, "avatar"), 0)
        end
        return r
    end

    return Bridge
end

end)()

-- ===== src/actions.lua =====
__modules["actions"] = (function(...)
-- actions.lua: aksi dasar yang dipakai semua fitur (PNB, plant, harvest, auto collect).
-- Pondasi baru berisi aksi inventory. Jalan, ambil drop, dan box ditambah bareng fiturnya.
-- Diadaptasi dari Clarissv main.lua (count, tileAt, refreshInventory).
return function(G)
    local App, Bridge, Net = G.App, G.Bridge, G.Net
    local Actions = {}

    function Actions.count(id)
        return Bridge.runtime().inventory:count(id)
    end

    function Actions.tileAt(x, y)
        local world = Bridge.runtime().world
        assert(x >= 0 and y >= 0 and x < world.w and y < world.h, "Tile di luar world.")
        return world.fg[y] and world.fg[y][x] or 0
    end

    -- Minta isi tas versi SERVER, lalu samakan tas lokal. Dipanggil sebelum keputusan penting,
    -- karena hitungan lokal bisa meleset (contoh: takeDrop tidak update tas lokal).
    function Actions.refreshInventory(token)
        local r = Bridge.runtime()
        local name = r.world.name
        local timeout = App.config.options.actionTimeout
        -- Kalau script sedang pegang kontrol, tunggu pickup bawaan game yang masih jalan selesai
        -- dulu, dan tahan pickup baru selama sinkron, biar snapshot server tidak ketinggalan item.
        local hold = App.controls
        if hold then
            hold.syncing = true
            local deadline = os.clock() + timeout
            while true do
                if token then Net.checkpoint(token) end
                local taking = hold.autoTakes > 0
                for _, drop in pairs(r.world.dropList()) do
                    if drop.taking then taking = true end
                end
                if not taking then break end
                assert(os.clock() < deadline, "Menunggu pickup yang sedang jalan: timeout.")
                Net.pause(0.05, token)
            end
        end
        local ok, result = pcall(Actions.syncInventory, r, name, timeout, token)
        if hold then hold.syncing = false end
        if not ok then error(result, 0) end
        return result
    end

    function Actions.syncInventory(r, name, timeout, token)
        local snapshot
        for attempt = 1, 3 do
            if token then Bridge.worldCheck(name, token) end
            snapshot = Net.bounded(r.world.call, timeout, token, "GetInventory")
            if token then Bridge.worldCheck(name, token) end -- balasan bisa datang pas sudah keluar world
            if type(snapshot) == "table" and type(snapshot.slots) == "table" then break end
            if attempt < 3 then Net.pause(0.25, token) end
        end
        assert(type(snapshot) == "table" and type(snapshot.slots) == "table", "Balasan backpack dari server tidak valid.")
        local desired = {}
        for _, slot in pairs(snapshot.slots) do
            local id, n = slot[1], slot[2]
            assert(type(id) == "number" and type(n) == "number", "Slot backpack dari server tidak valid.")
            desired[id] = (desired[id] or 0) + n
        end
        if type(snapshot.capacity) == "number" then r.inventory.capacity = snapshot.capacity end
        -- Kurangi yang kelebihan (kecuali tool), tambah yang kurang. Sama seperti handler InventorySync game.
        local current = {}
        for _, slot in ipairs(r.inventory.slots) do current[slot.id] = slot.n end
        for id, n in pairs(current) do
            if r.items[id] and r.items[id].kind ~= "tool" and n > (desired[id] or 0) then
                r.inventory:remove(id, n - (desired[id] or 0))
            end
        end
        for id, n in pairs(desired) do
            local missing = n - r.inventory:count(id)
            if missing > 0 then r.inventory:add(id, missing) end
        end
        return desired
    end

    -- Daftar blok di tas yang bisa di-PNB (buat dropdown UI).
    function Actions.farmableBlocks()
        local r = Bridge.runtime()
        local list, seen = {}, {}
        for _, slot in ipairs(r.inventory.slots) do
            local item = r.items[slot.id]
            if not seen[slot.id] and G.Core.farmable(item) then
                seen[slot.id] = true
                table.insert(list, { id = slot.id, name = item.name or ("Item " .. slot.id) })
            end
        end
        table.sort(list, function(a, b) return a.name < b.name end)
        return list
    end

    return Actions
end

end)()

-- ===== src/movement.lua =====
__modules["movement"] = (function(...)
-- movement.lua: ambil alih kontrol karakter, jalan/lompat ke tile, dan masuk world.
-- Diadaptasi dari Clarissv main.lua v0.1.43: takeControls, releaseControls, navigationMap,
-- walkTo, moveTo, moveToPoint, withoutPickups, suspendHarvestVehicle, harvestEquipmentScope,
-- queueResume, enterPlantWorld. Logikanya dipertahankan; cabang Rotation/Botting dibuang dulu.
return function(G)
    local App, Bridge, Net, Actions, Navigation, task = G.App, G.Bridge, G.Net, G.Actions, G.Navigation, G.task
    local Movement = {}
    local worldCheck, position, pause, checkpoint = Bridge.worldCheck, Bridge.position, Net.pause, Net.checkpoint

    ---------------------------------------------------------------- kontrol
    -- Ganti fungsi arah/lompat milik game dengan versi kita. Selama dipegang, karakter
    -- bergerak sesuai hold.direction (-1 kiri, 0 diam, 1 kanan) dan hold.jump.
    -- Pickup bawaan game juga dibungkus: bisa ditahan (pausePickup) saat menanam/sinkron tas.
    function Movement.takeControls()
        if App.controls then return App.controls end
        local r = Bridge.runtime()
        local controls, world = r.controls, r.world
        local hold = { table = controls, dir = controls.dir, jumping = controls.jumping, direction = 0, jump = false,
            world = world, displayTake = world.displayTake, takeDrop = world.takeDrop, autoTakes = 0,
            syncing = false, pausePickup = false, suppressedTakes = {} }
        hold.dirOverride = function() return hold.direction end
        hold.jumpOverride = function() return hold.jump end
        controls.dir, controls.jumping = hold.dirOverride, hold.jumpOverride
        hold.displayOverride = function() end
        hold.takeOverride = function(uid, ...)
            if hold.syncing or hold.pausePickup then
                hold.suppressedTakes[uid] = { grid = world.fg, at = os.clock() }
                return 0
            end
            hold.suppressedTakes[uid] = nil
            hold.autoTakes = hold.autoTakes + 1
            local result = table.pack(pcall(hold.takeDrop, uid, ...))
            task.defer(function() hold.autoTakes = hold.autoTakes - 1 end)
            if not result[1] then error(result[2]) end
            return table.unpack(result, 2, result.n)
        end
        world.displayTake, world.takeDrop = hold.displayOverride, hold.takeOverride
        App.controls = hold
        return hold
    end

    -- Kembalikan fungsi asli, tapi cuma kalau yang terpasang masih versi kita.
    function Movement.releaseControls()
        local hold = App.controls
        if hold then
            if hold.table.dir == hold.dirOverride then hold.table.dir = hold.dir end
            if hold.table.jumping == hold.jumpOverride then hold.table.jumping = hold.jumping end
            if hold.world.displayTake == hold.displayOverride then hold.world.displayTake = hold.displayTake end
            if hold.world.takeDrop == hold.takeOverride then hold.world.takeDrop = hold.takeDrop end
            App.controls = nil
        end
    end

    -- Jalankan fn dengan pickup bawaan game ditahan (dipakai saat menanam).
    function Movement.withoutPickups(fn)
        local hold = App.controls
        local previous = hold and hold.pausePickup
        if hold then hold.pausePickup = true end
        local result = table.pack(pcall(fn))
        if hold then hold.pausePickup = previous end
        if not result[1] then error(result[2], 0) end
        return table.unpack(result, 2, result.n)
    end

    ---------------------------------------------------------------- jalan
    -- Peta untuk navigation.lua: ukuran world, kecepatan, gravitasi, tile padat/platform/berbahaya.
    function Movement.navigationMap(r)
        local world = r.world
        local function itemAt(x, y) return r.items[world.fg[y] and world.fg[y][x] or 0] end
        return {
            w = world.w, h = world.h, speed = (world.riding and world.riding.speed or 7.2) * (world.speedScale or 1),
            gravity = 55 * (world.gravityScale or 1),
            solid = function(x, y) return r.body.solidAt(x, y) end,
            platform = function(x, y) local item = itemAt(x, y); return item and item.platform end,
            danger = function(x, y)
                local item = itemAt(x, y)
                return item and (item.deadly or item.hurts)
            end,
        }
    end

    local function transientRouteFault(problem)
        if type(problem) ~= "string" then return false end
        return problem:find("Returning to the saved position timed out", 1, true)
            or problem:find("Could not reach the saved position", 1, true)
            or problem:find("The planned jumps did not reach the platforms", 1, true)
            or problem:find("The avatar did not land on a reachable floor or platform", 1, true)
    end

    -- Jalan ke tile (x, y) = tile tempat kaki berdiri. onStep(state) dipanggil tiap langkah:
    -- return false = berhenti, "hold" = diam sebentar (misal menunggu tanam), lainnya = lanjut.
    local function walkTo(x, y, worldName, token, onStep)
        local r = worldCheck(worldName, token)
        Actions.tileAt(x, y)
        local hold = Movement.takeControls()
        local targetX, targetY = x + 0.5, y + 1
        local farmNavigation = App.job == "plant" or App.job == "harvest" or App.job == "rotation"
        local timeout = farmNavigation and math.max(90, App.config.options.moveTimeout) or App.config.options.moveTimeout
        local deadline, banned, replans = os.clock() + timeout, {}, 0
        local function collectionStep(state)
            if not onStep then return true, 0 end
            local started = os.clock()
            local proceed = onStep(state)
            local waited = os.clock() - started
            deadline = deadline + waited -- waktu menunggu aksi tidak dihitung sebagai gagal jalan
            return proceed ~= false, waited, proceed == "hold"
        end
        local function reached(state, tx, ty)
            return state.grounded and math.abs(state.x - tx) < 0.16
                and math.abs(state.y - ty) < 0.22 and math.abs(state.vx or 0) < 0.8
        end
        while true do
            worldCheck(worldName, token)
            local state = position()
            local proceed, _, pacing = collectionStep(state)
            if not proceed then hold.direction, hold.jump = 0, false; return false end
            while pacing do
                hold.direction, hold.jump = 0, false
                pause(0.025, token)
                deadline = deadline + 0.025
                worldCheck(worldName, token)
                state = position()
                proceed, _, pacing = collectionStep(state)
                if not proceed then return false end
            end
            state = position()
            if reached(state, targetX, targetY) then hold.direction, hold.jump = 0, false; return end
            assert(os.clock() < deadline, "Could not reach the saved position. Check stepping platforms and door access.")
            hold.direction, hold.jump = 0, false
            local landingDeadline = math.min(deadline, os.clock() + 2.5 + r.world.h / 24)
            while not state.grounded do
                assert(os.clock() < landingDeadline, "The avatar did not land on a reachable floor or platform.")
                pause(0.03, token)
                worldCheck(worldName, token)
                state = position()
            end
            local start = { x = math.floor(state.x), y = math.floor(state.y - 0.01) }
            local routeContext = worldName .. ": from tile " .. start.x .. ", " .. start.y
                .. " to standing tile " .. x .. ", " .. y
            App.navigationDebug = "Planning " .. routeContext
            local route, message = Navigation.plan(Movement.navigationMap(r), start, { x = x, y = y }, {
                banned = banned, fullWorld = farmNavigation,
                maxNodes = farmNavigation and math.min(12000, r.world.w * r.world.h) or 1600,
                step = function() pause(0, token); worldCheck(worldName, token) end,
            })
            if not route then
                App.navigationDebug = "Failed " .. routeContext .. "; " .. tostring(message)
                error(tostring(message) .. " Route: " .. routeContext, 0)
            end
            if #route == 0 then route = { { x = x, y = y, fromX = start.x, fromY = start.y, jump = false, duration = 0.2 } } end
            route = Navigation.straightRuns(route)
            App.navigationDebug = "Planned " .. #route .. " walking/jumping steps to " .. x .. ", " .. y
            local failed
            for _, waypoint in ipairs(route) do
                local began, movedAt, movedX, movedY = os.clock(), os.clock(), state.x, state.y
                local launchAt, airborne = nil, false
                while true do
                    worldCheck(worldName, token)
                    state = position()
                    local stepProceed, waited, stepPacing = collectionStep(state)
                    began, movedAt = began + waited, movedAt + waited
                    if not stepProceed then hold.direction, hold.jump = 0, false; return false end
                    state = position()
                    if not stepPacing and reached(state, waypoint.x + 0.5, waypoint.y + 1) then break end
                    assert(os.clock() < deadline, "Returning to the saved position timed out. Check the route.")
                    if G.focusedTextBox() or stepPacing then
                        hold.direction, hold.jump = 0, false
                        movedAt = os.clock()
                        if stepPacing then began, deadline = began + 0.025, deadline + 0.025 end
                    else
                        hold.direction = waypoint.drop and Navigation.dropSteer(state, waypoint)
                            or Navigation.steer(waypoint.x + 0.5 - state.x, state.vx or 0, state.grounded and 48 or 17)
                        if waypoint.jump and not launchAt and state.grounded then launchAt = os.clock() end
                        if launchAt and not state.grounded then airborne = true end
                        hold.jump = launchAt ~= nil and ((not airborne and os.clock() - launchAt < 0.2)
                            or (airborne and not state.grounded and (state.vy or 0) < -0.1))
                        if math.abs(state.x - movedX) + math.abs(state.y - movedY) > 0.08 then
                            movedX, movedY, movedAt = state.x, state.y, os.clock()
                        end
                        if os.clock() - movedAt > 1 or os.clock() - began > math.max(2.5, waypoint.duration + 1.5) then
                            failed = waypoint
                            break
                        end
                    end
                    pause(0.025, token)
                end
                hold.direction, hold.jump = 0, false
                if failed then break end
            end
            if failed then
                -- Langkah yang gagal dilarang, lalu rute direncanakan ulang (maks 4x).
                for _, edge in ipairs(failed.edges) do
                    local from = edge.fromY * r.world.w + edge.fromX
                    local destination = edge.y * r.world.w + edge.x
                    banned[from .. ":" .. destination .. ":" .. tostring(edge.jump)] = true
                end
                replans = replans + 1
                assert(replans <= 4, "The planned jumps did not reach the platforms. Check the entrance and route layout.")
                G.setStatus("Trying another route around the obstacle...")
                failed = nil
            end
        end
    end

    function Movement.moveTo(x, y, worldName, token, onStep)
        for attempt = 1, 3 do
            local result = table.pack(pcall(walkTo, x, y, worldName, token, onStep))
            if result[1] then return table.unpack(result, 2, result.n) end
            checkpoint(token)
            local pending = App.plantState and App.plantState.pending
            -- Clarissv: retry rute cuma untuk Rotation/Botting. Mode tunggal langsung lempar error.
            if App.job ~= "rotation" or App.pending > 0 or pending or not transientRouteFault(result[2]) or attempt == 3 then
                error(result[2], 0)
            end
            worldCheck(worldName, token)
            local hold = Movement.takeControls()
            hold.direction, hold.jump = 0, false
            App.navigationRecovery = worldName .. ": replanning walking route, attempt " .. (attempt + 1) .. "/3"
            G.setStatus("Movement delayed; " .. App.navigationRecovery .. "...")
            pause(0.5, token)
        end
    end

    function Movement.moveToPoint(point, token)
        return Movement.moveTo(point.standX or point.x, point.standY or point.y, point.world, token)
    end

    ---------------------------------------------------------------- tractor
    -- Tractor (Dear John) harus dicopot sebelum jalan/menanam, lalu sepatu lama dipasang lagi.
    local function rememberHarvestEquipment(gear)
        if App.harvestGearRestore then return end
        local previousFeet = gear.feet()
        App.harvestGearRestore = function()
            local current = gear.feet()
            if current ~= previousFeet then
                if current then gear.wear(current) end
                if previousFeet then gear.wear(previousFeet) end
            end
        end
    end
    function Movement.suspendHarvestVehicle(token)
        local r = Bridge.runtime()
        if not r.world.riding or not r.world.riding.harvest then return end
        local gear = r.harvestGear
        assert(gear and gear.feet(), "Remove your harvesting vehicle; equipment hooks are unavailable.")
        rememberHarvestEquipment(gear)
        gear.wear(gear.feet())
        local deadline = os.clock() + App.config.options.actionTimeout
        while r.world.riding and r.world.riding.harvest do
            checkpoint(token)
            assert(os.clock() < deadline, "The harvesting vehicle did not unequip.")
            pause(0.025, token)
        end
    end
    function Movement.harvestEquipmentScope(fn)
        local parentRestore = App.harvestGearRestore
        App.harvestGearRestore = nil
        local result = table.pack(pcall(fn))
        local restore = App.harvestGearRestore
        App.harvestGearRestore = parentRestore
        local restored, issue = true, nil
        if restore then restored, issue = pcall(restore) end
        if not restored then App.harvestGearError = tostring(issue) end
        if not result[1] then error(result[2], 0) end
        assert(restored, "Could not restore previous footwear: " .. tostring(issue))
        return table.unpack(result, 2, result.n)
    end

    ---------------------------------------------------------------- masuk world
    -- Titip loader ke executor: setelah pindah server, script otomatis jalan lagi dan resume.
    function Movement.queueResume()
        local queue, loader = G.queueOnTeleport, G.env.GrowbloxHanselLoaderURL
        if type(queue) ~= "function" or type(loader) ~= "string" or not loader:match("^https://") then return false end
        if not App.queued then
            -- Kode antrean membaca loader TERBARU dari file (ditulis tiap script dimuat / auto update),
            -- dan cuma jalan sekali walau antrean berisi lebih dari satu (misal setelah update).
            queue(table.concat({
                "local e = getgenv()",
                "if e.GrowbloxHanselQueuedRan then return end",
                "e.GrowbloxHanselQueuedRan = true",
                "e.GrowbloxHanselAutoResume = true",
                "local u = " .. string.format("%q", loader),
                "pcall(function() if isfile and isfile('GrowbloxHansel/loader-url.txt') then local t = readfile('GrowbloxHansel/loader-url.txt') if type(t) == 'string' and t:match('^https://') then u = t end end end)",
                "loadstring(game:HttpGet(u))()",
            }, "; "))
            App.queued = true
        end
        return true
    end

    -- Masuk world `name` dan tunggu sampai stabil. options:
    --   save()        simpan checkpoint SEBELUM masuk (bisa pindah server)
    --   label         nama task di pesan status, misal "planting"
    --   resumeButton  nama tombol resume di pesan status
    --   moving        true = jangan tunggu 1 detik & jangan sinkron tas (dipakai Moving Drops nanti)
    function Movement.enterWorld(name, token, options)
        options = options or {}
        Movement.suspendHarvestVehicle(token)
        local r = Bridge.runtime()
        local attempts, nextEntry, stableSince = 0, 0, nil
        local deadline = os.clock() + App.config.options.actionTimeout + 15
        Movement.releaseControls()
        while App.pending > 0 do
            checkpoint(token)
            assert(os.clock() < deadline, "A previous request did not settle; cannot enter another world yet.")
            pause(0.05, token)
        end
        while true do
            checkpoint(token)
            if (r.world.name ~= name or Bridge.pickerOpen(r)) and os.clock() >= nextEntry then
                attempts = attempts + 1
                assert(attempts <= 3, "World entry repeatedly returned to the picker: " .. name)
                assert(type(r.world.enter) == "function", "The world entry hook is unavailable.")
                if options.save then options.save() end
                local queued = Movement.queueResume()
                G.setStatus("Entering " .. name .. "...")
                local entered, message, teleport = Net.bounded(r.world.enter, App.config.options.actionTimeout + 15, token, name)
                if teleport then
                    App.teleporting = true
                    G.setStatus(queued and ("Changing servers; " .. (options.label or "the task") .. " will resume after loading.")
                        or ("Changing servers. Run the loader after arrival, then use " .. (options.resumeButton or "Resume") .. "."))
                    local teleportDeadline = os.clock() + 45
                    while os.clock() < teleportDeadline do pause(0.2, token) end
                    error("Server teleport did not finish. Use " .. (options.resumeButton or "Resume") .. " after arrival.")
                end
                if not entered then assert(attempts < 3, tostring(message or "Could not enter " .. name))
                elseif r.picker and r.world.name == name then r.picker.complete() end
                nextEntry, stableSince = os.clock() + 2, nil
                deadline = os.clock() + App.config.options.actionTimeout + 15
            end
            if r.world.name == name and not Bridge.pickerOpen(r) and (not r.body or Bridge.avatarReady(r))
                and not G.frozen() then
                stableSince = stableSince or os.clock()
                if os.clock() - stableSince >= (options.moving and 0 or 1) then break end
            else stableSince = nil end
            assert(os.clock() < deadline, "World or avatar did not finish loading: " .. name)
            pause(0.1, token)
        end
        App.teleporting = false
        -- World yang dimuat ulang bisa memasang tractor lagi. Copot sebelum jalan.
        Movement.suspendHarvestVehicle(token)
        Movement.takeControls()
        if not options.moving then Actions.refreshInventory(token) end
    end

    -- Error biasa saat aksi bisa jadi efek keluar world / avatar mati yang belum kelihatan
    -- (classifyPNBFault Clarissv). Tunggu 1,5 detik: kalau ternyata karena itu, ubah jadi error
    -- "recoverable" supaya task bisa masuk lagi ke world. Dipakai PNB dan Harvest.
    ---------------------------------------------------------------- respawn ke box dekat pintu
    -- Adaptasi returnToStorage Clarissv ("Respawn to Farm storage"). Respawn = karakter muncul lagi
    -- di pintu putih (Main Door). Kalau Display Box dekat pintu itu dan karakter jauh dari box,
    -- respawn lebih cepat daripada jalan. Dipakai Harvest (tas penuh) dan Rotation (simpan seed).
    local DOOR_RANGE, WALK_RANGE = 8, 10
    function Movement.mainDoor(r)
        for y = 0, r.world.h - 1 do
            local row = r.world.fg[y]
            for x = 0, r.world.w - 1 do
                local id = row and row[x]
                local item = id and r.items[id]
                if id == 6 or (item and type(item.name) == "string" and item.name:lower() == "main door") then
                    return { x = x, y = y }
                end
            end
        end
    end
    -- Return: true kalau respawn dipakai, false + alasan kalau tetap jalan kaki.
    function Movement.respawnNear(box, token)
        local r = Bridge.runtime()
        if not App.config.options.respawnStore then return false, "setting Respawn ke box mati" end
        local respawn = r.respawn or (r.world and r.world.respawn)
        if type(respawn) ~= "function" then return false, "hook respawn tidak ada" end
        local door = Movement.mainDoor(r)
        if not door then return false, "pintu putih (Main Door) tidak ketemu" end
        local standX, standY = box.standX or box.x, box.standY or box.y
        local doorGap = math.abs(door.x - standX) + math.abs(door.y - standY)
        if doorGap > DOOR_RANGE then return false, "box jauh dari pintu (" .. doorGap .. " tile)" end
        local here = Bridge.position()
        local walk = math.abs(here.x - (standX + 0.5)) + math.abs(here.y - (standY + 1))
        if walk <= WALK_RANGE then return false, "sudah dekat box" end
        Movement.takeControls()
        local beforeX, beforeY, began = here.x, here.y, os.clock()
        G.setStatus("Respawn ke pintu (Display Box dekat pintu)...")
        Net.bounded(respawn, App.config.options.actionTimeout, token)
        local deadline, moved, stable = os.clock() + math.max(15, App.config.options.actionTimeout), false, nil
        while true do
            checkpoint(token)
            local state = Bridge.avatarState(r)
            if not state or not state.active or state.dead
                or math.abs(state.x - beforeX) + math.abs(state.y - beforeY) > 0.5 then moved = true end
            if moved and state and state.active and not state.dead and state.grounded then
                stable = stable or os.clock()
                if os.clock() - stable >= 0.25 then break end
            else stable = nil end
            assert(os.clock() < deadline, "Respawn tidak selesai; item tetap di tas.")
            pause(0.05, token)
        end
        Bridge.worldCheck(box.world, token)
        App.respawnInfo = string.format("%s respawn %.1fd (hemat jalan %d tile)", os.date("%H:%M:%S"), os.clock() - began, math.floor(walk))
        App.respawnCount = (App.respawnCount or 0) + 1
        return true
    end

    -- Error apa pun (termasuk "attempt to index nil" karena world/karakter hilang) yang ternyata
    -- akibat keluar world, pindah world, atau avatar mati -> "recoverable". Membaca status game di sini
    -- juga dijaga: kalau gagal dibaca, anggap sedang keluar world (bukan alasan untuk stop).
    function Movement.classifyFault(problem, token, name)
        if type(problem) == "table" and problem.recoverable then return problem end
        if tostring(problem):find("Stopped", 1, true) then return problem end
        pcall(Movement.releaseControls)
        local deadline = os.clock() + 1.5
        repeat
            checkpoint(token)
            local ok, verdict = pcall(function()
                local r = Bridge.runtime()
                local current = type(r.world) == "table" and r.world.name or nil
                if current == "" or current == nil or Bridge.pickerOpen(r) then
                    return Bridge.recoverable("Keluar ke world picker saat aksi: " .. tostring(problem), name, "worldPicker")
                end
                if name and current ~= name then
                    return Bridge.recoverable("Pindah ke world " .. tostring(current) .. " saat aksi: " .. tostring(problem), name, "worldChanged")
                end
                if r.body and not Bridge.avatarReady(r) then
                    return Bridge.recoverable("Avatar tidak aktif saat aksi: " .. tostring(problem), name, "avatar")
                end
            end)
            if not ok then
                return Bridge.recoverable("Status game tidak terbaca (" .. tostring(verdict) .. ") saat aksi: " .. tostring(problem), name, "unreadable")
            end
            if verdict then return verdict end
            if os.clock() >= deadline then return problem end
            pause(0.1, token)
        until false
    end

    return Movement
end

end)()

-- ===== src/storage.lua =====
__modules["storage"] = (function(...)
-- storage.lua: Display Box. Baca isi, ambil (withdraw), setor (deposit), dan simpan posisi box.
-- Diadaptasi dari Clarissv main.lua v0.1.43: boxRows, storageCount, settleStorage, closerStorage,
-- storageRequest, withdraw, deposit, captureNearby, pointText. Hook Botting dibuang.
return function(G)
    local App, Core, Bridge, Net, Actions, Movement, Navigation =
        G.App, G.Core, G.Bridge, G.Net, G.Actions, G.Movement, G.Navigation
    local Storage = {}
    local worldCheck, position, pause = Bridge.worldCheck, Bridge.position, Net.pause
    local count, refreshInventory = Actions.count, Actions.refreshInventory

    -- Isi box = daftar baris { itemId, jumlah }.
    function Storage.boxRows(point)
        local r = Bridge.runtime()
        assert(r.world.name == point.world, "Storage box is in another world.")
        local item = r.items[Actions.tileAt(point.x, point.y)]
        assert(item and item.display and not item.displayOne, "The saved tile is not a Display Box.")
        return r.world.displays.get(point.x, point.y) or {}
    end
    -- Hitung item di box. Item lain selain id/companionId = error (box harus khusus).
    function Storage.count(point, id, companionId)
        return Core.storageCount(Storage.boxRows(point), id, companionId)
    end

    local function settleStorage(point, token, refused)
        local hold = Movement.takeControls()
        hold.direction, hold.jump = 0, false
        local deadline = os.clock() + 0.75
        while math.abs(position().vx or 0) > 0.2 and os.clock() < deadline do pause(0.025, token) end
        if refused then pause(0.15, token) end -- beri waktu posisi baru sampai ke server
        worldCheck(point.world, token)
    end

    -- Server bilang "Get closer"? Cari tile berpijak paling dekat ke box lalu mendekat.
    local function closerStorage(point, token)
        local r, state = worldCheck(point.world, token), position()
        local map, goals = Movement.navigationMap(r), {}
        for y = math.max(0, point.y - 1), math.min(r.world.h - 2, point.y + 1) do
            for x = math.max(0, point.x - 1), math.min(r.world.w - 1, point.x + 1) do
                goals[#goals + 1] = { x = x, y = y, score = (x - point.x) ^ 2 + (y - point.y) ^ 2 }
            end
        end
        table.sort(goals, function(a, b)
            if a.score ~= b.score then return a.score < b.score end
            local ad = math.abs(a.x + 0.5 - state.x) + math.abs(a.y + 1 - state.y)
            local bd = math.abs(b.x + 0.5 - state.x) + math.abs(b.y + 1 - state.y)
            if ad ~= bd then return ad < bd end
            return a.y == b.y and a.x < b.x or a.y < b.y
        end)
        local start = { x = math.floor(state.x), y = math.floor(state.y - 0.01) }
        local goal
        for _, candidate in ipairs(goals) do
            local route = Navigation.plan(map, start, candidate, { fullWorld = true, maxNodes = math.min(12000, map.w * map.h),
                step = function() pause(0, token); worldCheck(point.world, token) end })
            if route then goal = candidate; break end
        end
        assert(goal, "No supported storage approach reaches this Display Box. Check the nearby floor or platform.")
        Movement.moveTo(goal.x, goal.y, point.world, token)
        if goal.x ~= point.x then
            -- Geser di dalam tile berpijak ke arah box, badan tetap di tile itu.
            local target = goal.x + 0.5 + (point.x > goal.x and 0.18 or -0.18)
            local hold, deadline = Movement.takeControls(), os.clock() + 2
            while os.clock() < deadline do
                state = position()
                assert(state.grounded and math.abs(state.y - (goal.y + 1)) < 0.25, "Storage approach left its supported tile.")
                if math.abs(target - state.x) < 0.075 and math.abs(state.vx or 0) < 0.2 then break end
                hold.direction, hold.jump = Navigation.steer(target - state.x, state.vx or 0), false
                pause(0.025, token)
                worldCheck(point.world, token)
            end
            hold.direction, hold.jump = 0, false
        end
        App.storageApproachDebug = point.world .. " box " .. point.x .. ", " .. point.y .. "; closer stand " .. goal.x .. ", " .. goal.y
        settleStorage(point, token, true)
    end

    -- world.call("DisplayItem", ...) dari game mengembalikan (ok, hasil). Timeout tetap jadi error.
    -- Coba request box maks 3x. Yang diulang CUMA penolakan "Get closer"; error lain dilempar.
    local function storageRequest(point, token, request)
        for attempt = 1, 3 do
            local ok, result = request()
            if ok then return ok, result end
            if type(result) ~= "string" or not result:find("Get closer to the Display Box.", 1, true) or attempt == 3 then
                return ok, result
            end
            G.setStatus("Display Box requires a closer approach; retry " .. (attempt + 1) .. "/3...")
            closerStorage(point, token)
        end
    end

    -- Ambil semua item `id` (dan companionId) dari box. onReady dipanggil tepat sebelum request,
    -- biasanya untuk menulis checkpoint "pickupPending". Return: jumlah id, jumlah companion.
    function Storage.withdraw(point, id, token, companionId, onReady)
        worldCheck(point.world, token)
        Movement.moveToPoint(point, token)
        settleStorage(point, token)
        if Storage.count(point, id, companionId) == 0
            and (not companionId or Storage.count(point, companionId, id) == 0) then return 0, 0 end
        refreshInventory(token)
        assert(Bridge.runtime().inventory:room(id) > 0, "Your backpack has no room for this block.")
        local before, companionBefore = count(id), companionId and count(companionId) or 0
        if onReady then onReady(before) end
        local ok, result = storageRequest(point, token, function()
            return Net.bounded(Bridge.runtime().world.call, App.config.options.actionTimeout, token,
                "DisplayItem", point.x, point.y, nil)
        end)
        assert(ok and type(result) == "table", type(result) == "string" and result or "Storage withdrawal failed.")
        local taken, companionTaken = 0, 0
        for _, row in pairs(result.taken or {}) do
            assert(row[1] == id or companionId and row[1] == companionId,
                "The storage box changed and another item was withdrawn. Check your backpack.")
            assert(type(row[2]) == "number" and row[2] > 0 and row[2] == math.floor(row[2]), "Invalid storage withdrawal count.")
            if row[1] == id then taken = taken + row[2] else companionTaken = companionTaken + row[2] end
        end
        refreshInventory(token)
        assert(taken + companionTaken > 0 and count(id) == before + taken, "The server did not confirm blocks in your backpack.")
        if companionId then
            assert(count(companionId) == companionBefore + companionTaken, "The server did not confirm seeds in your backpack.")
        end
        return taken, companionTaken
    end

    function Storage.deposit(point, id, amount, token, onReady, companionId)
        worldCheck(point.world, token)
        Movement.moveToPoint(point, token)
        settleStorage(point, token)
        Storage.count(point, id, companionId)
        refreshInventory(token)
        if onReady then onReady(count(id)) end
        amount = math.min(math.floor(amount), count(id))
        assert(amount > 0, "No items are available to deposit.")
        local before = count(id)
        local ok, result = storageRequest(point, token, function()
            return Net.bounded(Bridge.runtime().world.call, App.config.options.actionTimeout, token,
                "DisplayItem", point.x, point.y, id, nil, nil, amount, point.x + 0.5)
        end)
        assert(ok, type(result) == "string" and result or "The storage deposit was rejected.")
        refreshInventory(token)
        assert(count(id) <= before - amount, "The server did not confirm the storage deposit.")
        return amount
    end

    -- Jumlah item `id` di box, tanpa peduli item lain di box itu (box campur).
    function Storage.countOnly(point, id)
        return Core.itemCount(Storage.boxRows(point), id)
    end

    -- Ambil HANYA item `id` dari box yang juga berisi item lain (box campur).
    -- Game cuma punya perintah "ambil semua" (DisplayItem x, y, nil), jadi caranya: ambil semua,
    -- lalu item lain langsung ditaruh balik ke box yang sama (DisplayItem deposit).
    -- Box yang isinya cuma `id` memakai Storage.withdraw biasa. Return: jumlah `id` yang diambil.
    function Storage.withdrawSelected(point, id, token, onReady)
        local others = false
        for _, row in pairs(Storage.boxRows(point)) do
            if type(row) == "table" and row[1] ~= id then others = true end
        end
        if not others then return (Storage.withdraw(point, id, token, nil, onReady)) end
        worldCheck(point.world, token)
        Movement.moveToPoint(point, token)
        settleStorage(point, token)
        if Storage.countOnly(point, id) == 0 then return 0 end
        refreshInventory(token)
        assert(Bridge.runtime().inventory:room(id) > 0, "Tas tidak punya ruang untuk item ini.")
        local before = count(id)
        if onReady then onReady(before) end
        local ok, result = storageRequest(point, token, function()
            return Net.bounded(Bridge.runtime().world.call, App.config.options.actionTimeout, token,
                "DisplayItem", point.x, point.y, nil)
        end)
        assert(ok and type(result) == "table", type(result) == "string" and result or "Storage withdrawal failed.")
        refreshInventory(token)
        local taken, back = 0, {}
        for _, row in pairs(result.taken or {}) do
            assert(type(row[2]) == "number" and row[2] > 0 and row[2] == math.floor(row[2]), "Invalid storage withdrawal count.")
            if row[1] == id then taken = taken + row[2] else table.insert(back, { row[1], row[2] }) end
        end
        -- Taruh balik item lain. Gagal di sini = berhenti dengan pesan jelas (item ada di tas).
        for _, row in ipairs(back) do
            local itemId, amount = row[1], math.min(row[2], count(row[1]))
            if amount > 0 then
                local before2 = count(itemId)
                local put, issue = storageRequest(point, token, function()
                    return Net.bounded(Bridge.runtime().world.call, App.config.options.actionTimeout, token,
                        "DisplayItem", point.x, point.y, itemId, nil, nil, amount, point.x + 0.5)
                end)
                assert(put, "Item lain (" .. tostring(itemId) .. " x" .. amount .. ") terambil dan gagal ditaruh balik ke box: "
                    .. tostring(issue) .. ". Item itu ada di tas.")
                refreshInventory(token)
                assert(count(itemId) <= before2 - amount, "Server tidak mengonfirmasi item " .. tostring(itemId) .. " kembali ke box. Item itu ada di tas.")
            end
        end
        assert(count(id) == before + taken, "The server did not confirm the withdrawn items in your backpack.")
        return taken
    end

    ---------------------------------------------------------------- deteksi box otomatis
    -- Cari Display Box di world sekarang yang boleh dipakai untuk menyimpan `allowed` (daftar id):
    -- isinya kosong atau hanya item `allowed`. Box yang sudah berisi item itu didahulukan, lalu box
    -- kosong; kalau seri, yang paling dekat karakter. Posisi berdiri = tile di samping box (kiri,
    -- kanan, di box itu sendiri, 2 tile kiri/kanan) yang bisa dipijak. Return: point box.
    function Storage.findBox(allowed)
        local r, state = Bridge.runtime(), position()
        local map = Movement.navigationMap(r)
        local ok = {}
        for _, id in ipairs(allowed) do ok[id] = true end
        local function standable(x, y)
            if x < 0 or x >= r.world.w or y < 0 or y + 1 >= r.world.h then return false end
            return not map.solid(x, y) and (map.solid(x, y + 1) or map.platform(x, y + 1)) and true or false
        end
        local best, bestRank
        local seen, skipped = 0, 0
        for y = 0, r.world.h - 1 do
            local row = r.world.fg[y]
            for x = 0, r.world.w - 1 do
                local item = row and r.items[row[x] or 0]
                if item and item.display and not item.displayOne then
                    seen = seen + 1
                    local rows = r.world.displays.get(x, y) or {}
                    local usable, used = true, false
                    for _, entry in pairs(rows) do
                        if type(entry) == "table" then
                            if ok[entry[1]] then used = true else usable = false end
                        end
                    end
                    local stand
                    for _, dx in ipairs({ -1, 1, 0, -2, 2 }) do
                        if standable(x + dx, y) then stand = { x = x + dx, y = y }; break end
                    end
                    if usable and stand then
                        local distance = math.abs(x + 0.5 - state.x) + math.abs(y + 1 - state.y)
                        local rank = (used and 0 or 100000) + distance
                        if not bestRank or rank < bestRank then
                            best, bestRank = { world = r.world.name, x = x, y = y, standX = stand.x, standY = stand.y }, rank
                        end
                    else
                        skipped = skipped + 1
                    end
                end
            end
        end
        assert(best, string.format("Tidak ada Display Box yang bisa dipakai di %s (%d box, %d berisi item lain / tidak bisa didekati). "
            .. "Taruh 1 Display Box kosong di world ini.", r.world.name, seen, skipped))
        return best
    end

    ---------------------------------------------------------------- simpan posisi box
    function Storage.pointText(point)
        if not point then return "Belum disimpan" end
        local text = point.world .. "  |  tile " .. point.x .. ", " .. point.y
        if point.standX then text = text .. "  |  stand " .. point.standX .. ", " .. point.standY end
        return text
    end

    -- Cari box/door terdekat di sekitar karakter (3 tile kiri-kanan, 2 atas, 1 bawah) dan simpan
    -- posisinya beserta tempat karakter berdiri sekarang.
    function Storage.captureNearby(key, kind)
        local r, state = Bridge.runtime(), position()
        local standX, standY = math.floor(state.x), math.floor(state.y - 0.01)
        local candidates = {}
        for y = math.max(0, standY - 2), math.min(r.world.h - 1, standY + 1) do
            for x = math.max(0, standX - 3), math.min(r.world.w - 1, standX + 3) do
                local item = r.items[Actions.tileAt(x, y)]
                local matches = item and (kind == "box" and item.display and not item.displayOne
                    or kind == "door" and (item.door or item.vip))
                if matches then
                    local distance = (x + 0.5 - state.x) ^ 2 + (y + 1 - state.y) ^ 2
                    table.insert(candidates, { x = x, y = y, distance = distance })
                end
            end
        end
        table.sort(candidates, function(a, b) return a.distance < b.distance end)
        assert(candidates[1], "Stand beside the " .. kind .. " and try saving again.")
        assert(not candidates[2] or math.abs(candidates[1].distance - candidates[2].distance) > 0.1,
            "Two targets are equally close. Stand closer to the one you want to save.")
        local chosen = candidates[1]
        App.config.points[key] = { world = r.world.name, x = chosen.x, y = chosen.y, standX = standX, standY = standY }
        return App.config.points[key]
    end

    return Storage
end

end)()

-- ===== src/drops.lua =====
__modules["drops"] = (function(...)
-- drops.lua: pungut drop (blok, seed, gem) dari lantai lewat UID pickup.
-- Diadaptasi dari Clarissv main.lua v0.1.43: takeDropBatch dan collectDrops.
-- Bedanya: area pungut bisa diatur (radius), dan drop yang 3x ditolak server cuma dilewati,
-- tidak menghentikan task (grid PNB 5x5 menjatuhkan drop lebih jauh dari grid 1 tile Clarissv).
return function(G)
    local App, Bridge, Net, Actions, Movement = G.App, G.Bridge, G.Net, G.Actions, G.Movement
    local Drops = { GEM = 112 }
    local worldCheck, position, pause, checkpoint = Bridge.worldCheck, Bridge.position, Net.pause, Net.checkpoint


    -- Kirim maksimal 8 permintaan pickup sekaligus, lalu tunggu semua balasan.
    -- Tiap drop "dipesan" dulu (drop.taking) supaya pickup bawaan game tidak mengambil yang sama.
    function Drops.takeBatch(worldName, targets, attempts, retryAt, eligible, token, limit)
        local jobs = Drops.issueTakes(worldName, targets, attempts, retryAt, eligible, token, limit)
        local deadline = os.clock() + App.config.options.actionTimeout
        local results = {}
        for _, job in ipairs(jobs) do
            local amount = Net.awaitRequest(job.request, deadline, token)
            if amount > 0 then attempts[job.uid] = 0 end
            table.insert(results, { uid = job.uid, id = job.id, amount = amount })
        end
        return results
    end
    -- Kirim permintaan pickup tanpa menunggu balasan (dipakai juga saat jalan). Return: daftar job.
    function Drops.issueTakes(worldName, targets, attempts, retryAt, eligible, token, limit)
        local r = worldCheck(worldName, token)
        local take = App.controls and App.controls.takeDrop or r.world.takeDrop
        assert(type(take) == "function" and type(r.world.dropTaken) == "function",
            "The loose-drop pickup hooks are unavailable. Copy diagnostics from Settings.")
        local jobs, reserved = {}, {}
        for _, drop in ipairs(targets) do
            if #jobs >= (limit or 8) then break end
            worldCheck(worldName, token)
            local present = false
            for _, current in pairs(r.world.dropList()) do if current == drop then present = true; break end end
            local room = drop.id == Drops.GEM and 65535 or math.max(0, r.inventory:room(drop.id) - (reserved[drop.id] or 0))
            local want = math.floor(math.min(drop.n, room, 65535))
            if want > 0 and present and eligible(drop) then
                local before, grid, uid, id = drop.n, r.world.fg, drop.uid, drop.id
                local here = position()
                local distance = math.max(math.abs(drop.x - here.x), math.abs(drop.y - (here.y - 0.5)))
                if id ~= Drops.GEM then reserved[id] = (reserved[id] or 0) + want end
                attempts[uid] = (attempts[uid] or 0) + 1
                if App.controls then App.controls.suppressedTakes[uid] = nil end
                drop.taking = true
                local request = Net.beginRequest(function()
                    local ok, result = pcall(function()
                        local amount = take(uid, want)
                        if amount == nil then amount = 0 end
                        assert(type(amount) == "number" and amount >= 0 and amount <= want
                            and amount == math.floor(amount), "Invalid pickup response from the server.")
                        Drops.noteReach(distance, amount > 0)
                        if amount > 0 and r.world.name == worldName and r.world.fg == grid then
                            r.world.dropTaken(uid, math.min(drop.n, math.max(0, before - amount)))
                            if id == Drops.GEM then App.stats.gems = App.stats.gems + amount end
                        elseif amount == 0 then
                            retryAt[uid], drop.refused = os.clock() + 1, os.clock()
                        end
                        return amount
                    end)
                    drop.taking = false
                    assert(ok, tostring(result))
                    return result
                end)
                table.insert(jobs, { request = request, uid = uid, id = id })
            end
        end
        return jobs
    end

    -- Pungut sambil jalan: step(state) dipanggil tiap langkah dan langsung mengirim pickup untuk drop
    -- dalam jangkauan (maks 8 sedang jalan) TANPA berhenti menunggu balasan server. finish()
    -- menunggu semua balasan. pending(area) = masih ada drop cocok di area (belum diambil).
    function Drops.sweeper(worldName, ids, token)
        local r = Bridge.runtime()
        local all, wanted = ids == "all", {}
        if not all then for _, id in ipairs(ids) do wanted[id] = true end end
        local jobs, requested, attempts, retryAt = {}, {}, {}, {}
        local sweep = { taken = 0 }
        local function matches(drop)
            return type(drop) == "table" and not drop.display and not drop.pending and type(drop.uid) == "number"
                and type(drop.n) == "number" and drop.n > 0 and (all or wanted[drop.id])
                and type(drop.x) == "number" and type(drop.y) == "number"
                and (drop.id == Drops.GEM or r.inventory:room(drop.id) > 0)
        end
        function sweep.step(state)
            local active = 0
            for _, job in ipairs(jobs) do if not job.request.done then active = active + 1 end end
            if active >= 8 then return end
            local reach, standY = Drops.reach(), math.floor(state.y - 0.01)
            local function inReach(drop)
                return matches(drop) and not drop.taking and not requested[drop.uid]
                    and (drop.readyAt or 0) <= os.clock()
                    and math.abs(drop.x - state.x) <= reach.radius
                    and drop.y >= standY - reach.up and drop.y <= standY + reach.down
            end
            local targets = {}
            for _, drop in pairs(r.world.dropList()) do
                if inReach(drop) then table.insert(targets, drop) end
            end
            if #targets == 0 then return end
            for _, job in ipairs(Drops.issueTakes(worldName, targets, attempts, retryAt, inReach, token, 8 - active)) do
                requested[job.uid] = true
                table.insert(jobs, job)
            end
        end
        function sweep.finish()
            local deadline, any = os.clock() + App.config.options.actionTimeout, false
            for _, job in ipairs(jobs) do
                local ok, amount = pcall(Net.awaitRequest, job.request, deadline, token)
                if not ok then
                    if type(amount) == "table" or tostring(amount):find("Stopped", 1, true) then error(amount, 0) end
                elseif amount > 0 then
                    any, sweep.taken = true, sweep.taken + 1
                else
                    requested[job.uid] = nil -- ditolak (kejauhan): boleh dicoba lagi dari dekat
                end
            end
            jobs = {}
            if any then Actions.refreshInventory(token) end
        end
        function sweep.pending(anchor, area)
            for _, drop in pairs(r.world.dropList()) do
                if matches(drop) and not drop.taking and math.abs(drop.x - (anchor.x + 0.5)) <= area.radius
                    and drop.y >= anchor.y - area.up and drop.y <= anchor.y + area.down then return true end
            end
            return false
        end
        return sweep
    end

    -- Pungut semua drop dengan id di `ids` dalam kotak di sekitar posisi berdiri `anchor`:
    -- |x - tengah| <= radius, dan y dari anchor.y - up sampai anchor.y + down.
    -- Return: tabel { [id] = jumlah yang berhasil dipungut }, dan jumlah drop yang dilewati.
    -- options.onlyIfPresent = true: kalau di area belum ada drop yang cocok, langsung selesai tanpa
    -- jeda dan tanpa request inventory (hemat ~0,3-0,5 detik per panggilan di PNB/panen; drop yang
    -- muncul belakangan terambil di panggilan berikutnya).
    function Drops.collectNear(anchor, ids, token, options)
        options = options or {}
        local radius, up, down = options.radius or 1.25, options.up or 1.5, options.down or 1.25
        if options.onlyIfPresent then
            local r, all, any = Bridge.runtime(), ids == "all", false
            local wanted = {}
            if not all then for _, id in ipairs(ids) do wanted[id] = true end end
            for _, drop in pairs(r.world.dropList()) do
                if type(drop) == "table" and not drop.display and type(drop.n) == "number" and drop.n > 0
                    and (all or wanted[drop.id]) and type(drop.x) == "number" and type(drop.y) == "number"
                    and math.abs(drop.x - (anchor.x + 0.5)) <= radius
                    and drop.y >= anchor.y - up and drop.y <= anchor.y + down then any = true; break end
            end
            if not any then App.collectSkips = (App.collectSkips or 0) + 1; return {}, 0 end
        end
        pause(App.config.options.collectDelay, token)
        return Movement.withoutPickups(function()
            local r = worldCheck(anchor.world, token)
            Actions.refreshInventory(token) -- selesaikan pickup bawaan game yang masih jalan
            -- ids = "all" -> semua item (Auto Collect). options.attempts boleh dibawa antar panggilan
            -- supaya drop yang terus ditolak server (kejauhan) tidak di-spam.
            local attempts, retryAt, deadline = options.attempts or {}, {}, os.clock() + App.config.options.actionTimeout
            local collected, gemsTaken, skipped = {}, 0, 0
            local wanted = {}
            local all = ids == "all"
            if not all then for _, id in ipairs(ids) do wanted[id] = true end end
            local function nearby(drop)
                return not drop.display and not drop.pending and type(drop.uid) == "number"
                    and type(drop.n) == "number" and drop.n > 0 and not drop.taking and (all or wanted[drop.id])
                    and type(drop.x) == "number" and type(drop.y) == "number"
                    and math.abs(drop.x - (anchor.x + 0.5)) <= radius
                    and drop.y >= anchor.y - up and drop.y <= anchor.y + down
            end
            while true do
                worldCheck(anchor.world, token)
                if options.stopIf and options.stopIf() then return collected, skipped end
                if options.onEachRound then options.onEachRound() end
                local targets, waiting = {}, false
                skipped = 0
                for _, drop in pairs(r.world.dropList()) do
                    if nearby(drop) then
                        local room = drop.id == Drops.GEM and 65535 or r.inventory:room(drop.id)
                        if room > 0 then
                            retryAt[drop.uid] = retryAt[drop.uid] or ((drop.refused or -math.huge) + 1)
                            if (attempts[drop.uid] or 0) >= (options.maxAttempts or 3) then skipped = skipped + 1
                            elseif math.max(drop.readyAt or 0, retryAt[drop.uid]) > os.clock() then waiting = true
                            else table.insert(targets, drop) end
                        end
                    end
                end
                if #targets == 0 then
                    if gemsTaken > 0 and r.gemHud then
                        local ok, gems = pcall(Net.bounded, r.world.call, App.config.options.actionTimeout, token, "GetGems")
                        if ok and type(gems) == "number" then r.gemHud.setGems(gems) end
                    end
                    if not waiting or os.clock() >= deadline then return collected, skipped end
                    pause(0.05, token)
                else
                    local accepted = false
                    for _, result in ipairs(Drops.takeBatch(anchor.world, targets, attempts, retryAt, nearby, token)) do
                        if result.amount > 0 then
                            accepted = true
                            collected[result.id] = (collected[result.id] or 0) + result.amount
                            if result.id == Drops.GEM then gemsTaken = gemsTaken + result.amount end
                        end
                    end
                    if accepted then
                        Actions.refreshInventory(token)
                        deadline = os.clock() + App.config.options.actionTimeout
                    end
                end
            end
        end)
    end

    -- Ukur jangkauan pungut server: tiap pungut (dari posisi berdiri, tanpa jalan) dicatat jaraknya
    -- (tile, ambil yang terbesar dari jarak samping / atas-bawah) dan diterima atau ditolak.
    -- Hasilnya muncul di diagnostics, dan jarak terjauh yang pernah diterima dipakai sebagai
    -- jangkauan pungut berikutnya (Drops.reach), jadi karakter tidak jalan kalau tidak perlu.
    App.reach = App.reach or { ok = 0, no = 0, okMax = 0, noMin = math.huge }
    function Drops.noteReach(distance, accepted)
        local stat = App.reach
        if accepted then
            stat.ok, stat.okMax = stat.ok + 1, math.max(stat.okMax, distance)
        else
            stat.no, stat.noMin = stat.no + 1, math.min(stat.noMin, distance)
        end
    end
    function Drops.reachText()
        local stat = App.reach
        return string.format("diterima %dx (terjauh %.2f tile), ditolak %dx (terdekat %s); dipakai %.2f tile",
            stat.ok, stat.okMax, stat.no, stat.noMin == math.huge and "-" or string.format("%.2f tile", stat.noMin), Drops.reach().radius)
    end

    -- Jangkauan pungut server Growblox: bawaan dari Clarissv collectDrops (1.25 tile ke samping,
    -- 1.5 ke atas, 1.25 ke bawah). Kalau server terbukti menerima lebih jauh, pakai jarak itu (maks 5).
    Drops.REACH = { radius = 1.25, up = 1.5, down = 1.25 }
    function Drops.reach()
        local learned = math.min(5, App.reach.okMax)
        if learned <= Drops.REACH.radius then return Drops.REACH end
        return { radius = learned, up = math.max(1.5, learned), down = math.max(1.25, learned) }
    end

    -- Pungut semua drop `ids` di dalam `area` sekitar `anchor`. Yang di luar jangkauan server
    -- didatangi: cari lantai terdekat yang bisa dipakai memungut (Navigation.pickupGoal, sama
    -- seperti panen Clarissv), jalan ke sana, pungut, lanjut ke drop berikutnya.
    -- Karakter TIDAK dikembalikan ke anchor; pemanggil yang mengurus (ensureAnchor).
    -- options: { filter(drop) -> bool, maxTrips (bawaan 40), onTrip(drop) }
    -- Return: { [id] = jumlah }, jumlah drop yang dilewati (tidak terjangkau / ditolak).
    function Drops.collectArea(anchor, ids, token, area, options)
        options = options or {}
        local r = worldCheck(anchor.world, token)
        local total, skipped, attempts = {}, {}, {}
        local function add(got)
            for id, n in pairs(got or {}) do total[id] = (total[id] or 0) + n end
        end
        local all, wanted = ids == "all", {}
        if not all then for _, id in ipairs(ids) do wanted[id] = true end end
        local function inArea(drop)
            return not drop.display and type(drop.uid) == "number" and type(drop.n) == "number" and drop.n > 0
                and (all or wanted[drop.id]) and type(drop.x) == "number" and type(drop.y) == "number"
                and not skipped[drop.uid] and (not options.filter or options.filter(drop))
                and (drop.id == Drops.GEM or r.inventory:room(drop.id) > 0)
                and math.abs(drop.x - (anchor.x + 0.5)) <= area.radius
                and drop.y >= anchor.y - area.up and drop.y <= anchor.y + area.down
        end
        -- 1) yang sudah terjangkau dari posisi sekarang
        local here = position()
        local stand = { world = anchor.world, x = math.floor(here.x), y = math.floor(here.y - 0.01) }
        -- Selama server belum pernah menolak, coba SELURUH area sekali dari tempat berdiri (tanpa
        -- jalan) untuk mengukur jangkauan server. Setelah ada penolakan, cuma yang terbukti terjangkau.
        local reach, probing = Drops.reach(), App.reach.no == 0
        local near = probing and { radius = area.radius + math.abs(stand.x - anchor.x), up = area.up + 1, down = area.down + 1 } or reach
        add(Drops.collectNear(stand, ids, token, { radius = near.radius, up = near.up,
            down = near.down, attempts = attempts, maxAttempts = probing and 1 or 3 }))
        -- 2) datangi sisanya satu per satu, terdekat dulu
        for _ = 1, options.maxTrips or 40 do
            checkpoint(token)
            local state, nearest, best = position(), nil, math.huge
            for _, drop in pairs(r.world.dropList()) do
                if inArea(drop) then
                    local d = math.abs(drop.x - state.x) + math.abs(drop.y - (state.y - 0.5)) * 2
                    if d < best then nearest, best = drop, d end
                end
            end
            if not nearest then break end
            local goal = G.Navigation.pickupGoal(Movement.navigationMap(r), state, nearest, {
                step = function() pause(0, token); worldCheck(anchor.world, token) end })
            if not goal then
                skipped[nearest.uid] = true -- tidak ada lantai yang bisa dipakai memungut
            else
                if options.onTrip then options.onTrip(nearest) end
                local ok, problem = pcall(Movement.moveTo, goal.x, goal.y, anchor.world, token)
                if not ok then
                    if type(problem) == "table" or tostring(problem):find("Stopped", 1, true) then error(problem, 0) end
                    skipped[nearest.uid] = true
                else
                    local spot = { world = anchor.world, x = goal.x, y = goal.y }
                    local got = Drops.collectNear(spot, ids, token, { radius = Drops.REACH.radius,
                        up = Drops.REACH.up, down = Drops.REACH.down, attempts = attempts })
                    add(got)
                    for _, drop in pairs(r.world.dropList()) do
                        if drop == nearest and drop.n > 0 then
                            -- masih ada setelah didatangi = server menolak 3x; jangan diulang terus
                            if (attempts[drop.uid] or 0) >= 3 or not (got and next(got)) then skipped[drop.uid] = true end
                        end
                    end
                end
            end
        end
        local n = 0
        for _ in pairs(skipped) do n = n + 1 end
        return total, n
    end

    return Drops
end

end)()

-- ===== src/jobs.lua =====
__modules["jobs"] = (function(...)
-- jobs.lua: mulai/stop task (Planting, Harvest, PNB, Rotation) dengan satu cara yang sama.
-- Diadaptasi dari Clarissv main.lua v0.1.43: start, App:stop, setRunningEnabled, syncRunToggles.
-- Bedanya: tiap fitur MENDAFTAR di sini (Jobs.register), jadi start() tidak perlu tahu isi fiturnya.
return function(G)
    local App, Core, Bridge, Net, Movement, task = G.App, G.Core, G.Bridge, G.Net, G.Movement, G.task
    local Jobs = { specs = {}, toggles = {} }

    -- spec = {
    --   label        nama di status, misal "Planting"
    --   prepare(r, saved)   cek hook game yang dibutuhkan (opsional; saved = checkpoint resume)
    --   run(token, saved)   isi task; selesai normal = return, gagal = error
    --   clear()      hapus checkpoint fitur ini (dipanggil saat Stop / task lain mulai)
    --   resume       true = checkpoint `mode` dilanjutkan otomatis setelah pindah server
    --   validResume(data)   cek isi checkpoint sebelum dilanjutkan (opsional)
    -- }
    function Jobs.register(mode, spec)
        Jobs.specs[mode] = spec
        if spec.resume then
            table.insert(G.resumeHandlers, function()
                local record = G.State.loadCheckpoint(mode)
                if not record or type(record.data) ~= "table" then return false end
                if spec.validResume and not spec.validResume(record.data) then return false end
                App.config, App.profile = record.config, Core.profileName(record.profile)
                Jobs.start(mode, record.data)
                return true
            end)
        end
    end

    -- World tujuan dari checkpoint yang menunggu dilanjutkan (dipakai saat script dimuat ulang di
    -- world picker dan game belum memuat world sama sekali: masuk lewat UI picker dulu).
    function Jobs.resumeTargetWorld()
        for mode, spec in pairs(Jobs.specs) do
            if spec.resume and spec.resumeWorld then
                local ok, record = pcall(G.State.loadCheckpoint, mode)
                if ok and record and type(record.data) == "table" then
                    local found, name = pcall(spec.resumeWorld, record.data, record.config)
                    if found and type(name) == "string" and name ~= "" then return name, mode end
                end
            end
        end
    end

    ---------------------------------------------------------------- dipakai bersama PNB, Harvest, Rotation
    -- Checkpoint task: save() simpan data(), refresh() simpan ulang tiap 2 menit (supaya tidak basi
    -- saat task jalan lama, batas 6 jam), clear() hapus. Error simpan dicatat, task tetap jalan.
    App.resumeErrors = App.resumeErrors or {}
    function Jobs.checkpointer(name, data)
        local last = -math.huge
        local cp = {}
        function cp.save()
            G.State.saveCheckpoint(name, data())
            last = os.clock()
        end
        function cp.refresh()
            if App.pending == 0 and os.clock() - last >= 120 then
                local ok, issue = pcall(cp.save)
                App.resumeErrors[name] = not ok and tostring(issue) or nil
            end
        end
        function cp.clear() G.State.clearCheckpoint(name) end
        return cp
    end

    -- Loop tahan banting (satu aturan untuk semua task):
    --   keluar world / avatar mati  -> kalau setting Rejoin nyala, ulangi loop (loop masuk lagi ke world);
    --                                   kalau mati, task berhenti;
    --   error lain                  -> diulang hanya kalau opts.anyError (Rotation), selain itu berhenti;
    --   gagal opts.maxFailures kali berturut-turut tanpa kemajuan (opts.progress tidak berubah) -> berhenti.
    -- opts = { label, loop(token, resume), world() -> nama world task, progress() -> angka,
    --          anyError, maxFailures (bawaan 3), wait (detik jeda sebelum ulang),
    --          onRetry(problem, left) -> data resume untuk loop berikutnya }
    App.rejoins, App.retries = App.rejoins or {}, App.retries or {}
    function Jobs.resilient(token, resume, opts)
        local failures, mark = 0, nil
        local key = opts.label
        while true do
            local completed, problem = pcall(opts.loop, token, resume)
            if completed then return end
            Net.checkpoint(token)
            local classified, verdict = pcall(Movement.classifyFault, problem, token, opts.world())
            if classified then problem = verdict
            elseif tostring(verdict):find("Stopped", 1, true) then error(verdict, 0)
            else problem = G.Bridge.recoverable("Status game tidak terbaca: " .. tostring(problem), opts.world(), "unreadable") end
            local left = type(problem) == "table" and problem.recoverable
            if left and not App.config.options.autoRejoin then error(problem, 0) end
            if not left and not opts.anyError then error(problem, 0) end
            local now = opts.progress and opts.progress() or 0
            if mark ~= now then failures = 0 end
            failures, mark = failures + 1, now
            local limit = opts.maxFailures or 3
            assert(failures <= limit, opts.label .. " gagal " .. limit .. "x tanpa kemajuan: " .. tostring(problem))
            if left then App.rejoins[key] = (App.rejoins[key] or 0) + 1
            else App.retries[key] = (App.retries[key] or 0) + 1 end
            App.lastRetryError = os.date("%H:%M:%S") .. " " .. opts.label .. ": " .. tostring(problem)
            G.setStatus((left and "Keluar dari world" or "Error") .. " (" .. tostring(problem) .. "). "
                .. opts.label .. " diulang (" .. failures .. "/" .. limit .. ")...")
            resume = opts.onRetry and opts.onRetry(problem, left) or { retry = true }
            if opts.wait then
                Movement.releaseControls()
                Net.pause(opts.wait, token)
                Movement.takeControls()
            end
        end
    end

    -- Samakan posisi toggle On/Off di UI dengan job yang benar-benar jalan.
    function Jobs.syncToggles()
        App.syncingRunToggles = true
        for mode, control in pairs(Jobs.toggles) do
            local enabled = App.alive and App.job == mode and App.jobToken == App.token
            if control.Value ~= enabled then pcall(function() control:Set(enabled, false, false) end) end
        end
        App.syncingRunToggles = false
    end

    function Jobs.start(mode, saved)
        Net.idle()
        local spec = assert(Jobs.specs[mode], "Task tidak dikenal: " .. tostring(mode))
        local r = Bridge.runtime()
        if spec.prepare then spec.prepare(r, saved) end
        Core.checkSetup(App.config, mode, r.items)
        for other, otherSpec in pairs(Jobs.specs) do
            if other ~= mode and otherSpec.clear then pcall(otherSpec.clear) end
        end
        G.State.saveSession()
        local token = Net.beginJob(mode)
        App.teleporting, App.recovering = false, false
        Jobs.syncToggles()
        task.spawn(function()
            local ok, message = xpcall(function()
                Net.checkpoint(token)
                Movement.takeControls()
                spec.run(token, saved)
            end, function(err) return tostring(err) end)
            Movement.releaseControls()
            App.job, App.jobToken, App.recovering = nil, nil, false
            Jobs.syncToggles()
            if not ok and token == App.token and App.alive then
                App.lastError = message
                G.setStatus("Paused: " .. message)
                G.notify(message)
            end
        end)
        return token
    end

    -- Jeda task untuk update: simpan checkpoint, hentikan task TANPA menghapus checkpoint, tunggu
    -- task benar-benar berhenti & request server selesai. Return: mode yang dijeda (nil kalau tidak
    -- ada task), atau false + alasan kalau task ini tidak bisa dilanjutkan otomatis.
    function Jobs.suspend(maxWait)
        local mode = App.job
        if not mode then return nil end
        local spec = Jobs.specs[mode]
        if not (spec and spec.resume and spec.save) then return false, (spec and spec.label or mode) .. " tidak punya checkpoint" end
        local saved, issue = pcall(spec.save)
        if not saved then return false, "checkpoint gagal disimpan: " .. tostring(issue) end
        App.token = App.token + 1
        App.teleporting, App.recovering = false, false
        local deadline = os.clock() + (maxWait or 20)
        while (App.job or App.pending > 0) and os.clock() < deadline do task.wait(0.1) end
        Movement.releaseControls()
        Jobs.syncToggles()
        if App.job or App.pending > 0 then return false, "task belum berhenti" end
        return mode
    end
    -- Lanjutkan checkpoint yang ada (dipakai kalau update batal setelah task dijeda).
    function Jobs.resumeSaved()
        for _, handler in ipairs(G.resumeHandlers) do
            local found, resumed = pcall(handler)
            if found and resumed then return true end
        end
        return false
    end

    -- Stop: token naik, jadi loop task berhenti di checkpoint berikutnya. Checkpoint semua fitur dihapus.
    function Jobs.stop()
        App.token = App.token + 1
        App.teleporting, App.recovering = false, false
        Jobs.syncToggles()
        Movement.releaseControls()
        for _, spec in pairs(Jobs.specs) do if spec.clear then pcall(spec.clear) end end
        pcall(G.State.saveSession)
        G.setStatus(App.pending > 0 and "Stopped; waiting for a pending server request." or "Stopped.")
    end

    -- Dipanggil toggle UI. On = mulai (kalau belum jalan), Off = stop (kalau task ini yang jalan).
    function Jobs.setRunning(mode, enabled)
        if App.syncingRunToggles then return true end
        local ok, message = pcall(function()
            if enabled then
                if App.job == mode and App.jobToken == App.token then return end
                Jobs.start(mode)
            elseif App.job == mode and App.jobToken == App.token then
                Jobs.stop()
            end
        end)
        Jobs.syncToggles()
        if not ok then G.notify(tostring(message)) end
        return ok, message
    end

    return Jobs
end

end)()

-- ===== src/scan.lua =====
__modules["scan"] = (function(...)
-- scan.lua: World Scan, mirip Growscan di Growtopia, untuk world yang sedang dimasuki.
-- Semua data dibaca dari memori game (tanpa request ke server):
--   grid tile (world.fg)    -> jumlah blok per jenis, pohon per jenis seed
--   data pohon              -> mateng / tumbuh + sisa waktu (waktu tanam + lama tumbuh item)
--   daftar drop             -> total item floating per jenis
--   isi Display Box         -> isi semua box di world
-- Data pohon dicari dengan 2 cara:
--   1) hook game (treeGrowthHooks, cara Clarissv) kalau masih tersedia;
--   2) sidik jari: tabel di sekitar fungsi milik world yang, untuk tile berisi seed, punya entri
--      pohon (tabel dengan angka waktu tanam). Dipakai setelah update Growblox 17 Nov 2026.
-- Hasil cara 2 juga dicatat detail di diagnostics supaya bisa disesuaikan kalau game berubah lagi.
return function(G)
    local App, Bridge = G.App, G.Bridge
    local Scan = {}
    -- Pencarian besar dijeda sesekali supaya game tidak nge-freeze (cuma kalau sedang di dalam task).
    local work = 0
    local function breathe(cost)
        work = work + (cost or 1)
        if work >= 3000 then
            work = 0
            local scheduler = G.task or task
            if coroutine.isyieldable() and scheduler and scheduler.wait then scheduler.wait() end
        end
    end

    -- Kumpulkan tabel kandidat: upvalue fungsi milik world + field tabel konteks (satu tingkat).
    local function candidateTables(r)
        -- cache per world: pindah world bisa membuat tabel pohon baru
        if r.treeCandidates and r.treeCandidatesWorld == r.world.name then return r.treeCandidates end
        local list, seen = {}, {}
        local function add(value)
            if type(value) == "table" and not seen[value] and value ~= r.world and value ~= r.items and #list < 6000 then
                seen[value] = true
                table.insert(list, value)
                return true
            end
        end
        local functions = {}
        for _, fn in ipairs(r.ownedFunctions or {}) do table.insert(functions, fn) end
        for _, key in ipairs({ "ride", "fg", "displayPut", "call" }) do
            if type(r.world[key]) == "function" then table.insert(functions, r.world[key]) end
        end
        for _, fn in pairs(r.handlers or {}) do if type(fn) == "function" then table.insert(functions, fn) end end
        for _, fn in ipairs(functions) do
            for _, value in pairs(Bridge.upvalues(fn)) do
                breathe(1)
                if add(value) then
                    -- tabel konteks: lihat field-nya juga (maks 256 per tabel)
                    pcall(function()
                        local n = 0
                        for _, field in next, value do
                            n = n + 1
                            breathe(1)
                            if n > 256 then break end
                            add(field)
                        end
                    end)
                end
            end
        end
        r.treeCandidates, r.treeCandidatesWorld = list, r.world.name
        return list
    end

    -- Entri pohon = tabel yang punya angka (waktu tanam). Kunci angka pertama yang mirip
    -- waktu server (> 1e9) dipakai sebagai "waktu tanam". Clarissv: tree.p.
    local function plantedField(entry)
        if type(entry) ~= "table" then return nil end
        if type(rawget(entry, "p")) == "number" then return "p" end
        local found
        pcall(function()
            for key, value in next, entry do
                if type(value) == "number" and value > 1e9 then found = key; break end
            end
        end)
        return found
    end
    -- Cara tabel pohon menyimpan entri: indeks y*w+x (Clarissv), 1-based, [y][x], [x][y], atau "x:y".
    local LAYOUTS = {
        { name = "y*w+x", get = function(t, x, y, w) return rawget(t, y * w + x) end },
        { name = "y*w+x+1", get = function(t, x, y, w) return rawget(t, y * w + x + 1) end },
        { name = "[y][x]", get = function(t, x, y) local row = rawget(t, y); return type(row) == "table" and rawget(row, x) or nil end },
        { name = "[x][y]", get = function(t, x, y) local col = rawget(t, x); return type(col) == "table" and rawget(col, y) or nil end },
        { name = "\"x:y\"", get = function(t, x, y) return rawget(t, x .. ":" .. y) end },
        { name = "\"x,y\"", get = function(t, x, y) return rawget(t, x .. "," .. y) end },
    }

    -- Cari tabel pohon memakai beberapa tile seed sebagai bukti. Return accessor + keterangan.
    function Scan.resolveTrees(r, seedTiles, retried)
        if r.treeRipe and r.treeRemaining then
            return { source = "hook game (cara Clarissv)", ripe = r.treeRipe, remaining = r.treeRemaining }
        end
        if #seedTiles == 0 then return nil, "tidak ada pohon di world ini" end
        local w = r.world.w
        local best
        -- Cache per world: tabel pohon yang sudah ketemu dipakai lagi kalau masih cocok (cek cepat),
        -- jadi pencarian besar cuma sekali per world, bukan tiap siklus panen.
        local cached = r.treeResolved
        if cached and cached.world == r.world.name then
            local hits = 0
            for i = 1, math.min(#seedTiles, 8) do
                local tile = seedTiles[i]
                local ok, entry = pcall(cached.layout.get, cached.table, tile.x, tile.y, w)
                if ok and type(entry) == "table" and type(rawget(entry, cached.field)) == "number" then hits = hits + 1 end
            end
            if hits > 0 then best = { table = cached.table, layout = cached.layout, field = cached.field, hits = hits } end
        end
        for _, t in ipairs(best and {} or candidateTables(r)) do
            breathe(#LAYOUTS)
            for _, layout in ipairs(LAYOUTS) do
                local hits, field = 0, nil
                for i = 1, math.min(#seedTiles, 8) do
                    local tile = seedTiles[i]
                    local ok, entry = pcall(layout.get, t, tile.x, tile.y, w)
                    local key = ok and plantedField(entry)
                    if key then hits, field = hits + 1, field or key end
                end
                if hits > 0 and (not best or hits > best.hits) then
                    best = { table = t, layout = layout, field = field, hits = hits }
                end
            end
        end
        if not best then
            if not retried then
                r.treeCandidates = nil -- tabel bisa sudah diganti game; kumpulkan ulang sekali
                return Scan.resolveTrees(r, seedTiles, true)
            end
            return nil, "tabel pohon tidak ketemu di " .. #candidateTables(r) .. " tabel kandidat"
        end
        local t, layout, field = best.table, best.layout, best.field
        r.treeResolved = { world = r.world.name, table = t, layout = layout, field = field }
        local function entryAt(x, y) local ok, e = pcall(layout.get, t, x, y, w); return ok and e or nil end
        local function remaining(x, y, id)
            local entry, item = entryAt(x, y), r.items[id]
            if type(entry) ~= "table" or type(entry[field]) ~= "number" or not item then return nil end
            return math.max(0, entry[field] + (item.grow or 0) - G.serverTime())
        end
        return {
            source = string.format("sidik jari: layout %s, field waktu tanam '%s', cocok %d/%d tile",
                layout.name, tostring(field), best.hits, math.min(#seedTiles, 8)),
            remaining = remaining,
            ripe = function(x, y, id)
                local left = remaining(x, y, id)
                if left == nil then return nil end
                return left <= 0
            end,
            entryAt = entryAt,
        }
    end

    -- Ringkas isi satu entri pohon untuk diagnostics (field: tipe/nilai).
    local function describeEntry(entry)
        if type(entry) ~= "table" then return type(entry) end
        local parts, n = {}, 0
        pcall(function()
            for key, value in next, entry do
                n = n + 1
                if n > 8 then break end
                local text = type(value) == "number" and string.format("%.1f", value) or type(value)
                table.insert(parts, tostring(key) .. "=" .. text)
            end
        end)
        return "{" .. table.concat(parts, ", ") .. "}"
    end

    local function itemName(r, id)
        local item = r.items[id]
        return (item and item.name or "Item") .. " (" .. tostring(id) .. ")"
    end
    local function duration(seconds)
        seconds = math.floor(seconds + 0.5)
        if seconds >= 3600 then return string.format("%dj %dm", math.floor(seconds / 3600), math.floor((seconds % 3600) / 60)) end
        if seconds >= 60 then return string.format("%dm %dd", math.floor(seconds / 60), seconds % 60) end
        return seconds .. "d"
    end
    local function sortedCounts(map)
        local list = {}
        for id, n in pairs(map) do table.insert(list, { id = id, n = n }) end
        table.sort(list, function(a, b) return a.n == b.n and a.id < b.id or a.n > b.n end)
        return list
    end

    -- Scan world sekarang. Return: daftar baris laporan (juga disimpan di App.scanReport).
    -- full = true (tombol Growscan): semua item tanpa batas daftar, plus total gabungan
    -- (floating + isi Display Box). Tanpa full (scan otomatis Harvest/Rotation): diringkas.
    function Scan.run(full)
        local limit = full and math.huge or 12
        local r = Bridge.worldCheck(nil)
        local world, items = r.world, r.items
        local blocks, trees, seedTiles, boxes = {}, {}, {}, {}
        for y = 0, world.h - 1 do
            local row = world.fg[y]
            if row then
                for x = 0, world.w - 1 do
                    local id = row[x]
                    if id and id ~= 0 then
                        local item = items[id]
                        if item and item.kind == "seed" then
                            trees[id] = trees[id] or { total = 0, ripe = 0, growing = 0, unknown = 0, longest = 0 }
                            trees[id].total = trees[id].total + 1
                            table.insert(seedTiles, { x = x, y = y, id = id })
                        else
                            blocks[id] = (blocks[id] or 0) + 1
                            if item and item.display and not item.displayOne then table.insert(boxes, { x = x, y = y }) end
                        end
                    end
                end
            end
        end

        local resolver, problem = Scan.resolveTrees(r, seedTiles)
        for _, tile in ipairs(seedTiles) do
            local info = trees[tile.id]
            local ripe = resolver and resolver.ripe(tile.x, tile.y, tile.id)
            if ripe == true then info.ripe = info.ripe + 1
            elseif ripe == false then
                info.growing = info.growing + 1
                local left = resolver.remaining(tile.x, tile.y, tile.id)
                if type(left) == "number" then info.longest = math.max(info.longest, left) end
            else info.unknown = info.unknown + 1 end
        end

        local floating, hidden = {}, 0
        for _, drop in pairs(world.dropList()) do
            if type(drop) == "table" and type(drop.id) == "number" and type(drop.n) == "number" then
                if drop.display then hidden = hidden + 1
                else floating[drop.id] = (floating[drop.id] or 0) + drop.n end
            end
        end

        local lines = { string.format("World %s (%dx%d), %s", tostring(world.name), world.w, world.h, os.date("%H:%M:%S")) }
        table.insert(lines, "POHON:")
        local treeList = {}
        for id, info in pairs(trees) do table.insert(treeList, { id = id, info = info }) end
        table.sort(treeList, function(a, b) return a.info.total > b.info.total end)
        if #treeList == 0 then table.insert(lines, "  (tidak ada pohon)") end
        for _, entry in ipairs(treeList) do
            local info = entry.info
            local text = string.format("  %s: %d pohon, %d mateng, %d tumbuh", itemName(r, entry.id), info.total, info.ripe, info.growing)
            if info.growing > 0 then text = text .. ", semua mateng dalam " .. duration(info.longest) end
            if info.unknown > 0 then text = text .. ", " .. info.unknown .. " status tidak terbaca" end
            table.insert(lines, text)
        end
        table.insert(lines, "  Data pohon: " .. (resolver and resolver.source or ("belum bisa dibaca: " .. tostring(problem))))
        if seedTiles[1] and not (r.treeRipe and r.treeRemaining) then
            local tile = seedTiles[1]
            table.insert(lines, string.format("  Contoh pohon di %d,%d: %s", tile.x, tile.y,
                resolver and resolver.entryAt and describeEntry(resolver.entryAt(tile.x, tile.y)) or "-"))
            local item = items[tile.id]
            table.insert(lines, "  Lama tumbuh item: " .. tostring(item and item.grow))
        end

        table.insert(lines, "FLOATING:")
        local floatList = sortedCounts(floating)
        if #floatList == 0 then table.insert(lines, "  (kosong)") end
        for i = 1, math.min(#floatList, limit) do
            table.insert(lines, "  " .. itemName(r, floatList[i].id) .. ": " .. floatList[i].n)
        end
        if hidden > 0 then table.insert(lines, "  (" .. hidden .. " drop bertanda display tidak dihitung)") end

        table.insert(lines, "BLOK:")
        local blockList = sortedCounts(blocks)
        for i = 1, math.min(#blockList, limit) do
            table.insert(lines, "  " .. itemName(r, blockList[i].id) .. ": " .. blockList[i].n)
        end

        table.insert(lines, "DISPLAY BOX: " .. #boxes)
        local stored = {}
        for i, box in ipairs(boxes) do
            local ok, rows = pcall(function() return world.displays.get(box.x, box.y) end)
            local parts = {}
            if ok and type(rows) == "table" then
                for _, row in pairs(rows) do
                    if type(row) == "table" and type(row[1]) == "number" and type(row[2]) == "number" then
                        table.insert(parts, itemName(r, row[1]) .. " " .. tostring(row[2]))
                        stored[row[1]] = (stored[row[1]] or 0) + row[2]
                    end
                end
            end
            if i <= (full and math.huge or 6) then
                table.insert(lines, string.format("  %d,%d: %s", box.x, box.y, #parts > 0 and table.concat(parts, ", ") or "kosong"))
            end
        end
        if full then
            -- Total item yang bisa diambil di world ini: floating + isi semua Display Box.
            local totals = {}
            for id, n in pairs(floating) do totals[id] = (totals[id] or 0) + n end
            for id, n in pairs(stored) do totals[id] = (totals[id] or 0) + n end
            table.insert(lines, "TOTAL ITEM (floating + Display Box):")
            local totalList = sortedCounts(totals)
            if #totalList == 0 then table.insert(lines, "  (kosong)") end
            for _, entry in ipairs(totalList) do
                table.insert(lines, string.format("  %s: %d (floating %d, box %d)", itemName(r, entry.id), entry.n,
                    floating[entry.id] or 0, stored[entry.id] or 0))
            end
        end
        App.scanReport = lines
        App.scanTrees = trees
        return lines
    end

    -- Tombol Growscan: scan lengkap world yang sedang dimasuki (dipasang di tab Harvest).
    function Scan.buildGrowscan(tab)
        local UI = G.UI
        pcall(function() tab:Section({ Title = "Growscan" }) end)
        local result = tab:Paragraph({ Title = "Growscan", Desc = "Scan semua item di world ini: pohon (mateng/tumbuh), item floating, blok, isi semua Display Box, dan totalnya. Dibaca dari memori game, tanpa request ke server." })
        tab:Button({ Title = "Scan world (Growscan)", Callback = function()
            local ok, lines = pcall(Scan.run, true)
            local text = ok and table.concat(lines, "\n") or ("Scan gagal: " .. tostring(lines))
            UI.paragraph(result, "Growscan", text)
            G.setStatus(ok and ("Growscan selesai: " .. tostring(Bridge.runtime().world.name)) or text)
        end })
        tab:Button({ Title = "Copy hasil Growscan", Callback = function()
            local copy = G.exec and G.exec.setclipboard
            if not App.scanReport then G.notify("Scan world dulu."); return end
            if type(copy) ~= "function" then G.notify("Executor tidak mendukung copy; hasil ada di Copy diagnostics."); return end
            copy(table.concat(App.scanReport, "\n"))
            G.notify("Hasil Growscan disalin.")
        end })
    end

    return Scan
end

end)()

-- ===== src/ui.lua =====
__modules["ui"] = (function(...)
-- ui.lua: jendela WindUI. Pondasi baru bikin kerangka tab + tab Settings.
-- Isi tab fitur (Place & Break + Auto Collect, Planting, Harvest, Rotation) ditambah bareng fiturnya.
return function(G)
    local App, task = G.App, G.task
    local UI = { tabs = {}, statuses = {} }

    -- Paragraf "Status" di tiap tab, diupdate bareng oleh UI.refresh().
    function UI.addStatus(paragraph) table.insert(UI.statuses, paragraph); return paragraph end

    -- Bungkus aksi tombol: jalan di thread sendiri, cek sedang tidak ada task,
    -- dan kalau error tampilkan pesannya, bukan bikin script crash.
    function UI.action(fn)
        return function()
            task.spawn(function()
                local ok, message = pcall(G.Net.idle)
                if not ok then G.notify(tostring(message)); return end
                App.configuring = true
                ok, message = pcall(fn)
                App.configuring = false
                if ok then ok, message = pcall(G.State.saveSession) end
                if not ok then G.setStatus(tostring(message)); G.notify(tostring(message)) end
            end)
        end
    end

    function UI.paragraph(paragraph, title, desc)
        if paragraph and paragraph.ParagraphFrame then
            paragraph.ParagraphFrame:SetTitle(title)
            paragraph.ParagraphFrame:SetDesc(desc)
        end
    end

    function UI.build(WindUI)
        local window = WindUI:CreateWindow({
            Title = "Growblox Hansel", Author = "v" .. G.VERSION .. " | Learn to own",
            Folder = G.State.ROOT, Icon = "sprout", Size = G.UDim2.fromOffset(600, 520),
            OpenButton = { Title = "Growblox Hansel", Enabled = true, Draggable = true, OnlyMobile = false },
        })
        UI.window = window
        App.window = window
        window:OnDestroy(function() G.unload() end)

        -- Urutan tab = urutan muncul di layar. Auto Collect ada di dalam tab Place & Break.
        UI.tabs.pnb = window:Tab({ Title = "Place & Break", Icon = "hammer" })
        UI.tabs.plant = window:Tab({ Title = "Planting", Icon = "sprout" })
        UI.tabs.harvest = window:Tab({ Title = "Harvest", Icon = "package" })
        UI.tabs.rotation = window:Tab({ Title = "Rotation", Icon = "repeat" })
        UI.tabs.settings = window:Tab({ Title = "Settings", Icon = "settings" })
        G.Pnb.buildTab(UI.tabs.pnb)
        G.Plant.buildTab(UI.tabs.plant)
        G.Harvest.buildTab(UI.tabs.harvest)
        G.Rotation.buildTab(UI.tabs.rotation)

        local s = UI.tabs.settings
        UI.status = UI.addStatus(s:Paragraph({ Title = "Status", Desc = App.status }))
        s:Button({ Title = "Stop task", Desc = "Hentikan task yang lagi jalan. Checkpoint resume ikut dihapus.",
            Callback = function() G.Jobs.stop() end })
        s:Button({ Title = "Reconnect to game", Desc = "Pakai ini kalau muncul 'found 0'. Masuk world dulu, baru pencet.",
            Callback = UI.action(function() G.connect() end) })
        s:Button({ Title = "Copy diagnostics", Callback = function()
            local text = G.diagnostics()
            if type(G.exec.setclipboard) == "function" then G.exec.setclipboard(text); G.notify("Diagnostics di-copy.")
            else print(text); G.notify("Diagnostics dicetak ke console.") end
        end })
        UI.buildSettings(s)
        UI.buildAutostart(s)
        s:Button({ Title = "Unload script", Callback = function() G.unload() end })
        UI.log = s:Paragraph({ Title = "Aktivitas terakhir", Desc = "-" })
        return window
    end

    -- Setting umum (adaptasi tab Settings Clarissv v0.1.43). Hanya bisa diubah saat tidak ada task.
    -- Hit delay dan batas seed ada di tab Place & Break.
    function UI.buildSettings(s)
        local Core, State, Net = G.Core, G.State, G.Net
        UI.settings = {}
        pcall(function() s:Section({ Title = "Settings" }) end)
        for _, info in ipairs({
            { "antiAFK", "Anti-AFK", "Jaga sesi tetap aktif saat Roblox mendeteksi idle (klik virtual tiap idle, maks sekali per menit)." },
            { "fastHarvest", "Panen cepat (ping tinggi)", "Harvest/Rotation: pohon satu baris dipukul sambil jalan tanpa berhenti di tiap pohon, drop dipungut sambil jalan. Pohon yang gagal otomatis diulang cara biasa. Matikan kalau banyak pohon terlewat." },
            { "autoUpdate", "Auto update", "Cek patch baru di GitHub tiap 10 menit. Ada versi baru: task yang jalan (Rotation/Harvest/PNB) dijeda dengan checkpoint, script baru dimuat, task dilanjutkan dari titik terakhir. Planting ditunggu sampai selesai." },
            { "respawnStore", "Respawn ke Display Box dekat pintu", "Tas penuh saat Harvest/Rotation dan Display Box ada di dekat pintu putih (maks 8 tile): respawn ke pintu lalu simpan, bukan jalan jauh. Box jauh dari pintu = tetap jalan." },
            { "autoReconnect", "Auto reconnect", "Kena disconnect (layar 'Disconnected' / 'Reconnect'): masuk lagi ke Growblox otomatis (maks 5x, jeda 15 detik), lalu task yang punya checkpoint dilanjutkan." },
            { "autoRejoin", "Rejoin world and return to PNB & Harvest", "Keluar ke world picker, avatar mati, atau pindah server: masuk lagi ke world task (PNB: balik ke spot; Harvest: world farm, scan ulang, lanjut panen). Juga lanjut Planting dari checkpoint." },
        }) do
            local key = info[1]
            UI.settings[key] = s:Toggle({ Title = info[2], Desc = info[3], Value = App.config.options[key],
                Callback = function(value)
                    if App.syncingSettings then return end
                    local ok, message = pcall(function()
                        Net.idle()
                        App.config.options[key] = value == true
                        if key == "antiAFK" and value then G.installAntiAFK() end
                        if key == "autoReconnect" and value then G.installReconnect() end
                        State.saveSession()
                    end)
                    if not ok then
                        G.notify("Stop task dulu sebelum mengubah setting.")
                        App.syncingSettings = true
                        pcall(function() UI.settings[key]:Set(App.config.options[key], false, false) end)
                        App.syncingSettings = false
                    end
                end })
        end
        for _, info in ipairs({
            { "placeDelay", "Jeda setelah place (detik)", 0.05 }, { "collectDelay", "Waktu tunggu drop (detik)", 0.05 },
            { "actionTimeout", "Batas waktu request server (detik)", 1 }, { "moveTimeout", "Batas waktu jalan (detik)", 1 },
        }) do
            local key, limits = info[1], Core.LIMITS[info[1]]
            UI.settings[key] = s:Slider({ Title = info[2], Step = info[3],
                Value = { Min = limits[1], Max = limits[2], Default = App.config.options[key] },
                Callback = function(value)
                    if App.syncingSettings then return end
                    local ok = pcall(function()
                        Net.idle()
                        App.config.options[key] = tonumber(value)
                        State.saveSession()
                    end)
                    if not ok then G.notify("Stop task dulu sebelum mengubah setting.") end
                end })
        end
    end

    -- Auto-start: script pendek untuk folder autoexec executor. Executor menjalankannya tiap kali
    -- masuk game (termasuk setelah mental ke world picker / rejoin, saat queue_on_teleport tidak
    -- terpanggil), lalu task yang punya checkpoint dilanjutkan otomatis.
    function UI.autostartScript()
        local pinned = tostring(G.env and G.env.GrowbloxHanselLoaderURL or "")
        local main = pinned:gsub("releases/loader%-[%w]+%.lua$", "loader.lua")
        if main == "" or not main:match("^https://") then
            main = "https://raw.githubusercontent.com/Hanselane/growblox-hansel/main/loader.lua"
        end
        return table.concat({
            "-- Growblox Hansel auto-start (taruh di folder autoexec executor)",
            "if not game:IsLoaded() then game.Loaded:Wait() end",
            "task.wait(3)",
            "-- sudah dimuat lewat queue_on_teleport / manual? jangan jalan dobel",
            "if getgenv().GrowbloxHanselLoading or getgenv().GrowbloxHanselApp then return end",
            "getgenv().GrowbloxHanselAutoResume = true",
            "local u = " .. string.format("%q", main),
            "-- loader versi terakhir yang dipakai (ditulis script / auto update), kalau ada",
            "pcall(function() if isfile and isfile('GrowbloxHansel/loader-url.txt') then local t = readfile('GrowbloxHansel/loader-url.txt') if type(t) == 'string' and t:match('^https://') then u = t end end end)",
            "loadstring(game:HttpGet(u))()",
        }, "\n")
    end
    function UI.buildAutostart(s)
        pcall(function() s:Section({ Title = "Update" }) end)
        s:Button({ Title = "Cek update sekarang", Callback = function()
            G.task.spawn(function()
                G.notify("Cek update...")
                local ok, result = pcall(G.Update.tick, true)
                G.notify(tostring(ok and result or ("Gagal: " .. tostring(result))))
            end)
        end })
        pcall(function() s:Section({ Title = "Auto-start" }) end)
        s:Paragraph({ Title = "Auto-start setelah mental / rejoin",
            Desc = "Kalau setelah keluar ke world picker script tidak jalan sendiri, pasang auto-start: tekan tombol di bawah, "
                .. "lalu tempel isinya ke file baru di folder autoexec executor (Delta: folder Autoexecute). Tiap masuk game, "
                .. "script dimuat dan task yang punya checkpoint (Rotation, Harvest, PNB) dilanjutkan; dari world picker script "
                .. "masuk sendiri ke world tujuan. Tanpa checkpoint, script cuma terbuka seperti biasa." })
        s:Button({ Title = "Copy script auto-start", Callback = function()
            local copy = G.exec and G.exec.setclipboard
            local text = UI.autostartScript()
            if type(copy) == "function" then copy(text); G.notify("Script auto-start di-copy.")
            else print(text); G.notify("Executor tidak mendukung copy; script dicetak ke console.") end
        end })
    end

    -- Dipanggil berkala dari main.lua.
    function UI.refresh()
        for _, paragraph in ipairs(UI.statuses) do UI.paragraph(paragraph, "Status", App.status) end
        G.Jobs.syncToggles()
        UI.paragraph(UI.log, "Aktivitas terakhir", table.concat(App.logs, "\n", 1, math.min(#App.logs, 8)))
    end

    return UI
end

end)()

-- ===== src/plant.lua =====
__modules["plant"] = (function(...)
-- plant.lua: fitur Planting. Tanam seed di semua world farm, isi ulang dari Display Box, resume setelah pindah server.
-- Diadaptasi dari Clarissv main.lua v0.1.43: clearPlantResume, savePlantResume, readPlantResume, deferPlantTile,
-- confirmPlantBatch, reconcilePlant, plantTile, plantRetryTargets, retryPlantFromBelow, plantRow, runPlant,
-- seedChoices, refreshSeeds, changePlantSetting, resumePlant, dan isi tab Planting.
-- Logika tanam dipertahankan. Cabang Rotation/Botting dibuang dulu; titik sambungnya ditandai "HOOK ROTATION".
return function(G)
    local App, Core, Bridge, Net, Actions, Movement, Storage, State, task =
        G.App, G.Core, G.Bridge, G.Net, G.Actions, G.Movement, G.Storage, G.State, G.task
    local Plant = {}
    local worldCheck, position, checkpoint, pause = Bridge.worldCheck, Bridge.position, Net.checkpoint, Net.pause
    local count, tileAt, refreshInventory = Actions.count, Actions.tileAt, Actions.refreshInventory
    local moveTo, withoutPickups = Movement.moveTo, Movement.withoutPickups

    ---------------------------------------------------------------- checkpoint
    function Plant.clearResume()
        App.plantState = nil
        State.clearCheckpoint("plant")
    end

    -- Simpan progress: world ke berapa, fase (farm/stock/pickupPending), baris, tile yang di-skip,
    -- dan batch seed yang belum terkonfirmasi (pending). Dipanggil SEBELUM setiap aksi berisiko.
    function Plant.saveResume(state)
        State.saveSession()
        local copy = { worldIndex = state.worldIndex, phase = state.phase, skipped = {}, pending = state.pending, deferred = {} }
        if state.rows then
            copy.rows = {}
            for _, row in ipairs(state.rows) do table.insert(copy.rows, { y = row.y, left = row.left, right = row.right }) end
            copy.rowY = state.rowY
        end
        for key, reason in pairs(state.skipped or {}) do copy.skipped[key] = reason end
        for key, point in pairs(state.deferred or {}) do copy.deferred[key] = { x = point.x, y = point.y, tries = point.tries } end
        State.saveCheckpoint("plant", copy)
        App.plantState = state
        if Plant.onSave then Plant.onSave(state) end -- HOOK ROTATION
    end

    -- Baca dan validasi checkpoint. File yang aneh ditolak, bukan ditebak.
    function Plant.readResume(record)
        record = record or State.loadCheckpoint("plant")
        if not record then return nil end
        record.profile = Core.profileName(record.profile)
        local state = record.data
        assert(type(state) == "table" and type(state.worldIndex) == "number" and state.worldIndex == math.floor(state.worldIndex)
            and state.worldIndex >= 1 and state.worldIndex <= #record.config.planting.worlds + 1
            and (state.phase == "farm" or state.phase == "stock" or state.phase == "pickupPending")
            and type(state.skipped) == "table", "Invalid saved planting progress.")
        for key, reason in pairs(state.skipped) do
            assert(type(key) == "string" and key:match("^%d+:%d+$") and type(reason) == "string", "Invalid skipped planting tile.")
        end
        if state.deferred then
            assert(type(state.deferred) == "table", "Invalid deferred planting tiles.")
            for key, point in pairs(state.deferred) do
                assert(type(point) == "table" and Core.integer(point.x, 0, 65535) and Core.integer(point.y, 0, 65535)
                    and key == point.x .. ":" .. point.y and (point.tries == 0 or point.tries == 1), "Invalid deferred planting tile.")
            end
        end
        if state.rows then
            assert(type(state.rows) == "table", "Invalid saved farm rows.")
            for key in pairs(state.rows) do
                assert(Core.integer(key, 1, #state.rows), "Invalid saved farm row list.")
            end
            local previous = -1
            for _, row in ipairs(state.rows) do
                assert(type(row) == "table", "Invalid saved farm row.")
                for _, key in ipairs({ "y", "left", "right" }) do
                    assert(Core.integer(row[key], 0, 65535), "Invalid saved farm row.")
                end
                assert(row.y > previous and row.left <= row.right, "Invalid saved farm row order.")
                previous = row.y
            end
            if state.rowY ~= nil then
                local found = false
                for _, row in ipairs(state.rows) do if row.y == state.rowY then found = true end end
                assert(found, "Invalid saved planting row.")
            end
        else assert(state.rowY == nil, "Missing saved farm rows.") end
        if state.pending then
            local point = state.pending
            assert(state.phase == "farm" and point.world == record.config.planting.worlds[state.worldIndex], "Invalid pending seed world.")
            for _, key in ipairs({ "x", "y", "before" }) do
                assert(Core.integer(point[key], 0, 65535), "Invalid pending seed placement.")
            end
            assert(point.before >= 1 and point.before <= 200, "Invalid pending seed count.")
            if point.tiles then
                assert(type(point.tiles) == "table" and #point.tiles >= 1 and #point.tiles <= 8
                    and #point.tiles <= point.before, "Invalid pending seed batch.")
                local seen = {}
                for key in pairs(point.tiles) do assert(Core.integer(key, 1, #point.tiles), "Invalid pending seed batch list.") end
                for _, tile in ipairs(point.tiles) do
                    assert(type(tile) == "table" and Core.integer(tile.x, 0, 65535) and tile.y == point.y and not seen[tile.x],
                        "Invalid pending seed batch tile.")
                    seen[tile.x] = true
                end
                assert(point.tiles[1].x == point.x, "Invalid pending seed batch origin.")
            end
        end
        record.state = state
        return record
    end

    ---------------------------------------------------------------- tanam
    local function enterFarmWorld(name, state, token)
        Movement.enterWorld(name, token, { label = "planting", resumeButton = "Resume planting",
            save = function() Plant.saveResume(state) end })
    end

    -- Tile yang gagal ditanam ditunda: dicatat di skipped dan deferred (bisa dicoba sekali lagi dari bawah).
    local function deferPlantTile(state, point, reason)
        local key = point.x .. ":" .. point.y
        state.deferred = state.deferred or {}
        local previous = state.deferred[key]
        state.deferred[key] = { x = point.x, y = point.y, tries = previous and previous.tries or 0 }
        state.skipped[key] = reason
    end

    -- Penanaman di game itu "optimis": tile langsung berubah di layar sebelum server setuju.
    -- Fungsi ini menunggu sampai jumlah seed di server dan isi tile cocok, baru batch dianggap selesai.
    -- Seed yang tidak terkonfirmasi tidak membuat task berhenti; tile-nya ditunda.
    local function confirmPlantBatch(state, token, save, lastPlant)
        local pending = state.pending
        if not pending then return end
        local name, id = pending.world, App.config.planting.seedId
        local tiles = pending.tiles or { pending }
        local hold = Movement.takeControls()
        hold.direction, hold.jump = 0, false
        pause(math.max(0, (lastPlant or 0) + 0.2 - os.clock()), token)
        local deadline = os.clock() + App.config.options.actionTimeout
        while true do
            worldCheck(name, token)
            local actual = refreshInventory(token)[id] or 0
            assert(actual <= pending.before and actual >= pending.before - #tiles,
                "Seed count changed unexpectedly while planting. Check diagnostics before resuming.")
            local planted, values = 0, {}
            for index, point in ipairs(tiles) do
                local value = tileAt(point.x, point.y)
                assert(value == 0 or value == id, "A pending planting tile changed to another item. Check the farm before resuming.")
                values[index] = value
                if value == id then planted = planted + 1 end
            end
            local consistent = actual == pending.before - planted
            if consistent or os.clock() >= deadline then
                local stable, settled = true, os.clock() + 0.12
                repeat
                    worldCheck(name, token)
                    for index, point in ipairs(tiles) do
                        if tileAt(point.x, point.y) ~= values[index] then stable = false; break end
                    end
                    if not stable then break end
                    pause(0.03, token)
                until os.clock() >= settled
                for index, point in ipairs(tiles) do
                    if tileAt(point.x, point.y) ~= values[index] then stable = false; break end
                end
                -- Batch sebagian berhasil butuh satu hitungan server lagi sebelum ditutup.
                if stable and (not consistent or planted < #tiles) then
                    stable = (refreshInventory(token)[id] or 0) == actual
                end
                if stable then
                    local confirmed = math.min(planted, pending.before - actual)
                    local assigned, skipped = 0, 0
                    for index, point in ipairs(tiles) do
                        if values[index] == id and assigned < confirmed then assigned = assigned + 1
                        else
                            deferPlantTile(state, point, "placement not confirmed")
                            skipped = skipped + 1
                        end
                    end
                    App.stats.planted = App.stats.planted + confirmed
                    state.pending = nil
                    save(state)
                    if skipped > 0 then
                        App.plantingRecovery = name .. ": skipped " .. skipped .. " unconfirmed tiles near " .. pending.x .. ", " .. pending.y
                        G.setStatus(App.plantingRecovery .. "; continuing and retrying from below where reachable.")
                    end
                    return actual, skipped == 0
                end
            end
            pause(0.15, token)
        end
    end
    Plant.confirmBatch = confirmPlantBatch

    function Plant.reconcile(state, token)
        if state.pending then confirmPlantBatch(state, token, Plant.saveResume) end
    end

    -- Tanam satu tile secara presisi (dipakai untuk tile yang terlewat saat jalan).
    local function plantTile(point, state, token, save)
        save = save or Plant.saveResume
        return withoutPickups(function()
            local name, id = App.config.planting.worlds[state.worldIndex], App.config.planting.seedId
            local r = worldCheck(name, token)
            local before = refreshInventory(token)[id] or 0
            if not Core.plantingTile(r.world, r.items, point.x, point.y) then return false end
            if not r.handlers.canPlace(r.items[id], point.x, point.y) then return false end
            assert(before > 0, "No planting seeds are left in the backpack.")
            state.pending = { world = name, x = point.x, y = point.y, before = before, tiles = { { x = point.x, y = point.y } } }
            save(state)
            r.handlers.plantSeed(id, point.x, point.y)
            local _, confirmed = confirmPlantBatch(state, token, save, os.clock() + math.max(0, App.config.options.placeDelay - 0.2))
            return confirmed
        end)
    end

    -- Tile di baris ATAS yang tertunda, yang masih bisa dijangkau dari baris ini (maks 2,5 tile).
    local function plantRetryTargets(row, state)
        local targets, r = {}, Bridge.runtime()
        for _, point in pairs(state.deferred or {}) do
            local x = math.max(row.left, math.min(row.right, point.x))
            if point.tries == 0 and point.y < row.y and math.abs(point.x - x) <= 2.5
                and math.abs(point.y + 0.5 - (row.y + 1 - 0.475)) <= 2.5
                and Core.plantingTile(r.world, r.items, point.x, point.y) then table.insert(targets, point) end
        end
        table.sort(targets, function(a, b) return a.x * (row.direction or 1) < b.x * (row.direction or 1) end)
        return targets
    end

    -- Coba sekali lagi tile atas yang tertunda, dari posisi berdiri di baris bawah. Tidak pernah loop.
    local function retryPlantFromBelow(row, state, token, save)
        save = save or Plant.saveResume
        local name = App.config.planting.worlds[state.worldIndex]
        local r, attempts = worldCheck(name, token), 0
        local avatar = position()
        if not avatar.grounded or math.abs(avatar.y - (row.y + 1)) > 0.22 then return attempts end
        for _, point in ipairs(plantRetryTargets(row, state)) do
            local anchor = math.max(row.left, math.min(row.right, point.x))
            if math.abs(avatar.x - (anchor + 0.5)) <= 0.55 then
                local key = point.x .. ":" .. point.y
                if not Core.plantingTile(r.world, r.items, point.x, point.y) then state.deferred[key] = nil; save(state)
                elseif count(App.config.planting.seedId) > 0 then
                    point.tries = 1
                    save(state)
                    if r.handlers.canPlace(r.items[App.config.planting.seedId], point.x, point.y) then
                        attempts = attempts + 1
                        G.setStatus("Retrying planting at " .. point.x .. ", " .. point.y .. " from below...")
                        if plantTile(point, state, token, save) then state.skipped[key], state.deferred[key] = nil, nil
                        else state.skipped[key] = "placement refused after lower-row retry" end
                    else state.skipped[key] = "lower-row placement not permitted" end
                    save(state)
                end
            end
        end
        return attempts
    end

    -- Tanam sambil jalan sepanjang satu baris. Batch maks 8 seed; tiap tile dicatat ke checkpoint
    -- SEBELUM seed ditaruh, dan batch dikonfirmasi ke server sebelum batch berikutnya.
    local function plantRow(row, reverse, state, token)
        return withoutPickups(function()
            local name, id = App.config.planting.worlds[state.worldIndex], App.config.planting.seedId
            local r = worldCheck(name, token)
            local points = {}
            for x = reverse and row.right or row.left, reverse and row.left or row.right, reverse and -1 or 1 do
                if not state.skipped[x .. ":" .. row.y] and Core.plantingTile(r.world, r.items, x, row.y) then
                    table.insert(points, { x = x, y = row.y })
                end
            end
            if #points == 0 or count(id) == 0 then return end
            local avatar, first = position(), points[1]
            local ahead = (first.x + 0.5 - avatar.x) * (reverse and -1 or 1)
            if not avatar.grounded or math.abs(avatar.y - (row.y + 1)) > 0.22 or ahead < -1.2 then
                moveTo(first.x, row.y, name, token, function()
                    return Core.rowHasPlantingSpace(r.world, r.items, row, state.skipped)
                end)
            end
            local available = refreshInventory(token)[id] or 0
            local cursor, nextPlant, lastPlant = 1, 0, 0
            local function confirm()
                if state.pending then available = confirmPlantBatch(state, token, Plant.saveResume, lastPlant) end
            end
            local function step(current)
                checkpoint(token)
                worldCheck(name, token)
                for _, point in ipairs(plantRetryTargets(row, state)) do
                    local anchor = math.max(row.left, math.min(row.right, point.x))
                    if current.grounded and math.abs(current.y - (row.y + 1)) <= 0.22
                        and math.abs(current.x - (anchor + 0.5)) <= 0.55 then
                        confirm()
                        retryPlantFromBelow(row, state, token)
                        available = count(id)
                        break
                    end
                end
                if state.pending then
                    local corrected = false
                    for _, point in ipairs(state.pending.tiles) do if tileAt(point.x, point.y) ~= id then corrected = true end end
                    if corrected or #state.pending.tiles >= 8 or count(id) == 0 then confirm() end
                end
                if available == 0 then return false end
                local point = points[cursor]
                if not point then return false end
                current = position()
                local distance = (point.x + 0.5 - current.x) * (reverse and -1 or 1)
                if current.grounded and math.abs(current.y - (row.y + 1)) <= 0.22 and distance < -1.2 then return false end
                if not current.grounded or math.abs(current.y - (row.y + 1)) > 0.22
                    or math.abs(current.x - (point.x + 0.5)) > 1.2
                    or G.focusedTextBox() then return true end
                if os.clock() < nextPlant then return distance <= 0.55 and "hold" or true end
                if not Core.plantingTile(r.world, r.items, point.x, point.y) then cursor = cursor + 1; return true end
                if not r.handlers.canPlace(r.items[id], point.x, point.y) then
                    if math.abs(current.x - (point.x + 0.5)) <= 0.55 then
                        deferPlantTile(state, point, "not permitted")
                        Plant.saveResume(state)
                        cursor = cursor + 1
                    end
                    return true
                end
                local pending = state.pending or { world = name, x = point.x, y = point.y, before = available, tiles = {} }
                table.insert(pending.tiles, { x = point.x, y = point.y })
                state.pending = pending
                Plant.saveResume(state)
                r.handlers.plantSeed(id, point.x, point.y)
                checkpoint(token)
                worldCheck(name, token)
                lastPlant, nextPlant = os.clock(), os.clock() + math.max(0.15, App.config.options.placeDelay)
                cursor = cursor + 1
                if tileAt(point.x, point.y) ~= id then confirm() end
                return true
            end
            local destination, stepFailed = points[#points], false
            local ok, issue = pcall(moveTo, destination.x, row.y, name, token, function(current)
                local succeeded, proceed = pcall(step, current)
                if not succeeded then stepFailed = true; error(proceed, 0) end
                return proceed
            end)
            checkpoint(token)
            worldCheck(name, token)
            if not ok and stepFailed then error(issue, 0) end
            confirm()
            if not ok then error(issue, 0) end
        end)
    end

    local function routeProblem(text)
        return text:find("route", 1, true) or text:find("position", 1, true) or text:find("support", 1, true)
            or text:find("platform", 1, true) or text:find("timed out", 1, true)
    end

    -- Isi semua world farm. Return false kalau box seed habis, true kalau semua farm selesai.
    -- lastWorldIndex: berhenti di farm ini (dipakai Rotation untuk replant satu farm).
    function Plant.run(token, saved, lastWorldIndex)
        return Movement.harvestEquipmentScope(function()
            Movement.suspendHarvestVehicle(token)
            Core.checkSetup(App.config, "plant", Bridge.runtime().items)
            local settings, id = App.config.planting, App.config.planting.seedId
            local state = saved and saved.state or { worldIndex = 1, phase = "farm", skipped = {} }
            assert(state.phase ~= "pickupPending", "A seed storage withdrawal was interrupted. Check the backpack and box, then clear saved planting.")
            Plant.saveResume(state)
            local lastWorld = lastWorldIndex or #settings.worlds
            while state.worldIndex <= lastWorld do
                checkpoint(token)
                if state.phase == "stock" then
                    enterFarmWorld(settings.storageWorld, state, token)
                    local box = App.config.points.plantBox
                    if Storage.countOnly(box, id) == 0 then
                        Plant.clearResume()
                        G.setStatus("Planting stopped: the seed storage box is empty. Unfinished farm: " .. settings.worlds[state.worldIndex])
                        return false
                    end
                    Storage.withdrawSelected(box, id, token, function()
                        state.phase = "pickupPending"
                        Plant.saveResume(state)
                    end)
                    state.phase = "farm"
                    Plant.saveResume(state)
                end
                local name = settings.worlds[state.worldIndex]
                enterFarmWorld(name, state, token)
                assert(Bridge.runtime().handlers and type(Bridge.runtime().handlers.canPlace) == "function"
                    and type(Bridge.runtime().handlers.plantSeed) == "function",
                    "The seed planting hooks are unavailable. Copy diagnostics from Settings.")
                Plant.reconcile(state, token)
                local r, refill, streamedRows = Bridge.runtime(), false, {}
                if not state.rows then state.rows = Core.farmRows(r.world, r.items); Plant.saveResume(state) end
                for _, row in ipairs(state.rows) do
                    assert(row.y < r.world.h - 1 and row.right < r.world.w, "Saved farm rows no longer fit this world. Clear saved planting and start again.")
                end
                G.setStatus("Planting " .. r.items[id].name .. " in " .. name .. " (" .. state.worldIndex .. "/" .. #settings.worlds .. ")...")
                -- Daftar kunjungan: tiap baris diawali penanda retryRow (cek tile atas yang tertunda),
                -- lalu tile kosong baris itu dalam arah zigzag.
                local visits = {}
                for index, row in ipairs(state.rows) do
                    row.direction = index % 2 == 1 and 1 or -1
                    table.insert(visits, { retryRow = row })
                    for x = row.direction == 1 and row.left or row.right, row.direction == 1 and row.right or row.left, row.direction do
                        if Core.plantingTile(r.world, r.items, x, row.y) then table.insert(visits, { x = x, y = row.y }) end
                    end
                end
                for _, point in ipairs(visits) do
                    checkpoint(token)
                    worldCheck(name, token)
                    local key = not point.retryRow and point.x .. ":" .. point.y
                    if point.retryRow then
                        local row = point.retryRow
                        local targets = plantRetryTargets(row, state)
                        if #targets > 0 and not Core.rowHasPlantingSpace(r.world, r.items, row, state.skipped) then
                            if count(id) == 0 then refill = true; break end
                            local arrived, issue = pcall(function()
                                local firstTarget, lastTarget = targets[1], targets[#targets]
                                moveTo(math.max(row.left, math.min(row.right, firstTarget.x)), row.y, name, token)
                                moveTo(math.max(row.left, math.min(row.right, lastTarget.x)), row.y, name, token, function()
                                    retryPlantFromBelow(row, state, token)
                                    return count(id) > 0 and #plantRetryTargets(row, state) > 0
                                end)
                            end)
                            checkpoint(token)
                            worldCheck(name, token)
                            if not arrived then
                                if state.pending or type(issue) == "table" and issue.recoverable then error(issue, 0) end
                                local text = tostring(issue)
                                assert(routeProblem(text), text)
                                for _, target in ipairs(targets) do
                                    target.tries = 1
                                    state.skipped[target.x .. ":" .. target.y] = "lower-row approach unreachable"
                                end
                                Plant.saveResume(state)
                            end
                        end
                    elseif not state.skipped[key] and Core.plantingTile(r.world, r.items, point.x, point.y) then
                        if count(id) == 0 then refill = true; break end
                        local permitted = not r.world.areas or type(r.world.areas.canEdit) ~= "function" or r.world.areas.canEdit(point.x, point.y)
                        local arrived, issue = true, nil
                        if permitted then
                            arrived, issue = pcall(function()
                                if state.rowY ~= point.y then
                                    for index, row in ipairs(state.rows) do
                                        if row.y == point.y then
                                            local reached = moveTo(index % 2 == 1 and row.left or row.right, row.y, name, token, function()
                                                return Core.rowHasPlantingSpace(r.world, r.items, row, state.skipped)
                                            end)
                                            if reached == false then return end
                                            break
                                        end
                                    end
                                    state.rowY = point.y
                                    Plant.saveResume(state)
                                end
                                if not streamedRows[point.y] then
                                    streamedRows[point.y] = true
                                    for index, row in ipairs(state.rows) do
                                        if row.y == point.y then plantRow(row, index % 2 == 0, state, token); break end
                                    end
                                end
                                if not state.skipped[key] and Core.plantingTile(r.world, r.items, point.x, point.y) then
                                    moveTo(point.x, point.y, name, token)
                                end
                            end)
                        end
                        checkpoint(token)
                        worldCheck(name, token)
                        if not arrived then
                            -- Timeout saat konfirmasi batch TIDAK boleh dianggap tile tak terjangkau.
                            if state.pending then error(issue, 0) end
                            if type(issue) == "table" and issue.recoverable then error(issue, 0) end
                            local text = tostring(issue)
                            assert(routeProblem(text), text)
                            if Core.plantingTile(r.world, r.items, point.x, point.y) then deferPlantTile(state, point, "unreachable") end
                        elseif not permitted or (not state.skipped[key] and Core.plantingTile(r.world, r.items, point.x, point.y)
                            and count(id) > 0 and not plantTile(point, state, token)) then
                            deferPlantTile(state, point, state.skipped[key] or "not permitted")
                        end
                        if state.skipped[key] then Plant.saveResume(state) end
                    end
                end
                if refill then
                    state.phase = "stock"
                else
                    local skipped = 0
                    for _ in pairs(state.skipped) do skipped = skipped + 1 end
                    if Plant.onFarmDone then Plant.onFarmDone(r, name, token) end -- HOOK ROTATION
                    G.setStatus("Processed " .. name .. ": " .. skipped .. " tiles skipped due to access or route. Moving to the next farm.")
                    state.worldIndex, state.skipped, state.rows, state.rowY, state.deferred = state.worldIndex + 1, {}, nil, nil, {}
                end
                Plant.saveResume(state)
            end
            Plant.clearResume()
            G.setStatus((lastWorldIndex and "Finished replanting " .. settings.worlds[lastWorldIndex] .. "."
                or "Finished planting all configured farms.") .. " Seeds planted this session: " .. App.stats.planted)
            return true
        end)
    end

    ---------------------------------------------------------------- daftar job
    G.Jobs.register("plant", {
        label = "Planting",
        prepare = function(r)
            assert(r.body and r.controls and type(r.inventory.room) == "function" and type(r.inventory.add) == "function"
                and type(r.inventory.remove) == "function", "Collection and planting need the live backpack and movement hooks.")
            assert(r.handlers and type(r.handlers.canPlace) == "function" and type(r.handlers.plantSeed) == "function",
                "The seed planting hooks are unavailable. Copy diagnostics from Settings.")
        end,
        -- Error "recoverable" (balik ke world picker, avatar belum siap) dilanjut dari checkpoint terakhir.
        run = function(token, saved)
            local progress = saved
            while true do
                local completed, problem = pcall(Plant.run, token, progress)
                if completed then break end
                checkpoint(token)
                if type(problem) == "table" and problem.recoverable and App.config.options.autoRejoin then
                    progress = { state = App.plantState }
                    assert(progress.state and progress.state.phase ~= "pickupPending", "Seed withdrawal was interrupted. Check the backpack before resuming.")
                    G.setStatus("Planting interrupted; returning to its saved world...")
                else error(problem, 0) end
            end
        end,
        clear = function() Plant.clearResume() end,
    })

    function Plant.resume()
        Net.idle()
        local saved = Plant.readResume()
        assert(saved, "No saved planting task is available.")
        assert(saved.state.phase ~= "pickupPending", "A seed withdrawal was interrupted. Check the backpack and storage, then clear saved planting.")
        App.config, App.profile = saved.config, saved.profile
        if Plant.syncInputs then Plant.syncInputs() end
        G.Jobs.start("plant", saved)
    end
    -- Auto-resume setelah pindah server.
    table.insert(G.resumeHandlers, function()
        if not Plant.readResume() then return false end
        Plant.resume()
        return true
    end)

    ---------------------------------------------------------------- pilihan seed
    -- Daftar seed untuk dropdown: seed di tas, di box tersimpan, seed dari blok terpilih,
    -- plus hasil pencarian nama/ID. Maksimal 40 pilihan.
    function Plant.seedChoices(query)
        local r = Bridge.runtime()
        local candidates, seen, relevant = {}, {}, {}
        query = (query or ""):match("^%s*(.-)%s*$"):lower()
        local selectedId, selected = App.config.planting.seedId, nil
        for _, slot in pairs(r.inventory.slots) do relevant[slot.id] = true end
        local box = App.config.points.plantBox
        if box and box.world == r.world.name then
            local ok, rows = pcall(Storage.boxRows, box)
            if ok then for _, row in pairs(rows) do relevant[row[1]] = true end end
        end
        if App.config.blockId > 0 then
            local ok, seed = pcall(Core.seedId, r.items, App.config.blockId)
            if ok then relevant[seed] = true end
        end
        local function consider(id)
            if seen[id] or type(id) ~= "number" then return end
            seen[id] = true
            local item = r.items[id]
            if type(item) ~= "table" or item.kind ~= "seed" then return end
            local name = item.name or ("Seed " .. id)
            if id == selectedId or query == "" or name:lower():find(query, 1, true) or tostring(id) == query then
                local label = name .. " [" .. id .. "]"
                table.insert(candidates, { id = id, label = label, rank = id == selectedId and 0 or relevant[id] and 1 or 2 })
                if id == selectedId then selected = label end
            end
        end
        consider(selectedId)
        for id in pairs(relevant) do consider(id) end
        if query ~= "" then
            local scanned = 0
            for id in pairs(r.items) do
                scanned = scanned + 1
                if scanned % 512 == 0 then task.wait() end
                consider(id)
            end
        end
        table.sort(candidates, function(a, b) return a.rank < b.rank or a.rank == b.rank and a.label < b.label end)
        local labels, lookup = {}, {}
        for index = 1, math.min(40, #candidates) do
            local choice = candidates[index]
            labels[index], lookup[choice.label] = choice.label, choice.id
        end
        table.sort(labels)
        return labels, lookup, selected, #candidates > #labels
    end

    ---------------------------------------------------------------- tab Planting
    function Plant.buildTab(tab)
        local UI = G.UI
        local controls, seedLabels, seedSearch, generation = {}, {}, "", 0
        local syncing = true

        local function refreshSeeds(syncInputs)
            if not App.runtime then return end
            local labels, lookup, selected, more = Plant.seedChoices(seedSearch)
            syncing = true
            seedLabels = lookup
            controls.seed.Value = selected
            controls.seed:Refresh(labels)
            if syncInputs ~= false then Plant.syncInputs() end
            UI.paragraph(controls.choices, "Seed choices", more and "Showing up to 40 choices. Narrow the search to find another seed."
                or "Showing backpack seeds, the selected seed, and seeds in your saved box. Search by name or exact ID for other seeds.")
            syncing = false
        end
        Plant.refreshSeeds = refreshSeeds

        function Plant.syncInputs()
            local was = syncing
            syncing = true
            pcall(function() controls.storageWorld:Set(App.config.planting.storageWorld) end)
            pcall(function() controls.worlds:Set(table.concat(App.config.planting.worlds, ", ")) end)
            UI.paragraph(controls.point, "Planting seed storage", Storage.pointText(App.config.points.plantBox))
            syncing = was
        end

        local function changeSetting(key, value)
            if syncing or App.syncingUI then return end
            local ok, message = pcall(function()
                Net.idle()
                if key == "seedId" then value = assert(seedLabels[value], "Choose a seed.")
                elseif key == "worlds" then value = Core.parseWorlds(value)
                elseif value ~= "" then value = Core.worldName(value) end
                local candidate = Core.validate(App.config)
                candidate.planting[key] = value
                App.config.planting = Core.validatePlanting(candidate.planting)
                State.saveSession()
            end)
            if not ok then G.notify(tostring(message)) end
        end

        UI.addStatus(tab:Paragraph({ Title = "Status", Desc = App.status }))
        tab:Paragraph({ Title = "Fill dirt farms with seeds", Desc = "Start at the top-left supported farm row and alternate left-to-right and right-to-left down the farm. Skip occupied, floating, and denied tiles. Refill from the saved seed Display Box and resume the same row direction, then continue through your farm world list." })
        controls.search = tab:Input({ Title = "Find seed by name or ID", Value = "", Placeholder = "e.g. Sugar Cane or 955",
            Callback = function(value)
                if syncing or App.syncingUI then return end
                seedSearch, generation = tostring(value or ""), generation + 1
                local mine = generation
                task.spawn(function()
                    task.wait(0.25)
                    if not App.alive or mine ~= generation then return end
                    local ok, issue = pcall(refreshSeeds, false)
                    if not ok and App.alive then G.notify(tostring(issue)) end
                end)
            end })
        controls.choices = tab:Paragraph({ Title = "Seed choices", Desc = "Backpack and saved seed choices load after connecting. Search to find other seeds." })
        controls.seed = tab:Dropdown({ Title = "Seed to plant", Values = {}, SearchBarEnabled = true,
            Callback = function(value)
                if type(value) == "table" then value = value[1] end
                changeSetting("seedId", value)
            end })
        controls.storageWorld = tab:Input({ Title = "Seed storage world", Value = App.config.planting.storageWorld,
            Placeholder = "e.g. ZZ4", Callback = function(value) changeSetting("storageWorld", value) end })
        controls.worlds = tab:Input({ Title = "Dirt farm worlds (in order)", Value = table.concat(App.config.planting.worlds, ", "),
            Placeholder = "FARM1, FARM2, FARM3", Callback = function(value) changeSetting("worlds", value) end })
        controls.point = tab:Paragraph({ Title = "Planting seed storage", Desc = Storage.pointText(App.config.points.plantBox) })
        tab:Button({ Title = "Save seed Display Box", Desc = "Berdiri di samping box seed. Box boleh berisi item lain; yang diambil cuma seed yang dipilih. Box berisi 1 jenis seed langsung memilih seed itu.",
            Callback = UI.action(function()
                local point = Storage.captureNearby("plantBox", "box")
                App.config.planting.storageWorld = Core.worldName(Bridge.runtime().world.name)
                -- Box berisi tepat 1 jenis seed = seed itu otomatis dipilih. Box campur boleh.
                local seed, seeds = nil, 0
                for _, row in pairs(Storage.boxRows(point)) do
                    local item = Bridge.runtime().items[row[1]]
                    if item and item.kind == "seed" and row[1] ~= seed then seed, seeds = row[1], seeds + 1 end
                end
                if seeds == 1 then App.config.planting.seedId = seed end
                refreshSeeds()
                G.setStatus("Saved planting seed storage: " .. Storage.pointText(point))
            end) })
        tab:Button({ Title = "Refresh seed choices", Callback = UI.action(refreshSeeds) })
        G.Jobs.toggles.plant = tab:Toggle({ Title = "Plant seeds", Value = false,
            Desc = "On plants and refills automatically. Off stops. Unreachable or denied tiles are reported and skipped.",
            Callback = function(enabled) G.Jobs.setRunning("plant", enabled) end })
        tab:Button({ Title = "Resume planting", Desc = "Restore the seed, world list, and progress after a server change or interruption.",
            Callback = function() local ok, message = pcall(Plant.resume); if not ok then G.notify(tostring(message)) end end })
        tab:Button({ Title = "Clear saved planting", Desc = "Use after checking an interrupted storage withdrawal or seed placement.",
            Callback = UI.action(function() Plant.clearResume(); G.setStatus("Cleared saved planting.") end) })
        syncing = false
        -- Setelah tersambung ke game, isi pilihan seed.
        table.insert(G.onConnected, function() pcall(refreshSeeds) end)
    end

    return Plant
end

end)()

-- ===== src/pnb.lua =====
__modules["pnb"] = (function(...)
-- pnb.lua: Place & Break dengan grid 5x5 (layout terinspirasi Crusader), stock & seed lewat Display Box,
-- dan Auto Collect.
-- placeTile/breakTile/settleTile diadaptasi dari Clarissv main.lua v0.1.43; bedanya grid bisa
-- sampai 24 tile di sekitar karakter, dan tile yang terisi blok lain dilewati, bukan error.
return function(G)
    local App, Core, Bridge, Net, Actions, Movement, Drops, State, task =
        G.App, G.Core, G.Bridge, G.Net, G.Actions, G.Movement, G.Drops, G.State, G.task
    local Pnb = {}
    local worldCheck, position, checkpoint, pause = Bridge.worldCheck, Bridge.position, Net.checkpoint, Net.pause
    local count, tileAt, refreshInventory = Actions.count, Actions.tileAt, Actions.refreshInventory

    ---------------------------------------------------------------- posisi
    -- Tile berdiri karakter sekarang: x = kolom, y = baris tempat badan (kaki di y + 1).
    function Pnb.standingTile()
        local r, state = Bridge.runtime(), position()
        assert(state.grounded, "Berdiri di lantai dulu, jangan sambil lompat.")
        return { world = r.world.name, x = math.floor(state.x), y = math.floor(state.y - 0.01) }
    end
    -- Tile absolut dari daftar offset, urut atas ke bawah, kiri ke kanan.
    function Pnb.targets(anchor)
        local list = {}
        for _, tile in ipairs(Core.sortPNBTiles(Core.validatePNBTiles(App.config.pnb.tiles))) do
            table.insert(list, { x = anchor.x + tile.dx, y = anchor.y + tile.dy })
        end
        return list
    end
    local function atAnchor(anchor)
        local state = position()
        return state.grounded and math.abs(state.x - (anchor.x + 0.5)) < 0.3 and math.abs(state.y - (anchor.y + 1)) < 0.3
    end
    local function ensureAnchor(anchor, token)
        if not atAnchor(anchor) then Movement.moveTo(anchor.x, anchor.y, anchor.world, token) end
    end
    -- Karakter terdorong/terangkat dari spot (seperti di Clarissv: dipulihkan, bukan stop).
    -- Tunggu sebentar kalau masih di udara, lalu jalan balik ke spot. Terlalu sering = stop.
    local recoveries = {}
    local function holdAnchor(anchor, token)
        if atAnchor(anchor) then return end
        local settle = os.clock() + 0.6
        while os.clock() < settle and not atAnchor(anchor) do pause(0.05, token) end
        if atAnchor(anchor) then return end
        local now = os.clock()
        table.insert(recoveries, now)
        while recoveries[1] and now - recoveries[1] > 60 do table.remove(recoveries, 1) end
        assert(#recoveries <= 10, "Karakter terus bergeser dari posisi PNB (10x dalam 1 menit). Cek apa yang mendorong karakter.")
        App.pnbRecoveries = (App.pnbRecoveries or 0) + 1
        G.setStatus("Karakter bergeser; kembali ke posisi PNB...")
        local hold = Movement.takeControls()
        hold.direction, hold.jump = 0, false
        Movement.moveTo(anchor.x, anchor.y, anchor.world, token)
    end

    ---------------------------------------------------------------- place & break
    local function settleTile(x, y, id, seconds, worldName, token)
        local deadline = os.clock() + seconds
        repeat
            worldCheck(worldName, token)
            assert(tileAt(x, y) == id, "Tile " .. x .. ", " .. y .. " changed while the action settled. Stopping.")
            pause(0.03, token)
        until os.clock() >= deadline
    end

    -- Taruh satu blok, lalu tunggu server benar-benar mengurangi blok di tas.
    local function placeTile(anchor, point, id, token)
        return Movement.withoutPickups(function()
            local r = worldCheck(anchor.world, token)
            holdAnchor(anchor, token)
            local before = refreshInventory(token)[id] or 0
            worldCheck(anchor.world, token)
            if tileAt(point.x, point.y) ~= 0 then return false end
            assert(r.handlers.canPlace(r.items[id], point.x, point.y),
                "Cannot place at " .. point.x .. ", " .. point.y .. ". Check reach, access, and empty tiles.")
            assert(before > 0, "No blocks are left in your backpack.")
            r.handlers.setTile("fg", point.x, point.y, id, false, (position().facing or 1) < 0)
            App.lastPlacement = { x = point.x, y = point.y, world = anchor.world, grid = r.world.fg, at = os.clock() }
            r.inventory:remove(id, 1)
            pause(App.config.options.placeDelay, token)
            local deadline = os.clock() + App.config.options.actionTimeout
            while true do
                worldCheck(anchor.world, token)
                local after = refreshInventory(token)[id] or 0
                if after == before - 1 then break end
                assert(after == before, "Backpack changed unexpectedly while placing. Stopping.")
                assert(os.clock() < deadline, "The server did not consume a block for tile "
                    .. point.x .. ", " .. point.y .. ". Check placement access and range.")
                pause(0.15, token)
            end
            settleTile(point.x, point.y, id, 0.12, anchor.world, token)
            return true
        end)
    end

    -- Pukul sampai pecah. Jeda antar pukulan = Hit delay (punchDelay).
    local function breakTile(anchor, point, id, token)
        local r = worldCheck(anchor.world, token)
        assert(tileAt(point.x, point.y) == id, "The target tile changed. Stopping before punching another block.")
        local deadline = os.clock() + App.config.options.actionTimeout + (r.items[id].hits or 1) * App.config.options.punchDelay
        local placed = App.lastPlacement
        if placed and placed.world == anchor.world and placed.grid == r.world.fg and placed.x == point.x and placed.y == point.y then
            local remaining = 0.32 - (os.clock() - placed.at) -- blok baru ditaruh butuh waktu sebelum bisa dipukul
            if remaining > 0 then pause(remaining, token) end
        end
        while tileAt(point.x, point.y) == id do
            worldCheck(anchor.world, token)
            if not atAnchor(anchor) then
                holdAnchor(anchor, token)
                deadline = os.clock() + App.config.options.actionTimeout -- waktu jalan balik tidak dihitung
            end
            assert(os.clock() < deadline, "Block did not break. Check permissions and your punching range.")
            r.handlers.hit(point.x, point.y)
            pause(App.config.options.punchDelay, token)
        end
        assert(tileAt(point.x, point.y) == 0, "The block changed while breaking.")
        settleTile(point.x, point.y, 0, math.max(0.18, App.config.options.punchDelay), anchor.world, token)
        App.stats.broken = App.stats.broken + 1
    end

    Pnb.placeTile, Pnb.breakTile = placeTile, breakTile -- dipakai Rotation

    -- Area pungut di sekitar grid 5x5: 2,75 tile ke samping, 3 ke atas, 2,5 ke bawah.
    local GRID_AREA = { radius = 2.75, up = 3, down = 2.5 }

    ---------------------------------------------------------------- stock & seed
    -- Ambil stock dari Display Box (sama seperti PNB Clarissv: "Refilling blocks from the right
    -- storage box", world.call("DisplayItem", x, y, nil)). Box berisi blok yang di-PNB saja.
    -- Return: jumlah blok yang diambil (0 = box kosong).
    function Pnb.takeStock(anchor, blockId, token)
        local box = App.config.points.stock
        G.setStatus("Mengambil stock blok dari Display Box...")
        local taken = G.Storage.withdraw(box, blockId, token)
        App.stockDebug = os.date("%H:%M:%S") .. " +" .. taken .. " blok dari box " .. box.x .. ", " .. box.y
        ensureAnchor(anchor, token)
        return taken
    end

    -- Auto drop seed = taruh seed ke Display Box (sama seperti PNB Clarissv: "Putting seeds into
    -- the left storage box", world.call("DisplayItem", ...)). Drop ke lantai tidak dipakai karena
    -- belum ada perintah server yang diketahui untuk itu.
    function Pnb.dropSeeds(anchor, seedId, token)
        local box = App.config.points.seedDrop
        G.setStatus("Menaruh seed ke Display Box...")
        G.Storage.deposit(box, seedId, count(seedId), token)
        refreshInventory(token)
        ensureAnchor(anchor, token)
    end

    -- Pungut hasil PNB: semua blok/seed/gem (atau semua item kalau Auto Collect nyala) di area
    -- grid 5x5. Tile di pinggir grid (2 tile dari karakter) di luar jangkauan server, jadi
    -- karakter melangkah ke sana, memungut, lalu kembali ke posisi PNB.
    local GRID_AREA = { radius = 2.75, up = 3, down = 2.5 }
    -- quick = true (tiap putaran PNB): kalau belum ada drop di area, lewati tanpa request apa pun.
    local function anyDrop(anchor, ids, area)
        local all, wanted = ids == "all", {}
        if not all then for _, id in ipairs(ids) do wanted[id] = true end end
        for _, drop in pairs(Bridge.runtime().world.dropList()) do
            if type(drop) == "table" and not drop.display and type(drop.n) == "number" and drop.n > 0
                and (all or wanted[drop.id]) and type(drop.x) == "number" and type(drop.y) == "number"
                and math.abs(drop.x - (anchor.x + 0.5)) <= area.radius
                and drop.y >= anchor.y - area.up and drop.y <= anchor.y + area.down then return true end
        end
        return false
    end
    function Pnb.collect(anchor, pickupIds, token, quick)
        local ids, area = pickupIds, GRID_AREA
        if App.config.options.autoCollect then
            local range = App.config.options.collectRange
            ids = "all"
            area = { radius = math.max(GRID_AREA.radius, range), up = math.max(GRID_AREA.up, range),
                down = math.max(GRID_AREA.down, range) }
        end
        if quick and not anyDrop(anchor, ids, area) then
            App.collectSkips = (App.collectSkips or 0) + 1
            return
        end
        local got = Drops.collectArea(anchor, ids, token, area)
        local n = 0
        for _, amount in pairs(got) do n = n + amount end
        App.pnbCollected = (App.pnbCollected or 0) + n
        ensureAnchor(anchor, token)
    end

    ---------------------------------------------------------------- Auto Collect (saat tidak ada task)
    -- Tiap 0.3 detik: kalau ada item di lantai dalam jangkauan karakter, pungut (tanpa jalan).
    -- Server Growblox menolak pungut dari jauh; drop yang ditolak 3x dilewati selama 15 detik.
    local autoAttempts, autoReset = {}, 0
    function Pnb.autoCollectTick()
        local options = App.config and App.config.options
        if not (App.alive and options and options.autoCollect) or App.job or App.pending > 0
            or App.configuring or App.autoCollectHold or App.teleporting then return false end
        if os.clock() > autoReset then autoAttempts, autoReset = {}, os.clock() + 15 end
        local okRuntime, r = pcall(Bridge.runtime)
        if not okRuntime or type(r) ~= "table" or not r.world or not r.inventory then return false end
        local okPos, state = pcall(position)
        if not okPos or type(state) ~= "table" then return false end
        local range = options.collectRange
        local here = { world = r.world.name, x = math.floor(state.x), y = math.floor(state.y - 0.01) }
        local any = false
        for _, drop in pairs(r.world.dropList()) do
            if not drop.display and not drop.taking and type(drop.uid) == "number" and type(drop.n) == "number"
                and drop.n > 0 and type(drop.x) == "number" and type(drop.y) == "number"
                and (autoAttempts[drop.uid] or 0) < 3
                and math.abs(drop.x - (here.x + 0.5)) <= range and drop.y >= here.y - range and drop.y <= here.y + range
                and (drop.id == Drops.GEM or r.inventory:room(drop.id) > 0) then any = true; break end
        end
        if not any then return false end
        App.autoCollecting = true
        local ok, got = pcall(Drops.collectNear, here, "all", nil, { radius = range, up = range, down = range,
            attempts = autoAttempts, stopIf = function() return App.autoCollectHold or App.job ~= nil or not App.alive end })
        App.autoCollecting = false
        if ok then
            local n = 0
            for _, amount in pairs(got or {}) do n = n + amount end
            if n > 0 then App.autoCollectInfo = "terakhir +" .. n .. " item" end
        else
            App.autoCollectInfo = "error: " .. tostring(got)
        end
        return ok
    end

    ---------------------------------------------------------------- rejoin & resume
    -- Adaptasi Clarissv v0.1.43: savePNBResume, refreshPNBCheckpoint, classifyPNBFault, recoverPNB.
    -- Setting "Rejoin world and return to PNB" (options.autoRejoin): kalau terlempar ke world picker,
    -- avatar mati/respawn, atau pindah server, masuk lagi ke world PNB lalu jalan balik ke spot.
    local resumePoint = G.Jobs.checkpointer("pnb", function() return { anchor = App.config.points.pnb } end)
    Pnb.saveResume, Pnb.clearResume = resumePoint.save, resumePoint.clear

    -- Masuk lagi ke world PNB (lewat world picker, bisa pindah server) lalu jalan ke spot.
    function Pnb.returnToSpot(token)
        local anchor = App.config.points.pnb
        App.recovering = true
        G.setStatus("Masuk lagi ke " .. anchor.world .. "...")
        Movement.enterWorld(anchor.world, token, { save = Pnb.saveResume, label = "Place & Break",
            resumeButton = "Place & Break" })
        Movement.takeControls()
        refreshInventory(token)
        G.setStatus("Jalan balik ke spot PNB...")
        Movement.moveTo(anchor.x, anchor.y, anchor.world, token)
        App.recovering = false
        G.setStatus("Sudah di spot PNB. Lanjut Place & Break...")
    end

    ---------------------------------------------------------------- loop utama
    function Pnb.run(token)
        local r = Bridge.runtime()
        local anchor, blockId = App.config.points.pnb, App.config.blockId
        local okSeed, seedId = pcall(Core.seedId, r.items, blockId)
        if not okSeed then seedId = nil end
        local pickupIds = { blockId, Drops.GEM }
        if seedId then table.insert(pickupIds, seedId) end
        worldCheck(anchor.world, token)
        ensureAnchor(anchor, token)
        if App.config.options.autoRejoin then Pnb.saveResume(); Movement.queueResume() end
        G.setStatus("PNB mulai di " .. anchor.world .. " (" .. anchor.x .. ", " .. anchor.y .. "), " .. #App.config.pnb.tiles .. " tile.")
        while true do
            checkpoint(token)
            worldCheck(anchor.world, token)
            resumePoint.refresh()
            holdAnchor(anchor, token)
            refreshInventory(token)
            if seedId and App.config.pnb.autoDrop and count(seedId) >= App.config.options.seedThreshold then
                Pnb.dropSeeds(anchor, seedId, token)
            end
            local targets, existing = Pnb.targets(anchor), false
            for _, point in ipairs(targets) do if tileAt(point.x, point.y) == blockId then existing = true end end
            if count(blockId) == 0 and not existing then
                Pnb.collect(anchor, pickupIds, token)
                if count(blockId) == 0 then
                    if App.config.pnb.autoStock then Pnb.takeStock(anchor, blockId, token) end
                    if not (App.config.pnb.autoStock and (refreshInventory(token)[blockId] or 0) > 0) then
                        G.setStatus(App.config.pnb.autoStock and "Selesai: Display Box stock kosong."
                            or "Selesai: blok di tas habis. Nyalakan Auto take stock untuk ambil dari Display Box.")
                        return
                    end
                end
            end
            G.setStatus("Placing " .. r.items[blockId].name .. "...")
            local worked = existing
            for _, point in ipairs(targets) do
                if count(blockId) == 0 then break end
                if tileAt(point.x, point.y) == 0 and placeTile(anchor, point, blockId, token) then worked = true end
            end
            G.setStatus("Breaking the selected blocks...")
            for _, point in ipairs(targets) do
                if tileAt(point.x, point.y) == blockId then breakTile(anchor, point, blockId, token) end
            end
            assert(worked, "Semua tile PNB terhalang blok lain. Kosongkan tile yang dipilih atau pilih tile lain.")
            G.setStatus("Collecting gems, seeds, and returned blocks...")
            Pnb.collect(anchor, pickupIds, token, true)
        end
    end

    G.Jobs.register("pnb", {
        label = "Place & Break",
        save = function() Pnb.saveResume() end,
        prepare = function(r, saved)
            assert(r.body and r.controls and r.handlers.setTile and r.handlers.hit and r.handlers.canPlace,
                "Hook place/break tidak tersedia. Copy diagnostics dari Settings.")
            -- Posisi PNB = tempat karakter berdiri saat toggle dinyalakan (seperti Crusader).
            -- Resume setelah pindah server: pakai spot dari checkpoint.
            if saved and saved.anchor then App.config.points.pnb = saved.anchor
            else App.config.points.pnb = Pnb.standingTile() end
        end,
        -- Sama seperti Clarissv: keluar world / avatar mati + setting Rejoin nyala = masuk lagi ke
        -- world, balik ke spot, lanjut PNB (Jobs.resilient). Gagal 3x tanpa kemajuan = berhenti.
        run = function(token, saved)
            G.Jobs.resilient(token, saved, {
                label = "Place & Break",
                world = function() return App.config.points.pnb.world end,
                progress = function() return App.stats.broken end,
                loop = function(loopToken, resume)
                    local anchor, r = App.config.points.pnb, Bridge.runtime()
                    if resume and (r.world.name ~= anchor.world or Bridge.pickerOpen(r) or resume.retry) then
                        Pnb.returnToSpot(loopToken)
                    end
                    Pnb.run(loopToken)
                end,
            })
            Pnb.clearResume()
        end,
        clear = function() Pnb.clearResume() end,
        resume = true, -- lanjut otomatis setelah pindah server
        validResume = function(data) return type(data.anchor) == "table" end,
        resumeWorld = function(data) return data.anchor and data.anchor.world end,
    })

    ---------------------------------------------------------------- tab Place & Break
    local function tileSet()
        local set = {}
        for _, tile in ipairs(App.config.pnb.tiles) do set[tile.dx .. ":" .. tile.dy] = true end
        return set
    end
    -- Peta teks 5x5 untuk paragraf: [Y] = karakter, [#] = dipilih, [ ] = kosong.
    function Pnb.gridText()
        local set, lines = tileSet(), {}
        for dy = -2, 2 do
            local row = {}
            for dx = -2, 2 do
                row[#row + 1] = (dx == 0 and dy == 0) and "[Y]" or (set[dx .. ":" .. dy] and "[#]" or "[  ]")
            end
            lines[#lines + 1] = table.concat(row, " ")
        end
        return table.concat(lines, "\n")
    end
    function Pnb.toggleTile(dx, dy)
        Net.idle()
        if dx == 0 and dy == 0 then return end
        local tiles, removed = {}, false
        for _, tile in ipairs(App.config.pnb.tiles) do
            if tile.dx == dx and tile.dy == dy then removed = true else table.insert(tiles, tile) end
        end
        if not removed then table.insert(tiles, { dx = dx, dy = dy }) end
        App.config.pnb.tiles = Core.validatePNBTiles(tiles)
        State.saveSession()
        if Pnb.refreshTab then Pnb.refreshTab() end
    end

    -- Panel 5x5 melayang (Roblox GUI). Klik kotak = pilih/batal pilih tile; kotak tengah = karakter.
    function Pnb.openGridPanel()
        if Pnb.panel and Pnb.panel.Parent then Pnb.panel:Destroy(); Pnb.panel = nil; return end
        local new = G.newInstance
        local gui = new("ScreenGui")
        gui.Name, gui.ResetOnSpawn = "GrowbloxHanselPNBTiles", false
        local frame = new("Frame")
        frame.Size, frame.Position = G.UDim2.fromOffset(250, 300), G.UDim2.new(0.5, -125, 0.5, -150)
        frame.BackgroundColor3, frame.BorderSizePixel, frame.Active = G.Color3.fromRGB(30, 30, 36), 0, true
        frame.Parent = gui
        local title = new("TextLabel")
        title.Size, title.Position, title.BackgroundTransparency = G.UDim2.fromOffset(250, 30), G.UDim2.fromOffset(0, 0), 1
        title.Text, title.TextColor3, title.TextSize = "PNB tiles - klik untuk pilih", G.Color3.fromRGB(235, 235, 235), 14
        title.Parent = frame
        local buttons = {}
        local function paint()
            local set = tileSet()
            for key, button in pairs(buttons) do
                local selected = set[key]
                button.BackgroundColor3 = selected and G.Color3.fromRGB(70, 160, 90) or G.Color3.fromRGB(60, 60, 70)
                button.Text = selected and "#" or ""
            end
        end
        for dy = -2, 2 do
            for dx = -2, 2 do
                local button = new("TextButton")
                button.Size = G.UDim2.fromOffset(42, 42)
                button.Position = G.UDim2.fromOffset(15 + (dx + 2) * 45, 38 + (dy + 2) * 45)
                button.BorderSizePixel, button.TextColor3, button.TextSize = 0, G.Color3.fromRGB(255, 255, 255), 16
                button.Parent = frame
                if dx == 0 and dy == 0 then
                    button.Text, button.BackgroundColor3, button.AutoButtonColor = "You", G.Color3.fromRGB(70, 110, 190), false
                else
                    buttons[dx .. ":" .. dy] = button
                    button.MouseButton1Click:Connect(function()
                        local ok, message = pcall(Pnb.toggleTile, dx, dy)
                        if not ok then G.notify(tostring(message)) end
                        paint()
                    end)
                end
            end
        end
        local close = new("TextButton")
        close.Size, close.Position = G.UDim2.fromOffset(220, 30), G.UDim2.fromOffset(15, 262)
        close.Text, close.BackgroundColor3, close.TextColor3 = "Tutup", G.Color3.fromRGB(90, 50, 50), G.Color3.fromRGB(255, 255, 255)
        close.BorderSizePixel, close.Parent = 0, frame
        close.MouseButton1Click:Connect(function() gui:Destroy(); Pnb.panel = nil end)
        paint()
        gui.Parent = G.guiParent()
        Pnb.panel = gui
    end

    function Pnb.buildTab(tab)
        local UI = G.UI
        local controls, blockLookup, syncing = {}, {}, true

        local function refreshBlocks()
            if not App.runtime then return end
            local labels, selected = {}, nil
            blockLookup = {}
            for _, block in ipairs(Actions.farmableBlocks()) do
                local label = block.name .. " [" .. block.id .. "] x" .. count(block.id)
                table.insert(labels, label)
                blockLookup[label] = block.id
                if block.id == App.config.blockId then selected = label end
            end
            syncing = true
            pcall(function() controls.block:Refresh(labels) end)
            if selected then pcall(function() controls.block:Select(selected) end) end
            syncing = false
        end
        function Pnb.refreshTab()
            UI.paragraph(controls.grid, "PNB tiles", Pnb.gridText())
            UI.paragraph(controls.stock, "Stock (Display Box)", G.Storage.pointText(App.config.points.stock))
            UI.paragraph(controls.drop, "Seed drop (Display Box)", G.Storage.pointText(App.config.points.seedDrop))
        end
        local function setOption(fn)
            if syncing then return end
            local ok, message = pcall(function() Net.idle(); fn(); State.saveSession() end)
            if not ok then G.notify(tostring(message)) end
        end

        UI.addStatus(tab:Paragraph({ Title = "Status", Desc = App.status }))
        controls.block = tab:Dropdown({ Title = "Block in your backpack", Values = {}, SearchBarEnabled = true,
            Callback = function(value)
                if type(value) == "table" then value = value[1] end
                setOption(function() App.config.blockId = assert(blockLookup[value], "Pilih blok.") end)
            end })
        tab:Button({ Title = "Refresh block", Callback = UI.action(refreshBlocks) })
        G.Jobs.toggles.pnb = tab:Toggle({ Title = "Place & Break", Value = false,
            Desc = "Posisi PNB = tempat lo berdiri saat toggle dinyalakan.",
            Callback = function(enabled) G.Jobs.setRunning("pnb", enabled) end })
        tab:Slider({ Title = "Hit delay (detik)", Step = 0.01,
            Value = { Min = Core.LIMITS.punchDelay[1], Max = Core.LIMITS.punchDelay[2], Default = App.config.options.punchDelay },
            Callback = function(value) setOption(function() App.config.options.punchDelay = tonumber(value) end) end })

        pcall(function() tab:Section({ Title = "Auto Collect" }) end)
        controls.autoCollect = tab:Toggle({ Title = "Auto Collect", Value = App.config.options.autoCollect,
            Desc = "Pungut semua item (blok, seed, gem, dll.) di sekitar karakter. Jalan sendiri, juga ikut saat PNB.",
            Callback = function(enabled) setOption(function() App.config.options.autoCollect = enabled == true end) end })
        tab:Slider({ Title = "Jangkauan collect (tile)", Step = 0.5,
            Value = { Min = Core.LIMITS.collectRange[1], Max = Core.LIMITS.collectRange[2], Default = App.config.options.collectRange },
            Callback = function(value) setOption(function() App.config.options.collectRange = tonumber(value) end) end })

        pcall(function() tab:Section({ Title = "Stock" }) end)
        controls.stock = tab:Paragraph({ Title = "Stock (Display Box)", Desc = "Belum diset" })
        tab:Button({ Title = "Set stock position here", Desc = "Berdiri di samping Display Box berisi blok yang di-PNB.",
            Callback = UI.action(function()
                local box = G.Storage.captureNearby("stock", "box")
                Pnb.refreshTab()
                G.setStatus("Display Box stock disimpan: tile " .. box.x .. ", " .. box.y .. ".")
            end) })
        controls.autoStock = tab:Toggle({ Title = "Auto take stock", Value = App.config.pnb.autoStock,
            Desc = "Blok di tas habis: jalan ke Display Box stock, ambil blok, lalu lanjut PNB.",
            Callback = function(enabled) setOption(function() App.config.pnb.autoStock = enabled == true end) end })

        controls.drop = tab:Paragraph({ Title = "Seed drop (Display Box)", Desc = "Belum diset" })
        tab:Button({ Title = "Set seed drop position here", Desc = "Berdiri di samping Display Box tempat seed ditaruh.", Callback = UI.action(function()
            local box = G.Storage.captureNearby("seedDrop", "box")
            Pnb.refreshTab()
            G.setStatus("Display Box seed disimpan: tile " .. box.x .. ", " .. box.y .. ".")
        end) })
        controls.autoDrop = tab:Toggle({ Title = "Auto drop seed", Value = App.config.pnb.autoDrop,
            Desc = "Seed di tas mencapai batas: jalan ke Display Box seed, taruh semua seed, lalu lanjut PNB.",
            Callback = function(enabled) setOption(function() App.config.pnb.autoDrop = enabled == true end) end })
        tab:Slider({ Title = "Drop seed saat seed di tas >=", Step = 1,
            Value = { Min = 1, Max = 200, Default = App.config.options.seedThreshold },
            Callback = function(value) setOption(function() App.config.options.seedThreshold = math.floor(tonumber(value)) end) end })

        controls.grid = tab:Paragraph({ Title = "PNB tiles", Desc = Pnb.gridText() })
        tab:Button({ Title = "Atur PNB tiles (5x5)", Desc = "Buka panel kotak 5x5. Kotak tengah = lo. Klik kotak lain untuk dipilih.",
            Callback = function() local ok, message = pcall(Pnb.openGridPanel); if not ok then G.notify(tostring(message)) end end })
        tab:Button({ Title = "Clear tiles", Callback = UI.action(function()
            App.config.pnb.tiles = {}
            Pnb.refreshTab()
            G.setStatus("Semua tile PNB dihapus. Pilih lagi lewat Atur PNB tiles.")
        end) })
        syncing = false
        Pnb.refreshTab()
        table.insert(G.onConnected, function() pcall(refreshBlocks); pcall(Pnb.refreshTab) end)
        task.spawn(function()
            while App.alive do
                task.wait(0.3)
                pcall(Pnb.autoCollectTick)
            end
        end)
    end

    return Pnb
end

end)()

-- ===== src/harvest.lua =====
__modules["harvest"] = (function(...)
-- harvest.lua: panen pohon dengan Fist, diadaptasi dari Clarissv main.lua v0.1.43
-- (runTreeHarvest mode Fist, runHarvest, makeHarvestPlanter). Aturan Hansel:
--   0) multi world seperti Planting; tanaman & Display Box dideteksi otomatis per world;
--   1) scan dulu; 2) yang dipanen cuma pohon yang SUDAH mateng (Clarissv menunggu semua);
--   3) pukul pohon sambil collect: pickup bawaan game tetap nyala saat jalan, dan sisa drop
--      tiap baris dipungut sebelum pindah baris; 4) hasil (blok + seed) disimpan ke Display Box world itu;
--   5) opsional Replant during harvest: tile yang baru dipanen langsung ditanam lagi.
return function(G)
    local App, Core, Bridge, Net, Actions, Movement, Drops, Storage, Scan =
        G.App, G.Core, G.Bridge, G.Net, G.Actions, G.Movement, G.Drops, G.Storage, G.Scan
    local Harvest = {}
    local worldCheck, checkpoint, pause = Bridge.worldCheck, Net.checkpoint, Net.pause
    local count, tileAt, refreshInventory = Actions.count, Actions.tileAt, Actions.refreshInventory

    local function duration(seconds)
        seconds = math.floor(seconds + 0.5)
        if seconds >= 3600 then return string.format("%dj %dm", math.floor(seconds / 3600), math.floor((seconds % 3600) / 60)) end
        if seconds >= 60 then return string.format("%dm %dd", math.floor(seconds / 60), seconds % 60) end
        return seconds .. "d"
    end

    -- Hasil "scan" untuk panen: baris farm (zigzag) berisi pohon yang sudah mateng.
    function Harvest.plan(r, seedId)
        local tiles = {}
        for y = 0, r.world.h - 1 do
            for x = 0, r.world.w - 1 do
                if r.world.fg[y] and r.world.fg[y][x] == seedId then table.insert(tiles, { x = x, y = y }) end
            end
        end
        local resolver, problem = Scan.resolveTrees(r, tiles)
        assert(#tiles == 0 or resolver, "Data pohon tidak terbaca: " .. tostring(problem) .. ". Scan world lalu copy diagnostics.")
        local work, ripe, growing, longest, soonest = {}, 0, 0, 0, nil
        for _, row in ipairs(Core.farmRows(r.world, r.items)) do
            local points = {}
            local first, last = row.direction == 1 and row.left or row.right, row.direction == 1 and row.right or row.left
            for x = first, last, row.direction do
                if tileAt(x, row.y) == seedId then
                    local ready = resolver.ripe(x, row.y, seedId)
                    if ready then table.insert(points, { x = x, y = row.y }); ripe = ripe + 1
                    elseif ready == false then
                        growing = growing + 1
                        local left = resolver.remaining(x, row.y, seedId) or 0
                        longest = math.max(longest, left)
                        soonest = math.min(soonest or left, left)
                    end
                end
            end
            if #points > 0 then table.insert(work, { row = row, points = points }) end
        end
        return { rows = work, ripe = ripe, growing = growing, longest = longest, soonest = soonest, resolver = resolver }
    end

    -- Simpan blok (dan seed) hasil panen ke Display Box farm. keepSeeds = sisakan seed untuk replant.
    local function store(blockId, seedId, keepSeeds, token, box)
        box = box or App.config.points.farmBox
        refreshInventory(token)
        if count(blockId) > 0 or count(seedId) - (keepSeeds or 0) > 0 then
            local used, why = Movement.respawnNear(box, token) -- box dekat pintu putih: respawn, bukan jalan
            if not used then App.respawnInfo = App.respawnInfo or ("jalan kaki: " .. tostring(why)) end
            refreshInventory(token)
        end
        if count(blockId) > 0 then
            G.setStatus("Menyimpan blok hasil panen ke Display Box farm...")
            Storage.deposit(box, blockId, count(blockId), token, nil, seedId)
        end
        local seeds = count(seedId) - (keepSeeds or 0)
        if seeds > 0 then
            G.setStatus("Menyimpan seed hasil panen ke Display Box farm...")
            Storage.deposit(box, seedId, seeds, token, nil, blockId)
        end
    end

    -- Tanam ulang satu tile yang baru dipanen. Dikonfirmasi ke server (jumlah seed berkurang 1
    -- dan tile berisi seed). Ditolak/tidak terkonfirmasi = dilewati, panen tetap lanjut.
    local function replant(r, point, seedId, token)
        if tileAt(point.x, point.y) ~= 0 or count(seedId) <= 0 then return false end
        if not r.handlers.plantSeed or not r.handlers.canPlace(r.items[seedId], point.x, point.y) then return false end
        return Movement.withoutPickups(function()
            local before = refreshInventory(token)[seedId] or 0
            if before <= 0 then return false end
            r.handlers.plantSeed(seedId, point.x, point.y)
            pause(math.max(0.15, App.config.options.placeDelay), token)
            local deadline = os.clock() + App.config.options.actionTimeout
            repeat
                worldCheck(r.world.name, token)
                local now = refreshInventory(token)[seedId] or 0
                if now == before - 1 and tileAt(point.x, point.y) == seedId then
                    App.stats.replanted = (App.stats.replanted or 0) + 1
                    return true
                end
                pause(0.15, token)
            until os.clock() >= deadline
            return false
        end)
    end

    -- Pukul satu pohon mateng sampai tile kosong (maks 3 pukulan, seperti Clarissv).
    local function harvestTree(r, point, seedId, resolver, token)
        local name = r.world.name
        if tileAt(point.x, point.y) ~= seedId or not resolver.ripe(point.x, point.y, seedId) then return false end
        Movement.moveTo(point.x, point.y, name, token)
        if tileAt(point.x, point.y) ~= seedId then return false end
        local tries = 0
        repeat
            worldCheck(name, token)
            tries = tries + 1
            assert(tries <= 3, "Fist tidak berhasil memanen pohon di " .. point.x .. ", " .. point.y .. ". Cek akses world.")
            r.handlers.hit(point.x, point.y)
            -- Tunggu jawaban server (ping tinggi bisa > 0,25 detik) sebelum memukul lagi, supaya
            -- tidak memukul dobel lalu dianggap gagal. Maks ~1,2 detik per pukulan.
            pause(math.max(0.1, App.config.options.punchDelay * 0.5), token)
            for _ = 1, 22 do
                if tileAt(point.x, point.y) ~= seedId then break end
                pause(0.05, token)
            end
        until tileAt(point.x, point.y) ~= seedId
        App.stats.trees = (App.stats.trees or 0) + 1
        return true
    end

    ---------------------------------------------------------------- deteksi otomatis
    -- Tanaman di world = jenis seed yang paling banyak ditanam (pohon) di world itu.
    function Harvest.detectCrop(r)
        local counts = {}
        for y = 0, r.world.h - 1 do
            local row = r.world.fg[y]
            for x = 0, r.world.w - 1 do
                local id = row and row[x]
                local item = id and r.items[id]
                if item and item.kind == "seed" then counts[id] = (counts[id] or 0) + 1 end
            end
        end
        local best, most = nil, 0
        for id, n in pairs(counts) do if n > most or (n == most and id < best) then best, most = id, n end end
        return best, most
    end

    -- Masuk world, deteksi tanaman + blok hasilnya + Display Box untuk menyimpan (blok & seed).
    -- Dipakai Harvest dan Rotation. Return: { r, seedId, blockId, box, boxProblem } atau nil + alasan.
    -- needBox = false: world tetap dikerjakan walau tidak ada box yang cocok (box = nil).
    function Harvest.setupWorld(name, token, label, save, needBox)
        local r = Bridge.runtime()
        if r.world.name ~= name or Bridge.pickerOpen(r) then
            G.setStatus(label .. ": masuk " .. name .. "...")
            Movement.enterWorld(name, token, { label = label, resumeButton = label, save = save })
        end
        r = worldCheck(name, token)
        G.setStatus(label .. ": scan " .. name .. "...")
        local seedId, trees = Harvest.detectCrop(r)
        if not seedId then return nil, "tidak ada pohon" end
        local blockId = Core.blockForSeed(r.items, seedId)
        local found, box = pcall(Storage.findBox, { blockId, seedId })
        local boxProblem
        if not found then
            boxProblem = tostring(box):gsub("^.-:%d+: ", "")
            if needBox ~= false then return nil, boxProblem end
            box = nil
        end
        pcall(Scan.run) -- laporan scan lengkap ikut ke diagnostics
        return { r = r, seedId = seedId, blockId = blockId, box = box, boxProblem = boxProblem, trees = trees }
    end

    Harvest.store, Harvest.replant, Harvest.harvestTree, Harvest.duration = store, replant, harvestTree, duration

    ---------------------------------------------------------------- panen cepat (ping tinggi)
    -- Pohon berurutan di baris yang sama dipanen SAMBIL JALAN: karakter berjalan ke pohon terakhir
    -- grup tanpa berhenti di tiap pohon; tiap pohon dipukul saat karakter sudah 1 tile darinya
    -- (tanpa menunggu jawaban server). Di ujung grup: tunggu jawaban server, pohon yang masih ada
    -- dipanen cara biasa (dikonfirmasi), lalu sisa drop dipungut. Drop yang dilewati terambil oleh
    -- pickup bawaan game. onTree(point) dipanggil untuk tiap pohon yang terpanen.
    -- Return: jumlah pohon terpanen.
    local HIT_RANGE = 1.1
    function Harvest.harvestPass(r, points, seedId, resolver, token, ids, onTree)
        local name, total, index = r.world.name, 0, 1
        while index <= #points do
            checkpoint(token)
            -- grup = pohon berurutan di baris yang sama, jarak antar pohon maks 3 tile
            local group = { points[index] }
            while points[index + #group] and points[index + #group].y == group[1].y
                and math.abs(points[index + #group].x - group[#group].x) <= 3
                and (#group < 2 or (points[index + #group].x - group[#group].x) * (group[#group].x - group[#group - 1].x) > 0) do
                table.insert(group, points[index + #group])
            end
            index = index + #group
            local live = {}
            for _, point in ipairs(group) do
                if tileAt(point.x, point.y) == seedId and resolver.ripe(point.x, point.y, seedId) then table.insert(live, point) end
            end
            if #live > 0 then
                local hit, sweep = {}, Drops.sweeper(name, ids, token)
                local function strike(state)
                    sweep.step(state)
                    for _, point in ipairs(live) do
                        local key = point.x .. ":" .. point.y
                        if not hit[key] and math.abs(state.y - (point.y + 1)) < 0.35
                            and math.abs(state.x - (point.x + 0.5)) <= HIT_RANGE and tileAt(point.x, point.y) == seedId then
                            r.handlers.hit(point.x, point.y)
                            hit[key] = true
                        end
                    end
                    return true
                end
                -- mulai dari ujung grup yang paling dekat karakter, lalu sapu ke ujung satunya
                local here = Bridge.position()
                if math.abs(here.x - (live[1].x + 0.5)) > math.abs(here.x - (live[#live].x + 0.5)) then
                    local reversed = {}
                    for i = #live, 1, -1 do table.insert(reversed, live[i]) end
                    live = reversed
                end
                local last = live[#live]
                Movement.moveTo(live[1].x, live[1].y, name, token, strike)
                Movement.moveTo(last.x, last.y, name, token, strike)
                strike(Bridge.position())
                -- tunggu jawaban server untuk pukulan terakhir (maks ~1,2 detik)
                for _ = 1, 24 do
                    local waiting = false
                    for _, point in ipairs(live) do
                        if hit[point.x .. ":" .. point.y] and tileAt(point.x, point.y) == seedId then waiting = true; break end
                    end
                    if not waiting then break end
                    pause(0.05, token)
                end
                for _, point in ipairs(live) do
                    local done = tileAt(point.x, point.y) ~= seedId
                    if done then
                        App.stats.trees = (App.stats.trees or 0) + 1
                    else
                        done = harvestTree(r, point, seedId, resolver, token) -- ditolak / belum kena: cara biasa
                        App.fastHarvestRetries = (App.fastHarvestRetries or 0) + 1
                    end
                    if done then
                        total = total + 1
                        if onTree then onTree(point) end
                    end
                end
                local first = live[1]
                local anchor = { world = name, x = math.floor((first.x + last.x) / 2), y = last.y }
                local area = { radius = math.abs(last.x - first.x) / 2 + 1.5, up = 1.5, down = 1.25 }
                -- drop muncul di belakang karakter (ping): sapu balik sambil pungut, tanpa berhenti
                sweep.step(Bridge.position())
                if sweep.pending(anchor, area) and first ~= last then
                    Movement.moveTo(first.x, first.y, name, token, function(state) sweep.step(state); return true end)
                    sweep.step(Bridge.position())
                end
                sweep.finish()
                if sweep.pending(anchor, area) then Drops.collectArea(anchor, ids, token, area) end
            end
        end
        return total
    end

    ---------------------------------------------------------------- panen satu world
    function Harvest.runWorld(index, token, save)
        local name = App.config.harvesting.worlds[index]
        App.harvestIndex = index
        save()
        local setup, why = Harvest.setupWorld(name, token, "Harvest", save)
        App.harvestWorlds = App.harvestWorlds or {}
        if not setup then
            App.harvestWorlds[name] = "dilewati: " .. why
            return 0
        end
        local r, seedId, blockId, box = setup.r, setup.seedId, setup.blockId, setup.box
        local replantOn = App.config.harvesting.replant
        local plan = Harvest.plan(r, seedId)
        local summary = string.format("%s, %d mateng, %d tumbuh%s, box %d,%d", r.items[seedId].name, plan.ripe, plan.growing,
            plan.growing > 0 and (" (semua mateng dalam " .. duration(plan.longest) .. ")") or "", box.x, box.y)
        App.harvestPlan = name .. ": " .. summary
        if plan.ripe == 0 then
            -- hasil panen sebelum mental/keluar world masih di tas -> tetap disimpan ke box
            if count(blockId) > 0 then store(blockId, seedId, 0, token, box) end
            App.harvestWorlds[name] = "belum ada yang mateng; " .. summary
            return 0
        end
        local ids = { blockId, seedId, Drops.GEM }
        local trees, replanted = 0, 0
        for _, entry in ipairs(plan.rows) do
            local row = entry.row
            G.setStatus(string.format("Harvest %s (%d/%d): baris %d, %d pohon mateng...", name, index,
                #App.config.harvesting.worlds, row.y, #entry.points))
            if App.config.options.fastHarvest and not replantOn then
                -- panen cepat sambil jalan, per potongan 20 pohon (cek tas penuh di antaranya)
                for start = 1, #entry.points, 20 do
                    checkpoint(token)
                    if r.inventory:room(blockId) < 70 or r.inventory:room(seedId) < 30 then store(blockId, seedId, 0, token, box) end
                    local chunk = {}
                    for i = start, math.min(#entry.points, start + 19) do table.insert(chunk, entry.points[i]) end
                    trees = trees + Harvest.harvestPass(r, chunk, seedId, plan.resolver, token, ids)
                end
                entry.points = {}
            end
            for _, point in ipairs(entry.points) do
                checkpoint(token)
                -- Tas hampir penuh: simpan dulu ke box world ini, lalu lanjut dari pohon ini.
                if r.inventory:room(blockId) < 10 or r.inventory:room(seedId) < 10 then
                    store(blockId, seedId, replantOn and math.min(count(seedId), 100) or 0, token, box)
                end
                if harvestTree(r, point, seedId, plan.resolver, token) then
                    trees = trees + 1
                    -- Pukul sambil collect: pungut hasil pohon ini dari tempat berdiri sebelum lanjut.
                    Drops.collectNear({ world = name, x = point.x, y = point.y }, ids, token, Drops.reach())
                    if replantOn and replant(r, point, seedId, token) then replanted = replanted + 1 end
                end
            end
            -- Sisa drop di baris ini (yang tidak terambil otomatis saat jalan) dipungut sekarang.
            local mid = math.floor((row.left + row.right) / 2)
            Drops.collectArea({ world = name, x = mid, y = row.y }, ids, token,
                { radius = (row.right - row.left) / 2 + 1.5, up = 1.5, down = 1.25 })
        end
        store(blockId, seedId, 0, token, box)
        App.harvestWorlds[name] = string.format("dipanen %d, ditanam ulang %d; %s", trees, replanted, summary)
        return trees
    end

    ---------------------------------------------------------------- job
    local resumePoint = G.Jobs.checkpointer("harvest", function() return { worldIndex = App.harvestIndex or 1 } end)
    Harvest.saveResume, Harvest.clearResume = resumePoint.save, resumePoint.clear

    -- Semua world di list, satu kali jalan. Per world: masuk, deteksi tanaman & Display Box,
    -- panen pohon mateng, simpan blok + seed ke box world itu.
    function Harvest.run(token, saved)
        local worlds = App.config.harvesting.worlds
        local start = saved and saved.worldIndex or 1
        if start > #worlds then start = 1 end
        local total = 0
        for index = start, #worlds do
            checkpoint(token)
            total = total + Harvest.runWorld(index, token, resumePoint.save)
        end
        local parts = {}
        for _, name in ipairs(worlds) do table.insert(parts, name .. ": " .. tostring(App.harvestWorlds[name] or "-")) end
        App.harvestPlan = table.concat(parts, " | ")
        G.setStatus(string.format("Selesai: %d pohon dipanen di %d world.", total, #worlds))
    end

    G.Jobs.register("harvest", {
        label = "Harvest",
        save = function() Harvest.saveResume() end,
        prepare = function(r)
            assert(r.body and r.controls and r.handlers and type(r.handlers.hit) == "function",
                "Hook pukul/gerak tidak tersedia. Copy diagnostics dari Settings.")
        end,
        -- Keluar world / avatar mati + setting Rejoin nyala: masuk lagi ke world yang sedang dipanen,
        -- scan ulang, lanjut (pohon yang sudah dipanen tidak terhitung lagi). Gagal 3x tanpa kemajuan = berhenti.
        run = function(token, saved)
            if App.config.options.autoRejoin then Movement.queueResume() end
            G.Jobs.resilient(token, saved, {
                label = "Harvest",
                world = function() return App.config.harvesting.worlds[App.harvestIndex or 1] end,
                progress = function() return App.stats.trees or 0 end,
                loop = Harvest.run,
                onRetry = function() return { worldIndex = App.harvestIndex or 1 } end,
            })
            Harvest.clearResume()
        end,
        clear = function() Harvest.clearResume() end,
        resume = true,
        validResume = function(data) return type(data.worldIndex) == "number" end,
        resumeWorld = function(data, config) return config.harvesting.worlds[data.worldIndex or 1] end,
    })

    ---------------------------------------------------------------- tab Harvest
    function Harvest.buildTab(tab)
        local UI, State = G.UI, G.State
        local controls, syncing = {}, true
        UI.addStatus(tab:Paragraph({ Title = "Status", Desc = App.status }))
        local function setOption(fn)
            if syncing then return end
            local ok, message = pcall(function() Net.idle(); fn(); State.saveSession() end)
            if not ok then G.notify(tostring(message)) end
        end
        function Harvest.refreshTab()
            local lines = {}
            for i, name in ipairs(App.config.harvesting.worlds) do
                table.insert(lines, i .. ". " .. name .. (App.harvestWorlds and App.harvestWorlds[name] and (": " .. App.harvestWorlds[name]) or ""))
            end
            UI.paragraph(controls.list, "World harvest", #lines > 0 and table.concat(lines, "\n") or "Belum ada world.")
        end
        tab:Paragraph({ Title = "Cara kerja", Desc = "Per world di list: masuk, scan otomatis (tanaman = seed yang paling banyak ditanam), panen pohon yang sudah mateng, simpan blok + seed ke Display Box di world itu (dicari otomatis: box kosong atau berisi blok/seed tanaman itu)." })
        tab:Input({ Title = "World harvest (urut)", Value = table.concat(App.config.harvesting.worlds, ", "),
            Placeholder = "FARM1, FARM2", Desc = "Pisahkan dengan koma.",
            Callback = function(value)
                setOption(function() App.config.harvesting.worlds = Core.parseWorlds(value or "") end)
                Harvest.refreshTab()
            end })
        tab:Toggle({ Title = "Replant during harvest", Value = App.config.harvesting.replant,
            Desc = "Tile yang baru dipanen langsung ditanam lagi pakai seed di tas (termasuk seed hasil panen).",
            Callback = function(value) setOption(function() App.config.harvesting.replant = value == true end) end })
        controls.list = tab:Paragraph({ Title = "World harvest", Desc = "Belum ada world." })
        G.Jobs.toggles.harvest = tab:Toggle({ Title = "Harvest", Value = false,
            Desc = "Panen semua world di list satu kali jalan.",
            Callback = function(enabled) G.Jobs.setRunning("harvest", enabled) end })
        Scan.buildGrowscan(tab)
        syncing = false
        Harvest.refreshTab()
        table.insert(G.onConnected, function() pcall(Harvest.refreshTab) end)
    end

    return Harvest
end

end)()

-- ===== src/rotation.lua =====
__modules["rotation"] = (function(...)
-- rotation.lua: Rotation khusus Hansel (bukan Full Rotation Clarissv). Per world di list rotasi:
--   1) masuk world, scan pohon;
--   2) HARVEST pohon mateng (zigzag dari atas) sampai blok di tas mencapai target (bawaan 180);
--   3) PNB di tempat berhenti: 1 tile kosong di samping (kanan dulu, lalu kiri), sampai blok habis;
--   4) REPLANT tile yang tadi dipanen (+ tile PNB), lalu kembali ke 2 sampai tidak ada pohon mateng;
--   5) simpan seed sisa (HANYA seed, blok tidak pernah disimpan) ke Display Box world itu, lalu world berikutnya.
-- Replant (v0.5.2): 1) lubang di baris di ATAS posisi sekarang, 2) tile yang barusan dipanen + tile PNB,
--   3) tile kosong lain di farm yang bisa ditanam. Supaya farm tidak bolong-bolong.
-- Resume (v0.5.2): checkpoint selalu disimpan (world ke berapa); error di tengah jalan diulang dari
--   world itu (maks 5x tanpa kemajuan), dan tombol "Resume rotation" melanjutkan setelah berhenti.
-- Setelah world terakhir balik ke world pertama. Kalau satu putaran tidak ada yang dipanen, tunggu
-- sampai pohon tercepat mateng (maks 10 menit per tunggu), lalu putar lagi.
-- Memakai helper Harvest (harvestTree, replant, store) dan PNB (placeTile, breakTile).
return function(G)
    local App, Core, Bridge, Net, Actions, Movement, Drops, State, Harvest, Pnb =
        G.App, G.Core, G.Bridge, G.Net, G.Actions, G.Movement, G.Drops, G.State, G.Harvest, G.Pnb
    local Rotation = {}
    local worldCheck, position, checkpoint, pause = Bridge.worldCheck, Bridge.position, Net.checkpoint, Net.pause
    local count, tileAt, refreshInventory = Actions.count, Actions.tileAt, Actions.refreshInventory

    ---------------------------------------------------------------- checkpoint / resume
    -- Checkpoint rotasi = world ke berapa + STATE world itu (rencana panen yang dikunci, posisi
    -- di rencana, tahap harvest/pnb/replant, tile bekas panen, spot & tile PNB). Setelah mental /
    -- dimuat ulang, rotasi lanjut dari tahap terakhir, bukan mulai dari awal.
    local resumePoint = G.Jobs.checkpointer("rotation", function()
        return { worldIndex = App.rotationIndex or 1, state = App.rotationState }
    end)
    Rotation.saveResume, Rotation.clearResume = resumePoint.save, resumePoint.clear
    local refreshResume = resumePoint.refresh

    -- Pencatat waktu per tahap (diagnostics "Waktu rotasi"): total detik + jumlah unit per tahap.
    App.phaseTime = App.phaseTime or {}
    local function timed(phase, units, fn, ...)
        local started = os.clock()
        local results = table.pack(pcall(fn, ...))
        local entry = App.phaseTime[phase] or { seconds = 0, units = 0 }
        entry.seconds = entry.seconds + (os.clock() - started)
        local n = type(units) == "function" and units(table.unpack(results, 2, results.n)) or units or 0
        entry.units = entry.units + (tonumber(n) or 0)
        App.phaseTime[phase] = entry
        if not results[1] then error(results[2], 0) end
        return table.unpack(results, 2, results.n)
    end
    Rotation.timed = timed

    local function info(text)
        App.rotationInfo = text
        G.setStatus(text)
    end
    -- Jalankan satu langkah kecil (1 pukul / 1 place-break). Error sesaat (timeout request, tile
    -- berubah saat settle, pukul gagal) tidak menghentikan world: dicatat, tunggu 0,5 detik, lanjut.
    -- Stop, keluar world, dan avatar mati tetap dilempar ke atas. Return: true kalau sukses.
    local function soft(token, worldName, fn, ...)
        local ok, problem = pcall(fn, ...)
        if ok then return true end
        if type(problem) == "table" or tostring(problem):find("Stopped", 1, true) then error(problem, 0) end
        problem = Movement.classifyFault(problem, token, worldName)
        if type(problem) == "table" then error(problem, 0) end
        App.rotationLastError = os.date("%H:%M:%S") .. " " .. tostring(problem)
        App.rotationSoftErrors = (App.rotationSoftErrors or 0) + 1
        pause(0.5, token)
        Movement.takeControls()
        return false
    end
    Rotation.soft = soft

    local function standing()
        local state = position()
        return { world = Bridge.runtime().world.name, x = math.floor(state.x), y = math.floor(state.y - 0.01) }
    end

    -- Simpan HANYA seed ke box world ini (blok tetap di tas untuk PNB). keep = seed yang disisakan.
    function Rotation.storeSeeds(blockId, seedId, keep, token, box)
        if not box then return end -- world ini tanpa Display Box yang cocok: seed tetap di tas
        refreshInventory(token)
        local amount = count(seedId) - (keep or 0)
        if amount > 0 then
            local used = Movement.respawnNear(box, token) -- box dekat pintu putih: respawn, bukan jalan
            if used then refreshInventory(token); amount = count(seedId) - (keep or 0) end
            info(string.format("Menyimpan %d seed ke Display Box %s tile %d, %d...", amount, box.world, box.x, box.y))
            G.Storage.deposit(box, seedId, amount, token, nil, blockId)
        end
    end
    -- PNB di tempat berhenti panen: 1 tile kosong di samping (kanan dulu, lalu kiri). Kalau di situ
    -- tidak ada, coba berdiri di tile bekas panen lain (`spots`) yang punya samping kosong.
    -- Return: tile PNB (ikut di-replant), atau nil kalau tidak ketemu (blok tetap di tas).
    local function sideOf(r, blockId, here)
        for _, dx in ipairs({ 1, -1 }) do
            local x = here.x + dx
            if x >= 0 and x < r.world.w and tileAt(x, here.y) == 0 and r.handlers.canPlace(r.items[blockId], x, here.y) then
                return { x = x, y = here.y }
            end
        end
    end
    -- Seed hampir penuh saat PNB/harvest: REPLANT dulu (pakai seed, tanpa jalan jauh ke box),
    -- baru simpan ke box kalau masih penuh. Lalu balik ke `back`.
    -- Seed di tas >= batas (Rotation: 190-200): simpan sejumlah seed ke Display Box world ini
    -- (respawn dulu kalau box dekat pintu putih), lalu balik ke `back`. Tanpa box: replant dulu.
    local function seedOverflow(r, box, blockId, seedId, token, pending, back)
        local cfg = App.config.rotation
        if count(seedId) < cfg.seedLimit and r.inventory:room(seedId) >= 5 then return end
        if box then
            local amount = math.min(count(seedId), cfg.seedStore)
            info(string.format("Seed di tas %d (batas %d): simpan %d ke Display Box...", count(seedId), cfg.seedLimit, amount))
            Rotation.storeSeeds(blockId, seedId, count(seedId) - amount, token, box)
        else
            info("Seed penuh dan tidak ada Display Box: replant dulu...")
            local order = Rotation.replantOrder(r, pending or {}, back and back.y, blockId)
            if #order > 0 then Rotation.replantTiles(r, order, seedId, token, blockId) end
        end
        if back then Movement.moveTo(back.x, back.y, back.world or r.world.name, token) end
    end

    function Rotation.pnbHere(r, box, blockId, seedId, token, spots, pending)
        local here = standing()
        local side = sideOf(r, blockId, here)
        for index = #(spots or {}), 1, -1 do
            if side then break end
            local spot = spots[index]
            if tileAt(spot.x, spot.y) == 0 then
                local candidate = sideOf(r, blockId, spot)
                if candidate then
                    Movement.moveTo(spot.x, spot.y, r.world.name, token)
                    here, side = standing(), sideOf(r, blockId, standing())
                end
            end
        end
        if not side then
            info("Tidak ada tile kosong di samping untuk PNB; blok tetap di tas, lanjut.")
            return nil
        end
        local ids = { blockId, seedId, Drops.GEM }
        info(string.format("PNB di %d,%d (tile %s): %d blok...", here.x, here.y, side.x > here.x and "kanan" or "kiri", count(blockId)))
        local stuck, last = 0, count(blockId)
        local planned = {}
        for _, point in ipairs(pending or {}) do table.insert(planned, point) end
        table.insert(planned, side)
        while count(blockId) > 0 do
            checkpoint(token)
            refreshResume()
            seedOverflow(r, box, blockId, seedId, token, planned, here)
            soft(token, r.world.name, function()
                Pnb.placeTile(here, side, blockId, token)  -- (placeTile/breakTile cek isi tile sendiri)
            end)
            if tileAt(side.x, side.y) == blockId then
                soft(token, r.world.name, function() Pnb.breakTile(here, side, blockId, token) end)
            end
            soft(token, r.world.name, function()
                local reach = Drops.reach()
                Drops.collectNear(here, ids, token, { radius = reach.radius, up = reach.up, down = reach.down, onlyIfPresent = true })
            end)
            local inside = tileAt(side.x, side.y)
            assert(inside == 0 or inside == blockId or inside == seedId,
                "Tile PNB rotasi terisi item lain di " .. side.x .. ", " .. side.y .. ".")
            if inside == seedId then break end -- tile PNB sudah ditanam saat replant karena seed penuh
            -- jaga-jaga: 8 putaran tanpa blok berkurang = jangan muter selamanya
            if count(blockId) < last then stuck, last = 0, count(blockId) else stuck = stuck + 1 end
            if stuck >= 8 then
                App.rotationLastError = "PNB tidak maju di " .. side.x .. ", " .. side.y .. " (place/break ditolak); lanjut replant."
                break
            end
        end
        -- drop dari blok terakhir: tunggu & pungut normal sebelum pindah tahap
        soft(token, r.world.name, function() Drops.collectNear(here, ids, token, Drops.reach()) end)
        return side
    end

    -- Urutan replant: 1) lubang di baris DI ATAS posisi sekarang, 2) tile bekas panen + tile PNB,
    -- 3) tile kosong lain di farm yang bisa ditanam (zigzag). Tile berisi blok sisa PNB yang belum
    -- dipecah (blockId) ikut: dipecah dulu lalu ditanam. Tanpa duplikat.
    local function supported(r, x, y)
        if x < 0 or x >= r.world.w or y < 0 or y >= r.world.h - 1 then return false end
        local below = r.items[r.world.fg[y + 1] and r.world.fg[y + 1][x] or 0]
        return below ~= nil and (below.solid == true or below.platform == true)
    end
    local function plantable(r, x, y, blockId)
        if Core.plantingTile(r.world, r.items, x, y) then return true end
        return blockId ~= nil and r.world.fg[y] and r.world.fg[y][x] == blockId and supported(r, x, y) or false
    end
    function Rotation.replantOrder(r, pending, currentY, blockId)
        local rows = Core.farmRows(r.world, r.items)
        local all = {}
        for index, row in ipairs(rows) do
            local direction = index % 2 == 1 and 1 or -1
            local first, last = direction == 1 and row.left or row.right, direction == 1 and row.right or row.left
            for x = first, last, direction do
                if plantable(r, x, row.y, blockId) then table.insert(all, { x = x, y = row.y }) end
            end
        end
        local list, seen = {}, {}
        local function add(point)
            local key = point.x .. ":" .. point.y
            if not seen[key] and plantable(r, point.x, point.y, blockId) then
                seen[key] = true
                table.insert(list, { x = point.x, y = point.y })
            end
        end
        for _, point in ipairs(all) do if currentY and point.y < currentY then add(point) end end
        for _, point in ipairs(pending) do add(point) end
        for _, point in ipairs(all) do add(point) end
        return list
    end

    -- Pecah blok sisa di tile tanam: berdiri di samping (kiri/kanan, sebaris), pukul, pungut.
    function Rotation.clearBlock(r, point, blockId, token, seedId)
        local stand
        for _, dx in ipairs({ -1, 1 }) do
            local x = point.x + dx
            if x >= 0 and x < r.world.w and supported(r, x, point.y) then
                local item = r.items[r.world.fg[point.y][x] or 0]
                if not item or not item.solid then stand = { x = x, y = point.y }; break end
            end
        end
        assert(stand, "Tidak ada tempat berdiri untuk memecah blok sisa di " .. point.x .. ", " .. point.y .. ".")
        Movement.moveTo(stand.x, stand.y, r.world.name, token)
        local here = standing()
        Pnb.breakTile(here, point, blockId, token)
        Drops.collectNear(here, { blockId, seedId or blockId, Drops.GEM }, token, Drops.reach())
        App.rotationCleared = (App.rotationCleared or 0) + 1
    end

    -- Tanam ulang tile kosong di daftar (urut). Seed habis = berhenti; sisanya dicoba putaran berikutnya.
    function Rotation.replantTiles(r, tiles, seedId, token, blockId)
        local planted, left = 0, {}
        for index, point in ipairs(tiles) do
            checkpoint(token)
            if blockId and tileAt(point.x, point.y) == blockId and count(seedId) > 0 then
                soft(token, r.world.name, Rotation.clearBlock, r, point, blockId, token, seedId)
            end
            if tileAt(point.x, point.y) == 0 then
                if count(seedId) <= 0 then
                    for i = index, #tiles do if tileAt(tiles[i].x, tiles[i].y) == 0 then table.insert(left, tiles[i]) end end
                    break
                end
                Movement.moveTo(point.x, point.y, r.world.name, token)
                if Harvest.replant(r, point, seedId, token) then planted = planted + 1
                elseif tileAt(point.x, point.y) == 0 then table.insert(left, point) end
            end
        end
        return planted, left
    end

    -- Satu world. State world disimpan di App.rotationState (ikut checkpoint), jadi setelah mental
    -- rotasi lanjut dari tahap terakhir:
    --   plan    = daftar pohon mateng hasil scan AWAL (dikunci; pohon yang mateng belakangan
    --             menunggu kunjungan berikutnya), cursor = pohon berikutnya di daftar itu
    --   phase   = "harvest" | "pnb" | "replant"
    --   pending = tile bekas panen putaran ini (+ tile PNB), spot/side = posisi & tile PNB
    -- Return: jumlah pohon dipanen kunjungan ini, detik sampai pohon tercepat berikutnya mateng.
    local function newState(name, plan)
        local list = {}
        for _, entry in ipairs(plan.rows) do
            for _, point in ipairs(entry.points) do table.insert(list, { point.x, point.y }) end
        end
        return { world = name, plan = list, cursor = 1, phase = "harvest", pending = {}, extra = 0,
            stats = { harvested = 0, pnb = 0, replanted = 0 } }
    end
    local function point(pair) return { x = pair[1], y = pair[2] } end

    function Rotation.runWorld(index, token, saved)
        local cfg = App.config.rotation
        local name, target = cfg.worlds[index], cfg.blockTarget
        App.rotationIndex = index
        -- State world ini: dari memori (diulang setelah error) atau checkpoint (script dimuat ulang).
        local state = App.rotationState
        if not (state and state.world == name) then
            state = saved and type(saved.state) == "table" and saved.state.world == name and saved.state or nil
        end
        App.rotationState = state
        Rotation.saveResume()
        -- Masuk + scan otomatis: tanaman = seed terbanyak di world, Display Box dicari otomatis.
        local setup, why = timed("masuk & scan world", 1, Harvest.setupWorld, name, token,
            string.format("Rotasi %d/%d", index, #cfg.worlds), Rotation.saveResume, false)
        App.rotationWorlds = App.rotationWorlds or {}
        if not setup then
            App.rotationWorlds[name] = "dilewati: " .. why
            App.rotationState = nil
            info("Rotasi: " .. name .. " dilewati (" .. why .. ").")
            return 0, nil, true
        end
        local r, seedId, blockId, box = setup.r, setup.seedId, setup.blockId, setup.box
        App.rotationBoxNote = setup.boxProblem and (name .. ": tanpa Display Box (" .. setup.boxProblem .. "); seed tetap di tas") or nil
        local ids = { blockId, seedId, Drops.GEM }
        local plan = Harvest.plan(r, seedId)
        if not state then
            state = newState(name, plan) -- KUNCI hasil scan awal
            App.rotationState = state
        else
            info(string.format("Rotasi %s: lanjut dari tahap %s (pohon %d/%d).", name, state.phase, state.cursor, #state.plan))
        end
        local stats = state.stats
        local function progress(phase)
            info(string.format("Rotasi %s (%d/%d) - %s | pohon %d/%d | dipanen %d, PNB %d blok, ditanam ulang %d",
                name, index, #cfg.worlds, phase, math.min(state.cursor, #state.plan), #state.plan,
                stats.harvested, stats.pnb, stats.replanted))
        end
        local function save() pcall(Rotation.saveResume) end
        local harvestedNow = 0

        while true do
            checkpoint(token)
            pause(0.05, token) -- loop ini tidak boleh muter tanpa jeda
            refreshResume()
            refreshInventory(token)

            -- 1) HARVEST pohon dari rencana yang dikunci, sampai blok di tas = target
            if state.phase == "harvest" then
                local function full() return count(blockId) >= target and (state.extra or 0) <= 0 end
                progress("harvest")
                local started, got = os.clock(), 0
                while state.cursor <= #state.plan and not full() do
                    checkpoint(token)
                    refreshResume()
                    local tree = point(state.plan[state.cursor])
                    seedOverflow(r, box, blockId, seedId, token, nil, nil)
                    if App.config.options.fastHarvest then
                        -- panen cepat sambil jalan: ambil beberapa pohon sekaligus, secukupnya untuk
                        -- mendekati target blok (perkiraan aman 4 blok/pohon supaya tidak kelebihan)
                        local need = math.max(1, math.ceil((target - count(blockId)) / 4), state.extra or 0)
                        local chunk = {}
                        for i = state.cursor, math.min(#state.plan, state.cursor + math.min(12, need) - 1) do
                            table.insert(chunk, point(state.plan[i]))
                        end
                        local ok = soft(token, name, function()
                            Harvest.harvestPass(r, chunk, seedId, plan.resolver, token, ids, function(done)
                                table.insert(state.pending, { done.x, done.y })
                                stats.harvested, got = stats.harvested + 1, got + 1
                                harvestedNow = harvestedNow + 1
                                if count(blockId) >= target then state.extra = math.max(0, (state.extra or 0) - 1) end
                            end)
                        end)
                        state.failed = ok and 0 or (state.failed or 0) + 1
                        if ok or state.failed >= 2 then state.cursor, state.failed = state.cursor + #chunk, 0 end
                        refreshInventory(token)
                        save()
                    else
                        local done = false
                        local ok = soft(token, name, function()
                            done = Harvest.harvestTree(r, tree, seedId, plan.resolver, token)
                        end)
                        -- sukses / pohon sudah tidak ada -> lanjut; gagal 2x di pohon yang sama -> lewati
                        state.failed = ok and 0 or (state.failed or 0) + 1
                        if ok or state.failed >= 2 then state.cursor, state.failed = state.cursor + 1, 0 end
                        if ok and done then
                            soft(token, name, function()
                                Drops.collectNear({ world = name, x = tree.x, y = tree.y }, ids, token, Drops.reach())
                            end)
                            table.insert(state.pending, { tree.x, tree.y })
                            stats.harvested, got = stats.harvested + 1, got + 1
                            harvestedNow = harvestedNow + 1
                            if count(blockId) >= target then state.extra = math.max(0, (state.extra or 0) - 1) end
                            if got % 10 == 0 then save() end
                        end
                    end
                end
                if #state.pending > 0 then
                    local last = point(state.pending[#state.pending])
                    soft(token, name, function()
                        Drops.collectArea({ world = name, x = last.x, y = last.y }, ids, token, { radius = 4, up = 1.5, down = 1.25 })
                    end)
                end
                local entry = App.phaseTime.harvest or { seconds = 0, units = 0 }
                entry.seconds, entry.units = entry.seconds + (os.clock() - started), entry.units + got
                App.phaseTime.harvest = entry
                refreshInventory(token)
                if count(blockId) > 0 then
                    local here = standing()
                    state.phase, state.spot = "pnb", { here.x, here.y }
                elseif #state.pending > 0 then
                    state.phase = "replant"
                elseif state.cursor > #state.plan then
                    break -- rencana habis, tidak ada yang perlu ditanam
                end
                save()
            end

            -- 2) PNB di spot berhenti panen (disimpan), sampai blok habis
            if state.phase == "pnb" then
                local spot = state.spot and point(state.spot) or standing()
                if state.spot then
                    local here = standing()
                    if here.x ~= spot.x or here.y ~= spot.y then Movement.moveTo(spot.x, spot.y, name, token) end
                end
                local spots = {}
                for _, pair in ipairs(state.pending) do table.insert(spots, point(pair)) end
                local before = count(blockId)
                progress("PNB " .. before .. " blok")
                local pendingPoints = {}
                for _, pair in ipairs(state.pending) do table.insert(pendingPoints, point(pair)) end
                local side = timed("PNB", function() return before - count(blockId) end,
                    Rotation.pnbHere, r, box, blockId, seedId, token, spots, pendingPoints)
                if side then
                    table.insert(state.pending, { side.x, side.y })
                    stats.pnb = stats.pnb + (before - count(blockId))
                    state.extra, state.phase = 0, "replant"
                elseif state.cursor <= #state.plan then
                    state.extra, state.phase = 2, "harvest" -- tidak ada tile kosong: panen 2 pohon lagi
                else
                    info("Blok tidak bisa di-PNB (tidak ada tile kosong & rencana panen habis); blok tetap di tas.")
                    state.phase = "replant"
                end
                save()
            end

            -- 3) REPLANT: atas -> bekas panen + tile PNB -> sisa farm; blok sisa dipecah dulu
            if state.phase == "replant" then
                local pendingPoints = {}
                for _, pair in ipairs(state.pending) do table.insert(pendingPoints, point(pair)) end
                local currentY = pendingPoints[#pendingPoints] and pendingPoints[#pendingPoints].y or standing().y
                local order = Rotation.replantOrder(r, pendingPoints, currentY, blockId)
                if #order > 0 and count(seedId) > 0 then
                    progress("replant " .. #order .. " tile (atas -> bekas panen -> sisa farm)")
                    local planted = timed("replant", function(n) return n end, Rotation.replantTiles, r, order, seedId, token, blockId)
                    stats.replanted = stats.replanted + planted
                end
                state.pending, state.phase = {}, "harvest"
                save()
                if state.cursor > #state.plan then break end -- rencana dari scan awal selesai
            end
        end

        -- Kunjungan world ini selesai. Seed TIDAK disimpan di sini (cuma saat tas penuh).
        local finished = state
        App.rotationState = nil
        save()
        plan = Harvest.plan(r, seedId)
        App.rotationWorlds, App.rotationTotals = App.rotationWorlds or {}, App.rotationTotals or {}
        local sum = App.rotationTotals[name] or { harvested = 0, pnb = 0, replanted = 0 }
        for key in pairs(sum) do sum[key] = sum[key] + finished.stats[key] end
        App.rotationTotals[name] = sum
        App.rotationWorlds[name] = string.format("total dipanen %d, PNB %d blok, ditanam ulang %d | %d tile belum ditanam, %d mateng baru, %d tumbuh%s",
            sum.harvested, sum.pnb, sum.replanted, #Rotation.replantOrder(r, {}, nil, blockId), plan.ripe, plan.growing,
            plan.soonest and (", tercepat mateng " .. Harvest.duration(plan.soonest)) or "")
        return harvestedNow, (plan.ripe > 0 and 0 or plan.soonest)
    end

    function Rotation.run(token, saved)
        local cfg = App.config.rotation
        local index = saved and saved.worldIndex or 1
        if index > #cfg.worlds then index = 1 end
        while true do
            local harvested, soonest, skipped = 0, nil, {}
            for i = index, #cfg.worlds do
                local got, soon, skip = Rotation.runWorld(i, token, saved)
                saved = nil
                harvested = harvested + got
                if soon then soonest = math.min(soonest or soon, soon) end
                if skip then table.insert(skipped, cfg.worlds[i] .. ": " .. tostring(App.rotationWorlds[cfg.worlds[i]])) end
            end
            index = 1
            App.rotationLaps = (App.rotationLaps or 0) + 1
            if harvested == 0 then
                -- Satu putaran penuh tanpa panen: tunggu pohon tercepat mateng (maks 10 menit).
                local wait = math.max(5, math.min(soonest or 60, 600))
                local deadline = os.clock() + wait
                while os.clock() < deadline do
                    info((#skipped > 0 and ("Rotasi: " .. table.concat(skipped, " | ") .. ". ") or "Rotasi: belum ada pohon mateng di semua world. ")
                        .. "Cek lagi dalam " .. Harvest.duration(deadline - os.clock()) .. ".")
                    refreshResume()
                    pause(math.min(5, math.max(0.1, deadline - os.clock())), token)
                end
            end
        end
    end

    G.Jobs.register("rotation", {
        label = "Rotation",
        save = function() Rotation.saveResume() end,
        prepare = function(r)
            assert(r.body and r.controls and r.handlers and type(r.handlers.hit) == "function"
                and type(r.handlers.setTile) == "function" and type(r.handlers.plantSeed) == "function",
                "Hook pukul/place/tanam tidak tersedia. Copy diagnostics dari Settings.")
        end,
        -- Error di tengah jalan TIDAK langsung menghentikan rotasi (Jobs.resilient, anyError):
        --   keluar world / avatar mati (+ setting Rejoin) -> masuk lagi ke world itu, lanjut dari scan;
        --   error lain (jalan timeout, request box gagal, dll.) -> tunggu 3 detik, ulangi world itu dari
        --   scan. Berhenti kalau gagal 5x berturut-turut tanpa kemajuan sama sekali.
        run = function(token, saved)
            if App.config.options.autoRejoin then Movement.queueResume() end
            G.Jobs.resilient(token, saved, {
                label = "Rotation", anyError = true, maxFailures = 5, wait = 3,
                world = function() return App.config.rotation.worlds[App.rotationIndex or 1] end,
                progress = function() return (App.stats.trees or 0) + (App.stats.broken or 0) + (App.stats.replanted or 0) end,
                loop = Rotation.run,
                onRetry = function() return { worldIndex = App.rotationIndex or 1 } end,
            })
        end,
        clear = function() Rotation.clearResume() end,
        resume = true,
        validResume = function(data) return type(data.worldIndex) == "number" end,
        resumeWorld = function(data, config) return config.rotation.worlds[data.worldIndex or 1] or config.rotation.worlds[1] end,
    })
    -- Lanjut rotasi dari checkpoint (world terakhir yang dikerjakan). Dipakai tombol "Resume rotation"
    -- setelah rotasi berhenti karena error, dan otomatis setelah pindah server.
    function Rotation.resume()
        local record = State.loadCheckpoint("rotation")
        assert(record and type(record.data) == "table" and type(record.data.worldIndex) == "number",
            "Tidak ada rotasi tersimpan. Nyalakan Rotation untuk mulai dari world pertama.")
        App.config, App.profile = record.config, Core.profileName(record.profile)
        G.Jobs.start("rotation", record.data)
    end


    ---------------------------------------------------------------- tab Rotation
    function Rotation.buildTab(tab)
        local UI = G.UI
        local controls, syncing = {}, true
        UI.addStatus(tab:Paragraph({ Title = "Status", Desc = App.status }))
        tab:Paragraph({ Title = "Cara kerja", Desc = "Per world di list: masuk & scan otomatis (tanaman = seed terbanyak, Display Box dicari otomatis) -> harvest pohon mateng sampai blok di tas = target -> PNB 1 tile kosong di samping sampai blok habis -> replant (atas, bekas panen, sisa farm) -> ulangi sampai tidak ada pohon mateng -> simpan seed sisa ke box -> world berikutnya (muter)." })
        local function setOption(fn)
            if syncing then return end
            local ok, message = pcall(function() Net.idle(); fn(); State.saveSession() end)
            if not ok then G.notify(tostring(message)) end
        end
        function Rotation.refreshTab()
            local lines = {}
            for i, name in ipairs(App.config.rotation.worlds) do
                table.insert(lines, i .. ". " .. name .. (App.rotationWorlds and App.rotationWorlds[name] and (": " .. App.rotationWorlds[name]) or ""))
            end
            UI.paragraph(controls.list, "World rotasi", #lines > 0 and table.concat(lines, "\n") or "Belum ada world.")
        end
        tab:Input({ Title = "World farm rotasi (urut)", Value = table.concat(App.config.rotation.worlds, ", "),
            Placeholder = "FARM1, FARM2, FARM3", Desc = "Terpisah dari list world Planting & Harvest. Pisahkan dengan koma.",
            Callback = function(value)
                setOption(function() App.config.rotation.worlds = Core.parseWorlds(value or "") end)
                Rotation.refreshTab()
            end })
        tab:Slider({ Title = "Harvest sampai blok di tas", Step = 1,
            Value = { Min = 10, Max = 200, Default = App.config.rotation.blockTarget },
            Callback = function(value) setOption(function() App.config.rotation.blockTarget = math.floor(tonumber(value)) end) end })
        tab:Slider({ Title = "Simpan seed kalau di tas mencapai", Step = 1,
            Value = { Min = 150, Max = 200, Default = App.config.rotation.seedLimit },
            Callback = function(value) setOption(function() App.config.rotation.seedLimit = math.floor(tonumber(value)) end) end })
        tab:Slider({ Title = "Jumlah seed yang disimpan", Step = 1,
            Value = { Min = 1, Max = 200, Default = App.config.rotation.seedStore },
            Callback = function(value) setOption(function() App.config.rotation.seedStore = math.floor(tonumber(value)) end) end })
        controls.list = tab:Paragraph({ Title = "World rotasi", Desc = "Belum ada world." })
        G.Jobs.toggles.rotation = tab:Toggle({ Title = "Rotation", Value = false,
            Desc = "Jalan terus sampai di-stop. Mulai dari world pertama di list.",
            Callback = function(enabled) G.Jobs.setRunning("rotation", enabled) end })
        tab:Button({ Title = "Resume rotation", Desc = "Lanjut dari world terakhir yang dikerjakan (setelah rotasi berhenti karena error atau script dimuat ulang).",
            Callback = function()
                local ok, message = pcall(Rotation.resume)
                if not ok then G.notify(tostring(message)) end
            end })
        syncing = false
        Rotation.refreshTab()
        table.insert(G.onConnected, function() pcall(Rotation.refreshTab) end)
    end

    return Rotation
end

end)()

-- ===== src/update.lua =====
__modules["update"] = (function(...)
-- update.lua: auto update saat script jalan.
-- Tiap 10 menit baca latest.json di GitHub (ditulis build.mjs: versi + path loader permanen).
-- Ada versi baru -> loader baru di-download & di-compile dulu -> task yang jalan dijeda dengan
-- checkpoint (Jobs.suspend, checkpoint TIDAK dihapus) -> loader baru dijalankan dengan
-- AutoResume, jadi script baru menyambung dan melanjutkan task dari titik terakhir.
-- Gagal di tengah jalan -> versi lama tetap hidup dan task-nya dilanjutkan lagi.
return function(G)
    local App, task = G.App, G.task
    local Update = { INTERVAL = 600, URL_FILE = "GrowbloxHansel/loader-url.txt" }
    App.update = App.update or { info = "belum dicek" }

    -- "0.7.10" > "0.7.9"
    function Update.newer(candidate, current)
        local a, b = {}, {}
        for n in tostring(candidate):gmatch("%d+") do table.insert(a, tonumber(n)) end
        for n in tostring(current):gmatch("%d+") do table.insert(b, tonumber(n)) end
        for i = 1, math.max(#a, #b) do
            local x, y = a[i] or 0, b[i] or 0
            if x ~= y then return x > y end
        end
        return false
    end

    -- Folder repo dari URL loader yang sedang dipakai (.../main/releases/loader-xxx.lua -> .../main/).
    -- Loader yang di-pin ke commit tetap dicek ke branch main supaya patch berikutnya kelihatan.
    function Update.base()
        local url = G.env and G.env.GrowbloxHanselLoaderURL
        if type(url) ~= "string" or not url:match("^https://") then return nil end
        local root = url:match("^(https://raw%.githubusercontent%.com/[^/]+/[^/]+/)")
        if root then return root .. "main/" end
        return (url:gsub("releases/loader%-[%w]+%.lua$", ""))
    end

    -- Simpan URL loader yang sedang dipakai: dibaca kode queue_on_teleport & script auto-start,
    -- jadi setelah update, pindah server / masuk ulang memuat versi baru, bukan versi lama.
    function Update.rememberLoader(url)
        local fs = G.fs or {}
        if type(url) ~= "string" or not url:match("^https://") or type(fs.writefile) ~= "function" then return false end
        return pcall(function()
            if fs.isfolder and fs.makefolder and not fs.isfolder("GrowbloxHansel") then fs.makefolder("GrowbloxHansel") end
            fs.writefile(Update.URL_FILE, url)
        end)
    end

    function Update.check()
        local base = assert(Update.base(), "Auto update butuh script yang dimuat dari loader GitHub.")
        local text = G.httpGet(base .. "latest.json?t=" .. tostring(os.time()))
        local info = G.json.decode(text)
        assert(type(info) == "table" and type(info.version) == "string" and type(info.loader) == "string",
            "latest.json tidak valid.")
        info.url = base .. info.loader
        App.update.checked, App.update.latest = os.time(), info.version
        return info, Update.newer(info.version, G.VERSION)
    end

    -- Kapan boleh update: tidak sedang pindah world/pulih, dan task yang jalan bisa dilanjutkan.
    function Update.blocker()
        if App.configuring then return "sedang menyambung" end
        if App.teleporting or App.recovering then return "sedang masuk ulang world" end
        if App.job then
            local spec = G.Jobs.specs[App.job]
            if not (spec and spec.resume and spec.save) then return (spec and spec.label or App.job) .. " ditunggu selesai" end
        end
        return nil
    end

    function Update.apply(info)
        local blocked = Update.blocker()
        if blocked then return false, blocked end
        -- 1) download + compile dulu, sebelum menyentuh task
        local okText, source = pcall(G.httpGet, info.url)
        if not okText then return false, "download loader gagal: " .. tostring(source) end
        local chunk, problem = loadstring(source, "Growblox Hansel loader")
        if not chunk then return false, "loader rusak: " .. tostring(problem) end
        -- 2) jeda task dengan checkpoint
        local suspended, why = G.Jobs.suspend(25)
        if suspended == false then
            if not App.job then G.Jobs.resumeSaved() end
            return false, why
        end
        -- 3) jalankan versi baru (dia mematikan instance ini sendiri)
        local env, oldUrl = G.env, G.env.GrowbloxHanselLoaderURL
        G.setStatus(string.format("Update %s -> %s%s...", G.VERSION, info.version,
            suspended and (", " .. suspended .. " dilanjutkan setelahnya") or ""))
        env.GrowbloxHanselAutoResume = suspended and true or nil
        env.GrowbloxHanselUpdatedFrom = G.VERSION
        Update.rememberLoader(info.url)
        local ran, failure = pcall(chunk)
        if ran then return true end
        -- gagal: kembalikan versi lama
        env.GrowbloxHanselAutoResume, env.GrowbloxHanselUpdatedFrom = nil, nil
        env.GrowbloxHanselLoaderURL = oldUrl
        env.GrowbloxHanselLoading = nil
        Update.rememberLoader(oldUrl)
        if env.GrowbloxHanselApp ~= App then env.GrowbloxHanselApp = App end
        App.alive = true
        if suspended then G.Jobs.resumeSaved() end
        return false, "versi baru gagal dimuat: " .. tostring(failure)
    end

    -- Satu putaran: cek, kalau ada versi baru coba pasang. Return: teks hasil untuk diagnostics.
    function Update.tick(force)
        local okCheck, info, newer = pcall(Update.check)
        if not okCheck then App.update.info = "cek gagal: " .. tostring(info); return App.update.info end
        if not newer then App.update.info = "sudah terbaru (" .. G.VERSION .. ")"; return App.update.info end
        if not force and not App.config.options.autoUpdate then
            App.update.info = "versi baru " .. info.version .. " tersedia (auto update mati)"
            return App.update.info
        end
        local done, why = Update.apply(info)
        if done then return "update ke " .. info.version end
        App.update.info = "versi baru " .. info.version .. " ditunda: " .. tostring(why)
        return App.update.info
    end

    function Update.install()
        Update.rememberLoader(G.env and G.env.GrowbloxHanselLoaderURL)
        if not Update.base() then App.update.info = "mati (bukan loader GitHub)"; return false end
        task.spawn(function()
            task.wait(90)
            while App.alive do
                local wait = Update.INTERVAL
                if App.config.options.autoUpdate then
                    Update.tick(false)
                    -- versi baru ada tapi ditunda (misal Planting jalan): coba lagi lebih cepat
                    if App.alive and App.update.latest and Update.newer(App.update.latest, G.VERSION) then wait = 30 end
                end
                local untilAt = os.clock() + wait
                while App.alive and os.clock() < untilAt do task.wait(1) end
            end
        end)
        return true
    end

    return Update
end

end)()

-- ===== src/main.lua =====
__modules["main"] = (function(...)
-- main.lua: titik masuk. Kumpulkan alat dari executor/Roblox, rangkai semua modul, connect ke game.
-- Urutan: bersihkan sesi lama -> App -> modul -> UI -> connect (dengan retry) -> loop heartbeat.
return function(modules, VERSION)
    local HttpService = game:GetService("HttpService")
    local Players = game:GetService("Players")
    local ReplicatedStorage = game:GetService("ReplicatedStorage")
    local UserInputService = game:GetService("UserInputService")
    local Workspace = game:GetService("Workspace")
    local player = Players.LocalPlayer
    local env = getgenv and getgenv() or _G
    local ACCOUNT_ID = player.UserId
    assert(type(ACCOUNT_ID) == "number" and ACCOUNT_ID > 0, "Akun Roblox belum siap. Jalankan lagi setelah login.")

    -- 1) Script dijalankan ulang? Matikan instance lama dulu biar nggak ada dua yang jalan.
    local previous = env.GrowbloxHanselApp
    if previous then
        previous.alive = false
        previous.token = (previous.token or 0) + 1
        -- Kembalikan kontrol karakter yang mungkin masih dipegang instance lama.
        local hold = previous.controls
        if hold then
            if hold.table.dir == hold.dirOverride then hold.table.dir = hold.dir end
            if hold.table.jumping == hold.jumpOverride then hold.table.jumping = hold.jumping end
            if hold.world.displayTake == hold.displayOverride then hold.world.displayTake = hold.displayTake end
            if hold.world.takeDrop == hold.takeOverride then hold.world.takeDrop = hold.takeDrop end
            previous.controls = nil
        end
        if previous.window then pcall(function() previous.window:Destroy() end) end
        if previous.idleConnection then pcall(function() previous.idleConnection:Disconnect() end) end
        if previous.reconnectConnection then pcall(function() previous.reconnectConnection:Disconnect() end) end
    end

    -- 2) App = seluruh state yang hidup selama script jalan.
    local App = {
        alive = true, job = nil, jobToken = nil, token = 0, pending = 0, configuring = false,
        status = "Menyambung ke Growblox...", logs = {}, runtime = nil, connectionError = nil,
        discoveryReport = {}, startupStage = "Memuat", profile = "Default",
        stats = { gems = 0, broken = 0, planted = 0, harvested = 0 },
    }
    env.GrowbloxHanselApp = App

    -- 3) G = "kotak alat" yang dibagikan ke semua modul. Semua akses ke executor/Roblox lewat sini,
    -- jadi di tes kita tinggal ganti isi G dengan versi palsu (mock).
    local G = { App = App, VERSION = VERSION, task = task, UDim2 = UDim2, accountId = ACCOUNT_ID }
    G.exec = {
        getgc = getgc, getupvalues = getupvalues or (debug and debug.getupvalues),
        getupvalue = getupvalue or (debug and debug.getupvalue),
        debugInfo = debug and debug.info, getinfo = getinfo or (debug and debug.getinfo),
        getrawmetatable = getrawmetatable, setclipboard = setclipboard or toclipboard,
        getconnections = getconnections or get_signal_cons, firesignal = firesignal,
        sharedTables = { { label = "executor shared", value = shared }, { label = "executor globals", value = env.shared } },
    }
    if type(getrenv) == "function" then
        local ok, gameEnv = pcall(getrenv)
        if ok and type(gameEnv) == "table" then
            table.insert(G.exec.sharedTables, { label = "game runtime shared", value = gameEnv.shared })
        end
    end
    G.fs = { isfile = isfile, readfile = readfile, writefile = writefile, isfolder = isfolder,
        makefolder = makefolder, delfile = delfile }
    G.json = { encode = function(v) return HttpService:JSONEncode(v) end,
        decode = function(s) return HttpService:JSONDecode(s) end }
    G.registryKey = function() return ReplicatedStorage:GetAttribute("Qz") end
    G.serverTime = function() return Workspace:GetServerTimeNow() end
    G.isInstance = function(v) return type(typeof) == "function" and typeof(v) == "Instance" end
    G.frozen = function() return player:GetAttribute("Frozen") == true end
    G.accountOk = function() return player.UserId == ACCOUNT_ID end
    G.focusedTextBox = function() return UserInputService:GetFocusedTextBox() end
    G.env = env
    G.queueOnTeleport = queue_on_teleport or queueonteleport or (syn and syn.queue_on_teleport)
    G.newInstance, G.Color3 = Instance and Instance.new, Color3
    G.guiParent = function()
        if type(gethui) == "function" then return gethui() end
        return game:GetService("CoreGui")
    end

    local WindUI
    function G.setStatus(text)
        App.status = text
        print("[Growblox Hansel] " .. text)
        table.insert(App.logs, 1, os.date("%H:%M:%S") .. "  " .. text)
        if #App.logs > 30 then table.remove(App.logs) end
    end
    function G.notify(text)
        if WindUI then pcall(function() WindUI:Notify({ Title = "Growblox Hansel", Content = text, Duration = 6 }) end) end
    end

    -- 4) Rangkai modul. Urutannya mengikuti siapa butuh siapa.
    G.resumeHandlers = {} -- fitur yang bisa di-resume mendaftar di sini
    G.onConnected = {}    -- dipanggil setiap kali berhasil tersambung (misal isi ulang pilihan seed)
    G.Core = modules.core
    G.Navigation = modules.navigation
    G.Net = modules.net(G)
    G.State = modules.state(G)
    G.Bridge = modules.bridge(G)
    G.Actions = modules.actions(G)
    G.Movement = modules.movement(G)
    G.Storage = modules.storage(G)
    G.Drops = modules.drops(G)
    G.Jobs = modules.jobs(G)
    G.Scan = modules.scan(G)
    G.UI = modules.ui(G)
    G.Plant = modules.plant(G)
    G.Pnb = modules.pnb(G)
    G.Harvest = modules.harvest(G)
    G.Rotation = modules.rotation(G)
    G.httpGet = G.httpGet or function(url) return game:HttpGet(url) end
    G.Update = modules.update(G)
    App.config = G.Core.defaults()

    -- resuming = true: script dimuat ulang untuk melanjutkan task (setelah mental / pindah server).
    -- Tunggu game lebih lama (sampai ~2 menit) dan boleh tersambung dari world picker, karena
    -- task-nya sendiri yang akan masuk lagi ke world tujuan.
    function G.connect(resuming)
        G.setStatus("Menyambung ke game...")
        local r = G.Bridge.connect({ attempts = resuming and 30 or 8, delay = 4, allowPicker = true,
            onRetry = function(attempt, total, message)
                G.setStatus("World belum siap (" .. message .. "). Coba lagi " .. attempt .. "/" .. (total - 1) .. "...")
            end })
        local where = r.connectedInPicker and "world picker" or tostring(r.world.name)
        G.setStatus(r.ready and ("Tersambung ke " .. where .. ".")
            or ("Tersambung ke " .. where .. ", tapi ada hook yang hilang. Cek diagnostics."))
        for _, handler in ipairs(G.onConnected) do pcall(handler, r) end
        return r
    end

    -- Masuk world lewat UI world picker: isi kotak "World Name", lalu tekan Enter / "Enter World".
    -- Cara menekan dicoba berurutan sesuai dukungan executor. Return: cara yang dipakai.
    function G.enterFromPicker(name)
        local gui = assert(player:FindFirstChildOfClass("PlayerGui"), "PlayerGui tidak ada.")
        local box, button
        for _, object in ipairs(gui:GetDescendants()) do
            if not box and object.Name == "WorldName" then
                box = object:IsA("TextBox") and object or object:FindFirstChildWhichIsA("TextBox", true)
                    or (object.Parent and object.Parent:FindFirstChildWhichIsA("TextBox", true))
            end
            if not button and object:IsA("GuiButton") then
                local text = (object:IsA("TextButton") and object.Text or "") .. " " .. object.Name
                for _, child in ipairs(object:GetDescendants()) do
                    if child:IsA("TextLabel") then text = text .. " " .. child.Text end
                end
                if text:lower():find("enter world", 1, true) or text:lower():find("enterworld", 1, true) then button = object end
            end
        end
        assert(box, "Kotak World Name di world picker tidak ketemu.")
        box.Text = name
        local X = G.exec
        if type(X.getconnections) == "function" then
            local fired = 0
            for _, connection in ipairs(X.getconnections(box.FocusLost)) do
                local ok = pcall(function()
                    if connection.Fire then connection:Fire(true) else connection.Function(true) end
                end)
                if ok then fired = fired + 1 end
            end
            if fired > 0 then return "Enter di kotak World Name" end
            if button then
                for _, signal in ipairs({ button.Activated, button.MouseButton1Click }) do
                    for _, connection in ipairs(X.getconnections(signal)) do
                        local ok = pcall(function()
                            if connection.Fire then connection:Fire() else connection.Function() end
                        end)
                        if ok then fired = fired + 1 end
                    end
                    if fired > 0 then return "tombol Enter World (koneksi)" end
                end
            end
        end
        if button and type(X.firesignal) == "function" then
            if pcall(X.firesignal, button.MouseButton1Click) then return "tombol Enter World (firesignal)" end
        end
        assert(button, "Tombol Enter World tidak ketemu.")
        local input = game:GetService("VirtualInputManager")
        local inset = game:GetService("GuiService"):GetGuiInset()
        local center = button.AbsolutePosition + button.AbsoluteSize / 2 + inset
        input:SendMouseButtonEvent(center.X, center.Y, 0, true, game, 0)
        task.wait(0.05)
        input:SendMouseButtonEvent(center.X, center.Y, 0, false, game, 0)
        return "klik virtual Enter World"
    end

    function G.diagnostics()
        local lines = {
            "Growblox Hansel " .. VERSION,
            "World: " .. (App.runtime and App.runtime.world.name or "belum tersambung"),
            "Profil: " .. App.profile .. " | Akun: " .. ACCOUNT_ID,
            "Status: " .. App.status,
            "Connect error: " .. (App.connectionError or "tidak ada"),
            "Percobaan connect: " .. tostring(App.connectAttempts or "-"),
            "Tahap startup: " .. App.startupStage .. (App.pickerEntry and (" | masuk lewat picker: " .. App.pickerEntry) or ""),
            "Loader: " .. tostring(env.GrowbloxHanselLoaderDebug or "lokal / tidak diketahui"),
            "Job: " .. tostring(App.job or "idle") .. " | Request pending: " .. App.pending,
            "Navigasi: " .. tostring(App.navigationDebug or "-"),
            "Auto reconnect: " .. (App.config.options.autoReconnect and "on" or "off") .. "; " .. tostring(App.reconnectInfo or "-"),
            "Auto update: " .. (App.config.options.autoUpdate and "on" or "off") .. "; " .. tostring(App.update and App.update.info),
            "Panen cepat: " .. (App.config.options.fastHarvest and "on" or "off") .. "; diulang cara biasa " .. tostring(App.fastHarvestRetries or 0) .. " pohon",
            "Respawn ke box: " .. (App.config.options.respawnStore and "on" or "off") .. "; dipakai " .. tostring(App.respawnCount or 0)
                .. "x; terakhir " .. tostring(App.respawnInfo or "-"),
            "Anti-AFK: " .. (App.config.options.antiAFK and "on" or "off") .. "; "
                .. (App.antiAFKError or (App.idleConnection and "siap" or "belum terpasang"))
                .. (App.lastIdleInput and string.format("; input terakhir %.0f detik lalu", os.clock() - App.lastIdleInput) or ""),
            (function()
                local function counts(map)
                    local parts = {}
                    for _, key in ipairs({ "Place & Break", "Harvest", "Rotation" }) do
                        if map[key] then table.insert(parts, key .. " " .. map[key] .. "x") end
                    end
                    return #parts > 0 and table.concat(parts, ", ") or "0"
                end
                local errors = {}
                for name, issue in pairs(App.resumeErrors or {}) do table.insert(errors, name .. ": " .. issue) end
                return "Rejoin: " .. (App.config.options.autoRejoin and "on" or "off") .. "; masuk ulang " .. counts(App.rejoins or {})
                    .. "; diulang karena error " .. counts(App.retries or {})
                    .. (App.lastRetryError and ("; terakhir: " .. App.lastRetryError) or "")
                    .. (#errors > 0 and ("; checkpoint error: " .. table.concat(errors, ", ")) or "")
            end)(),
            "Planting recovery: " .. tostring(App.plantingRecovery or "-"),
            "Rotation: " .. tostring(App.rotationInfo or "-") .. " | world ke-" .. tostring(App.rotationIndex or "-")
                .. ", putaran " .. tostring(App.rotationLaps or 0)
                .. ", error kecil dilewati " .. tostring(App.rotationSoftErrors or 0) .. "x"
                .. (App.rotationLastError and ("; error kecil terakhir: " .. App.rotationLastError) or ""),
            (function()
                local parts = {}
                for _, pair in ipairs({ { "World rotasi", App.rotationWorlds }, { "World harvest", App.harvestWorlds } }) do
                    for name, text in pairs(pair[2] or {}) do table.insert(parts, pair[1] .. " " .. name .. ": " .. text) end
                end
                if App.rotationBoxNote then table.insert(parts, "Catatan box: " .. App.rotationBoxNote) end
                return #parts > 0 and table.concat(parts, "\n") or "World rotasi/harvest: -"
            end)(),
            "Harvest: " .. tostring(App.harvestPlan or "-") .. " | world ke-" .. tostring(App.harvestIndex or "-")
                .. ", replant " .. tostring(App.config.harvesting.replant),
            (function()
                local labels = { { "harvest", "pohon" }, { "PNB", "blok" }, { "replant", "tile" },
                    { "masuk & scan world", "kali" }, { "simpan seed", nil } }
                local parts, total = {}, 0
                for _, info in ipairs(labels) do
                    local entry = (App.phaseTime or {})[info[1]]
                    if entry then
                        total = total + entry.seconds
                        local text = string.format("%s %.0fd", info[1], entry.seconds)
                        if info[2] and entry.units > 0 then
                            text = text .. string.format(" (%d %s, %.2f d/%s)", entry.units, info[2], entry.seconds / entry.units, info[2])
                        end
                        table.insert(parts, text)
                    end
                end
                if #parts == 0 then return "Waktu rotasi: -" end
                for i, info in ipairs(labels) do
                    local entry = (App.phaseTime or {})[info[1]]
                    if entry and total > 0 then
                        for j, part in ipairs(parts) do
                            if part:sub(1, #info[1] + 1) == info[1] .. " " then
                                parts[j] = part .. string.format(" = %d%%", math.floor(entry.seconds / total * 100 + 0.5))
                            end
                        end
                    end
                end
                return "Waktu rotasi: " .. table.concat(parts, "; ") .. string.format(" | pungut dilewati (tanpa drop) %dx", App.collectSkips or 0)
            end)(),
            "Jangkauan pungut server: " .. G.Drops.reachText(),
            "Stock terakhir: " .. tostring(App.stockDebug or "-"),
            "Auto collect: " .. (App.config and App.config.options.autoCollect and "on" or "off") .. ", jangkauan "
                .. tostring(App.config and App.config.options.collectRange) .. ", " .. tostring(App.autoCollectInfo or "-"),
            "Seed ditanam sesi ini: " .. App.stats.planted .. " | Blok dipecah: " .. App.stats.broken,
            "PNB: blok " .. tostring(App.config.blockId) .. ", " .. #App.config.pnb.tiles .. " tile, auto stock "
                .. tostring(App.config.pnb.autoStock) .. ", auto drop " .. tostring(App.config.pnb.autoDrop) .. ", balik ke spot " .. (App.pnbRecoveries or 0) .. "x",
        }
        for _, line in ipairs(App.discoveryReport) do table.insert(lines, line) end
        if App.scanReport then
            table.insert(lines, "World Scan:")
            for _, line in ipairs(App.scanReport) do table.insert(lines, "  " .. line) end
        end
        table.insert(lines, "Log:")
        for i = 1, math.min(#App.logs, 15) do table.insert(lines, App.logs[i]) end
        return table.concat(lines, "\n")
    end

    -- Anti-AFK (adaptasi installAntiAFK Clarissv v0.1.43): saat Roblox mendeteksi idle,
    -- kirim klik kanan virtual lewat VirtualUser. Maksimal sekali per menit.
    function G.installAntiAFK()
        if App.idleConnection then return true end
        local ok, service = pcall(function() return game:GetService("VirtualUser") end)
        if not ok then App.antiAFKError = tostring(service); return false end
        local connected, connection = pcall(function()
            return player.Idled:Connect(function()
                if not App.alive or not App.config.options.antiAFK then return end
                if App.lastIdleInput and os.clock() - App.lastIdleInput < 60 then return end
                local sent, message = pcall(function()
                    service:CaptureController()
                    service:ClickButton2(Vector2.new(0, 0))
                end)
                if sent then App.lastIdleInput, App.antiAFKError = os.clock(), nil
                else App.antiAFKError = tostring(message) end
            end)
        end)
        if not connected then App.antiAFKError = tostring(connection); return false end
        App.idleConnection, App.antiAFKError = connection, nil
        return true
    end

    -- Auto reconnect: Roblox menampilkan layar error/disconnect (GuiService.ErrorMessageChanged).
    -- Simpan antrean auto-resume (queue_on_teleport), lalu teleport masuk lagi ke Growblox. Gagal =
    -- coba lagi tiap 15 detik, maks 5x. Setelah masuk, task yang punya checkpoint dilanjutkan.
    function G.installReconnect()
        if App.reconnectConnection then return true end
        local okService, GuiService = pcall(function() return game:GetService("GuiService") end)
        local okTeleport, TeleportService = pcall(function() return game:GetService("TeleportService") end)
        if not okService or not okTeleport then App.reconnectInfo = "service tidak tersedia"; return false end
        local busy = false
        local function rejoin(message)
            if busy or not App.alive or not App.config.options.autoReconnect then return end
            if type(message) ~= "string" or message == "" then return end
            busy = true
            App.reconnectInfo = os.date("%H:%M:%S") .. " disconnect: " .. message:sub(1, 80)
            pcall(G.State.saveSession)
            task.spawn(function()
                for attempt = 1, 5 do
                    if not App.alive or not App.config.options.autoReconnect then break end
                    G.env.GrowbloxHanselAutoResume = nil
                    App.queued = false
                    pcall(G.Movement.queueResume) -- setelah masuk lagi, script dimuat & task dilanjutkan
                    App.reconnectInfo = os.date("%H:%M:%S") .. " reconnect " .. attempt .. "/5 (" .. message:sub(1, 60) .. ")"
                    G.setStatus("Disconnect. Masuk lagi ke Growblox (" .. attempt .. "/5)...")
                    pcall(function() TeleportService:Teleport(game.PlaceId, player) end)
                    task.wait(15)
                end
                busy = false
            end)
        end
        local connected, connection = pcall(function()
            return GuiService.ErrorMessageChanged:Connect(rejoin)
        end)
        if not connected then App.reconnectInfo = "gagal pasang: " .. tostring(connection); return false end
        App.reconnectConnection = connection
        App.reconnectInfo = App.reconnectInfo or "siap"
        -- Layar error sudah tampil sebelum script jalan? Tangani juga.
        local okMessage, current = pcall(function() return GuiService:GetErrorMessage() end)
        if okMessage and type(current) == "string" and current ~= "" then rejoin(current) end
        return true
    end

    function G.unload()
        if not App.alive then return end
        if App.reconnectConnection then pcall(function() App.reconnectConnection:Disconnect() end); App.reconnectConnection = nil end
        if App.idleConnection then pcall(function() App.idleConnection:Disconnect() end); App.idleConnection = nil end
        if App.job then pcall(G.Jobs.stop) end
        pcall(G.Movement.releaseControls)
        App.alive = false
        App.token = App.token + 1
        if env.GrowbloxHanselApp == App then env.GrowbloxHanselApp = nil end
        if App.window then pcall(function() App.window:Destroy() end) end
    end

    -- 5) Pulihkan setting terakhir (kalau ada), lalu muat UI.
    local restored, problem = pcall(G.State.restoreSession)
    if not restored then G.setStatus("Session lama nggak bisa dibaca: " .. tostring(problem)) end
    if App.config.options.antiAFK then G.installAntiAFK() end
    if App.config.options.autoReconnect then G.installReconnect() end
    pcall(G.Update.install)
    if env.GrowbloxHanselUpdatedFrom then
        G.setStatus("Auto update: " .. tostring(env.GrowbloxHanselUpdatedFrom) .. " -> " .. VERSION .. ".")
        App.update.info = "diupdate dari " .. tostring(env.GrowbloxHanselUpdatedFrom)
        env.GrowbloxHanselUpdatedFrom = nil
    end

    local function loadWindUI()
        if type(env.GrowbloxHanselWindUI) == "table" then return env.GrowbloxHanselWindUI end
        local source
        if G.State.exists("GrowbloxHansel/WindUI.lua") then source = readfile("GrowbloxHansel/WindUI.lua")
        elseif type(env.GrowbloxHanselWindUIURL) == "string" then source = game:HttpGet(env.GrowbloxHanselWindUIURL)
        else error("WindUI tidak ditemukan. Taruh WindUI.lua di folder workspace GrowbloxHansel/.") end
        local chunk, message = loadstring(source, "WindUI")
        assert(chunk, message)
        local ui = chunk()
        env.GrowbloxHanselWindUI = ui
        return ui
    end
    WindUI = loadWindUI()
    G.UI.build(WindUI)

    -- 6) Connect di latar belakang. Tunggu atribut Qz (tanda game sudah memuat modulnya), maks 30 detik.
    task.spawn(function()
        local deadline = os.clock() + 30
        while App.alive and ReplicatedStorage:GetAttribute("Qz") == nil and os.clock() < deadline do task.wait(0.25) end
        if not App.alive then return end
        -- Dimuat ulang (auto-resume) tapi masih di world picker dan game belum memuat world sama
        -- sekali (Qz belum ada, world table 0): masuk ke world tujuan task lewat UI picker dulu.
        -- Sedang melanjutkan task: antrekan auto-resume SEKARANG. Masuk world dari picker (atau
        -- apa pun selama resume) bisa pindah server; tanpa antrean ini script tidak dimuat di server
        -- baru dan rotasi berhenti di world picker.
        if env.GrowbloxHanselAutoResume then
            App.queued = false
            local queued = pcall(G.Movement.queueResume)
            App.pickerEntry = App.pickerEntry or (queued and App.queued and "antrean auto-resume siap" or "queue_on_teleport tidak tersedia")
        end
        if env.GrowbloxHanselAutoResume and ReplicatedStorage:GetAttribute("Qz") == nil then
            local target = G.Jobs.resumeTargetWorld()
            for attempt = 1, 3 do
                if not target or ReplicatedStorage:GetAttribute("Qz") ~= nil or not App.alive then break end
                G.setStatus("Masuk " .. target .. " lewat world picker (" .. attempt .. "/3)...")
                local ok, how = pcall(G.enterFromPicker, target)
                App.pickerEntry = (ok and tostring(how) or ("gagal: " .. tostring(how))) .. " -> " .. target
                local wait = os.clock() + 20
                while App.alive and ReplicatedStorage:GetAttribute("Qz") == nil and os.clock() < wait do task.wait(0.25) end
            end
        end
        App.configuring = true
        local ok, message = pcall(G.connect, env.GrowbloxHanselAutoResume == true)
        App.configuring = false
        if not ok then
            G.setStatus(tostring(message))
            G.notify(tostring(message))
            return
        end
        -- Setelah pindah server, fitur yang punya checkpoint dilanjutkan otomatis.
        if env.GrowbloxHanselAutoResume then
            env.GrowbloxHanselAutoResume = nil
            for _, handler in ipairs(G.resumeHandlers) do
                local found, resumed = pcall(handler)
                if found and resumed then break end
                if not found then G.setStatus("Gagal resume: " .. tostring(resumed)) end
            end
        end
    end)

    -- 7) Heartbeat: update UI dan simpan setting berkala.
    task.spawn(function()
        local nextSave = 0
        while App.alive do
            pcall(G.UI.refresh)
            if not App.configuring and os.clock() >= nextSave then
                nextSave = os.clock() + 5
                local saved, issue = pcall(G.State.saveSession)
                App.sessionSaveError = not saved and tostring(issue) or nil
            end
            task.wait(0.5)
        end
    end)

    G.setStatus("Script dimuat. Menunggu game...")
    return App
end

end)()

return __modules.main(__modules, __VERSION)
