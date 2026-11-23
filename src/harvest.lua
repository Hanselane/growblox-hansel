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
            pause(math.max(0.25, App.config.options.punchDelay), token)
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
            App.harvestWorlds[name] = "belum ada yang mateng; " .. summary
            return 0
        end
        local ids = { blockId, seedId, Drops.GEM }
        local trees, replanted = 0, 0
        for _, entry in ipairs(plan.rows) do
            local row = entry.row
            G.setStatus(string.format("Harvest %s (%d/%d): baris %d, %d pohon mateng...", name, index,
                #App.config.harvesting.worlds, row.y, #entry.points))
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
