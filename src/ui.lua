-- ui.lua: jendela WindUI. Pondasi baru bikin kerangka tab + tab Settings.
-- Isi tab fitur (Place & Break + Auto Collect, Planting, Harvest, Rotation) ditambah bareng fiturnya.
return function(G)
    local App, task = G.App, G.task
    local UI = { tabs = {}, statuses = {} }

    -- Paragraf "Status" di tiap tab, diupdate bareng oleh UI.refresh().
    function UI.addStatus(paragraph) table.insert(UI.statuses, paragraph); return paragraph end

    -- Bungkus aksi tombol: jalan di thread sendiri, cek sedang tidak ada task,
    -- dan kalau error tampilkan pesannya, bukan bikin script crash.
    function UI.action(fn)
        return function()
            task.spawn(function()
                local ok, message = pcall(G.Net.idle)
                if not ok then G.notify(tostring(message)); return end
                App.configuring = true
                ok, message = pcall(fn)
                App.configuring = false
                if ok then ok, message = pcall(G.State.saveSession) end
                if not ok then G.setStatus(tostring(message)); G.notify(tostring(message)) end
            end)
        end
    end

    function UI.paragraph(paragraph, title, desc)
        if paragraph and paragraph.ParagraphFrame then
            paragraph.ParagraphFrame:SetTitle(title)
            paragraph.ParagraphFrame:SetDesc(desc)
        end
    end

    function UI.build(WindUI)
        local window = WindUI:CreateWindow({
            Title = "Growblox Hansel", Author = "v" .. G.VERSION .. " | Learn to own",
            Folder = G.State.ROOT, Icon = "sprout", Size = G.UDim2.fromOffset(600, 520),
            OpenButton = { Title = "Growblox Hansel", Enabled = true, Draggable = true, OnlyMobile = false },
        })
        UI.window = window
        App.window = window
        window:OnDestroy(function() G.unload() end)

        -- Urutan tab = urutan muncul di layar. Auto Collect ada di dalam tab Place & Break.
        UI.tabs.pnb = window:Tab({ Title = "Place & Break", Icon = "hammer" })
        UI.tabs.plant = window:Tab({ Title = "Planting", Icon = "sprout" })
        UI.tabs.harvest = window:Tab({ Title = "Harvest", Icon = "package" })
        UI.tabs.rotation = window:Tab({ Title = "Rotation", Icon = "repeat" })
        UI.tabs.settings = window:Tab({ Title = "Settings", Icon = "settings" })
        G.Pnb.buildTab(UI.tabs.pnb)
        G.Plant.buildTab(UI.tabs.plant)
        G.Harvest.buildTab(UI.tabs.harvest)
        G.Rotation.buildTab(UI.tabs.rotation)

        local s = UI.tabs.settings
        UI.status = UI.addStatus(s:Paragraph({ Title = "Status", Desc = App.status }))
        s:Button({ Title = "Stop task", Desc = "Hentikan task yang lagi jalan. Checkpoint resume ikut dihapus.",
            Callback = function() G.Jobs.stop() end })
        s:Button({ Title = "Reconnect to game", Desc = "Pakai ini kalau muncul 'found 0'. Masuk world dulu, baru pencet.",
            Callback = UI.action(function() G.connect() end) })
        s:Button({ Title = "Copy diagnostics", Callback = function()
            local text = G.diagnostics()
            if type(G.exec.setclipboard) == "function" then G.exec.setclipboard(text); G.notify("Diagnostics di-copy.")
            else print(text); G.notify("Diagnostics dicetak ke console.") end
        end })
        UI.buildSettings(s)
        UI.buildAutostart(s)
        s:Button({ Title = "Unload script", Callback = function() G.unload() end })
        UI.log = s:Paragraph({ Title = "Aktivitas terakhir", Desc = "-" })
        return window
    end

    -- Setting umum (adaptasi tab Settings Clarissv v0.1.43). Hanya bisa diubah saat tidak ada task.
    -- Hit delay dan batas seed ada di tab Place & Break.
    function UI.buildSettings(s)
        local Core, State, Net = G.Core, G.State, G.Net
        UI.settings = {}
        pcall(function() s:Section({ Title = "Settings" }) end)
        for _, info in ipairs({
            { "antiAFK", "Anti-AFK", "Jaga sesi tetap aktif saat Roblox mendeteksi idle (klik virtual tiap idle, maks sekali per menit)." },
            { "autoRejoin", "Rejoin world and return to PNB & Harvest", "Keluar ke world picker, avatar mati, atau pindah server: masuk lagi ke world task (PNB: balik ke spot; Harvest: world farm, scan ulang, lanjut panen). Juga lanjut Planting dari checkpoint." },
        }) do
            local key = info[1]
            UI.settings[key] = s:Toggle({ Title = info[2], Desc = info[3], Value = App.config.options[key],
                Callback = function(value)
                    if App.syncingSettings then return end
                    local ok, message = pcall(function()
                        Net.idle()
                        App.config.options[key] = value == true
                        if key == "antiAFK" and value then G.installAntiAFK() end
                        State.saveSession()
                    end)
                    if not ok then
                        G.notify("Stop task dulu sebelum mengubah setting.")
                        App.syncingSettings = true
                        pcall(function() UI.settings[key]:Set(App.config.options[key], false, false) end)
                        App.syncingSettings = false
                    end
                end })
        end
        for _, info in ipairs({
            { "placeDelay", "Jeda setelah place (detik)", 0.05 }, { "collectDelay", "Waktu tunggu drop (detik)", 0.05 },
            { "actionTimeout", "Batas waktu request server (detik)", 1 }, { "moveTimeout", "Batas waktu jalan (detik)", 1 },
        }) do
            local key, limits = info[1], Core.LIMITS[info[1]]
            UI.settings[key] = s:Slider({ Title = info[2], Step = info[3],
                Value = { Min = limits[1], Max = limits[2], Default = App.config.options[key] },
                Callback = function(value)
                    if App.syncingSettings then return end
                    local ok = pcall(function()
                        Net.idle()
                        App.config.options[key] = tonumber(value)
                        State.saveSession()
                    end)
                    if not ok then G.notify("Stop task dulu sebelum mengubah setting.") end
                end })
        end
    end

    -- Auto-start: script pendek untuk folder autoexec executor. Executor menjalankannya tiap kali
    -- masuk game (termasuk setelah mental ke world picker / rejoin, saat queue_on_teleport tidak
    -- terpanggil), lalu task yang punya checkpoint dilanjutkan otomatis.
    function UI.autostartScript()
        local pinned = tostring(G.env and G.env.GrowbloxHanselLoaderURL or "")
        local main = pinned:gsub("releases/loader%-[%w]+%.lua$", "loader.lua")
        if main == "" or not main:match("^https://") then
            main = "https://raw.githubusercontent.com/Hanselane/growblox-hansel/main/loader.lua"
        end
        return table.concat({
            "-- Growblox Hansel auto-start (taruh di folder autoexec executor)",
            "if not game:IsLoaded() then game.Loaded:Wait() end",
            "task.wait(3)",
            "-- sudah dimuat lewat queue_on_teleport / manual? jangan jalan dobel",
            "if getgenv().GrowbloxHanselLoading or getgenv().GrowbloxHanselApp then return end",
            "getgenv().GrowbloxHanselAutoResume = true",
            "loadstring(game:HttpGet(" .. string.format("%q", main) .. "))()",
        }, "\n")
    end
    function UI.buildAutostart(s)
        pcall(function() s:Section({ Title = "Auto-start" }) end)
        s:Paragraph({ Title = "Auto-start setelah mental / rejoin",
            Desc = "Kalau setelah keluar ke world picker script tidak jalan sendiri, pasang auto-start: tekan tombol di bawah, "
                .. "lalu tempel isinya ke file baru di folder autoexec executor (Delta: folder Autoexecute). Tiap masuk game, "
                .. "script dimuat dan task yang punya checkpoint (Rotation, Harvest, PNB) dilanjutkan; dari world picker script "
                .. "masuk sendiri ke world tujuan. Tanpa checkpoint, script cuma terbuka seperti biasa." })
        s:Button({ Title = "Copy script auto-start", Callback = function()
            local copy = G.exec and G.exec.setclipboard
            local text = UI.autostartScript()
            if type(copy) == "function" then copy(text); G.notify("Script auto-start di-copy.")
            else print(text); G.notify("Executor tidak mendukung copy; script dicetak ke console.") end
        end })
    end

    -- Dipanggil berkala dari main.lua.
    function UI.refresh()
        for _, paragraph in ipairs(UI.statuses) do UI.paragraph(paragraph, "Status", App.status) end
        G.Jobs.syncToggles()
        UI.paragraph(UI.log, "Aktivitas terakhir", table.concat(App.logs, "\n", 1, math.min(#App.logs, 8)))
    end

    return UI
end
