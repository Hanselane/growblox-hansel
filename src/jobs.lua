-- jobs.lua: mulai/stop task (Planting, Harvest, PNB, Rotation) dengan satu cara yang sama.
-- Diadaptasi dari Clarissv main.lua v0.1.43: start, App:stop, setRunningEnabled, syncRunToggles.
-- Bedanya: tiap fitur MENDAFTAR di sini (Jobs.register), jadi start() tidak perlu tahu isi fiturnya.
return function(G)
    local App, Core, Bridge, Net, Movement, task = G.App, G.Core, G.Bridge, G.Net, G.Movement, G.task
    local Jobs = { specs = {}, toggles = {} }

    -- spec = {
    --   label        nama di status, misal "Planting"
    --   prepare(r, saved)   cek hook game yang dibutuhkan (opsional; saved = checkpoint resume)
    --   run(token, saved)   isi task; selesai normal = return, gagal = error
    --   clear()      hapus checkpoint fitur ini (dipanggil saat Stop / task lain mulai)
    -- }
    function Jobs.register(mode, spec)
        Jobs.specs[mode] = spec
    end

    -- Samakan posisi toggle On/Off di UI dengan job yang benar-benar jalan.
    function Jobs.syncToggles()
        App.syncingRunToggles = true
        for mode, control in pairs(Jobs.toggles) do
            local enabled = App.alive and App.job == mode and App.jobToken == App.token
            if control.Value ~= enabled then pcall(function() control:Set(enabled, false, false) end) end
        end
        App.syncingRunToggles = false
    end

    function Jobs.start(mode, saved)
        Net.idle()
        local spec = assert(Jobs.specs[mode], "Task tidak dikenal: " .. tostring(mode))
        local r = Bridge.runtime()
        if spec.prepare then spec.prepare(r, saved) end
        Core.checkSetup(App.config, mode, r.items)
        for other, otherSpec in pairs(Jobs.specs) do
            if other ~= mode and otherSpec.clear then pcall(otherSpec.clear) end
        end
        G.State.saveSession()
        local token = Net.beginJob(mode)
        App.teleporting, App.recovering = false, false
        Jobs.syncToggles()
        task.spawn(function()
            local ok, message = xpcall(function()
                Net.checkpoint(token)
                Movement.takeControls()
                spec.run(token, saved)
            end, function(err) return tostring(err) end)
            Movement.releaseControls()
            App.job, App.jobToken, App.recovering = nil, nil, false
            Jobs.syncToggles()
            if not ok and token == App.token and App.alive then
                App.lastError = message
                G.setStatus("Paused: " .. message)
                G.notify(message)
            end
        end)
        return token
    end

    -- Stop: token naik, jadi loop task berhenti di checkpoint berikutnya. Checkpoint semua fitur dihapus.
    function Jobs.stop()
        App.token = App.token + 1
        App.teleporting, App.recovering = false, false
        Jobs.syncToggles()
        Movement.releaseControls()
        for _, spec in pairs(Jobs.specs) do if spec.clear then pcall(spec.clear) end end
        pcall(G.State.saveSession)
        G.setStatus(App.pending > 0 and "Stopped; waiting for a pending server request." or "Stopped.")
    end

    -- Dipanggil toggle UI. On = mulai (kalau belum jalan), Off = stop (kalau task ini yang jalan).
    function Jobs.setRunning(mode, enabled)
        if App.syncingRunToggles then return true end
        local ok, message = pcall(function()
            if enabled then
                if App.job == mode and App.jobToken == App.token then return end
                Jobs.start(mode)
            elseif App.job == mode and App.jobToken == App.token then
                Jobs.stop()
            end
        end)
        Jobs.syncToggles()
        if not ok then G.notify(tostring(message)) end
        return ok, message
    end

    return Jobs
end
