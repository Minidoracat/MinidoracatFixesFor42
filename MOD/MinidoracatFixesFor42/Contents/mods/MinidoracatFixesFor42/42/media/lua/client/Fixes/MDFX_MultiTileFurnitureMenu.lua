--[[
    MDFX_MultiTileFurnitureMenu —— 多格家具缺角殘骸的右鍵清除選項

    本 MOD **不做斷根**（理由見 server 端檔頭與 docs/fixes.md），所以新的缺角
    仍會產生。清除完全由玩家手動觸發——這也正是它安全的原因：有明確的行為人，
    才有距離與安全屋授權可驗。

    原版對殘缺群組是完全靜默的：大槌打不掉、拆解不了、搬不走，也不給任何提示，
    玩家只會覺得「壞掉了」。

    這裡在右鍵選單補一個「清除卡住的家具殘骸」，只在該物件確實屬於殘缺
    sprite-grid 群組時才出現（判準與原版鎖死用的那道 gate 完全相同）。

    MP 下經 sendClientCommand 交由伺服器權威執行，伺服器端會重驗距離與殘缺狀態
    ——座標來自客戶端，不可信。單人則直接本地執行。
]]

require "Fixes/MDFX_SpriteGrid"

MDFX_MultiTileFurnitureMenu = MDFX_MultiTileFurnitureMenu or {}

-- 與伺服器端 MAX_CLEANUP_DIST 一致；這裡只是不要顯示構不到的選項，
-- 真正的把關在伺服器端。
local MAX_DIST = 12

--- 點下去才重新判定，不能沿用建立選單當下抓到的 present。
--- 選單建好到玩家點擊之間世界可能已經變了（別人拆了、chunk 卸載、容器被塞東西），
--- 拿舊清單去刪就是 TOCTOU——單人沒有伺服器那道重驗，會直接刪錯東西。
local function requestCleanup(playerObj, obj)
    local stillBroken, present = MDFX_SpriteGrid.inspect(obj)
    if not stillBroken then return end
    -- 與伺服器端同一套 policy，避免「選項點得下去、伺服器靜默拒絕」
    if MDFX_SpriteGrid.isSafehouseBlocked(present, playerObj) then return end
    local sq = obj:getSquare()
    if not sq then return end

    if isClient() then
        -- MP：座標交給伺服器，最終判定以伺服器重新掃描為準
        sendClientCommand(playerObj, "MDFX", "cleanupBrokenFurniture",
            { x = sq:getX(), y = sq:getY(), z = sq:getZ() })
    else
        -- 單人：沒有伺服器 lane，用剛剛重新掃到的清單直接清
        MDFX_SpriteGrid.removeMembers(present)
    end
end

function MDFX_MultiTileFurnitureMenu.onFill(playerNum, context, worldobjects, test)
    if test then return end
    local playerObj = getSpecificPlayer(playerNum)
    if not playerObj then return end

    for _, obj in ipairs(worldobjects) do
        -- 這裡的判定只決定「要不要顯示選項」；真正的刪除依據在點擊時重新掃描
        local broken, present = MDFX_SpriteGrid.inspect(obj)
        if broken and not MDFX_SpriteGrid.isSafehouseBlocked(present, playerObj) then
            local sq = obj:getSquare()
            local dx, dy = sq:getX() - playerObj:getX(), sq:getY() - playerObj:getY()
            if (dx * dx + dy * dy) <= (MAX_DIST * MAX_DIST) then
                context:addOption(getText("ContextMenu_MDFX_ClearBrokenFurniture"), nil, function()
                    requestCleanup(playerObj, obj)
                end)
            end
            return   -- 一格上不會有兩組殘骸值得分開列
        end
    end
end

Events.OnFillWorldObjectContextMenu.Add(MDFX_MultiTileFurnitureMenu.onFill)
