--[[
MDFX_BasementVoidGuard — 掉到地下室的牆外：站在地下、沒有地板的空格裡，走不回來，重新登入也一樣

【缺陷】（行號為 42.22.2 反編譯快照）
原版地圖有些房子的地下室樓梯頂，正好放在上樓樓梯頂格的正下方（地下室區的 StairX／StairY 由地圖
指定，Basements.java:154-229、:314-413）。原版靠樓梯兩側的牆擋住側面；牆被大錘敲掉後，從旁邊的
房間可以直接走進樓梯頂格。IsoMovingObject.postupdate() 這時的順序出錯：
1. DoCollide() 先把「所在格」換成下一步要到的那一格（:1504），也就是樓梯頂格。
2. 所在格有樓梯時 getGlobalMovementMod() 回 0.75（:801），每幀位移超過 0.01 格就乘上它（:998-1002）。
   原本剛好跨過格線的一步變短，人實際還留在原來那一格。
3. doStairs()（:1006）照「所在格」算高度：樓梯頂格的正下方也是樓梯頂時，改用下面那道樓梯的高度
   （:277-291），高度變成略低於 0。
4. findCurrentGridSquare()（:1008）用實際位置與新高度重找所在格，得到原來那一格的正下方、地下一層。
那是地下室牆外的空格：格子存在、沒有地板（IsoChunk.java:2386-2415 只在有物件的格子周圍補空格）。
每幀位移超過 0.01 格才會發生：30 FPS 走路就會，60 FPS 偶爾，244 FPS 走路不會、衝刺會。

【後果】
角色往下掉到地下一層（摔傷），站在牆外的空格裡；牆從外面進不去，周圍沒有格子的地方走不過去。
伺服器照存這個位置，重新登入還在原地，只能等管理員傳送。

【本補丁】
每次本機玩家更新（OnPlayerUpdate）看他所在的格子：
- 有地板、樓梯或斜面（TreatAsSolidFloor）：記下這個位置。
- 在地面以下，而且這一格與正下方各層都沒有地板、樓梯、斜面：這就是牆外的空格。把人放回剛才記下
  的位置並取消掉落；記下的位置離現在超過 NEAR 格（剛登入就在牆外、被傳送進來）時，改放到正上方
  最近的地板，再不行找地面層 RADIUS 格內的地板。都找不到就照原版。
- 其他（地面以上的半空中、地下樓梯井上方）：照原版。
放回照原版 IsoGameCharacter.teleportTo 的做法設位置與上一幀位置，但座標保留小數（teleportTo 會截成
整數，IsoGameCharacter.java:16965-16979），再把所在格換成新位置那一格：同一幀稍後的掉落計算
（IsoGameCharacter.updateFalling，:9573-9616）看的是所在格，不換就會照牆外那一格繼續往下掉。
一直按住方向鍵往缺口走，會一直被放回原來那一格：那個缺口走不過去，但不會再掉下去。

【已知限制】
- 不補牆、不擋大錘、不改地圖；只在掉到牆外之後放回。
- 坐在車上、開著穿牆（noclip）的玩家不處理；格子還沒載入時不處理。
- 放回前那一幀畫面上角色會低一點點。

【診斷】
每次介入記一行（連續 EVENT_GAP_MS 內的放回算同一次；每次啟動最多 LOG_LIMIT 行，之後照樣放回、不再記）。

【退場條件】
官方讓這種位置進不去（例如 doStairs 不在側面進入時換成下方樓梯的高度），或把掉到牆外的角色放回。
判定：fixes-e2e 的 basement-void，30 FPS、牆拆掉、不載本補丁時 `BV SUMMARY … outside=0`。
遊戲更新後跑 `python scripts/check_vanilla_alignment.py`（本修復登記的是 Java 指紋）。
]]

if MDFX_BasementVoidGuard then return end

local function say(message)
    print("[MinidoracatFixes] MDFX_BasementVoidGuard " .. message .. " See docs/fixes.md MDFX_BasementVoidGuard")
end

if not (Events and Events.OnPlayerUpdate and Events.OnPlayerUpdate.Add and getCell and getTimestampMs) then
    say("NOT installed: engine API shape changed; re-check docs/fixes.md.")
    return
end

local NEAR = 2            -- 記下的位置離現在超過幾格就不用（不是剛走過來的）
local RADIUS = 2          -- 正上方沒有地板時，在地面層找幾格內
local EVENT_GAP_MS = 5000 -- 這段時間內連續的放回算同一次（按住方向鍵往缺口走）
local LOG_LIMIT = 20

local abs = math.abs

local G = { putBack = 0, events = 0 }
MDFX_BasementVoidGuard = G

local good = {}     -- [玩家編號] = { x, y, z }：上一個腳下有地板的位置
local lastAt = {}   -- [玩家編號] = 上一次放回的時間
local disabled, warnedNowhere = false, false

-- 地面以下，而且正下方各層也沒有地板、樓梯、斜面（這一格自己沒有，呼叫前已經看過）
local function isVoid(cell, sq)
    local z = sq:getZ()
    if z >= 0 then return false end
    local chunk = sq:getChunk()
    if not chunk then return false end
    local x, y = sq:getX(), sq:getY()
    for level = z - 1, chunk:getMinLevel(), -1 do
        local below = cell:getGridSquare(x, y, level)
        if below and below:TreatAsSolidFloor() then return false end
    end
    return true
end

local function standable(sq)
    return sq ~= nil and sq:TreatAsSolidFloor() and not sq:isSolid() and not sq:isSolidTrans()
end

-- 正上方最近的地板；沒有就找地面層 RADIUS 格內、由近到遠
local function floorAbove(cell, sq)
    local x, y = sq:getX(), sq:getY()
    for z = sq:getZ() + 1, 0 do
        if standable(cell:getGridSquare(x, y, z)) then return x + 0.5, y + 0.5, z end
    end
    for r = 1, RADIUS do
        for dy = -r, r do
            for dx = -r, r do
                if (abs(dx) == r or abs(dy) == r) and standable(cell:getGridSquare(x + dx, y + dy, 0)) then
                    return x + dx + 0.5, y + dy + 0.5, 0
                end
            end
        end
    end
    return nil
end

local function put(p, x, y, z)
    p:setX(x)
    p:setY(y)
    p:setZ(z)
    p:setLastX(x)
    p:setLastY(y)
    p:setLastZ(z)
    p:setFallTime(0)
    p:setLastFallSpeed(0)
    p:setbFalling(false)
    p:setCurrentSquareFromPosition()
end

local function check(p)
    if not p:isLocalPlayer() or p:getVehicle() or p:isNoClip() then return end
    local sq = p:getCurrentSquare()
    if not sq then return end
    local n = p:getPlayerNum()
    if sq:TreatAsSolidFloor() then
        local g = good[n]
        if not g then
            g = {}
            good[n] = g
        end
        g[1], g[2], g[3] = p:getX(), p:getY(), p:getZ()
        return
    end
    local cell = getCell()
    if not cell or not isVoid(cell, sq) then return end

    local x, y, z = p:getX(), p:getY(), p:getZ()
    local g = good[n]
    local tx, ty, tz, how
    if g and abs(g[1] - x) <= NEAR and abs(g[2] - y) <= NEAR then
        tx, ty, tz, how = g[1], g[2], g[3], "put back to %.2f,%.2f,%.2f, the last position on a floor"
    else
        tx, ty, tz = floorAbove(cell, sq)
        how = "moved to %.2f,%.2f,%.2f, the nearest floor above"
    end
    if not tx then
        if not warnedNowhere then
            warnedNowhere = true
            say(string.format("player %d is below ground at %d,%d,%d with no floor here or below, and no floor was found above or within %d squares at ground level; left alone.",
                n, sq:getX(), sq:getY(), sq:getZ(), RADIUS))
        end
        return
    end

    put(p, tx, ty, tz)
    G.putBack = G.putBack + 1
    local now = getTimestampMs()
    local last = lastAt[n]
    lastAt[n] = now
    if last and now - last < EVENT_GAP_MS then return end
    G.events = G.events + 1
    if G.events <= LOG_LIMIT then
        say(string.format("player %d was below ground at %.2f,%.2f,%.2f (square %d,%d,%d) with no floor here or below; " .. how .. " (#%d%s).",
            n, x, y, z, sq:getX(), sq:getY(), sq:getZ(), tx, ty, tz, G.events,
            G.events == LOG_LIMIT and ", further events are not logged" or ""))
    end
end
G.check = check

local function onPlayerUpdate(p)
    if disabled then return end
    local ok, err = pcall(check, p)
    if not ok then
        disabled = true
        say("disabled after an internal error (vanilla behaviour from here on): " .. tostring(err) .. ".")
    end
end

Events.OnPlayerUpdate.Add(onPlayerUpdate)
