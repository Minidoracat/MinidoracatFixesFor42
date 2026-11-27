-- MDFX_FarmingGosPrune 離線自我檢查
-- 用法（repo 根目錄）： lua scripts/test_farming_gos_prune.lua
--                       lua scripts/test_farming_gos_prune.lua --mutants   （每個突變都要被抓到）
--                       lua scripts/test_farming_gos_prune.lua --fix <檔>  （改測別份原始碼；--mutants 內部用）
--
-- 以最小假 vanilla 農作物系統驗證：
--   * 假 Java GOS（newObject 同格重複就拋 "already an object at"、removeObject、新增／移除封包）
--   * 假 SFarmingSystem（isValidModData／isValidIsoObject 照 SFarmingSystem.lua:48-54；
--     getLuaObjectOnSquare／getIsoObjectOnSquare／newLuaObject／removeLuaObject／
--     getLuaObjectCount／getLuaObjectByIndex 照 server/Map/SGlobalObjectSystem.lua:40-131；
--     luaObject 就是 globalObject 的 modData 表，照 SGlobalObject.lua:63-73）
--   * SPlantGlobalObject.fromModData 照抄 SPlantGlobalObject.lua:779-812 的語意
--   * 假 MapObjects.OnLoadWithSprite（靜態類別，用 . 呼叫；同 priority 取代）、getCell 依載入集合回格子、
--     假 IsoObject（畫面 sprite 與 spriteName 欄位分開，IsoObject.java:1979-1982）
-- 涵蓋：
--   1. 註冊：每種作物的 trampled／dead 清單都以 priority 4242 註冊；一組拋錯不影響其他組、診斷一次、
--      用那組 sprite 的作物永不移出；OnGameBoot 重註冊冪等；形狀不符 NOT installed；isClient() 不裝
--   2. 移出生命週期：載入時驗證 → 卸載後第一次只記時間 → 未滿 30 秒不動 → 滿 30 秒才 removeLuaObject
--   3. 不移出：非移出狀態、伴生作物、-nosave、modData 與 luaObject 不同、spriteName 缺／不符、
--      sprite 沒註冊、卸載期間 luaObject 變了、從沒載入過、中途重新載入要重新等
--   4. 每輪上限 100
--   5. 重建 hook：原樣重建＋一包新增；各種 no-op；建到一半失敗會拿掉半成品、不外洩錯誤
--   6. 移出 → 重建來回，26 個 KEYS 完全相同
--   7. 掃描拋錯不外洩；診斷每 session 只印一次
--   8. 分攤到每幀：開輪那幀不走、每 tick 300 株、閒置不碰引擎；重走只評估一次；放棄一輪清空條目；
--      輪中再觸發只補一輪；數量縮到游標以下；尾端新增；-nosave 與出錯中途放棄；
--      原版 fromModData 只比 KEYS、別的 MOD 換掉才比多寫的鍵；延後比對的語意

local S = dofile("scripts/_stub.lua")
local T = S.checker()
local FIX = (arg and arg[1] == "--fix" and arg[2]) or (S.SERVER_FIXES .. "MDFX_FarmingGosPrune.lua")

-- ── --mutants：每個突變寫成暫存檔，用子行程跑整支測試，要轉紅（非 0 結束）──
local MUTANTS = {
    { "拿掉 isClient 閘門", "if isClient() then return end\n", "" },
    { "rebuildable 不看 spriteName", "if name == nil or modData.spriteName ~= name then return nil end", "if name == nil then return nil end" },
    { "rebuildable 不看狀態", "    if not EVICTABLE[modData.state] then return nil end\n", "" },
    { "移出不限註冊過的 sprite", "if not modData or not restorable[name] then return nil end", "if not modData then return nil end" },
    { "hook 不看這格已有 luaObject", "        if existing then\n", "        if false then\n" },
    { "載入不清驗證", "            verified[existing] = nil\n", "" },
    { "載入不清這輪的 keep", "            if pass then pass.keep[existing] = nil end\n", "" },
    { "記時間時不比對", "            if not same(luaObject, entry.snap, entry.full) then return end\n", "" },
    { "輪中觸發加額度", "Events.EveryTenMinutes.Add(function() due = true end)",
        "Events.EveryTenMinutes.Add(function() due = true; if pass then pass.evicted = pass.evicted - CAP end end)" },
    { "hook 失敗不拿掉半成品", "            pcall(function() system.system:removeObject(globalObject) end)\n", "" },
    { "priority 改回 5", "local PRIORITY = 4242", "local PRIORITY = 5" },
    { "註冊不逐種 pcall", "local ok, err = pcall(MapObjects.OnLoadWithSprite, names, onLoad, PRIORITY)",
        "local ok, err = true, MapObjects.OnLoadWithSprite(names, onLoad, PRIORITY)" },
    { "拿掉 seen 檢查（重走再評估）", "    if pass.seen[luaObject] then return end\n", "" },
    { "seen 寫在過濾之後", "    pass.seen[luaObject] = true\n    if not EVICTABLE[luaObject.state] or companion(luaObject) then return end\n",
        "    if not EVICTABLE[luaObject.state] or companion(luaObject) then return end\n    pass.seen[luaObject] = true\n" },
    { "移出時改用這輪的 full", "        if same(luaObject, entry.snap, entry.full) then",
        "        if same(luaObject, entry.snap, pass.full) then" },
    { "驗證不回傳 full", "if ok and same(luaObject, t, full) then return t, full end", "if ok and same(luaObject, t, full) then return t end" },
    { "舊式 modData 不跑全鍵", "    full = full or not modData.objectName\n", "" },
    { "快照不看輪中途換掉 fromModData", "    full = full or not judged\n", "" },
    { "舊式 modData 只認 nil", "full = full or not modData.objectName", "full = full or modData.objectName == nil" },
    { "放棄時不清 verified", "pass, due, verified = nil, false, {}", "pass, due = nil, false" },
    { "開輪那幀也走", "        return -- EveryTenMinutes", "        -- EveryTenMinutes" },
    { "每 tick 沒有上限", "local BATCH = 300", "local BATCH = math.huge" },
    { "每 tick 從尾端重來", "local i = math.min(pass.cursor, system:getLuaObjectCount())", "local i = system:getLuaObjectCount()" },
    { "游標不夾到數量", "local i = math.min(pass.cursor, system:getLuaObjectCount())", "local i = pass.cursor" },
    { "不記游標", "    pass.cursor = i\n", "" },
    { "拿掉閒置閘門", "    if not pass and not due then return end\n", "" },
    { "上限變成每 tick", "    local cell, now = getCell(), getTimestampMs()\n", "    pass.evicted = 0\n    local cell, now = getCell(), getTimestampMs()\n" },
    { "拿掉上限", " and pass.evicted < CAP", "" },
    { "拿掉 since 檢查", "entry.since and now - entry.since >= SETTLE_MS and ", "" },
    { "拿掉 30 秒下限", "now - entry.since >= SETTLE_MS and ", "" },
    { "移出前不比對", "        if same(luaObject, entry.snap, entry.full) then\n", "        if true then\n" },
    { "驗證時不比對", "if ok and same(luaObject, t, full) then return t, full end", "if ok then return t, full end" },
    { "拿掉狀態檢查", "    if not EVICTABLE[luaObject.state] or companion(luaObject) then return end\n",
        "    if companion(luaObject) then return end\n" },
    { "拿掉伴生檢查", " or companion(luaObject) then return end", " then return end" },
    { "拿掉 isNoSave", "if not system or getCore():isNoSave() then return abandon() end", "if not system then return abandon() end" },
    { "拿掉 instance 檢查", "if not system or getCore():isNoSave() then return abandon() end", "if getCore():isNoSave() then return abandon() end" },
    { "放棄時不清 due", "pass, due, verified = nil, false, {}", "pass, verified = nil, {}" },
    { "只在開輪時看 isNoSave", "if not system or getCore():isNoSave() then return abandon() end",
        "if not system or (not pass and getCore():isNoSave()) then return abandon() end" },
    { "載入分支沿用舊 since", "if snap then pass.keep[luaObject] = { snap = snap, full = full } end",
        "if snap then pass.keep[luaObject] = { snap = snap, full = full, since = verified[luaObject] and verified[luaObject].since } end" },
    { "EveryTenMinutes 時重開一輪", "Events.EveryTenMinutes.Add(function() due = true end)",
        "Events.EveryTenMinutes.Add(function() due = true; pass = nil end)" },
    { "收尾時丟掉輪中的觸發", "    verified = pass.keep\n", "    verified = pass.keep\n    due = false\n" },
    { "出錯不放棄", "        abandon()\n        warnOnce(\"sweepError\"", "        warnOnce(\"sweepError\"" },
    { "full 固定 true", "full = foreign(), fn", "full = true, fn" },
    { "full 固定 false", "full = foreign(), fn", "full = false, fn" },
    { "不記開輪時的 fromModData", "fn = SPlantGlobalObject.fromModData }", "fn = nil }" },
    { "不看 /mods/", " or string.find(path, \"/mods/\", 1, true) ~= nil", "" },
    { "不比檔名尾", "string.sub(path, -#VANILLA_FILE) ~= VANILLA_FILE or ", "" },
    { "不轉斜線", "string.lower(string.gsub(file, \"\\\\\", \"/\"))", "string.lower(file)" },
    { "不轉小寫", "string.lower(string.gsub(file, \"\\\\\", \"/\"))", "(string.gsub(file, \"\\\\\", \"/\"))" },
    { "查來源不包 pcall", "local ok, file = pcall(getFilenameOfClosure, SPlantGlobalObject.fromModData)",
        "local ok, file = true, getFilenameOfClosure(SPlantGlobalObject.fromModData)" },
    { "查不到來源當原版", "if not ok or type(file) ~= \"string\" then return true end", "if not ok or type(file) ~= \"string\" then return false end" },
}

if arg and arg[1] == "--mutants" then
    local fh = assert(io.open(FIX, "rb"))
    local src = fh:read("a")
    fh:close()
    -- 直譯器路徑可能有空白；暫存檔放 scripts/（乾淨 checkout 沒有 temp/）
    local lua, tmp = arg[-1] or "lua", "scripts/_mutant_farming_gos_prune.lua"
    local function run(source)
        local out = assert(io.open(tmp, "wb"))
        out:write(source)
        out:close()
        -- 編譯不過的突變不算抓到：子行程的 pcall 會把它變成 FAIL
        if not loadfile(tmp) then
            os.remove(tmp)
            return nil, "COMPILE"
        end
        local p = io.popen(string.format('"%s" scripts/test_farming_gos_prune.lua --fix %s 2>&1', lua, tmp))
        local log = p:read("a")
        local ok = p:close()
        os.remove(tmp)
        return ok, log
    end
    -- 先用同一條指令跑原始碼：沒跑起來或沒全綠，就不能把突變的失敗算成抓到
    local baseOk, baseLog = run(src)
    if not baseOk or not baseLog:find(" checks, 0 failed", 1, true) then
        print(baseLog)
        print("baseline did not pass; mutants not run")
        os.exit(1)
    end
    local survived, broken = 0, 0
    for _, m in ipairs(MUTANTS) do
        local s, e = src:find(m[2], 1, true)
        if not s or src:find(m[2], e + 1, true) then
            broken = broken + 1
            print("  BROKEN    " .. m[1] .. "（樣式" .. (s and "不唯一" or "找不到") .. "）")
        else
            local ok, log = run(src:sub(1, s - 1) .. m[3] .. src:sub(e + 1))
            local fails = select(2, log:gsub("  FAIL  ", ""))
            if log == "COMPILE" then
                broken = broken + 1
                print("  BROKEN    " .. m[1] .. "（編譯不過）")
            elseif ok then
                survived = survived + 1
                print("  SURVIVED  " .. m[1])
            elseif fails == 0 and not log:find("  PASS  ", 1, true) then
                broken = broken + 1
                print("  BROKEN    " .. m[1] .. "（測試沒跑起來）")
            else
                print(string.format("  KILLED    %s（%s）", m[1], fails > 0 and (fails .. " 項轉紅") or "拋錯中止"))
            end
        end
    end
    print("")
    print(string.format("%d mutants, %d survived, %d broken", #MUTANTS, survived, broken))
    os.exit((survived == 0 and broken == 0) and 0 or 1)
end

local PRIORITY = 4242
local SETTLE = 30000

-- SFarmingSystem:initSystem 的 setObjectModDataKeys（SFarmingSystem.lua:30-34）
local KEYS = {
    "state", "nbOfGrow", "typeOfSeed", "fertilizer", "mildewLvl",
    "aphidLvl", "fliesLvl", "slugsLvl", "hasWeeds", "waterLvl", "waterNeeded", "waterNeededMax",
    "lastWaterHour", "nextGrowing", "hasSeed", "hasVegetable",
    "health", "badCare", "exterior", "spriteName", "objectName", "cursed", "compost", "bonusYield", "naturalLight",
    "owner",
}

local TR = { Carrots = { "tr_carrots_0", "tr_carrots_1" }, Onion = { "tr_onion_0", "tr_onion_1" } }
local DEAD = { Carrots = { "dead_carrots_0", "dead_carrots_1", "dead_carrots_2" }, Onion = { "dead_onion_0", "dead_onion_1" } }
local NIL = {} -- crop() 欄位覆寫用：把這個欄位設成 nil

local W -- 這一局的世界：loaded、squares、packets、calls、hooks、now、noSave、throwFor

local function key(x, y, z)
    return x .. "," .. y .. "," .. z
end

-- 事件依註冊順序觸發（LuaEventManager）
local function newEvent()
    local ev = { handlers = {} }
    function ev.Add(fn) ev.handlers[#ev.handlers + 1] = fn end
    function ev.fire()
        for i = 1, #ev.handlers do ev.handlers[i]() end
    end
    return ev
end

-- ── 假 Java GOS（GlobalObjectSystem；方法用 : 呼叫）──────────────
local function newJavaSystem()
    local sys = { objects = {} }
    function sys:getObjectAt(x, y, z)
        for _, go in ipairs(self.objects) do
            if go.x == x and go.y == y and go.z == z then return go end
        end
        return nil
    end
    function sys:newObject(x, y, z)
        if self:getObjectAt(x, y, z) then error("already an object at " .. key(x, y, z)) end
        local go = { x = x, y = y, z = z, modData = {} }
        function go:getModData() return self.modData end
        self.objects[#self.objects + 1] = go
        return go
    end
    function sys:removeObject(go)
        for i, o in ipairs(self.objects) do
            if o == go then table.remove(self.objects, i) return end
        end
    end
    function sys:getObjectCount() return #self.objects end
    function sys:getObjectByIndex(i) return self.objects[i + 1] end
    function sys:addGlobalObjectOnClient(go) W.packets[#W.packets + 1] = "add " .. key(go.x, go.y, go.z) end
    function sys:removeGlobalObjectOnClient(go) W.packets[#W.packets + 1] = "remove " .. key(go.x, go.y, go.z) end
    return sys
end

-- ── 假 SPlantGlobalObject ──────────────────────────────────────
local function makePlant()
    local P = {}
    P.__index = P
    -- SPlantGlobalObject.lua:779-812
    function P:fromModData(modData)
        self.state = modData.state
        self.nbOfGrow = modData.nbOfGrow
        self.typeOfSeed = modData.typeOfSeed
        self.fertilizer = modData.fertilizer
        self.mildewLvl = modData.mildewLvl
        self.aphidLvl = modData.aphidLvl
        self.fliesLvl = modData.fliesLvl
        self.slugsLvl = modData.slugsLvl
        self.hasWeeds = modData.hasWeeds == "true" or modData.hasWeeds == true
        self.naturalLight = modData.naturalLight
        self.waterLvl = modData.waterLvl
        self.waterNeeded = modData.waterNeeded
        self.waterNeededMax = modData.waterNeededMax
        self.lastWaterHour = modData.lastWaterHour
        self.nextGrowing = modData.nextGrowing
        self.hasSeed = modData.hasSeed == "true" or modData.hasSeed == true
        self.hasVegetable = modData.hasVegetable == "true" or modData.hasVegetable == true
        self.cursed = modData.cursed == "true" or modData.cursed == true
        self.compost = modData.compost == "true" or modData.compost == true
        self.bonusYield = modData.bonusYield == "true" or modData.bonusYield == true
        self.health = modData.health
        self.badCare = modData.badCare == "true" or modData.badCare == true
        self.exterior = modData.exterior == true or modData.exterior == nil
        self.spriteName = modData.spriteName
        self.objectName = modData.objectName
        self.owner = modData.owner
        if not self.spriteName then
            self.spriteName = farming_vegetableconf.getSpriteName(self)
        end
        if not self.objectName then
            self.objectName = farming_vegetableconf.getObjectName(self)
        end
    end
    function P:aboutToRemoveFromSystem() end
    return P
end

-- ── 假 SFarmingSystem（class 表，instance 以它為 metatable）──────────
local function makeSystem()
    local C = {}
    C.__index = C
    function C:isValidModData(modData) -- SFarmingSystem.lua:48-50
        return modData and modData.state and modData.nbOfGrow and modData.health
    end
    function C:isValidIsoObject(isoObject) -- :52-54
        return isoObject:hasModData() and self:isValidModData(isoObject:getModData())
    end
    function C:getLuaObjectAt(x, y, z)
        local go = self.system:getObjectAt(x, y, z)
        return go and go:getModData() or nil
    end
    function C:getLuaObjectOnSquare(square)
        if not square then return nil end
        return self:getLuaObjectAt(square:getX(), square:getY(), square:getZ())
    end
    function C:getIsoObjectOnSquare(square)
        if not square then return nil end
        for i = 1, square:getObjects():size() do
            local isoObject = square:getObjects():get(i - 1)
            if self:isValidIsoObject(isoObject) then return isoObject end
        end
        return nil
    end
    function C:newLuaObject(globalObject) -- SGlobalObject.lua:63-73：luaObject 就是 globalObject 的 modData
        local o = setmetatable(globalObject:getModData(), SPlantGlobalObject)
        o.luaSystem = self
        o.globalObject = globalObject
        o.x, o.y, o.z = globalObject.x, globalObject.y, globalObject.z
        return o
    end
    function C:newLuaObjectOnClient(luaObject) self.system:addGlobalObjectOnClient(luaObject.globalObject) end
    function C:removeLuaObjectOnClient(luaObject) self.system:removeGlobalObjectOnClient(luaObject.globalObject) end
    function C:removeLuaObject(luaObject) -- SGlobalObjectSystem.lua:92-99
        if not luaObject or luaObject.luaSystem ~= self then return end
        luaObject:aboutToRemoveFromSystem()
        self:removeLuaObjectOnClient(luaObject)
        self.system:removeObject(luaObject.globalObject)
    end
    function C:getLuaObjectCount() return self.system:getObjectCount() end
    function C:getLuaObjectByIndex(index) return self.system:getObjectByIndex(index - 1):getModData() end
    return C
end

-- ── 假 farming_vegetableconf ───────────────────────────────────
local function makeConf()
    local conf = {
        props = { Carrots = {}, Onion = { aphidsBane = true, slugsProof = true }, Mystery = {} },
        trampledSprite = { Carrots = TR.Carrots, Onion = TR.Onion },
        deadSprite = { Carrots = DEAD.Carrots, Onion = DEAD.Onion },
    }
    -- farming_vegetableconf.lua:250-256 的 spriteType 選法（這裡一律取第 1 張）
    function conf.getSpriteName(plant)
        local list = (plant.state == "destroyed" or plant.state == "harvested") and conf.trampledSprite or conf.deadSprite
        return list[plant.typeOfSeed][1]
    end
    function conf.getObjectName(plant) return "Fallback " .. tostring(plant.typeOfSeed) end
    return conf
end

-- ── 假格子與 IsoObject ─────────────────────────────────────────
local function squareAt(x, y, z)
    local k = key(x, y, z)
    local sq = W.squares[k]
    if sq then return sq end
    local objs = {}
    local list = {}
    function list:size() return #objs end
    function list:get(i) return objs[i + 1] end
    sq = { objs = objs }
    function sq:getX() return x end
    function sq:getY() return y end
    function sq:getZ() return z end
    function sq:getObjects() return list end
    -- 地板：沒有 modData，getIsoObjectOnSquare 要跳過它
    objs[1] = { hasModData = function() return false end, getModData = function() return {} end }
    W.squares[k] = sq
    return sq
end

local function newIso(sq, md, rendered, field)
    local sprite = { name = rendered }
    function sprite:getName() return self.name end
    local o = { md = md, sprite = sprite, field = field, sq = sq }
    function o:getSquare() return self.sq end
    function o:hasModData() return self.md ~= nil end
    function o:getModData() return self.md end
    function o:getSprite() return self.sprite end
    function o:getSpriteName() return self.field end
    sq.objs[#sq.objs + 1] = o
    return o
end

local function baseFields()
    return {
        state = "destroyed", nbOfGrow = 0, typeOfSeed = "Carrots", fertilizer = 0, mildewLvl = 0,
        aphidLvl = 0, fliesLvl = 0, slugsLvl = 0, hasWeeds = false, waterLvl = 0, waterNeeded = 70,
        waterNeededMax = 85, lastWaterHour = 120, nextGrowing = 300, hasSeed = false, hasVegetable = false,
        health = 0, badCare = false, exterior = true, spriteName = TR.Carrots[1], objectName = "Destroyed Carrots",
        cursed = false, compost = false, bonusYield = false, owner = "alice",
    }
end

-- 一株作物：地圖物件（modData 照 fields）＋同步好的 luaObject（loadIsoObject 的建立順序，
-- server/Map/SGlobalObjectSystem.lua:143-147）。opts.rendered 畫面 sprite（預設 md.spriteName）、
-- opts.field spriteName 欄位（預設一張過期的幼苗）、opts.orphan 不建 luaObject、opts.unloaded 不載入
local function crop(x, y, fields, opts)
    opts = opts or {}
    local md = baseFields()
    for k, v in pairs(fields or {}) do
        if v == NIL then md[k] = nil else md[k] = v end
    end
    local sq = squareAt(x, y, 0)
    local rendered = opts.rendered
    if rendered == nil then rendered = md.spriteName end
    local iso = newIso(sq, md, rendered, opts.field or "vegetation_farming_01_1")
    local c = { x = x, y = y, z = 0, md = md, iso = iso, sq = sq, k = key(x, y, 0), rendered = rendered }
    if not opts.orphan then
        local system = SFarmingSystem.instance
        local go = system.system:newObject(x, y, 0)
        c.lo = system:newLuaObject(go)
        c.lo:fromModData(md)
    end
    if not opts.unloaded then W.loaded[c.k] = true end
    W.packets = {}
    return c
end

local function snapshot(t)
    local s = {}
    for _, k in ipairs(KEYS) do s[k] = t[k] end
    return s
end

local function sameKeys(a, b)
    for _, k in ipairs(KEYS) do
        if a[k] ~= b[k] then return false, k .. ": " .. tostring(a[k]) .. " vs " .. tostring(b[k]) end
    end
    return true
end

local function inGos(c)
    return SFarmingSystem.instance:getLuaObjectAt(c.x, c.y, 0) == c.lo
end

local function packetCount(prefix)
    local n = 0
    for _, p in ipairs(W.packets) do
        if p:sub(1, #prefix) == prefix then n = n + 1 end
    end
    return n
end

local function hasPacket(p)
    for _, q in ipairs(W.packets) do
        if q == p then return true end
    end
    return false
end

-- 只觸發 EveryTenMinutes／只觸發 n 次 OnTick（W.now 不動）；錯誤外洩就回 false
local function fireTen()
    local ok, err = pcall(Events.EveryTenMinutes.fire)
    return ok, tostring(err)
end

local function fireTicks(n)
    for _ = 1, n do
        local ok, err = pcall(Events.OnTick.fire)
        if not ok then return false, tostring(err) end
    end
    return true, "true"
end

-- 觸發一次 EveryTenMinutes，再觸發 8 次 OnTick（開輪 1 次、700 株 3 批、餘裕），讓這輪走完
local function tick(advance)
    W.now = W.now + (advance or 0)
    local ok, err = fireTen()
    if not ok then return ok, err end
    return fireTicks(8)
end

local function unloadAll() W.loaded = {} end

-- 標準一輪：載入時掃 → 全部卸載 → 掃（記時間）→ 滿 30 秒掃 → 再 30 秒掃
local function cycle()
    tick(1000)
    unloadAll()
    tick(1000)
    tick(SETTLE)
    tick(SETTLE)
end

-- 模擬 MapObjects 在格子載入時呼叫這張 sprite 的 hook
local function callHook(c)
    local hooks = W.hooks[c.rendered]
    local fn = hooks and hooks[PRIORITY]
    if not fn then return false, "no hook at priority " .. PRIORITY .. " for " .. tostring(c.rendered) end
    W.loaded[c.k] = true
    local ok, err = pcall(fn, c.iso)
    return ok, tostring(err)
end

local function resetEnv(opts)
    opts = opts or {}
    S.reset()
    local client = opts.client == true
    isClient = function() return client end
    for _, m in ipairs({ "Farming/SFarmingSystem", "Farming/SPlantGlobalObject", "Farming/farming_vegetableconf" }) do
        package.loaded[m] = true
    end
    Events.EveryTenMinutes = newEvent()
    Events.OnTick = newEvent()
    W = { loaded = {}, squares = {}, packets = {}, calls = {}, hooks = {}, now = 1000000, noSave = false,
        lookups = 0, noSaveCalls = 0, cells = 0,
        -- 原版 fromModData 的來源（getFilenameOfClosure）；設成 error 物件就拋錯
        closureFile = "C:/Steam/steamapps/common/ProjectZomboid/media/lua/server/Farming/SPlantGlobalObject.lua" }
    getFilenameOfClosure = function()
        if type(W.closureFile) == "table" then error("getFilenameOfClosure boom") end
        return W.closureFile
    end
    SPlantGlobalObject = makePlant()
    SFarmingSystem = makeSystem()
    SFarmingSystem.instance = setmetatable({ system = newJavaSystem() }, SFarmingSystem)
    farming_vegetableconf = makeConf()
    -- MapObjects 是 exposed 靜態類別；同 priority 取代對方（MapObjects.java:148-151）
    MapObjects = {
        OnLoadWithSprite = function(names, fn, priority)
            if W.throwFor ~= nil and names == W.throwFor then error("OnLoadWithSprite boom") end
            W.calls[#W.calls + 1] = { names = names, fn = fn, priority = priority }
            for i = 1, #names do
                W.hooks[names[i]] = W.hooks[names[i]] or {}
                W.hooks[names[i]][priority] = fn
            end
        end,
    }
    local cell = {}
    function cell:getGridSquare(x, y, z)
        local k = key(x, y, z)
        W.lookups = W.lookups + 1
        if W.boomAt == k then error("getGridSquare boom") end
        if W.loaded[k] then return W.squares[k] end
        return nil
    end
    getCell = function()
        W.cells = W.cells + 1
        return cell
    end
    local core = {}
    function core:isNoSave()
        W.noSaveCalls = W.noSaveCalls + 1
        return W.noSave
    end
    getCore = function() return core end
    getTimestampMs = function() return W.now end
end

local function load()
    local ok, err = pcall(S.load, FIX)
    return ok, tostring(err)
end

local function noFixErrors()
    return not S.printed("sweep failed") and not S.printed("could not rebuild") and not S.printed("could not register")
end

local function calledWith(names)
    for _, c in ipairs(W.calls) do
        if c.names == names then return c end
    end
    return nil
end

-- ── 1. 註冊 ───────────────────────────────────────────────────
T.section("[1] 註冊")
resetEnv()
local ok, err = load()
T.check("1 載入不拋錯", ok, err)
local lists = { TR.Carrots, TR.Onion, DEAD.Carrots, DEAD.Onion }
local allRegistered, samePriority, sameFn = true, true, true
local firstFn = W.calls[1] and W.calls[1].fn
for _, names in ipairs(lists) do
    local c = calledWith(names)
    if not c then allRegistered = false
    else
        if c.priority ~= PRIORITY then samePriority = false end
        if c.fn ~= firstFn then sameFn = false end
    end
end
T.check("1 每種作物的 trampled／dead 清單都註冊、沒有清單的作物跳過", allRegistered and #W.calls == 4, "calls=" .. #W.calls)
T.check("1 priority 一律 4242", samePriority)
T.check("1 全部是同一個 hook 函式", sameFn and type(firstFn) == "function")
T.check("1 裝了一個 EveryTenMinutes、一個 OnTick 與一個 OnGameBoot", #Events.EveryTenMinutes.handlers == 1
    and #Events.OnTick.handlers == 1 and #S.bootHandlers == 1)
T.check("1 正常安裝不印診斷", not S.printed("[MinidoracatFixes]"))

-- 後載 MOD 在開機前加進新作物
farming_vegetableconf.props.Potato = {}
farming_vegetableconf.trampledSprite.Potato = { "tr_potato_0" }
S.fireBoot()
local stable = true
for name, byPriority in pairs(W.hooks) do
    local n = 0
    for p, fn in pairs(byPriority) do
        n = n + 1
        if p ~= PRIORITY or fn ~= firstFn then stable = false end
    end
    if n ~= 1 then stable = false end
end
T.check("1 OnGameBoot 重新註冊全部清單", #W.calls == 9, "calls=" .. #W.calls)
T.check("1 重註冊冪等（每張 sprite 只有 4242 一個、同一個函式）", stable)
T.check("1 後載 MOD 的作物也包進來", calledWith(farming_vegetableconf.trampledSprite.Potato) ~= nil
    and W.hooks.tr_potato_0 and W.hooks.tr_potato_0[PRIORITY] == firstFn)

T.section("[1b] 一組註冊拋錯")
resetEnv()
W.throwFor = DEAD.Onion
ok, err = load()
T.check("1b 單組拋錯不外洩", ok, err)
T.check("1b 其他三組照常註冊", #W.calls == 3 and calledWith(TR.Carrots) and calledWith(TR.Onion) and calledWith(DEAD.Carrots)
    and not calledWith(DEAD.Onion), "calls=" .. #W.calls)
T.check("1b 印一次註冊失敗診斷", S.printCount("could not register deadSprite of Onion") == 1)
S.fireBoot()
T.check("1b OnGameBoot 再失敗不重印", S.printCount("could not register") == 1)
local failed = crop(1, 1, { state = "dead", typeOfSeed = "Onion", nbOfGrow = 2, spriteName = DEAD.Onion[1] })
local control = crop(2, 1, { state = "destroyed", typeOfSeed = "Onion", nbOfGrow = 2, spriteName = TR.Onion[1] })
cycle()
T.check("1b 用註冊失敗那組 sprite 的作物永不移出", inGos(failed))
T.check("1b 對照：同一輪註冊成功的作物有移出", not inGos(control))

T.section("[1c] 形狀不符")
resetEnv()
local shapeCrop = crop(1, 1, {})
SFarmingSystem.newLuaObjectOnClient = nil
ok, err = load()
T.check("1c 缺 method：載入不拋錯", ok, err)
T.check("1c 缺 method：印 NOT installed、一個都不註冊", S.printCount("MDFX_FarmingGosPrune NOT installed") == 1 and #W.calls == 0)
cycle()
T.check("1c 缺 method：什麼都不移出", inGos(shapeCrop) and packetCount("remove") == 0)
resetEnv()
shapeCrop = crop(1, 1, {})
MapObjects = nil
ok, err = load()
T.check("1c 缺 MapObjects：印 NOT installed", ok and S.printCount("MDFX_FarmingGosPrune NOT installed") == 1, err)
cycle()
T.check("1c 缺 MapObjects：什麼都不移出", inGos(shapeCrop) and packetCount("remove") == 0)

T.section("[1d] isClient()")
resetEnv({ client = true })
ok, err = load()
T.check("1d 不註冊、不掛事件、不印", ok and #W.calls == 0 and #Events.EveryTenMinutes.handlers == 0
    and #Events.OnTick.handlers == 0 and #S.bootHandlers == 0 and not S.printed("[MinidoracatFixes]"), err)

-- ── 2. 移出生命週期 ───────────────────────────────────────────
for _, case in ipairs({
    { "destroyed", TR.Carrots[1] }, { "harvested", TR.Carrots[2] },
    { "dead", DEAD.Carrots[2] }, { "rotten", DEAD.Carrots[3] },
}) do
    local state = case[1]
    T.section("[2] 移出生命週期：" .. state)
    resetEnv()
    load()
    local c = crop(10, 10, { state = state, spriteName = case[2], nbOfGrow = 4, health = 5 })
    local stay = crop(11, 10, { state = state, spriteName = case[2] })
    tick(1000)
    T.check("2 " .. state .. " 載入中：不移出", inGos(c) and #W.packets == 0)
    W.loaded[c.k] = nil
    local t0 = W.now + 1000
    tick(1000)
    T.check("2 " .. state .. " 第一次掃到沒載入：只記時間、不送包", inGos(c) and #W.packets == 0)
    W.now = t0 + SETTLE - 1
    tick()
    T.check("2 " .. state .. " 距第一次未滿 30 秒：仍不移出", inGos(c) and #W.packets == 0)
    W.now = t0 + SETTLE
    tick()
    T.check("2 " .. state .. " 滿 30 秒：removeLuaObject 移出、送一包移除", not inGos(c)
        and #W.packets == 1 and hasPacket("remove 10,10,0"), table.concat(W.packets, ";"))
    T.check("2 " .. state .. " 仍載入中的另一株不動", inGos(stay))
    T.check("2 " .. state .. " 印一次移出診斷", S.printCount("moved 1 dead/rotten/destroyed/harvested") == 1)
    T.check("2 " .. state .. " 沒有錯誤診斷", noFixErrors())
end

-- ── 3. 不移出 ─────────────────────────────────────────────────
T.section("[3] 不移出（同一輪）")
resetEnv()
load()
local seeded = crop(1, 1, { state = "seeded", nbOfGrow = 2, health = 60 })
local plow = crop(2, 1, { state = "plow", nbOfGrow = -1, health = 100 })
local destroy = crop(3, 1, { state = "destroy", nbOfGrow = 0 })
local companion = crop(4, 1, { state = "dead", typeOfSeed = "Onion", nbOfGrow = 3, spriteName = DEAD.Onion[1] })
local companionDestroyed = crop(5, 1, { state = "destroyed", typeOfSeed = "Onion", nbOfGrow = 5, spriteName = TR.Onion[2] })
local youngOnion = crop(6, 1, { state = "dead", typeOfSeed = "Onion", nbOfGrow = 2, spriteName = DEAD.Onion[2] })
local healthDiff = crop(7, 1, { health = 50 })
healthDiff.lo.health = 40
local ownerDiff = crop(8, 1, { owner = "bob" })
ownerDiff.lo.owner = nil
local exteriorDiff = crop(9, 1, { exterior = NIL })
exteriorDiff.lo.exterior = nil
local noSprite = crop(10, 1, { spriteName = NIL }, { rendered = TR.Carrots[1] })
local wrongSprite = crop(11, 1, { spriteName = TR.Carrots[2] }, { rendered = TR.Carrots[1], field = TR.Carrots[2] })
local unregistered = crop(12, 1, { spriteName = "vegetation_farming_01_13" })
local plain = crop(13, 1, {})
cycle()
T.check("3 seeded 不移出", inGos(seeded))
T.check("3 plow 不移出", inGos(plow))
T.check("3 'destroy'（翻土被毀）不移出", inGos(destroy))
T.check("3 伴生作物（死洋蔥 nbOfGrow 3）不移出", inGos(companion))
T.check("3 伴生作物不看 state（踩爛洋蔥 nbOfGrow 5）不移出", inGos(companionDestroyed))
T.check("3 對照：洋蔥 nbOfGrow 2 不算伴生 → 移出", not inGos(youngOnion))
T.check("3 地圖物件 health 與 luaObject 不同 → 不移出", inGos(healthDiff))
T.check("3 owner 不同（luaObject nil、modData 有值）→ 不移出", inGos(ownerDiff))
T.check("3 exterior 不同（modData nil 會重建成 true、luaObject nil）→ 不移出", inGos(exteriorDiff))
T.check("3 md.spriteName nil（fromModData 會補、hook 不會重建）→ 不移出", inGos(noSprite)
    and noSprite.lo.spriteName == TR.Carrots[1])
T.check("3 畫面 sprite 與 md.spriteName 不同（spriteName 欄位相同也一樣）→ 不移出", inGos(wrongSprite))
T.check("3 畫面 sprite 沒註冊 hook → 不移出", inGos(unregistered))
T.check("3 對照：一般踩爛紅蘿蔔 → 移出", not inGos(plain))
T.check("3 恰好移出兩株", packetCount("remove") == 2, table.concat(W.packets, ";"))
T.check("3 沒有錯誤診斷", noFixErrors())

T.section("[3b] -nosave")
resetEnv()
load()
W.noSave = true
local ns = crop(1, 1, {})
cycle()
T.check("3b isNoSave() 為真：不移出", inGos(ns) and packetCount("remove") == 0)
W.noSave = false
W.loaded[ns.k] = true
cycle()
T.check("3b 對照：關掉 -nosave 後同一株照常移出", not inGos(ns))

T.section("[3b2] -nosave 放棄後不每 tick 查")
resetEnv()
load()
W.noSave = true
fireTen()
W.noSaveCalls = 0
fireTicks(5)
T.check("3b2 一次 EveryTenMinutes 後連續 5 tick：只查一次 isNoSave", W.noSaveCalls == 1, "calls=" .. W.noSaveCalls)
W.noSave = false

T.section("[3b3] SFarmingSystem.instance 為 nil 時觸發一輪")
resetEnv()
load()
local liveInst = SFarmingSystem.instance
SFarmingSystem.instance = nil
fireTen()
local tickOk, tickErr = pcall(fireTicks, 3)
SFarmingSystem.instance = liveInst
T.check("3b3 不拋錯、不印 sweep failed", tickOk and not S.printed("sweep failed"), tickErr)

T.section("[3c] 卸載期間 luaObject 變了")
resetEnv()
load()
local changedLate = crop(1, 1, {})
local changedEarly = crop(2, 1, {})
local changedBack = crop(3, 1, {})
local ctl = crop(4, 1, {})
tick(1000)
unloadAll()
changedEarly.lo.health = 7
tick(1000)
changedLate.lo.waterLvl = 99
changedBack.lo.health = 9
tick(SETTLE)
changedBack.lo.health = 0
tick(SETTLE)
tick(SETTLE)
T.check("3c 第一次卸載掃描前就變了 → 不移出", inGos(changedEarly))
T.check("3c 記下時間之後才變 → 不移出", inGos(changedLate))
T.check("3c 滿 30 秒那次比對時不同就丟掉條目，之後變回去也不移出", inGos(changedBack))
T.check("3c 對照：沒變的移出", not inGos(ctl))

T.section("[3d] 載入時不一致、卸載後才變一致")
resetEnv()
load()
local lateMatch = crop(1, 1, { health = 50 })
lateMatch.lo.health = 40
tick(1000)
unloadAll()
lateMatch.lo.health = 50
tick(1000)
tick(SETTLE)
tick(SETTLE)
T.check("3d 載入時沒驗證通過 → 永不移出", inGos(lateMatch) and packetCount("remove") == 0)

T.section("[3e] 從沒載入過")
resetEnv()
load()
local never = crop(1, 1, {}, { unloaded = true })
tick(1000)
tick(SETTLE)
tick(SETTLE)
T.check("3e 從沒在載入時驗證過 → 不移出", inGos(never) and packetCount("remove") == 0)

T.section("[3f] 中途重新載入要重新等")
resetEnv()
load()
local reloaded = crop(1, 1, {})
tick(1000)
unloadAll()
local first = W.now + 1000
tick(1000)
W.loaded[reloaded.k] = true
W.now = first + 20000
tick()
unloadAll()
local second = first + 29000
W.now = second
tick()
W.now = first + SETTLE + 1
tick()
T.check("3f 距第一次卸載已過 30 秒但中間重新載入過 → 不移出", inGos(reloaded))
W.now = second + SETTLE - 1
tick()
T.check("3f 距重新卸載未滿 30 秒 → 不移出", inGos(reloaded))
W.now = second + SETTLE
tick()
T.check("3f 距重新卸載滿 30 秒 → 移出", not inGos(reloaded))

-- ── 4. 每輪上限 ───────────────────────────────────────────────
T.section("[4] 每輪上限 100")
resetEnv()
load()
local many = {}
for i = 1, 150 do many[i] = crop(i, 50, {}) end
tick(1000)
unloadAll()
tick(1000)
W.packets = {}
tick(SETTLE)
T.check("4 第一輪只移出 100 株", packetCount("remove") == 100 and SFarmingSystem.instance:getLuaObjectCount() == 50,
    "removed=" .. packetCount("remove"))
T.check("4 診斷報剩下的數量", S.printed("moved 100 ") and S.printed("(50 objects left)"))
W.packets = {}
tick(1000)
T.check("4 下一輪移出剩下 50 株", packetCount("remove") == 50 and SFarmingSystem.instance:getLuaObjectCount() == 0,
    "removed=" .. packetCount("remove"))

-- ── 5. 重建 hook ──────────────────────────────────────────────
T.section("[5] 重建 hook")
resetEnv()
load()
local ev = crop(10, 10, { state = "dead", spriteName = DEAD.Carrots[2], nbOfGrow = 4, health = 12, hasWeeds = true,
    owner = "carol", waterLvl = 17.5 })
local evSnap = snapshot(ev.lo)
cycle()
T.check("5 前提：已移出", not inGos(ev))
W.packets = {}
ok, err = callHook(ev)
local rebuilt = SFarmingSystem.instance:getLuaObjectAt(10, 10, 0)
T.check("5 hook 不外洩錯誤", ok, err)
T.check("5 重建出新的 luaObject", rebuilt ~= nil and rebuilt ~= ev.lo and rebuilt.x == 10 and rebuilt.y == 10 and rebuilt.z == 0)
local same, diff = sameKeys(rebuilt or {}, evSnap)
T.check("5 26 個 KEYS 與移出前完全相同", same, diff)
T.check("5 送一包新增", #W.packets == 1 and hasPacket("add 10,10,0"), table.concat(W.packets, ";"))
T.check("5 印一次重建診斷", S.printCount("rebuilt the dead crop at 10,10,0") == 1)

local count = SFarmingSystem.instance:getLuaObjectCount()
W.packets = {}
ok, err = callHook(ev)
T.check("5 這格已有 luaObject → no-op", ok and SFarmingSystem.instance:getLuaObjectAt(10, 10, 0) == rebuilt
    and SFarmingSystem.instance:getLuaObjectCount() == count and #W.packets == 0 and noFixErrors(), err)

local function noRebuild(label, c)
    W.packets = {}
    local n = SFarmingSystem.instance:getLuaObjectCount()
    local okHook, errHook = callHook(c)
    T.check(label, okHook and SFarmingSystem.instance:getLuaObjectAt(c.x, c.y, 0) == nil
        and SFarmingSystem.instance:getLuaObjectCount() == n and #W.packets == 0 and noFixErrors(), errHook)
end
noRebuild("5 md.state 不是可移出狀態（seeded）→ no-op",
    crop(20, 10, { state = "seeded", nbOfGrow = 2, health = 60 }, { orphan = true }))
noRebuild("5 md.spriteName 與畫面 sprite 不同 → no-op",
    crop(21, 10, { spriteName = TR.Carrots[2] }, { orphan = true, rendered = TR.Carrots[1] }))
noRebuild("5 md.spriteName nil → no-op", crop(22, 10, { spriteName = NIL }, { orphan = true, rendered = TR.Carrots[1] }))
noRebuild("5 modData 無效（health nil）→ no-op", crop(23, 10, { health = NIL }, { orphan = true }))
local noMd = crop(24, 10, {}, { orphan = true })
noMd.iso.md = nil
noRebuild("5 沒有 modData → no-op", noMd)
local inst = SFarmingSystem.instance
SFarmingSystem.instance = nil
local noInst = crop(25, 10, {}, { orphan = true })
W.packets = {}
ok, err = callHook(noInst)
T.check("5 SFarmingSystem.instance 為 nil → no-op", ok and #W.packets == 0 and noFixErrors(), err)
SFarmingSystem.instance = inst
T.check("5 instance nil 時沒動到 GOS", inst:getLuaObjectAt(25, 10, 0) == nil)

T.section("[5b] 建到一半失敗")
local realFrom = SPlantGlobalObject.fromModData
SPlantGlobalObject.fromModData = function() error("fromModData boom") end
local half = crop(30, 10, {}, { orphan = true })
count = inst:getLuaObjectCount()
W.packets = {}
ok, err = callHook(half)
T.check("5b 錯誤不外洩", ok, err)
T.check("5b 半成品的 GOS 物件被拿掉", inst:getLuaObjectCount() == count and inst:getLuaObjectAt(30, 10, 0) == nil)
T.check("5b 不送包", #W.packets == 0)
T.check("5b 印一次重建失敗診斷", S.printCount("could not rebuild a crop") == 1)
callHook(half)
T.check("5b 再失敗不重印", S.printCount("could not rebuild a crop") == 1 and inst:getLuaObjectCount() == count)
SPlantGlobalObject.fromModData = realFrom
ok, err = callHook(half)
T.check("5b 恢復後同一格可以重建（沒有殘留的 GOS 物件擋住）", ok and inst:getLuaObjectAt(30, 10, 0) ~= nil
    and hasPacket("add 30,10,0"), err)

-- ── 6. 來回 ──────────────────────────────────────────────────
T.section("[6] 移出 → 重建來回")
resetEnv()
load()
local sets = {
    { label = "預設踩爛紅蘿蔔", fields = {} },
    { label = "收成、布林用字串、owner、室內、小數", fields = { state = "harvested", spriteName = TR.Carrots[2],
        hasWeeds = "true", hasSeed = true, hasVegetable = "false", owner = "alice", exterior = false,
        naturalLight = 0.75, waterLvl = 33.5, fertilizer = 2, cursed = true, compost = "true", bonusYield = true,
        badCare = "true", mildewLvl = 3, aphidLvl = 1, fliesLvl = 2, slugsLvl = 4 } },
    { label = "爛洋蔥、owner nil、exterior nil、lastWaterHour nil", fields = { state = "rotten", typeOfSeed = "Onion",
        nbOfGrow = 2, spriteName = DEAD.Onion[2], owner = NIL, exterior = NIL, lastWaterHour = NIL,
        nextGrowing = 12345.678, health = 3.25, objectName = "Rotten Onion" } },
    { label = "死紅蘿蔔、objectName nil（fromModData 補名字）", fields = { state = "dead", spriteName = DEAD.Carrots[3],
        objectName = NIL, nbOfGrow = 6, health = 0, waterNeeded = NIL } },
}
for i, set in ipairs(sets) do
    set.c = crop(i, 60, set.fields)
    set.snap = snapshot(set.c.lo)
end
cycle()
for _, set in ipairs(sets) do
    local c = set.c
    local wasEvicted = not inGos(c)
    local okHook, errHook = callHook(c)
    local back = SFarmingSystem.instance:getLuaObjectAt(c.x, c.y, 0)
    local eq, d = sameKeys(back or {}, set.snap)
    T.check("6 " .. set.label .. "：移出後重建，KEYS 相同", wasEvicted and okHook and back ~= nil and eq,
        (errHook ~= "true" and errHook or "") .. (d or ""))
end
T.check("6 沒有錯誤診斷", noFixErrors())

-- ── 7. 錯誤與診斷節流 ─────────────────────────────────────────
T.section("[7] 掃描拋錯、診斷一次")
resetEnv()
load()
local a = crop(1, 1, {})
local b = crop(2, 1, {})
W.loaded[b.k] = nil -- b 晚一輪才載入驗證
cycle()
T.check("7 前提：a 已移出", not inGos(a) and inGos(b))
W.loaded[b.k] = true
cycle()
T.check("7 第二輪移出 b，移出診斷仍只一次", not inGos(b) and S.printCount("MDFX_FarmingGosPrune: moved") == 1)
callHook(a)
callHook(b)
T.check("7 重建兩株，重建診斷只一次", SFarmingSystem.instance:getLuaObjectAt(1, 1, 0) ~= nil
    and SFarmingSystem.instance:getLuaObjectAt(2, 1, 0) ~= nil and S.printCount("MDFX_FarmingGosPrune: rebuilt") == 1)
getCell = function() error("getCell boom") end
local ok1, err1 = tick(1000)
local ok2, err2 = tick(1000)
T.check("7 getCell 拋錯不外洩", ok1 and ok2, err1 .. " / " .. err2)
T.check("7 掃描失敗診斷只印一次、帶原因", S.printCount("sweep failed") == 1 and S.printed("getCell boom"))

-- ── 8. 分攤到每幀 ────────────────────────────────────────────
-- 沒有地圖物件的 seeded 作物：撐出索引、不會被評估
local function filler(n, y)
    local system = SFarmingSystem.instance
    for i = 1, n do
        local lo = system:newLuaObject(system.system:newObject(10000 + i, y, 0))
        lo.state, lo.nbOfGrow = "seeded", 2
    end
end

-- 載入時驗過 → 全部卸載 → 記時間 → 時間往後 30 秒（下一輪就能移出）
local function settle()
    tick(1000)
    unloadAll()
    tick(1000)
    W.now = W.now + SETTLE
end

local function count() return SFarmingSystem.instance:getLuaObjectCount() end

T.section("[8a] 重走一株：第一次載入中驗不過、重走時已卸載")
resetEnv()
load()
local victim = crop(900, 2, { state = "seeded", nbOfGrow = 2, health = 60 }) -- 索引 1
local rewalk = crop(1, 2, {})                                               -- 索引 2：第一個走訪 tick 的最後一株
filler(299, 3)
settle()
W.loaded[rewalk.k] = true
rewalk.iso.md.health = 77
fireTen()
fireTicks(2)
SFarmingSystem.instance:removeLuaObject(victim.lo)
W.loaded[rewalk.k] = nil
fireTicks(6)
T.check("8a 別人移掉前方物件讓它被重走：不拿上一輪的條目移出", inGos(rewalk))

T.section("[8b] 重走一株：第一次載入中驗過、重走時已卸載")
resetEnv()
load()
victim = crop(900, 2, { state = "seeded", nbOfGrow = 2, health = 60 })
rewalk = crop(1, 2, {})
filler(299, 3)
settle()
W.loaded[rewalk.k] = true
fireTen()
fireTicks(2)
SFarmingSystem.instance:removeLuaObject(victim.lo)
W.loaded[rewalk.k] = nil
fireTicks(6)
T.check("8b 重走時不繞過 30 秒", inGos(rewalk))
tick()
T.check("8b 下一輪只記時間", inGos(rewalk))
W.now = W.now + SETTLE
tick()
T.check("8b 滿 30 秒才移出", not inGos(rewalk))

T.section("[8c] 一輪出錯放棄：不沿用更早一輪的條目")
resetEnv()
load()
local boom = crop(1, 3, {})    -- 索引 1：最後走到
local changed = crop(2, 3, {}) -- 索引 2
settle()
W.loaded[changed.k] = true
changed.iso.md.health = 77
W.boomAt = boom.k
tick()
T.check("8c 前提：這輪出錯、印一次", S.printCount("sweep failed") == 1 and S.printed("getGridSquare boom"))
W.boomAt = nil
unloadAll()
tick()
T.check("8c 出錯那輪驗不過的作物，下一輪不拿更早的條目移出", inGos(changed))

T.section("[8d] 開輪那幀不走、每 tick 300 株、閒置不碰引擎")
resetEnv()
load()
for i = 1, 700 do crop(i, 4, {}) end
fireTen()
local seen = { W.lookups }
for _ = 1, 4 do
    fireTicks(1)
    seen[#seen + 1] = W.lookups
end
local noSaveBefore = W.noSaveCalls
fireTicks(5)
T.check("8d EveryTenMinutes 那幀不走", seen[1] == 0, table.concat(seen, ","))
T.check("8d 開輪的 OnTick 不走", seen[2] == 0, table.concat(seen, ","))
T.check("8d 之後每 tick 300 株、接著上一 tick 走", seen[3] == 300 and seen[4] == 600 and seen[5] == 700, table.concat(seen, ","))
T.check("8d 走完之後閒置：不再查格子、不查 -nosave", W.lookups == 700 and W.noSaveCalls == noSaveBefore,
    W.lookups .. " / " .. (W.noSaveCalls - noSaveBefore))

T.section("[8e] 每輪上限 100 跨 tick 累計")
resetEnv()
load()
for i = 1, 700 do crop(i, 5, {}) end
settle()
W.packets = {}
tick()
T.check("8e 一輪 3 個 tick 合計恰好移出 100 株", packetCount("remove") == 100, "removed=" .. packetCount("remove"))
for _ = 1, 6 do tick() end
T.check("8e 再 6 輪全部移完", count() == 0, "left=" .. count())

T.section("[8f] 輪中再觸發 EveryTenMinutes")
resetEnv()
load()
for i = 1, 700 do crop(i, 6, {}) end
fireTen()
fireTicks(2)
fireTen()
fireTen()
fireTicks(2)
local midway = W.lookups
fireTicks(8)
local after = W.lookups
fireTicks(5)
T.check("8f 不重開進行中的那輪", midway == 700, "lookups=" .. midway)
T.check("8f 走完後恰好再補一輪", after == 1400 and W.lookups == 1400, after .. " / " .. W.lookups)

T.section("[8g] 數量縮到游標以下")
resetEnv()
load()
local shrink = {}
for i = 1, 700 do shrink[i] = crop(i, 7, {}) end
fireTen()
fireTicks(2)
for i = 1, 350 do SFarmingSystem.instance:removeLuaObject(shrink[i].lo) end
fireTicks(5)
T.check("8g 不拋錯，剩下沒走過的 50 株照走", not S.printed("sweep failed") and W.lookups == 350, "lookups=" .. W.lookups)
settle()
for _ = 1, 4 do tick() end
T.check("8g 之後照常移完", count() == 0, "left=" .. count())

T.section("[8h] 原版 fromModData 只比 KEYS；別的 MOD 換掉才比多寫的鍵")
local function extraFrom()
    local realFrom = SPlantGlobalObject.fromModData
    SPlantGlobalObject.fromModData = function(self, md)
        realFrom(self, md)
        self.extra = 1
    end
end
local MOD_FILE = "D:/Steam/steamapps/workshop/content/108600/1/mods/Farm/42/media/lua/server/Farming/SPlantGlobalObject.lua"
resetEnv()
load()
W.closureFile = "C:\\STEAM\\ProjectZomboid\\media\\lua\\server\\Farming\\SPlantGlobalObject.lua"
local plainA = crop(1, 8, {})
local realPairs, pairsCalls = pairs, 0
pairs = function(t)
    pairsCalls = pairsCalls + 1
    return realPairs(t)
end
cycle()
pairs = realPairs
T.check("8h 原版路徑（反斜線、大寫）：照常移出、不跑 pairs", not inGos(plainA) and pairsCalls == 0, "pairs=" .. pairsCalls)

resetEnv()
load()
W.closureFile = MOD_FILE
local missing, matching = crop(1, 8, {}), crop(2, 8, {})
extraFrom()
matching.lo.extra = 1
cycle()
T.check("8h /mods/ 底下同名檔：多寫的鍵不同 → 不移出", inGos(missing))
T.check("8h /mods/ 底下同名檔：多寫的鍵相同 → 移出", not inGos(matching))

for _, case in ipairs({
    { "別的檔名", "C:/Steam/ProjectZomboid/media/lua/server/Farming/MyFarming.lua" },
    { "查來源拋錯", {} },
}) do
    resetEnv()
    load()
    W.closureFile = case[2]
    local other = crop(1, 8, {})
    extraFrom()
    cycle()
    T.check("8h " .. case[1] .. "：當成外來、多寫的鍵不同 → 不移出", inGos(other) and not S.printed("sweep failed"))
end

resetEnv()
load()
local swapped = crop(1, 8, {})
fireTen()
fireTicks(1)
W.closureFile = MOD_FILE
extraFrom()
fireTicks(7)
unloadAll()
tick(1000)
tick(SETTLE)
T.check("8h 輪中途才換掉 fromModData：之後那輪重判、多寫的鍵不同 → 不移出", inGos(swapped))

do
    resetEnv()
    load()
    local late = crop(1, 8, {})
    fireTen()
    fireTicks(1)
    W.closureFile = MOD_FILE
    extraFrom()
    late.lo.extra = 1
    fireTicks(7)
    unloadAll()
    tick(1000)
    late.lo.extra = 2
    tick(SETTLE)
    T.check("8h 輪中途才換掉、記時間之後多寫的鍵才變：移出時仍比多寫的鍵 → 不移出", inGos(late))
end

do
    resetEnv()
    load()
    W.closureFile = "C:/STEAM/ProjectZomboid/media/lua/server/Farming/SPlantGlobalObject.lua"
    local back = crop(1, 8, {})
    back.lo.extra = 2
    local vanillaFrom = SPlantGlobalObject.fromModData
    fireTen()
    fireTicks(1)
    extraFrom()
    fireTicks(7)
    SPlantGlobalObject.fromModData = vanillaFrom
    unloadAll()
    tick(1000)
    tick(SETTLE)
    T.check("8h 開輪後才換掉、下一輪前又換回：快照時仍比多寫的鍵 → 不移出", inGos(back))
end

T.section("[8i] 輪中途 -nosave")
resetEnv()
load()
for i = 1, 50 do crop(i, 9, {}) end
filler(300, 10)
settle()
W.packets = {}
fireTen()
fireTicks(2)
W.noSave = true
fireTicks(6)
T.check("8i 走到一半開 -nosave：不移出", packetCount("remove") == 0, "removed=" .. packetCount("remove"))
W.noSave = false
tick()
T.check("8i 關掉之後下一輪也不拿放棄前的條目移出", packetCount("remove") == 0, "removed=" .. packetCount("remove"))

T.section("[8j] 出錯後不每 tick 重試")
resetEnv()
load()
local retry = crop(1, 11, {})
local realGetCell = getCell
getCell = function()
    W.cells = W.cells + 1
    error("getCell boom 8j")
end
fireTen()
fireTicks(7)
T.check("8j 出錯只發生一次", W.cells == 1 and S.printCount("sweep failed") == 1, "getCell=" .. W.cells)
getCell = realGetCell
cycle()
T.check("8j 恢復後照常移出", not inGos(retry))

T.section("[8k] 輪中途在尾端新增")
resetEnv()
load()
for i = 1, 350 do crop(i, 12, {}) end
settle()
fireTen()
fireTicks(2)
local late = crop(5000, 12, {}, { unloaded = true })
fireTicks(6)
for _ = 1, 5 do tick() end
T.check("8k 原有的照常移完，只剩新增的那株", count() == 1 and inGos(late), "left=" .. count())

T.section("[8l] 延後比對")
resetEnv()
load()
local flip = crop(1, 13, {})
tick(1000)
unloadAll()
tick(1000)
flip.lo.health = 9
tick(1000)
flip.lo.health = 0
W.now = W.now + SETTLE
tick()
T.check("8l 未滿 30 秒時變了又變回：移出當下相同就移出", not inGos(flip))

resetEnv()
load()
local queued = {}
for i = 1, 150 do queued[i] = crop(i, 14, {}) end
settle()
tick()
T.check("8l 前提：上限擋下 50 株、索引 1 那株還在", count() == 50 and inGos(queued[1]), "left=" .. count())
queued[1].lo.health = 5
tick()
T.check("8l 排隊時變了：輪到移出時比對擋下", inGos(queued[1]) and count() == 1, "left=" .. count())

T.section("[8m] 重走一株：第一次因狀態被排除、重走時已恢復")
resetEnv()
load()
victim = crop(900, 2, { state = "seeded", nbOfGrow = 2, health = 60 }) -- 索引 1
rewalk = crop(1, 2, {})                                               -- 索引 2：第一個走訪 tick 的最後一株
filler(299, 3)
settle()
local restState = rewalk.lo.state
rewalk.lo.state = "seeded"
fireTen()
fireTicks(2)
SFarmingSystem.instance:removeLuaObject(victim.lo)
rewalk.lo.state = restState
fireTicks(6)
T.check("8m 這輪已排除的作物，重走時不拿上一輪的條目移出", inGos(rewalk))

T.section("[8n] 快照記下自己的比對方式")
resetEnv()
load()
local vanillaFile, vanillaFrom = W.closureFile, SPlantGlobalObject.fromModData
W.closureFile = MOD_FILE
local drift = crop(1, 15, {})
extraFrom()
drift.lo.extra = 1
tick(1000)
unloadAll()
W.closureFile, SPlantGlobalObject.fromModData = vanillaFile, vanillaFrom
tick(1000)
drift.lo.extra = 2
tick(SETTLE)
tick(SETTLE)
T.check("8n 外來 fromModData 做的快照，換回原版後仍比多寫的鍵：不同 → 不移出", inGos(drift))

T.section("[8o] 舊式 modData（objectName 是 nil 或 false）一律全鍵比對")
local realName = farming_vegetableconf.getObjectName
for _, v in ipairs({ NIL, false }) do
    resetEnv()
    load()
    local oldStyle = crop(1, 16, { objectName = v })
    farming_vegetableconf.getObjectName = function(plant)
        plant.extra = 1
        return realName(plant)
    end
    cycle()
    T.check("8o objectName " .. (v == false and "false" or "nil") .. "：換掉的 getObjectName 多寫的鍵不同 → 不移出", inGos(oldStyle))
    farming_vegetableconf.getObjectName = realName
end

T.section("[8p] 活的作物不查格子")
resetEnv()
load()
filler(50, 17)
fireTen()
fireTicks(3)
T.check("8p 走過 50 株活作物，一次都不查格子", W.lookups == 0, "lookups=" .. W.lookups)

T.section("[8q] 輪中再觸發 EveryTenMinutes：每輪上限不變")
do
    resetEnv()
    load()
    for i = 1, 700 do crop(i, 18, {}) end
    settle()
    W.packets = {}
    fireTen()
    fireTicks(2)
    fireTen()
    fireTicks(2)
    T.check("8q 這輪收到兩次 EveryTenMinutes：仍只移出 100 株", packetCount("remove") == 100, "removed=" .. packetCount("remove"))
end

T.section("[8r] 第一次記時間時比一次")
do
    resetEnv()
    load()
    local c = crop(1, 19, {})
    local health = c.lo.health
    tick(1000)
    unloadAll()
    c.lo.health = 9
    tick(1000)
    c.lo.health = health
    tick(SETTLE)
    tick(SETTLE)
    T.check("8r 卸載時已經和快照不同：之後變回也不移出", inGos(c))
end

T.section("[8s] 重新載入讓舊驗證失效")
do
    resetEnv()
    load()
    local c = crop(1, 20, {})
    settle()
    W.loaded[c.k] = true
    callHook(c)
    W.loaded[c.k] = nil
    tick()
    T.check("8s 載入後、輪到它之前又卸載：不拿載入前的條目移出", inGos(c))
    W.loaded[c.k] = true
    cycle()
    T.check("8s 之後重新驗過照常移出", not inGos(c))

    resetEnv()
    load()
    filler(300, 21)
    c = crop(1, 21, {}) -- 索引 301：這輪第一個走到
    tick(1000)
    unloadAll()
    fireTen()
    fireTicks(2)
    W.loaded[c.k] = true
    callHook(c)
    W.loaded[c.k] = nil
    fireTicks(6)
    W.now = W.now + SETTLE
    tick()
    T.check("8s 這輪記下時間後才重新載入：這輪記下的也不算", inGos(c))
end

T.finish()
