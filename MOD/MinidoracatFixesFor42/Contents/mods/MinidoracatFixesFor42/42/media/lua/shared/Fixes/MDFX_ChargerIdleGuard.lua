--[[
MDFX_ChargerIdleGuard — 沒在充電的汽車電池充電器讓附近發電機每幀重算用電清單（三端）

【缺陷】（行號為 42.21.0 反編譯快照）
IsoCarBatteryCharger.addToWorld（IsoCarBatteryCharger.java:111-114）把每台充電器登記進 IsoCell 的每幀
更新清單；IsoCell.ProcessIsoObject（IsoCell.java:2194-2213）每幀對清單逐一 update()，伺服器與客戶端都跑。
update()（:122-156）在「沒放電池」或「放了電池但沒電」時每幀呼叫 setActivated(false)，而
setActivated（:433-436）不比對狀態就呼叫 IsoGenerator.updateGenerator（IsoGenerator.java:693-705），
把半徑內每台發電機標成 updateSurrounding。下一幀發電機 update（:264-267）或客戶端
LightingJNI.checkLights → updateSurroundingNow（LightingJNI.java:253、IsoGenerator.java:683-691）就整份重跑
setSurroundingElectricity（:274-331：逐件翻譯名稱、現場編譯 regex、DecimalFormat）。
同類的 ClothingWasherLogic.setActivated（ClothingWasherLogic.java:287-291）有比對狀態，充電器沒有。

【後果】
沒在充電的充電器旁只要有發電機，伺服器與每個附近的客戶端就每幀重算一次用電清單。正式服某基地
（10 台充電器、10 台發電機）客戶端 60 秒內 3 萬次 updateGenerator、2.3 萬次 setSurroundingElectricity，
約佔客戶端記憶體配置的七成。

【本補丁】
沒啟動（isActivated() 為 false）的充電器每幀只做三件事：lastUpdate＝-1、setActivated(false)（沒電池或沒電時）、
stopChargingSound()（:129-141）。前一件與最後一件第一次之後就是定值，只剩那次多餘的
updateGenerator。所以把它移出每幀更新清單（IsoCell.addToProcessIsoObjectRemove，下一次
ProcessIsoObject 開頭才真的拿掉：:2195-2199、:2270-2276），一啟動就放回（addToProcessIsoObject，:2261-2268）。

1. 發現充電器（事件觸發、只讀新增的尾段）：
   - LoadChunk（IsoChunk.java:3969；同一個 doLoadGridsquare 先對每個物件 addToWorld，:3807）、
     包 ISPlaceCarBatteryChargerAction.complete（伺服器／單人放置，AddSpecialObject → addToWorld）：
     讀 getProcessIsoObjects() 新增的尾段。addToProcessIsoObject 只在尾端 add、ProcessIsoObject 的
     removeAll 保持其餘元素的相對順序，所以記住上次讀到的最後一個元素（錨點），從尾端往前讀到它為止；
     找不到錨點（已被移除）就等於整份讀一次。第一個 OnTick 也讀一次（開局整份）。
   - OnObjectAdded（客戶端收到 AddItemToMapPacket，AddItemToMapPacket.java:66、:94）：直接看那個物件。
   讀漏的充電器照原版跑（不會被移出）。
2. 只能檢查的狀態轉換只看已知的充電器：
   - 已移出的每 tick 檢查：isActivated() 就放回（MP 客戶端上別人打開的充電器只經
     syncIsoObjectReceive 改 activated，IsoCarBatteryCharger.java:380-393，沒有 Lua 事件）。
   - 仍在清單上的每 CHECK_EVERY tick 檢查一次，連續 IDLE_CHECKS 次沒啟動才移出（停電、拿掉電池時
     引擎在 update() 裡自己關掉，同樣沒有事件；晚幾 tick 移出不影響行為）。
   - 包 ISActivateCarBatteryChargerAction.complete：原版跑完立即放回，伺服器／單人零延遲。
   不在世界上的（chunk 卸載後 square 的 chunk 是 null、物件仍留在 square 上：IsoChunk.java:3248-3260；
   拿走則 getObjectIndex() 為 -1）丟掉、不放回。錨點不在世界上時先讀一次尾段再換錨點。
3. 移出前一律重查 isActivated()；自己的程式出錯就停用並把移出的全部放回（照原版跑）。

【已知限制】
- 發電機用電清單不再被沒在充電的充電器每幀刷新，改由其他觸發（家電開關、物件增減、chunk 載入）
  刷新，與附近沒有充電器的原版基地相同。
- MP 客戶端別人打開的充電器在收到同步的那一幀之後才放回，充電從下一幀起算（原版從同一幀）。
- Core.ResetLua 會丟掉追蹤；已移出的充電器要等 chunk 重新載入才回到清單。遊戲中不會 ResetLua。

【退場條件】
官方讓 IsoCarBatteryCharger.setActivated 比對狀態（或 update 不再對沒啟動的充電器呼叫 setActivated）。
遊戲更新後跑 `python scripts/check_vanilla_alignment.py`（本修復登記 Java 與 Lua 指紋）。
]]

if MDFX_ChargerIdleGuard then return end

local NAME = "MDFX_ChargerIdleGuard"
local CHECK_EVERY = 10 -- tick；仍在清單上的充電器隔幾 tick 檢查一次
local IDLE_CHECKS = 2  -- 連續幾次檢查都沒啟動才移出（第一次之後原版已停掉音效、lastUpdate 歸 -1）

local warned = {}
local function warnOnce(key, message)
    if warned[key] then return end
    warned[key] = true
    print("[MinidoracatFixes] " .. NAME .. " " .. message .. " See docs/fixes.md " .. NAME)
end

local Activate, Place = ISActivateCarBatteryChargerAction, ISPlaceCarBatteryChargerAction
if not (Events and Events.OnTick and Events.OnTick.Add and Events.LoadChunk and Events.LoadChunk.Add
        and Events.OnObjectAdded and Events.OnObjectAdded.Add and getCell and instanceof and IsoCarBatteryCharger
        and type(Activate) == "table" and type(Activate.complete) == "function"
        and type(Place) == "table" and type(Place.complete) == "function") then
    warnOnce("shape", "NOT installed: vanilla car battery charger shape changed; re-check docs/fixes.md.")
    return
end

-- ins：在每幀更新清單上的已知充電器；outs：本補丁移出的；idle：連續看到沒啟動的檢查次數
local ins, outs, idle, known = {}, {}, {}, {}
local anchor = nil
local frame = 0
local started = false
local disabled = false
local cellChecked = false
local chargerChecked = false

local G = { removed = 0, restored = 0, dropped = 0, tailScans = 0, fullScans = 0, scanned = 0 }
G.tracked = function() return #ins + #outs end
G.out = function() return #outs end
MDFX_ChargerIdleGuard = G

local function cell()
    local c = getCell()
    if c ~= nil and not cellChecked then
        if type(c.getProcessIsoObjects) ~= "function" or type(c.addToProcessIsoObject) ~= "function"
                or type(c.addToProcessIsoObjectRemove) ~= "function" then
            error("shape: IsoCell")
        end
        cellChecked = true
    end
    return c
end

local function inWorld(o)
    local sq = o:getSquare()
    return sq ~= nil and sq:getChunk() ~= nil and o:getObjectIndex() ~= -1
end

-- 與最後一個交換後拿掉；分兩行寫：i == #list 時多重賦值的先後未定義
local function take(list, i)
    local o, n = list[i], #list
    list[i] = list[n]
    list[n] = nil
    return o
end

local function drop(list, i)
    local o = take(list, i)
    known[o], idle[o] = nil, nil
    G.dropped = G.dropped + 1
end

local function restore(c, i)
    local o = take(outs, i)
    c:addToProcessIsoObject(o)
    ins[#ins + 1], idle[o] = o, 0
    G.restored = G.restored + 1
end

local function track(o)
    if known[o] then return end
    if not chargerChecked then
        if type(o.isActivated) ~= "function" or type(o.getObjectIndex) ~= "function" or type(o.getSquare) ~= "function" then
            error("shape: IsoCarBatteryCharger")
        end
        chargerChecked = true
    end
    known[o] = true
    ins[#ins + 1], idle[o] = o, 0
end

local function consider(o)
    if o ~= nil and instanceof(o, "IsoCarBatteryCharger") then track(o) end
end

-- 從尾端往前讀到錨點為止；找不到錨點就讀完整份
local function scan(c)
    if c == nil then return end
    local list = c:getProcessIsoObjects()
    local n = list:size()
    local i = n - 1
    while i >= 0 do
        local o = list:get(i)
        if anchor ~= nil and o == anchor then break end
        consider(o)
        i = i - 1
    end
    if i < 0 and n > 0 then G.fullScans = G.fullScans + 1 else G.tailScans = G.tailScans + 1 end
    G.scanned = G.scanned + (n - 1 - i)
    anchor = n > 0 and list:get(n - 1) or nil
end

-- 要移出的正好是錨點（剛放置或剛放回的充電器常在最後）：先讀尾段，它仍是最後一個就改用前一個，免得下次整份讀
local function unanchor(c, o)
    scan(c)
    if anchor ~= o then return end
    local list = c:getProcessIsoObjects()
    local n = list:size()
    anchor = n > 1 and list:get(n - 2) or nil
end

local function tick()
    local c = cell()
    if c == nil then return end
    if not started then
        started = true
        scan(c)
    end
    for i = #outs, 1, -1 do
        local o = outs[i]
        if not inWorld(o) then
            drop(outs, i)
        elseif o:isActivated() then
            restore(c, i)
        end
    end
    frame = frame + 1
    if frame < CHECK_EVERY then return end
    frame = 0
    if anchor ~= nil and not inWorld(anchor) then scan(c) end
    for i = #ins, 1, -1 do
        local o = ins[i]
        if not inWorld(o) then
            drop(ins, i)
        elseif o:isActivated() then
            idle[o] = 0
        elseif idle[o] + 1 < IDLE_CHECKS then
            idle[o] = idle[o] + 1
        else
            if o == anchor then unanchor(c, o) end
            c:addToProcessIsoObjectRemove(o)
            outs[#outs + 1], idle[o] = take(ins, i), nil
            G.removed = G.removed + 1
            warnOnce("removed", "took an idle car battery charger at " .. o:getX() .. "," .. o:getY() .. "," .. o:getZ()
                .. " off the per-frame update list (vanilla re-scans nearby generators every frame for it);"
                .. " it goes back the moment it is switched on. Further ones not logged this session.")
        end
    end
end
G.tick = tick
G.scan = function() scan(cell()) end
G.anchor = function() return anchor end

-- 停用時把移出的全部放回，之後完全照原版
local function disable(err)
    disabled = true
    local c = getCell()
    for i = #outs, 1, -1 do
        local o = outs[i]
        pcall(function() if c ~= nil and inWorld(o) then c:addToProcessIsoObject(o) end end)
        outs[i] = nil
    end
    local s = tostring(err)
    local k = s:find("shape: ", 1, true)
    if k then
        warnOnce("shape", "NOT installed: vanilla " .. s:sub(k + 7) .. " shape changed; re-check docs/fixes.md.")
    else
        warnOnce("error", "disabled for this session after an unexpected error: " .. s
            .. "; every charger is back on the vanilla update list.")
    end
end

local function guarded(fn, a)
    if disabled then return end
    local ok, err = pcall(fn, a)
    if not ok then disable(err) end
end

local function afterActivate(action)
    local o = action.charger
    if o == nil then return end
    if not known[o] then
        if instanceof(o, "IsoCarBatteryCharger") and inWorld(o) then track(o) end
        return
    end
    if not o:isActivated() then return end
    for i = 1, #outs do
        if outs[i] == o then
            restore(cell(), i)
            return
        end
    end
    idle[o] = 0
end

-- 同一個 Lua 環境重複載入時，檔頭的全域判斷讓這裡只包一次；Core.ResetLua 重建類別表與全域後重新包
local function wrapAfter(cls, after)
    local original = cls.complete
    cls.complete = function(self, ...)
        local r = original(self, ...)
        guarded(after, self)
        return r
    end
end

wrapAfter(Activate, afterActivate)
wrapAfter(Place, G.scan)
Events.LoadChunk.Add(function() guarded(G.scan) end)
Events.OnObjectAdded.Add(function(o) guarded(consider, o) end)
Events.OnTick.Add(function() guarded(tick) end)
