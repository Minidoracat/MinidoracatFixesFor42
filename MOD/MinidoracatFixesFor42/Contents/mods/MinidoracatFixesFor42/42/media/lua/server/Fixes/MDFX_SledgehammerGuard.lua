--[[
MDFX_SledgehammerGuard — 大錘拆除的兩個缺口（伺服器與單人）：
  一、缺片的多格物件用大錘拆不掉（原版）
  二、強化伺服器端驗證：大錘拆除照原版 42.22 的伺服器規則再檢查一次

【缺陷一】（行號為 42.22.2 原版 Lua 與反編譯快照）
大錘動作完成時（shared/TimedActions/ISDestroyStuffAction.lua:111-350，多人遊戲由伺服器執行），一般物件走
:330 的 `self.item:getSquare():transmitRemoveItemFromSquare(self.item)`。單參數版固定要求「安全移除」
（IsoGridSquare.java:5929-5931）：物件的圖塊屬於多格圖塊組（SpriteGrid）時，引擎要先在周圍找齊整組的每一片
（IsoObjectUtils.getSpriteGridMultiTileObjects，IsoObjectUtils.java:115-155），缺任何一片就回 -1、什麼都不移除
（伺服器 IsoGridSquare.java:5938-5956；單人 IsoObjectUtils.safelyRemoveTileObjectFromSquare :32-41）。
警告只在除錯模式印，`complete` 不看回傳值，照樣往下跑（大錘照常擲耐久）、回 true。
缺片的多格物件來自世界生成（只生成一半的 2×2 巨石 boulders_16～31）或其他只移除單片的途徑。
後果：大錘游標是綠的、動作跑完、大錘照常耗損，物件留在原地，沒有任何訊息；每一片都一樣，永遠拆不掉。

【缺陷二】原版 42.22 在 `complete` 開頭有兩道伺服器端的規則（:116-130：要帶著大錘而且離目標夠近、
伺服器選項 SledgehammerOnlyInSafehouse 開著時要在允許自己用的安全屋裡）。整支取代 `complete` 的 MOD
不一定有這兩道。細節屬攻擊面分析，依家族保密規則只寫在本機知識庫（fixes-dev 的 references/world-objects.md）。

【本補丁】包裝 `ISDestroyStuffAction.complete`：

前：照原版 :116-130 的寫法檢查那兩道規則，不過就回 false、不呼叫原函式（原版在這兩道之前沒有任何作用，
    所以原函式是原版時結果相同）。目標是 nil 時不檢查，交給原函式（原版 :112-114 自己回 false）。
    每次拒絕記一行（每個連線每次開機最多 LOG_LIMIT 行）。檢查本身出錯時印一次、原樣重拋，不呼叫原函式：檢查照原版的寫法，
    出錯時原版的 `complete` 在同一處也會出錯；整支取代的版本卻可能不檢查就拆。
後（缺陷一）：
1. 原函式回傳值不是 true（原版或別的 MOD 判定不能拆）就照回，不做任何事。
2. 回 true 而目標（`self.item`）已經不在格子上＝原版移掉了（正常情況），不做任何事。
3. 目標還在格子上、它的圖塊屬於多格圖塊組、物件沒有 component，而且**確定缺片**：照引擎找整組的走法
   （IsoObjectUtils.java:115-155）看這一組佔的每一格，有一格載入了、圖塊組在那個位置有圖塊、格子上卻沒有它才算。
   格子沒載入不算（分不出是缺片還是沒載入；0.4.0 移出的 MDFX_MultiTileFurniture 就是把沒載入當成缺片）。
4. 用原版同一個呼叫再問引擎一次：引擎找得齊就照原版整組移除；仍回 -1 才改用兩個參數的
   `transmitRemoveItemFromSquare(item, false)` 只移除被敲的那一片（原版 server/Map/MapObjects/MOFeedingTrough.lua:21、
   MOHutch.lua:99 同寫法；伺服器走 GameServer.RemoveItemFromMap，會送給客戶端），移除後讀回確認才印診斷行。
   其餘的片照樣一片一片敲。
目標不是多格圖塊的不管：原版回 true 而物件還在，是別的原因（例：別的 MOD 把轉角牆原地換成半面牆）。
整組都在的不管：回 true 不代表內層真的要求過移除（別的 MOD 可能刻意留著它），沒有缺片的證據就不碰。
有 component 的物件（建造選單蓋的設施、裝液體或製作中材料的物件）不管：整組找不齊時原版只倒了被敲那一片自己的容器，
沒倒 component 的內容（:132 `dumpContentsInSquare` → IsoObjectUtils.java:161-180 提早返回），單片移除會連內容一起刪。
自己那一段出錯、或單片移除之後物件還在，就印一次、照回原版的結果。多人遊戲的客戶端不安裝（`complete` 在伺服器跑）。

【取捨】
- 不順手移除同一組剩下的其他片：相鄰兩組同款的殘片分不出誰是誰的，只動玩家敲的那一片。
- 只處理沒有 component 的多格圖塊（巨石、一般家具）。有 component 的多格設施缺片時照原版拆不掉：沒有回報、沒有實測，
  要處理得先把 component 的內容倒出來。
- 拒絕的 log 以連線計額度（同 MDFX_HealthCheatPermission）：一個人洗版蓋不掉別人的拒絕行。目標已經不在格子上
  （別人先拆掉了）的拒絕不記：原版同樣回 false，不是違規。
- 除錯模式下背包沒有大錘時，原版的檢查會建一把臨時大錘（:17-19）；本補丁先檢查一次，等於多建一把，只在除錯模式。

【安裝機制】
放 server/：單人與伺服器都載入，而且排在所有 MOD 的 shared/ 之後（NicksSledgehammerFix 在 shared/ 整支取代
`complete`，本檔包到的是它的版本）。sentinel 存 wrapper 自身引用：比本檔晚載入的 server/ 檔整支替換時，
OnInitGlobalModData 復查再包一層。用這個事件是因為單人在進場時才載 server/（GameLoadingState.java:149），
OnGameBoot 早在主選單就觸發過了；OnInitGlobalModData 在世界初始化時觸發（IsoWorld.java:2022），單人與伺服器都在所有 Lua 載完之後。
開服之後才包上來的 MOD（例：安全屋的權限檢查）在外層：它拒絕時原函式與本補丁都不會跑。

【退場條件】
缺陷一：官方讓缺片的多格物件拆得掉（`transmitRemoveItemFromSquare` 對找不齊的整組不再回 -1，或大錘改用別的移除方式）。
到時原版在第 2 步就移掉了，「後」自動不介入（診斷行不再出現）。
缺陷二：常見的整支取代 `complete` 的 MOD 都帶上原版 42.22 的那兩道規則。原函式是原版時「前」與原版同結果，留著無害。
遊戲更新後跑 `python scripts/check_vanilla_alignment.py`。
]]

if type(isClient) ~= "function" or isClient() then return end

local NAME = "MDFX_SledgehammerGuard"
local LOG_LIMIT = 20 -- 每個連線每次開機記幾行拒絕

local warned = {}
local function warnOnce(key, message)
    if warned[key] then return end
    warned[key] = true
    print("[MinidoracatFixes] " .. NAME .. " " .. message .. " See docs/fixes.md " .. NAME)
end

-- 原版 42.22.2 伺服器端的兩道規則（ISDestroyStuffAction.lua:116-130），寫法照原版。nil＝放行，否則回拒絕原因
local function refusal(action)
    local item, character = action.item, action.character
    if item == nil then return nil end -- 原版 :112-114 自己回 false；角色是 nil 時和原版一樣在下一行出錯
    if not character:isBuildCheat() and not action:hasSledgehammerInRange(character, item) then
        return "no usable sledgehammer within reach"
    end
    if getServerOptions():getBoolean("SledgehammerOnlyInSafehouse") then
        local role = character:getRole()
        if not (role and role:hasCapability(Capability.UseBuildCheat)) then
            local safe = SafeHouse.isSafeHouse(item:getSquare(), nil, false)
            if not (safe and safe:playerAllowed(character)) then return "SledgehammerOnlyInSafehouse outside an allowed safehouse" end
        end
    end
    return nil
end

-- SteamID 是 long，轉成 Lua 會捨入（16 的倍數），從 1e14 起 tostring 是科學記號：拆兩半拼出十進位（同 MDFX_HealthCheatPermission）
local function steamText(player)
    local v = player:getSteamID()
    if type(v) ~= "number" or v <= 0 then return "none" end
    local hi = math.floor(v / 1e9)
    local lo = tostring(math.floor(v - hi * 1e9))
    return (hi > 0 and tostring(hi) .. string.rep("0", 9 - #lo) or "") .. lo
end

local function clip(v)
    return (string.sub((string.gsub(tostring(v), "[%c\"]", "?")), 1, 32))
end

local logged = {} -- 連線（SteamID|onlineID，非 Steam 伺服器 onlineID|名稱）→ 已記的拒絕行數
local function logRefusal(action, why)
    local item, p = action.item, action.character
    if item:getObjectIndex() == -1 then return end -- 目標已經不在格子上：原版也回 false，不是違規
    local sid, id = steamText(p), tostring(p:getOnlineID())
    local who = "player=\"" .. clip(p:getUsername()) .. "\" onlineID=" .. id .. " steamid~" .. sid
    local key = sid ~= "none" and (sid .. "|" .. id) or (id .. "|" .. tostring(p:getUsername()))
    local n = (logged[key] or 0) + 1
    logged[key] = n
    if n > LOG_LIMIT + 1 then return end
    if n > LOG_LIMIT then
        print("[MinidoracatFixes] " .. NAME .. " reached LOG_LIMIT for " .. who
            .. "; further refused sledgehammer hits from this connection are not logged this session. See docs/fixes.md " .. NAME)
        return
    end
    local sq, sprite = item:getSquare(), item:getSprite()
    print("[MinidoracatFixes] " .. NAME .. " refused a sledgehammer hit (" .. why .. ") on " .. clip(sprite and sprite:getName())
        .. " at " .. sq:getX() .. "," .. sq:getY() .. "," .. sq:getZ() .. " by " .. who .. " (#" .. n .. "). See docs/fixes.md " .. NAME)
end

-- 照引擎找整組的走法看每一格：格子載入了、圖塊組在那個位置有圖塊、格子上卻沒有它＝確定缺片。沒載入的格子不算證據。
-- 圖塊組裡沒有圖塊的位置也不算：引擎對這種圖塊組一律算找不齊（verifyObject 拿物件的圖塊和 null 比），完整的也一樣，
-- 那是另一件事，這裡不把完整的物件拆成單片。
local function hasMissingPiece(item, sq)
    local sprite, grid, cell = item:getSprite(), item:getSpriteGrid(), getCell()
    local x0 = sq:getX() - grid:getSpriteGridPosX(sprite)
    local y0 = sq:getY() - grid:getSpriteGridPosY(sprite)
    local z0 = sq:getZ() - grid:getSpriteGridPosZ(sprite)
    for z = 0, grid:getLevels() - 1 do
        for x = 0, grid:getWidth() - 1 do
            for y = 0, grid:getHeight() - 1 do
                local want = grid:getSprite(x, y, z)
                local other = want ~= nil and cell:getGridSquare(x0 + x, y0 + y, z0 + z) or nil
                if other ~= nil then
                    local objects, found = other:getObjects(), false
                    for i = 0, objects:size() - 1 do
                        if objects:get(i):getSprite() == want then
                            found = true
                            break
                        end
                    end
                    if not found then return true end
                end
            end
        end
    end
    return false
end

local function failed(detail)
    warnOnce("error", "could not check for or remove a leftover piece; vanilla result kept: " .. tostring(detail) .. ".")
end

local function afterComplete(action)
    local item = action.item
    if item == nil or item:getObjectIndex() == -1 then return end
    if item:getSpriteGrid() == nil or item:componentSize() > 0 then return end
    local sq = item:getSquare()
    if not hasMissingPiece(item, sq) then return end
    if sq:transmitRemoveItemFromSquare(item) ~= -1 then return end
    local sprite = item:getSprite()
    local where = tostring(sprite and sprite:getName()) .. " at " .. sq:getX() .. "," .. sq:getY() .. "," .. sq:getZ()
    sq:transmitRemoveItemFromSquare(item, false)
    -- Java 端拋例外時 Lua 只拿到 nil，要讀回才知道有沒有移除。不用 error()：Kahlua 連 pcall 接住的錯也每次印堆疊
    if item:getObjectIndex() ~= -1 then return failed(where .. " is still on its square after the single-piece removal") end
    warnOnce("removed", "vanilla left " .. where .. " standing after a sledgehammer hit (a multi-tile object with missing pieces);"
        .. " removed that piece. Further ones not logged this session.")
end

local function install()
    local cls = ISDestroyStuffAction
    if type(cls) ~= "table" or type(cls.complete) ~= "function" then
        warnOnce("shape", "NOT installed: vanilla ISDestroyStuffAction shape changed; re-check docs/fixes.md.")
        return
    end
    if cls[NAME] == cls.complete then return end

    local original = cls.complete

    local function wrapper(self, ...)
        local checked, why = pcall(refusal, self)
        if not checked then
            -- 這裡只重拋錯誤值，原始堆疊引擎已先印過；全文先印進 log 再單參重拋（同 MDFX_ReloadSpeedGuard）
            warnOnce("check", "could not check the server rules for a sledgehammer hit; NOT masking it (re-throwing): " .. tostring(why) .. ".")
            error(why)
        elseif why then
            if not pcall(logRefusal, self, why) then warnOnce("log", "could not log a refused sledgehammer hit.") end
            return false
        end
        local result = original(self, ...)
        if result == true then
            local ok, err = pcall(afterComplete, self)
            if not ok then failed(err) end
        end
        return result
    end

    cls.complete = wrapper
    cls[NAME] = wrapper
end

install()
if Events and Events.OnInitGlobalModData then
    Events.OnInitGlobalModData.Add(install)
end
