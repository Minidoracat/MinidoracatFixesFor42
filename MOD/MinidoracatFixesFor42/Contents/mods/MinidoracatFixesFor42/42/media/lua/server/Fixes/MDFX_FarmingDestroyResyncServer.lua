--[[
MDFX_FarmingDestroyResyncServer — 打到已踩爛作物的客戶端 destroy 指令，伺服器在分派前就返回（server 端）
客戶端那一半是 client/Fixes/MDFX_FarmingDestroyResync.lua；兩支合起來是 docs/fixes.md 的 MDFX_FarmingDestroyResync。

【缺陷】（行號為 42.22.2 原版 Lua 與反編譯快照）
客戶端的車停在作物上時，客戶端每次車輛更新都對伺服器早就踩爛的作物再送一次 destroy（成因見客戶端那支的檔頭）。
伺服器每包都走 SGlobalObjectSystem.receiveClientCommand（SGlobalObjectSystem.java:111-117）→
SFarmingSystem:OnClientCommand（server/Farming/SFarmingSystem.lua:83-85）→ SFarmingSystemCommands.destroy
（farmingCommands.lua:118-125）→ destroyThis（SPlantGlobalObject.lua:695-705）→ deadPlant → saveData，值都沒變。
別的 MOD 包在 SFarmingSystemCommands 每個指令外面的檢查（例如安全屋權限）也每包跑一次。
客戶端修好之後，還有一種情況客戶端會一直送：它的地圖物件停在舊狀態（伺服器送 modData 時它還沒載完那個 chunk，
ObjectModDataPacket.java:53-56 找不到物件就丟掉）。這時 MDFX_FarmingSyncDedupe 判定內容沒變、不再送，客戶端收斂不了。

【後果】
正式服 2026-11-25 Lua 取樣：伺服器主執行緒 22.6% 在 SFarmingSystem.lua:84 OnClientCommand 底下，其中 16.7% 是安全屋 MOD
的權限判定（那位玩家不在時 0%）。

【本補丁】
包裝 SFarmingSystem.OnClientCommand（Java 每次用 rawget 取，找不到會查 metatable，KahluaTableImpl.java:100，所以包類別上的就生效）：
指令是 destroy、座標是數字、伺服器這一格的作物 state 已經是 "destroyed"、地圖物件（有的話）的 modData state 也是 "destroyed"
就直接返回，不分派。兩份不一致時照原函式走，讓原版 saveData 把權威狀態寫回地圖物件再送出。
返回前把地圖物件的 modData 再送一次（transmitModData 送給附近所有連線，GameServer.java:2952-2955），
同一株每個 RESEND_MS 固定視窗最多一次（跨視窗時兩次可能相隔不到 1 秒，最多約每秒兩次），讓地圖物件停在舊狀態的客戶端收斂；原版每次 destroy 也會送這一包。
視窗一到（或系統時鐘往回調）就整張表清掉：表的大小以一個視窗內被打到的作物數為上限，鍵用伺服器的作物物件（客戶端的小數座標會被 Java 截成同一格）。
其餘指令、其餘作物、座標不對都照原函式。只包原版自己的 OnClientCommand（getFilenameOfClosure 指向原版 SFarmingSystem.lua）。

【與原版的差異】
同客戶端那支：只少處理伺服器上已經 destroyed 的作物的 destroy，原版這時只是把 deadPlant 歸零的欄位再歸零一次。
另外這種指令不再經過別的 MOD 對 SFarmingSystemCommands.destroy 的任何處理（例如安全屋的權限檢查、拒絕紀錄與通知）。

【安裝】
MDFX_Guard.onServer：只在 dedicated server，檔案載入時與 OnGameBoot 各試一次；本 Lua 狀態裝過、現任也不是當初包的原版函式就不再檢查
（被別的 MOD 串接包住也不誤報）；現任又變回當初的原版函式（別的程式寫回去）就重新包。
形狀不符或不是原版的函式印 NOT installed 並放棄；自己的判斷出錯印一次並照原函式走。

【退場條件】
docs/fixes.md MDFX_FarmingDestroyResync：官方的伺服器不再處理打到已踩爛作物的 destroy，而且沒有還會洪流的舊客戶端。
]]

local VANILLA_FILE = "/media/lua/server/farming/sfarmingsystem.lua"
local DOC = " See docs/fixes.md MDFX_FarmingDestroyResync"
local RESEND_MS = 1000

local G = MDFX_FarmingDestroyResync or { skipped = 0 }
MDFX_FarmingDestroyResync = G
G.serverSkipped = G.serverSkipped or 0
G.resent = G.resent or 0

local installedOn, installedOriginal = nil, nil
local resentAt = {}
local windowStart = nil
local skipLogged = false

local function warnOnce(key, message)
    return MDFX_Guard.warnOnce("farmingDestroyResync:" .. key, "MDFX_FarmingDestroyResync " .. message .. DOC)
end

-- 回傳 true＝伺服器上這一格已經 destroyed（地圖物件也是），這包不必分派
local function alreadyDestroyed(system, args)
    if type(args) ~= "table" then return false end
    local x, y, z = args.x, args.y, args.z
    if type(x) ~= "number" or type(y) ~= "number" or type(z) ~= "number" then return false end
    local plant = system:getLuaObjectAt(x, y, z)
    if plant == nil or plant.state ~= "destroyed" then return false end
    local iso = plant:getIsoObject()
    if iso and iso:getModData().state ~= "destroyed" then return false end
    if not iso then return true end
    local now = getTimestampMs()
    if not windowStart or now < windowStart or now - windowStart >= RESEND_MS then
        resentAt = {}
        windowStart = now
    end
    if not resentAt[plant] then
        resentAt[plant] = true
        iso:transmitModData()
        G.resent = G.resent + 1
    end
    return true
end

local function wrap(original)
    return function(self, command, playerObj, args)
        if command == "destroy" then
            local ok, skip = pcall(alreadyDestroyed, self, args)
            if not ok then
                warnOnce("error", "could not read the crop for a destroy command (" .. tostring(skip)
                    .. "); handled it the vanilla way. Further errors not logged this session.")
            elseif skip then
                G.serverSkipped = G.serverSkipped + 1
                if not skipLogged then
                    skipLogged = true
                    warnOnce("skipped", "crop at " .. tostring(args.x) .. "," .. tostring(args.y) .. "," .. tostring(args.z)
                        .. " is already destroyed; ignored a destroy command from a client (crop data is re-sent to nearby"
                        .. " players about once a second). Further skips not logged this session.")
                end
                return
            end
        end
        return original(self, command, playerObj, args)
    end
end

MDFX_Guard.onServer(function()
    local cls = SFarmingSystem
    if type(cls) ~= "table" or type(cls.OnClientCommand) ~= "function" or type(cls.getLuaObjectAt) ~= "function"
        or type(getFilenameOfClosure) ~= "function" or type(getTimestampMs) ~= "function" then
        warnOnce("shape", "NOT installed: vanilla SFarmingSystem shape changed; re-check docs/fixes.md.")
        return
    end
    if installedOn == cls and cls.OnClientCommand ~= installedOriginal then return end
    local current = cls.OnClientCommand
    local okSrc, file = pcall(getFilenameOfClosure, current)
    local path = okSrc and type(file) == "string" and string.lower(string.gsub(file, "\\", "/")) or nil
    if not path or string.sub(path, -#VANILLA_FILE) ~= VANILLA_FILE or string.find(path, "/mods/", 1, true) then
        warnOnce("foreign", "NOT installed: SFarmingSystem.OnClientCommand comes from " .. tostring(file) .. ", not vanilla; leaving it alone.")
        return
    end
    cls.OnClientCommand = wrap(current)
    installedOn, installedOriginal = cls, current
end)
