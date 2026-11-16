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
