--[[
    MDFX_SpriteGrid —— 多格家具（sprite grid）群組掃描共用工具

    忠實移植 zombie.iso.IsoObjectUtils#getSpriteGridMultiTileObjects 的判準：
    走遍 sprite grid 的整個矩形，逐格要求「該格存在 sprite 與該格預期完全相符的物件」，
    任一格缺席即整組視為殘缺。用同一套判準，本 MOD 認定的「殘缺」才會與原版
    鎖死搬運／拆解的那道 gate 完全一致——不會多清也不會漏清。
]]

MDFX_SpriteGrid = MDFX_SpriteGrid or {}

--- 群組錨點（grid 座標 0,0,0 那一格）的世界座標。
--- 物件仍在 square 上時才能算，所以移除前就要先取。
--- 回傳：x, y, z 或 nil
function MDFX_SpriteGrid.originOf(obj)
    if not obj or not obj:hasSpriteGrid() then return nil end
    local grid = obj:getSpriteGrid()
    local sprite = obj:getSprite()
    local sq = obj:getSquare()
    if not grid or not sprite or not sq then return nil end
    return sq:getX() - grid:getSpriteGridPosX(sprite),
           sq:getY() - grid:getSpriteGridPosY(sprite),
           sq:getZ() - grid:getSpriteGridPosZ(sprite)
end

--- 掃描以 (ox,oy,oz) 為錨點的整組。
--- getSquareFn 可注入是為了離線測試。
--- 回傳：present（現存成員陣列）, complete（是否完整）, unknown（有格子無法判定）
---
--- ⚠ complete=false 與 unknown=true 必須分開，這是本檔最重要的一件事。
--- Java 原版的 getSpriteGridMultiTileObjects 在「格子沒載入」與「格子缺成員」
--- 兩種情況都回 false——但它是拿來當**許可 gate**（無法確認就不准移除，fail-closed）。
--- 本 MOD 反過來拿判準當**刪除依據**，若照抄就會把「還沒載入的格子」當成缺角，
--- 進而刪掉跨 chunk 邊界的完好家具。所以無法判定一律走 unknown，永不刪除。
function MDFX_SpriteGrid.scan(grid, ox, oy, oz, getSquareFn)
    getSquareFn = getSquareFn or getSquare
    local present = {}
    local complete = true
    local unknown = false
    for z = 0, grid:getLevels() - 1 do
        for x = 0, grid:getWidth() - 1 do
            for y = 0, grid:getHeight() - 1 do
                local expected = grid:getSprite(x, y, z)
                local sq = getSquareFn(ox + x, oy + y, oz + z)
                if not sq then
                    -- 該格未載入：成員在不在根本不知道，不能算成缺角
                    unknown = true
                elseif not expected then
                    -- 稀疏 grid（該格沒有預期 sprite）：原版會讓這種家具永遠撿不起來，
                    -- 我們則是不准刪——同樣 fail-closed，寧可留著也不誤刪
                    unknown = true
                else
                    local found = nil
                    local objs = sq:getObjects()
                    for i = 0, objs:size() - 1 do
                        local o = objs:get(i)
                        if o:getSprite() == expected then
                            found = o
                            break
                        end
                    end
                    if found then
                        present[#present + 1] = found
                    else
                        complete = false
                    end
                end
            end
        end
    end
    return present, complete, unknown
end

--- 群組裡是否還有裝著東西的容器。
--- 原版 RemoveTileObject 完全不管容器，移除就等於把內容物一起毀掉。
--- 玩家自己動手拆是他家的事，但本 MOD 的自動清掃不能靜默吃掉玩家的儲物。
function MDFX_SpriteGrid.hasStoredItems(present)
    for _, obj in ipairs(present) do
        local container = obj:getContainer()
        if container and container:getItems() and container:getItems():size() > 0 then
            return true
        end
    end
    return false
end

--- 這個物件是否屬於一個「可以安全清除」的殘缺群組。
--- 回傳：broken, present, ox, oy, oz
function MDFX_SpriteGrid.inspect(obj, getSquareFn)
    local ox, oy, oz = MDFX_SpriteGrid.originOf(obj)
    if not ox then return false end
    local present, complete, unknown = MDFX_SpriteGrid.scan(obj:getSpriteGrid(), ox, oy, oz, getSquareFn)
    if unknown or complete or #present == 0 then return false, present, ox, oy, oz end
    if MDFX_SpriteGrid.hasStoredItems(present) then return false, present, ox, oy, oz end
    return true, present, ox, oy, oz
end

--- 移除一組現存成員。回傳實際移除數量。
--- transmitRemoveItemFromSquare 的兩參數非 safe 版繞過整組檢查
--- （IsoGridSquare.java:6319，原版先例 MOHutch.lua:99）：
---   伺服器端 → GameServer.RemoveItemFromMap，廣播＋自刪
---   單人      → 直接本地 RemoveTileObject
function MDFX_SpriteGrid.removeMembers(present)
    local removed = 0
    for _, obj in ipairs(present) do
        local sq = obj:getSquare()
        if sq then
            sq:transmitRemoveItemFromSquare(obj, false)
            removed = removed + 1
        end
    end
    return removed
end
