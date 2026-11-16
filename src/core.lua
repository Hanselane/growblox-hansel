-- core.lua: logika MURNI. Tidak menyentuh game, file, atau UI, jadi bisa dites di luar Roblox.
-- Banyak fungsi diadaptasi dari Claris Growblox Autofarm (Clarissv), core.lua.
local Core = {}

Core.CONFIG_VERSION = 1
Core.POINTS = { "pnb", "blockBox", "seedBox", "farmBox", "plantBox" }
Core.COLLECT_FILTERS = { "all", "gems", "crop" }

-- Angka yang boleh diatur user: { minimum, maksimum, bawaan }.
Core.LIMITS = {
    placeDelay = { 0.15, 2, 0.2 }, punchDelay = { 0.22, 2, 0.24 },
    collectDelay = { 0, 5, 0.1 }, actionTimeout = { 5, 30, 10 },
    moveTimeout = { 5, 90, 30 }, seedThreshold = { 1, 200, 200 },
    collectRange = { 0.5, 5, 1.5 },
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
    }
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
            if key ~= "pnb" then -- box butuh posisi berdiri di depannya
                assert(integer(point.standX, 0, 65535) and integer(point.standY, 0, 65535),
                    "Posisi berdiri hilang: " .. key)
                copy.standX, copy.standY = point.standX, point.standY
            end
            out.points[key] = copy
        end
    end

    local planting = input.planting or {}
    assert(type(planting) == "table", "Bagian planting di profil rusak.")
    if planting.seedId ~= nil then
        assert(integer(planting.seedId, 0, 65535), "ID seed tidak valid.")
        out.planting.seedId = planting.seedId
    end
    if planting.storageWorld ~= nil and planting.storageWorld ~= "" then
        out.planting.storageWorld = Core.worldName(planting.storageWorld)
    end
    local seen = {}
    for _, name in ipairs(planting.worlds or {}) do
        local world = Core.worldName(name)
        assert(not seen[world], "World farm dobel: " .. world)
        seen[world] = true
        table.insert(out.planting.worlds, world)
    end
    assert(#out.planting.worlds <= 50, "Maksimal 50 world farm.")

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

return Core
