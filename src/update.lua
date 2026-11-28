-- update.lua: auto update saat script jalan.
-- Tiap 10 menit baca latest.json di GitHub (ditulis build.mjs: versi + path loader permanen).
-- Ada versi baru -> loader baru di-download & di-compile dulu -> task yang jalan dijeda dengan
-- checkpoint (Jobs.suspend, checkpoint TIDAK dihapus) -> loader baru dijalankan dengan
-- AutoResume, jadi script baru menyambung dan melanjutkan task dari titik terakhir.
-- Gagal di tengah jalan -> versi lama tetap hidup dan task-nya dilanjutkan lagi.
return function(G)
    local App, task = G.App, G.task
    local Update = { INTERVAL = 600, URL_FILE = "GrowbloxHansel/loader-url.txt" }
    App.update = App.update or { info = "belum dicek" }

    -- "0.7.10" > "0.7.9"
    function Update.newer(candidate, current)
        local a, b = {}, {}
        for n in tostring(candidate):gmatch("%d+") do table.insert(a, tonumber(n)) end
        for n in tostring(current):gmatch("%d+") do table.insert(b, tonumber(n)) end
        for i = 1, math.max(#a, #b) do
            local x, y = a[i] or 0, b[i] or 0
            if x ~= y then return x > y end
        end
        return false
    end

    -- Folder repo dari URL loader yang sedang dipakai (.../main/releases/loader-xxx.lua -> .../main/).
    -- Loader yang di-pin ke commit tetap dicek ke branch main supaya patch berikutnya kelihatan.
    function Update.base()
        local url = G.env and G.env.GrowbloxHanselLoaderURL
        if type(url) ~= "string" or not url:match("^https://") then return nil end
        local root = url:match("^(https://raw%.githubusercontent%.com/[^/]+/[^/]+/)")
        if root then return root .. "main/" end
        return (url:gsub("releases/loader%-[%w]+%.lua$", ""))
    end

    -- Simpan URL loader yang sedang dipakai: dibaca kode queue_on_teleport & script auto-start,
    -- jadi setelah update, pindah server / masuk ulang memuat versi baru, bukan versi lama.
    function Update.rememberLoader(url)
        local fs = G.fs or {}
        if type(url) ~= "string" or not url:match("^https://") or type(fs.writefile) ~= "function" then return false end
        return pcall(function()
            if fs.isfolder and fs.makefolder and not fs.isfolder("GrowbloxHansel") then fs.makefolder("GrowbloxHansel") end
            fs.writefile(Update.URL_FILE, url)
        end)
    end

    function Update.check()
        local base = assert(Update.base(), "Auto update butuh script yang dimuat dari loader GitHub.")
        local text = G.httpGet(base .. "latest.json?t=" .. tostring(os.time()))
        local info = G.json.decode(text)
        assert(type(info) == "table" and type(info.version) == "string" and type(info.loader) == "string",
            "latest.json tidak valid.")
        info.url = base .. info.loader
        App.update.checked, App.update.latest = os.time(), info.version
        return info, Update.newer(info.version, G.VERSION)
    end

    -- Kapan boleh update: tidak sedang pindah world/pulih, dan task yang jalan bisa dilanjutkan.
    function Update.blocker()
        if App.configuring then return "sedang menyambung" end
        if App.teleporting or App.recovering then return "sedang masuk ulang world" end
        if App.job then
            local spec = G.Jobs.specs[App.job]
            if not (spec and spec.resume and spec.save) then return (spec and spec.label or App.job) .. " ditunggu selesai" end
        end
        return nil
    end

    function Update.apply(info)
        local blocked = Update.blocker()
        if blocked then return false, blocked end
        -- 1) download + compile dulu, sebelum menyentuh task
        local okText, source = pcall(G.httpGet, info.url)
        if not okText then return false, "download loader gagal: " .. tostring(source) end
        local chunk, problem = loadstring(source, "Growblox Hansel loader")
        if not chunk then return false, "loader rusak: " .. tostring(problem) end
        -- 2) jeda task dengan checkpoint
        local suspended, why = G.Jobs.suspend(25)
        if suspended == false then
            if not App.job then G.Jobs.resumeSaved() end
            return false, why
        end
        -- 3) jalankan versi baru (dia mematikan instance ini sendiri)
        local env, oldUrl = G.env, G.env.GrowbloxHanselLoaderURL
        G.setStatus(string.format("Update %s -> %s%s...", G.VERSION, info.version,
            suspended and (", " .. suspended .. " dilanjutkan setelahnya") or ""))
        env.GrowbloxHanselAutoResume = suspended and true or nil
        env.GrowbloxHanselUpdatedFrom = G.VERSION
        Update.rememberLoader(info.url)
        local ran, failure = pcall(chunk)
        if ran then return true end
        -- gagal: kembalikan versi lama
        env.GrowbloxHanselAutoResume, env.GrowbloxHanselUpdatedFrom = nil, nil
        env.GrowbloxHanselLoaderURL = oldUrl
        env.GrowbloxHanselLoading = nil
        Update.rememberLoader(oldUrl)
        if env.GrowbloxHanselApp ~= App then env.GrowbloxHanselApp = App end
        App.alive = true
        if suspended then G.Jobs.resumeSaved() end
        return false, "versi baru gagal dimuat: " .. tostring(failure)
    end

    -- Satu putaran: cek, kalau ada versi baru coba pasang. Return: teks hasil untuk diagnostics.
    function Update.tick(force)
        local okCheck, info, newer = pcall(Update.check)
        if not okCheck then App.update.info = "cek gagal: " .. tostring(info); return App.update.info end
        if not newer then App.update.info = "sudah terbaru (" .. G.VERSION .. ")"; return App.update.info end
        if not force and not App.config.options.autoUpdate then
            App.update.info = "versi baru " .. info.version .. " tersedia (auto update mati)"
            return App.update.info
        end
        local done, why = Update.apply(info)
        if done then return "update ke " .. info.version end
        App.update.info = "versi baru " .. info.version .. " ditunda: " .. tostring(why)
        return App.update.info
    end

    function Update.install()
        Update.rememberLoader(G.env and G.env.GrowbloxHanselLoaderURL)
        if not Update.base() then App.update.info = "mati (bukan loader GitHub)"; return false end
        task.spawn(function()
            task.wait(90)
            while App.alive do
                local wait = Update.INTERVAL
                if App.config.options.autoUpdate then
                    Update.tick(false)
                    -- versi baru ada tapi ditunda (misal Planting jalan): coba lagi lebih cepat
                    if App.alive and App.update.latest and Update.newer(App.update.latest, G.VERSION) then wait = 30 end
                end
                local untilAt = os.clock() + wait
                while App.alive and os.clock() < untilAt do task.wait(1) end
            end
        end)
        return true
    end

    return Update
end
