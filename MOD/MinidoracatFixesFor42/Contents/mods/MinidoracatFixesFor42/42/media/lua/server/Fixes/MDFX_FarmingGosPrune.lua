--[[
MDFX_FarmingGosPrune — 讓 gos_farming.bin 不會長到 10 MiB 上限（server／單人）

【缺陷】
農作物系統把載入過的每一株作物永久留在 gos_farming.bin，死掉的也一樣。會把物件移出的只有
plowFadeCheck（SFarmingSystem.lua:253-262：翻土、踩爛、已收成 30 天後、所在格有載入時、
每 10 遊戲分鐘 1/20000）。存檔緩衝固定 10,485,760 byte（SliceY.java:10），
SGlobalObjectSystem.save()（SGlobalObjectSystem.java:273-298）又是先截斷檔案再序列化，
一旦超過就留下 0 byte 檔，下次開機整個農作物系統清空、時鐘歸零
（見 MDFX_FarmingClockBackup、MDFX_FarmingStallHeal）。正式服實例：20,100 個物件、9.93 MB，
其中 destroyed 70%、rotten 14%、dead 4%、harvested 2%。

另一個原版缺口：踩爛與已收成的作物用 trampledSprite（farming_vegetableconf.lua:250-251），
MOFarming.lua:126-137 只替 sprite／unhealthy／dying／dead 四組與 01_13／01_14 註冊 OnLoad，
這類作物一旦失去 GOS 登記（例如上述清空之後），重新載入也不會回來；農作選單靠 GOS 找作物
（ISFarmingMenu.lua 的 getLuaObjectOnSquare），那格從此無法移除或翻土。

【本補丁】兩部分，生命週期不同。
1. 重建（常駐）：對每種作物的 trampledSprite 與 deadSprite 註冊 MapObjects.OnLoadWithSprite，
   priority 4242（原版 5；同 priority 會取代對方，MapObjects.java:148-151，所以挑罕見值；
   高的先跑，:141-147）。格子載入時，地圖物件符合 rebuildable（農作 modData 有效、狀態是
   destroyed／harvested／dead／rotten、modData.spriteName 就是畫面上的 sprite）而且這格沒有
   luaObject，就用 fromModData 原樣重建並通知客戶端（建立順序同 loadIsoObject，
   server/Map/SGlobalObjectSystem.lua:143-147）。刻意不走 stateFromIsoObject：它把 spriteName
   換成 IsoObject 的 spriteName 欄位，而 setSpriteFromName 從不更新那個欄位
   （IsoObject.java:1979-1982），欄位還跟著 chunk 存檔（:1165、:1412），重建出來會跟原本不同。
   dead／rotten 接著照常跑原版 LoadPlant（priority 5）→ stateToIsoObject，也就是原版格子載入時
   本來就會做的同步。
2. 移出：每 10 遊戲分鐘開一輪，分攤到之後的 OnTick，每個 tick 由後往前走 300 株
   （伺服器每秒最多 10 個 tick，GameServer.java:850-851；1.2 萬株約 4 秒走完），只看 destroyed／harvested／dead／rotten：
   - 所在格有載入：地圖物件 rebuildable、畫面 sprite 在 1. 註冊過，而且用 fromModData 從它重建
     出來的內容與 luaObject 逐鍵相同 → 記下這份內容。hook 與這裡共用 rebuildable：
     只移出 hook 對這個地圖物件一定能重建出一模一樣條目的作物。
   - 所在格沒載入：上一輪走完時記下過，第一次掃到時比對一次、相同才記時間（載入期間最後的變動
     已寫回地圖物件，和快照不同就不再沿用）；之後的輪距第一次至少 30 秒真實時間、這輪移出不滿
     100 株，才再比對一次，相同就當場用原版 removeLuaObject（SGlobalObjectSystem.lua:95-102，
     會通知所有客戶端）移出——決定與移出在同一個 tick，格子只在 Lua 事件之外載入
     （ServerMap.java:500、:583-584），中間不會被載入。
     作物所在格重新載入時（1. 的 hook 碰到已有 luaObject），之前記下的與這輪記下的都作廢，要這次載入中重新驗過。
     卸載時 chunk 存檔排進背景執行緒（ServerMap.java:1013），已被存檔執行緒
     拿走、正在寫的那份不會被後來的讀取等待；等一輪加 30 秒（睡覺快轉時 10 遊戲分鐘可能不到
     1 秒）讓移出之後的重新載入一定讀到新檔。
   - 不移出：伴生作物（nbOfGrow >= 3 且有 aphidsBane／fliesBane／slugsBane）——diseaseThis
     （SFarmingSystem.lua:396-405）替鄰格活作物擋病蟲害時不看 state，死掉的洋蔥、大蒜田照樣有效；
     以 -nosave 執行時（chunk 不寫檔，重新載入會讀到舊檔）整個不移出。
   - 一輪的走法：GOS 物件清單只在尾端新增、移除時後面左移（GlobalObjectSystem.java:41、:53），
     由後往前走不會漏掉這輪開始時就在的作物；別人中途移掉游標前方的物件會讓一株被重走，
     每株每輪只評估一次（這輪排除的也算）。開輪在 OnTick（EveryTenMinutes 與它同一幀，IngameState.java:1558、:1562），
     開輪那一幀不走；輪中 EveryTenMinutes 再到，這輪走完後再開一輪。一輪出錯、沒有 instance
     或 -nosave 就放棄，已記下的全部清空（沿用更早一輪的會漏掉這輪才看到的變動）。
     原版 fromModData 只寫 KEYS 那 26 個鍵（SPlantGlobalObject.lua:779-813），只比 KEYS；
     別的 MOD 換掉它（getFilenameOfClosure 不是原版檔）才另比它多寫的鍵，每輪開頭判一次，
     輪中途換掉的（和開輪時不是同一個函式）那株一律全鍵比對；
     舊式 modData 的 objectName 是 nil 或 false 時原版改呼叫可被換掉的 getObjectName，一律全鍵比對。
     快照記下自己用哪種比對，之後照記下的比（換回原版後仍比外來函式多寫的鍵）。
   伺服器只卸載沒有任何連線 isRelevantTo 的 cell（ServerMap.java:537-560、:589-615），
   被移出的格子沒有客戶端持有；客戶端連線時才拿整份清單（SGlobalObjects.java:103-135），
   之後靠新增／移除封包，鏡像保持一致。例外：連線加進廣播表（GameServer.java:4427-4436）比打包
   清單早一段登入驗證，這段時間重建的作物清單與延後的新增封包都有，原版客戶端每株跳兩條錯誤
   （資料沒壞）；由 client/Fixes/MDFX_GosDuplicateNewGuard.lua 承接。

【與原版的差異】
- destroyed／harvested 在沒載入時原版什麼都不做（checkPlant2 :265 直接 return；plowFadeCheck 要有
  square；lowerWaterLvlAndUpDisease／changeHealth 只處理活的），移出期間沒有差別。
- dead／rotten 在沒載入時原版只有一件事：每 10 遊戲分鐘 1/5000 變成 destroyed（:267-270）。
  移出期間這個外觀轉換暫停，格子再載入後照常繼續。
- 移出之後，chunk 裡的地圖物件是唯一的來源：chunk 存檔失敗，或在這株最後一次於載入中被走到（驗過）
  到卸載之間，改過的客戶端（ObjectModDataPacket 不驗來源）或只改地圖物件的 MOD 改了那格的 modData，
  重建出來的就是那份內容。
- 會逐一走訪 SFarmingSystem 物件的其他 MOD，在沒載入的區域看到的物件變少。
- 多了移出／重建時的新增、移除封包（每株各一包、送給所有連線，包括還在登入的連線，見上）。
- 原版失去 GOS 登記的踩爛／已收成作物，格子再載入時會重新登記；dead／rotten 的孤兒改由本補丁
  原樣重建（原版會走 stateFromIsoObject）。

【生命週期】
2. 可以單獨退場（刪掉這段即可，已移出的作物在所在區域下次載入時由 1. 重建）；
1. 要等官方替 trampledSprite 註冊 OnLoad 才能退場。整個 MOD 移除時，被移出、所在區域之後
沒再載入過的踩爛／已收成作物會變回原版的孤兒（畫面上還在，農作選單找不到）。

【安裝機制】
形狀不符（缺 SFarmingSystem／SPlantGlobalObject 方法、farming_vegetableconf 表或 MapObjects）就印
NOT installed、兩部分都不裝。檔案載入時註冊一次，OnGameBoot 再註冊一次，把後載 MOD 加進
farming_vegetableconf 的作物也包進來（同 priority 重複註冊只會取代成同一個函式）；
每種作物各自 pcall，一種註冊失敗不影響其他種。移出只認註冊成功的 sprite。

【退場條件】
移出：官方讓 GOS 存檔不再受 10 MiB 緩衝限制、或不再先截斷檔案。
重建：官方替 trampledSprite 註冊 OnLoad（MOFarming.lua）。
遊戲更新後跑 `python scripts/check_vanilla_alignment.py`。
]]

if isClient() then return end

require "Farming/SFarmingSystem"
require "Farming/SPlantGlobalObject"
require "Farming/farming_vegetableconf"

local DOC = " See docs/fixes.md MDFX_FarmingGosPrune"
local PRIORITY = 4242
local CAP = 100
local SETTLE_MS = 30000
local EVICTABLE = { destroyed = true, harvested = true, dead = true, rotten = true }
-- SFarmingSystem:initSystem 的 setObjectModDataKeys（SFarmingSystem.lua:30-34）
local KEYS = {
    "state", "nbOfGrow", "typeOfSeed", "fertilizer", "mildewLvl",
    "aphidLvl", "fliesLvl", "slugsLvl", "hasWeeds", "waterLvl", "waterNeeded", "waterNeededMax",
    "lastWaterHour", "nextGrowing", "hasSeed", "hasVegetable",
    "health", "badCare", "exterior", "spriteName", "objectName", "cursed", "compost", "bonusYield", "naturalLight",
    "owner",
}

-- 1. 註冊過 hook 的 sprite 名稱
local restorable = {}
-- 2. luaObject → { snap = 重建內容, full = 比對要不要跑 pairs, since = 第一次掃到沒載入的時間 }；每輪走完整張換新
local verified = {}
-- 進行中的一輪 { cursor, keep, seen, evicted, full, fn = 開輪時判過的 fromModData }；due＝EveryTenMinutes 到了、還沒開輪（輪中再到也只是這個旗標）
local pass
local due = false

local function warnOnce(key, message)
    return MDFX_Guard.warnOnce("farmingGosPrune:" .. key, message)
end

local function shapeOk()
    local system, plant = SFarmingSystem, SPlantGlobalObject
    if type(system) ~= "table" or type(plant) ~= "table" or MapObjects == nil
        or type(farming_vegetableconf) ~= "table" or type(farming_vegetableconf.props) ~= "table" then
        return false
    end
    for _, name in ipairs({ "isValidIsoObject", "getLuaObjectOnSquare", "getIsoObjectOnSquare", "newLuaObject",
        "newLuaObjectOnClient", "removeLuaObject", "getLuaObjectCount", "getLuaObjectByIndex" }) do
        if type(system[name]) ~= "function" then return false end
    end
    return type(plant.fromModData) == "function"
end

-- MapObjects 找 callback 用的名字（MapObjects.java:195）
local function renderedName(isoObject)
    local sprite = isoObject:getSprite()
    if not sprite then return nil end
    local name = sprite:getName()
    if name == nil then name = isoObject:getSpriteName() end
    return name
end

-- hook 會不會重建這個地圖物件；會的話回傳它的 modData 與畫面 sprite 名稱
local function rebuildable(system, isoObject)
    if not system:isValidIsoObject(isoObject) then return nil end
    local modData = isoObject:getModData()
    if not EVICTABLE[modData.state] then return nil end
    local name = renderedName(isoObject)
    if name == nil or modData.spriteName ~= name then return nil end
    return modData, name
end

-- ── 1. 重建 ─────────────────────────────────────────────

local function where(x, y, z)
    return tostring(x) .. "," .. tostring(y) .. "," .. tostring(z)
end

local function onLoad(isoObject)
    local ok, err = pcall(function()
        local system = SFarmingSystem.instance
        if not system then return end
        local square = isoObject:getSquare()
        if not square then return end
        local existing = system:getLuaObjectOnSquare(square)
        if existing then
            -- 重新載入：之前的驗證與計時都不算，要這次載入中重新驗過才能再開始計時（這輪記下的也丟掉）
            verified[existing] = nil
            if pass then pass.keep[existing] = nil end
            return
        end
        local modData = rebuildable(system, isoObject)
        if not modData then return end
        local x, y, z = square:getX(), square:getY(), square:getZ()
        local globalObject = system.system:newObject(x, y, z)
        local built, buildErr = pcall(function()
            local luaObject = system:newLuaObject(globalObject)
            luaObject:fromModData(modData)
            system:newLuaObjectOnClient(luaObject)
        end)
        if not built then
            pcall(function() system.system:removeObject(globalObject) end)
            error(buildErr, 0)
        end
        warnOnce("rebuilt", "MDFX_FarmingGosPrune: rebuilt the " .. tostring(modData.state) .. " crop at " .. where(x, y, z)
            .. " from its map object as its area loaded. Further rebuilds not logged this session." .. DOC)
    end)
    if not ok then
        warnOnce("rebuildError", "MDFX_FarmingGosPrune could not rebuild a crop from its map object (" .. tostring(err)
            .. "); left it as vanilla does. Further occurrences suppressed this session." .. DOC)
    end
end

local function register()
    if not shapeOk() then
        warnOnce("shape", "MDFX_FarmingGosPrune NOT installed: vanilla SFarmingSystem / SPlantGlobalObject / farming_vegetableconf / MapObjects shape changed; re-check docs/fixes.md")
        return
    end
    local conf = farming_vegetableconf
    for seed in pairs(conf.props) do
        for _, kind in ipairs({ "trampledSprite", "deadSprite" }) do
            local names = type(conf[kind]) == "table" and conf[kind][seed]
            if type(names) == "table" and #names > 0 then
                local ok, err = pcall(MapObjects.OnLoadWithSprite, names, onLoad, PRIORITY)
                if ok then
                    for i = 1, #names do restorable[names[i]] = true end
                else
                    warnOnce("register:" .. tostring(seed) .. ":" .. kind, "MDFX_FarmingGosPrune could not register "
                        .. kind .. " of " .. tostring(seed) .. " (" .. tostring(err) .. "); those crops stay in gos_farming.bin." .. DOC)
                end
            end
        end
    end
end

-- ── 2. 移出 ─────────────────────────────────────────────

local BATCH = 300
local VANILLA_FILE = "media/lua/server/farming/splantglobalobject.lua"

-- 回傳重建內容，與呼叫的 fromModData 是不是開輪時判過的那個
local function rebuild(modData)
    local t, fn = {}, SPlantGlobalObject.fromModData
    fn(t, modData)
    return t, fn == pass.fn
end

-- fromModData 不是原版檔（查不到來源也算）：可能多寫 KEYS 以外的鍵，比對要跑第二段
local function foreign()
    local ok, file = pcall(getFilenameOfClosure, SPlantGlobalObject.fromModData)
    if not ok or type(file) ~= "string" then return true end
    local path = string.lower(string.gsub(file, "\\", "/"))
    return string.sub(path, -#VANILLA_FILE) ~= VANILLA_FILE or string.find(path, "/mods/", 1, true) ~= nil
end

local function same(luaObject, t, full)
    for i = 1, #KEYS do
        local k = KEYS[i]
        if luaObject[k] ~= t[k] then return false end
    end
    if full then
        for k, v in pairs(t) do
            if luaObject[k] ~= v then return false end
        end
    end
    return true
end

-- diseaseThis 對鄰格伴生作物只看 nbOfGrow >= 3 與 *Bane（SFarmingSystem.lua:396-405），不看 state
local function companion(luaObject)
    if (tonumber(luaObject.nbOfGrow) or 0) < 3 then return false end
    local prop = farming_vegetableconf.props[luaObject.typeOfSeed]
    if not prop then return false end
    return (prop.aphidsBane or prop.fliesBane or prop.slugsBane) and true or false
end

-- 驗過回傳快照與它要用的比對方式（full）；之後照記下的比，不看那輪的 pass.full
local function verify(system, luaObject, square, full)
    local isoObject = system:getIsoObjectOnSquare(square)
    if not isoObject then return nil end
    local modData, name = rebuildable(system, isoObject)
    if not modData or not restorable[name] then return nil end
    -- 舊式 modData 的 objectName 是 nil／false：原版改呼叫可被換掉的 getObjectName（SPlantGlobalObject.lua:810-812），它寫了什麼看不出來
    full = full or not modData.objectName
    local ok, t, judged = pcall(rebuild, modData)
    -- 輪中途換掉了 fromModData：開輪時的判斷不算數
    full = full or not judged
    if ok and same(luaObject, t, full) then return t, full end
    return nil
end

local function visit(system, cell, now, luaObject)
    if not luaObject then return end
    -- 別人中途移掉游標前方的物件會讓索引重走一株；每株每輪只評估一次（這輪排除的也算）
    if pass.seen[luaObject] then return end
    pass.seen[luaObject] = true
    if not EVICTABLE[luaObject.state] or companion(luaObject) then return end
    local square = cell:getGridSquare(luaObject.x, luaObject.y, luaObject.z)
    if square then
        local snap, full = verify(system, luaObject, square, pass.full)
        if snap then pass.keep[luaObject] = { snap = snap, full = full } end
        return
    end
    local entry = verified[luaObject]
    if not entry then return end
    if entry.since and now - entry.since >= SETTLE_MS and pass.evicted < CAP then
        -- 決定與移出在同一個 tick，中間不會有格子載入
        if same(luaObject, entry.snap, entry.full) then
            system:removeLuaObject(luaObject)
            pass.evicted = pass.evicted + 1
        end
    else
        if not entry.since then
            -- 第一次看到沒載入就比一次：載入期間最後的變動已寫回地圖物件，和快照不同就不再沿用；之後只在要移出時才比
            if not same(luaObject, entry.snap, entry.full) then return end
            entry.since = now
        end
        pass.keep[luaObject] = entry
    end
end

-- 一輪沒走完就不留任何條目：沿用更早一輪的會漏掉這輪才看到的變動
local function abandon()
    pass, due, verified = nil, false, {}
end

local function step()
    local system = SFarmingSystem.instance
    if not system or getCore():isNoSave() then return abandon() end
    if not pass then
        due = false
        pass = { cursor = system:getLuaObjectCount(), keep = {}, seen = {}, evicted = 0,
            full = foreign(), fn = SPlantGlobalObject.fromModData }
        return -- EveryTenMinutes 與 OnTick 同一幀（IngameState.java:1558、:1562）：開輪這一幀不走
    end
    local cell, now = getCell(), getTimestampMs()
    -- 由後往前：自己移出只讓走過的元素左移；新增一律接在尾端（GlobalObjectSystem.java:41、:53）
    local i = math.min(pass.cursor, system:getLuaObjectCount())
    for _ = 1, BATCH do
        if i < 1 then break end
        local luaObject = system:getLuaObjectByIndex(i)
        i = i - 1
        visit(system, cell, now, luaObject)
    end
    pass.cursor = i
    if i >= 1 then return end
    verified = pass.keep
    local evicted = pass.evicted
    pass = nil
    if evicted > 0 then
        warnOnce("evicted", "MDFX_FarmingGosPrune: moved " .. evicted .. " dead/rotten/destroyed/harvested crops in unloaded areas out of gos_farming.bin ("
            .. system:getLuaObjectCount() .. " objects left); they are rebuilt from their map objects when the area loads."
            .. " Further evictions not logged this session." .. DOC)
    end
end

local function onTick()
    if not pass and not due then return end
    local ok, err = pcall(step)
    if not ok then
        abandon()
        warnOnce("sweepError", "MDFX_FarmingGosPrune sweep failed (" .. tostring(err)
            .. "); nothing more was moved this time. Further occurrences suppressed this session." .. DOC)
    end
end

register()
Events.EveryTenMinutes.Add(function() due = true end)
Events.OnTick.Add(onTick)
if Events and Events.OnGameBoot then
    Events.OnGameBoot.Add(register)
end
