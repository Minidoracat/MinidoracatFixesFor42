--[[
MDFX_StaleRoomGuard — 玩家自建建築改建後，客戶端殘留「已失效房間」的格子讓遊戲崩潰斷線

【缺陷】（行號為 42.20.4 反編譯快照）
客戶端處理玩家自建建築的 WorldRegionToMetaGrid.clientProcessBuildings（:59）在牆／地板
變動後，把附近的自建建築整批移除再重建。移除時 removeIsoRoom（:432-434）把舊房間的
def 設成 null，但之後的 updateSquares（:601-610）只重設「被標記為需要更新」的區塊裡的
格子，而 removeUserDefinedBuildingsFromCell（:206-214）只標記仍掛著建築的區域——
被重算過、或拆牆後不再封閉的區域都不在其中。這些格子的 roomId 還是舊值，
getRoom()（IsoGridSquare.java:9643-9645）回傳那個 def 已是 null 的舊房間。

【後果】
客戶端每一幀替每一位玩家（本地與遠端都算，IsoPlayer.java:2135-2136
`if (!GameServer.server) updateEmitter()`）更新聲音參數，ParameterFirearmRoomSize
（:38-39）對腳下格子的房間直接 getRoomDef().getArea()，沒有 null 檢查 → NPE。
例外傳到 IngameState.updateInternal，原版在那裡存一份當機副本後
doDisconnect("crash")（IngameState.java:1553-1588）——玩家被踢回主選單。
只要一位玩家站在這種格子上，所有看得到他的客戶端會同時斷線；重連後區塊重新
載入、暫時正常，等附近又有人蓋或拆東西就再發生。伺服器不執行這兩段，單人會中。

【本補丁】
在 OnTick 修好每位玩家周圍的失效格子。引擎每一幀依序是 IsoCell.update（玩家移動、
讀聲音參數＝爆點）→ IsoRegions.update（重建房間＝失效格子在這裡產生）
（IsoWorld.java:2935-2937）→ Lua OnTick（IngameState.java:1507、:1534），所以
OnTick 剛好落在「產生」與「下一幀讀取」之間。修法照原版 updateSquares 對正常
更新的格子做的事：地圖上這個位置已經沒有房間（IsoMetaGrid.getRoomAt 回 nil）就
setRoomID(-1)，再 RecalcProperties() 讓室外旗標跟著更新（IsoGridSquare.java:7703）。
地圖上仍有房間的形狀不該出現，遇到就不動、印一行診斷：房間 id 大於 2^53
（RoomID.java:4-7），經過 Lua 數字會失真，不自己拼回去。

【效能】只在需要時檢查，不是每幀掃描：
1. 每位玩家每幀只比對腳下格子換了沒（每人 2 次 Java 呼叫）。
2. 換格子時檢查新位置上下三層、周圍 3×3 共 27 格。一幀移動不到一格，所以腳下與
   下一步踩得到的格子永遠是檢查過的。
3. 房間只會在重建時失效，而重建前一定換掉整份區域資料（IsoRegions.update 交換兩份
   DataRoot，IsoRegions.java:206-214；兩份各有自己的 DataChunk 物件，
   DataRoot.java:18-66）。每幀只問一次某個已知區塊的 DataChunk 是不是同一個物件；
   換了就重新檢查所有玩家周圍。
4. 還沒找到任何區域資料（附近沒有玩家建築）時，每 30 幀在玩家所在與相鄰區塊找
   一次；找到的當下全部重新檢查（它可能在被我們看到之前就重建過）。

【已知限制】
一幀內移動超過一格（傳送、網路校正、極快的載具）時，落點若剛好是失效格子，仍會
走原版的崩潰路徑。

【退場條件】
官方在 getRoomSize 補上 null 檢查，或 updateSquares 也重設失效房間的格子。
**42.21 已退場**：removeUserDefinedBuildingsFromCell 移除每棟自建建築前先 markBuildingChunksDirty，
updateSquares 會重設舊房間覆蓋的每一格（實機對照組拆牆後失效格子 0 幀）。本檔只在找到失效格子時
才動作，保留為 regression 保險；爆點本身仍沒有 null 檢查。
遊戲更新後跑 `python scripts/check_vanilla_alignment.py`（本修復登記的是 Java 指紋）。
]]

if MDFX_StaleRoomGuard then return end

local warned = {}
local function warnOnce(key, message)
    if warned[key] then return end
    warned[key] = true
    print("[MinidoracatFixes] MDFX_StaleRoomGuard " .. message .. " See docs/fixes.md MDFX_StaleRoomGuard")
end

if not (Events and Events.OnTick and Events.OnTick.Add and getSquare and getWorld and isClient
        and getOnlinePlayers and getNumActivePlayers and getSpecificPlayer
        and IsoRegions and IsoRegions.getDataChunk) then
    warnOnce("shape", "NOT installed: engine API shape changed; re-check docs/fixes.md.")
    return
end

local CHUNK = 8          -- B42 區塊寬（IsoRegions.java:39 CHUNK_DIM）
local SEARCH_EVERY = 30  -- 沒有探針時隔幾幀找一次

local getDataChunk = IsoRegions.getDataChunk
local getSquare = getSquare
local floor = math.floor

local G = { repaired = 0, unexpected = 0, verified = 0, resyncs = 0 }
MDFX_StaleRoomGuard = G

-- slot i＝本幀第 i 位玩家：上次看到的玩家、腳下格子、所在區塊
local slotPlayer, slotSquare, slotCX, slotCY = {}, {}, {}, {}
local slotCount = 0
local probeX, probeY, probe = nil, nil, nil
local searchIn = 0
local mp = nil
local disabled = false

local function repair(s)
    local x, y, z = s:getX(), s:getY(), s:getZ()
    local where = x .. "," .. y .. "," .. z
    if getWorld():getMetaGrid():getRoomAt(x, y, z) ~= nil then
        G.unexpected = G.unexpected + 1
        warnOnce("unexpected", "left square " .. where
            .. " untouched: it points at a removed room but the map still has a room there (NOT guessing the room id).")
        return
    end
    s:setRoomID(-1)
    s:RecalcProperties()
    G.repaired = G.repaired + 1
    warnOnce("repaired", "repaired square " .. where
        .. " that still pointed at a removed player-built room (vanilla ParameterFirearmRoomSize would crash and disconnect)."
        .. " Further repairs suppressed this session.")
end

local function tryProbe(cx, cy)
    local dc = getDataChunk(cx, cy)
    if dc == nil then return false end
    probeX, probeY, probe = cx, cy, dc
    return true
end

local function verify(i, sq)
    G.verified = G.verified + 1
    local x, y, z = sq:getX(), sq:getY(), sq:getZ()
    for zz = z - 1, z + 1 do
        for xx = x - 1, x + 1 do
            for yy = y - 1, y + 1 do
                local s = getSquare(xx, yy, zz)
                if s then
                    local room = s:getRoom()
                    if room and room:getRoomDef() == nil then repair(s) end
                end
            end
        end
    end
    local cx, cy = floor(x / CHUNK), floor(y / CHUNK)
    slotCX[i], slotCY[i] = cx, cy
    if probe == nil then tryProbe(cx, cy) end
end

local function visit(i, p, resync)
    local sq = p:getCurrentSquare()
    if resync or slotPlayer[i] ~= p or slotSquare[i] ~= sq then
        slotPlayer[i], slotSquare[i] = p, sq
        if sq then verify(i, sq) end
    end
end

local function scan(resync)
    local n = 0
    if mp then
        local list = getOnlinePlayers()
        for j = 0, list:size() - 1 do
            local p = list:get(j)
            if p then
                n = n + 1
                visit(n, p, resync)
            end
        end
    else
        for j = 0, getNumActivePlayers() - 1 do
            local p = getSpecificPlayer(j)
            if p then
                n = n + 1
                visit(n, p, resync)
            end
        end
    end
    for i = n + 1, slotCount do
        slotPlayer[i], slotSquare[i], slotCX[i], slotCY[i] = nil, nil, nil, nil
    end
    slotCount = n
end

local function search()
    for i = 1, slotCount do
        local cx, cy = slotCX[i], slotCY[i]
        if cx then
            for dx = -1, 1 do
                for dy = -1, 1 do
                    if tryProbe(cx + dx, cy + dy) then return true end
                end
            end
        end
    end
    return false
end

local function tick()
    if mp == nil then mp = isClient() == true end
    local resync = false
    if probeX then
        local dc = getDataChunk(probeX, probeY)
        if dc ~= probe then
            probe = dc
            resync = true
            G.resyncs = G.resyncs + 1
        end
    end
    local hadProbe = probe ~= nil
    scan(resync)
    if probe == nil then
        searchIn = searchIn - 1
        if searchIn <= 0 then
            searchIn = SEARCH_EVERY
            search()
        end
    end
    if not hadProbe and probe ~= nil then
        G.resyncs = G.resyncs + 1
        scan(true)
    end
end
G.tick = tick

local function onTick()
    if disabled then return end
    local ok, err = pcall(tick)
    if not ok then
        disabled = true
        warnOnce("error", "disabled for this session after an unexpected error: " .. tostring(err) .. ".")
    end
end

Events.OnTick.Add(onTick)
