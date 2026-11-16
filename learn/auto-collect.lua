-- ============================================================
-- AUTO COLLECT (contoh belajar) untuk Claris Growblox v0.1.43
-- Tempel di src/main.lua TEPAT SETELAH loop `for _, info in ipairs(sliderInfo) do ... end`
-- (sebelum baris `ui.diagnostics = settingsTab:Paragraph(...)`).
--
-- Dibungkus `do ... end` karena main.lua sudah punya ~188 variabel `local`
-- di level atas, dan Lua membatasi 200 local per fungsi. Di dalam `do`,
-- variabel di bawah ini tidak ikut menghabiskan jatah itu.
-- ============================================================
do
    -- Setting sesi saja: hilang saat script di-reload. Sengaja TIDAK disimpan
    -- ke profil, karena Core.validate mewajibkan setiap key di Core.LIMITS ada
    -- di profil lama. Menambah key baru di sana bisa membuat profil lama ditolak.
    App.autoCollect = {enabled = false, range = 1.5, filter = "Semua", taken = 0, refused = 0, status = "Off"}

    local GEM_ID = 112 -- ID gem di Growblox (dipakai juga oleh collectDrops)

    -- 1) UI: tab sendiri, isinya toggle on/off, slider jangkauan, pilihan item, dan status.
    local collectTab = window:Tab({ Title = "Auto Collect", Icon = "magnet" })
    collectTab:Toggle({
        Title = "Auto collect",
        Desc = "Ambil drop di sekitar karakter. Otomatis berhenti selama task lain (PNB, rotation, dll.) jalan.",
        Value = false,
        Callback = function(value) App.autoCollect.enabled = value == true end,
    })
    collectTab:Slider({
        Title = "Jangkauan (tile)", Step = 0.25,
        Value = { Min = 0.5, Max = 5, Default = 1.5 },
        Callback = function(value) App.autoCollect.range = tonumber(value) or 1.5 end,
    })
    collectTab:Dropdown({
        Title = "Item yang diambil",
        Values = {"Semua", "Gem saja", "Blok + seed terpilih"},
        Value = "Semua",
        Callback = function(value)
            if type(value) == "table" then value = value[1] end -- WindUI kadang mengirim tabel
            App.autoCollect.filter = value
        end,
    })
    local statusBox = collectTab:Paragraph({ Title = "Status", Desc = "Off" })

    -- 2) Filter: drop ini boleh diambil atau nggak?
    local function wanted(drop, ac, blockId, seedId, me)
        if drop.display or drop.pending or drop.taking then return false end -- isi box / lagi diproses
        if type(drop.uid) ~= "number" or type(drop.n) ~= "number" or drop.n <= 0 then return false end
        if type(drop.x) ~= "number" or type(drop.y) ~= "number" then return false end
        if ac.filter == "Gem saja" and drop.id ~= GEM_ID then return false end
        if ac.filter == "Blok + seed terpilih" and drop.id ~= blockId and drop.id ~= seedId then return false end
        -- me.x = tengah karakter, me.y = kaki. Tengah badan kira-kira 0.475 tile di atas kaki.
        local dx, dy = drop.x - me.x, drop.y - (me.y - 0.475)
        return dx * dx + dy * dy <= ac.range * ac.range -- lingkaran dengan jari-jari = jangkauan
    end

    -- 3) Satu putaran: cari drop, kirim maksimal 8 permintaan pickup, tunggu hasilnya.
    local function step(ac, memo)
        if App.job or App.configuring then
            ac.status = "Jeda: task " .. tostring(App.job or "setup") .. " lagi jalan"
            return
        end
        local r = App.runtime
        if not r then ac.status = "Belum connect ke game"; return end
        if not r.body or type(r.world.dropList) ~= "function" or type(r.world.takeDrop) ~= "function"
            or type(r.world.dropTaken) ~= "function" then
            ac.status = "Hook pickup nggak tersedia"; return
        end
        if r.world.name == nil or r.world.name == "" or pickerOpen(r) then ac.status = "Di luar world"; return end
        local me = r.body.state()
        if not me.active or me.dead then ac.status = "Karakter belum siap"; return end

        -- Pindah world = drop baru semua. Hapus catatan percobaan lama.
        if memo.world ~= r.world.name or memo.grid ~= r.world.fg then
            memo.world, memo.grid = r.world.name, r.world.fg
            memo.attempts, memo.retryAt, memo.skipUntil = {}, {}, {}
        end

        local blockId, seedId = App.config.blockId, nil
        if blockId > 0 then
            local ok, id = pcall(Core.seedId, r.items, blockId)
            if ok then seedId = id end
        end

        local now, targets, reserved = os.clock(), {}, {}
        for _, drop in pairs(r.world.dropList()) do
            if #targets >= 8 then break end -- sama dengan batas script asli: maks 8 request bersamaan
            if wanted(drop, ac, blockId, seedId, me) and (memo.skipUntil[drop.uid] or 0) <= now then
                -- readyAt = drop baru jatuh belum boleh diambil; retryAt = jeda 1 detik setelah ditolak
                local readyAt = math.max(drop.readyAt or 0, memo.retryAt[drop.uid] or 0)
                local room = drop.id == GEM_ID and 65535 or (r.inventory:room(drop.id) - (reserved[drop.id] or 0))
                local want = math.floor(math.min(drop.n, room, 65535))
                if readyAt <= now and want > 0 then
                    if drop.id ~= GEM_ID then reserved[drop.id] = (reserved[drop.id] or 0) + want end
                    table.insert(targets, {drop = drop, want = want})
                end
            end
        end
        if #targets == 0 then
            ac.status = "Aktif, nunggu drop dalam " .. ac.range .. " tile"
            return
        end

        local jobs, deadline = {}, os.clock() + App.config.options.actionTimeout
        for _, target in ipairs(targets) do
            local drop, want = target.drop, target.want
            local uid, id, before, grid = drop.uid, drop.id, drop.n, r.world.fg
            drop.taking = true -- tandai biar nggak diambil dua kali
            memo.attempts[uid] = (memo.attempts[uid] or 0) + 1
            -- beginRequest menaikkan App.pending, jadi task lain nggak bisa mulai pas pickup lagi jalan.
            local request = beginRequest(function()
                local ok, amount = pcall(r.world.takeDrop, uid, want)
                drop.taking = false
                assert(ok, tostring(amount))
                amount = amount or 0
                assert(type(amount) == "number" and amount >= 0 and amount <= want, "Respons pickup aneh dari server.")
                -- takeDrop cuma ngirim request. Tampilan drop di layar diupdate manual di sini,
                -- dan cuma kalau kita masih di world yang sama.
                if amount > 0 and r.world.fg == grid then
                    r.world.dropTaken(uid, math.max(0, before - amount))
                end
                return amount
            end)
            table.insert(jobs, {request = request, uid = uid, id = id})
        end

        local gems, accepted = 0, false
        for _, job in ipairs(jobs) do
            local ok, amount = pcall(awaitRequest, job.request, deadline, nil)
            if ok and amount > 0 then
                accepted, memo.attempts[job.uid] = true, 0
                ac.taken = ac.taken + amount
                if job.id == GEM_ID then gems = gems + amount; App.stats.gems = App.stats.gems + amount end
            else
                -- 0 = server menolak (biasanya kejauhan). Coba lagi 1 detik lagi;
                -- setelah 3x ditolak, abaikan drop itu selama 30 detik.
                ac.refused = ac.refused + 1
                memo.retryAt[job.uid] = os.clock() + 1
                if (memo.attempts[job.uid] or 0) >= 3 then memo.skipUntil[job.uid] = os.clock() + 30 end
            end
        end

        -- takeDrop nggak update isi tas lokal. Sinkron sekali per batch yang berhasil.
        if accepted then
            pcall(refreshInventory)
            if gems > 0 and r.gemHud then
                local ok, total = pcall(bounded, r.world.call, App.config.options.actionTimeout, nil, "GetGems")
                if ok and type(total) == "number" then r.gemHud.setGems(total) end
            end
        end
        ac.status = "Aktif: " .. #jobs .. " drop dicoba barusan"
    end

    -- 4) Loop latar belakang. Berhenti sendiri kalau script di-unload (App.alive = false).
    task.spawn(function()
        local memo = {}
        while App.alive do
            local ac = App.autoCollect
            if ac.enabled then
                local ok, problem = pcall(step, ac, memo)
                if not ok then ac.status = "Error: " .. tostring(problem) end
            else
                ac.status = "Off"
            end
            paragraphSet(statusBox, "Status", ac.status .. "\nDiambil: " .. ac.taken .. "  |  Ditolak: " .. ac.refused)
            task.wait(ac.enabled and 0.25 or 0.5)
        end
    end)
end
