-- MDFX_GosDuplicateNewGuard 離線自我檢查
-- 用法（repo 根目錄）： lua scripts/test_gos_duplicate_new_guard.lua [--mutants]
--
-- 照載本機遊戲的原版 shared/ISBaseObject.lua、client/Map/CGlobalObjectSystem.lua、CGlobalObject.lua、
-- client/Farming/CPlantGlobalObject.lua、CFarmingSystem.lua（PZ_HOME 可改安裝目錄）；Java 端用 Lua 照形狀模擬：
--   * CGlobalObjects.registerSystem 照連線清單建物件（CGlobalObjects.java:28-68），OnCGlobalObjectSystemInit 時觸發
--   * newObject 同座標已有物件時，照 Kahlua MethodCaller（MethodCaller.java:34-43）記下例外、回傳 nil，不中斷 Lua
--   * receiveNewLuaObjectAt 先 pcall newLuaObjectAt、再把封包內容 rawset 進 getObjectAt 拿到的物件
--     （CGlobalObjectSystem.java:34-50）；rawget 沿 metatable 找方法（KahluaTableImpl.java:98）
-- 驗證：
--   * 對照組（不載補丁）重現正式服症狀：每個重複新增兩條錯誤，資料照樣寫進原本的物件
--   * 修正組零錯誤、物件與資料和對照組逐一相同；新座標照原版建立
--   * 登入競態整段模擬（清單已含＋延後的新增／更新／移除）結果與伺服器一致
--   * 不從地圖物件抄 modData、回傳既有物件、只印一次、計數、覆寫了 newLuaObjectAt 的 MOD 系統不受影響
--   * 形狀不符印 NOT installed；重複載入不疊；ResetLua 後重新安裝；自己的查詢出錯照原版走
-- --mutants：逐一抽掉每道防線，確認至少一項檢查轉紅。

local PZ_HOME = os.getenv("PZ_HOME") or "D:/SteamLibrary/steamapps/common/ProjectZomboid"
local VANILLA = PZ_HOME .. "/media/lua/"
local FIX = "MOD/MinidoracatFixesFor42/Contents/mods/MinidoracatFixesFor42/42/media/lua/client/Fixes/MDFX_GosDuplicateNewGuard.lua"

local realPrint = print

local function readFile(path)
    local f = assert(io.open(path, "rb"))
    local s = f:read("*a")
    f:close()
    return s
end

local SOURCES = { fix = readFile(FIX) }
local VANILLA_FILES = {
    { "ISBaseObject.lua", readFile(VANILLA .. "shared/ISBaseObject.lua") },
    { "CGlobalObjectSystem.lua", readFile(VANILLA .. "client/Map/CGlobalObjectSystem.lua") },
    { "CGlobalObject.lua", readFile(VANILLA .. "client/Map/CGlobalObject.lua") },
    { "CPlantGlobalObject.lua", readFile(VANILLA .. "client/Farming/CPlantGlobalObject.lua") },
    { "CFarmingSystem.lua", readFile(VANILLA .. "client/Farming/CFarmingSystem.lua") },
}

-- ── 假 Java 端 ─────────────────────────────────────────────────────
local prints, errors, handlers, squares, systems, initialState

local function key(x, y, z)
    return string.format("%d,%d,%d", math.floor(x), math.floor(y), math.floor(z))
end

local function newGlobalObject(system, x, y, z)
    local go = { system = system, x = x, y = y, z = z, modData = {} }
    function go:getModData() return self.modData end
    function go:getX() return self.x end
    function go:getY() return self.y end
    function go:getZ() return self.z end
    return go
end

local function newJavaSystem(name)
    local sys = { name = name, modData = {}, objects = {}, lookup = {} }
    function sys:getModData() return self.modData end
    function sys:getObjectAt(x, y, z) return self.lookup[key(x, y, z)] end
    function sys:newObject(x, y, z)
        if self:getObjectAt(x, y, z) ~= nil then
            -- MethodCaller.call 吞掉 Java 例外、記一行、不推回傳值 → Lua 拿到 nil
            errors[#errors + 1] = "java.lang.IllegalStateException: already an object at " .. key(x, y, z)
            return nil
        end
        local go = newGlobalObject(self, x, y, z)
        self.objects[#self.objects + 1] = go
        self.lookup[key(x, y, z)] = go
        return go
    end
    function sys:removeObject(go)
        for i = #self.objects, 1, -1 do
            if self.objects[i] == go then table.remove(self.objects, i) end
        end
        self.lookup[key(go.x, go.y, go.z)] = nil
    end
    function sys:getObjectCount() return #self.objects end
    function sys:getObjectByIndex(i) return self.objects[i + 1] end
    function sys:sendCommand() end
    return sys
end

local function getSystemByName(name)
    for i = 1, #systems do
        if systems[i].name == name then return systems[i] end
    end
    return nil
end

local function resetEnv(state, opts)
    opts = opts or {}
    prints, errors, handlers, squares, systems = {}, {}, {}, {}, {}
    initialState = state or {}
    print = function(...)
        local parts = {}
        for i = 1, select("#", ...) do parts[i] = tostring(select(i, ...)) end
        prints[#prints + 1] = table.concat(parts, " ")
    end
    require = function() end
    getDebug = function() return false end
    isClient = function() return opts.mp ~= false end
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
            local sys = getSystemByName(name)
            if not sys then
                sys = newJavaSystem(name)
                systems[#systems + 1] = sys
                for _, o in ipairs((initialState[name] or {})) do
                    local go = sys:newObject(o.x, o.y, o.z)
                    for k, v in pairs(o.data) do rawset(go:getModData(), k, v) end
                end
            end
            return sys
        end,
        getSystemCount = function() return #systems end,
        getSystemByIndex = function(i) return systems[i + 1] end,
        getSystemByName = getSystemByName,
    }
    ISBaseObject, CGlobalObjectSystem, CGlobalObject, CPlantGlobalObject, CFarmingSystem = nil, nil, nil, nil, nil
    MDFX_GosDuplicateNewGuard = nil
end

-- 地圖上一個農作物地圖物件（modData 有 state／nbOfGrow／health 才算數，CFarmingSystem.lua:10-15）
local function putIsoPlant(x, y, z, md)
    local iso = { md = md }
    function iso:hasModData() return true end
    function iso:getModData() return self.md end
    local list = { iso }
    squares[key(x, y, z)] = { getObjects = function()
        return { size = function() return #list end, get = function(_, i) return list[i + 1] end }
    end }
end

local function loadVanilla()
    for _, f in ipairs(VANILLA_FILES) do
        assert(load(f[2], "=" .. f[1]))()
    end
end

local function initSystems()
    for _, fn in ipairs(handlers.OnCGlobalObjectSystemInit or {}) do fn() end
end

-- KahluaTableImpl.rawget 找不到時沿 metatable 找（KahluaTableImpl.java:98），Java 就是這樣拿到 Lua 方法
local function javaRawget(t, k)
    local v = rawget(t, k)
    if v == nil then
        local mt = getmetatable(t)
        if type(mt) == "table" then return javaRawget(mt, k) end
    end
    return v
end

local function luaCall(fn, ...)
    local ok, err = pcall(fn, ...)
    if not ok then errors[#errors + 1] = "Lua: " .. tostring(err) end
end

-- CGlobalObjectSystem.java:34-50／52-60／62-78
local function receiveNew(name, x, y, z, args)
    local sys = getSystemByName(name)
    if not sys then return end
    luaCall(javaRawget(sys.modData, "newLuaObjectAt"), sys.modData, x, y, z)
    local go = sys:getObjectAt(x, y, z)
    if go then
        for k, v in pairs(args or {}) do rawset(go:getModData(), k, v) end
    end
end

local function receiveRemove(name, x, y, z)
    local sys = getSystemByName(name)
    if not sys then return end
    luaCall(javaRawget(sys.modData, "removeLuaObjectAt"), sys.modData, x, y, z)
end

local function receiveUpdate(name, x, y, z, args)
    local sys = getSystemByName(name)
    local go = sys and sys:getObjectAt(x, y, z)
    if not go then return end
    for k, v in pairs(args or {}) do rawset(go:getModData(), k, v) end
    luaCall(javaRawget(sys.modData, "OnLuaObjectUpdated"), sys.modData, go:getModData())
end

local function printCount(needle)
    local n = 0
    for i = 1, #prints do
        if prints[i]:find(needle, 1, true) then n = n + 1 end
    end
    return n
end

local function kept()
    return MDFX_GosDuplicateNewGuard and MDFX_GosDuplicateNewGuard.kept
end

-- 鏡像的可比較字串：每個物件的座標、類別、Lua 欄位接線與所有純量欄位
local function mirror(name)
    local sys = getSystemByName(name)
    if not sys then return "<no system>" end
    local rows = {}
    for _, go in ipairs(sys.objects) do
        local md = go:getModData()
        local mt = getmetatable(md)
        local keys = {}
        for k, v in pairs(md) do
            local t = type(v)
            if t == "string" or t == "number" or t == "boolean" then keys[#keys + 1] = tostring(k) .. "=" .. tostring(v) end
        end
        table.sort(keys)
        rows[#rows + 1] = key(go.x, go.y, go.z) .. " " .. tostring(mt and mt.Type)
            .. " wired=" .. tostring(md.globalObject == go and md.luaSystem == sys.modData)
            .. " {" .. table.concat(keys, ",") .. "}"
    end
    table.sort(rows)
    return table.concat(rows, "\n")
end

local A = { x = 100, y = 200, z = 0, data = { state = "destroyed", typeOfSeed = "Pumpkin", nbOfGrow = 4, health = 0, waterLvl = 0 } }
local B = { x = 101, y = 200, z = 0, data = { state = "dead", typeOfSeed = "Spinach", nbOfGrow = 3, health = 0, waterLvl = 0 } }

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
        assert(load(srcs.fix, "=MDFX_GosDuplicateNewGuard.lua"))()
    end
    -- 一個客戶端場次：原版 client 檔 → 本 MOD → GameLoadingState 的 initSystems（照清單建物件）
    local function session(withFix, state, opts)
        resetEnv(state, opts)
        loadVanilla()
        if withFix then loadFix() end
        if opts and opts.beforeInit then opts.beforeInit() end
        initSystems()
    end
    local function farm(x, y, z)
        local go = getSystemByName("farming"):getObjectAt(x, y, z)
        return go and go:getModData()
    end

    -- 1. 對照組：重現正式服症狀
    session(false, { farming = { A } })
    receiveNew("farming", A.x, A.y, A.z, { state = "destroyed", typeOfSeed = "Pumpkin", nbOfGrow = 4, health = 0, waterLvl = 7 })
    local vanillaDup = mirror("farming")
    check("1 對照組：重複新增兩條錯誤（Java 例外＋Lua 錯誤）", #errors == 2, table.concat(errors, " | "))
    check("1 對照組：例外文字與正式服相同", errors[1] and errors[1]:find("already an object at 100,200,0", 1, true) ~= nil, errors[1])
    check("1 對照組：Java 照樣把封包內容寫進原本的物件", farm(A.x, A.y, A.z).waterLvl == 7)

    -- 2. 修正組：同一封包零錯誤、物件不換、資料相同
    session(true, { farming = { A } })
    local before = farm(A.x, A.y, A.z)
    receiveNew("farming", A.x, A.y, A.z, { state = "destroyed", typeOfSeed = "Pumpkin", nbOfGrow = 4, health = 0, waterLvl = 7 })
    local after = farm(A.x, A.y, A.z)
    check("2 修正組：零錯誤", #errors == 0, table.concat(errors, " | "))
    check("2 修正組：還是原本那個物件、沒有多建", after == before and getSystemByName("farming"):getObjectCount() == 1)
    check("2 修正組：Lua 類別與接線不變", getmetatable(after) == CPlantGlobalObject and after.luaSystem == CFarmingSystem.instance
        and after.globalObject == getSystemByName("farming"):getObjectAt(A.x, A.y, A.z))
    check("2 修正組：封包內容照樣寫入", after.waterLvl == 7)
    check("2 修正組：鏡像與對照組逐一相同", mirror("farming") == vanillaDup, mirror("farming") .. "\n--- vs ---\n" .. vanillaDup)
    check("2 修正組：一行診斷，帶系統名與座標", printCount("MDFX_GosDuplicateNewGuard the server announced a new farming object at 100,200,0") == 1,
        table.concat(prints, " | "))
    check("2 修正組：診斷不含原版錯誤字串", printCount("already an object at") == 0)
    check("2 修正組：計數 1", kept() == 1)

    -- 3. 新座標：與原版相同
    session(false, { farming = { A } })
    receiveNew("farming", B.x, B.y, B.z, B.data)
    local vanillaNew = mirror("farming")
    session(true, { farming = { A } })
    receiveNew("farming", B.x, B.y, B.z, B.data)
    check("3 新座標照原版建立、零錯誤", #errors == 0 and mirror("farming") == vanillaNew, mirror("farming") .. "\n--- vs ---\n" .. vanillaNew)
    check("3 新座標不計數、不印診斷", kept() == 0 and printCount("MDFX_GosDuplicateNewGuard") == 0)

    -- 4. 直接呼叫：回傳既有物件
    session(true, { farming = { A } })
    local existing = farm(A.x, A.y, A.z)
    local okCall, ret = pcall(CFarmingSystem.instance.newLuaObjectAt, CFarmingSystem.instance, A.x, A.y, A.z)
    check("4 回傳既有的 luaObject", okCall and ret == existing and ret ~= nil, ret)

    -- 5. 只印一次、每次都計數
    session(true, { farming = { A, B } })
    receiveNew("farming", A.x, A.y, A.z, { waterLvl = 1 })
    receiveNew("farming", B.x, B.y, B.z, { waterLvl = 2 })
    check("5 兩次重複只印一行", printCount("MDFX_GosDuplicateNewGuard the server announced") == 1, table.concat(prints, " | "))
    check("5 計數 2", kept() == 2)

    -- 6. 登入競態整段：清單已含 A、B；延後的封包依序是 A 重複新增、C 新增、A 更新、B 移除再新增
    local C = { x = 102, y = 200, z = 0, data = { state = "seeded", typeOfSeed = "Carrots", nbOfGrow = 1, health = 80, waterLvl = 50 } }
    local function joinRace(withFix)
        session(withFix, { farming = { A, B } })
        putIsoPlant(B.x, B.y, B.z, { state = "dead", nbOfGrow = 3, health = 0 })
        receiveNew("farming", A.x, A.y, A.z, { state = "destroyed", typeOfSeed = "Pumpkin", nbOfGrow = 4, health = 0, waterLvl = 9 })
        receiveNew("farming", C.x, C.y, C.z, C.data)
        receiveUpdate("farming", A.x, A.y, A.z, { waterLvl = 12 })
        receiveRemove("farming", B.x, B.y, B.z)
        receiveNew("farming", B.x, B.y, B.z, { state = "dead", typeOfSeed = "Spinach", nbOfGrow = 3, health = 0, waterLvl = 4 })
        return #errors, mirror("farming")
    end
    local vErr, vMirror = joinRace(false)
    local fErr, fMirror = joinRace(true)
    check("6 對照組只有 A 的重複新增出錯（2 條）", vErr == 2, vErr)
    check("6 修正組零錯誤", fErr == 0, fErr)
    check("6 修正組最終鏡像與對照組相同（A 更新、B 重建、C 新增）", fMirror == vMirror, fMirror .. "\n--- vs ---\n" .. vMirror)
    check("6 最終鏡像三株且 A 是最後一次更新的值", getSystemByName("farming"):getObjectCount() == 3 and farm(A.x, A.y, A.z).waterLvl == 12)

    -- 7. 不從地圖物件抄 modData（原版這條路徑沒有 updateFromIsoObject）
    session(false, { farming = { A } })
    putIsoPlant(A.x, A.y, A.z, { state = "destroyed", nbOfGrow = 4, health = 0, isoOnly = true, waterLvl = 99 })
    receiveNew("farming", A.x, A.y, A.z, { waterLvl = 7 })
    local vanillaIso = mirror("farming")
    session(true, { farming = { A } })
    putIsoPlant(A.x, A.y, A.z, { state = "destroyed", nbOfGrow = 4, health = 0, isoOnly = true, waterLvl = 99 })
    receiveNew("farming", A.x, A.y, A.z, { waterLvl = 7 })
    check("7 地圖物件的 modData 沒被抄進來", farm(A.x, A.y, A.z).isoOnly == nil and farm(A.x, A.y, A.z).waterLvl == 7)
    check("7 與對照組逐一相同", mirror("farming") == vanillaIso, mirror("farming") .. "\n--- vs ---\n" .. vanillaIso)

    -- 8. 單人（isClient 為假）照樣生效
    session(true, { farming = { A } }, { mp = false })
    receiveNew("farming", A.x, A.y, A.z, { waterLvl = 3 })
    check("8 單人也不再出錯", #errors == 0 and farm(A.x, A.y, A.z).waterLvl == 3)

    -- 9. 自己覆寫 newLuaObjectAt 的 MOD 系統：照它自己的版本
    local calls = 0
    session(true, { psr = { { x = 5, y = 6, z = 0, data = { charge = 1 } } } }, { beforeInit = function()
        local PB = CGlobalObjectSystem:derive("PBSystem")
        function PB:new() return CGlobalObjectSystem.new(self, "psr") end
        function PB:newLuaObject(go)
            local o = go:getModData()
            o.x, o.y, o.z = go:getX(), go:getY(), go:getZ()
            return o
        end
        function PB:newLuaObjectAt(x, y, z)
            calls = calls + 1
            return self.system:getObjectAt(x, y, z):getModData()
        end
        CGlobalObjectSystem.RegisterSystemClass(PB)
    end })
    receiveNew("psr", 5, 6, 0, { charge = 2 })
    check("9 覆寫版本被呼叫、本補丁不介入", calls == 1 and kept() == 0 and #errors == 0)

    -- 10. 自己的查詢出錯：印一次、照原函式走（新座標照常建立）
    session(true, { farming = { A } })
    local sys = getSystemByName("farming")
    local realGet = sys.getObjectAt
    local failNext = true
    sys.getObjectAt = function(self, x, y, z)
        if failNext then failNext = false; error("lookup boom") end
        return realGet(self, x, y, z)
    end
    receiveNew("farming", B.x, B.y, B.z, B.data)
    check("10 查詢出錯時照原函式建立新物件", #errors == 0 and farm(B.x, B.y, B.z) ~= nil and getmetatable(farm(B.x, B.y, B.z)) == CPlantGlobalObject,
        table.concat(errors, " | "))
    check("10 查詢出錯印一行", printCount("could not look up an existing object") == 1)

    -- 11. 形狀不符：不安裝、不出錯
    resetEnv()
    local ok1 = pcall(function() assert(load(srcs.fix, "=MDFX_GosDuplicateNewGuard.lua"))() end)
    check("11 沒有 CGlobalObjectSystem：印 NOT installed、不拋錯", ok1 and printCount("NOT installed") == 1)
    resetEnv()
    CGlobalObjectSystem = {}
    local ok2 = pcall(function() assert(load(srcs.fix, "=MDFX_GosDuplicateNewGuard.lua"))() end)
    check("11 沒有 newLuaObjectAt：印 NOT installed、不動類別", ok2 and printCount("NOT installed") == 1 and CGlobalObjectSystem.newLuaObjectAt == nil)

    -- 12. 重複載入不疊；ResetLua（新類別表）後重新安裝
    session(true, { farming = { A } })
    local first = CGlobalObjectSystem.newLuaObjectAt
    loadFix()
    check("12 重複載入：包裝不變", CGlobalObjectSystem.newLuaObjectAt == first)
    receiveNew("farming", A.x, A.y, A.z, { waterLvl = 5 })
    check("12 重複載入：每個重複只計一次", kept() == 1)
    session(true, { farming = { A } })
    check("12 ResetLua 後重新安裝在新表上", CGlobalObjectSystem.newLuaObjectAt ~= first
        and CGlobalObjectSystem.MDFX_GosDuplicateNewGuard == CGlobalObjectSystem.newLuaObjectAt)
    receiveNew("farming", A.x, A.y, A.z, { waterLvl = 6 })
    check("12 ResetLua 後照常生效", #errors == 0 and farm(A.x, A.y, A.z).waterLvl == 6)

    return checks, failures
end

-- ── 主程式 ───────────────────────────────────────────────────────
local MUTANTS = {
    { name = "不載入修正", whole = "fix" },
    { name = "不檢查既有物件", from = "    elseif existing then", to = "    elseif false then" },
    { name = "既有物件仍呼叫原函式", from = "        return existing:getModData()", to = "        return original(self, x, y, z)" },
    { name = "既有物件回傳 nil", from = "        return existing:getModData()", to = "        return nil" },
    { name = "查詢不包 pcall", from = "    local ok, existing = pcall(existingAt, self, x, y, z)",
        to = "    local ok, existing = true, existingAt(self, x, y, z)" },
    { name = "改用 getLuaObjectAt 查（會先抄地圖物件的 modData）", from = "    return self.system:getObjectAt(x, y, z)",
        to = "    local o = self:getLuaObjectAt(x, y, z)\n    return o and o.globalObject" },
    { name = "拆掉形狀檢查", from = "if type(cls) ~= \"table\" or type(cls.newLuaObjectAt) ~= \"function\" then", to = "if false then" },
    { name = "拆掉冪等 marker 檢查", from = "if cls[MARKER] == cls.newLuaObjectAt then", to = "if false then" },
    { name = "不寫 marker", from = "cls[MARKER] = wrapper", to = "" },
    { name = "診斷不節流", from = "    if warned[key] then return end\n", to = "" },
    { name = "不計數", from = "        G.kept = G.kept + 1\n", to = "" },
}

local function replaceOnce(src, from, to)
    local s, e = src:find(from, 1, true)
    if not s then return nil, "pattern not found: " .. from end
    if src:find(from, e + 1, true) then return nil, "pattern not unique: " .. from end
    return src:sub(1, s - 1) .. to .. src:sub(e + 1)
end

local function mutate(m)
    if m.whole then return { fix = "" } end
    local src, why = replaceOnce(SOURCES.fix, m.from, m.to)
    if not src then return nil, why end
    return { fix = src }
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
