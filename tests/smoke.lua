-- Smoke test: jalankan dist/main.lua (hasil build) di "Roblox palsu" dari awal sampai tersambung.
local T = dofile("tests/lib.lua")
local S = T.scheduler()
local game_ = T.fakeGame()
game_.worldCopies = 0 -- skenario bug Clarissv: script jalan sebelum world selesai loading

-- WindUI palsu: semua method mengembalikan objek yang bisa dipanggil apa saja.
local created = { tabs = {}, buttons = {} }
local function widget()
    return setmetatable({ ParagraphFrame = { SetTitle = function() end, SetDesc = function(_, d) created.lastDesc = d end } },
        { __index = function(self, key)
            return function(_, arg)
                if key == "Tab" then table.insert(created.tabs, arg.Title) end
                if key == "Button" then created.buttons[arg.Title] = arg.Callback end
                return widget()
            end
        end })
end
local env = { GrowbloxHanselWindUI = { CreateWindow = function() return widget() end, Notify = function() end } }

local files = {}
local attributes = {}
local services = {
    HttpService = { JSONEncode = function(_, v) return "{}" end, JSONDecode = function() return {} end },
    Players = { LocalPlayer = { UserId = 123, GetAttribute = function() return nil end } },
    ReplicatedStorage = { GetAttribute = function(_, key) return attributes[key] end },
    Workspace = { GetServerTimeNow = function() return 1000 end },
}
game = { GetService = function(_, name) return services[name] end }
getgenv = function() return env end
task = S.task
UDim2 = { fromOffset = function() return {} end }
getgc, getupvalues = game_.exec.getgc, game_.exec.getupvalues
debug.info = game_.exec.debugInfo
isfile = function(p) return files[p] ~= nil end
readfile = function(p) return files[p] end
writefile = function(p, t) files[p] = t end
isfolder = function() return true end
makefolder = function() end

local chunk = assert(loadfile("dist/main.lua"))
local App

T.test("bundle dimuat dan UI terbentuk", function()
    App = chunk()
    T.eq(App.alive, true)
    T.eq(#created.tabs, 5, "jumlah tab")
    T.eq(created.buttons["Reconnect to game"] ~= nil, true, "tombol Reconnect")
end)
T.test("startup nunggu atribut Qz, lalu retry sampai world dimuat", function()
    S.run(2)
    T.eq(App.runtime, nil, "belum connect sebelum Qz ada")
    attributes.Qz = "key"
    S.run(6)
    T.eq(App.runtime, nil, "world belum dimuat")
    T.eq(App.status:find("Coba lagi", 1, true) ~= nil, true, "status menunjukkan retry: " .. App.status)
    game_.worldCopies = 1
    S.run(6)
    T.eq(App.runtime ~= nil, true, "tersambung setelah world dimuat")
    T.eq(App.status, "Tersambung ke NDJD.")
end)
T.test("unload menghentikan script", function()
    created.buttons["Unload script"]()
    S.run(1)
    T.eq(App.alive, false)
    T.eq(env.GrowbloxHanselApp, nil, "referensi global dibersihkan")
end)

S.restore()
print(string.format("\n%d lolos, %d gagal", T.passed, T.failed))
return T.failed
