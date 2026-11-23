-- pnb.lua: Place & Break dengan grid 5x5 (layout terinspirasi Crusader), stock & seed lewat Display Box,
-- dan Auto Collect.
-- placeTile/breakTile/settleTile diadaptasi dari Clarissv main.lua v0.1.43; bedanya grid bisa
-- sampai 24 tile di sekitar karakter, dan tile yang terisi blok lain dilewati, bukan error.
return function(G)
    local App, Core, Bridge, Net, Actions, Movement, Drops, State, task =
        G.App, G.Core, G.Bridge, G.Net, G.Actions, G.Movement, G.Drops, G.State, G.task
    local Pnb = {}
    local worldCheck, position, checkpoint, pause = Bridge.worldCheck, Bridge.position, Net.checkpoint, Net.pause
    local count, tileAt, refreshInventory = Actions.count, Actions.tileAt, Actions.refreshInventory

    ---------------------------------------------------------------- posisi
    -- Tile berdiri karakter sekarang: x = kolom, y = baris tempat badan (kaki di y + 1).
    function Pnb.standingTile()
        local r, state = Bridge.runtime(), position()
        assert(state.grounded, "Berdiri di lantai dulu, jangan sambil lompat.")
        return { world = r.world.name, x = math.floor(state.x), y = math.floor(state.y - 0.01) }
    end
    -- Tile absolut dari daftar offset, urut atas ke bawah, kiri ke kanan.
    function Pnb.targets(anchor)
        local list = {}
        for _, tile in ipairs(Core.sortPNBTiles(Core.validatePNBTiles(App.config.pnb.tiles))) do
            table.insert(list, { x = anchor.x + tile.dx, y = anchor.y + tile.dy })
        end
        return list
    end
    local function atAnchor(anchor)
        local state = position()
        return state.grounded and math.abs(state.x - (anchor.x + 0.5)) < 0.3 and math.abs(state.y - (anchor.y + 1)) < 0.3
    end
    local function ensureAnchor(anchor, token)
        if not atAnchor(anchor) then Movement.moveTo(anchor.x, anchor.y, anchor.world, token) end
    end
    -- Karakter terdorong/terangkat dari spot (seperti di Clarissv: dipulihkan, bukan stop).
    -- Tunggu sebentar kalau masih di udara, lalu jalan balik ke spot. Terlalu sering = stop.
    local recoveries = {}
    local function holdAnchor(anchor, token)
        if atAnchor(anchor) then return end
        local settle = os.clock() + 0.6
        while os.clock() < settle and not atAnchor(anchor) do pause(0.05, token) end
        if atAnchor(anchor) then return end
        local now = os.clock()
        table.insert(recoveries, now)
        while recoveries[1] and now - recoveries[1] > 60 do table.remove(recoveries, 1) end
        assert(#recoveries <= 10, "Karakter terus bergeser dari posisi PNB (10x dalam 1 menit). Cek apa yang mendorong karakter.")
        App.pnbRecoveries = (App.pnbRecoveries or 0) + 1
        G.setStatus("Karakter bergeser; kembali ke posisi PNB...")
        local hold = Movement.takeControls()
        hold.direction, hold.jump = 0, false
        Movement.moveTo(anchor.x, anchor.y, anchor.world, token)
    end

    ---------------------------------------------------------------- place & break
    local function settleTile(x, y, id, seconds, worldName, token)
        local deadline = os.clock() + seconds
        repeat
            worldCheck(worldName, token)
            assert(tileAt(x, y) == id, "Tile " .. x .. ", " .. y .. " changed while the action settled. Stopping.")
            pause(0.03, token)
        until os.clock() >= deadline
    end

    -- Taruh satu blok, lalu tunggu server benar-benar mengurangi blok di tas.
    local function placeTile(anchor, point, id, token)
        return Movement.withoutPickups(function()
            local r = worldCheck(anchor.world, token)
            holdAnchor(anchor, token)
            local before = refreshInventory(token)[id] or 0
            worldCheck(anchor.world, token)
            if tileAt(point.x, point.y) ~= 0 then return false end
            assert(r.handlers.canPlace(r.items[id], point.x, point.y),
                "Cannot place at " .. point.x .. ", " .. point.y .. ". Check reach, access, and empty tiles.")
            assert(before > 0, "No blocks are left in your backpack.")
            r.handlers.setTile("fg", point.x, point.y, id, false, (position().facing or 1) < 0)
            App.lastPlacement = { x = point.x, y = point.y, world = anchor.world, grid = r.world.fg, at = os.clock() }
            r.inventory:remove(id, 1)
            pause(App.config.options.placeDelay, token)
            local deadline = os.clock() + App.config.options.actionTimeout
            while true do
                worldCheck(anchor.world, token)
                local after = refreshInventory(token)[id] or 0
                if after == before - 1 then break end
                assert(after == before, "Backpack changed unexpectedly while placing. Stopping.")
                assert(os.clock() < deadline, "The server did not consume a block for tile "
                    .. point.x .. ", " .. point.y .. ". Check placement access and range.")
                pause(0.15, token)
            end
            settleTile(point.x, point.y, id, 0.12, anchor.world, token)
            return true
        end)
    end

    -- Pukul sampai pecah. Jeda antar pukulan = Hit delay (punchDelay).
    local function breakTile(anchor, point, id, token)
        local r = worldCheck(anchor.world, token)
        assert(tileAt(point.x, point.y) == id, "The target tile changed. Stopping before punching another block.")
        local deadline = os.clock() + App.config.options.actionTimeout + (r.items[id].hits or 1) * App.config.options.punchDelay
        local placed = App.lastPlacement
        if placed and placed.world == anchor.world and placed.grid == r.world.fg and placed.x == point.x and placed.y == point.y then
            local remaining = 0.32 - (os.clock() - placed.at) -- blok baru ditaruh butuh waktu sebelum bisa dipukul
            if remaining > 0 then pause(remaining, token) end
        end
        while tileAt(point.x, point.y) == id do
            worldCheck(anchor.world, token)
            if not atAnchor(anchor) then
                holdAnchor(anchor, token)
                deadline = os.clock() + App.config.options.actionTimeout -- waktu jalan balik tidak dihitung
            end
            assert(os.clock() < deadline, "Block did not break. Check permissions and your punching range.")
            r.handlers.hit(point.x, point.y)
            pause(App.config.options.punchDelay, token)
        end
        assert(tileAt(point.x, point.y) == 0, "The block changed while breaking.")
        settleTile(point.x, point.y, 0, math.max(0.18, App.config.options.punchDelay), anchor.world, token)
        App.stats.broken = App.stats.broken + 1
    end

    Pnb.placeTile, Pnb.breakTile = placeTile, breakTile -- dipakai Rotation

    -- Area pungut di sekitar grid 5x5: 2,75 tile ke samping, 3 ke atas, 2,5 ke bawah.
    local GRID_AREA = { radius = 2.75, up = 3, down = 2.5 }

    ---------------------------------------------------------------- stock & seed
    -- Ambil stock dari Display Box (sama seperti PNB Clarissv: "Refilling blocks from the right
    -- storage box", world.call("DisplayItem", x, y, nil)). Box berisi blok yang di-PNB saja.
    -- Return: jumlah blok yang diambil (0 = box kosong).
    function Pnb.takeStock(anchor, blockId, token)
        local box = App.config.points.stock
        G.setStatus("Mengambil stock blok dari Display Box...")
        local taken = G.Storage.withdraw(box, blockId, token)
        App.stockDebug = os.date("%H:%M:%S") .. " +" .. taken .. " blok dari box " .. box.x .. ", " .. box.y
        ensureAnchor(anchor, token)
        return taken
    end

    -- Auto drop seed = taruh seed ke Display Box (sama seperti PNB Clarissv: "Putting seeds into
    -- the left storage box", world.call("DisplayItem", ...)). Drop ke lantai tidak dipakai karena
    -- belum ada perintah server yang diketahui untuk itu.
    function Pnb.dropSeeds(anchor, seedId, token)
        local box = App.config.points.seedDrop
        G.setStatus("Menaruh seed ke Display Box...")
        G.Storage.deposit(box, seedId, count(seedId), token)
        refreshInventory(token)
        ensureAnchor(anchor, token)
    end

    -- Pungut hasil PNB: semua blok/seed/gem (atau semua item kalau Auto Collect nyala) di area
    -- grid 5x5. Tile di pinggir grid (2 tile dari karakter) di luar jangkauan server, jadi
    -- karakter melangkah ke sana, memungut, lalu kembali ke posisi PNB.
    local GRID_AREA = { radius = 2.75, up = 3, down = 2.5 }
    -- quick = true (tiap putaran PNB): kalau belum ada drop di area, lewati tanpa request apa pun.
    local function anyDrop(anchor, ids, area)
        local all, wanted = ids == "all", {}
        if not all then for _, id in ipairs(ids) do wanted[id] = true end end
        for _, drop in pairs(Bridge.runtime().world.dropList()) do
            if type(drop) == "table" and not drop.display and type(drop.n) == "number" and drop.n > 0
                and (all or wanted[drop.id]) and type(drop.x) == "number" and type(drop.y) == "number"
                and math.abs(drop.x - (anchor.x + 0.5)) <= area.radius
                and drop.y >= anchor.y - area.up and drop.y <= anchor.y + area.down then return true end
        end
        return false
    end
    function Pnb.collect(anchor, pickupIds, token, quick)
        local ids, area = pickupIds, GRID_AREA
        if App.config.options.autoCollect then
            local range = App.config.options.collectRange
            ids = "all"
            area = { radius = math.max(GRID_AREA.radius, range), up = math.max(GRID_AREA.up, range),
                down = math.max(GRID_AREA.down, range) }
        end
        if quick and not anyDrop(anchor, ids, area) then
            App.collectSkips = (App.collectSkips or 0) + 1
            return
        end
        local got = Drops.collectArea(anchor, ids, token, area)
        local n = 0
        for _, amount in pairs(got) do n = n + amount end
        App.pnbCollected = (App.pnbCollected or 0) + n
        ensureAnchor(anchor, token)
    end

    ---------------------------------------------------------------- Auto Collect (saat tidak ada task)
    -- Tiap 0.3 detik: kalau ada item di lantai dalam jangkauan karakter, pungut (tanpa jalan).
    -- Server Growblox menolak pungut dari jauh; drop yang ditolak 3x dilewati selama 15 detik.
    local autoAttempts, autoReset = {}, 0
    function Pnb.autoCollectTick()
        local options = App.config and App.config.options
        if not (App.alive and options and options.autoCollect) or App.job or App.pending > 0
            or App.configuring or App.autoCollectHold or App.teleporting then return false end
        if os.clock() > autoReset then autoAttempts, autoReset = {}, os.clock() + 15 end
        local okRuntime, r = pcall(Bridge.runtime)
        if not okRuntime or type(r) ~= "table" or not r.world or not r.inventory then return false end
        local okPos, state = pcall(position)
        if not okPos or type(state) ~= "table" then return false end
        local range = options.collectRange
        local here = { world = r.world.name, x = math.floor(state.x), y = math.floor(state.y - 0.01) }
        local any = false
        for _, drop in pairs(r.world.dropList()) do
            if not drop.display and not drop.taking and type(drop.uid) == "number" and type(drop.n) == "number"
                and drop.n > 0 and type(drop.x) == "number" and type(drop.y) == "number"
                and (autoAttempts[drop.uid] or 0) < 3
                and math.abs(drop.x - (here.x + 0.5)) <= range and drop.y >= here.y - range and drop.y <= here.y + range
                and (drop.id == Drops.GEM or r.inventory:room(drop.id) > 0) then any = true; break end
        end
        if not any then return false end
        App.autoCollecting = true
        local ok, got = pcall(Drops.collectNear, here, "all", nil, { radius = range, up = range, down = range,
            attempts = autoAttempts, stopIf = function() return App.autoCollectHold or App.job ~= nil or not App.alive end })
        App.autoCollecting = false
        if ok then
            local n = 0
            for _, amount in pairs(got or {}) do n = n + amount end
            if n > 0 then App.autoCollectInfo = "terakhir +" .. n .. " item" end
        else
            App.autoCollectInfo = "error: " .. tostring(got)
        end
        return ok
    end

    ---------------------------------------------------------------- rejoin & resume
    -- Adaptasi Clarissv v0.1.43: savePNBResume, refreshPNBCheckpoint, classifyPNBFault, recoverPNB.
    -- Setting "Rejoin world and return to PNB" (options.autoRejoin): kalau terlempar ke world picker,
    -- avatar mati/respawn, atau pindah server, masuk lagi ke world PNB lalu jalan balik ke spot.
    local resumePoint = G.Jobs.checkpointer("pnb", function() return { anchor = App.config.points.pnb } end)
    Pnb.saveResume, Pnb.clearResume = resumePoint.save, resumePoint.clear

    -- Masuk lagi ke world PNB (lewat world picker, bisa pindah server) lalu jalan ke spot.
    function Pnb.returnToSpot(token)
        local anchor = App.config.points.pnb
        App.recovering = true
        G.setStatus("Masuk lagi ke " .. anchor.world .. "...")
        Movement.enterWorld(anchor.world, token, { save = Pnb.saveResume, label = "Place & Break",
            resumeButton = "Place & Break" })
        Movement.takeControls()
        refreshInventory(token)
        G.setStatus("Jalan balik ke spot PNB...")
        Movement.moveTo(anchor.x, anchor.y, anchor.world, token)
        App.recovering = false
        G.setStatus("Sudah di spot PNB. Lanjut Place & Break...")
    end

    ---------------------------------------------------------------- loop utama
    function Pnb.run(token)
        local r = Bridge.runtime()
        local anchor, blockId = App.config.points.pnb, App.config.blockId
        local okSeed, seedId = pcall(Core.seedId, r.items, blockId)
        if not okSeed then seedId = nil end
        local pickupIds = { blockId, Drops.GEM }
        if seedId then table.insert(pickupIds, seedId) end
        worldCheck(anchor.world, token)
        ensureAnchor(anchor, token)
        if App.config.options.autoRejoin then Pnb.saveResume(); Movement.queueResume() end
        G.setStatus("PNB mulai di " .. anchor.world .. " (" .. anchor.x .. ", " .. anchor.y .. "), " .. #App.config.pnb.tiles .. " tile.")
        while true do
            checkpoint(token)
            worldCheck(anchor.world, token)
            resumePoint.refresh()
            holdAnchor(anchor, token)
            refreshInventory(token)
            if seedId and App.config.pnb.autoDrop and count(seedId) >= App.config.options.seedThreshold then
                Pnb.dropSeeds(anchor, seedId, token)
            end
            local targets, existing = Pnb.targets(anchor), false
            for _, point in ipairs(targets) do if tileAt(point.x, point.y) == blockId then existing = true end end
            if count(blockId) == 0 and not existing then
                Pnb.collect(anchor, pickupIds, token)
                if count(blockId) == 0 then
                    if App.config.pnb.autoStock then Pnb.takeStock(anchor, blockId, token) end
                    if not (App.config.pnb.autoStock and (refreshInventory(token)[blockId] or 0) > 0) then
                        G.setStatus(App.config.pnb.autoStock and "Selesai: Display Box stock kosong."
                            or "Selesai: blok di tas habis. Nyalakan Auto take stock untuk ambil dari Display Box.")
                        return
                    end
                end
            end
            G.setStatus("Placing " .. r.items[blockId].name .. "...")
            local worked = existing
            for _, point in ipairs(targets) do
                if count(blockId) == 0 then break end
                if tileAt(point.x, point.y) == 0 and placeTile(anchor, point, blockId, token) then worked = true end
            end
            G.setStatus("Breaking the selected blocks...")
            for _, point in ipairs(targets) do
                if tileAt(point.x, point.y) == blockId then breakTile(anchor, point, blockId, token) end
            end
            assert(worked, "Semua tile PNB terhalang blok lain. Kosongkan tile yang dipilih atau pilih tile lain.")
            G.setStatus("Collecting gems, seeds, and returned blocks...")
            Pnb.collect(anchor, pickupIds, token, true)
        end
    end

    G.Jobs.register("pnb", {
        label = "Place & Break",
        prepare = function(r, saved)
            assert(r.body and r.controls and r.handlers.setTile and r.handlers.hit and r.handlers.canPlace,
                "Hook place/break tidak tersedia. Copy diagnostics dari Settings.")
            -- Posisi PNB = tempat karakter berdiri saat toggle dinyalakan (seperti Crusader).
            -- Resume setelah pindah server: pakai spot dari checkpoint.
            if saved and saved.anchor then App.config.points.pnb = saved.anchor
            else App.config.points.pnb = Pnb.standingTile() end
        end,
        -- Sama seperti Clarissv: keluar world / avatar mati + setting Rejoin nyala = masuk lagi ke
        -- world, balik ke spot, lanjut PNB (Jobs.resilient). Gagal 3x tanpa kemajuan = berhenti.
        run = function(token, saved)
            G.Jobs.resilient(token, saved, {
                label = "Place & Break",
                world = function() return App.config.points.pnb.world end,
                progress = function() return App.stats.broken end,
                loop = function(loopToken, resume)
                    local anchor, r = App.config.points.pnb, Bridge.runtime()
                    if resume and (r.world.name ~= anchor.world or Bridge.pickerOpen(r) or resume.retry) then
                        Pnb.returnToSpot(loopToken)
                    end
                    Pnb.run(loopToken)
                end,
            })
            Pnb.clearResume()
        end,
        clear = function() Pnb.clearResume() end,
        resume = true, -- lanjut otomatis setelah pindah server
        validResume = function(data) return type(data.anchor) == "table" end,
    })

    ---------------------------------------------------------------- tab Place & Break
    local function tileSet()
        local set = {}
        for _, tile in ipairs(App.config.pnb.tiles) do set[tile.dx .. ":" .. tile.dy] = true end
        return set
    end
    -- Peta teks 5x5 untuk paragraf: [Y] = karakter, [#] = dipilih, [ ] = kosong.
    function Pnb.gridText()
        local set, lines = tileSet(), {}
        for dy = -2, 2 do
            local row = {}
            for dx = -2, 2 do
                row[#row + 1] = (dx == 0 and dy == 0) and "[Y]" or (set[dx .. ":" .. dy] and "[#]" or "[  ]")
            end
            lines[#lines + 1] = table.concat(row, " ")
        end
        return table.concat(lines, "\n")
    end
    function Pnb.toggleTile(dx, dy)
        Net.idle()
        if dx == 0 and dy == 0 then return end
        local tiles, removed = {}, false
        for _, tile in ipairs(App.config.pnb.tiles) do
            if tile.dx == dx and tile.dy == dy then removed = true else table.insert(tiles, tile) end
        end
        if not removed then table.insert(tiles, { dx = dx, dy = dy }) end
        App.config.pnb.tiles = Core.validatePNBTiles(tiles)
        State.saveSession()
        if Pnb.refreshTab then Pnb.refreshTab() end
    end

    -- Panel 5x5 melayang (Roblox GUI). Klik kotak = pilih/batal pilih tile; kotak tengah = karakter.
    function Pnb.openGridPanel()
        if Pnb.panel and Pnb.panel.Parent then Pnb.panel:Destroy(); Pnb.panel = nil; return end
        local new = G.newInstance
        local gui = new("ScreenGui")
        gui.Name, gui.ResetOnSpawn = "GrowbloxHanselPNBTiles", false
        local frame = new("Frame")
        frame.Size, frame.Position = G.UDim2.fromOffset(250, 300), G.UDim2.new(0.5, -125, 0.5, -150)
        frame.BackgroundColor3, frame.BorderSizePixel, frame.Active = G.Color3.fromRGB(30, 30, 36), 0, true
        frame.Parent = gui
        local title = new("TextLabel")
        title.Size, title.Position, title.BackgroundTransparency = G.UDim2.fromOffset(250, 30), G.UDim2.fromOffset(0, 0), 1
        title.Text, title.TextColor3, title.TextSize = "PNB tiles - klik untuk pilih", G.Color3.fromRGB(235, 235, 235), 14
        title.Parent = frame
        local buttons = {}
        local function paint()
            local set = tileSet()
            for key, button in pairs(buttons) do
                local selected = set[key]
                button.BackgroundColor3 = selected and G.Color3.fromRGB(70, 160, 90) or G.Color3.fromRGB(60, 60, 70)
                button.Text = selected and "#" or ""
            end
        end
        for dy = -2, 2 do
            for dx = -2, 2 do
                local button = new("TextButton")
                button.Size = G.UDim2.fromOffset(42, 42)
                button.Position = G.UDim2.fromOffset(15 + (dx + 2) * 45, 38 + (dy + 2) * 45)
                button.BorderSizePixel, button.TextColor3, button.TextSize = 0, G.Color3.fromRGB(255, 255, 255), 16
                button.Parent = frame
                if dx == 0 and dy == 0 then
                    button.Text, button.BackgroundColor3, button.AutoButtonColor = "You", G.Color3.fromRGB(70, 110, 190), false
                else
                    buttons[dx .. ":" .. dy] = button
                    button.MouseButton1Click:Connect(function()
                        local ok, message = pcall(Pnb.toggleTile, dx, dy)
                        if not ok then G.notify(tostring(message)) end
                        paint()
                    end)
                end
            end
        end
        local close = new("TextButton")
        close.Size, close.Position = G.UDim2.fromOffset(220, 30), G.UDim2.fromOffset(15, 262)
        close.Text, close.BackgroundColor3, close.TextColor3 = "Tutup", G.Color3.fromRGB(90, 50, 50), G.Color3.fromRGB(255, 255, 255)
        close.BorderSizePixel, close.Parent = 0, frame
        close.MouseButton1Click:Connect(function() gui:Destroy(); Pnb.panel = nil end)
        paint()
        gui.Parent = G.guiParent()
        Pnb.panel = gui
    end

    function Pnb.buildTab(tab)
        local UI = G.UI
        local controls, blockLookup, syncing = {}, {}, true

        local function refreshBlocks()
            if not App.runtime then return end
            local labels, selected = {}, nil
            blockLookup = {}
            for _, block in ipairs(Actions.farmableBlocks()) do
                local label = block.name .. " [" .. block.id .. "] x" .. count(block.id)
                table.insert(labels, label)
                blockLookup[label] = block.id
                if block.id == App.config.blockId then selected = label end
            end
            syncing = true
            pcall(function() controls.block:Refresh(labels) end)
            if selected then pcall(function() controls.block:Select(selected) end) end
            syncing = false
        end
        function Pnb.refreshTab()
            UI.paragraph(controls.grid, "PNB tiles", Pnb.gridText())
            UI.paragraph(controls.stock, "Stock (Display Box)", G.Storage.pointText(App.config.points.stock))
            UI.paragraph(controls.drop, "Seed drop (Display Box)", G.Storage.pointText(App.config.points.seedDrop))
        end
        local function setOption(fn)
            if syncing then return end
            local ok, message = pcall(function() Net.idle(); fn(); State.saveSession() end)
            if not ok then G.notify(tostring(message)) end
        end

        UI.addStatus(tab:Paragraph({ Title = "Status", Desc = App.status }))
        controls.block = tab:Dropdown({ Title = "Block in your backpack", Values = {}, SearchBarEnabled = true,
            Callback = function(value)
                if type(value) == "table" then value = value[1] end
                setOption(function() App.config.blockId = assert(blockLookup[value], "Pilih blok.") end)
            end })
        tab:Button({ Title = "Refresh block", Callback = UI.action(refreshBlocks) })
        G.Jobs.toggles.pnb = tab:Toggle({ Title = "Place & Break", Value = false,
            Desc = "Posisi PNB = tempat lo berdiri saat toggle dinyalakan.",
            Callback = function(enabled) G.Jobs.setRunning("pnb", enabled) end })
        tab:Slider({ Title = "Hit delay (detik)", Step = 0.01,
            Value = { Min = Core.LIMITS.punchDelay[1], Max = Core.LIMITS.punchDelay[2], Default = App.config.options.punchDelay },
            Callback = function(value) setOption(function() App.config.options.punchDelay = tonumber(value) end) end })

        pcall(function() tab:Section({ Title = "Auto Collect" }) end)
        controls.autoCollect = tab:Toggle({ Title = "Auto Collect", Value = App.config.options.autoCollect,
            Desc = "Pungut semua item (blok, seed, gem, dll.) di sekitar karakter. Jalan sendiri, juga ikut saat PNB.",
            Callback = function(enabled) setOption(function() App.config.options.autoCollect = enabled == true end) end })
        tab:Slider({ Title = "Jangkauan collect (tile)", Step = 0.5,
            Value = { Min = Core.LIMITS.collectRange[1], Max = Core.LIMITS.collectRange[2], Default = App.config.options.collectRange },
            Callback = function(value) setOption(function() App.config.options.collectRange = tonumber(value) end) end })

        pcall(function() tab:Section({ Title = "Stock" }) end)
        controls.stock = tab:Paragraph({ Title = "Stock (Display Box)", Desc = "Belum diset" })
        tab:Button({ Title = "Set stock position here", Desc = "Berdiri di samping Display Box berisi blok yang di-PNB.",
            Callback = UI.action(function()
                local box = G.Storage.captureNearby("stock", "box")
                Pnb.refreshTab()
                G.setStatus("Display Box stock disimpan: tile " .. box.x .. ", " .. box.y .. ".")
            end) })
        controls.autoStock = tab:Toggle({ Title = "Auto take stock", Value = App.config.pnb.autoStock,
            Desc = "Blok di tas habis: jalan ke Display Box stock, ambil blok, lalu lanjut PNB.",
            Callback = function(enabled) setOption(function() App.config.pnb.autoStock = enabled == true end) end })

        controls.drop = tab:Paragraph({ Title = "Seed drop (Display Box)", Desc = "Belum diset" })
        tab:Button({ Title = "Set seed drop position here", Desc = "Berdiri di samping Display Box tempat seed ditaruh.", Callback = UI.action(function()
            local box = G.Storage.captureNearby("seedDrop", "box")
            Pnb.refreshTab()
            G.setStatus("Display Box seed disimpan: tile " .. box.x .. ", " .. box.y .. ".")
        end) })
        controls.autoDrop = tab:Toggle({ Title = "Auto drop seed", Value = App.config.pnb.autoDrop,
            Desc = "Seed di tas mencapai batas: jalan ke Display Box seed, taruh semua seed, lalu lanjut PNB.",
            Callback = function(enabled) setOption(function() App.config.pnb.autoDrop = enabled == true end) end })
        tab:Slider({ Title = "Drop seed saat seed di tas >=", Step = 1,
            Value = { Min = 1, Max = 200, Default = App.config.options.seedThreshold },
            Callback = function(value) setOption(function() App.config.options.seedThreshold = math.floor(tonumber(value)) end) end })

        controls.grid = tab:Paragraph({ Title = "PNB tiles", Desc = Pnb.gridText() })
        tab:Button({ Title = "Atur PNB tiles (5x5)", Desc = "Buka panel kotak 5x5. Kotak tengah = lo. Klik kotak lain untuk dipilih.",
            Callback = function() local ok, message = pcall(Pnb.openGridPanel); if not ok then G.notify(tostring(message)) end end })
        tab:Button({ Title = "Clear tiles", Callback = UI.action(function()
            App.config.pnb.tiles = {}
            Pnb.refreshTab()
            G.setStatus("Semua tile PNB dihapus. Pilih lagi lewat Atur PNB tiles.")
        end) })
        syncing = false
        Pnb.refreshTab()
        table.insert(G.onConnected, function() pcall(refreshBlocks); pcall(Pnb.refreshTab) end)
        task.spawn(function()
            while App.alive do
                task.wait(0.3)
                pcall(Pnb.autoCollectTick)
            end
        end)
    end

    return Pnb
end
