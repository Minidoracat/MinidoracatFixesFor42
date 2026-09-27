--[[
MDFX_FarmingStallHeal — 作物卡在舊農作物時鐘上不長的自癒（server／單人）

【缺陷】
農作物時鐘 hoursElapsed 在 gos_farming.bin 讀不到時歸零（成因見 MDFX_FarmingClockBackup）。
作物之後從地圖物件的 modData 重新登記：SGlobalObjectSystem:loadIsoObject
（server/Map/SGlobalObjectSystem.lua:133-149）對沒有 luaObject 的格子走
SPlantGlobalObject:stateFromIsoObject（SPlantGlobalObject.lua:43-56），照抄舊時鐘的
nextGrowing／lastWaterHour。原版的時鐘錯位補救只寫在 stateToIsoObject（:66-76），
觸發條件是 lastWaterHour > hoursElapsed，而且要等該格下一次載入才會跑；在那之前只要
下雨（SFarmingSystem.lua:309）或澆水（SPlantGlobalObject.lua:513），lastWaterHour 就被改成
新時鐘的小值，補救永遠不會觸發。

【後果】
nextGrowing 停在舊時鐘（正式服實例：比現在多約 30,900 遊戲小時），checkPlant2 的
`self.hoursElapsed >= luaObject.nextGrowing`（SFarmingSystem.lua:278）幾十年內都不會成立，
作物停在目前階段。農業 6 級以上看到下個階段要「數月」，其他人看到「未知」。

【本補丁】
包裝 SFarmingSystem:checkPlant2（每 10 遊戲分鐘對每株非 destroyed／harvested 作物各跑一次，
不論有沒有載入）。對 state == "seeded" 的作物，呼叫原函式之前先判斷：
- lastWaterHour > hoursElapsed（原版自己的觸發條件，只是提早到定期檢查），或
- nextGrowing 比現在晚超過 LIMIT：原版在任何合法沙盒設定下都排不出這麼遠的時間。
  calcNextGrowing（farming_vegetableconf.lua:82-102）排的是 T × (1 / FarmingSpeedNew) + randomGrowthOffset；
  FarmingSpeedNew 最小 0.1（SandboxOptions.java:232）→ 倍率最多 10，offset 最多 +12（:78-80）；
  T 最長是 grow() 的 timeToGrow + water + waterMax + diseaseLvl（:297、:307、:321，三項合計 < 50）、
  rotTime（:284-285）或 badPlant 的 30／50（:356-360）。LIMIT = max(T) × 10 + 12，
  以目前 props 在第一次用到時算一次（原版 55 種作物：max(T) = 1494 → LIMIT = 14,952 小時）。
  排程函式（calcNextGrowing、calcNextTimeFactor、randomGrowthOffset、badPlant、
  farming_vegetableconf.grow）任一不是原版檔案的（getFilenameOfClosure 看來源），這條判斷整個關掉
  ——別的農作 MOD 可能合法地排得更遠。
成立就照原版 :67-74 的方式補救，但只往安全的方向改：
- nextGrowing 設成 hoursElapsed + timeToGrow（debug FastGrow 時 +1），**只在比現值早時**才寫。
  原版會無條件寫；時鐘由 MDFX_FarmingClockBackup 還原後，最後一次存檔之後才卸載的 chunk 可能帶著
  略新的 lastWaterHour，無條件寫會把本來幾小時後就要長的作物往後延幾百小時。
- lastWaterHour 領先時鐘才設回 hoursElapsed。
接著照常跑原函式；它最後的 saveData 會把新值同步給地圖物件與客戶端。

【零行為差異】
只有時鐘倒退過的作物會成立：原版的 lastWaterHour 只會被設成當下時鐘或讀回的舊值，
nextGrowing 也不可能超過 LIMIT。正常作物原樣透傳。判斷本身拋錯 → 印一次診斷，照跑原函式；
原函式的錯誤原樣外洩。

【安裝機制】
marker 存 wrapper 自身：Core.ResetLua 重建 SFarmingSystem 時 marker 消失、本檔重跑重新包裝；
後載 MOD 整支替換 checkPlant2 時，OnGameBoot 復查把「他的版本」當新 original 再包一層。

【退場條件】
官方在 stateFromIsoObject 也補上時鐘補救，而且補救不再只看 lastWaterHour；
或讀檔失敗不再讓時鐘歸零（此時 MDFX_FarmingClockBackup 也一起退場）。
遊戲更新後跑 `python scripts/check_vanilla_alignment.py`。
]]

if isClient() then return end

require "Farming/SFarmingSystem"
require "Farming/farming_vegetableconf"

local MARKER = "MDFX_stallHeal"
local DOC = " See docs/fixes.md MDFX_FarmingStallHeal"
local VANILLA_CONF = "/media/lua/server/farming/farming_vegetableconf.lua"

-- nil＝還沒算；false＝排程函式不是原版，遠期判斷關掉
local limit = nil

local function warnOnce(key, message)
    return MDFX_Guard.warnOnce("farmingStallHeal:" .. key, message)
end

local function longestWait()
    local maxT = 50
    for _, prop in pairs(farming_vegetableconf.props) do
        local timeToGrow = tonumber(prop.timeToGrow) or 0
        local rotTime = tonumber(prop.rotTime) or math.floor(timeToGrow / 2)
        if timeToGrow + 50 > maxT then maxT = timeToGrow + 50 end
        if rotTime > maxT then maxT = rotTime end
    end
    return maxT * 10 + 12
end

-- LIMIT 的每一項都出自這幾個函式；任一被別的 MOD 換掉就不能用
local function scheduleIsVanilla()
    if type(getFilenameOfClosure) ~= "function" then return false, "getFilenameOfClosure is unavailable" end
    local fns = {
        { "calcNextGrowing", calcNextGrowing }, { "calcNextTimeFactor", calcNextTimeFactor },
        { "randomGrowthOffset", randomGrowthOffset }, { "badPlant", badPlant },
        { "farming_vegetableconf.grow", farming_vegetableconf.grow },
    }
    for i = 1, #fns do
        local name, fn = fns[i][1], fns[i][2]
        if type(fn) ~= "function" then return false, name .. " is missing" end
        local ok, file = pcall(getFilenameOfClosure, fn)
        if not ok or type(file) ~= "string" then return false, name .. " has no known source" end
        local path = string.lower(string.gsub(file, "\\", "/"))
        if string.sub(path, -#VANILLA_CONF) ~= VANILLA_CONF or string.find(path, "/mods/", 1, true) then
            return false, name .. " comes from " .. file
        end
    end
    return true
end

local function currentLimit()
    if limit == nil then
        local vanilla, why = scheduleIsVanilla()
        if vanilla then
            limit = longestWait()
        else
            limit = false
            warnOnce("limitOff", "MDFX_FarmingStallHeal: far-future nextGrowing check disabled because " .. why
                .. "; only vanilla's lastWaterHour trigger is used." .. DOC)
        end
    end
    return limit
end

local function heal(system, plant)
    if plant.state ~= "seeded" then return end
    local now = system.hoursElapsed
    if type(now) ~= "number" then return end
    local water, grow = plant.lastWaterHour, plant.nextGrowing
    local max = currentLimit()
    local waterAhead = type(water) == "number" and water > now
    local growAhead = max and type(grow) == "number" and grow - now > max
    if not waterAhead and not growAhead then return end
    local prop = farming_vegetableconf.props[plant.typeOfSeed]
    if prop then
        local target
        if getCore():getDebug() and getDebugOptions():getBoolean("Cheat.Farming.FastGrow") then
            target = now + 1
        else
            target = now + prop.timeToGrow
        end
        if type(grow) ~= "number" or grow > target then plant.nextGrowing = target end
    end
    if waterAhead then plant.lastWaterHour = now end
    warnOnce("healed", "MDFX_FarmingStallHeal: crop at " .. tostring(plant.x) .. "," .. tostring(plant.y) .. "," .. tostring(plant.z)
        .. " (" .. tostring(plant.typeOfSeed) .. ") was scheduled on an older farming clock (nextGrowing " .. tostring(grow)
        .. " -> " .. tostring(plant.nextGrowing) .. ", lastWaterHour " .. tostring(water) .. " -> " .. tostring(plant.lastWaterHour)
        .. ", hoursElapsed " .. now .. ", limit " .. tostring(max) .. "). Further occurrences suppressed this session." .. DOC)
end

local function install()
    local cls = SFarmingSystem
    if type(cls) ~= "table" or type(cls.checkPlant2) ~= "function"
        or type(farming_vegetableconf) ~= "table" or type(farming_vegetableconf.props) ~= "table" then
        warnOnce("shape", "MDFX_FarmingStallHeal NOT installed: vanilla SFarmingSystem.checkPlant2 / farming_vegetableconf.props shape changed; re-check docs/fixes.md")
        return
    end
    if cls[MARKER] == cls.checkPlant2 then return end
    local original = cls.checkPlant2
    local function wrapper(self, luaObject)
        if luaObject then
            local ok, err = pcall(heal, self, luaObject)
            if not ok then
                warnOnce("error", "MDFX_FarmingStallHeal could not check a crop (" .. tostring(err)
                    .. "); left it to vanilla. Further occurrences suppressed this session." .. DOC)
            end
        end
        return original(self, luaObject)
    end
    cls.checkPlant2 = wrapper
    cls[MARKER] = wrapper
end

install()
if Events and Events.OnGameBoot then
    Events.OnGameBoot.Add(install)
end
