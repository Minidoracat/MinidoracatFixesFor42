--[[
MDFX_FarmingClockBackup — gos_farming.bin 讀不到時還原農作物時鐘（server／單人）

【缺陷】
農作物系統用自己的時鐘 hoursElapsed（每遊戲小時 +1，SFarmingSystem.lua:93）排每株作物
的下次生長時間 nextGrowing。這個時鐘只存在 gos_farming.bin（setModDataKeys，:27）。
存檔時 SGlobalObjectSystem.save()（SGlobalObjectSystem.java:273-298）先開 FileOutputStream
（:279，當場把檔案截成 0 byte）才往固定 10 MiB 的 SliceY.SliceBuffer 序列化；超過就丟
BufferOverflowException、被 catch 後只記 log（:294），檔案停在 0 byte。下次開機 load()
（:240-271）讀空檔在 :251 拋 IllegalArgumentException，也只記 log，系統以空狀態啟動，
SFarmingSystem:new 的 `o.hoursElapsed = o.hoursElapsed or 0`（SFarmingSystem.lua:11）把時鐘歸零。

【後果】
作物之後從地圖物件的 modData 重新登記（MOFarming.lua → loadIsoObject →
stateFromIsoObject），nextGrowing 仍是舊時鐘的值（正式服實例：舊時鐘 30,104，
作物卡在 3 萬多遊戲小時後才會長）。原版只在 stateToIsoObject（SPlantGlobalObject.lua:66-76）
有一道看 lastWaterHour 的補救，下雨或澆水就讓它失效（見 MDFX_FarmingStallHeal）。

【本補丁】
- 每 10 遊戲分鐘（排在原版 EveryTenMinutes 之後，原版先 +1）把時鐘抄進 GlobalModData
  `MinidoracatFixes_FarmingClock.hoursElapsed`。GlobalModData 與 gos_farming.bin 在同一輪存檔寫出
  （ServerMap.java:391、:409），但是獨立檔案，不受農作物存檔溢出影響。
- OnSGlobalObjectSystemInit（原版的 handler 已建好 SFarmingSystem.instance）時：
  loadedWorldVersion() 仍是 -1（這個欄位只在 load 整份讀完才寫，SGlobalObjectSystem.java:207）
  ＝檔案不存在或讀不完；再加上有備份、備份比現在的時鐘大 → 把時鐘設回備份。
  GlobalModData 在世界初始化時就讀好（IsoWorld.java:1995），早於 initSystems
  （GameServer.java:802、GameLoadingState.java:315）；作物要等 chunk 載入的 OnLoad 才重新登記，
  所以重新登記時用的已經是還原後的時鐘，nextGrowing 對得上。

【零行為差異】
存檔正常讀到時完全不動時鐘，只多寫一個數字進 GlobalModData（不 transmit，客戶端看不到）。
新世界沒有備份，不會誤判。還原值就是檔案壞掉前最後一次存檔時的時鐘；就算判斷錯
（例如有人刻意刪檔重置農作物），時鐘只是遞增計數，設成較大的值不會讓任何作物變快或變慢。

【安裝機制】
require "Farming/SFarmingSystem" 讓原版的事件先註冊（事件依註冊順序觸發）。
開機時沒找到 SFarmingSystem.instance 就印 NOT installed；這一局如果存檔也沒讀到，就不寫備份
——讀檔失敗又沒還原時寫入，會用歸零後的時鐘蓋掉唯一的備份。

【退場條件】
官方把 GOS 存檔改成不會留下 0 byte 檔（先寫暫存檔再改名、或拿掉 10 MiB 上限），
或讀檔失敗時自己保住時鐘。遊戲更新後跑 `python scripts/check_vanilla_alignment.py`。
]]

if isClient() then return end

require "Farming/SFarmingSystem"

local KEY = "MinidoracatFixes_FarmingClock"
local DOC = " See docs/fixes.md MDFX_FarmingClockBackup"

-- 本 session 開機時是否比對過備份
local checked = false

local function warnOnce(key, message)
    return MDFX_Guard.warnOnce("farmingClockBackup:" .. key, message)
end

local function loadedWorldVersion(system)
    local ok, version = pcall(function() return system.system:loadedWorldVersion() end)
    if ok then return version end
    return nil
end

local function restore()
    local system = SFarmingSystem and SFarmingSystem.instance
    if type(system) ~= "table" then
        warnOnce("shape", "MDFX_FarmingClockBackup NOT installed: vanilla SFarmingSystem.instance missing at OnSGlobalObjectSystemInit; re-check docs/fixes.md")
        return
    end
    checked = true
    if loadedWorldVersion(system) ~= -1 then return end
    local ok, saved = pcall(function() return ModData.exists(KEY) and ModData.get(KEY).hoursElapsed end)
    if not ok or type(saved) ~= "number" then return end
    local current = system.hoursElapsed
    if type(current) == "number" and current >= saved then return end
    system.hoursElapsed = saved
    warnOnce("restored", "MDFX_FarmingClockBackup: gos_farming.bin did not load; farming clock restored from backup (hoursElapsed "
        .. tostring(current) .. " -> " .. tostring(saved) .. "), so crops rebuilt from map objects keep their schedule." .. DOC)
end

local function record()
    local system = SFarmingSystem and SFarmingSystem.instance
    if type(system) ~= "table" or type(system.hoursElapsed) ~= "number" then return end
    if not checked then
        local version = loadedWorldVersion(system)
        if version == nil or version == -1 then return end
    end
    local ok, err = pcall(function() ModData.getOrCreate(KEY).hoursElapsed = system.hoursElapsed end)
    if not ok then
        warnOnce("record", "MDFX_FarmingClockBackup could not write the clock backup (" .. tostring(err) .. ")." .. DOC)
    end
end

Events.OnSGlobalObjectSystemInit.Add(restore)
Events.EveryTenMinutes.Add(record)
