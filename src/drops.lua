-- drops.lua: pungut drop (blok, seed, gem) dari lantai lewat UID pickup.
-- Diadaptasi dari Clarissv main.lua v0.1.43: takeDropBatch dan collectDrops.
-- Bedanya: area pungut bisa diatur (radius), dan drop yang 3x ditolak server cuma dilewati,
-- tidak menghentikan task (grid PNB 5x5 menjatuhkan drop lebih jauh dari grid 1 tile Clarissv).
return function(G)
    local App, Bridge, Net, Actions, Movement = G.App, G.Bridge, G.Net, G.Actions, G.Movement
    local Drops = { GEM = 112 }
    local worldCheck, position, pause = Bridge.worldCheck, Bridge.position, Net.pause

    -- Kirim maksimal 8 permintaan pickup sekaligus, lalu tunggu semua balasan.
    -- Tiap drop "dipesan" dulu (drop.taking) supaya pickup bawaan game tidak mengambil yang sama.
    function Drops.takeBatch(worldName, targets, attempts, retryAt, eligible, token)
        local r = worldCheck(worldName, token)
        local take = App.controls and App.controls.takeDrop or r.world.takeDrop
        assert(type(take) == "function" and type(r.world.dropTaken) == "function",
            "The loose-drop pickup hooks are unavailable. Copy diagnostics from Settings.")
        local jobs, reserved = {}, {}
        local deadline = os.clock() + App.config.options.actionTimeout
        for _, drop in ipairs(targets) do
            if #jobs >= 8 then break end
            worldCheck(worldName, token)
            local present = false
            for _, current in pairs(r.world.dropList()) do if current == drop then present = true; break end end
            local room = drop.id == Drops.GEM and 65535 or math.max(0, r.inventory:room(drop.id) - (reserved[drop.id] or 0))
            local want = math.floor(math.min(drop.n, room, 65535))
            if want > 0 and present and eligible(drop) then
                local before, grid, uid, id = drop.n, r.world.fg, drop.uid, drop.id
                if id ~= Drops.GEM then reserved[id] = (reserved[id] or 0) + want end
                attempts[uid] = (attempts[uid] or 0) + 1
                if App.controls then App.controls.suppressedTakes[uid] = nil end
                drop.taking = true
                local request = Net.beginRequest(function()
                    local ok, result = pcall(function()
                        local amount = take(uid, want)
                        if amount == nil then amount = 0 end
                        assert(type(amount) == "number" and amount >= 0 and amount <= want
                            and amount == math.floor(amount), "Invalid pickup response from the server.")
                        if amount > 0 and r.world.name == worldName and r.world.fg == grid then
                            r.world.dropTaken(uid, math.min(drop.n, math.max(0, before - amount)))
                            if id == Drops.GEM then App.stats.gems = App.stats.gems + amount end
                        elseif amount == 0 then
                            retryAt[uid], drop.refused = os.clock() + 1, os.clock()
                        end
                        return amount
                    end)
                    drop.taking = false
                    assert(ok, tostring(result))
                    return result
                end)
                table.insert(jobs, { request = request, uid = uid, id = id })
            end
        end
        local results = {}
        for _, job in ipairs(jobs) do
            local amount = Net.awaitRequest(job.request, deadline, token)
            if amount > 0 then attempts[job.uid] = 0 end
            table.insert(results, { uid = job.uid, id = job.id, amount = amount })
        end
        return results
    end

    -- Pungut semua drop dengan id di `ids` dalam kotak di sekitar posisi berdiri `anchor`:
    -- |x - tengah| <= radius, dan y dari anchor.y - up sampai anchor.y + down.
    -- Return: tabel { [id] = jumlah yang berhasil dipungut }, dan jumlah drop yang dilewati.
    function Drops.collectNear(anchor, ids, token, options)
        options = options or {}
        local radius, up, down = options.radius or 1.25, options.up or 1.5, options.down or 1.25
        pause(App.config.options.collectDelay, token)
        return Movement.withoutPickups(function()
            local r = worldCheck(anchor.world, token)
            Actions.refreshInventory(token) -- selesaikan pickup bawaan game yang masih jalan
            -- ids = "all" -> semua item (Auto Collect). options.attempts boleh dibawa antar panggilan
            -- supaya drop yang terus ditolak server (kejauhan) tidak di-spam.
            local attempts, retryAt, deadline = options.attempts or {}, {}, os.clock() + App.config.options.actionTimeout
            local collected, gemsTaken, skipped = {}, 0, 0
            local wanted = {}
            local all = ids == "all"
            if not all then for _, id in ipairs(ids) do wanted[id] = true end end
            local function nearby(drop)
                return not drop.display and not drop.pending and type(drop.uid) == "number"
                    and type(drop.n) == "number" and drop.n > 0 and not drop.taking and (all or wanted[drop.id])
                    and type(drop.x) == "number" and type(drop.y) == "number"
                    and math.abs(drop.x - (anchor.x + 0.5)) <= radius
                    and drop.y >= anchor.y - up and drop.y <= anchor.y + down
            end
            while true do
                worldCheck(anchor.world, token)
                if options.stopIf and options.stopIf() then return collected, skipped end
                if options.onEachRound then options.onEachRound() end
                local targets, waiting = {}, false
                skipped = 0
                for _, drop in pairs(r.world.dropList()) do
                    if nearby(drop) then
                        local room = drop.id == Drops.GEM and 65535 or r.inventory:room(drop.id)
                        if room > 0 then
                            retryAt[drop.uid] = retryAt[drop.uid] or ((drop.refused or -math.huge) + 1)
                            if (attempts[drop.uid] or 0) >= 3 then skipped = skipped + 1
                            elseif math.max(drop.readyAt or 0, retryAt[drop.uid]) > os.clock() then waiting = true
                            else table.insert(targets, drop) end
                        end
                    end
                end
                if #targets == 0 then
                    if gemsTaken > 0 and r.gemHud then
                        local ok, gems = pcall(Net.bounded, r.world.call, App.config.options.actionTimeout, token, "GetGems")
                        if ok and type(gems) == "number" then r.gemHud.setGems(gems) end
                    end
                    if not waiting or os.clock() >= deadline then return collected, skipped end
                    pause(0.05, token)
                else
                    local accepted = false
                    for _, result in ipairs(Drops.takeBatch(anchor.world, targets, attempts, retryAt, nearby, token)) do
                        if result.amount > 0 then
                            accepted = true
                            collected[result.id] = (collected[result.id] or 0) + result.amount
                            if result.id == Drops.GEM then gemsTaken = gemsTaken + result.amount end
                        end
                    end
                    if accepted then
                        Actions.refreshInventory(token)
                        deadline = os.clock() + App.config.options.actionTimeout
                    end
                end
            end
        end)
    end

    return Drops
end
