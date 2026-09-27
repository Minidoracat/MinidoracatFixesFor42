--[[
MDFX_FarmingSyncDedupe — 原版農作物同步改成「有變才送」（server 端）

【缺陷】
原版伺服器在兩個時機把作物的名稱、sprite、整份 modData 無條件重送給範圍內所有
連線（GameServer.java:2887-2890、:2899-2905 → INetworkPacket.sendToRelative
:173-182），值沒變也送：

1. 載入時。server/Farming/SPlantGlobalObject.lua 的 stateFromIsoObject（:43-56）與
   stateToIsoObject（:58-87）在 isServer() 時固定送三包（:51-55、:82-86：
   sendObjectChange NAME、SPRITE、transmitModData）。它們由
   SGlobalObjectSystem:loadIsoObject（server/Map/SGlobalObjectSystem.lua:133-149）
   呼叫；MOFarming.lua:126-137 把枯作物（vegetation_farming_01_13/14）與各作物
   sprite 掛在 MapObjects.OnLoadWithSprite，所以伺服器每載入一個 cell
   （ServerMap.java:950-956 RecalcAll2 → IsoChunk.java:3825 MapObjects.loadGridSquare），
   格內每株作物送三包。這時沒有任何客戶端持有這個 chunk：伺服器只卸載「沒有任何
   連線 isRelevantTo」的 cell（ServerMap.java:539、:589-615），客戶端的 chunk 要等
   伺服器端 loaded 之後才從記憶體現場序列化（PlayerDownloadServer.java:158-164、:234）。
   三包都被 ObjectModDataPacket.parse 以 object is null 丟掉（:50-56），客戶端之後
   拿到的 chunk 本來就含載入後的名稱、sprite、modData。stateFromIsoObject 甚至不寫
   iso object（只讀），那三包只是 :48-49 註解說的「MapObjects 載入程式可能改過」保險。
2. 定期。SFarmingSystem:EveryTenMinutes（server/Farming/SFarmingSystem.lua:87-128）
   每 10 遊戲分鐘對每株非 destroyed／harvested 作物 checkPlant2（:264-290）→
   saveData（SPlantGlobalObject.lua:771-777）→ 無條件 transmitModData（:775）。
   翻土、枯死、腐爛、地圖內建沒被踩過的枯作物（MOFarming.lua:43 寫的是 "destroy"，
   isAlive 把它當活的）值都不變，照樣每次整份重送。

【後果】
走過農地時每株作物連送三包，之後每 10 遊戲分鐘再整份重送；一株作物的 modData
約 0.5–0.8 KB（22–26 個鍵）。正式服 60 秒出向抓包裡作物 modData 佔出向 3.4%，
幾乎全是地圖內建枯作物的載入時重送。

【本補丁】
只在 isServer() 安裝，而且只包原版自己的函式：getFilenameOfClosure
（LuaManager.java:7321-7323）要指向原版的 SPlantGlobalObject.lua、路徑不含
/mods/（與 LuaClosure.java:170 判斷 Vanilla／MOD 的方式相同）。別的 MOD 已經覆寫
的 method 不碰，印一行 NOT installed。三個 method 各自判斷、各自安裝。

- stateFromIsoObject／stateToIsoObject：原函式本體照跑，只是給它一張自己的全域表，
  讓本體裡的 isServer() 回 false、那三包不送（setfenv 只改這一個 closure 的全域
  查找：BaseLib.java:152-180、KahluaThread.java:272-275；它呼叫的其他函式照常）。
  wrapper 比對呼叫前後再逐項補送：名稱變了送 NAME、sprite 換了送 SPRITE、modData
  內容變了送 transmitModData，順序同原版。sprite 比的是 getSprite() 物件本身：
  setSpriteFromName 不更新 spriteName 欄位（IsoObject.java:1979-1982、:2235-2237），
  用 getSpriteName() 比會漏掉 sprite 變化。
- saveData：先做原版的 toModData（:774），「寫入前後相同」而且「和這一格上次實際
  送出的內容相同」才不送；其餘交給原函式照原版送（再 toModData 一次，同值）。
  只比寫入前後不夠：setSpriteName／setObjectName 先把整份 modData 寫進 iso object
  卻不送（:118、:103），播種（:732-733）、生長（SFarmingSystem.lua:288-289）、
  枯死與踩爛（→ deadPlant :765）都是這樣接著 saveData；只比前後會漏掉這些真正
  有變的同步。寫入前後也要比：客戶端送來的 ObjectModData 會先改掉 server 的 iso
  modData 再轉給其他人（ObjectModDataPacket.java:50-96），toModData 蓋回原值後
  只有「寫入前」看得到差異。

比對的是內容，不是 table identity：照 KahluaTableImpl.save（:210-231、:379-401）
實際會上線的型別（鍵 string／number，值 string／number／boolean）排序後組成字串。
遇到巢狀 table，或比對本身失敗，就當「看不出來」，照原版送。

【零行為差異】
有變一定送，客戶端拿到的名稱、sprite、modData 與原版相同；少送的只有內容與客戶端
已持有的完全相同的那幾包。單人／客戶端不安裝（單人的 transmitModData 本來就不送，
IsoObject.java:4805-4815）。transmitModData 順帶的 flagForHotSave（:4813）在 dedicated
server 不處理（ServerMap.java:1065），少呼叫不影響存檔。

【取捨】
- 不做陷阱、營火。陷阱（STrapGlobalObject.lua:30-98）載入時同款三包，但數量少、
  modData 帶巢狀 zones；點燃的營火每遊戲分鐘 fuelAmt 都在變
  （SCampfireSystem.lua:135-145 → SCampfireGlobalObject.lua:262-263），「有變才送」
  省不到，要省只能降頻，那會讓客戶端看到舊的燃料量。

【安裝機制】
MDFX_Guard.onServer：立即安裝一次，OnGameBoot 再查一次。本 session 裝過的 method
記在 installed，之後不論現任是不是我們的都不再動（後載 MOD 包我們或換掉我們，
都不接回去）。Core.ResetLua 重載時 vanilla 重建 class、本檔重跑，重新安裝。

【退場條件】
官方把這三處改成比對後才送（或拿掉載入時的三包、saveData 的無條件送）。
遊戲更新後跑 `python scripts/check_vanilla_alignment.py`：:51-55、:82-86、:771-777
的形狀任一改變都會 CHANGED。
]]

local VANILLA_FILE = "/media/lua/server/farming/splantglobalobject.lua"
local DOC = " See docs/fixes.md MDFX_FarmingSyncDedupe"

-- 座標 "x,y,z" → saveData 上次實際送出的 modData 指紋
-- ponytail: 本 session 不清，上限＝同步過的作物格數（每格一條字串）；記憶體真的吃緊再改成 chunk 卸載時清
local sent = {}
local installed = {}

local function warnOnce(key, message)
    return MDFX_Guard.warnOnce("farmingSyncDedupe:" .. key, message)
end

local function positionOf(luaObject)
    local x, y, z = luaObject.x, luaObject.y, luaObject.z
    if type(x) ~= "number" or type(y) ~= "number" or type(z) ~= "number" then return nil end
    return x .. "," .. y .. "," .. z
end

-- 值編成自帶邊界的字串（字串帶長度），整份串起來不會有歧義；不會上線的型別回 nil
local function encode(v)
    local t = type(v)
    if t == "string" then return "s" .. #v .. ":" .. v end
    if t == "number" then return "n" .. tostring(v) .. ";" end
    if t == "boolean" then return v and "T" or "F" end
    return nil
end

-- 插入排序：verify_mod.py 禁 table.sort，一份作物 modData 約 26 鍵
local function fingerprint(md)
    local entries = {}
    for k, v in pairs(md) do
        if type(v) == "table" then return nil end
        local ek = type(k) ~= "boolean" and encode(k) or nil
        local ev = encode(v)
        if ek and ev then
            local e = ek .. ev
            local i = #entries
            while i > 0 and entries[i] > e do
                entries[i + 1] = entries[i]
                i = i - 1
            end
            entries[i + 1] = e
        end
    end
    return table.concat(entries)
end

local function snapshot(md)
    local ok, fp = pcall(fingerprint, md)
    if ok then return fp end
    warnOnce("fingerprint", "MDFX_FarmingSyncDedupe could not compare a crop's modData (" .. tostring(fp)
        .. "); sent it as vanilla does. Further occurrences suppressed this session." .. DOC)
    return nil
end

local function noteSkip(kind, luaObject, what)
    warnOnce("skip:" .. kind, "MDFX_FarmingSyncDedupe: unchanged " .. what .. " at " .. tostring(positionOf(luaObject))
        .. " not re-sent. Further skips not logged this session." .. DOC)
end

-- stateFromIsoObject（:43-56）／stateToIsoObject（:58-87）
local function wrapLoad(original)
    local env = getfenv(original)
    setfenv(original, setmetatable({ isServer = function() return false end }, { __index = env, __newindex = env }))
    return function(self, isoObject)
        if not isoObject then return original(self, isoObject) end
        local name, sprite = isoObject:getName(), isoObject:getSprite()
        local before = snapshot(isoObject:getModData())
        original(self, isoObject)
        local sentAny = false
        if isoObject:getName() ~= name then
            isoObject:sendObjectChange(IsoObjectChange.NAME)
            sentAny = true
        end
        if isoObject:getSprite() ~= sprite then
            isoObject:sendObjectChange(IsoObjectChange.SPRITE)
            sentAny = true
        end
        local after = snapshot(isoObject:getModData())
        if after == nil or after ~= before then
            isoObject:transmitModData()
            sentAny = true
        end
        if not sentAny then noteSkip("load", self, "crop load sync (name/sprite/modData)") end
    end
end

-- saveData（:771-777）
local function wrapSave(original)
    return function(self)
        local isoObject = self:getIsoObject()
        if not isoObject then return original(self) end
        local md = isoObject:getModData()
        local before = snapshot(md)
        self:toModData(md)
        local after = snapshot(md)
        local key = positionOf(self)
        if key and after and before == after and sent[key] == after then
            noteSkip("save", self, "crop modData resend")
            return
        end
        if key then sent[key] = after end
        return original(self)
    end
end

local TARGETS = {
    { "stateFromIsoObject", wrapLoad },
    { "stateToIsoObject", wrapLoad },
    { "saveData", wrapSave },
}

local function sourceOf(fn)
    local ok, file = pcall(getFilenameOfClosure, fn)
    if not ok or type(file) ~= "string" then return false, tostring(file) end
    local path = string.lower(string.gsub(file, "\\", "/"))
    return string.sub(path, -#VANILLA_FILE) == VANILLA_FILE and string.find(path, "/mods/", 1, true) == nil, file
end

MDFX_Guard.onServer(function()
    local cls = SPlantGlobalObject
    if type(cls) ~= "table" or type(getFilenameOfClosure) ~= "function"
        or type(getfenv) ~= "function" or type(setfenv) ~= "function" then
        warnOnce("shape", "MDFX_FarmingSyncDedupe NOT installed: vanilla SPlantGlobalObject shape changed; re-check docs/fixes.md")
        return
    end
    local count = 0
    for i = 1, #TARGETS do
        local method, wrap = TARGETS[i][1], TARGETS[i][2]
        local current = cls[method]
        if not installed[method] then
            if type(current) ~= "function" then
                warnOnce("shape:" .. method, "MDFX_FarmingSyncDedupe NOT installed for SPlantGlobalObject." .. method
                    .. ": vanilla shape changed; re-check docs/fixes.md")
            else
                local vanilla, file = sourceOf(current)
                if not vanilla then
                    warnOnce("foreign:" .. method, "MDFX_FarmingSyncDedupe NOT installed for SPlantGlobalObject." .. method
                        .. ": it comes from " .. file .. ", not vanilla; leaving it alone." .. DOC)
                else
                    local ok, wrapper = pcall(wrap, current)
                    if ok then
                        cls[method] = wrapper
                        installed[method] = wrapper
                    else
                        warnOnce("wrap:" .. method, "MDFX_FarmingSyncDedupe NOT installed for SPlantGlobalObject." .. method
                            .. ": " .. tostring(wrapper) .. DOC)
                    end
                end
            end
        end
        if installed[method] then count = count + 1 end
    end
    if count == #TARGETS then
        warnOnce("installed", "MDFX_FarmingSyncDedupe installed: crop name/sprite/modData re-sent only when changed"
            .. " (SPlantGlobalObject stateFromIsoObject/stateToIsoObject/saveData)." .. DOC)
    end
end)
