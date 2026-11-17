-- plant.lua: fitur Planting. Tanam seed di semua world farm, isi ulang dari Display Box, resume setelah pindah server.
-- Diadaptasi dari Clarissv main.lua v0.1.43: clearPlantResume, savePlantResume, readPlantResume, deferPlantTile,
-- confirmPlantBatch, reconcilePlant, plantTile, plantRetryTargets, retryPlantFromBelow, plantRow, runPlant,
-- seedChoices, refreshSeeds, changePlantSetting, resumePlant, dan isi tab Planting.
-- Logika tanam dipertahankan. Cabang Rotation/Botting dibuang dulu; titik sambungnya ditandai "HOOK ROTATION".
return function(G)
    local App, Core, Bridge, Net, Actions, Movement, Storage, State, task =
        G.App, G.Core, G.Bridge, G.Net, G.Actions, G.Movement, G.Storage, G.State, G.task
    local Plant = {}
    local worldCheck, position, checkpoint, pause = Bridge.worldCheck, Bridge.position, Net.checkpoint, Net.pause
    local count, tileAt, refreshInventory = Actions.count, Actions.tileAt, Actions.refreshInventory
    local moveTo, withoutPickups = Movement.moveTo, Movement.withoutPickups

    ---------------------------------------------------------------- checkpoint
    function Plant.clearResume()
        App.plantState = nil
        State.clearCheckpoint("plant")
    end

    -- Simpan progress: world ke berapa, fase (farm/stock/pickupPending), baris, tile yang di-skip,
    -- dan batch seed yang belum terkonfirmasi (pending). Dipanggil SEBELUM setiap aksi berisiko.
    function Plant.saveResume(state)
        State.saveSession()
        local copy = { worldIndex = state.worldIndex, phase = state.phase, skipped = {}, pending = state.pending, deferred = {} }
        if state.rows then
            copy.rows = {}
            for _, row in ipairs(state.rows) do table.insert(copy.rows, { y = row.y, left = row.left, right = row.right }) end
            copy.rowY = state.rowY
        end
        for key, reason in pairs(state.skipped or {}) do copy.skipped[key] = reason end
        for key, point in pairs(state.deferred or {}) do copy.deferred[key] = { x = point.x, y = point.y, tries = point.tries } end
        State.saveCheckpoint("plant", copy)
        App.plantState = state
        if Plant.onSave then Plant.onSave(state) end -- HOOK ROTATION
    end

    -- Baca dan validasi checkpoint. File yang aneh ditolak, bukan ditebak.
    function Plant.readResume(record)
        record = record or State.loadCheckpoint("plant")
        if not record then return nil end
        record.profile = Core.profileName(record.profile)
        local state = record.data
        assert(type(state) == "table" and type(state.worldIndex) == "number" and state.worldIndex == math.floor(state.worldIndex)
            and state.worldIndex >= 1 and state.worldIndex <= #record.config.planting.worlds + 1
            and (state.phase == "farm" or state.phase == "stock" or state.phase == "pickupPending")
            and type(state.skipped) == "table", "Invalid saved planting progress.")
        for key, reason in pairs(state.skipped) do
            assert(type(key) == "string" and key:match("^%d+:%d+$") and type(reason) == "string", "Invalid skipped planting tile.")
        end
        if state.deferred then
            assert(type(state.deferred) == "table", "Invalid deferred planting tiles.")
            for key, point in pairs(state.deferred) do
                assert(type(point) == "table" and Core.integer(point.x, 0, 65535) and Core.integer(point.y, 0, 65535)
                    and key == point.x .. ":" .. point.y and (point.tries == 0 or point.tries == 1), "Invalid deferred planting tile.")
            end
        end
        if state.rows then
            assert(type(state.rows) == "table", "Invalid saved farm rows.")
            for key in pairs(state.rows) do
                assert(Core.integer(key, 1, #state.rows), "Invalid saved farm row list.")
            end
            local previous = -1
            for _, row in ipairs(state.rows) do
                assert(type(row) == "table", "Invalid saved farm row.")
                for _, key in ipairs({ "y", "left", "right" }) do
                    assert(Core.integer(row[key], 0, 65535), "Invalid saved farm row.")
                end
                assert(row.y > previous and row.left <= row.right, "Invalid saved farm row order.")
                previous = row.y
            end
            if state.rowY ~= nil then
                local found = false
                for _, row in ipairs(state.rows) do if row.y == state.rowY then found = true end end
                assert(found, "Invalid saved planting row.")
            end
        else assert(state.rowY == nil, "Missing saved farm rows.") end
        if state.pending then
            local point = state.pending
            assert(state.phase == "farm" and point.world == record.config.planting.worlds[state.worldIndex], "Invalid pending seed world.")
            for _, key in ipairs({ "x", "y", "before" }) do
                assert(Core.integer(point[key], 0, 65535), "Invalid pending seed placement.")
            end
            assert(point.before >= 1 and point.before <= 200, "Invalid pending seed count.")
            if point.tiles then
                assert(type(point.tiles) == "table" and #point.tiles >= 1 and #point.tiles <= 8
                    and #point.tiles <= point.before, "Invalid pending seed batch.")
                local seen = {}
                for key in pairs(point.tiles) do assert(Core.integer(key, 1, #point.tiles), "Invalid pending seed batch list.") end
                for _, tile in ipairs(point.tiles) do
                    assert(type(tile) == "table" and Core.integer(tile.x, 0, 65535) and tile.y == point.y and not seen[tile.x],
                        "Invalid pending seed batch tile.")
                    seen[tile.x] = true
                end
                assert(point.tiles[1].x == point.x, "Invalid pending seed batch origin.")
            end
        end
        record.state = state
        return record
    end

    ---------------------------------------------------------------- tanam
    local function enterFarmWorld(name, state, token)
        Movement.enterWorld(name, token, { label = "planting", resumeButton = "Resume planting",
            save = function() Plant.saveResume(state) end })
    end

    -- Tile yang gagal ditanam ditunda: dicatat di skipped dan deferred (bisa dicoba sekali lagi dari bawah).
    local function deferPlantTile(state, point, reason)
        local key = point.x .. ":" .. point.y
        state.deferred = state.deferred or {}
        local previous = state.deferred[key]
        state.deferred[key] = { x = point.x, y = point.y, tries = previous and previous.tries or 0 }
        state.skipped[key] = reason
    end

    -- Penanaman di game itu "optimis": tile langsung berubah di layar sebelum server setuju.
    -- Fungsi ini menunggu sampai jumlah seed di server dan isi tile cocok, baru batch dianggap selesai.
    -- Seed yang tidak terkonfirmasi tidak membuat task berhenti; tile-nya ditunda.
    local function confirmPlantBatch(state, token, save, lastPlant)
        local pending = state.pending
        if not pending then return end
        local name, id = pending.world, App.config.planting.seedId
        local tiles = pending.tiles or { pending }
        local hold = Movement.takeControls()
        hold.direction, hold.jump = 0, false
        pause(math.max(0, (lastPlant or 0) + 0.2 - os.clock()), token)
        local deadline = os.clock() + App.config.options.actionTimeout
        while true do
            worldCheck(name, token)
            local actual = refreshInventory(token)[id] or 0
            assert(actual <= pending.before and actual >= pending.before - #tiles,
                "Seed count changed unexpectedly while planting. Check diagnostics before resuming.")
            local planted, values = 0, {}
            for index, point in ipairs(tiles) do
                local value = tileAt(point.x, point.y)
                assert(value == 0 or value == id, "A pending planting tile changed to another item. Check the farm before resuming.")
                values[index] = value
                if value == id then planted = planted + 1 end
            end
            local consistent = actual == pending.before - planted
            if consistent or os.clock() >= deadline then
                local stable, settled = true, os.clock() + 0.12
                repeat
                    worldCheck(name, token)
                    for index, point in ipairs(tiles) do
                        if tileAt(point.x, point.y) ~= values[index] then stable = false; break end
                    end
                    if not stable then break end
                    pause(0.03, token)
                until os.clock() >= settled
                for index, point in ipairs(tiles) do
                    if tileAt(point.x, point.y) ~= values[index] then stable = false; break end
                end
                -- Batch sebagian berhasil butuh satu hitungan server lagi sebelum ditutup.
                if stable and (not consistent or planted < #tiles) then
                    stable = (refreshInventory(token)[id] or 0) == actual
                end
                if stable then
                    local confirmed = math.min(planted, pending.before - actual)
                    local assigned, skipped = 0, 0
                    for index, point in ipairs(tiles) do
                        if values[index] == id and assigned < confirmed then assigned = assigned + 1
                        else
                            deferPlantTile(state, point, "placement not confirmed")
                            skipped = skipped + 1
                        end
                    end
                    App.stats.planted = App.stats.planted + confirmed
                    state.pending = nil
                    save(state)
                    if skipped > 0 then
                        App.plantingRecovery = name .. ": skipped " .. skipped .. " unconfirmed tiles near " .. pending.x .. ", " .. pending.y
                        G.setStatus(App.plantingRecovery .. "; continuing and retrying from below where reachable.")
                    end
                    return actual, skipped == 0
                end
            end
            pause(0.15, token)
        end
    end
    Plant.confirmBatch = confirmPlantBatch

    function Plant.reconcile(state, token)
        if state.pending then confirmPlantBatch(state, token, Plant.saveResume) end
    end

    -- Tanam satu tile secara presisi (dipakai untuk tile yang terlewat saat jalan).
    local function plantTile(point, state, token, save)
        save = save or Plant.saveResume
        return withoutPickups(function()
            local name, id = App.config.planting.worlds[state.worldIndex], App.config.planting.seedId
            local r = worldCheck(name, token)
            local before = refreshInventory(token)[id] or 0
            if not Core.plantingTile(r.world, r.items, point.x, point.y) then return false end
            if not r.handlers.canPlace(r.items[id], point.x, point.y) then return false end
            assert(before > 0, "No planting seeds are left in the backpack.")
            state.pending = { world = name, x = point.x, y = point.y, before = before, tiles = { { x = point.x, y = point.y } } }
            save(state)
            r.handlers.plantSeed(id, point.x, point.y)
            local _, confirmed = confirmPlantBatch(state, token, save, os.clock() + math.max(0, App.config.options.placeDelay - 0.2))
            return confirmed
        end)
    end

    -- Tile di baris ATAS yang tertunda, yang masih bisa dijangkau dari baris ini (maks 2,5 tile).
    local function plantRetryTargets(row, state)
        local targets, r = {}, Bridge.runtime()
        for _, point in pairs(state.deferred or {}) do
            local x = math.max(row.left, math.min(row.right, point.x))
            if point.tries == 0 and point.y < row.y and math.abs(point.x - x) <= 2.5
                and math.abs(point.y + 0.5 - (row.y + 1 - 0.475)) <= 2.5
                and Core.plantingTile(r.world, r.items, point.x, point.y) then table.insert(targets, point) end
        end
        table.sort(targets, function(a, b) return a.x * (row.direction or 1) < b.x * (row.direction or 1) end)
        return targets
    end

    -- Coba sekali lagi tile atas yang tertunda, dari posisi berdiri di baris bawah. Tidak pernah loop.
    local function retryPlantFromBelow(row, state, token, save)
        save = save or Plant.saveResume
        local name = App.config.planting.worlds[state.worldIndex]
        local r, attempts = worldCheck(name, token), 0
        local avatar = position()
        if not avatar.grounded or math.abs(avatar.y - (row.y + 1)) > 0.22 then return attempts end
        for _, point in ipairs(plantRetryTargets(row, state)) do
            local anchor = math.max(row.left, math.min(row.right, point.x))
            if math.abs(avatar.x - (anchor + 0.5)) <= 0.55 then
                local key = point.x .. ":" .. point.y
                if not Core.plantingTile(r.world, r.items, point.x, point.y) then state.deferred[key] = nil; save(state)
                elseif count(App.config.planting.seedId) > 0 then
                    point.tries = 1
                    save(state)
                    if r.handlers.canPlace(r.items[App.config.planting.seedId], point.x, point.y) then
                        attempts = attempts + 1
                        G.setStatus("Retrying planting at " .. point.x .. ", " .. point.y .. " from below...")
                        if plantTile(point, state, token, save) then state.skipped[key], state.deferred[key] = nil, nil
                        else state.skipped[key] = "placement refused after lower-row retry" end
                    else state.skipped[key] = "lower-row placement not permitted" end
                    save(state)
                end
            end
        end
        return attempts
    end

    -- Tanam sambil jalan sepanjang satu baris. Batch maks 8 seed; tiap tile dicatat ke checkpoint
    -- SEBELUM seed ditaruh, dan batch dikonfirmasi ke server sebelum batch berikutnya.
    local function plantRow(row, reverse, state, token)
        return withoutPickups(function()
            local name, id = App.config.planting.worlds[state.worldIndex], App.config.planting.seedId
            local r = worldCheck(name, token)
            local points = {}
            for x = reverse and row.right or row.left, reverse and row.left or row.right, reverse and -1 or 1 do
                if not state.skipped[x .. ":" .. row.y] and Core.plantingTile(r.world, r.items, x, row.y) then
                    table.insert(points, { x = x, y = row.y })
                end
            end
            if #points == 0 or count(id) == 0 then return end
            local avatar, first = position(), points[1]
            local ahead = (first.x + 0.5 - avatar.x) * (reverse and -1 or 1)
            if not avatar.grounded or math.abs(avatar.y - (row.y + 1)) > 0.22 or ahead < -1.2 then
                moveTo(first.x, row.y, name, token, function()
                    return Core.rowHasPlantingSpace(r.world, r.items, row, state.skipped)
                end)
            end
            local available = refreshInventory(token)[id] or 0
            local cursor, nextPlant, lastPlant = 1, 0, 0
            local function confirm()
                if state.pending then available = confirmPlantBatch(state, token, Plant.saveResume, lastPlant) end
            end
            local function step(current)
                checkpoint(token)
                worldCheck(name, token)
                for _, point in ipairs(plantRetryTargets(row, state)) do
                    local anchor = math.max(row.left, math.min(row.right, point.x))
                    if current.grounded and math.abs(current.y - (row.y + 1)) <= 0.22
                        and math.abs(current.x - (anchor + 0.5)) <= 0.55 then
                        confirm()
                        retryPlantFromBelow(row, state, token)
                        available = count(id)
                        break
                    end
                end
                if state.pending then
                    local corrected = false
                    for _, point in ipairs(state.pending.tiles) do if tileAt(point.x, point.y) ~= id then corrected = true end end
                    if corrected or #state.pending.tiles >= 8 or count(id) == 0 then confirm() end
                end
                if available == 0 then return false end
                local point = points[cursor]
                if not point then return false end
                current = position()
                local distance = (point.x + 0.5 - current.x) * (reverse and -1 or 1)
                if current.grounded and math.abs(current.y - (row.y + 1)) <= 0.22 and distance < -1.2 then return false end
                if not current.grounded or math.abs(current.y - (row.y + 1)) > 0.22
                    or math.abs(current.x - (point.x + 0.5)) > 1.2
                    or G.focusedTextBox() then return true end
                if os.clock() < nextPlant then return distance <= 0.55 and "hold" or true end
                if not Core.plantingTile(r.world, r.items, point.x, point.y) then cursor = cursor + 1; return true end
                if not r.handlers.canPlace(r.items[id], point.x, point.y) then
                    if math.abs(current.x - (point.x + 0.5)) <= 0.55 then
                        deferPlantTile(state, point, "not permitted")
                        Plant.saveResume(state)
                        cursor = cursor + 1
                    end
                    return true
                end
                local pending = state.pending or { world = name, x = point.x, y = point.y, before = available, tiles = {} }
                table.insert(pending.tiles, { x = point.x, y = point.y })
                state.pending = pending
                Plant.saveResume(state)
                r.handlers.plantSeed(id, point.x, point.y)
                checkpoint(token)
                worldCheck(name, token)
                lastPlant, nextPlant = os.clock(), os.clock() + math.max(0.15, App.config.options.placeDelay)
                cursor = cursor + 1
                if tileAt(point.x, point.y) ~= id then confirm() end
                return true
            end
            local destination, stepFailed = points[#points], false
            local ok, issue = pcall(moveTo, destination.x, row.y, name, token, function(current)
                local succeeded, proceed = pcall(step, current)
                if not succeeded then stepFailed = true; error(proceed, 0) end
                return proceed
            end)
            checkpoint(token)
            worldCheck(name, token)
            if not ok and stepFailed then error(issue, 0) end
            confirm()
            if not ok then error(issue, 0) end
        end)
    end

    local function routeProblem(text)
        return text:find("route", 1, true) or text:find("position", 1, true) or text:find("support", 1, true)
            or text:find("platform", 1, true) or text:find("timed out", 1, true)
    end

    -- Isi semua world farm. Return false kalau box seed habis, true kalau semua farm selesai.
    -- lastWorldIndex: berhenti di farm ini (dipakai Rotation untuk replant satu farm).
    function Plant.run(token, saved, lastWorldIndex)
        return Movement.harvestEquipmentScope(function()
            Movement.suspendHarvestVehicle(token)
            Core.checkSetup(App.config, "plant", Bridge.runtime().items)
            local settings, id = App.config.planting, App.config.planting.seedId
            local state = saved and saved.state or { worldIndex = 1, phase = "farm", skipped = {} }
            assert(state.phase ~= "pickupPending", "A seed storage withdrawal was interrupted. Check the backpack and box, then clear saved planting.")
            Plant.saveResume(state)
            local lastWorld = lastWorldIndex or #settings.worlds
            while state.worldIndex <= lastWorld do
                checkpoint(token)
                if state.phase == "stock" then
                    enterFarmWorld(settings.storageWorld, state, token)
                    local box = App.config.points.plantBox
                    if Storage.countOnly(box, id) == 0 then
                        Plant.clearResume()
                        G.setStatus("Planting stopped: the seed storage box is empty. Unfinished farm: " .. settings.worlds[state.worldIndex])
                        return false
                    end
                    Storage.withdrawSelected(box, id, token, function()
                        state.phase = "pickupPending"
                        Plant.saveResume(state)
                    end)
                    state.phase = "farm"
                    Plant.saveResume(state)
                end
                local name = settings.worlds[state.worldIndex]
                enterFarmWorld(name, state, token)
                assert(Bridge.runtime().handlers and type(Bridge.runtime().handlers.canPlace) == "function"
                    and type(Bridge.runtime().handlers.plantSeed) == "function",
                    "The seed planting hooks are unavailable. Copy diagnostics from Settings.")
                Plant.reconcile(state, token)
                local r, refill, streamedRows = Bridge.runtime(), false, {}
                if not state.rows then state.rows = Core.farmRows(r.world, r.items); Plant.saveResume(state) end
                for _, row in ipairs(state.rows) do
                    assert(row.y < r.world.h - 1 and row.right < r.world.w, "Saved farm rows no longer fit this world. Clear saved planting and start again.")
                end
                G.setStatus("Planting " .. r.items[id].name .. " in " .. name .. " (" .. state.worldIndex .. "/" .. #settings.worlds .. ")...")
                -- Daftar kunjungan: tiap baris diawali penanda retryRow (cek tile atas yang tertunda),
                -- lalu tile kosong baris itu dalam arah zigzag.
                local visits = {}
                for index, row in ipairs(state.rows) do
                    row.direction = index % 2 == 1 and 1 or -1
                    table.insert(visits, { retryRow = row })
                    for x = row.direction == 1 and row.left or row.right, row.direction == 1 and row.right or row.left, row.direction do
                        if Core.plantingTile(r.world, r.items, x, row.y) then table.insert(visits, { x = x, y = row.y }) end
                    end
                end
                for _, point in ipairs(visits) do
                    checkpoint(token)
                    worldCheck(name, token)
                    local key = not point.retryRow and point.x .. ":" .. point.y
                    if point.retryRow then
                        local row = point.retryRow
                        local targets = plantRetryTargets(row, state)
                        if #targets > 0 and not Core.rowHasPlantingSpace(r.world, r.items, row, state.skipped) then
                            if count(id) == 0 then refill = true; break end
                            local arrived, issue = pcall(function()
                                local firstTarget, lastTarget = targets[1], targets[#targets]
                                moveTo(math.max(row.left, math.min(row.right, firstTarget.x)), row.y, name, token)
                                moveTo(math.max(row.left, math.min(row.right, lastTarget.x)), row.y, name, token, function()
                                    retryPlantFromBelow(row, state, token)
                                    return count(id) > 0 and #plantRetryTargets(row, state) > 0
                                end)
                            end)
                            checkpoint(token)
                            worldCheck(name, token)
                            if not arrived then
                                if state.pending or type(issue) == "table" and issue.recoverable then error(issue, 0) end
                                local text = tostring(issue)
                                assert(routeProblem(text), text)
                                for _, target in ipairs(targets) do
                                    target.tries = 1
                                    state.skipped[target.x .. ":" .. target.y] = "lower-row approach unreachable"
                                end
                                Plant.saveResume(state)
                            end
                        end
                    elseif not state.skipped[key] and Core.plantingTile(r.world, r.items, point.x, point.y) then
                        if count(id) == 0 then refill = true; break end
                        local permitted = not r.world.areas or type(r.world.areas.canEdit) ~= "function" or r.world.areas.canEdit(point.x, point.y)
                        local arrived, issue = true, nil
                        if permitted then
                            arrived, issue = pcall(function()
                                if state.rowY ~= point.y then
                                    for index, row in ipairs(state.rows) do
                                        if row.y == point.y then
                                            local reached = moveTo(index % 2 == 1 and row.left or row.right, row.y, name, token, function()
                                                return Core.rowHasPlantingSpace(r.world, r.items, row, state.skipped)
                                            end)
                                            if reached == false then return end
                                            break
                                        end
                                    end
                                    state.rowY = point.y
                                    Plant.saveResume(state)
                                end
                                if not streamedRows[point.y] then
                                    streamedRows[point.y] = true
                                    for index, row in ipairs(state.rows) do
                                        if row.y == point.y then plantRow(row, index % 2 == 0, state, token); break end
                                    end
                                end
                                if not state.skipped[key] and Core.plantingTile(r.world, r.items, point.x, point.y) then
                                    moveTo(point.x, point.y, name, token)
                                end
                            end)
                        end
                        checkpoint(token)
                        worldCheck(name, token)
                        if not arrived then
                            -- Timeout saat konfirmasi batch TIDAK boleh dianggap tile tak terjangkau.
                            if state.pending then error(issue, 0) end
                            if type(issue) == "table" and issue.recoverable then error(issue, 0) end
                            local text = tostring(issue)
                            assert(routeProblem(text), text)
                            if Core.plantingTile(r.world, r.items, point.x, point.y) then deferPlantTile(state, point, "unreachable") end
                        elseif not permitted or (not state.skipped[key] and Core.plantingTile(r.world, r.items, point.x, point.y)
                            and count(id) > 0 and not plantTile(point, state, token)) then
                            deferPlantTile(state, point, state.skipped[key] or "not permitted")
                        end
                        if state.skipped[key] then Plant.saveResume(state) end
                    end
                end
                if refill then
                    state.phase = "stock"
                else
                    local skipped = 0
                    for _ in pairs(state.skipped) do skipped = skipped + 1 end
                    if Plant.onFarmDone then Plant.onFarmDone(r, name, token) end -- HOOK ROTATION
                    G.setStatus("Processed " .. name .. ": " .. skipped .. " tiles skipped due to access or route. Moving to the next farm.")
                    state.worldIndex, state.skipped, state.rows, state.rowY, state.deferred = state.worldIndex + 1, {}, nil, nil, {}
                end
                Plant.saveResume(state)
            end
            Plant.clearResume()
            G.setStatus((lastWorldIndex and "Finished replanting " .. settings.worlds[lastWorldIndex] .. "."
                or "Finished planting all configured farms.") .. " Seeds planted this session: " .. App.stats.planted)
            return true
        end)
    end

    ---------------------------------------------------------------- daftar job
    G.Jobs.register("plant", {
        label = "Planting",
        prepare = function(r)
            assert(r.body and r.controls and type(r.inventory.room) == "function" and type(r.inventory.add) == "function"
                and type(r.inventory.remove) == "function", "Collection and planting need the live backpack and movement hooks.")
            assert(r.handlers and type(r.handlers.canPlace) == "function" and type(r.handlers.plantSeed) == "function",
                "The seed planting hooks are unavailable. Copy diagnostics from Settings.")
        end,
        -- Error "recoverable" (balik ke world picker, avatar belum siap) dilanjut dari checkpoint terakhir.
        run = function(token, saved)
            local progress = saved
            while true do
                local completed, problem = pcall(Plant.run, token, progress)
                if completed then break end
                checkpoint(token)
                if type(problem) == "table" and problem.recoverable and App.config.options.autoRejoin then
                    progress = { state = App.plantState }
                    assert(progress.state and progress.state.phase ~= "pickupPending", "Seed withdrawal was interrupted. Check the backpack before resuming.")
                    G.setStatus("Planting interrupted; returning to its saved world...")
                else error(problem, 0) end
            end
        end,
        clear = function() Plant.clearResume() end,
    })

    function Plant.resume()
        Net.idle()
        local saved = Plant.readResume()
        assert(saved, "No saved planting task is available.")
        assert(saved.state.phase ~= "pickupPending", "A seed withdrawal was interrupted. Check the backpack and storage, then clear saved planting.")
        App.config, App.profile = saved.config, saved.profile
        if Plant.syncInputs then Plant.syncInputs() end
        G.Jobs.start("plant", saved)
    end
    -- Auto-resume setelah pindah server.
    table.insert(G.resumeHandlers, function()
        if not Plant.readResume() then return false end
        Plant.resume()
        return true
    end)

    ---------------------------------------------------------------- pilihan seed
    -- Daftar seed untuk dropdown: seed di tas, di box tersimpan, seed dari blok terpilih,
    -- plus hasil pencarian nama/ID. Maksimal 40 pilihan.
    function Plant.seedChoices(query)
        local r = Bridge.runtime()
        local candidates, seen, relevant = {}, {}, {}
        query = (query or ""):match("^%s*(.-)%s*$"):lower()
        local selectedId, selected = App.config.planting.seedId, nil
        for _, slot in pairs(r.inventory.slots) do relevant[slot.id] = true end
        local box = App.config.points.plantBox
        if box and box.world == r.world.name then
            local ok, rows = pcall(Storage.boxRows, box)
            if ok then for _, row in pairs(rows) do relevant[row[1]] = true end end
        end
        if App.config.blockId > 0 then
            local ok, seed = pcall(Core.seedId, r.items, App.config.blockId)
            if ok then relevant[seed] = true end
        end
        local function consider(id)
            if seen[id] or type(id) ~= "number" then return end
            seen[id] = true
            local item = r.items[id]
            if type(item) ~= "table" or item.kind ~= "seed" then return end
            local name = item.name or ("Seed " .. id)
            if id == selectedId or query == "" or name:lower():find(query, 1, true) or tostring(id) == query then
                local label = name .. " [" .. id .. "]"
                table.insert(candidates, { id = id, label = label, rank = id == selectedId and 0 or relevant[id] and 1 or 2 })
                if id == selectedId then selected = label end
            end
        end
        consider(selectedId)
        for id in pairs(relevant) do consider(id) end
        if query ~= "" then
            local scanned = 0
            for id in pairs(r.items) do
                scanned = scanned + 1
                if scanned % 512 == 0 then task.wait() end
                consider(id)
            end
        end
        table.sort(candidates, function(a, b) return a.rank < b.rank or a.rank == b.rank and a.label < b.label end)
        local labels, lookup = {}, {}
        for index = 1, math.min(40, #candidates) do
            local choice = candidates[index]
            labels[index], lookup[choice.label] = choice.label, choice.id
        end
        table.sort(labels)
        return labels, lookup, selected, #candidates > #labels
    end

    ---------------------------------------------------------------- tab Planting
    function Plant.buildTab(tab)
        local UI = G.UI
        local controls, seedLabels, seedSearch, generation = {}, {}, "", 0
        local syncing = true

        local function refreshSeeds(syncInputs)
            if not App.runtime then return end
            local labels, lookup, selected, more = Plant.seedChoices(seedSearch)
            syncing = true
            seedLabels = lookup
            controls.seed.Value = selected
            controls.seed:Refresh(labels)
            if syncInputs ~= false then Plant.syncInputs() end
            UI.paragraph(controls.choices, "Seed choices", more and "Showing up to 40 choices. Narrow the search to find another seed."
                or "Showing backpack seeds, the selected seed, and seeds in your saved box. Search by name or exact ID for other seeds.")
            syncing = false
        end
        Plant.refreshSeeds = refreshSeeds

        function Plant.syncInputs()
            local was = syncing
            syncing = true
            pcall(function() controls.storageWorld:Set(App.config.planting.storageWorld) end)
            pcall(function() controls.worlds:Set(table.concat(App.config.planting.worlds, ", ")) end)
            UI.paragraph(controls.point, "Planting seed storage", Storage.pointText(App.config.points.plantBox))
            syncing = was
        end

        local function changeSetting(key, value)
            if syncing or App.syncingUI then return end
            local ok, message = pcall(function()
                Net.idle()
                if key == "seedId" then value = assert(seedLabels[value], "Choose a seed.")
                elseif key == "worlds" then value = Core.parseWorlds(value)
                elseif value ~= "" then value = Core.worldName(value) end
                local candidate = Core.validate(App.config)
                candidate.planting[key] = value
                App.config.planting = Core.validatePlanting(candidate.planting)
                State.saveSession()
            end)
            if not ok then G.notify(tostring(message)) end
        end

        UI.addStatus(tab:Paragraph({ Title = "Status", Desc = App.status }))
        tab:Paragraph({ Title = "Fill dirt farms with seeds", Desc = "Start at the top-left supported farm row and alternate left-to-right and right-to-left down the farm. Skip occupied, floating, and denied tiles. Refill from the saved seed Display Box and resume the same row direction, then continue through your farm world list." })
        controls.search = tab:Input({ Title = "Find seed by name or ID", Value = "", Placeholder = "e.g. Sugar Cane or 955",
            Callback = function(value)
                if syncing or App.syncingUI then return end
                seedSearch, generation = tostring(value or ""), generation + 1
                local mine = generation
                task.spawn(function()
                    task.wait(0.25)
                    if not App.alive or mine ~= generation then return end
                    local ok, issue = pcall(refreshSeeds, false)
                    if not ok and App.alive then G.notify(tostring(issue)) end
                end)
            end })
        controls.choices = tab:Paragraph({ Title = "Seed choices", Desc = "Backpack and saved seed choices load after connecting. Search to find other seeds." })
        controls.seed = tab:Dropdown({ Title = "Seed to plant", Values = {}, SearchBarEnabled = true,
            Callback = function(value)
                if type(value) == "table" then value = value[1] end
                changeSetting("seedId", value)
            end })
        controls.storageWorld = tab:Input({ Title = "Seed storage world", Value = App.config.planting.storageWorld,
            Placeholder = "e.g. ZZ4", Callback = function(value) changeSetting("storageWorld", value) end })
        controls.worlds = tab:Input({ Title = "Dirt farm worlds (in order)", Value = table.concat(App.config.planting.worlds, ", "),
            Placeholder = "FARM1, FARM2, FARM3", Callback = function(value) changeSetting("worlds", value) end })
        controls.point = tab:Paragraph({ Title = "Planting seed storage", Desc = Storage.pointText(App.config.points.plantBox) })
        tab:Button({ Title = "Save seed Display Box", Desc = "Berdiri di samping box seed. Box boleh berisi item lain; yang diambil cuma seed yang dipilih. Box berisi 1 jenis seed langsung memilih seed itu.",
            Callback = UI.action(function()
                local point = Storage.captureNearby("plantBox", "box")
                App.config.planting.storageWorld = Core.worldName(Bridge.runtime().world.name)
                -- Box berisi tepat 1 jenis seed = seed itu otomatis dipilih. Box campur boleh.
                local seed, seeds = nil, 0
                for _, row in pairs(Storage.boxRows(point)) do
                    local item = Bridge.runtime().items[row[1]]
                    if item and item.kind == "seed" and row[1] ~= seed then seed, seeds = row[1], seeds + 1 end
                end
                if seeds == 1 then App.config.planting.seedId = seed end
                refreshSeeds()
                G.setStatus("Saved planting seed storage: " .. Storage.pointText(point))
            end) })
        tab:Button({ Title = "Refresh seed choices", Callback = UI.action(refreshSeeds) })
        G.Jobs.toggles.plant = tab:Toggle({ Title = "Plant seeds", Value = false,
            Desc = "On plants and refills automatically. Off stops. Unreachable or denied tiles are reported and skipped.",
            Callback = function(enabled) G.Jobs.setRunning("plant", enabled) end })
        tab:Button({ Title = "Resume planting", Desc = "Restore the seed, world list, and progress after a server change or interruption.",
            Callback = function() local ok, message = pcall(Plant.resume); if not ok then G.notify(tostring(message)) end end })
        tab:Button({ Title = "Clear saved planting", Desc = "Use after checking an interrupted storage withdrawal or seed placement.",
            Callback = UI.action(function() Plant.clearResume(); G.setStatus("Cleared saved planting.") end) })
        syncing = false
        -- Setelah tersambung ke game, isi pilihan seed.
        table.insert(G.onConnected, function() pcall(refreshSeeds) end)
    end

    return Plant
end
