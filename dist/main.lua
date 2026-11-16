-- Growblox Hansel v0.1.1. File ini HASIL BUILD; edit src/, lalu jalankan: node build.mjs
local __VERSION = "0.1.1"
local __modules = {}

-- ===== src/core.lua =====
__modules["core"] = (function(...)
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
    local function owns(fn, world, scan)
        for _, value in pairs(upvalues(fn, scan)) do if value == world then return true end end
        return false
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
                if not body or (state.active and not state.dead) then
                    App.runtime, App.connectionError = result, nil
                    App.connectAttempts = attempt
                    return result
                end
                result = "Your character is not ready yet."
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

-- ===== src/ui.lua =====
__modules["ui"] = (function(...)
-- ui.lua: jendela WindUI. Pondasi baru bikin kerangka tab + tab Settings.
-- Isi tab fitur (Place & Break + Auto Collect, Planting, Harvest, Rotation) ditambah bareng fiturnya.
return function(G)
    local App, task = G.App, G.task
    local UI = { tabs = {} }

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
        UI.tabs.pnb:Paragraph({ Title = "Belum dibuat", Desc = "Place & Break dan Auto Collect ditambah di tahap berikutnya." })
        for _, key in ipairs({ "plant", "harvest", "rotation" }) do
            UI.tabs[key]:Paragraph({ Title = "Belum dibuat", Desc = "Fitur ini ditambah di tahap berikutnya." })
        end

        local s = UI.tabs.settings
        UI.status = s:Paragraph({ Title = "Status", Desc = App.status })
        s:Button({ Title = "Reconnect to game", Desc = "Pakai ini kalau muncul 'found 0'. Masuk world dulu, baru pencet.",
            Callback = UI.action(function() G.connect() end) })
        s:Button({ Title = "Copy diagnostics", Callback = function()
            local text = G.diagnostics()
            if type(G.exec.setclipboard) == "function" then G.exec.setclipboard(text); G.notify("Diagnostics di-copy.")
            else print(text); G.notify("Diagnostics dicetak ke console.") end
        end })
        s:Button({ Title = "Unload script", Callback = function() G.unload() end })
        UI.log = s:Paragraph({ Title = "Aktivitas terakhir", Desc = "-" })
        return window
    end

    -- Dipanggil berkala dari main.lua.
    function UI.refresh()
        UI.paragraph(UI.status, "Status", App.status)
        UI.paragraph(UI.log, "Aktivitas terakhir", table.concat(App.logs, "\n", 1, math.min(#App.logs, 8)))
    end

    return UI
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
        if previous.window then pcall(function() previous.window:Destroy() end) end
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
    G.Core = modules.core
    G.Net = modules.net(G)
    G.State = modules.state(G)
    G.Bridge = modules.bridge(G)
    G.Actions = modules.actions(G)
    G.UI = modules.ui(G)
    App.config = G.Core.defaults()
    G.resumeHandlers = {} -- fitur yang bisa di-resume mendaftar di sini (dipakai tahap berikutnya)

    function G.connect()
        G.setStatus("Menyambung ke game...")
        local r = G.Bridge.connect({ attempts = 8, delay = 4, onRetry = function(attempt, total, message)
            G.setStatus("World belum siap (" .. message .. "). Coba lagi " .. attempt .. "/" .. (total - 1) .. "...")
        end })
        G.setStatus(r.ready and ("Tersambung ke " .. r.world.name .. ".")
            or ("Tersambung ke " .. r.world.name .. ", tapi ada hook yang hilang. Cek diagnostics."))
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
        }
        for _, line in ipairs(App.discoveryReport) do table.insert(lines, line) end
        table.insert(lines, "Log:")
        for i = 1, math.min(#App.logs, 15) do table.insert(lines, App.logs[i]) end
        return table.concat(lines, "\n")
    end

    function G.unload()
        if not App.alive then return end
        App.alive = false
        App.token = App.token + 1
        if env.GrowbloxHanselApp == App then env.GrowbloxHanselApp = nil end
        if App.window then pcall(function() App.window:Destroy() end) end
    end

    -- 5) Pulihkan setting terakhir (kalau ada), lalu muat UI.
    local restored, problem = pcall(G.State.restoreSession)
    if not restored then G.setStatus("Session lama nggak bisa dibaca: " .. tostring(problem)) end

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
