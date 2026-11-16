-- ui.lua: jendela WindUI. Pondasi baru bikin kerangka tab + tab Settings.
-- Isi tab fitur (Place & Break + Auto Collect, Planting, Harvest, Rotation) ditambah bareng fiturnya.
return function(G)
    local App, task = G.App, G.task
    local UI = { tabs = {} }

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
        UI.tabs.pnb:Paragraph({ Title = "Belum dibuat", Desc = "Place & Break dan Auto Collect ditambah di tahap berikutnya." })
        for _, key in ipairs({ "plant", "harvest", "rotation" }) do
            UI.tabs[key]:Paragraph({ Title = "Belum dibuat", Desc = "Fitur ini ditambah di tahap berikutnya." })
        end

        local s = UI.tabs.settings
        UI.status = s:Paragraph({ Title = "Status", Desc = App.status })
        s:Button({ Title = "Reconnect to game", Desc = "Pakai ini kalau muncul 'found 0'. Masuk world dulu, baru pencet.",
            Callback = UI.action(function() G.connect() end) })
        s:Button({ Title = "Copy diagnostics", Callback = function()
            local text = G.diagnostics()
            if type(G.exec.setclipboard) == "function" then G.exec.setclipboard(text); G.notify("Diagnostics di-copy.")
            else print(text); G.notify("Diagnostics dicetak ke console.") end
        end })
        s:Button({ Title = "Unload script", Callback = function() G.unload() end })
        UI.log = s:Paragraph({ Title = "Aktivitas terakhir", Desc = "-" })
        return window
    end

    -- Dipanggil berkala dari main.lua.
    function UI.refresh()
        UI.paragraph(UI.status, "Status", App.status)
        UI.paragraph(UI.log, "Aktivitas terakhir", table.concat(App.logs, "\n", 1, math.min(#App.logs, 8)))
    end

    return UI
end
