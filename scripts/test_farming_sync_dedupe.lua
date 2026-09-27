-- MDFX_FarmingSyncDedupe 離線自我檢查
-- 用法（repo 根目錄）： lua scripts/test_farming_sync_dedupe.lua
--
-- 以最小假 vanilla SPlantGlobalObject（本體照 SPlantGlobalObject.lua:43-121、:771-777 的
-- 送包形狀）與假 IsoObject（照 IsoObject.java 的 name／sprite／spriteName 欄位語意）驗證：
--   * isServer() 為假時完全不安裝，也不動原函式的全域表
--   * 載入時（stateFromIsoObject／stateToIsoObject）：原版固定三包 → 名稱／sprite／modData
--     各自有變才送、順序同原版；sprite 比物件本身（setSpriteFromName 不更新 spriteName 欄位）
--   * saveData：寫入前後相同且與這一格上次送出相同才不送；
--       - setSpriteName／setObjectName 先寫 modData 不送、再 saveData（播種、生長、枯死的形狀）必須送
--       - 別人改過 iso modData（客戶端轉送、MOD 直寫）必須送
--   * 指紋比內容不比順序、分得出 "1" 與 1、巢狀 table 一律照原版送、比對失敗照原版送
--   * 只包原版檔案的函式（別的 MOD 覆寫就不碰），三個 method 各自判斷
--   * 原函式拋錯原樣外洩；重複載入／OnGameBoot 不疊；後載 MOD 替換後不接回去
--   * 診斷每種只印一次

local S = dofile("scripts/_stub.lua")
local T = S.checker()
local FIX = S.SERVER_FIXES .. "MDFX_FarmingSyncDedupe.lua"
local VANILLA_PATH = "D:/SteamLibrary/steamapps/common/ProjectZomboid/media/lua/server/Farming/SPlantGlobalObject.lua"

-- Kahlua 的 setfenv／getfenv（BaseLib.java:152-204，只換這一個 closure 的 env）在
-- Lua 5.2+ 不存在：用 _ENV upvalue 模擬，upvaluejoin 讓它不再與同 chunk 的函式共用 _ENV
local function envSlot(fn)
    local i = 1
    while true do
        local name = debug.getupvalue(fn, i)
        if name == "_ENV" then return i end
        if name == nil then return nil end
        i = i + 1
    end
end
local function kahluaSetfenv(fn, env)
    local slot = envSlot(fn)
    if slot then debug.upvaluejoin(fn, slot, function() return env end, 1) end
    return fn
end
local function kahluaGetfenv(fn)
    local slot = envSlot(fn)
    if not slot then return _G end
    local _, env = debug.getupvalue(fn, slot)
    return env
end

-- ── 假 IsoObject ────────────────────────────────────────────────
local SPRITES = {}
local function spriteNamed(name)
    if name == nil then return nil end
    local s = SPRITES[name]
    if not s then
        s = { name = name }
        SPRITES[name] = s
    end
    return s
end

local function newIso(name, spriteName, md)
    local o = { name = name, sprite = spriteNamed(spriteName), spriteNameField = spriteName, md = md or {}, sent = {} }
    function o:getName() return self.name end
    function o:setName(n) self.name = n end
    function o:getSprite() return self.sprite end
    function o:setSpriteFromName(n) self.sprite = spriteNamed(n) end -- IsoObject.java:1979-1982：不動 spriteName 欄位
    function o:getSpriteName() return self.spriteNameField or (self.sprite and self.sprite.name) end -- :2235-2237
    function o:getModData() return self.md end
    function o:sendObjectChange(change) self.sent[#self.sent + 1] = change end
    function o:transmitModData() self.sent[#self.sent + 1] = "MODDATA" end
    return o
end

local function take(iso)
    local s = table.concat(iso.sent, ",")
    iso.sent = {}
    return s
end

-- 依指定順序走訪的 table（模擬 Kahlua LinkedHashMap 插入順序，KahluaTableImpl.java:18）；
-- order 沒列到的鍵接在後面，照 next 的順序
local function ordered(t, order)
    return setmetatable(t, { __pairs = function(tbl)
        local listed = {}
        for _, k in ipairs(order) do listed[k] = true end
        local i, rest = 0, nil
        return function()
            while i < #order do
                i = i + 1
                local k = order[i]
                if rawget(tbl, k) ~= nil then return k, rawget(tbl, k) end
            end
            repeat
                rest = next(tbl, rest)
            until rest == nil or not listed[rest]
            if rest == nil then return nil end
            return rest, rawget(tbl, rest)
        end, tbl, nil
    end })
end

-- ── 假 vanilla SPlantGlobalObject（每次都是新 closure：setfenv 會改到它們）──────────
local FIELDS = { "state", "nbOfGrow", "typeOfSeed", "waterLvl", "health", "spriteName", "objectName" }
local FILES = {}

local function makeVanilla()
    local C = { calls = { saveData = 0 } }
    C.__index = C
    function C:toModData(md)
        for _, f in ipairs(FIELDS) do md[f] = self[f] end
    end
    function C:fromModData(md)
        for _, f in ipairs(FIELDS) do self[f] = md[f] end
    end
    function C:initNew()
        self.state = "plow"
        self.nbOfGrow = -1
    end
    function C:getIsoObject() return self.iso end
    -- :43-56
    function C:stateFromIsoObject(isoObject)
        self:initNew()
        self:fromModData(isoObject:getModData())
        self.objectName = isoObject:getName()
        self.spriteName = isoObject:getSpriteName()
        if isServer() then
            isoObject:sendObjectChange(IsoObjectChange.NAME)
            isoObject:sendObjectChange(IsoObjectChange.SPRITE)
            isoObject:transmitModData()
        end
    end
    -- :58-87（略去 exterior／lastWaterHour 整理，送包形狀相同）
    function C:stateToIsoObject(isoObject)
        if self.failLoad then error("vanilla stateToIsoObject boom") end
        isoObject:setName(self.objectName)
        isoObject:setSpriteFromName(self.spriteName)
        self:toModData(isoObject:getModData())
        if isServer() then
            isoObject:sendObjectChange(IsoObjectChange.NAME)
            isoObject:sendObjectChange(IsoObjectChange.SPRITE)
            isoObject:transmitModData()
        end
    end
    -- :93-106
    function C:setObjectName(objectName)
        if objectName == self.objectName then return end
        self.objectName = objectName
        local object = self:getIsoObject()
        if object then
            object:setName(self.objectName)
            if isServer() then object:sendObjectChange(IsoObjectChange.NAME) end
            self:toModData(object:getModData())
        end
    end
    -- :108-121
    function C:setSpriteName(spriteName)
        if spriteName == self.spriteName then return end
        self.spriteName = spriteName
        local object = self:getIsoObject()
        if object then
            object:setSpriteFromName(self.spriteName)
            if isServer() then object:sendObjectChange(IsoObjectChange.SPRITE) end
            self:toModData(object:getModData())
        end
    end
    -- :771-777
    function C:saveData()
        C.calls.saveData = C.calls.saveData + 1
        local isoObject = self:getIsoObject()
        if isoObject then
            self:toModData(isoObject:getModData())
            isoObject:transmitModData()
        end
    end
    for _, m in ipairs({ "stateFromIsoObject", "stateToIsoObject", "saveData", "setObjectName", "setSpriteName" }) do
        FILES[C[m]] = VANILLA_PATH
    end
    return C
end

local function resetEnv(asServer)
    S.reset({ server = asServer })
    setfenv, getfenv = kahluaSetfenv, kahluaGetfenv
    getFilenameOfClosure = function(fn) return FILES[fn] end -- LuaManager.java:7321-7323
    IsoObjectChange = { NAME = "NAME", SPRITE = "SPRITE" }
    SPlantGlobalObject = makeVanilla()
    return SPlantGlobalObject
end

local function carrot(x, y)
    return { x = x or 10, y = y or 20, z = 0, state = "seeded", nbOfGrow = 2, typeOfSeed = "Carrots",
        waterLvl = 60, health = 70, spriteName = "vegetation_farming_01_57", objectName = "Seedling Carrots" }
end

local function newPlant(C, fields, iso)
    local o = setmetatable({}, C)
    for k, v in pairs(fields) do o[k] = v end
    o.iso = iso
    return o
end

-- iso object 狀態與 luaObject 完全一致（chunk 從存檔載回、上次已同步的樣子）
local function syncedIso(C, fields)
    local iso = newIso(fields.objectName, fields.spriteName, {})
    local p = newPlant(C, fields, iso)
    C.toModData(p, iso.md)
    return p, iso
end

-- ── 1. client／單人：完全不安裝 ────────────────────────────────
T.section("[1] isServer() 為假時零介入")
local C = resetEnv(false)
local origFrom, origTo, origSave = C.stateFromIsoObject, C.stateToIsoObject, C.saveData
S.load(FIX)
S.fireBoot()
T.check("1 三個 method 都沒被換", C.stateFromIsoObject == origFrom and C.stateToIsoObject == origTo and C.saveData == origSave)
T.check("1 原函式的全域表沒被換", kahluaGetfenv(origTo) == _G and kahluaGetfenv(origFrom) == _G)
T.check("1 不印任何診斷", not S.printed("[MinidoracatFixes]"))

-- ── 2. server：安裝 ────────────────────────────────────────────
T.section("[2] server 安裝")
C = resetEnv(true)
local before = S.snapshotKeys(C)
origFrom, origTo, origSave = C.stateFromIsoObject, C.stateToIsoObject, C.saveData
S.load(FIX)
T.check("2 三個 method 都包上", C.stateFromIsoObject ~= origFrom and C.stateToIsoObject ~= origTo and C.saveData ~= origSave)
T.check("2 不新增任何成員", #S.extraKeys(C, before, nil) == 0, table.concat(S.extraKeys(C, before, nil), ","))
T.check("2 印 installed 一次", S.printCount("MDFX_FarmingSyncDedupe installed") == 1)
local wrappedTo = C.stateToIsoObject
S.fireBoot()
T.check("2 OnGameBoot 復查不疊、不重印", C.stateToIsoObject == wrappedTo and S.printCount("MDFX_FarmingSyncDedupe installed") == 1)
T.check("2 復查不把自己的 wrapper 當成別人的", not S.printed("NOT installed"))

-- ── 3. 載入時沒變：一包都不送 ──────────────────────────────────
T.section("[3] stateToIsoObject 沒變")
C = resetEnv(true)
local control = makeVanilla()
S.load(FIX)
local p, iso = syncedIso(C, carrot())
C.stateToIsoObject(p, iso)
T.check("3 名稱／sprite／modData 都沒變 → 零封包", take(iso) == "")
T.check("3 iso object 狀態照原版寫入", iso.md.state == "seeded" and iso.name == "Seedling Carrots")
C.stateToIsoObject(p, iso)
T.check("3 skip 診斷只印一次", S.printCount("unchanged crop load sync") == 1)
local cp, ciso = syncedIso(control, carrot())
control.stateToIsoObject(cp, ciso)
T.check("3 對照組：原版同一狀態也固定送三包", take(ciso) == "NAME,SPRITE,MODDATA")

-- ── 4. 載入時有變：逐項補送、順序同原版 ────────────────────────
T.section("[4] stateToIsoObject 逐項")
C = resetEnv(true)
S.load(FIX)
p, iso = syncedIso(C, carrot())
iso.name = "Old Name"
C.stateToIsoObject(p, iso)
T.check("4 只有名稱變 → 只送 NAME", take(iso) == "NAME")

p, iso = syncedIso(C, carrot())
iso.sprite = spriteNamed("vegetation_farming_01_1") -- sprite 物件被換過，spriteName 欄位與 modData 仍是新值
C.stateToIsoObject(p, iso)
T.check("4 只有 sprite 物件變（getSpriteName 看不出來）→ 只送 SPRITE", take(iso) == "SPRITE")

p, iso = syncedIso(C, carrot())
iso.md.waterLvl = 10
C.stateToIsoObject(p, iso)
T.check("4 只有 modData 變 → 只送 modData", take(iso) == "MODDATA")

local fields = carrot()
iso = newIso("Old Name", "vegetation_farming_01_1", { state = "plow" })
p = newPlant(C, fields, iso)
C.stateToIsoObject(p, iso)
T.check("4 三項都變 → 三包、順序 NAME,SPRITE,MODDATA", take(iso) == "NAME,SPRITE,MODDATA")

-- ── 5. stateFromIsoObject 只讀 iso object：一包都不送 ──────────
T.section("[5] stateFromIsoObject")
C = resetEnv(true)
control = makeVanilla()
S.load(FIX)
iso = newIso("Destroyed Carrots", "vegetation_farming_01_13", { state = "destroy", nbOfGrow = 0, health = 0 })
p = newPlant(C, { x = 1, y = 2, z = 0 }, nil)
C.stateFromIsoObject(p, iso)
T.check("5 修正後零封包", take(iso) == "")
T.check("5 luaObject 照原版從 iso object 讀回", p.state == "destroy" and p.objectName == "Destroyed Carrots"
    and p.spriteName == "vegetation_farming_01_13")
local ciso2 = newIso("Destroyed Carrots", "vegetation_farming_01_13", { state = "destroy", nbOfGrow = 0, health = 0 })
control.stateFromIsoObject(newPlant(control, { x = 1, y = 2, z = 0 }, nil), ciso2)
T.check("5 對照組：原版固定送三包", take(ciso2) == "NAME,SPRITE,MODDATA")

-- ── 6. saveData 基本序列 ───────────────────────────────────────
T.section("[6] saveData 序列")
C = resetEnv(true)
S.load(FIX)
p, iso = syncedIso(C, carrot())
C.saveData(p)
T.check("6 這一格還沒有基準 → 照原版送", take(iso) == "MODDATA" and C.calls.saveData == 1)
C.saveData(p)
T.check("6 沒變 → 不送、不呼叫原函式", take(iso) == "" and C.calls.saveData == 1)
T.check("6 skip 診斷印一次", S.printCount("unchanged crop modData resend") == 1)
p.waterLvl = 59.9
C.saveData(p)
T.check("6 值變了 → 送", take(iso) == "MODDATA" and iso.md.waterLvl == 59.9)
C.saveData(p)
C.saveData(p)
T.check("6 又沒變 → 不送；診斷仍只一次", take(iso) == "" and S.printCount("unchanged crop modData resend") == 1)

-- ── 7. 先寫 modData 不送、再 saveData（播種／生長／枯死）──────────
T.section("[7] setSpriteName／setObjectName 之後的 saveData")
C = resetEnv(true)
S.load(FIX)
p, iso = syncedIso(C, carrot())
C.saveData(p)
take(iso)
p.state = "dead"
C.setSpriteName(p, "vegetation_farming_01_60")
T.check("7 原版 setSpriteName 只送 SPRITE、modData 已寫進 iso", take(iso) == "SPRITE" and iso.md.state == "dead")
C.saveData(p)
T.check("7 寫入前後相同但和上次送出的不同 → 必須送", take(iso) == "MODDATA")
C.setObjectName(p, "Dead Carrots")
T.check("7 原版 setObjectName 只送 NAME", take(iso) == "NAME" and iso.md.objectName == "Dead Carrots")
C.saveData(p)
T.check("7 setObjectName 之後的 saveData 也必須送", take(iso) == "MODDATA")

-- ── 8. 別人改過 iso modData ────────────────────────────────────
T.section("[8] iso modData 被外部改寫")
C = resetEnv(true)
S.load(FIX)
p, iso = syncedIso(C, carrot())
C.saveData(p)
take(iso)
iso.md.waterLvl = 0 -- 客戶端送來的 ObjectModData 已套到 server（ObjectModDataPacket.java:50-96）
C.saveData(p)
T.check("8 toModData 蓋回原值、只有寫入前看得到 → 必須送", take(iso) == "MODDATA" and iso.md.waterLvl == 60)
C.saveData(p)
T.check("8 之後沒變 → 不送", take(iso) == "")
iso.md.otherModKey = "x" -- 某 MOD 直接寫 iso modData、自己沒送
C.saveData(p)
T.check("8 額外的鍵（前後都有、上次沒送過）→ 必須送", take(iso) == "MODDATA")
C.saveData(p)
T.check("8 送過之後 → 不送", take(iso) == "")

-- ── 9. 指紋比內容 ──────────────────────────────────────────────
T.section("[9] 指紋")
C = resetEnv(true)
S.load(FIX)
fields = carrot()
local order = { "state", "nbOfGrow", "typeOfSeed", "waterLvl", "health", "spriteName", "objectName" }
iso = newIso(fields.objectName, fields.spriteName, ordered({}, order))
p = newPlant(C, fields, iso)
C.toModData(p, iso.md)
C.saveData(p)
take(iso)
local reversed = {}
for i = #order, 1, -1 do reversed[#reversed + 1] = order[i] end
iso.md = ordered({}, reversed) -- 同內容、走訪順序相反（chunk 重載後的新 table）
C.toModData(p, iso.md)
C.saveData(p)
T.check("9 同內容不同走訪順序 → 不送", take(iso) == "")

iso.md.custom = "1"
C.saveData(p)
take(iso)
iso.md.custom = 1
C.saveData(p)
T.check("9 字串 \"1\" 與數字 1 分得出來 → 送", take(iso) == "MODDATA")

iso.md.fn = function() end -- 不會上線的型別（KahluaTableImpl.java:387-401）
C.saveData(p)
T.check("9 不會上線的值變動不算變 → 不送", take(iso) == "")

iso.md.nested = { a = 1 }
C.saveData(p)
C.saveData(p)
T.check("9 巢狀 table 看不出來 → 每次照原版送", take(iso) == "MODDATA,MODDATA")

p, iso = syncedIso(C, carrot())
iso.md.nested = { a = 1 }
C.stateToIsoObject(p, iso)
T.check("9 載入時遇到巢狀 table 也照原版送 modData", take(iso) == "MODDATA")

-- ── 10. 比對本身失敗 → 照原版送 ────────────────────────────────
T.section("[10] 指紋失敗")
C = resetEnv(true)
S.load(FIX)
p, iso = syncedIso(C, carrot())
setmetatable(iso.md, { __pairs = function() error("broken modData") end })
local ok = pcall(C.saveData, p)
T.check("10 不拋例外", ok)
T.check("10 照原版送", take(iso) == "MODDATA")
pcall(C.saveData, p)
T.check("10 診斷只印一次", S.printCount("could not compare") == 1)

-- ── 11. 沒有 iso object、多格、原函式拋錯 ──────────────────────
T.section("[11] 邊界")
C = resetEnv(true)
S.load(FIX)
p = newPlant(C, carrot(), nil)
ok = pcall(C.saveData, p)
T.check("11 沒有 iso object → 原樣交給原函式", ok and C.calls.saveData == 1)

local pa, isoA = syncedIso(C, carrot(1, 1))
local pb, isoB = syncedIso(C, carrot(2, 2))
C.saveData(pa)
C.saveData(pa)
C.saveData(pb)
T.check("11 基準按座標分開：A 的基準不讓 B 跳過", take(isoA) == "MODDATA" and take(isoB) == "MODDATA")

p, iso = syncedIso(C, carrot())
p.failLoad = true
local okLoad, err = pcall(C.stateToIsoObject, p, iso)
T.check("11 原函式拋錯原樣外洩", not okLoad and tostring(err):find("vanilla stateToIsoObject boom", 1, true) ~= nil)
T.check("11 拋錯時不補送", take(iso) == "")

-- ── 12. 只包原版檔案的函式 ─────────────────────────────────────
T.section("[12] 來源判斷")
C = resetEnv(true)
local modSave = function(self) end
FILES[modSave] = "C:/Users/x/Zomboid/mods/FarmMod/42/media/lua/server/Farming/SPlantGlobalObject.lua"
C.saveData = modSave
origTo = C.stateToIsoObject
S.load(FIX)
T.check("12 別的 MOD 覆寫的 saveData 不碰", C.saveData == modSave)
T.check("12 其他兩個照裝", C.stateToIsoObject ~= origTo)
T.check("12 印 NOT installed 並指出來源", S.printed("NOT installed for SPlantGlobalObject.saveData")
    and S.printed("mods/FarmMod"))
T.check("12 缺一個就不印 installed", not S.printed("MDFX_FarmingSyncDedupe installed"))

C = resetEnv(true)
local win = "D:\\SteamLibrary\\steamapps\\common\\ProjectZomboid\\media\\lua\\server\\Farming\\SPlantGlobalObject.lua"
for _, m in ipairs({ "stateFromIsoObject", "stateToIsoObject", "saveData" }) do FILES[C[m]] = win end
origSave = C.saveData
S.load(FIX)
T.check("12 Windows 反斜線路徑也認得是原版", C.saveData ~= origSave and S.printed("MDFX_FarmingSyncDedupe installed"))

C = resetEnv(true)
local other = function(self, isoObject) end
FILES[other] = "D:/SteamLibrary/steamapps/common/ProjectZomboid/media/lua/server/Farming/SFarmingSystem.lua"
C.stateFromIsoObject = other
S.load(FIX)
T.check("12 別的檔案定義的函式不碰", C.stateFromIsoObject == other)

-- ── 13. 形狀不符 ───────────────────────────────────────────────
T.section("[13] 形狀不符")
C = resetEnv(true)
getFilenameOfClosure = nil
origSave = C.saveData
ok = pcall(S.load, FIX)
T.check("13 缺 getFilenameOfClosure → 不炸、不裝", ok and C.saveData == origSave)
T.check("13 印 shape changed", S.printed("NOT installed: vanilla SPlantGlobalObject shape changed"))

C = resetEnv(true)
setfenv = nil
origSave = C.saveData
S.load(FIX)
T.check("13 缺 setfenv → 不裝", C.saveData == origSave)

resetEnv(true)
SPlantGlobalObject = nil
ok = pcall(S.load, FIX)
T.check("13 class 不存在 → 不炸、不建假表", ok and SPlantGlobalObject == nil)

C = resetEnv(true)
C.saveData = nil
origTo = C.stateToIsoObject
S.load(FIX)
T.check("13 單一 method 缺席 → 只有它不裝", C.saveData == nil and C.stateToIsoObject ~= origTo
    and S.printed("NOT installed for SPlantGlobalObject.saveData"))

-- ── 14. 重複載入與後載替換 ─────────────────────────────────────
T.section("[14] 冪等")
C = resetEnv(true)
S.load(FIX)
local w1 = C.saveData
S.load(FIX) -- 本檔單獨重跑：現任已是 wrapper（不是原版檔）→ 不疊
T.check("14 本檔重跑不疊第二層", C.saveData == w1)
p, iso = syncedIso(C, carrot())
C.saveData(p)
T.check("14 原函式恰呼叫一次", C.calls.saveData == 1 and take(iso) == "MODDATA")

C = resetEnv(true)
S.load(FIX)
local later = function(self) end
C.saveData = later
S.fireBoot()
T.check("14 後載 MOD 換掉後，OnGameBoot 不接回去", C.saveData == later)

T.finish()
