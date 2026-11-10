--[[
MDFX_StaleWornGuard — 把穿著的東西放到地上後，身上還畫著它、快捷列欄位不消失，要重登（單人：重新讀檔）才好

【缺陷】（行號為 42.22.2 原版 Lua 與反編譯快照）
「放置物品」要不要先脫下，是客戶端在排動作的那一刻用 isEquipped 判斷的
（server/BuildingObjects/ISPlace3DItemCursor.lua:27、:38）；伺服器端的 ISDropWorldItemAction:complete
（shared/TimedActions/ISDropWorldItemAction.lua:81-91）只把物品放到地上、移出物品欄，不碰穿戴。
客戶端那一刻判斷錯（例：外觀 MOD 在畫面繪製期間把穿戴清單換成複製品，放置游標剛好在那時放下），
就只排放下、不排脫下。
另外，伺服器照收客戶端送來的穿戴清單（SyncClothingPacket.process，SyncClothingPacket.java:176-217）：
清單上有、物品欄裡找不到的編號，另建一件同編號的物件穿上（:195-204）；背包不是 Clothing，
每收到一次清單就重建一次（:193 的轉型對背包恆為 null）。客戶端還當它穿著時，放下之後送來的清單
就把伺服器的穿戴換成這種另建的物件。

單人沒有穿戴清單的封包，只有前一條路：開著那類外觀 MOD 時，放下之後自己的穿戴清單還留著它。

【後果】
物品已經在地上（或被別人撿走），伺服器與客戶端的穿戴清單卻都還留著它：背上照畫、背包給的
快捷列欄位不消失。存檔用物品欄索引記穿戴（IsoPlayer.java:1263-1264），所以重新登入（讀檔）才會好。

【本補丁】
伺服器每 CHECK_MS 看一次線上玩家的穿戴（單人：本機玩家），並記下每位玩家「穿著、而且在自己主物品欄裡」的物品編號。
下面兩種算殘留，同一個編號連兩次檢查都成立才處理（不碰脫下、換穿途中的瞬間狀態）：
- 伺服器自己知道這件在別處：getContainer() 是別的容器，或不在任何容器而有 getWorldItem()（在地上）。
- 不在任何容器、也不在地上（照客戶端清單另建的物件），而這位玩家先前穿過同編號、當時在主物品欄的真物品。
處理＝removeWornItem(item, false)：走原版 setWornItem，伺服器把新的穿戴清單送給所有客戶端
（IsoGameCharacter.java:3460-3518、IsoPlayer.java:8956-8959），客戶端照清單拿掉
（SyncClothingPacket.java:181-190）。第二個參數必須是 false：true 會在物品欄放不下時把這件
再丟到地上一次（IsoGameCharacter.java:3477-3487）。
setWornItem 會把這件移出每幀更新清單（:3464-3466）；真物品已經在別處，所以呼叫後用
IsoCell.addToProcessItems 登記回去（和 ItemContainer.AddItem 相同，不需要更新的物品自己會退出）。
可以同時穿多件的部位不呼叫：removeWornItem 在那裡不會移除（WornItems.java:54-59），還會把該部位的
第一件（不一定是這一件）移出每幀更新清單。這種與呼叫後仍在穿戴清單的（Java 端出錯）記一次、這個編號不再處理。

沒有先例的另建物件不動：繃帶與傷口模型由客戶端建立、伺服器照清單另建（IsoGameCharacter.java:17421-17429），
在伺服器上從來不在物品欄裡。死亡的角色不看。多人遊戲的客戶端不安裝，由伺服器處理。

單人掛 OnTickEvenPaused，不掛 OnTick：外觀 MOD 在 OnTick 把穿戴清單換成複製品、畫完（OnPostRender）才換回，
OnTick 裡讀到、改到的可能是複製品；OnTickEvenPaused（IngameState.java:1346）在 IsoWorld.update（:1535）
與 OnTick（:1653）之前，每幀一次更新接一次繪製（GameWindow.java:667-691），這時是真清單。

【已知限制】
- 介入要等一到兩次檢查（CHECK_MS 的一到兩倍）。
- 穿上不到一次檢查就走到殘留的另建物件（伺服器沒看過它在物品欄裡）不處理。
- 單人遊戲裡別的 MOD 若在 OnTickEvenPaused 之前就把穿戴清單換成複製品，本補丁看不到真清單、不會介入。

【診斷】
每次介入記一行（每次啟動最多 LOG_LIMIT 行，之後照樣處理、不再記）。

【退場條件】
官方讓伺服器在物品離開物品欄時一併清掉穿戴（例如 ISDropWorldItemAction:complete 自己脫下），
而且伺服器不再替物品欄裡沒有的編號另建穿戴物件。
遊戲更新後跑 `python scripts/check_vanilla_alignment.py`。
]]

if MDFX_StaleWornGuard then return end
if type(isServer) ~= "function" or type(isClient) ~= "function" or isClient() then return end

local function say(message)
    print("[MinidoracatFixes] MDFX_StaleWornGuard " .. message .. " See docs/fixes.md MDFX_StaleWornGuard")
end

-- 伺服器：線上玩家、OnTick。單人：本機玩家（含分割畫面，沒人的位置是 nil）、OnTickEvenPaused（見檔頭）
local server = isServer()
local listPlayers = getOnlinePlayers
local event = Events and Events.OnTick
if not server then
    local localPlayers = triggerEvent and getNumActivePlayers and getSpecificPlayer and {
        size = function() return getNumActivePlayers() end,
        get = function(_, i) return getSpecificPlayer(i) end,
    }
    listPlayers = localPlayers and function() return localPlayers end
    event = Events and Events.OnTickEvenPaused
end

if not (event and event.Add and listPlayers and getTimestampMs and getCell) then
    say("NOT installed: engine API shape changed; re-check docs/fixes.md.")
    return
end

local CHECK_MS = 1000
local LOG_LIMIT = 20
local RECREATED = "re-created from a client list"

local G = { removed = 0, stuck = 0 }
MDFX_StaleWornGuard = G

-- 每位線上玩家：known＝穿過、當時在主物品欄的物品編號；suspect＝上一次檢查算殘留的編號；stuck＝拿不掉的編號
local state = {}
local nextAt = 0
local disabled = false

-- 算殘留時回傳原因，其餘回 nil（不動）。先看 getWorldItem：單人放到地上的物品 getContainer() 是地面的容器，伺服器上是 nil
local function stale(inv, item, known)
    local container = item:getContainer()
    if container == inv then return nil end
    if item:getWorldItem() then return "on the ground" end
    if container then return "in another container" end
    if known[item:getID()] then return RECREATED end
    return nil
end

local function giveUp(st, id, what)
    st.stuck[id] = true
    G.stuck = G.stuck + 1
    if G.stuck == 1 then
        say("could not remove stale worn item " .. what .. "; left as is. Further such items are not logged this session.")
    end
end

local function remove(player, worn, item, why, st)
    local id = item:getID()
    local what = string.format('%s#%s (%s) from player="%s" at %d,%d,%d', tostring(item:getFullType()), tostring(id), why,
        tostring(player:getUsername()), math.floor(player:getX()), math.floor(player:getY()), math.floor(player:getZ()))
    if worn:getBodyLocationGroup():isMultiItem(worn:getLocation(item)) then return giveUp(st, id, what) end
    player:removeWornItem(item, false)
    if why ~= RECREATED then
        local cell = getCell()
        if cell then cell:addToProcessItems(item) end
    end
    if worn:contains(item) then return giveUp(st, id, what) end
    -- 單人：setWornItem 不發 Lua 的 OnClothingUpdated（IsoGameCharacter.java:3460-3505），快捷列與物品欄靠它重算
    -- （ISHotbar.lua:837-845）；照 ISUnequipAction:complete（:132）補發。多人由客戶端收到新清單時發（SyncClothingPacket.java:227）
    if not server then triggerEvent("OnClothingUpdated", player) end
    G.removed = G.removed + 1
    if G.removed <= LOG_LIMIT then
        say(string.format("removed stale worn item %s (#%d%s).", what, G.removed,
            G.removed == LOG_LIMIT and ", further events are not logged" or ""))
    end
end

local function check(player, st)
    local inv, worn = player:getInventory(), player:getWornItems()
    local suspect = {}
    if inv and worn and not player:isDead() then
        for j = worn:size() - 1, 0, -1 do
            local item = worn:getItemByIndex(j)
            if item then
                local id = item:getID()
                local why = stale(inv, item, st.known)
                if not why then
                    if item:getContainer() == inv then st.known[id] = true end
                elseif not st.stuck[id] then
                    if st.suspect[id] then remove(player, worn, item, why, st) else suspect[id] = true end
                end
            end
        end
    end
    st.suspect = suspect
end

local function tick()
    local online = {}
    local players = listPlayers()
    for i = 0, players:size() - 1 do
        local player = players:get(i)
        if player then
            local st = state[player] or { known = {}, suspect = {}, stuck = {} }
            online[player] = st
            check(player, st)
        end
    end
    state = online
end
G.tick = tick

local function onTick()
    if disabled then return end
    local now = getTimestampMs()
    -- getTimestampMs 是系統時鐘：被往回調超過一個間隔時不等它追上
    if now < nextAt and nextAt - now <= CHECK_MS then return end
    nextAt = now + CHECK_MS
    local ok, err = pcall(tick)
    if not ok then
        disabled = true
        state = {}
        say("disabled after an internal error (vanilla behaviour from here on): " .. tostring(err) .. ".")
    end
end

event.Add(onTick)
