-- MDFX_FarmingDestroyResync 離線自我檢查
-- 用法（repo 根目錄）： lua scripts/test_farming_destroy_resync.lua [--mutants]
--
-- 照載本機遊戲的原版 shared/ISBaseObject.lua、client/Map/CGlobalObjectSystem.lua、CGlobalObject.lua、
-- client/Farming/CPlantGlobalObject.lua、CFarmingSystem.lua（PZ_HOME 可改安裝目錄）；Java 端用 Lua 照形狀模擬：
--   * 客戶端全域物件的 modData 一開始只有座標（農作系統沒設 objectSyncKeys，SGlobalObjects.java:103-135）
--   * GlobalObject.destroyThisObject（GlobalObject.java:85-98）：rawget("state") 是 "destroyed" 就返回，
--     否則播音效、照名字取 CFarmingSystem.destroyPlant 呼叫（pcallvoid）
--   * 伺服器的作物狀態只寫進地圖物件的 modData（ObjectModData 封包）
--   * getFilenameOfClosure 回函式來源檔（LuaManager.java:7278-7283）
-- 驗證：
--   * 對照組（不載補丁）重現洪流：伺服器上已踩爛的作物，每次車輛更新都送一次 destroy、播一次音效
--   * 修正組：第一次就不送，之後 Java 在開頭返回、不再進 Lua；活作物照送，伺服器狀態到了才停
--   * "destroy"（地圖內建枯作物）、dead、沒有地圖物件、沒有全域物件、square nil 照原版送
--   * 查詢出錯照原版送並印一次；instance 還沒建時照原版送
--   * 只印一次、計數；形狀不符／別的 MOD 換掉 destroyPlant 印 NOT installed；重複載入不疊；ResetLua 後重新安裝
-- 伺服器那一半（server/Fixes/MDFX_FarmingDestroyResyncServer.lua）：照載本機原版 SFarmingSystem.lua 的 OnClientCommand 與
-- 真的 MDFX_Guard.lua；Java 的 receiveClientCommand 用 rawget＋metatable 取函式（KahluaTableImpl.java:100）。驗證：
--   * 對照組每包都分派（外層的別的 MOD 檢查每包都跑）；修正組打到已 destroyed 的 destroy 不分派、外層 0 次
--   * 補送地圖物件 modData 同一株每個 1 秒視窗最多一次（鍵是伺服器的作物，客戶端的小數座標繞不過）；沒有地圖物件時照樣不分派
--   * 地圖物件的 state 還不是 destroyed：照原版分派（讓原版把權威狀態寫回去）
--   * 活作物、別的指令、座標不是數字、args 不是表、沒有作物、查詢出錯：照原版分派
--   * 不是 dedicated server 不安裝；形狀不符／別的 MOD 的版本（含同路徑同檔名）不安裝；OnGameBoot 復查不疊、
--     被別的 MOD 串接包住也不誤報；ResetLua 後重新安裝
-- --mutants：逐一抽掉每道防線（兩支檔都算），確認至少一項檢查轉紅。

local PZ_HOME = os.getenv("PZ_HOME") or "D:/SteamLibrary/steamapps/common/ProjectZomboid"
local VANILLA = PZ_HOME .. "/media/lua/"
local FIX = "MOD/MinidoracatFixesFor42/Contents/mods/MinidoracatFixesFor42/42/media/lua/client/Fixes/MDFX_FarmingDestroyResync.lua"
local CFARMING_PATH = PZ_HOME .. "/media/lua/client/Farming/CFarmingSystem.lua"
local SERVER_FIX = "MOD/MinidoracatFixesFor42/Contents/mods/MinidoracatFixesFor42/42/media/lua/server/Fixes/MDFX_FarmingDestroyResyncServer.lua"
local GUARD = "MOD/MinidoracatFixesFor42/Contents/mods/MinidoracatFixesFor42/42/media/lua/shared/Fixes/MDFX_Guard.lua"
local SFARMING_PATH = PZ_HOME .. "/media/lua/server/Farming/SFarmingSystem.lua"

local realPrint = print

local function readFile(path)
    local f = assert(io.open(path, "rb"))
    local s = f:read("*a")
    f:close()
    return s
end

local SOURCES = { fix = readFile(FIX), server = readFile(SERVER_FIX) }
local GUARD_SRC = readFile(GUARD)
local ONCLIENT_SRC = assert(readFile(SFARMING_PATH):match("function SFarmingSystem:OnClientCommand%(command, playerObj, args%)\r?\n.-\r?\nend"),
    "vanilla SFarmingSystem:OnClientCommand not found")
local VANILLA_FILES = {
    { "ISBaseObject.lua", readFile(VANILLA .. "shared/ISBaseObject.lua") },
    { "CGlobalObjectSystem.lua", readFile(VANILLA .. "client/Map/CGlobalObjectSystem.lua") },
    { "CGlobalObject.lua", readFile(VANILLA .. "client/Map/CGlobalObject.lua") },
    { "CPlantGlobalObject.lua", readFile(VANILLA .. "client/Farming/CPlantGlobalObject.lua") },
    { "CFarmingSystem.lua", readFile(VANILLA .. "client/Farming/CFarmingSystem.lua") },
}

-- ── 假 Java 端 ─────────────────────────────────────────────────────
local prints, errors, handlers, squares, systems, sent, sounds

local function key(x, y, z) return string.format("%d,%d,%d", x, y, z) end

local function newJavaSystem(name)
    local sys = { name = name, modData = {}, objects = {}, lookup = {} }
    function sys:getModData() return self.modData end
    function sys:getObjectAt(x, y, z) return self.lookup[key(x, y, z)] end
    function sys:newObject(x, y, z)
        local go = { x = x, y = y, z = z, modData = {} }
        function go:getModData() return self.modData end
        function go:getX() return self.x end
        function go:getY() return self.y end
        function go:getZ() return self.z end
        self.objects[#self.objects + 1] = go
        self.lookup[key(x, y, z)] = go
        return go
    end
    function sys:getObjectCount() return #self.objects end
    function sys:getObjectByIndex(i) return self.objects[i + 1] end
    function sys:sendCommand(command, playerObj, args)
        sent[#sent + 1] = { command = command, x = args.x, y = args.y, z = args.z }
    end
    return sys
end

local function resetEnv(opts)
    opts = opts or {}
    prints, errors, handlers, squares, systems, sent, sounds = {}, {}, {}, {}, {}, {}, 0
    print = function(...)
        local parts = {}
        for i = 1, select("#", ...) do parts[i] = tostring(select(i, ...)) end
        prints[#prints + 1] = table.concat(parts, " ")
    end
    require = function() end
    getDebug = function() return false end
    isClient = function() return true end
    getSpecificPlayer = function() return { id = 0 } end
    getFilenameOfClosure = function(fn)
        local src = debug.getinfo(fn, "S").source
        if src == "=CFarmingSystem.lua" then return CFARMING_PATH end
        return "C:/Users/x/Zomboid/mods/Other/42/media/lua/client/" .. src:gsub("^[=@]", "")
    end
    Events = setmetatable({}, { __index = function(t, name)
        local ev = { Add = function(fn)
            handlers[name] = handlers[name] or {}
            handlers[name][#handlers[name] + 1] = fn
        end, Remove = function() end }
        rawset(t, name, ev)
        return ev
    end })
    getCell = function()
        return { getGridSquare = function(_, x, y, z) return squares[key(x, y, z)] end }
    end
    CGlobalObjects = {
        registerSystem = function(name)
            local sys = newJavaSystem(name)
            systems[#systems + 1] = sys
            return sys
        end,
        getSystemCount = function() return #systems end,
        getSystemByIndex = function(i) return systems[i + 1] end,
    }
    ISBaseObject, CGlobalObjectSystem, CGlobalObject, CPlantGlobalObject, CFarmingSystem = nil, nil, nil, nil, nil
    MDFX_FarmingDestroyResync = nil
end

local function makeSquare(x, y, z, isoMd)
    local list = {}
    if isoMd then
        local iso = { md = isoMd }
        function iso:hasModData() return true end
        function iso:getModData() return self.md end
        list[1] = iso
    end
    local sq = { x = x, y = y, z = z }
    function sq:getX() return self.x end
    function sq:getY() return self.y end
    function sq:getZ() return self.z end
    function sq:getObjects()
        return { size = function() return #list end, get = function(_, i) return list[i + 1] end }
    end
    squares[key(x, y, z)] = sq
    return sq, list[1]
end

-- 伺服器透過登入清單／新增封包建的客戶端全域物件：只有座標（CGlobalObjects.java:28-68）
local function addGlobal(x, y, z)
    local inst = CFarmingSystem.instance
    local go = inst.system:newObject(x, y, z)
    inst:newLuaObject(go)
    return go
end

-- GlobalObject.destroyThisObject（GlobalObject.java:85-98）
local function javaDestroy(go, sq)
    if rawget(go:getModData(), "state") == "destroyed" then return end
    sounds = sounds + 1
    local fn = CFarmingSystem and CFarmingSystem.destroyPlant
    if fn then
        local ok, err = pcall(fn, sq)
        if not ok then errors[#errors + 1] = tostring(err) end
    end
end

local function frames(n, go, sq)
    for _ = 1, n do javaDestroy(go, sq) end
end

local function printCount(needle)
    local n = 0
    for i = 1, #prints do
        if prints[i]:find(needle, 1, true) then n = n + 1 end
    end
    return n
end

local function skipped() return MDFX_FarmingDestroyResync and MDFX_FarmingDestroyResync.skipped end

local function isoPlant(state)
    return { state = state, nbOfGrow = 4, health = 0, typeOfSeed = "Carrots", waterLvl = 0 }
end

-- ── 伺服器那一半 ─────────────────────────────────────────────────────
local srv

local function serverEnv(opts)
    opts = opts or {}
    resetEnv()
    isServer = function() return not opts.notServer end
    isClient = function() return false end
    srv = { now = 0, dispatched = 0, outer = 0, resent = 0, plants = {} }
    getTimestampMs = function() return srv.now end
    getFilenameOfClosure = function(fn)
        local src = debug.getinfo(fn, "S").source
        if src == "=SFarmingSystem.lua" then return SFARMING_PATH end
        return "C:/Users/x/Zomboid/mods/Other/42/media/lua/server/" .. src:gsub("^[=@]", "")
    end
    MDFX_Guard = nil
    assert(load(GUARD_SRC, "=MDFX_Guard.lua"))()
    if opts.noClass then
        SFarmingSystem = nil
    else
        SFarmingSystem = {}
        SFarmingSystem.__index = SFarmingSystem
        -- Java 把座標向零截成整數（KahluaNumberConverter.java:28-30 的 Double.intValue()）
        local function trunc(n) return n >= 0 and math.floor(n) or -math.floor(-n) end
        function SFarmingSystem:getLuaObjectAt(x, y, z) return srv.plants[key(trunc(x), trunc(y), trunc(z))] end
        assert(load(ONCLIENT_SRC, "=SFarmingSystem.lua"))()
        srv.inst = setmetatable({}, SFarmingSystem)
    end
    SFarmingSystemCommands = {}
    for _, name in ipairs({ "destroy", "water" }) do
        local inner = function() srv.dispatched = srv.dispatched + 1 end
        -- 別的 MOD 包在每個指令外面的檢查（例如安全屋權限，Permissions.lua 的 wrapFarmingCommands）
        SFarmingSystemCommands[name] = function(p, a)
            srv.outer = srv.outer + 1
            return inner(p, a)
        end
    end
end

local function serverPlant(x, y, z, state, noIso, isoState)
    local iso = nil
    if not noIso then
        local md = { state = isoState or state }
        iso = { transmitModData = function() srv.resent = srv.resent + 1 end, getModData = function() return md end }
    end
    local p = { state = state }
    function p:getIsoObject() return iso end
    srv.plants[key(x, y, z)] = p
end

-- SGlobalObjectSystem.receiveClientCommand（SGlobalObjectSystem.java:111-117）
local function javaReceive(command, args, times)
    for _ = 1, times or 1 do
        local fn = rawget(srv.inst, "OnClientCommand") or rawget(getmetatable(srv.inst), "OnClientCommand")
        local ok, err = pcall(fn, srv.inst, command, { id = 1 }, args)
        if not ok then errors[#errors + 1] = tostring(err) end
    end
end

local function serverSkipped() return MDFX_FarmingDestroyResync and MDFX_FarmingDestroyResync.serverSkipped end
local function bootEvents() for _, fn in ipairs(handlers.OnGameBoot or {}) do fn() end end

local function serverChecks(srcs, check)
    local function loadServer() assert(load(srcs.server, "=MDFX_FarmingDestroyResyncServer.lua"))() end
    local at = { x = 100, y = 200, z = 0 }

    -- S1. 對照組：每包都分派
    serverEnv()
    serverPlant(100, 200, 0, "destroyed")
    javaReceive("destroy", at, 100)
    check("S1 對照組：100 包 destroy 全部分派、外層檢查 100 次", srv.dispatched == 100 and srv.outer == 100, srv.dispatched)

    -- S2. 修正組：不分派、補送節流、只印一次
    serverEnv()
    loadServer()
    bootEvents()
    serverPlant(100, 200, 0, "destroyed")
    javaReceive("destroy", at, 100)
    check("S2 已 destroyed：100 包 0 次分派、外層 0 次", srv.dispatched == 0 and srv.outer == 0, srv.outer)
    check("S2 計數 100", serverSkipped() == 100, serverSkipped())
    check("S2 同一毫秒內只補送一次 modData", srv.resent == 1, srv.resent)
    srv.now = 999
    javaReceive("destroy", at)
    check("S2 不到 1 秒不再補送", srv.resent == 1, srv.resent)
    srv.now = 1000
    javaReceive("destroy", at)
    check("S2 滿 1 秒再補送一次", srv.resent == 2, srv.resent)
    serverPlant(110, 200, 0, "destroyed")
    javaReceive("destroy", { x = 110, y = 200, z = 0 })
    check("S2 另一株同一毫秒也補送", srv.resent == 3, srv.resent)
    javaReceive("destroy", { x = 100.25, y = 200, z = 0 })
    javaReceive("destroy", { x = 100.75, y = 200.5, z = 0 })
    check("S2 小數座標截成同一株：不多補送", srv.resent == 3 and srv.dispatched == 0, srv.resent)
    srv.now = 500  -- 系統時鐘往回調到視窗開始之前
    serverPlant(120, 200, 0, "destroyed")
    javaReceive("destroy", { x = 120, y = 200, z = 0 })
    srv.now = 1500
    javaReceive("destroy", { x = 120, y = 200, z = 0 })
    check("S2 時鐘往回調：從回調後算新視窗，1 秒後照樣補送", srv.resent == 5, srv.resent)
    check("S2 一行診斷，帶座標", printCount("MDFX_FarmingDestroyResync crop at 100,200,0 is already destroyed; ignored") == 1,
        table.concat(prints, " | "))
    check("S2 零錯誤", #errors == 0, table.concat(errors, " | "))

    -- S3～S6. 照原版分派
    serverPlant(101, 200, 0, "seeded", false, "destroyed")  -- 全域作物才是權威，地圖物件舊了也照分派
    serverPlant(102, 200, 0, "destroyed", true)
    local before = srv.dispatched
    javaReceive("destroy", { x = 101, y = 200, z = 0 })
    check("S3 活作物（地圖物件停在 destroyed）：照原版分派", srv.dispatched == before + 1)
    javaReceive("water", at)
    check("S4 別的指令打到已 destroyed：照原版分派", srv.dispatched == before + 2)
    javaReceive("destroy", { x = "100", y = "200", z = "0" })
    javaReceive("destroy", nil)
    javaReceive("destroy", { x = 103, y = 200, z = 0 })
    check("S5 座標不是數字、args 不是表、沒有作物：照原版分派、不印錯誤", srv.dispatched == before + 5
        and printCount("could not read") == 0, table.concat(prints, " | "))
    local resent = srv.resent
    javaReceive("destroy", { x = 102, y = 200, z = 0 })
    check("S6 沒有地圖物件：照樣不分派、不補送", srv.dispatched == before + 5 and srv.resent == resent and #errors == 0,
        table.concat(errors, " | "))
    serverPlant(111, 200, 0, "destroyed", false, "seeded")
    javaReceive("destroy", { x = 111, y = 200, z = 0 })
    check("S6 地圖物件還不是 destroyed：照原版分派、不補送", srv.dispatched == before + 6 and srv.resent == resent)
    before = before + 1

    -- S7. 查詢出錯：照原版分派、只印一次
    SFarmingSystem.getLuaObjectAt = function() error("lookup boom") end
    javaReceive("destroy", at, 3)
    check("S7 查詢出錯：照原版分派、只印一行", srv.dispatched == before + 8 and printCount("could not read the crop") == 1,
        table.concat(prints, " | "))

    -- S8. 不是 dedicated server：不安裝
    serverEnv({ notServer = true })
    local vanilla = SFarmingSystem.OnClientCommand
    loadServer()
    bootEvents()
    check("S8 不是 dedicated server：不安裝", SFarmingSystem.OnClientCommand == vanilla)

    -- S9. 形狀不符、別的 MOD 的版本、沒有 getFilenameOfClosure：不安裝、不拋錯
    serverEnv({ noClass = true })
    local ok9 = pcall(loadServer)
    check("S9 沒有 SFarmingSystem：印 NOT installed、不拋錯", ok9 and printCount("NOT installed") == 1)
    serverEnv()
    getFilenameOfClosure = nil
    vanilla = SFarmingSystem.OnClientCommand
    local ok9b = pcall(loadServer)
    check("S9 沒有 getFilenameOfClosure：印 NOT installed、不包", ok9b and printCount("NOT installed") == 1
        and SFarmingSystem.OnClientCommand == vanilla)
    serverEnv()
    local theirs = assert(load("return function(self, command, playerObj, args) end", "=OtherMod.lua"))()
    SFarmingSystem.OnClientCommand = theirs
    loadServer()
    check("S9 別的 MOD 的版本：印 NOT installed、不包", SFarmingSystem.OnClientCommand == theirs
        and printCount("NOT installed: SFarmingSystem.OnClientCommand comes from") == 1, table.concat(prints, " | "))
    serverEnv()
    theirs = assert(load("return function(self, command, playerObj, args) end", "=Farming/SFarmingSystem.lua"))()
    SFarmingSystem.OnClientCommand = theirs
    loadServer()
    check("S9 MOD 用同路徑同檔名覆寫：印 NOT installed、不包", SFarmingSystem.OnClientCommand == theirs
        and printCount("NOT installed: SFarmingSystem.OnClientCommand comes from") == 1, table.concat(prints, " | "))

    -- S10. OnGameBoot 復查不疊、不誤報；ResetLua 後重新安裝
    serverEnv()
    local vanilla10 = SFarmingSystem.OnClientCommand
    loadServer()
    local first = SFarmingSystem.OnClientCommand
    bootEvents()
    check("S10 OnGameBoot 復查：包裝不變、不印 NOT installed", SFarmingSystem.OnClientCommand == first
        and printCount("NOT installed") == 0, table.concat(prints, " | "))
    local chain = assert(load("return function(f) return function(...) return f(...) end end", "=OtherMod.lua"))()(first)
    SFarmingSystem.OnClientCommand = chain
    bootEvents()
    check("S10 開機前被別的 MOD 串接包住：不再包、不印 NOT installed", SFarmingSystem.OnClientCommand == chain
        and printCount("NOT installed") == 0, table.concat(prints, " | "))
    SFarmingSystem.OnClientCommand = vanilla10
    bootEvents()
    serverPlant(100, 200, 0, "destroyed")
    local d10 = srv.dispatched
    javaReceive("destroy", at)
    check("S10 開機前被寫回原版：重新包、不印 NOT installed", SFarmingSystem.OnClientCommand ~= vanilla10
        and srv.dispatched == d10 and printCount("NOT installed") == 0, table.concat(prints, " | "))
    serverEnv()
    loadServer()
    check("S10 ResetLua 後重新安裝在新表上", SFarmingSystem.OnClientCommand ~= first
        and debug.getinfo(SFarmingSystem.OnClientCommand, "S").source == "=MDFX_FarmingDestroyResyncServer.lua")
end

-- ── 測試套件（--mutants 以突變後的原始碼重跑同一套）──────────────────
local function runSuite(srcs, quiet)
    local checks, failures = 0, 0
    local function check(label, cond, detail)
        checks = checks + 1
        if cond then
            if not quiet then realPrint("  PASS  " .. label) end
        else
            failures = failures + 1
            if not quiet then realPrint("  FAIL  " .. label .. (detail and ("  — " .. tostring(detail)) or "")) end
        end
    end
    local function loadFix()
        assert(load(srcs.fix, "=MDFX_FarmingDestroyResync.lua"))()
    end
    -- 一個客戶端場次：原版 client 檔 → 本 MOD → 系統初始化
    local function session(withFix, opts)
        resetEnv(opts)
        for _, f in ipairs(VANILLA_FILES) do assert(load(f[2], "=" .. f[1]))() end
        if opts and opts.beforeFix then opts.beforeFix() end
        if withFix then loadFix() end
        if not (opts and opts.noInit) then
            for _, fn in ipairs(handlers.OnCGlobalObjectSystemInit or {}) do fn() end
        end
    end

    -- 1. 對照組：伺服器上已踩爛、客戶端全域物件 state 是 nil → 每幀送一次、播一次音效
    session(false)
    local sq = makeSquare(100, 200, 0, isoPlant("destroyed"))
    local go = addGlobal(100, 200, 0)
    frames(100, go, sq)
    check("1 對照組：100 幀送 100 次 destroy", #sent == 100 and sent[1].command == "destroy", #sent)
    check("1 對照組：音效 100 次", sounds == 100, sounds)
    check("1 對照組：全域物件 state 一直沒變", rawget(go:getModData(), "state") == nil)

    -- 2. 修正組：同一格第一幀就不送，之後 Java 不再進 Lua
    session(true)
    sq = makeSquare(100, 200, 0, isoPlant("destroyed"))
    go = addGlobal(100, 200, 0)
    frames(100, go, sq)
    check("2 修正組：100 幀 0 次 destroy", #sent == 0, #sent)
    check("2 修正組：全域物件 state 抄成 destroyed", rawget(go:getModData(), "state") == "destroyed")
    check("2 修正組：音效只剩第一幀", sounds == 1, sounds)
    check("2 修正組：計數 1", skipped() == 1, skipped())
    check("2 修正組：一行診斷，帶座標", printCount("MDFX_FarmingDestroyResync crop at 100,200,0 is already destroyed") == 1,
        table.concat(prints, " | "))
    check("2 修正組：零錯誤", #errors == 0, table.concat(errors, " | "))

    -- 3. 活作物：照送，伺服器狀態到了才停
    session(true)
    local live = isoPlant("seeded")
    sq = makeSquare(101, 200, 0, live)
    go = addGlobal(101, 200, 0)
    frames(3, go, sq)
    check("3 活作物：伺服器狀態到之前每幀照送", #sent == 3 and skipped() == 0, #sent)
    live.state = "destroyed"  -- 伺服器踩爛後的 ObjectModData
    frames(50, go, sq)
    check("3 活作物：伺服器狀態到了之後不再送", #sent == 3 and skipped() == 1, #sent)
    check("3 活作物：音效 4 次（3 次真的送＋1 次抄到狀態）", sounds == 4, sounds)

    -- 4. 不是 destroyed 的作物照原版送：地圖內建枯作物的 "destroy"、dead
    for _, st in ipairs({ "destroy", "dead", "rotten", "harvested" }) do
        session(true)
        sq = makeSquare(102, 200, 0, isoPlant(st))
        go = addGlobal(102, 200, 0)
        frames(5, go, sq)
        check("4 " .. st .. "：照原版每幀送", #sent == 5 and skipped() == 0, #sent)
    end

    -- 5. 沒有地圖物件（只剩全域物件）、沒有全域物件、square nil：照原版
    session(true)
    sq = makeSquare(103, 200, 0, nil)
    go = addGlobal(103, 200, 0)
    frames(5, go, sq)
    check("5 沒有地圖物件：照原版送", #sent == 5 and skipped() == 0, #sent)
    session(true)
    sq = makeSquare(104, 200, 0, isoPlant("destroyed"))
    CFarmingSystem.destroyPlant(sq)
    check("5 沒有全域物件：照原版送", #sent == 1 and skipped() == 0, #sent)
    local okNil = pcall(CFarmingSystem.destroyPlant, nil)
    check("5 square nil：照原版直接返回、不出錯", okNil and #sent == 1)

    -- 6. 自己的查詢出錯：印一次、照原版送
    session(true)
    sq = makeSquare(105, 200, 0, isoPlant("destroyed"))
    go = addGlobal(105, 200, 0)
    CFarmingSystem.instance.getLuaObjectOnSquare = function() error("lookup boom") end
    frames(3, go, sq)
    check("6 查詢出錯：照原版送", #sent == 3 and #errors == 0, #sent)
    check("6 查詢出錯：只印一行", printCount("could not read the crop on this square") == 1, table.concat(prints, " | "))

    -- 7. 系統還沒初始化（instance nil）：照原版送（原版這時也會在 sendCommand 出錯，錯誤原樣外洩）
    session(true, { noInit = true })
    sq = makeSquare(106, 200, 0, isoPlant("destroyed"))
    local ok7 = pcall(CFarmingSystem.destroyPlant, sq)
    check("7 instance nil：交給原函式（原版錯誤原樣外洩）", not ok7 and skipped() == 0 and printCount("could not read") == 0)

    -- 8. 只印一次、每次都計數
    session(true)
    local sqA, sqB = makeSquare(107, 200, 0, isoPlant("destroyed")), makeSquare(108, 200, 0, isoPlant("destroyed"))
    local goA, goB = addGlobal(107, 200, 0), addGlobal(108, 200, 0)
    frames(5, goA, sqA)
    frames(5, goB, sqB)
    check("8 兩格各擋一次、只印一行", skipped() == 2 and printCount("is already destroyed") == 1 and #sent == 0)

    -- 9. 形狀不符：不安裝、不出錯
    resetEnv()
    local ok9 = pcall(function() assert(load(srcs.fix, "=MDFX_FarmingDestroyResync.lua"))() end)
    check("9 沒有 CFarmingSystem：印 NOT installed、不拋錯", ok9 and printCount("NOT installed") == 1)
    session(false)
    CFarmingSystem.destroyPlant = nil
    local ok9b = pcall(loadFix)
    check("9 沒有 destroyPlant：印 NOT installed、不動類別", ok9b and printCount("NOT installed") == 1 and CFarmingSystem.destroyPlant == nil)
    session(false)
    getFilenameOfClosure = nil
    local plain = CFarmingSystem.destroyPlant
    local ok9c = pcall(loadFix)
    check("9 沒有 getFilenameOfClosure：印形狀不符的 NOT installed、不包", ok9c and printCount("NOT installed: vanilla CFarmingSystem shape changed") == 1
        and CFarmingSystem.destroyPlant == plain, table.concat(prints, " | "))

    -- 10. 別的 MOD 換掉 destroyPlant：不碰
    local theirs
    session(true, { beforeFix = function()
        theirs = assert(load("return function(square) end", "=OtherMod.lua"))()
        CFarmingSystem.destroyPlant = theirs
    end })
    check("10 別的 MOD 的版本：印 NOT installed、不包", CFarmingSystem.destroyPlant == theirs
        and printCount("NOT installed: CFarmingSystem.destroyPlant comes from") == 1, table.concat(prints, " | "))
    session(true, { beforeFix = function()
        theirs = assert(load("return function(square) end", "=Farming/CFarmingSystem.lua"))()
        CFarmingSystem.destroyPlant = theirs
    end })
    check("10 MOD 用同路徑同檔名覆寫：印 NOT installed、不包", CFarmingSystem.destroyPlant == theirs
        and printCount("NOT installed: CFarmingSystem.destroyPlant comes from") == 1, table.concat(prints, " | "))

    -- 11. 重複載入不疊；ResetLua（新類別表）後重新安裝
    session(true)
    local first = CFarmingSystem.destroyPlant
    loadFix()
    check("11 重複載入：包裝不變、不印 NOT installed", CFarmingSystem.destroyPlant == first and printCount("NOT installed") == 0,
        table.concat(prints, " | "))
    sq = makeSquare(109, 200, 0, isoPlant("destroyed"))
    go = addGlobal(109, 200, 0)
    frames(3, go, sq)
    check("11 重複載入：一格只計一次", skipped() == 1 and #sent == 0)
    session(true)
    check("11 ResetLua 後重新安裝在新表上", CFarmingSystem.destroyPlant ~= first
        and CFarmingSystem.MDFX_FarmingDestroyResync == CFarmingSystem.destroyPlant)

    serverChecks(srcs, check)
    return checks, failures
end

-- ── 主程式 ───────────────────────────────────────────────────────
local MUTANTS = {
    { name = "不載入修正", whole = "fix" },
    { name = "不檢查 destroyed", from = "        elseif destroyed then", to = "        elseif false then" },
    { name = "擋了仍呼叫原函式", from = "                .. \" is already destroyed on the server; did not send destroy again. Further skips not logged this session.\")\n            return",
        to = "                .. \" is already destroyed on the server; did not send destroy again. Further skips not logged this session.\")" },
    { name = "任何 state 都擋", from = "    return plant ~= nil and plant.state == \"destroyed\"", to = "    return plant ~= nil" },
    { name = "讀全域物件不先抄地圖物件", from = "    local plant = system:getLuaObjectOnSquare(square)",
        to = "    local go = system.system:getObjectAt(square:getX(), square:getY(), square:getZ())\n    local plant = go and go:getModData()" },
    { name = "查詢不包 pcall", from = "        local ok, destroyed = pcall(destroyedOnServer, square)",
        to = "        local ok, destroyed = true, destroyedOnServer(square)" },
    { name = "不判 instance nil", from = "    if not system then return false end\n", to = "" },
    { name = "拆掉形狀檢查", from = "if type(cls) ~= \"table\" or type(cls.destroyPlant) ~= \"function\" or type(cls.getLuaObjectOnSquare) ~= \"function\"\n    or type(getFilenameOfClosure) ~= \"function\" then",
        to = "if false then" },
    { name = "拆掉 getFilenameOfClosure 型別檢查", from = "\n    or type(getFilenameOfClosure) ~= \"function\" then", to = " then" },
    { name = "拆掉來源檢查", from = "if not path or string.sub(path, -#VANILLA_FILE) ~= VANILLA_FILE or string.find(path, \"/mods/\", 1, true) then",
        to = "if false then" },
    { name = "拆掉冪等 marker 檢查", from = "if cls[MARKER] == cls.destroyPlant then", to = "if false then" },
    { name = "拆掉 /mods/ 子條件", from = "string.sub(path, -#VANILLA_FILE) ~= VANILLA_FILE or string.find(path, \"/mods/\", 1, true) then",
        to = "string.sub(path, -#VANILLA_FILE) ~= VANILLA_FILE then" },
    { name = "不寫 marker", from = "cls[MARKER] = wrapper", to = "" },
    { name = "診斷不節流", from = "    if warned[key] then return end\n", to = "" },
    { name = "不計數", from = "            G.skipped = G.skipped + 1\n", to = "" },
    { name = "伺服器：不載入", whole = "server" },
    { target = "server", name = "伺服器：不檢查 destroyed", from = "    if plant == nil or plant.state ~= \"destroyed\" then return false end",
        to = "    if plant == nil then return false end" },
    { target = "server", name = "伺服器：擋了仍分派", from = "                end\n                return\n",
        to = "                end\n" },
    { target = "server", name = "伺服器：不看指令名", from = "        if command == \"destroy\" then", to = "        if true then" },
    { target = "server", name = "伺服器：判斷不包 pcall", from = "            local ok, skip = pcall(alreadyDestroyed, self, args)",
        to = "            local ok, skip = true, alreadyDestroyed(self, args)" },
    { target = "server", name = "伺服器：不驗座標型別",
        from = "    if type(x) ~= \"number\" or type(y) ~= \"number\" or type(z) ~= \"number\" then return false end\n", to = "" },
    { target = "server", name = "伺服器：不驗 args 型別", from = "    if type(args) ~= \"table\" then return false end\n", to = "" },
    { target = "server", name = "伺服器：不補送", from = "        iso:transmitModData()\n", to = "" },
    { target = "server", name = "伺服器：補送不節流", from = "    if not resentAt[plant] then", to = "    if true then" },
    { target = "server", name = "伺服器：補送鍵不分株", from = "    if not resentAt[plant] then\n        resentAt[plant] = true",
        to = "    if not resentAt[1] then\n        resentAt[1] = true" },
    { target = "server", name = "伺服器：補送鍵用客戶端座標", from = "    if not resentAt[plant] then\n        resentAt[plant] = true",
        to = "    local k = x .. \",\" .. y .. \",\" .. z\n    if not resentAt[k] then\n        resentAt[k] = true" },
    { target = "server", name = "伺服器：視窗到了不清表", from = "        resentAt = {}\n", to = "" },
    { target = "server", name = "伺服器：不判地圖物件 nil", from = "    if not iso then return true end\n", to = "" },
    { target = "server", name = "伺服器：不核對地圖物件 state",
        from = "    if iso and iso:getModData().state ~= \"destroyed\" then return false end\n", to = "" },
    { target = "server", name = "伺服器：拆掉形狀檢查",
        from = "    if type(cls) ~= \"table\" or type(cls.OnClientCommand) ~= \"function\" or type(cls.getLuaObjectAt) ~= \"function\"\n        or type(getFilenameOfClosure) ~= \"function\" or type(getTimestampMs) ~= \"function\" then",
        to = "    if false then" },
    { target = "server", name = "伺服器：拆掉來源檢查",
        from = "if not path or string.sub(path, -#VANILLA_FILE) ~= VANILLA_FILE or string.find(path, \"/mods/\", 1, true) then", to = "if false then" },
    { target = "server", name = "伺服器：拆 /mods/ 子條件",
        from = "string.sub(path, -#VANILLA_FILE) ~= VANILLA_FILE or string.find(path, \"/mods/\", 1, true) then",
        to = "string.sub(path, -#VANILLA_FILE) ~= VANILLA_FILE then" },
    { target = "server", name = "伺服器：拆掉已安裝檢查",
        from = "    if installedOn == cls and cls.OnClientCommand ~= installedOriginal then return end\n", to = "" },
    { target = "server", name = "伺服器：被寫回原版不重包", from = " and cls.OnClientCommand ~= installedOriginal then", to = " then" },
    { target = "server", name = "伺服器：時鐘回撥不清表", from = " or now < windowStart", to = "" },
    { target = "server", name = "伺服器：不計數", from = "                G.serverSkipped = G.serverSkipped + 1\n", to = "" },
}

local function replaceOnce(src, from, to)
    local s, e = src:find(from, 1, true)
    if not s then return nil, "pattern not found: " .. from end
    if src:find(from, e + 1, true) then return nil, "pattern not unique: " .. from end
    return src:sub(1, s - 1) .. to .. src:sub(e + 1)
end

local function mutate(m)
    local srcs = { fix = SOURCES.fix, server = SOURCES.server }
    if m.whole then
        srcs[m.whole] = ""
        return srcs
    end
    local target = m.target or "fix"
    local src, why = replaceOnce(SOURCES[target], m.from, m.to)
    if not src then return nil, why end
    srcs[target] = src
    return srcs
end

if arg and arg[1] == "--mutants" then
    local survived, broken = 0, 0
    for _, m in ipairs(MUTANTS) do
        local srcs, why = mutate(m)
        if not srcs then
            broken = broken + 1
            realPrint("  BROKEN    " .. m.name .. " — " .. why)
        else
            local ok, checks, failures = pcall(runSuite, srcs, true)
            print = realPrint
            if ok and failures == 0 then
                survived = survived + 1
                realPrint(string.format("  SURVIVED  %s（%d 項全綠）", m.name, checks))
            else
                realPrint(string.format("  KILLED    %s（%s）", m.name,
                    ok and (failures .. "/" .. checks .. " 項轉紅") or ("拋錯 " .. tostring(checks))))
            end
        end
    end
    realPrint("")
    realPrint(string.format("%d mutants, %d survived, %d broken", #MUTANTS, survived, broken))
    os.exit((survived == 0 and broken == 0) and 0 or 1)
end

local checks, failures = runSuite(SOURCES, false)
print = realPrint
realPrint("")
realPrint(string.format("%d checks, %d failed", checks, failures))
os.exit(failures == 0 and 0 or 1)
