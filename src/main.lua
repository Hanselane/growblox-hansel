-- main.lua: titik masuk. Kumpulkan alat dari executor/Roblox, rangkai semua modul, connect ke game.
-- Urutan: bersihkan sesi lama -> App -> modul -> UI -> connect (dengan retry) -> loop heartbeat.
return function(modules, VERSION)
    local HttpService = game:GetService("HttpService")
    local Players = game:GetService("Players")
    local ReplicatedStorage = game:GetService("ReplicatedStorage")
    local UserInputService = game:GetService("UserInputService")
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
        -- Kembalikan kontrol karakter yang mungkin masih dipegang instance lama.
        local hold = previous.controls
        if hold then
            if hold.table.dir == hold.dirOverride then hold.table.dir = hold.dir end
            if hold.table.jumping == hold.jumpOverride then hold.table.jumping = hold.jumping end
            if hold.world.displayTake == hold.displayOverride then hold.world.displayTake = hold.displayTake end
            if hold.world.takeDrop == hold.takeOverride then hold.world.takeDrop = hold.takeDrop end
            previous.controls = nil
        end
        if previous.window then pcall(function() previous.window:Destroy() end) end
        if previous.idleConnection then pcall(function() previous.idleConnection:Disconnect() end) end
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
        getconnections = getconnections or get_signal_cons, firesignal = firesignal,
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
    G.focusedTextBox = function() return UserInputService:GetFocusedTextBox() end
    G.env = env
    G.queueOnTeleport = queue_on_teleport or queueonteleport or (syn and syn.queue_on_teleport)
    G.newInstance, G.Color3 = Instance and Instance.new, Color3
    G.guiParent = function()
        if type(gethui) == "function" then return gethui() end
        return game:GetService("CoreGui")
    end

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
    G.resumeHandlers = {} -- fitur yang bisa di-resume mendaftar di sini
    G.onConnected = {}    -- dipanggil setiap kali berhasil tersambung (misal isi ulang pilihan seed)
    G.Core = modules.core
    G.Navigation = modules.navigation
    G.Net = modules.net(G)
    G.State = modules.state(G)
    G.Bridge = modules.bridge(G)
    G.Actions = modules.actions(G)
    G.Movement = modules.movement(G)
    G.Storage = modules.storage(G)
    G.Drops = modules.drops(G)
    G.Jobs = modules.jobs(G)
    G.Scan = modules.scan(G)
    G.UI = modules.ui(G)
    G.Plant = modules.plant(G)
    G.Pnb = modules.pnb(G)
    G.Harvest = modules.harvest(G)
    G.Rotation = modules.rotation(G)
    App.config = G.Core.defaults()

    -- resuming = true: script dimuat ulang untuk melanjutkan task (setelah mental / pindah server).
    -- Tunggu game lebih lama (sampai ~2 menit) dan boleh tersambung dari world picker, karena
    -- task-nya sendiri yang akan masuk lagi ke world tujuan.
    function G.connect(resuming)
        G.setStatus("Menyambung ke game...")
        local r = G.Bridge.connect({ attempts = resuming and 30 or 8, delay = 4, allowPicker = true,
            onRetry = function(attempt, total, message)
                G.setStatus("World belum siap (" .. message .. "). Coba lagi " .. attempt .. "/" .. (total - 1) .. "...")
            end })
        local where = r.connectedInPicker and "world picker" or tostring(r.world.name)
        G.setStatus(r.ready and ("Tersambung ke " .. where .. ".")
            or ("Tersambung ke " .. where .. ", tapi ada hook yang hilang. Cek diagnostics."))
        for _, handler in ipairs(G.onConnected) do pcall(handler, r) end
        return r
    end

    -- Masuk world lewat UI world picker: isi kotak "World Name", lalu tekan Enter / "Enter World".
    -- Cara menekan dicoba berurutan sesuai dukungan executor. Return: cara yang dipakai.
    function G.enterFromPicker(name)
        local gui = assert(player:FindFirstChildOfClass("PlayerGui"), "PlayerGui tidak ada.")
        local box, button
        for _, object in ipairs(gui:GetDescendants()) do
            if not box and object.Name == "WorldName" then
                box = object:IsA("TextBox") and object or object:FindFirstChildWhichIsA("TextBox", true)
                    or (object.Parent and object.Parent:FindFirstChildWhichIsA("TextBox", true))
            end
            if not button and object:IsA("GuiButton") then
                local text = (object:IsA("TextButton") and object.Text or "") .. " " .. object.Name
                for _, child in ipairs(object:GetDescendants()) do
                    if child:IsA("TextLabel") then text = text .. " " .. child.Text end
                end
                if text:lower():find("enter world", 1, true) or text:lower():find("enterworld", 1, true) then button = object end
            end
        end
        assert(box, "Kotak World Name di world picker tidak ketemu.")
        box.Text = name
        local X = G.exec
        if type(X.getconnections) == "function" then
            local fired = 0
            for _, connection in ipairs(X.getconnections(box.FocusLost)) do
                local ok = pcall(function()
                    if connection.Fire then connection:Fire(true) else connection.Function(true) end
                end)
                if ok then fired = fired + 1 end
            end
            if fired > 0 then return "Enter di kotak World Name" end
            if button then
                for _, signal in ipairs({ button.Activated, button.MouseButton1Click }) do
                    for _, connection in ipairs(X.getconnections(signal)) do
                        local ok = pcall(function()
                            if connection.Fire then connection:Fire() else connection.Function() end
                        end)
                        if ok then fired = fired + 1 end
                    end
                    if fired > 0 then return "tombol Enter World (koneksi)" end
                end
            end
        end
        if button and type(X.firesignal) == "function" then
            if pcall(X.firesignal, button.MouseButton1Click) then return "tombol Enter World (firesignal)" end
        end
        assert(button, "Tombol Enter World tidak ketemu.")
        local input = game:GetService("VirtualInputManager")
        local inset = game:GetService("GuiService"):GetGuiInset()
        local center = button.AbsolutePosition + button.AbsoluteSize / 2 + inset
        input:SendMouseButtonEvent(center.X, center.Y, 0, true, game, 0)
        task.wait(0.05)
        input:SendMouseButtonEvent(center.X, center.Y, 0, false, game, 0)
        return "klik virtual Enter World"
    end

    function G.diagnostics()
        local lines = {
            "Growblox Hansel " .. VERSION,
            "World: " .. (App.runtime and App.runtime.world.name or "belum tersambung"),
            "Profil: " .. App.profile .. " | Akun: " .. ACCOUNT_ID,
            "Status: " .. App.status,
            "Connect error: " .. (App.connectionError or "tidak ada"),
            "Percobaan connect: " .. tostring(App.connectAttempts or "-"),
            "Tahap startup: " .. App.startupStage .. (App.pickerEntry and (" | masuk lewat picker: " .. App.pickerEntry) or ""),
            "Loader: " .. tostring(env.GrowbloxHanselLoaderDebug or "lokal / tidak diketahui"),
            "Job: " .. tostring(App.job or "idle") .. " | Request pending: " .. App.pending,
            "Navigasi: " .. tostring(App.navigationDebug or "-"),
            "Anti-AFK: " .. (App.config.options.antiAFK and "on" or "off") .. "; "
                .. (App.antiAFKError or (App.idleConnection and "siap" or "belum terpasang"))
                .. (App.lastIdleInput and string.format("; input terakhir %.0f detik lalu", os.clock() - App.lastIdleInput) or ""),
            (function()
                local function counts(map)
                    local parts = {}
                    for _, key in ipairs({ "Place & Break", "Harvest", "Rotation" }) do
                        if map[key] then table.insert(parts, key .. " " .. map[key] .. "x") end
                    end
                    return #parts > 0 and table.concat(parts, ", ") or "0"
                end
                local errors = {}
                for name, issue in pairs(App.resumeErrors or {}) do table.insert(errors, name .. ": " .. issue) end
                return "Rejoin: " .. (App.config.options.autoRejoin and "on" or "off") .. "; masuk ulang " .. counts(App.rejoins or {})
                    .. "; diulang karena error " .. counts(App.retries or {})
                    .. (App.lastRetryError and ("; terakhir: " .. App.lastRetryError) or "")
                    .. (#errors > 0 and ("; checkpoint error: " .. table.concat(errors, ", ")) or "")
            end)(),
            "Planting recovery: " .. tostring(App.plantingRecovery or "-"),
            "Rotation: " .. tostring(App.rotationInfo or "-") .. " | world ke-" .. tostring(App.rotationIndex or "-")
                .. ", putaran " .. tostring(App.rotationLaps or 0)
                .. ", error kecil dilewati " .. tostring(App.rotationSoftErrors or 0) .. "x"
                .. (App.rotationLastError and ("; error kecil terakhir: " .. App.rotationLastError) or ""),
            (function()
                local parts = {}
                for _, pair in ipairs({ { "World rotasi", App.rotationWorlds }, { "World harvest", App.harvestWorlds } }) do
                    for name, text in pairs(pair[2] or {}) do table.insert(parts, pair[1] .. " " .. name .. ": " .. text) end
                end
                if App.rotationBoxNote then table.insert(parts, "Catatan box: " .. App.rotationBoxNote) end
                return #parts > 0 and table.concat(parts, "\n") or "World rotasi/harvest: -"
            end)(),
            "Harvest: " .. tostring(App.harvestPlan or "-") .. " | world ke-" .. tostring(App.harvestIndex or "-")
                .. ", replant " .. tostring(App.config.harvesting.replant),
            (function()
                local labels = { { "harvest", "pohon" }, { "PNB", "blok" }, { "replant", "tile" },
                    { "masuk & scan world", "kali" }, { "simpan seed", nil } }
                local parts, total = {}, 0
                for _, info in ipairs(labels) do
                    local entry = (App.phaseTime or {})[info[1]]
                    if entry then
                        total = total + entry.seconds
                        local text = string.format("%s %.0fd", info[1], entry.seconds)
                        if info[2] and entry.units > 0 then
                            text = text .. string.format(" (%d %s, %.2f d/%s)", entry.units, info[2], entry.seconds / entry.units, info[2])
                        end
                        table.insert(parts, text)
                    end
                end
                if #parts == 0 then return "Waktu rotasi: -" end
                for i, info in ipairs(labels) do
                    local entry = (App.phaseTime or {})[info[1]]
                    if entry and total > 0 then
                        for j, part in ipairs(parts) do
                            if part:sub(1, #info[1] + 1) == info[1] .. " " then
                                parts[j] = part .. string.format(" = %d%%", math.floor(entry.seconds / total * 100 + 0.5))
                            end
                        end
                    end
                end
                return "Waktu rotasi: " .. table.concat(parts, "; ") .. string.format(" | pungut dilewati (tanpa drop) %dx", App.collectSkips or 0)
            end)(),
            "Jangkauan pungut server: " .. G.Drops.reachText(),
            "Stock terakhir: " .. tostring(App.stockDebug or "-"),
            "Auto collect: " .. (App.config and App.config.options.autoCollect and "on" or "off") .. ", jangkauan "
                .. tostring(App.config and App.config.options.collectRange) .. ", " .. tostring(App.autoCollectInfo or "-"),
            "Seed ditanam sesi ini: " .. App.stats.planted .. " | Blok dipecah: " .. App.stats.broken,
            "PNB: blok " .. tostring(App.config.blockId) .. ", " .. #App.config.pnb.tiles .. " tile, auto stock "
                .. tostring(App.config.pnb.autoStock) .. ", auto drop " .. tostring(App.config.pnb.autoDrop) .. ", balik ke spot " .. (App.pnbRecoveries or 0) .. "x",
        }
        for _, line in ipairs(App.discoveryReport) do table.insert(lines, line) end
        if App.scanReport then
            table.insert(lines, "World Scan:")
            for _, line in ipairs(App.scanReport) do table.insert(lines, "  " .. line) end
        end
        table.insert(lines, "Log:")
        for i = 1, math.min(#App.logs, 15) do table.insert(lines, App.logs[i]) end
        return table.concat(lines, "\n")
    end

    -- Anti-AFK (adaptasi installAntiAFK Clarissv v0.1.43): saat Roblox mendeteksi idle,
    -- kirim klik kanan virtual lewat VirtualUser. Maksimal sekali per menit.
    function G.installAntiAFK()
        if App.idleConnection then return true end
        local ok, service = pcall(function() return game:GetService("VirtualUser") end)
        if not ok then App.antiAFKError = tostring(service); return false end
        local connected, connection = pcall(function()
            return player.Idled:Connect(function()
                if not App.alive or not App.config.options.antiAFK then return end
                if App.lastIdleInput and os.clock() - App.lastIdleInput < 60 then return end
                local sent, message = pcall(function()
                    service:CaptureController()
                    service:ClickButton2(Vector2.new(0, 0))
                end)
                if sent then App.lastIdleInput, App.antiAFKError = os.clock(), nil
                else App.antiAFKError = tostring(message) end
            end)
        end)
        if not connected then App.antiAFKError = tostring(connection); return false end
        App.idleConnection, App.antiAFKError = connection, nil
        return true
    end

    function G.unload()
        if not App.alive then return end
        if App.idleConnection then pcall(function() App.idleConnection:Disconnect() end); App.idleConnection = nil end
        if App.job then pcall(G.Jobs.stop) end
        pcall(G.Movement.releaseControls)
        App.alive = false
        App.token = App.token + 1
        if env.GrowbloxHanselApp == App then env.GrowbloxHanselApp = nil end
        if App.window then pcall(function() App.window:Destroy() end) end
    end

    -- 5) Pulihkan setting terakhir (kalau ada), lalu muat UI.
    local restored, problem = pcall(G.State.restoreSession)
    if not restored then G.setStatus("Session lama nggak bisa dibaca: " .. tostring(problem)) end
    if App.config.options.antiAFK then G.installAntiAFK() end

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
        -- Dimuat ulang (auto-resume) tapi masih di world picker dan game belum memuat world sama
        -- sekali (Qz belum ada, world table 0): masuk ke world tujuan task lewat UI picker dulu.
        if env.GrowbloxHanselAutoResume and ReplicatedStorage:GetAttribute("Qz") == nil then
            local target = G.Jobs.resumeTargetWorld()
            for attempt = 1, 3 do
                if not target or ReplicatedStorage:GetAttribute("Qz") ~= nil or not App.alive then break end
                G.setStatus("Masuk " .. target .. " lewat world picker (" .. attempt .. "/3)...")
                local ok, how = pcall(G.enterFromPicker, target)
                App.pickerEntry = (ok and tostring(how) or ("gagal: " .. tostring(how))) .. " -> " .. target
                local wait = os.clock() + 20
                while App.alive and ReplicatedStorage:GetAttribute("Qz") == nil and os.clock() < wait do task.wait(0.25) end
            end
        end
        App.configuring = true
        local ok, message = pcall(G.connect, env.GrowbloxHanselAutoResume == true)
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
