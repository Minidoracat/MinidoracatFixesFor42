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
--- 回傳：present（現存成員陣列）, complete（是否完整）
function MDFX_SpriteGrid.scan(grid, ox, oy, oz, getSquareFn)
    getSquareFn = getSquareFn or getSquare
    local present = {}
    local complete = true
    for z = 0, grid:getLevels() - 1 do
        for x = 0, grid:getWidth() - 1 do
            for y = 0, grid:getHeight() - 1 do
                local expected = grid:getSprite(x, y, z)
                local sq = getSquareFn(ox + x, oy + y, oz + z)
                local found = nil
                if sq and expected then
                    local objs = sq:getObjects()
                    for i = 0, objs:size() - 1 do
                        local o = objs:get(i)
                        if o:getSprite() == expected then
                            found = o
                            break
                        end
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
    return present, complete
end

--- 這個物件是否屬於一個殘缺群組。
--- 回傳：broken, present, ox, oy, oz
function MDFX_SpriteGrid.inspect(obj, getSquareFn)
    local ox, oy, oz = MDFX_SpriteGrid.originOf(obj)
    if not ox then return false end
    local present, complete = MDFX_SpriteGrid.scan(obj:getSpriteGrid(), ox, oy, oz, getSquareFn)
    return (not complete) and #present > 0, present, ox, oy, oz
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
