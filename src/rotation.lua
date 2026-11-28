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
    local SEED_KEEP = 100 -- seed yang disisakan di tas saat simpan di tengah putaran (buat replant)

    ---------------------------------------------------------------- checkpoint / resume
    local resumePoint = G.Jobs.checkpointer("rotation", function() return { worldIndex = App.rotationIndex or 1 } end)
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
    local function seedOverflow(r, box, blockId, seedId, token, pending, back)
        if r.inventory:room(seedId) >= 10 then return end
        info("Seed hampir penuh: replant dulu...")
        local order = Rotation.replantOrder(r, pending or {}, back and back.y)
        if #order > 0 then Rotation.replantTiles(r, order, seedId, token) end
        refreshInventory(token)
        if r.inventory:room(seedId) < 10 then
            Rotation.storeSeeds(blockId, seedId, math.min(count(seedId), SEED_KEEP), token, box)
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
    -- 3) tile kosong lain di farm yang bisa ditanam (zigzag). Tanpa duplikat.
    function Rotation.replantOrder(r, pending, currentY)
        local all = Core.plantingTiles(r.world, r.items, Core.farmRows(r.world, r.items))
        local list, seen = {}, {}
        local function add(point)
            local key = point.x .. ":" .. point.y
            if not seen[key] and Core.plantingTile(r.world, r.items, point.x, point.y) then
                seen[key] = true
                table.insert(list, { x = point.x, y = point.y })
            end
        end
        for _, point in ipairs(all) do if currentY and point.y < currentY then add(point) end end
        for _, point in ipairs(pending) do add(point) end
        for _, point in ipairs(all) do add(point) end
        return list
    end

    -- Tanam ulang tile kosong di daftar (urut). Seed habis = berhenti; sisanya dicoba putaran berikutnya.
    function Rotation.replantTiles(r, tiles, seedId, token)
        local planted, left = 0, {}
        for index, point in ipairs(tiles) do
            checkpoint(token)
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

    -- Satu world: putaran harvest -> PNB -> replant sampai tidak ada pohon mateng.
    -- Return: jumlah pohon dipanen di world ini, dan detik sampai pohon tercepat berikutnya mateng.
    function Rotation.runWorld(index, token)
        local cfg = App.config.rotation
        local name, target = cfg.worlds[index], cfg.blockTarget
        App.rotationIndex = index
        Rotation.saveResume()
        -- Masuk + scan otomatis: tanaman = seed terbanyak di world, Display Box dicari otomatis.
        -- Box tidak wajib: tanpa box yang cocok, rotasi tetap jalan; seed sisa tetap di tas.
        local setup, why = timed("masuk & scan world", 1, Harvest.setupWorld, name, token,
            string.format("Rotasi %d/%d", index, #cfg.worlds), Rotation.saveResume, false)
        App.rotationWorlds = App.rotationWorlds or {}
        if not setup then
            App.rotationWorlds[name] = "dilewati: " .. why
            info("Rotasi: " .. name .. " dilewati (" .. why .. ").")
            return 0, nil, true
        end
        local r, seedId, blockId, box = setup.r, setup.seedId, setup.blockId, setup.box
        App.rotationBoxNote = setup.boxProblem and (name .. ": tanpa Display Box (" .. setup.boxProblem .. "); seed sisa tetap di tas") or nil
        local ids = { blockId, seedId, Drops.GEM }
        local total, pending, plan = 0, {}, nil
        local stats = { harvested = 0, pnb = 0, replanted = 0 }
        -- extra = pohon yang tetap dipanen walau blok sudah >= target. Dipakai kalau PNB tidak
        -- menemukan tile kosong di samping: panen 2 pohon lagi supaya ada tile kosong untuk PNB.
        local extra = 0
        -- dipakai juga untuk laporan; diulang dari scan setelah error tidak menghapus hitungan putaran ini
        local function progress(phase)
            info(string.format("Rotasi %s (%d/%d) - %s | dipanen %d, PNB %d blok, ditanam ulang %d",
                name, index, #cfg.worlds, phase, stats.harvested, stats.pnb, stats.replanted))
        end
        while true do
            checkpoint(token)
            pause(0.05, token) -- selalu beri jeda: loop ini tidak boleh muter tanpa henti
            refreshResume()
            refreshInventory(token)
            -- 1) scan + HARVEST sampai blok di tas mencapai target
            plan = Harvest.plan(r, seedId)
            local harvested = {}
            local function full() return count(blockId) >= target and extra <= 0 end
            if not full() then
                progress("harvest (" .. plan.ripe .. " pohon mateng)")
                local harvestStart = os.clock()
                for _, entry in ipairs(plan.rows) do
                    for _, point in ipairs(entry.points) do
                        if full() then break end
                        checkpoint(token)
                        refreshResume()
                        seedOverflow(r, box, blockId, seedId, token, harvested, nil)
                        local got = false
                        local ok = soft(token, name, function()
                            got = Harvest.harvestTree(r, point, seedId, plan.resolver, token)
                        end)
                        if ok and got then
                            soft(token, name, function()
                                Drops.collectNear({ world = name, x = point.x, y = point.y }, ids, token, Drops.reach())
                            end)
                            table.insert(harvested, point)
                            stats.harvested = stats.harvested + 1
                            if count(blockId) >= target then extra = extra - 1 end
                        end
                    end
                    if full() then break end
                end
                -- sisa drop di sekitar pohon yang barusan dipanen
                if #harvested > 0 then
                    local last = harvested[#harvested]
                    Drops.collectArea({ world = name, x = last.x, y = last.y }, ids, token, { radius = 4, up = 1.5, down = 1.25 })
                end
                local entry = App.phaseTime.harvest or { seconds = 0, units = 0 }
                entry.seconds, entry.units = entry.seconds + (os.clock() - harvestStart), entry.units + #harvested
                App.phaseTime.harvest = entry
            end
            total = total + #harvested
            for _, point in ipairs(harvested) do table.insert(pending, point) end
            if #harvested == 0 and count(blockId) == 0 and #pending == 0 then break end
            -- 2) PNB di tempat berhenti sampai blok habis
            local didPnb = false
            if count(blockId) > 0 then
                local before = count(blockId)
                progress("PNB")
                local side = timed("PNB", function() return before - count(blockId) end,
                    Rotation.pnbHere, r, box, blockId, seedId, token, harvested, pending)
                if side then
                    table.insert(pending, side)
                    stats.pnb = stats.pnb + (before - count(blockId))
                    extra = 0
                    didPnb = true
                elseif plan.ripe > #harvested then
                    extra = 2 -- tidak ada tile kosong: panen 2 pohon lagi biar ada tempat PNB
                else
                    info("Blok tidak bisa di-PNB (tidak ada tile kosong & pohon mateng habis); blok tetap di tas.")
                end
            end
            -- 3) REPLANT tile yang dipanen (+ tile PNB), sampai ketemu pohon mateng berikutnya
            local currentY = harvested[#harvested] and harvested[#harvested].y or standing().y
            local order = Rotation.replantOrder(r, pending, currentY)
            if #order > 0 and count(seedId) > 0 then
                progress("replant " .. #order .. " tile (atas -> bekas panen -> sisa farm)")
                local planted = timed("replant", function(n) return n end, Rotation.replantTiles, r, order, seedId, token)
                stats.replanted = stats.replanted + planted
            end
            -- Tile yang belum kebagian seed tidak dibawa sebagai prioritas: putaran berikutnya
            -- bekas panen terbaru didahulukan, sisanya tertangkap lagi di langkah "sisa farm".
            pending = {}
            -- tidak ada pohon mateng lagi di world ini (atau tidak ada yang bisa dipanen sama sekali)
            -- berhenti kalau pohon mateng habis, atau putaran ini tidak mengubah apa pun
            if plan.ripe == 0 or (#harvested == 0 and not didPnb and extra <= 0) then break end
        end
        -- 4) simpan seed sisa (dan blok kalau masih ada) ke Display Box world ini
        progress("simpan seed sisa ke Display Box")
        timed("simpan seed", 0, Rotation.storeSeeds, blockId, seedId, 0, token, box)
        plan = Harvest.plan(r, seedId)
        App.rotationWorlds, App.rotationTotals = App.rotationWorlds or {}, App.rotationTotals or {}
        local sum = App.rotationTotals[name] or { harvested = 0, pnb = 0, replanted = 0 }
        for key in pairs(sum) do sum[key] = sum[key] + stats[key] end
        App.rotationTotals[name] = sum
        App.rotationWorlds[name] = string.format("total dipanen %d, PNB %d blok, ditanam ulang %d | %d tile belum ditanam, %d tumbuh%s",
            sum.harvested, sum.pnb, sum.replanted, #Core.plantingTiles(r.world, r.items), plan.growing,
            plan.soonest and (", tercepat mateng " .. Harvest.duration(plan.soonest)) or "")
        return total, plan.soonest
    end

    function Rotation.run(token, saved)
        local cfg = App.config.rotation
        local index = saved and saved.worldIndex or 1
        if index > #cfg.worlds then index = 1 end
        while true do
            local harvested, soonest, skipped = 0, nil, {}
            for i = index, #cfg.worlds do
                local got, soon, skip = Rotation.runWorld(i, token)
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
