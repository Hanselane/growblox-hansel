-- core.lua: logika MURNI. Tidak menyentuh game, file, atau UI, jadi bisa dites di luar Roblox.
-- Banyak fungsi diadaptasi dari Claris Growblox Autofarm (Clarissv), core.lua.
local Core = {}

Core.CONFIG_VERSION = 1
Core.POINTS = { "pnb", "blockBox", "seedBox", "farmBox", "plantBox", "stock", "seedDrop" }
-- Titik yang berupa TEMPAT BERDIRI (bukan box), jadi tidak butuh standX/standY.
Core.STAND_POINTS = { pnb = true, stock = true, seedDrop = true }
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
        if config.pnb.autoStock then assert(config.points.stock, "Set stock position dulu, atau matikan Auto take stock.") end
        if config.pnb.autoDrop then assert(config.points.seedDrop, "Set seed drop position dulu, atau matikan Auto drop seed.") end
        return true
    end
    error("Unknown farming task: " .. tostring(mode))
end

return Core
