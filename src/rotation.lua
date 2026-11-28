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
