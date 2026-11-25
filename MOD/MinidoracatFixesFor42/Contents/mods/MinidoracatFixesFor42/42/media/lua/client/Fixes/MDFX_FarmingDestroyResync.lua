--[[
MDFX_FarmingDestroyResync — 車停在作物上時，多人客戶端不停送農作 destroy 指令（客戶端）

【缺陷】（行號為 42.22.2 原版 Lua 與反編譯快照）
多人客戶端每次車輛更新都檢查車身周圍 2×2 格的作物（BaseVehicle.java:3578-3588 →
IsoGridSquare.checkForIntersectingCrops:9923-9927 → destroyFarmingPlant:11289）；殭屍也會（IsoZombie.java:3412-3416）。
GlobalObject.destroyThisObject（GlobalObject.java:85-98）只在這一格的全域物件 state 不是 "destroyed" 時，
播 RemovePlant 音效並呼叫 CFarmingSystem.destroyPlant（client/Farming/CFarmingSystem.lua:176-183）→ 送 destroy 指令。
客戶端全域物件的 state 卻幾乎不會是 "destroyed"：
1. 農作系統沒設 objectSyncKeys（只有餵食槽設，SFeedingTroughSystem.lua:22），登入清單（SGlobalObjects.java:103-135）
   與新增／更新封包（SGlobalObjectNetwork.java:91-129）只帶座標，客戶端物件的 state 一開始是 nil。
2. 伺服器改作物時送的是地圖物件的 modData（SPlantGlobalObject.lua:771-777 transmitModData），客戶端寫進地圖物件，
   不寫全域物件。全域物件只有 Lua 呼叫 getLuaObjectAt 時才從地圖物件抄一次（CGlobalObjectSystem.lua:84-92 →
   CGlobalObject.lua:46-51 updateFromIsoObject），也就是玩家看作物資訊、開農作選單、做農作動作的時候。
所以伺服器上早就踩爛的作物，客戶端照樣每次車輛更新都再送一次 destroy；伺服器每次都跑一遍
farmingCommands.lua:118-125 → destroyThis（SPlantGlobalObject.lua:695-705）→ deadPlant，值都沒變。

【後果】
車停在作物上、附近有玩家時，每個看得到那台車的客戶端每幀每格送一包，停多久送多久。正式服 2026-11-25 Lua 取樣：
有一位玩家在自己的基地（農地＋多台車與拖車）時，伺服器主執行緒 22.6% 在處理這個指令（含別的 MOD 對每個農作指令
做的權限判定），他不在時是 0%；同 10 分鐘內 Server is too busy 9 次，對照組 0 次。

【本補丁】
包裝 CFarmingSystem.destroyPlant：送之前先用原版的 getLuaObjectOnSquare 取這一格的作物（它會先從地圖物件抄
modData，也就是伺服器最後送來的狀態）。抄完 state 是 "destroyed" 就不送；其餘照原函式送。抄這一次也讓全域物件的
state 變成 "destroyed"，之後 Java 在 destroyThisObject 開頭就返回，不再呼叫 Lua、也不再播音效。
只包原版自己的 destroyPlant（getFilenameOfClosure 指向原版 CFarmingSystem.lua、路徑不含 /mods/）；別的 MOD 換掉
的就不碰，印 NOT installed。每次開機只印第一次，不送的次數記在 MDFX_FarmingDestroyResync.skipped。
伺服器那一半（server/Fixes/MDFX_FarmingDestroyResyncServer.lua）在分派前擋掉仍然送到的這種指令，並補送一次地圖物件的
modData，讓地圖物件停在舊狀態的客戶端也收斂。

【與原版的差異】
少送的都是打到伺服器上已經 destroyed 的作物的指令（車與殭屍兩條路徑都是；地圖物件的 state 只由伺服器改）。
伺服器對這種指令只是把 deadPlant 歸零的欄位再歸零一次，看得出差別的只有：
1. 澆水動作進行中作物被踩爛、車還壓著時，水量不再被下一包 destroy 歸零；管理員用農作除錯指令改的數值也一樣
   （施肥對已踩爛的作物原版本來就不做事）。
2. 已踩爛的作物不再每幀播 RemovePlant 音效（Java 在呼叫 Lua 之前就播）；活作物在伺服器狀態回來前照舊每幀播，
   抄到狀態那次再播一次，重新登入後每格再一次。
3. 這種指令不再到伺服器，伺服器端原版與別的 MOD 對它的處理都不再執行（例如安全屋的拒絕彙總與通知）。
全域物件記住 "destroyed" 之後，同一株若被別的 MOD 或改過的客戶端送的 kill 指令改成 dead（原版沒有介面會送），Java 不再呼叫 Lua；
原版玩家滑過作物提示或開農作選單後也一樣。

【安裝】
檔案載入時就包（原版 client 檔先於所有 MOD 執行）；marker 存 wrapper 本身，Core.ResetLua 重建類別表後重新安裝。
形狀不符印 NOT installed 並放棄；自己的查詢出錯印一次並照原函式送。

【退場條件】
官方讓客戶端全域物件跟著伺服器的作物狀態走（農作系統設 objectSyncKeys，或 destroyThisObject 改看地圖物件），
或客戶端 destroyPlant 送之前自己看狀態。只有伺服器擋掉不算：客戶端照樣每幀送，還會吃掉客戶端每秒 300 包的
GlobalObjects 限流（PacketsCache.java:76-111）。check_vanilla_alignment.py 有指紋。
]]

local MARKER = "MDFX_FarmingDestroyResync"
local VANILLA_FILE = "/media/lua/client/farming/cfarmingsystem.lua"
local DOC = " See docs/fixes.md MDFX_FarmingDestroyResync"

local warned = {}
local function warnOnce(key, message)
    if warned[key] then return end
    warned[key] = true
    print("[MinidoracatFixes] MDFX_FarmingDestroyResync " .. message .. DOC)
end

local cls = CFarmingSystem
if type(cls) ~= "table" or type(cls.destroyPlant) ~= "function" or type(cls.getLuaObjectOnSquare) ~= "function"
    or type(getFilenameOfClosure) ~= "function" then
    warnOnce("shape", "NOT installed: vanilla CFarmingSystem shape changed; re-check docs/fixes.md.")
    return
end
if cls[MARKER] == cls.destroyPlant then
    return
end

local okSrc, file = pcall(getFilenameOfClosure, cls.destroyPlant)
local path = okSrc and type(file) == "string" and string.lower(string.gsub(file, "\\", "/")) or nil
if not path or string.sub(path, -#VANILLA_FILE) ~= VANILLA_FILE or string.find(path, "/mods/", 1, true) then
    warnOnce("foreign", "NOT installed: CFarmingSystem.destroyPlant comes from " .. tostring(file) .. ", not vanilla; leaving it alone.")
    return
end

local G = MDFX_FarmingDestroyResync or { skipped = 0 }
MDFX_FarmingDestroyResync = G

local original = cls.destroyPlant

-- getLuaObjectOnSquare 先 updateFromIsoObject：拿到的 state 是伺服器最後送到這個客戶端的
local function destroyedOnServer(square)
    local system = CFarmingSystem.instance
    if not system then return false end
    local plant = system:getLuaObjectOnSquare(square)
    return plant ~= nil and plant.state == "destroyed"
end

local function wrapper(square)
    if square then
        local ok, destroyed = pcall(destroyedOnServer, square)
        if not ok then
            warnOnce("lookupError", "could not read the crop on this square (" .. tostring(destroyed) .. "); sent destroy as vanilla does.")
        elseif destroyed then
            G.skipped = G.skipped + 1
            warnOnce("skipped", "crop at " .. tostring(square:getX()) .. "," .. tostring(square:getY()) .. "," .. tostring(square:getZ())
                .. " is already destroyed on the server; did not send destroy again. Further skips not logged this session.")
            return
        end
    end
    return original(square)
end

cls.destroyPlant = wrapper
cls[MARKER] = wrapper
