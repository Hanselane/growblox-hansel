-- Tes loader.lua: download dari "GitHub palsu" (file lokal), cek checksum, cache, dan tolak file rusak.
local T = dofile("tests/lib.lua")
local S = T.scheduler()
local fake = T.fakeGame()

local function read(path)
    local f = assert(io.open(path, "rb")); local text = f:read("a"); f:close(); return text
end
local loaderSource = read("loader.lua")
local BASE = loaderSource:match('local BASE = "([^"]+)"')

local downloads, corrupt = {}, false
local files, folders = {}, {}
local env = {}
local services = {
    HttpService = { JSONEncode = function() return "{}" end, JSONDecode = function() return {} end },
    Players = { LocalPlayer = { UserId = 123, GetAttribute = function() return nil end } },
    ReplicatedStorage = { GetAttribute = function() return "key" end },
    Workspace = { GetServerTimeNow = function() return 1000 end },
    UserInputService = { GetFocusedTextBox = function() return nil end },
}
game = {
    GetService = function(_, name) return services[name] end,
    HttpGet = function(_, url)
        table.insert(downloads, url)
        assert(url:sub(1, #BASE) == BASE, "URL di luar repo: " .. url)
        local text = read(url:sub(#BASE + 1))
        if corrupt then text = text:sub(1, -2) .. " " end -- ubah 1 karakter
        return text
    end,
}
-- WindUI asli terlalu berat dijalankan di tes; ganti isinya lewat loadstring palsu
-- yang mengembalikan WindUI tiruan untuk file WindUI, dan kode asli untuk main.
local realLoad = load
local function widget()
    return setmetatable({ ParagraphFrame = { SetTitle = function() end, SetDesc = function() end } },
        { __index = function() return function() return widget() end end })
end
loadstring = function(source, name)
    if name == "WindUI" then
        return function() return { CreateWindow = function() return widget() end, Notify = function() end } end
    end
    return realLoad(source, name)
end
getgenv = function() return env end
task = S.task
UDim2 = { fromOffset = function() return {} end }
getgc, getupvalues = fake.exec.getgc, fake.exec.getupvalues
debug.info = fake.exec.debugInfo
isfile = function(p) return files[p] ~= nil end
readfile = function(p) return files[p] end
writefile = function(p, t) files[p] = t end
isfolder = function(p) return folders[p] == true end
makefolder = function(p) folders[p] = true end

local function runLoader()
    local co = coroutine.create(function() return realLoad(loaderSource, "loader")() end)
    local ok, result = coroutine.resume(co)
    while ok and coroutine.status(co) ~= "dead" do
        S.run(0.1)
        ok, result = coroutine.resume(co)
    end
    if not ok then error(result, 0) end
    return result
end

T.test("loader download, cek checksum, lalu menjalankan main", function()
    local App = runLoader()
    T.eq(type(App) == "table" and App.alive, true, "App jalan")
    T.eq(#downloads, 2, "2 file di-download")
    T.eq(env.GrowbloxHanselLoaderDebug:find("main download", 1, true) ~= nil, true, env.GrowbloxHanselLoaderDebug)
    App.alive = false
end)
T.test("auto-resume menunjuk salinan loader permanen yang isinya sama", function()
    local url = env.GrowbloxHanselLoaderURL
    T.eq(url:match("releases/loader%-%x+%.lua$") ~= nil, true, url)
    T.eq(read(url:sub(#BASE + 1)), loaderSource, "isi salinan = loader.lua")
end)
T.test("load kedua pakai cache, tanpa download", function()
    downloads = {}
    local App = runLoader()
    T.eq(#downloads, 0, "tidak ada download")
    T.eq(env.GrowbloxHanselLoaderDebug:find("main cache", 1, true) ~= nil, true, env.GrowbloxHanselLoaderDebug)
    App.alive = false
end)
T.test("file rusak ditolak dan tidak dijalankan", function()
    files = {} -- kosongkan cache
    corrupt = true
    T.errors(runLoader, "tidak cocok")
    corrupt = false
end)
T.test("loader menolak jalan kalau task masih aktif", function()
    env.GrowbloxHanselApp = { alive = true, job = "pnb", pending = 0 }
    T.errors(runLoader, "Stop task")
    env.GrowbloxHanselApp = nil
end)

S.restore()
print(string.format("\n%d lolos, %d gagal", T.passed, T.failed))
return T.failed
