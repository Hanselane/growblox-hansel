-- Growblox Hansel v0.3.8. File ini HASIL BUILD; edit src/, lalu jalankan: node build.mjs
local __VERSION = "0.3.8"
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
Core.BOOLS = { antiAFK = true, autoRejoin = true, autoCollect = false }

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
        harvesting = { method = "fist" },
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
    return out
end

-- Seed dari sebuah blok. Growblox: seedId tertulis di definisi item, atau blockId + 1.
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
    if mode == "plant" then
        local p = Core.validatePlanting(config.planting)
        assert(items[p.seedId] and items[p.seedId].kind == "seed", "Choose a seed on the Planting tab.")
        assert(p.storageWorld ~= "" and config.points.plantBox, "Save the planting seed Display Box and storage world first.")
        assert(config.points.plantBox.world:upper() == p.storageWorld, "The saved seed Display Box must be in the entered storage world.")
        assert(#p.worlds > 0, "Enter at least one dirt farm world.")
        for _, name in ipairs(p.worlds) do assert(name ~= p.storageWorld, "Seed storage and dirt farm worlds must be different.") end
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
            treeRipe = treeRipe, harvestGear = harvestGear, treeRemaining = treeRemaining }

        report("Item definitions: " .. itemSource)
        report("Hooks: " .. (#issues == 0 and "ready" or table.concat(issues, " ")))
        report("Planting hook: " .. (handlers.plantSeed and "ready" or ambiguous.plantSeed and "ambiguous" or "unavailable"))
        report("Tree growth hook: " .. (treeRipe and "ready" or "unavailable"))
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
                local state = body and body.state()
                local inWorld = result.world.name ~= nil and result.world.name ~= "" and not Bridge.pickerOpen(result)
                if inWorld and (not body or (state.active and not state.dead)) then
                    App.runtime, App.connectionError = result, nil
                    App.connectAttempts = attempt
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
        local state = r.body.state()
        assert(state.active and not state.dead, "Masuk ke world dan tunggu karakter siap.")
        return state
    end
    -- Dipanggil sebelum aksi penting: masih di world yang benar, avatar hidup, tidak di-freeze.
    function Bridge.worldCheck(name, token)
        if token then Net.checkpoint(token) end
        local r = Bridge.runtime()
        if r.world.name == nil or r.world.name == "" or Bridge.pickerOpen(r) then
            error(Bridge.recoverable("Kembali ke world picker.", name, "worldPicker"), 0)
        end
        assert(name == nil or r.world.name == name, "World berubah. Stop demi keamanan posisi tersimpan.")
        assert(not G.frozen(), "Karakter di-freeze.")
        if r.body then
            local state = r.body.state()
            if not state.active or state.dead then
                error(Bridge.recoverable("Menunggu avatar siap.", name, "avatar"), 0)
            end
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
            queue("getgenv().GrowbloxHanselAutoResume = true; loadstring(game:HttpGet("
                .. string.format("%q", loader) .. "))()")
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
            local avatar = r.body and r.body.state()
            if r.world.name == name and not Bridge.pickerOpen(r) and avatar and avatar.active and not avatar.dead
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
    function Drops.takeBatch(worldName, targets, attempts, retryAt, eligible, token)
        local r = worldCheck(worldName, token)
        local take = App.controls and App.controls.takeDrop or r.world.takeDrop
        assert(type(take) == "function" and type(r.world.dropTaken) == "function",
            "The loose-drop pickup hooks are unavailable. Copy diagnostics from Settings.")
        local jobs, reserved = {}, {}
        local deadline = os.clock() + App.config.options.actionTimeout
        for _, drop in ipairs(targets) do
            if #jobs >= 8 then break end
            worldCheck(worldName, token)
            local present = false
            for _, current in pairs(r.world.dropList()) do if current == drop then present = true; break end end
            local room = drop.id == Drops.GEM and 65535 or math.max(0, r.inventory:room(drop.id) - (reserved[drop.id] or 0))
            local want = math.floor(math.min(drop.n, room, 65535))
            if want > 0 and present and eligible(drop) then
                local before, grid, uid, id = drop.n, r.world.fg, drop.uid, drop.id
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
        local results = {}
        for _, job in ipairs(jobs) do
            local amount = Net.awaitRequest(job.request, deadline, token)
            if amount > 0 then attempts[job.uid] = 0 end
            table.insert(results, { uid = job.uid, id = job.id, amount = amount })
        end
        return results
    end

    -- Pungut semua drop dengan id di `ids` dalam kotak di sekitar posisi berdiri `anchor`:
    -- |x - tengah| <= radius, dan y dari anchor.y - up sampai anchor.y + down.
    -- Return: tabel { [id] = jumlah yang berhasil dipungut }, dan jumlah drop yang dilewati.
    function Drops.collectNear(anchor, ids, token, options)
        options = options or {}
        local radius, up, down = options.radius or 1.25, options.up or 1.5, options.down or 1.25
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
                            if (attempts[drop.uid] or 0) >= 3 then skipped = skipped + 1
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

    -- Jangkauan pungut server Growblox (dari Clarissv collectDrops): 1.25 tile ke samping,
    -- 1.5 ke atas, 1.25 ke bawah dari tile tempat berdiri. Lebih jauh dari itu ditolak server.
    Drops.REACH = { radius = 1.25, up = 1.5, down = 1.25 }

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
        add(Drops.collectNear(stand, ids, token, { radius = Drops.REACH.radius, up = Drops.REACH.up,
            down = Drops.REACH.down, attempts = attempts }))
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
    -- }
    function Jobs.register(mode, spec)
        Jobs.specs[mode] = spec
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
        for _, key in ipairs({ "harvest", "rotation" }) do
            UI.tabs[key]:Paragraph({ Title = "Belum dibuat", Desc = "Fitur ini ditambah di tahap berikutnya." })
        end

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
            { "autoRejoin", "Rejoin world and return to PNB", "Terlempar ke world picker, avatar mati, atau pindah server: masuk lagi ke world PNB, jalan balik ke spot, lanjut. Juga lanjut Planting dari checkpoint." },
        }) do
            local key = info[1]
            UI.settings[key] = s:Toggle({ Title = info[2], Desc = info[3], Value = App.config.options[key],
                Callback = function(value)
                    if App.syncingSettings then return end
                    local ok, message = pcall(function()
                        Net.idle()
                        App.config.options[key] = value == true
                        if key == "antiAFK" and value then G.installAntiAFK() end
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
                    if Storage.count(box, id) == 0 then
                        Plant.clearResume()
                        G.setStatus("Planting stopped: the seed storage box is empty. Unfinished farm: " .. settings.worlds[state.worldIndex])
                        return false
                    end
                    Storage.withdraw(box, id, token, nil, function()
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
        tab:Button({ Title = "Save seed Display Box", Desc = "Stand beside the seed box in the storage world. A dedicated box also selects its seed type.",
            Callback = UI.action(function()
                local point = Storage.captureNearby("plantBox", "box")
                App.config.planting.storageWorld = Core.worldName(Bridge.runtime().world.name)
                local seed
                for _, row in pairs(Storage.boxRows(point)) do
                    local item = Bridge.runtime().items[row[1]]
                    assert(item and item.kind == "seed", "Use a Display Box containing seeds only.")
                    assert(not seed or seed == row[1], "Use a Display Box dedicated to one seed type.")
                    seed = row[1]
                end
                if seed then App.config.planting.seedId = seed end
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
-- dan perekam aksi game untuk menemukan cara drop seed.
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
    function Pnb.collect(anchor, pickupIds, token)
        local ids, area = pickupIds, GRID_AREA
        if App.config.options.autoCollect then
            local range = App.config.options.collectRange
            ids = "all"
            area = { radius = math.max(GRID_AREA.radius, range), up = math.max(GRID_AREA.up, range),
                down = math.max(GRID_AREA.down, range) }
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
            or App.configuring or App.recording or App.autoCollectHold or App.teleporting then return false end
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
    local lastResumeSave = -math.huge
    function Pnb.saveResume()
        State.saveCheckpoint("pnb", { anchor = App.config.points.pnb })
        lastResumeSave = os.clock()
    end
    function Pnb.clearResume() State.clearCheckpoint("pnb") end
    -- Diperbarui tiap 2 menit supaya checkpoint tidak dianggap basi saat PNB jalan lama.
    local function refreshResume()
        if App.config.options.autoRejoin and App.pending == 0 and os.clock() - lastResumeSave >= 120 then
            local ok, issue = pcall(Pnb.saveResume)
            if not ok then App.pnbResumeError = tostring(issue) end
        end
    end

    -- Error biasa saat aksi bisa jadi efek world picker/avatar mati yang belum kelihatan.
    -- Tunggu 1,5 detik: kalau ternyata karena itu, ubah jadi error "recoverable".
    function Pnb.classifyFault(problem, token)
        if type(problem) == "table" and problem.recoverable then return problem end
        if tostring(problem):find("Stopped", 1, true) then return problem end
        Movement.releaseControls()
        local name, deadline = App.config.points.pnb.world, os.clock() + 1.5
        repeat
            checkpoint(token)
            local r = Bridge.runtime()
            if r.world.name == "" or r.world.name == nil or Bridge.pickerOpen(r) then
                return Bridge.recoverable("Kembali ke world picker saat aksi: " .. tostring(problem), name, "worldPicker")
            end
            if r.world.name ~= name then return problem end
            local state = r.body and r.body.state()
            if state and (not state.active or state.dead) then
                return Bridge.recoverable("Avatar tidak aktif saat aksi: " .. tostring(problem), name, "avatar")
            end
            if os.clock() >= deadline then return problem end
            pause(0.1, token)
        until false
    end

    -- Masuk lagi ke world PNB (lewat world picker, bisa pindah server) lalu jalan ke spot.
    function Pnb.returnToSpot(token)
        local anchor = App.config.points.pnb
        App.recovering = true
        App.pnbRejoins = (App.pnbRejoins or 0) + 1
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
            refreshResume()
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
            Pnb.collect(anchor, pickupIds, token)
        end
    end

    G.Jobs.register("pnb", {
        label = "Place & Break",
        prepare = function(r, saved)
            assert(r.body and r.controls and r.handlers.setTile and r.handlers.hit and r.handlers.canPlace,
                "Hook place/break tidak tersedia. Copy diagnostics dari Settings.")
            -- Posisi PNB = tempat karakter berdiri saat toggle dinyalakan (seperti Crusader).
            -- Resume setelah pindah server: pakai spot dari checkpoint.
            if saved and saved.anchor then App.config.points.pnb = saved.anchor
            else App.config.points.pnb = Pnb.standingTile() end
        end,
        -- Sama seperti Clarissv: error "recoverable" + setting Rejoin nyala = masuk lagi ke world,
        -- balik ke spot, lanjut PNB. Pemulihan yang terganggu 3x berturut-turut = berhenti.
        run = function(token, saved)
            local anchor = App.config.points.pnb
            if saved then
                local r = Bridge.runtime()
                if r.world.name ~= anchor.world or Bridge.pickerOpen(r) then Pnb.returnToSpot(token) end
            end
            while true do
                local completed, problem = pcall(Pnb.run, token)
                if completed then break end
                checkpoint(token)
                problem = Pnb.classifyFault(problem, token)
                if not (type(problem) == "table" and problem.recoverable and App.config.options.autoRejoin) then
                    error(problem, 0)
                end
                local interruptions = 0
                while true do
                    local recovered, nextProblem = pcall(Pnb.returnToSpot, token)
                    if recovered then break end
                    checkpoint(token)
                    if type(nextProblem) ~= "table" or not nextProblem.recoverable then error(nextProblem, 0) end
                    interruptions = interruptions + 1
                    assert(interruptions < 3, "Pemulihan terganggu 3x. Cek world tersimpan dan koneksi.")
                end
            end
            Pnb.clearResume()
        end,
        clear = function() Pnb.clearResume() end,
    })
    -- Auto-resume setelah pindah server (loader dijalankan ulang lewat queue_on_teleport).
    table.insert(G.resumeHandlers, function()
        local record = State.loadCheckpoint("pnb")
        if not record or type(record.data) ~= "table" or type(record.data.anchor) ~= "table" then return false end
        App.config, App.profile = record.config, Core.profileName(record.profile)
        G.Jobs.start("pnb", record.data)
        return true
    end)

    ---------------------------------------------------------------- perekam aksi game
    -- Bungkus sementara semua fungsi milik world dan touch controls, lalu catat setiap panggilan
    -- (nama + argumen) selama `seconds` detik. Dipakai untuk mencari perintah drop item.
    -- Fungsi yang dipanggil tiap frame tidak dibungkus sama sekali (hemat & tidak bikin lag).
    local NOISY = { dir = true, jumping = true, dropList = true, backpackNow = true, state = true }
    local function describe(value)
        local kind = type(value)
        if kind == "number" then
            if value == math.floor(value) and math.abs(value) < 2^53 then return string.format("%d", value) end
            return string.format("%.2f", value)
        end
        if kind == "boolean" then return tostring(value) end
        if kind == "string" then return string.format("%q", #value > 24 and value:sub(1, 24) .. "..." or value) end
        if kind == "table" then
            local n = 0
            pcall(function() for _ in next, value do n = n + 1 end end)
            return "table(" .. n .. ")"
        end
        return kind
    end
    function Pnb.record(seconds)
        Net.idle()
        local r = Bridge.runtime()
        local order, counts, byName, wrapped, started = {}, {}, {}, {}, os.clock()
        local function wrap(owner, label)
            if type(owner) ~= "table" then return end
            for key, fn in next, owner do
                if type(fn) == "function" and not NOISY[key] then
                    local original, name = fn, label .. "." .. tostring(key)
                    local wrapper = function(...)
                        byName[name] = (byName[name] or 0) + 1
                        local args = table.pack(...)
                        local parts = {}
                        for i = 1, math.min(args.n, 8) do parts[i] = describe(args[i]) end
                        local signature = name .. "(" .. table.concat(parts, ", ") .. ")"
                        if not counts[signature] then
                            if #order >= 3000 then return original(...) end
                            table.insert(order, { signature = signature, name = name, at = os.clock() - started })
                            counts[signature] = 0
                        end
                        counts[signature] = counts[signature] + 1
                        return original(...)
                    end
                    table.insert(wrapped, { owner = owner, key = key, original = original, wrapper = wrapper })
                end
            end
        end
        wrap(r.world, "world")
        wrap(r.controls, "controls")
        wrap(r.handlers, "handlers")
        wrap(r.gemHud, "hud")
        wrap(r.inventory, "inventory")
        for _, item in ipairs(wrapped) do rawset(item.owner, item.key, item.wrapper) end
        -- Lapis 2: sadap SEMUA kiriman ke server (FireServer/InvokeServer). Game menyimpan
        -- fungsi lokal sendiri, jadi aksi seperti drop bisa lolos dari bungkus tabel di atas;
        -- tapi apa pun yang dikirim ke server pasti lewat sini.
        local X, remoteActive, remoteNote = G.exec, true, "tidak tersedia di executor ini"
        if type(X.hookmetamethod) == "function" and type(X.getnamecallmethod) == "function" and X.game then
            local old
            local function note(remote, method, ...)
                local first = ...
                local name = "remote " .. tostring(remote) .. ":" .. method
                    .. (type(first) == "string" and (" " .. first) or "")
                byName[name] = (byName[name] or 0) + 1
                local args = table.pack(...)
                local parts = {}
                for i = 1, math.min(args.n, 8) do parts[i] = describe(args[i]) end
                local signature = name .. "(" .. table.concat(parts, ", ") .. ")"
                if not counts[signature] then
                    if #order >= 3000 then return end
                    table.insert(order, { signature = signature, name = name, at = os.clock() - started, remote = true })
                    counts[signature] = 0
                end
                counts[signature] = counts[signature] + 1
            end
            local hook = function(self, ...)
                if remoteActive then
                    local method = X.getnamecallmethod()
                    if (method == "FireServer" or method == "InvokeServer")
                        and not (X.checkcaller and X.checkcaller()) then
                        pcall(note, self, method, ...)
                    end
                end
                return old(self, ...)
            end
            local ok, result = pcall(X.hookmetamethod, X.game, "__namecall", X.newcclosure and X.newcclosure(hook) or hook)
            if ok and type(result) == "function" then old, remoteNote = result, "aktif" else remoteNote = "gagal: " .. tostring(result) end
        end
        App.recording = true
        App.recordReport = { "Rekaman berjalan... tunggu status 'Rekaman selesai'." }
        G.setStatus("Merekam " .. seconds .. " detik. Drop seed secara MANUAL sekarang. Copy diagnostics SETELAH status 'Rekaman selesai'.")
        task.delay(seconds, function()
            for _, item in ipairs(wrapped) do
                if rawget(item.owner, item.key) == item.wrapper then rawset(item.owner, item.key, item.original) end
            end
            App.recording = false
            remoteActive = false -- hook tetap terpasang tapi cuma meneruskan (aman)
            -- Yang ditampilkan: semua world.call, lalu panggilan JARANG (<= 3x) = aksi manual.
            -- Fungsi yang dipanggil ribuan kali (per frame) cuma diringkas jumlahnya.
            local report = { "Sadap server: " .. remoteNote }
            for _, entry in ipairs(order) do
                if entry.name == "world.call" or (counts[entry.signature] <= 3 and byName[entry.name] <= 30) then
                    if #report < 40 then
                        table.insert(report, string.format("%.1fs  %s x%d", entry.at, entry.signature, counts[entry.signature]))
                    end
                end
            end
            if #report == 1 then table.insert(report, "Tidak ada panggilan jarang. Drop seed belum tercatat; coba lagi.") end
            local busy = {}
            for name, n in pairs(byName) do if n > 30 then table.insert(busy, { name = name, n = n }) end end
            table.sort(busy, function(a, b) return a.n > b.n end)
            local parts = {}
            for i = 1, math.min(8, #busy) do parts[i] = busy[i].name .. " " .. busy[i].n end
            if #parts > 0 then table.insert(report, "Sering (diabaikan): " .. table.concat(parts, ", ")) end
            App.recordReport = report
            G.setStatus("Rekaman selesai. Copy diagnostics di Settings dan kirim.")
        end)
    end

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
        -- Untuk perekam aksi: menyadap panggilan ke server (RemoteEvent/RemoteFunction).
        hookmetamethod = hookmetamethod, getnamecallmethod = getnamecallmethod,
        newcclosure = newcclosure, checkcaller = checkcaller, game = game,
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
    G.UI = modules.ui(G)
    G.Plant = modules.plant(G)
    G.Pnb = modules.pnb(G)
    App.config = G.Core.defaults()

    function G.connect()
        G.setStatus("Menyambung ke game...")
        local r = G.Bridge.connect({ attempts = 8, delay = 4, onRetry = function(attempt, total, message)
            G.setStatus("World belum siap (" .. message .. "). Coba lagi " .. attempt .. "/" .. (total - 1) .. "...")
        end })
        G.setStatus(r.ready and ("Tersambung ke " .. r.world.name .. ".")
            or ("Tersambung ke " .. r.world.name .. ", tapi ada hook yang hilang. Cek diagnostics."))
        for _, handler in ipairs(G.onConnected) do pcall(handler, r) end
        return r
    end

    function G.diagnostics()
        local lines = {
            "Growblox Hansel " .. VERSION,
            "World: " .. (App.runtime and App.runtime.world.name or "belum tersambung"),
            "Profil: " .. App.profile .. " | Akun: " .. ACCOUNT_ID,
            "Status: " .. App.status,
            "Connect error: " .. (App.connectionError or "tidak ada"),
            "Percobaan connect: " .. tostring(App.connectAttempts or "-"),
            "Tahap startup: " .. App.startupStage,
            "Loader: " .. tostring(env.GrowbloxHanselLoaderDebug or "lokal / tidak diketahui"),
            "Job: " .. tostring(App.job or "idle") .. " | Request pending: " .. App.pending,
            "Navigasi: " .. tostring(App.navigationDebug or "-"),
            "Anti-AFK: " .. (App.config.options.antiAFK and "on" or "off") .. "; "
                .. (App.antiAFKError or (App.idleConnection and "siap" or "belum terpasang"))
                .. (App.lastIdleInput and string.format("; input terakhir %.0f detik lalu", os.clock() - App.lastIdleInput) or ""),
            "Rejoin & balik ke PNB: " .. (App.config.options.autoRejoin and "on" or "off") .. "; masuk ulang "
                .. tostring(App.pnbRejoins or 0) .. "x" .. (App.pnbResumeError and ("; checkpoint error: " .. App.pnbResumeError) or ""),
            "Planting recovery: " .. tostring(App.plantingRecovery or "-"),
            "Stock terakhir: " .. tostring(App.stockDebug or "-"),
            "Auto collect: " .. (App.config and App.config.options.autoCollect and "on" or "off") .. ", jangkauan "
                .. tostring(App.config and App.config.options.collectRange) .. ", " .. tostring(App.autoCollectInfo or "-"),
            "Seed ditanam sesi ini: " .. App.stats.planted .. " | Blok dipecah: " .. App.stats.broken,
            "PNB: blok " .. tostring(App.config.blockId) .. ", " .. #App.config.pnb.tiles .. " tile, auto stock "
                .. tostring(App.config.pnb.autoStock) .. ", auto drop " .. tostring(App.config.pnb.autoDrop) .. ", balik ke spot " .. (App.pnbRecoveries or 0) .. "x",
        }
        for _, line in ipairs(App.discoveryReport) do table.insert(lines, line) end
        if App.recordReport then
            table.insert(lines, "Rekaman aksi game:")
            for _, line in ipairs(App.recordReport) do table.insert(lines, "  " .. line) end
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

    function G.unload()
        if not App.alive then return end
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
        App.configuring = true
        local ok, message = pcall(G.connect)
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
