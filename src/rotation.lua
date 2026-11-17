-- rotation.lua: Rotation khusus Hansel (bukan Full Rotation Clarissv). Per world di list rotasi:
--   1) masuk world, scan pohon;
--   2) HARVEST pohon mateng (zigzag dari atas) sampai blok di tas mencapai target (bawaan 180);
--   3) PNB di tempat berhenti: 1 tile kosong di samping (kanan dulu, lalu kiri), sampai blok habis;
--   4) REPLANT tile yang tadi dipanen (+ tile PNB), lalu kembali ke 2 sampai tidak ada pohon mateng;
--   5) simpan seed sisa (dan blok kalau tas penuh) ke Display Box world itu, lalu world berikutnya.
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
    local lastSave = -math.huge
    function Rotation.saveResume()
        State.saveCheckpoint("rotation", { worldIndex = App.rotationIndex or 1 })
        lastSave = os.clock()
    end
    function Rotation.clearResume() State.clearCheckpoint("rotation") end
    local function refreshResume()
        if App.config.options.autoRejoin and App.pending == 0 and os.clock() - lastSave >= 120 then
            local ok, issue = pcall(Rotation.saveResume)
            if not ok then App.rotationResumeError = tostring(issue) end
        end
    end

    local function info(text)
        App.rotationInfo = text
        G.setStatus(text)
    end
    local function standing()
        local state = position()
        return { world = Bridge.runtime().world.name, x = math.floor(state.x), y = math.floor(state.y - 0.01) }
    end

    -- Seed hampir penuh di tas: simpan kelebihannya ke box world ini, lalu balik ke `back`.
    local function roomCheck(r, box, blockId, seedId, back, token)
        if r.inventory:room(seedId) < 10 or r.inventory:room(blockId) < 5 then
            Harvest.store(blockId, seedId, math.min(count(seedId), SEED_KEEP), token, box)
            if back then Movement.moveTo(back.x, back.y, back.world, token) end
        end
    end

    -- PNB di tempat berhenti panen: 1 tile kosong di samping (kanan dulu, lalu kiri).
    -- Return: tile yang dipakai (ikut di-replant nanti), atau nil kalau tidak ada tile kosong.
    function Rotation.pnbHere(r, box, blockId, seedId, token)
        local here = standing()
        local side
        for _, dx in ipairs({ 1, -1 }) do
            local x = here.x + dx
            if x >= 0 and x < r.world.w and tileAt(x, here.y) == 0 and r.handlers.canPlace(r.items[blockId], x, here.y) then
                side = { x = x, y = here.y }
                break
            end
        end
        if not side then
            info("Tidak ada tile kosong di samping untuk PNB; blok disimpan ke Display Box.")
            Harvest.store(blockId, seedId, count(seedId), token, box)
            return nil
        end
        local ids = { blockId, seedId, Drops.GEM }
        info(string.format("PNB di %d,%d (tile %s): %d blok...", here.x, here.y, side.x > here.x and "kanan" or "kiri", count(blockId)))
        while count(blockId) > 0 do
            checkpoint(token)
            refreshResume()
            roomCheck(r, box, blockId, seedId, here, token)
            if tileAt(side.x, side.y) == 0 then Pnb.placeTile(here, side, blockId, token) end
            if tileAt(side.x, side.y) == blockId then Pnb.breakTile(here, side, blockId, token) end
            Drops.collectNear(here, ids, token, Drops.REACH)
            assert(tileAt(side.x, side.y) == 0 or tileAt(side.x, side.y) == blockId,
                "Tile PNB rotasi terisi item lain di " .. side.x .. ", " .. side.y .. ".")
        end
        return side
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
        local name, seedId, target = cfg.worlds[index], cfg.seedId, cfg.blockTarget
        local box = cfg.boxes[name]
        App.rotationIndex = index
        if App.config.options.autoRejoin then Rotation.saveResume() end
        local r = Bridge.runtime()
        if r.world.name ~= name or Bridge.pickerOpen(r) then
            info(string.format("Rotasi world %d/%d: masuk %s...", index, #cfg.worlds, name))
            Movement.enterWorld(name, token, { label = "Rotation", resumeButton = "Rotation",
                save = App.config.options.autoRejoin and Rotation.saveResume or nil })
        end
        r = worldCheck(name, token)
        local blockId = Core.blockForSeed(r.items, seedId)
        G.Storage.count(box, blockId, seedId) -- box harus kosong / berisi blok & seed tanaman ini saja
        local ids = { blockId, seedId, Drops.GEM }
        local total, pending, plan = 0, {}, nil
        local stats = { harvested = 0, pnb = 0, replanted = 0 }
        local function progress(phase)
            info(string.format("Rotasi %s (%d/%d) - %s | dipanen %d, PNB %d blok, ditanam ulang %d",
                name, index, #cfg.worlds, phase, stats.harvested, stats.pnb, stats.replanted))
        end
        while true do
            checkpoint(token)
            refreshResume()
            refreshInventory(token)
            -- 1) scan + HARVEST sampai blok di tas mencapai target
            plan = Harvest.plan(r, seedId)
            local harvested = {}
            if count(blockId) < target then
                progress("harvest (" .. plan.ripe .. " pohon mateng)")
                for _, entry in ipairs(plan.rows) do
                    for _, point in ipairs(entry.points) do
                        if count(blockId) >= target then break end
                        checkpoint(token)
                        refreshResume()
                        roomCheck(r, box, blockId, seedId, nil, token)
                        if Harvest.harvestTree(r, point, seedId, plan.resolver, token) then
                            Drops.collectNear({ world = name, x = point.x, y = point.y }, ids, token, Drops.REACH)
                            table.insert(harvested, point)
                            stats.harvested = stats.harvested + 1
                        end
                    end
                    if count(blockId) >= target then break end
                end
                -- sisa drop di sekitar pohon yang barusan dipanen
                if #harvested > 0 then
                    local last = harvested[#harvested]
                    Drops.collectArea({ world = name, x = last.x, y = last.y }, ids, token, { radius = 4, up = 1.5, down = 1.25 })
                end
            end
            total = total + #harvested
            for _, point in ipairs(harvested) do table.insert(pending, point) end
            if #harvested == 0 and count(blockId) == 0 and #pending == 0 then break end
            -- 2) PNB di tempat berhenti sampai blok habis
            if count(blockId) > 0 then
                local before = count(blockId)
                progress("PNB")
                local side = Rotation.pnbHere(r, box, blockId, seedId, token)
                if side then
                    table.insert(pending, side)
                    stats.pnb = stats.pnb + before
                end
            end
            -- 3) REPLANT tile yang dipanen (+ tile PNB), sampai ketemu pohon mateng berikutnya
            if #pending > 0 then
                progress("replant " .. #pending .. " tile")
                local planted, left = Rotation.replantTiles(r, pending, seedId, token)
                stats.replanted = stats.replanted + planted
                pending = left
            end
            -- tidak ada pohon mateng lagi di world ini (atau tidak ada yang bisa dipanen sama sekali)
            if plan.ripe == 0 or (#harvested == 0 and count(blockId) == 0) then break end
        end
        -- 4) simpan seed sisa (dan blok kalau masih ada) ke Display Box world ini
        progress("simpan sisa ke Display Box")
        Harvest.store(blockId, seedId, 0, token, box)
        plan = Harvest.plan(r, seedId)
        App.rotationWorlds, App.rotationTotals = App.rotationWorlds or {}, App.rotationTotals or {}
        local sum = App.rotationTotals[name] or { harvested = 0, pnb = 0, replanted = 0 }
        for key in pairs(sum) do sum[key] = sum[key] + stats[key] end
        App.rotationTotals[name] = sum
        App.rotationWorlds[name] = string.format("total dipanen %d, PNB %d blok, ditanam ulang %d | %d tile belum ditanam, %d tumbuh%s",
            sum.harvested, sum.pnb, sum.replanted, #pending, plan.growing,
            plan.soonest and (", tercepat mateng " .. Harvest.duration(plan.soonest)) or "")
        return total, plan.soonest
    end

    function Rotation.run(token, saved)
        local cfg = App.config.rotation
        local index = saved and saved.worldIndex or 1
        if index > #cfg.worlds then index = 1 end
        while true do
            local harvested, soonest = 0, nil
            for i = index, #cfg.worlds do
                local got, soon = Rotation.runWorld(i, token)
                harvested = harvested + got
                if soon then soonest = math.min(soonest or soon, soon) end
            end
            index = 1
            App.rotationLaps = (App.rotationLaps or 0) + 1
            if harvested == 0 then
                -- Satu putaran penuh tanpa panen: tunggu pohon tercepat mateng (maks 10 menit).
                local wait = math.max(5, math.min(soonest or 60, 600))
                local deadline = os.clock() + wait
                while os.clock() < deadline do
                    info("Rotasi: belum ada pohon mateng di semua world. Cek lagi dalam "
                        .. Harvest.duration(deadline - os.clock()) .. ".")
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
        -- Keluar world / avatar mati + Rejoin nyala: masuk lagi ke world rotasi yang sedang dikerjakan
        -- dan lanjut dari scan. Gagal 3x berturut-turut tanpa kemajuan = berhenti.
        run = function(token, saved)
            if App.config.options.autoRejoin then Movement.queueResume() end
            local failures, mark = 0, nil
            local resume = saved
            while true do
                local completed, problem = pcall(Rotation.run, token, resume)
                if completed then break end
                checkpoint(token)
                local name = App.config.rotation.worlds[App.rotationIndex or 1]
                problem = Movement.classifyFault(problem, token, name)
                if not (type(problem) == "table" and problem.recoverable and App.config.options.autoRejoin) then
                    error(problem, 0)
                end
                local now = (App.stats.trees or 0) + (App.stats.broken or 0)
                if mark ~= now then failures = 0 end
                failures, mark = failures + 1, now
                assert(failures <= 3, "Rotation terganggu 3x tanpa kemajuan: " .. tostring(problem))
                App.rotationRejoins = (App.rotationRejoins or 0) + 1
                resume = { worldIndex = App.rotationIndex or 1 }
                info("Keluar dari world (" .. tostring(problem) .. "). Masuk lagi dan lanjut rotasi...")
            end
        end,
        clear = function() Rotation.clearResume() end,
    })
    table.insert(G.resumeHandlers, 1, function()
        local record = State.loadCheckpoint("rotation")
        if not record or type(record.data) ~= "table" or type(record.data.worldIndex) ~= "number" then return false end
        App.config, App.profile = record.config, Core.profileName(record.profile)
        G.Jobs.start("rotation", record.data)
        return true
    end)

    ---------------------------------------------------------------- tab Rotation
    function Rotation.buildTab(tab)
        local UI, Scan, Storage = G.UI, G.Scan, G.Storage
        local controls, lookup, syncing = {}, {}, true
        UI.addStatus(tab:Paragraph({ Title = "Status", Desc = App.status }))
        tab:Paragraph({ Title = "Cara kerja", Desc = "Per world di list: scan -> harvest pohon mateng sampai blok di tas = target -> PNB di 1 tile kosong di samping sampai blok habis -> replant tile yang dipanen -> ulangi sampai tidak ada pohon mateng -> simpan sisa ke Display Box world itu -> world berikutnya (muter)." })
        local function setOption(fn)
            if syncing then return end
            local ok, message = pcall(function() Net.idle(); fn(); State.saveSession() end)
            if not ok then G.notify(tostring(message)) end
        end
        local function choices()
            local values, selected = {}, nil
            lookup = {}
            local r = App.runtime
            for id, tree in pairs(App.scanTrees or {}) do
                local label = string.format("%s (%d) - %d mateng / %d pohon", r and r.items[id] and r.items[id].name or "Seed", id, tree.ripe, tree.total)
                table.insert(values, label)
                lookup[label] = id
                if id == App.config.rotation.seedId then selected = label end
            end
            table.sort(values)
            return values, selected
        end
        function Rotation.refreshTab()
            local cfg, lines = App.config.rotation, {}
            for i, name in ipairs(cfg.worlds) do
                local box = cfg.boxes[name]
                table.insert(lines, string.format("%d. %s: %s%s", i, name, box and ("box " .. box.x .. ", " .. box.y) or "BELUM ADA BOX",
                    App.rotationWorlds and App.rotationWorlds[name] and (" | " .. App.rotationWorlds[name]) or ""))
            end
            UI.paragraph(controls.list, "World rotasi", #lines > 0 and table.concat(lines, "\n") or "Belum ada world.")
        end
        Scan.buildTab(tab, function()
            local values, selected = choices()
            pcall(function() controls.crop:Refresh(values) end)
            if selected then pcall(function() controls.crop:Select(selected) end) end
        end)
        pcall(function() tab:Section({ Title = "Rotation" }) end)
        controls.worlds = tab:Input({ Title = "World farm rotasi (urut)", Value = table.concat(App.config.rotation.worlds, ", "),
            Placeholder = "FARM1, FARM2, FARM3", Desc = "Terpisah dari list world Planting. Pisahkan dengan koma.",
            Callback = function(value)
                setOption(function() App.config.rotation.worlds = Core.parseWorlds(value or "") end)
                Rotation.refreshTab()
            end })
        controls.crop = tab:Dropdown({ Title = "Tanaman rotasi", Desc = "Muncul setelah Scan world.", Values = {},
            Callback = function(value)
                if type(value) == "table" then value = value[1] end
                setOption(function() App.config.rotation.seedId = assert(lookup[value], "Pilih tanaman.") end)
            end })
        tab:Slider({ Title = "Harvest sampai blok di tas", Step = 1,
            Value = { Min = 10, Max = 200, Default = App.config.rotation.blockTarget },
            Callback = function(value) setOption(function() App.config.rotation.blockTarget = math.floor(tonumber(value)) end) end })
        tab:Button({ Title = "Set Display Box world ini", Desc = "Masuk tiap world di list, berdiri di samping Display Box-nya, tekan ini. Seed sisa & blok disimpan di sini.",
            Callback = UI.action(function()
                local box = Storage.captureNearby("rotationBox", "box")
                App.config.points.rotationBox = nil
                App.config.rotation.boxes[box.world] = box
                Rotation.refreshTab()
                G.setStatus("Display Box rotasi untuk " .. box.world .. " disimpan: tile " .. box.x .. ", " .. box.y .. ".")
            end) })
        controls.list = tab:Paragraph({ Title = "World rotasi", Desc = "Belum ada world." })
        G.Jobs.toggles.rotation = tab:Toggle({ Title = "Rotation", Value = false,
            Desc = "Jalan terus sampai di-stop. Mulai dari world pertama di list.",
            Callback = function(enabled) G.Jobs.setRunning("rotation", enabled) end })
        syncing = false
        Rotation.refreshTab()
        table.insert(G.onConnected, function() pcall(Rotation.refreshTab) end)
    end

    return Rotation
end
