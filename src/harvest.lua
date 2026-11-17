-- harvest.lua: panen pohon dengan Fist, diadaptasi dari Clarissv main.lua v0.1.43
-- (runTreeHarvest mode Fist, runHarvest, makeHarvestPlanter). Aturan Hansel:
--   1) World Scan dulu; 2) yang dipanen cuma pohon yang SUDAH mateng (Clarissv menunggu semua);
--   3) pukul pohon sambil collect: pickup bawaan game tetap nyala saat jalan, dan sisa drop
--      tiap baris dipungut sebelum pindah baris; 4) hasil disimpan ke Display Box farm;
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
        local work, ripe, growing, longest = {}, 0, 0, 0
        for _, row in ipairs(Core.farmRows(r.world, r.items)) do
            local points = {}
            local first, last = row.direction == 1 and row.left or row.right, row.direction == 1 and row.right or row.left
            for x = first, last, row.direction do
                if tileAt(x, row.y) == seedId then
                    local ready = resolver.ripe(x, row.y, seedId)
                    if ready then table.insert(points, { x = x, y = row.y }); ripe = ripe + 1
                    elseif ready == false then
                        growing = growing + 1
                        longest = math.max(longest, resolver.remaining(x, row.y, seedId) or 0)
                    end
                end
            end
            if #points > 0 then table.insert(work, { row = row, points = points }) end
        end
        return { rows = work, ripe = ripe, growing = growing, longest = longest, resolver = resolver }
    end

    -- Simpan blok (dan seed) hasil panen ke Display Box farm. keepSeeds = sisakan seed untuk replant.
    local function store(blockId, seedId, keepSeeds, token)
        local box = App.config.points.farmBox
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

    ---------------------------------------------------------------- keluar world & resume
    -- Setting "Rejoin world and return to PNB & Harvest": checkpoint harvest disimpan saat mulai
    -- dan tiap 2 menit, supaya setelah pindah server script dimuat ulang dan Harvest lanjut.
    local lastSave = -math.huge
    function Harvest.saveResume()
        G.State.saveCheckpoint("harvest", { world = App.config.points.farmBox.world })
        lastSave = os.clock()
    end
    function Harvest.clearResume() G.State.clearCheckpoint("harvest") end
    local function refreshResume()
        if App.config.options.autoRejoin and App.pending == 0 and os.clock() - lastSave >= 120 then
            local ok, issue = pcall(Harvest.saveResume)
            if not ok then App.harvestResumeError = tostring(issue) end
        end
    end

    function Harvest.run(token)
        local box, seedId = App.config.points.farmBox, App.config.harvesting.seedId
        local r = Bridge.runtime()
        if r.world.name ~= box.world or Bridge.pickerOpen(r) then
            G.setStatus("Masuk ke world farm " .. box.world .. "...")
            Movement.enterWorld(box.world, token, { label = "Harvest", resumeButton = "Harvest",
                save = App.config.options.autoRejoin and Harvest.saveResume or nil })
        end
        r = worldCheck(box.world, token)
        local blockId = Core.blockForSeed(r.items, seedId)
        Storage.count(box, blockId, seedId) -- tolak box yang berisi item lain sebelum mulai
        assert(type(r.handlers.hit) == "function", "Hook pukul (hit) tidak tersedia. Copy diagnostics.")
        local replantOn = App.config.harvesting.replant
        G.setStatus("Scan pohon di " .. box.world .. "...")
        local plan = Harvest.plan(r, seedId)
        App.harvestPlan = string.format("%s: %d mateng, %d tumbuh%s", box.world, plan.ripe, plan.growing,
            plan.growing > 0 and (", semua mateng dalam " .. duration(plan.longest)) or "")
        if plan.ripe == 0 then
            G.setStatus("Belum ada pohon mateng di " .. box.world .. ". " .. App.harvestPlan .. ".")
            return
        end
        local ids = { blockId, seedId, Drops.GEM }
        local trees, replanted = 0, 0
        for _, entry in ipairs(plan.rows) do
            local row = entry.row
            G.setStatus(string.format("Panen baris %d: %d pohon mateng...", row.y, #entry.points))
            for _, point in ipairs(entry.points) do
                checkpoint(token)
                refreshResume()
                -- Tas hampir penuh: simpan dulu ke box farm, lalu lanjut dari pohon ini.
                if r.inventory:room(blockId) < 10 or r.inventory:room(seedId) < 10 then
                    store(blockId, seedId, replantOn and math.min(count(seedId), 100) or 0, token)
                end
                if harvestTree(r, point, seedId, plan.resolver, token) then
                    trees = trees + 1
                    -- Pukul sambil collect: pungut hasil pohon ini dari tempat berdiri sebelum lanjut.
                    Drops.collectNear({ world = box.world, x = point.x, y = point.y }, ids, token, Drops.REACH)
                    if replantOn and replant(r, point, seedId, token) then replanted = replanted + 1 end
                end
            end
            -- Sisa drop di baris ini (yang tidak terambil otomatis saat jalan) dipungut sekarang.
            local mid = math.floor((row.left + row.right) / 2)
            Drops.collectArea({ world = box.world, x = mid, y = row.y }, ids, token,
                { radius = (row.right - row.left) / 2 + 1.5, up = 1.5, down = 1.25 })
        end
        store(blockId, seedId, 0, token)
        App.harvestPlan = App.harvestPlan .. string.format("; dipanen %d, ditanam ulang %d", trees, replanted)
        G.setStatus(string.format("Selesai: %d pohon dipanen%s. %s", trees,
            replantOn and (", " .. replanted .. " ditanam ulang") or "",
            plan.growing > 0 and (plan.growing .. " pohon masih tumbuh, mateng dalam " .. duration(plan.longest) .. ".") or "Semua pohon sudah dipanen."))
    end

    G.Jobs.register("harvest", {
        label = "Harvest",
        prepare = function(r)
            assert(r.body and r.controls and r.handlers and type(r.handlers.hit) == "function",
                "Hook pukul/gerak tidak tersedia. Copy diagnostics dari Settings.")
        end,
        -- Keluar world / avatar mati + setting Rejoin nyala: masuk lagi ke world farm, scan ulang,
        -- lanjut panen (aman: pohon yang sudah dipanen tidak terhitung lagi). Gagal 3x berturut-turut
        -- tanpa ada pohon yang berhasil dipanen di antaranya = berhenti.
        run = function(token)
            if App.config.options.autoRejoin then Harvest.saveResume(); Movement.queueResume() end
            local failures, treesAtFailure = 0, nil
            while true do
                local completed, problem = pcall(Harvest.run, token)
                if completed then break end
                checkpoint(token)
                problem = Movement.classifyFault(problem, token, App.config.points.farmBox.world)
                if not (type(problem) == "table" and problem.recoverable and App.config.options.autoRejoin) then
                    error(problem, 0)
                end
                local trees = App.stats.trees or 0
                if treesAtFailure ~= trees then failures = 0 end
                failures, treesAtFailure = failures + 1, trees
                assert(failures <= 3, "Harvest terganggu 3x tanpa kemajuan: " .. tostring(problem))
                App.harvestRejoins = (App.harvestRejoins or 0) + 1
                G.setStatus("Keluar dari world (" .. tostring(problem) .. "). Masuk lagi ke world farm dan lanjut harvest...")
            end
            Harvest.clearResume()
        end,
        clear = function() Harvest.clearResume() end,
    })
    -- Auto-resume setelah pindah server (loader dijalankan ulang lewat queue_on_teleport).
    table.insert(G.resumeHandlers, function()
        local record = G.State.loadCheckpoint("harvest")
        if not record or type(record.data) ~= "table" then return false end
        App.config, App.profile = record.config, Core.profileName(record.profile)
        G.Jobs.start("harvest", record.data)
        return true
    end)

    ---------------------------------------------------------------- tab Harvest
    function Harvest.buildTab(tab)
        local UI, State = G.UI, G.State
        local controls, lookup, syncing = {}, {}, true
        UI.addStatus(tab:Paragraph({ Title = "Status", Desc = App.status }))

        local function choices()
            local values, selected = {}, nil
            lookup = {}
            local r = App.runtime
            for id, info in pairs(App.scanTrees or {}) do
                local name = (r and r.items[id] and r.items[id].name or "Seed") .. " (" .. id .. ")"
                local label = string.format("%s - %d mateng / %d pohon", name, info.ripe, info.total)
                table.insert(values, label)
                lookup[label] = id
                if id == App.config.harvesting.seedId then selected = label end
            end
            table.sort(values)
            return values, selected
        end
        local function refreshChoices()
            local values, selected = choices()
            pcall(function() controls.crop:Refresh(values) end)
            if selected then pcall(function() controls.crop:Select(selected) end) end
        end
        function Harvest.refreshTab()
            UI.paragraph(controls.box, "Display Box farm", Storage.pointText(App.config.points.farmBox))
            UI.paragraph(controls.plan, "Rencana panen", App.harvestPlan or "Scan world dulu.")
        end

        Scan.buildTab(tab, function() refreshChoices(); Harvest.refreshTab() end)
        pcall(function() tab:Section({ Title = "Harvest (Fist)" }) end)
        controls.crop = tab:Dropdown({ Title = "Tanaman yang dipanen", Desc = "Muncul setelah Scan world.", Values = {},
            Callback = function(value)
                if syncing then return end
                if type(value) == "table" then value = value[1] end
                local ok, message = pcall(function()
                    Net.idle()
                    App.config.harvesting.seedId = assert(lookup[value], "Pilih tanaman.")
                    State.saveSession()
                end)
                if not ok then G.notify(tostring(message)) end
            end })
        controls.box = tab:Paragraph({ Title = "Display Box farm", Desc = "Belum diset" })
        tab:Button({ Title = "Set farm Display Box here", Desc = "Berdiri di samping Display Box di world farm. Hasil panen disimpan di sini.",
            Callback = UI.action(function()
                local box = Storage.captureNearby("farmBox", "box")
                Harvest.refreshTab()
                G.setStatus("Display Box farm disimpan: " .. box.world .. " tile " .. box.x .. ", " .. box.y .. ".")
            end) })
        controls.replant = tab:Toggle({ Title = "Replant during harvest", Value = App.config.harvesting.replant,
            Desc = "Tile yang baru dipanen langsung ditanam lagi pakai seed di tas (termasuk seed hasil panen). Seed habis = panen tetap lanjut.",
            Callback = function(value)
                if syncing then return end
                local ok, message = pcall(function()
                    Net.idle()
                    App.config.harvesting.replant = value == true
                    State.saveSession()
                end)
                if not ok then G.notify(tostring(message)) end
            end })
        controls.plan = tab:Paragraph({ Title = "Rencana panen", Desc = "Scan world dulu." })
        G.Jobs.toggles.harvest = tab:Toggle({ Title = "Harvest", Value = false,
            Desc = "Scan, panen pohon yang sudah mateng (zigzag dari atas), pungut hasil, simpan ke Display Box farm.",
            Callback = function(enabled) G.Jobs.setRunning("harvest", enabled) end })
        syncing = false
        Harvest.refreshTab()
        table.insert(G.onConnected, function() pcall(Harvest.refreshTab) end)
    end

    return Harvest
end
