--[[
    MDFX_SpriteGrid —— 多格家具（sprite grid）群組掃描共用工具

    忠實移植 zombie.iso.IsoObjectUtils#getSpriteGridMultiTileObjects 的判準：
    走遍 sprite grid 的整個矩形，逐格要求「該格存在 sprite 與該格預期完全相符的物件」，
    任一格缺席即整組視為殘缺。用同一套判準，本 MOD 認定的「殘缺」才會與原版
    鎖死搬運／拆解的那道 gate 完全一致——不會多清也不會漏清。
]]

MDFX_SpriteGrid = MDFX_SpriteGrid or {}

--- grid 裡與該 sprite 相同的格子數。
--- 原版 getSpriteGridPosX 走 getSpriteIndex，只回**第一個**相符的位置
--- （IsoSpriteGrid.java:52），而 validate() 不檢查唯一性。所以只要 grid 內有
--- 重複 sprite，錨點就會算錯、掃描範圍偏移到隔壁，把完好群組的成員刪掉。
--- 數量不等於 1 一律視為無法判定。
local function spriteOccurrences(grid, sprite)
    local n = 0
    for z = 0, grid:getLevels() - 1 do
        for x = 0, grid:getWidth() - 1 do
            for y = 0, grid:getHeight() - 1 do
                if grid:getSprite(x, y, z) == sprite then n = n + 1 end
            end
        end
    end
    return n
end

--- 群組錨點（grid 座標 0,0,0 那一格）的世界座標。
--- 物件仍在 square 上時才能算，所以移除前就要先取。
--- 回傳：x, y, z 或 nil（nil ＝ 無法判定，呼叫端一律不得刪除）
function MDFX_SpriteGrid.originOf(obj)
    if not obj or not obj:hasSpriteGrid() then return nil end
    local grid = obj:getSpriteGrid()
    local sprite = obj:getSprite()
    local sq = obj:getSquare()
    if not grid or not sprite or not sq then return nil end
    if spriteOccurrences(grid, sprite) ~= 1 then return nil end
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

--- 群組裡是否還有「不該被順手毀掉」的容器內容。
--- 原版 RemoveTileObject 完全不管容器，移除就等於把內容物一起毀掉。
--- 玩家用大槌拆是他自己的決定，但本 MOD 的「清殘骸」選項不該順手吃掉裡面的東西。
---
--- ⚠ 保證範圍限於**原版認得出來的**內容：所有 ItemContainer、未探索容器、
--- 有 override isNoContainerOrEmpty() 的 component（42.20 只有 CraftLogic 與
--- Resources），以及本檔另外查的 FluidContainer。第三方家具的自訂 component
--- 或 modData 不在保證內——Component 的預設實作直接回 true（Component.java:125）。
---
--- 兩個必須注意的地方，少一個就會誤刪：
---   1. 物件可能有**多個**容器。IsoObject.getContainerCount() = primary（0 或 1）
---      ＋ secondaryContainers，只查 getContainer() 會漏掉次要容器。
---   2. **未探索**的容器戰利品還沒生成，getItems():size() 是 0，但它「將會」有東西。
---      一律當成有內容（fail-closed），寧可留著殘骸也不要毀掉還沒生成的戰利品。
function MDFX_SpriteGrid.hasStoredItems(present)
    for _, obj in ipairs(present) do
        -- 直接用原版自己的判準（IsoObject.java:6692）：它已經走遍所有
        -- ItemContainer（含「未探索」＝戰利品還沒生成）與所有 component
        -- （Resources、CraftLogic 進行中的製作…）。自己重寫只會寫出它的子集。
        if not obj:isObjectNoContainerOrEmpty() then return true end

        -- 但它漏掉流體：FluidContainer 雖然是 component（ComponentType:62），
        -- 卻沒有 override isNoContainerOrEmpty()，會走 Component 的預設實作。
        -- 餵食槽有水時 primary ItemContainer 甚至是 nil，內容全在 FluidContainer
        -- （IsoFeedingTrough.java:59），原版判「有沒有流體」的寫法見 IsoObject.java:2650。
        local fluid = obj:getFluidContainer()
        if fluid and not fluid:isEmpty() then return true end
    end
    return false
end

--- 群組是否被安全屋擋下。
---   player 有值（玩家手動清除）→ 用原版 UI 同一套 policy 逐格判定
---     （isSafehouseAllowInteract 含管理員 capability 與交戰中對手，SafeHouse.java:245）
---   player 為 nil（自動清掃，沒有行為人）→ 只要任一成員在安全屋內就 fail closed，
---     留給有權限的玩家手動處理
---
--- ⚠ 必須逐一檢查**每個待刪成員當下的 square**。安全屋是矩形範圍，
--- 拿指令指定的那一格代表整組，就會出現「站在屋外對屋內 sibling 下手」的繞道。
function MDFX_SpriteGrid.isSafehouseBlocked(present, player)
    for _, obj in ipairs(present) do
        local sq = obj:getSquare()
        if sq then
            if player then
                if not SafeHouse.isSafehouseAllowInteract(sq, player) then return true end
            elseif SafeHouse.getSafeHouse(sq) then
                return true
            end
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
