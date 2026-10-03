--[[
MDFX_GosDuplicateNewGuard — 登入那幾秒內伺服器新增的作物（等全域物件），進遊戲時每個各跳兩條錯誤

【缺陷】（行號為 42.21.0 原版 Lua 與反編譯快照）
伺服器用兩條互不對齊的路徑，把全域物件（GlobalObjectSystem：農作物、營火、雨水桶、陷阱、餵食槽）同步給客戶端：
1. 整份清單：登入被接受時（GameServer.receiveClientConnect，GameServer.java:2718-2719）寫進 ConnectionDetails
   （ConnectionDetails.java:38 → SGlobalObjects.saveInitialStateForClient，SGlobalObjects.java:103-135）；客戶端載入
   世界時照清單建好全部物件（CGlobalObjects.registerSystem，CGlobalObjects.java:28-68；GameLoadingState.java:313-314）。
2. 逐筆的新增／移除／更新封包：SGlobalObjectNetwork.sendPacket（SGlobalObjectNetwork.java:39-61）廣播給
   udpEngine.connections 的每一條連線，不看連線狀態。連線在 RakNet 接上後就加進這張表
   （GameServer$DelayedConnection.connect，GameServer.java:4427-4436；伺服器 user log 的 Connection add），
   比清單早了整段登入驗證。客戶端載入期間收到的這類封包全部延後（GlobalObjectsPacket 的 handlingType=3
   沒有載入中處理，PacketTypes.java:809-811；GameClient.java:370-378），進遊戲時才依序處理
   （IngameState.enter 的 Processing delayed packets，GameClient.java:380-385）。
所以伺服器在「連線加進廣播表」到「打包清單」之間新增的物件，會同時出現在清單與延後的新增封包裡。處理那包
新增時，原版 CGlobalObjectSystem:newLuaObjectAt（client/Map/CGlobalObjectSystem.lua:69-72）不看同座標是否已有
物件就呼叫 newObject：Java 拋 already an object at（GlobalObjectSystem.java:36-45），Kahlua 記下例外後回傳 nil、
繼續執行（MethodCaller.java:34-43），接著 CGlobalObject.new 對 nil 取 getModData（client/Map/CGlobalObject.lua:16）
再拋一次。

【後果】
每個重複的新增封包兩條錯誤（Java 例外＋Lua 錯誤），玩家進遊戲那一刻成批跳出。資料沒有壞：Lua 失敗後，Java 照樣
把封包內容寫進原本那個物件（CGlobalObjectSystem.receiveNewLuaObjectAt，CGlobalObjectSystem.java:34-50）。原版只在
種植、蓋營火這類零星新增時碰得到；MDFX_FarmingGosPrune 在區域載入時整批重建作物，登入那幾秒剛好有人載入這種區域
時一次就是數十條。正式服實例：連線加進廣播表到打包清單相隔 1.9 秒，其間另一位玩家開車經過一塊廢棄農田，30 株
踩爛／枯死作物被重建，登入的玩家進遊戲時跳出 60 條錯誤。

【本補丁】
包裝 CGlobalObjectSystem.newLuaObjectAt：同座標已有物件就回傳那個物件、不再 newObject，其餘照原函式。Java 接著
把封包內容寫進這個物件，結果與原版拋錯之後相同，只是不再拋錯。查詢用 Java 的 self.system:getObjectAt，不用 Lua 的
getLuaObjectAt（它會先從地圖物件抄 modData，CGlobalObjectSystem.lua:84-92，原版這條路徑沒有）。包在基底類別上：
沒有自己覆寫 newLuaObjectAt 的系統（原版五個系統都沒有）一起受益；覆寫了的 MOD 系統照它自己的版本。每次開機只印
第一次，攔到的次數記在 MDFX_GosDuplicateNewGuard.kept。

【與原版的差異】
只少了錯誤：物件、它的 Lua 欄位與封包寫入的資料，和原版拋錯之後的狀態逐一相同。

【安裝】
檔案載入時就包（原版 client 檔先於所有 MOD 執行）；marker 存 wrapper 本身，Core.ResetLua 重建類別表後重新安裝。
形狀不符（沒有 CGlobalObjectSystem 或 newLuaObjectAt）印 NOT installed 並放棄；自己的查詢出錯印一次並照原函式走。

【退場條件】
官方讓 newLuaObjectAt 遇到已存在的物件不再拋錯，或伺服器不再對還沒拿到清單的連線廣播（check_vanilla_alignment.py
兩者都有 exithint）。
]]

local MARKER = "MDFX_GosDuplicateNewGuard"

local warned = {}
local function warnOnce(key, message)
    if warned[key] then return end
    warned[key] = true
    print("[MinidoracatFixes] MDFX_GosDuplicateNewGuard " .. message .. " See docs/fixes.md MDFX_GosDuplicateNewGuard")
end

local cls = CGlobalObjectSystem
if type(cls) ~= "table" or type(cls.newLuaObjectAt) ~= "function" then
    warnOnce("shape", "NOT installed: vanilla CGlobalObjectSystem shape changed; re-check docs/fixes.md.")
    return
end
if cls[MARKER] == cls.newLuaObjectAt then
    return
end

local G = MDFX_GosDuplicateNewGuard or { kept = 0 }
MDFX_GosDuplicateNewGuard = G

local original = cls.newLuaObjectAt

local function existingAt(self, x, y, z)
    return self.system:getObjectAt(x, y, z)
end

local function wrapper(self, x, y, z)
    local ok, existing = pcall(existingAt, self, x, y, z)
    if not ok then
        warnOnce("lookupError", "could not look up an existing object (" .. tostring(existing) .. "); vanilla path kept.")
    elseif existing then
        G.kept = G.kept + 1
        warnOnce("kept", "the server announced a new " .. tostring(self.systemName) .. " object at "
            .. tostring(x) .. "," .. tostring(y) .. "," .. tostring(z)
            .. " that this client already had (it joined while the server was adding it); kept the existing one."
            .. " Further occurrences not logged this session.")
        return existing:getModData()
    end
    return original(self, x, y, z)
end

cls.newLuaObjectAt = wrapper
cls[MARKER] = wrapper
