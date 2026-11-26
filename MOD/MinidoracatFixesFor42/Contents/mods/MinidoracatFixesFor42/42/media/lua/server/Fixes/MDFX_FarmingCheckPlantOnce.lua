--[[
MDFX_FarmingCheckPlantOnce — 農作每 10 遊戲分鐘的全表檢查，每株只向引擎取一次物件（server／單人）

【缺陷】
SFarmingSystem:checkPlant（server/Farming/SFarmingSystem.lua:236-251）每 10 遊戲分鐘
（:127 EveryTenMinutes）把全部作物走兩次：正向跑 checkPlant2、反向跑 plowFadeCheck。
兩個迴圈的每一輪都呼叫兩次 self:getLuaObjectByIndex(i)（:240-241、:246-247）：先判空、再取值，
兩次之間沒有別的程式，結果一定相同。getLuaObjectByIndex（server/Map/SGlobalObjectSystem.lua:44-46）
每次都跨到 Java：system:getObjectByIndex(index-1):getModData()。

【後果】
每株作物每 10 遊戲分鐘向引擎取 4 次，其中 2 次是多的；不論有沒有載入、是不是已踩爛
（destroyed 也在表上，checkPlant2 開頭才 return）。作物上萬株的伺服器，這段全表檢查
每次連續佔住主執行緒，多出來的那一半取物件是其中一部分。

【本補丁】
三項都成立才換成每輪只取一次的版本，否則不碰、印一行 NOT installed：
- 現任 checkPlant 來自原版 SFarmingSystem.lua（getFilenameOfClosure，路徑不含 /mods/）；
- 用假的 self 實際跑一次現任 checkPlant，呼叫序列和原版 :236-251 一模一樣（正向、反向、每輪取兩次、
  取到空值中止）：同檔的別支函式、官方改過的新本體都不會通過，不會被照抄版蓋掉；
- 實際分派到的 getLuaObjectByIndex 來自原版 SGlobalObjectSystem.lua（Java 取值，兩次結果必定相同）。
執行時 self 分派到的 getLuaObjectByIndex 不再是安裝時那支（別的 MOD 後來換掉），就整輪改跑原版 checkPlant。
照抄版其餘同原版：
- 迴圈次數照原版在開頭取一次 getLuaObjectCount()；
- 正向走完 checkPlant2，再反向走 plowFadeCheck，兩個迴圈不合併（checkPlant2 可能改變物件數）；
- 取到空值就中止那個迴圈；plowFadeCheck 移除物件的時機不變（反向走，移除不影響還沒走到的）；
- 一律經 self: 呼叫 getLuaObjectByIndex／checkPlant2／plowFadeCheck，別的 MOD 包的這幾個 method 照樣生效。

【零行為差異】
每株作物被檢查的順序、次數、時間點與原版相同；只少了每輪第二次、結果相同的取物件。
原函式內的錯誤（checkPlant2、plowFadeCheck、取物件越界時對 nil 取 modData）照樣外洩。

【安裝機制】
載檔時安裝一次：marker 存我們的函式；Core.ResetLua 重建 SFarmingSystem 時 marker 消失、本檔重跑重新安裝。
後載 MOD 包我們照常；換掉我們就不接回去。

【退場條件】
官方把 checkPlant 改成每輪只取一次（或改了這兩個迴圈的形狀）：試跑的呼叫序列對不上就自動不裝。
遊戲更新後跑 `python scripts/check_vanilla_alignment.py`：:236-251 的本體一改就 CHANGED；
只改了試跑看不出來的地方（例如迴圈內多了全域函式呼叫、依作物數量分支而只動區域變數）時，要人工確認照抄的版本仍與新原版相同。
]]

if isClient() then return end

require "Farming/SFarmingSystem"

local MARKER = "MDFX_checkPlantOnce"
local VANILLA_FILE = "/media/lua/server/farming/sfarmingsystem.lua"
local GETTER_FILE = "/media/lua/server/map/sglobalobjectsystem.lua"
local DOC = " See docs/fixes.md MDFX_FarmingCheckPlantOnce"

local function warnOnce(key, message)
    return MDFX_Guard.warnOnce("farmingCheckPlantOnce:" .. key, message)
end

-- 原版 :236-251，每輪只取一次；getter 被換掉時整輪交回原版
local function makeCheckPlant(original, getter)
    return function(self)
        if self.getLuaObjectByIndex ~= getter then return original(self) end
        for i = 1, self:getLuaObjectCount() do
            local luaObject = self:getLuaObjectByIndex(i)
            if not luaObject then break end
            self:checkPlant2(luaObject)
        end
        local i = self:getLuaObjectCount()
        while i > 0 do
            local luaObject = self:getLuaObjectByIndex(i)
            if not luaObject then break end
            self:plowFadeCheck(luaObject)
            i = i - 1
        end
    end
end

local function sourceOf(fn, vanillaFile)
    local ok, file = pcall(getFilenameOfClosure, fn)
    if not ok or type(file) ~= "string" then return false, "it has no known source" end
    local path = string.lower(string.gsub(file, "\\", "/"))
    if string.sub(path, -#vanillaFile) ~= vanillaFile or string.find(path, "/mods/", 1, true) then
        return false, "it comes from " .. file
    end
    return true
end

-- 3 株、第 2 株是空值：原版 :236-251 的呼叫序列（"+" 是多出來的參數）。
-- 假 self／假作物被讀到別的鍵就記成 "?鍵" 並回一個吞掉一切呼叫的代理、被寫新欄位就記成 "!鍵"，讓改過的本體
-- 以「序列不符」收尾、不拋錯：pcall 接住的錯照樣進引擎錯誤清單、算在本 MOD 頭上。超過 PROBE_LIMIT 筆就中止，防無窮迴圈。
local PROBE_TRACE = "n,g1,g1,c1,g2,n,g3,g3,f3,g2"
local PROBE_LIMIT = 64
local function probe(fn)
    local trace = {}
    local function log(s)
        trace[#trace + 1] = s
        if #trace > PROBE_LIMIT then error("probe runaway", 0) end
    end
    local function extra(n, ...) return string.rep("+", math.max(0, select("#", ...) - n)) end
    local function idOf(o) return type(o) == "table" and tostring(rawget(o, "id")) or "?" end
    local proxy = {}
    local function unknown(_, k) log("?" .. tostring(k)); return proxy end
    setmetatable(proxy, { __index = unknown, __call = function() return proxy end })
    local meta = { __index = unknown, __newindex = function(_, k) log("!" .. tostring(k)) end }
    local objs = { setmetatable({ id = 1 }, meta), false, setmetatable({ id = 3 }, meta) }
    local fake = setmetatable({
        getLuaObjectCount = function(...) log("n" .. extra(1, ...)); return 3 end,
        getLuaObjectByIndex = function(_, i, ...) log("g" .. tostring(i) .. extra(0, ...)); return objs[i] or nil end,
        checkPlant2 = function(_, o, ...) log("c" .. idOf(o) .. extra(0, ...)) end,
        plowFadeCheck = function(_, o, ...) log("f" .. idOf(o) .. extra(0, ...)) end,
    }, meta)
    local ok = pcall(fn, fake)
    return ok and table.concat(trace, ",") == PROBE_TRACE
end

local function install()
    local cls = SFarmingSystem
    if type(cls) ~= "table" or type(cls.checkPlant) ~= "function" then
        warnOnce("shape", "MDFX_FarmingCheckPlantOnce NOT installed: vanilla SFarmingSystem.checkPlant shape changed; re-check docs/fixes.md")
        return
    end
    if cls[MARKER] == cls.checkPlant then return end
    local original = cls.checkPlant
    local vanilla, why = sourceOf(original, VANILLA_FILE)
    if not vanilla then
        warnOnce("foreign", "MDFX_FarmingCheckPlantOnce NOT installed for SFarmingSystem.checkPlant: " .. why
            .. ", not vanilla; leaving it alone." .. DOC)
        return
    end
    if not probe(original) then
        warnOnce("probe", "MDFX_FarmingCheckPlantOnce NOT installed: vanilla SFarmingSystem.checkPlant no longer"
            .. " behaves as this fix expects (game update?); leaving it alone." .. DOC)
        return
    end
    local getter = cls.getLuaObjectByIndex
    vanilla, why = sourceOf(getter, GETTER_FILE)
    if not vanilla then
        warnOnce("getter", "MDFX_FarmingCheckPlantOnce NOT installed: SFarmingSystem.getLuaObjectByIndex " .. why
            .. ", not vanilla; leaving checkPlant alone." .. DOC)
        return
    end
    local checkPlant = makeCheckPlant(original, getter)
    cls.checkPlant = checkPlant
    cls[MARKER] = checkPlant
    warnOnce("installed", "MDFX_FarmingCheckPlantOnce installed: the ten-minute crop check fetches each crop once per pass." .. DOC)
end

install()
