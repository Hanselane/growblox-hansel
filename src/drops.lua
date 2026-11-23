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
