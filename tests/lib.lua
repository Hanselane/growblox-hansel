-- Alat tes: assert sederhana, penjadwal task palsu, dan game Growblox palsu (mock).
local T = { passed = 0, failed = 0 }

function T.test(name, fn)
    local ok, err = pcall(fn)
    if ok then T.passed = T.passed + 1; print("  ok   " .. name)
    else T.failed = T.failed + 1; print("  FAIL " .. name .. "\n       " .. tostring(err)) end
end
function T.eq(actual, expected, label)
    if actual ~= expected then
        error((label or "nilai") .. ": dapat " .. tostring(actual) .. ", harusnya " .. tostring(expected), 2)
    end
end
function T.errors(fn, pattern)
    local ok, err = pcall(fn)
    if ok then error("harusnya error" .. (pattern and (" berisi '" .. pattern .. "'") or ""), 2) end
    if pattern and not tostring(err):find(pattern, 1, true) then
        error("pesan error '" .. tostring(err) .. "' tidak berisi '" .. pattern .. "'", 2)
    end
end

-- Lua 5.4 tidak punya loadstring/table.pack versi Luau persis; samakan.
loadstring = loadstring or load

-- Jam palsu + penjadwal coroutine, meniru task.spawn/task.wait milik Roblox.
function T.scheduler()
    local S = { now = 0, threads = {} }
    local realClock = os.clock
    os.clock = function() return S.now end
    S.restore = function() os.clock = realClock end
    S.task = {}
    function S.task.spawn(fn, ...)
        local co = coroutine.create(fn)
        local entry = { co = co, wake = S.now }
        table.insert(S.threads, entry)
        local ok, waitFor = coroutine.resume(co, ...)
        if not ok then entry.dead = true; error(waitFor, 0) end
        entry.wake = S.now + (waitFor or 0)
        if coroutine.status(co) == "dead" then entry.dead = true end
        return co
    end
    function S.task.defer(fn, ...) return S.task.spawn(fn, ...) end
    function S.task.wait(seconds)
        seconds = seconds or 0.016
        if coroutine.isyieldable() then coroutine.yield(seconds) else S.now = S.now + seconds end
        return seconds
    end
    -- Majukan waktu `seconds` detik, jalankan thread yang sudah waktunya bangun.
    function S.run(seconds, step)
        step = step or 0.05
        local stop = S.now + seconds
        while S.now < stop do
            S.now = S.now + step
            for _, entry in ipairs(S.threads) do
                if not entry.dead and entry.wake <= S.now then
                    local ok, waitFor = coroutine.resume(entry.co)
                    if not ok then entry.dead = true; entry.error = waitFor; print("       thread error: " .. tostring(waitFor))
                    elseif coroutine.status(entry.co) == "dead" then entry.dead = true
                    else entry.wake = S.now + (waitFor or 0) end
                end
            end
        end
    end
    return S
end

-- Game palsu. getupvalues/debugInfo palsu membaca tabel `meta` supaya bridge
-- bisa "membuktikan" kepemilikan fungsi persis seperti di game asli.
function T.fakeGame(options)
    options = options or {}
    local meta = { up = {}, names = {} }
    local function fn(name, owner, extra)
        local f = function() end
        meta.names[f] = name
        meta.up[f] = { owner }
        for _, v in ipairs(extra or {}) do table.insert(meta.up[f], v) end
        return f
    end
    local items = {
        [0] = { name = "Blank", solid = false }, [2] = { name = "Dirt", solid = true, hits = 3 },
        [3] = { name = "Dirt Seed", kind = "seed" }, [12] = { name = "Door", door = true },
        [18] = { name = "Fist", kind = "tool" }, [1422] = { name = "Display Box", display = true },
        [40] = { name = "Sugar Cane", hits = 4 }, [41] = { name = "Sugar Cane Seed", kind = "seed" },
    }
    local inventory = { slots = { { id = 40, n = 50 }, { id = 18, n = 1 } } }
    function inventory:count(id)
        local total = 0
        for _, s in ipairs(self.slots) do if s.id == id then total = total + s.n end end
        return total
    end
    function inventory:room(id) return 200 - self:count(id) end
    function inventory:add(id, n)
        for _, s in ipairs(self.slots) do if s.id == id then s.n = s.n + n; return end end
        table.insert(self.slots, { id = id, n = n })
    end
    function inventory:remove(id, n)
        for i, s in ipairs(self.slots) do
            if s.id == id then s.n = s.n - n; if s.n <= 0 then table.remove(self.slots, i) end; return end
        end
    end

    local world = { name = options.worldName or "NDJD", w = 100, h = 60, fg = {} }
    world.backpackNow = fn("backpackNow", inventory)
    world.displayPut = fn("displayPut", world)
    world.useDoor = fn("useDoor", world)
    world.enter = fn("enter", world)
    world.dropList = function() return {} end
    world.serverSlots = { { 40, 50 }, { 18, 1 } }
    world.call = function(method)
        if method == "GetInventory" then return { slots = world.serverSlots, capacity = 16 } end
    end
    meta.up[world.displayPut] = { world, items } -- item terbaca lewat upvalue fungsi world

    local avatar = { active = options.avatarReady ~= false, dead = false, x = 10.5, y = 20 }
    local body = { H = 0.95, HW = 0.3, solidAt = function() return false end }
    body.state = function() return avatar end
    meta.up[body.state] = { world }
    meta.names[body.state] = "state"
    local controls = {}
    for _, name in ipairs({ "dir", "jumping", "punchPressed", "setScale", "place", "edit" }) do
        controls[name] = function() end
    end
    local handlers = { fn("setTile", world), fn("hit", world), fn("canPlace", world), fn("plantSeed", world) }

    local G = { world = world, body = body, avatar = avatar, inventory = inventory, items = items,
        controls = controls, meta = meta, worldCopies = options.worldCopies or 1 }
    G.gc = function()
        local list = { body, controls, inventory, items, {} }
        for i = 1, G.worldCopies do
            if i == 1 then table.insert(list, world)
            else
                local copy = {}
                for k, v in pairs(world) do copy[k] = v end
                table.insert(list, copy)
            end
        end
        for _, h in ipairs(handlers) do table.insert(list, h) end
        for _, f in ipairs({ world.backpackNow, world.displayPut, world.useDoor, world.enter }) do table.insert(list, f) end
        return list
    end
    G.exec = {
        getgc = function() return G.gc() end,
        getupvalues = function(f) return meta.up[f] or {} end,
        debugInfo = function(f) return meta.names[f] end,
        sharedTables = {},
    }
    return G
end

return T
