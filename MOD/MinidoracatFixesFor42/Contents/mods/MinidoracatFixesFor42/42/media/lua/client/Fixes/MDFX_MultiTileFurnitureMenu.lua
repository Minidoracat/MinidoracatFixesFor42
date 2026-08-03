--[[
    MDFX_MultiTileFurnitureMenu —— 多格家具缺角殘骸的右鍵清除選項

    斷根（伺服器端 MDFX_MultiTileFurniture）只能防止新的殘骸產生；
    世界上已經卡住的舊殘骸需要有人手動清。原版對殘缺群組是完全靜默的：
    大槌打不掉、拆解不了、搬不走，也不給任何提示，玩家只會覺得「壞掉了」。

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

local function requestCleanup(playerObj, sq, present)
    if isClient() then
        sendClientCommand(playerObj, "MDFX", "cleanupBrokenFurniture",
            { x = sq:getX(), y = sq:getY(), z = sq:getZ() })
    else
        -- 單人：沒有伺服器 lane，直接本地清
        MDFX_SpriteGrid.removeMembers(present)
    end
end

function MDFX_MultiTileFurnitureMenu.onFill(playerNum, context, worldobjects, test)
    if test then return end
    local playerObj = getSpecificPlayer(playerNum)
    if not playerObj then return end

    for _, obj in ipairs(worldobjects) do
        local broken, present = MDFX_SpriteGrid.inspect(obj)
        if broken then
            local sq = obj:getSquare()
            local dx, dy = sq:getX() - playerObj:getX(), sq:getY() - playerObj:getY()
            if (dx * dx + dy * dy) <= (MAX_DIST * MAX_DIST) then
                context:addOption(getText("ContextMenu_MDFX_ClearBrokenFurniture"), nil, function()
                    requestCleanup(playerObj, sq, present)
                end)
            end
            return   -- 一格上不會有兩組殘骸值得分開列
        end
    end
end

Events.OnFillWorldObjectContextMenu.Add(MDFX_MultiTileFurnitureMenu.onFill)
