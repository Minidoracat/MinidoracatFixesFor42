--[[
    MDFX_MultiTileFurniture —— 多格家具缺角殘骸（伺服器端斷根＋清除執行）

    症狀
      野餐桌／鋼琴／鍛造爐等多格家具被大槌砸、被搬運撿取、或被殭屍打壞後，
      地上留下一兩格「殘骸」。此後大槌打不掉、拆解不了、也搬不走，永久卡在那裡。

    根因（MP）
      客戶端破壞／撿取時本地整組移除，送出的封包卻只帶單格 (x,y,z,index)。
      伺服器端 RemoveItemFromSquarePacket.removeItemFromMap 只對
      GARAGE_DOOR / DOUBLE_DOOR 做整組展開（:169-171），其餘一律單格刪
      —— 存檔於是只少一格。三條路徑收斂於此：MP 大槌、MP 搬運撿取、
      殭屍打壞玩家搬過的家具。

      殘骸鎖死則是另一半：IsoObjectUtils.getSpriteGridMultiTileObjects 是
      all-or-nothing，缺任一格就 return false，safelyRemoveTileObjectFromSquare
      回 -1、什麼都不刪且完全靜默；Lua 端 ISMoveableSpriteProps 的搬運／拆解
      gate 同構，連 movables cheat 都繞不過。

    為什麼是「延後確認」而不是當場展開
      OnObjectAboutToBeRemoved 對所有移除都會觸發，包含原版蓄意的單格手術：
      MOFeedingTrough.lua:21 在地圖載入時單格移除再替換成 IsoFeedingTrough，
      而餵食槽本身就用 sprite grid（IsoFeedingTrough.java:79-87）。當場展開
      會在 chunk 載入時把餵食槽的另一半刪掉，直接弄壞餵食槽與兔籠。

      所以這裡只記下群組錨點，延後 CONFIRM_TICKS 再回頭掃一次，**仍然殘缺才清**：
        - 原版替換：同一幀內就把該格補回同 sprite 的物件 → 掃描時完整 → 不動
        - 大槌／撿取／殭屍：缺角永遠補不回來 → 清掉剩餘成員
      順帶讓「清殘骸」與「斷根」共用同一套判準與同一段執行碼。

    移除手法
      square:transmitRemoveItemFromSquare(obj, false) —— 兩參數非 safe 版
      繞過整組檢查（IsoGridSquare.java:6319），原版自己就在用
      （MOHutch.lua:99、MOFeedingTrough.lua:21）。在伺服器端會走
      GameServer.RemoveItemFromMap：廣播給相關客戶端＋伺服器自刪，同步正確。
]]

if not isServer() then return end

require "Fixes/MDFX_SpriteGrid"

MDFX_MultiTileFurniture = MDFX_MultiTileFurniture or {}

-- 延後多久回頭確認。原版的移除→替換在同一幀內完成，1 tick 就夠；
-- 給到約一秒是留餘裕給其他 MOD 的延後替換流程。
local CONFIRM_TICKS = 60

-- 玩家能要求清除的最遠距離（格）。伺服器端信任邊界：
-- 座標來自客戶端，必須自行驗證，不能直接照著刪。
local MAX_CLEANUP_DIST = 12

local pending = {}        -- key -> { grid, x, y, z, ticks }
local pendingCount = 0
local sweeping = false    -- 重入 guard：自己刪 sibling 時不再排隊

local function report(err)
    print("[MinidoracatFixes] MDFX_MultiTileFurniture 失敗: " .. tostring(err))
end

--- 掃一組，仍殘缺才清。回傳清掉幾個。
function MDFX_MultiTileFurniture.sweepGroup(g)
    local present, complete = MDFX_SpriteGrid.scan(g.grid, g.x, g.y, g.z)
    if complete or #present == 0 then return 0 end
    return MDFX_SpriteGrid.removeMembers(present)
end

local function onObjectAboutToBeRemoved(obj)
    if sweeping then return end
    if not obj or not obj:hasSpriteGrid() then return end
    -- 物件還在 square 上，趁現在把錨點算出來；移除後就算不出來了
    local ox, oy, oz = MDFX_SpriteGrid.originOf(obj)
    if not ox then return end
    local key = ox .. "," .. oy .. "," .. oz
    if not pending[key] then pendingCount = pendingCount + 1 end
    pending[key] = { grid = obj:getSpriteGrid(), x = ox, y = oy, z = oz, ticks = CONFIRM_TICKS }
end

local function onTick()
    if pendingCount == 0 then return end
    local due = nil
    for key, g in pairs(pending) do
        g.ticks = g.ticks - 1
        if g.ticks <= 0 then
            due = due or {}
            due[#due + 1] = g
            pending[key] = nil
            pendingCount = pendingCount - 1
        end
    end
    if not due then return end

    sweeping = true
    for _, g in ipairs(due) do
        local ok, err = pcall(MDFX_MultiTileFurniture.sweepGroup, g)
        if not ok then report(err) end
    end
    sweeping = false   -- pcall 在內層，這裡保證會執行到
end

--- 客戶端右鍵「清除卡住的家具殘骸」。座標不可信，全部重驗。
local function onClientCommand(module, command, player, args)
    if module ~= "MDFX" or command ~= "cleanupBrokenFurniture" then return end
    if not player or not args or not args.x then return end

    local sq = getSquare(args.x, args.y, args.z)
    if not sq then return end

    -- 距離驗證：只准清自己構得到的地方
    local dx, dy = sq:getX() - player:getX(), sq:getY() - player:getY()
    if (dx * dx + dy * dy) > (MAX_CLEANUP_DIST * MAX_CLEANUP_DIST) then return end
    if math.abs(sq:getZ() - player:getZ()) > 1 then return end

    -- 群組驗證：只准清真的殘缺的組，不能拿來拆完好的家具
    local objs = sq:getObjects()
    for i = 0, objs:size() - 1 do
        local obj = objs:get(i)
        local broken, present = MDFX_SpriteGrid.inspect(obj)
        if broken then
            sweeping = true
            local ok, err = pcall(MDFX_SpriteGrid.removeMembers, present)
            sweeping = false
            if not ok then report(err) end
            return
        end
    end
end

Events.OnObjectAboutToBeRemoved.Add(onObjectAboutToBeRemoved)
Events.OnTick.Add(onTick)
Events.OnClientCommand.Add(onClientCommand)
