--[[
    MDFX_MultiTileFurniture —— 多格家具缺角殘骸的清除（伺服器端權威執行）

    症狀
      野餐桌／鋼琴／鍛造爐等多格家具被大槌砸、被搬運撿取、或被殭屍打壞後，
      地上留下一兩格「殘骸」。此後大槌打不掉、拆解不了、也搬不走，
      而且完全沒有任何提示，永久卡在那裡。

    根因（MP）
      客戶端破壞／撿取時本地整組移除，送出的封包卻只帶單格 (x,y,z,index)。
      伺服器端 RemoveItemFromSquarePacket.removeItemFromMap 只對
      GARAGE_DOOR / DOUBLE_DOOR 做整組展開（:169-171），其餘一律單格刪
      —— 存檔於是只少一格。

      殘骸鎖死則是另一半：IsoObjectUtils.getSpriteGridMultiTileObjects 是
      all-or-nothing，缺任一格就 return false，safelyRemoveTileObjectFromSquare
      回 -1、什麼都不刪且完全靜默；Lua 端搬運／拆解 gate 同構，
      連 movables cheat 都繞不過。

    範圍：只做「清殘骸」，不做「斷根」
      曾實作過自動斷根（掛 OnObjectAboutToBeRemoved、延後 60 tick 確認後清掉剩餘成員），
      但那條路走不通並已移除。原因是它分不出「永久殘骸」與「合法但延遲完成的
      remove-and-replace」——PZ 從未承諾 replacement 會在固定時間內完成
      （MOFeedingTrough.lua:15 目前恰好同幀完成，但那不是 API 契約）。
      獨立審查用延遲替換重現了「誤刪三個仍有效的成員」，而當時的測試全綠。
      沒有行為人、沒有操作意圖、只靠事後掃描，無法證明零資料損失。

      所以新的缺角仍會產生，但玩家隨時能用右鍵清掉。要真正斷根，該在 Java 端
      removeItemFromMap 比照車庫門直接展開——那裡才拿得到明確的操作意圖。

    移除手法
      square:transmitRemoveItemFromSquare(obj, false) —— 兩參數非 safe 版
      繞過整組檢查（IsoGridSquare.java:6319），原版自己就在用
      （MOHutch.lua:99、MOFeedingTrough.lua:21）。在伺服器端會走
      GameServer.RemoveItemFromMap：廣播給相關客戶端＋伺服器自刪，同步正確。
]]

if not isServer() then return end

require "Fixes/MDFX_SpriteGrid"

MDFX_MultiTileFurniture = MDFX_MultiTileFurniture or {}

-- 玩家能要求清除的最遠距離（格）。這是**防遠端操作的上界**，不是「伸手構得到」——
-- 原版右鍵本來就能在一段距離外點物件。真正擋住誤刪的是內容物、安全屋與殘缺判定，
-- 這裡只負責讓惡意客戶端無法對地圖另一端下手。
local MAX_CLEANUP_DIST = 12

local function report(err)
    print("[MinidoracatFixes] MDFX_MultiTileFurniture 失敗: " .. tostring(err))
end

--- 客戶端右鍵「清除卡住的家具殘骸」。
--- 這是信任邊界：module／command／座標／玩家狀態全部由客戶端送來，一律重驗，
--- 而且最終能不能刪由伺服器自己重新掃描決定，不看客戶端說了什麼。
local function handleCleanup(player, args)
    -- 型別驗證：畸形封包不能讓 handler 在 event 迴圈裡拋例外
    if type(args) ~= "table" then return end
    local x, y, z = args.x, args.y, args.z
    if type(x) ~= "number" or type(y) ~= "number" or type(z) ~= "number" then return end
    if not player or player:isDead() then return end

    local sq = getSquare(x, y, z)
    if not sq then return end

    -- 距離驗證
    local dx, dy = sq:getX() - player:getX(), sq:getY() - player:getY()
    if (dx * dx + dy * dy) > (MAX_CLEANUP_DIST * MAX_CLEANUP_DIST) then return end
    if math.abs(sq:getZ() - player:getZ()) > 1 then return end

    -- 群組驗證：inspect 已涵蓋「不得未載入」「不得錨點模糊」「不得完好」
    -- 「不得有內容物」，所以這條指令拆不掉完好家具，也吃不掉玩家的儲物
    local objs = sq:getObjects()
    for i = 0, objs:size() - 1 do
        local broken, present = MDFX_SpriteGrid.inspect(objs:get(i))
        if broken then
            -- 授權驗證必須放在拿到 present 之後，而且要逐一檢查**每個待刪成員**。
            -- 原版右鍵選單本身被 safehouseAllowInteract 擋著
            -- （ISWorldObjectContextMenu.lua:211），但那是客戶端 gate，惡意封包繞得過；
            -- 而安全屋是矩形範圍，只驗指令指定的那一格，就會出現「站在屋外對屋內
            -- sibling 下手」的繞道。
            if MDFX_SpriteGrid.isSafehouseBlocked(present, player) then return end

            -- 逐件移除不是原子操作：中途出錯只能記錄，無法 rollback，
            -- 可能留下部分刪除的狀態。PZ 沒有提供群組原子移除的 API。
            local ok, err = pcall(MDFX_SpriteGrid.removeMembers, present)
            if not ok then report(err) end
            return
        end
    end
end

local function onClientCommand(module, command, player, args)
    if module ~= "MDFX" or command ~= "cleanupBrokenFurniture" then return end
    local ok, err = pcall(handleCleanup, player, args)
    if not ok then report(err) end
end

Events.OnClientCommand.Add(onClientCommand)
