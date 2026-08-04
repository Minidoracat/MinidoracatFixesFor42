-- MDFX_SpriteGrid / MDFX_MultiTileFurniture 離線自我檢查
-- 用法（repo 根目錄）： lua scripts/test_multitile_furniture.lua
--
-- 範圍：只有「手動清除殘骸」。自動斷根已移除（分不出永久殘骸與延遲替換），
-- 所以這裡不再有 OnObjectAboutToBeRemoved / OnTick 相關情境。
--
-- 重點驗的是每一條會造成**不可逆刪除**的路徑都擋得住：
--   未載入格子、錨點模糊、完好群組、內容物（容器／component／流體）、
--   安全屋（含跨界繞道）、畸形封包、TOCTOU。

local MOD = "MOD/MinidoracatFixesFor42/Contents/mods/MinidoracatFixesFor42/42/media/lua/"

-- ── stub：PZ 全域 ───────────────────────────────────────────────
function require(_) end
function isServer() return true end
function getText(k) return k end

local handlers = {}
Events = setmetatable({}, { __index = function(t, name)
    local h = { Add = function(fn) handlers[name] = handlers[name] or {}; table.insert(handlers[name], fn) end }
    rawset(t, name, h)
    return h
end })

local world = {}
function getSquare(x, y, z) return world[x .. "," .. y .. "," .. z] end

-- 安全屋是**逐格**的矩形範圍。mock 必須照格判定，否則「站在屋外對屋內 sibling
-- 下手」那條繞道根本測不出來（全部回同一間安全屋等於假綠）。
local safehouses = {}   -- "x,y,z" -> { allowed = { name = true } }
local function shKey(sq) return sq:getX() .. "," .. sq:getY() .. "," .. sq:getZ() end
SafeHouse = {
    getSafeHouse = function(sq) return sq and safehouses[shKey(sq)] or nil end,
    isSafehouseAllowInteract = function(sq, player)
        local sh = sq and safehouses[shKey(sq)]
        if not sh then return true end
        return player ~= nil and sh.allowed[player._name] == true
    end,
}

-- MP／SP 切換，讓客戶端選單的兩條分支都測得到
local clientMode = false
function isClient() return clientMode end
local sentCommands = {}
function sendClientCommand(player, module, command, args)
    sentCommands[#sentCommands + 1] =
        { player = player, module = module, command = command, args = args }
end

local removedLog = {}

local function newSquare(x, y, z)
    local objs = {}
    local sq
    sq = {
        _objs = objs,
        getX = function() return x end,
        getY = function() return y end,
        getZ = function() return z end,
        getObjects = function()
            return { size = function() return #objs end,
                     get  = function(_, i) return objs[i + 1] end }
        end,
        transmitRemoveItemFromSquare = function(_, obj, safelyRemove)
            removedLog[#removedLog + 1] = { obj = obj, safelyRemove = safelyRemove }
            for i, o in ipairs(objs) do
                if o == obj then table.remove(objs, i) break end
            end
            obj._sq = nil
        end,
    }
    world[x .. "," .. y .. "," .. z] = sq
    return sq
end

-- sprite 用 table 身分比對，對應原版 verifyObject 的 object.getSprite() == testSprite
local function newSprite(gx, gy, gz) return { gx = gx, gy = gy, gz = gz } end

local function newGrid(w, h, levels, spriteMap)
    return {
        getWidth = function() return w end,
        getHeight = function() return h end,
        getLevels = function() return levels end,
        getSprite = function(_, x, y, z) return spriteMap[x .. "," .. y .. "," .. z] end,
        getSpriteGridPosX = function(_, s) return s.gx end,
        getSpriteGridPosY = function(_, s) return s.gy end,
        getSpriteGridPosZ = function(_, s) return s.gz end,
    }
end

--- itemCount = 目前件數；explored=false 代表戰利品還沒生成（size 會是 0）
local function makeContainer(itemCount, explored)
    return {
        isExplored = function() return explored ~= false end,
        getItems = function() return { size = function() return itemCount or 0 end } end,
    }
end

--- opts：{ containers = {…}, componentBusy = bool, fluid = number|nil }
---
--- ⚠ componentBusy 模擬的是「**原版 predicate 認得出來**的 component 狀態」
--- （42.20 只有 CraftLogic 與 Resources 兩個實質 override；Component 的預設實作
--- 直接回 true，見 Component.java:125）。沒有 override 的 stateful component
--- 本 MOD 也保護不到——那是已知限制，不是這個 stub 的假設。
local function place(sq, sprite, grid, opts)
    opts = opts or {}
    local o
    o = {
        _sq = sq,
        _containers = opts.containers or {},
        _componentBusy = opts.componentBusy or false,
        _fluid = opts.fluid,
        getSprite = function() return sprite end,
        getSquare = function() return o._sq end,
        hasSpriteGrid = function() return grid ~= nil end,
        getSpriteGrid = function() return grid end,
        -- 保留舊 API：讓「精確退回舊版程式碼」的 mutation 也跑得起來，
        -- 否則 mutation 會死在 stub 缺方法，變成假的 kill
        getContainer = function() return o._containers[1] end,
        getContainerCount = function() return #o._containers end,
        getContainerByIndex = function(_, i) return o._containers[i + 1] end,
        -- 對應原版 IsoObject.isObjectNoContainerOrEmpty（IsoObject.java:6692）
        isObjectNoContainerOrEmpty = function()
            for _, c in ipairs(o._containers) do
                if not c:isExplored() then return false end
                if c:getItems():size() > 0 then return false end
            end
            return not o._componentBusy
        end,
        -- FluidContainer 是 component 但沒 override isNoContainerOrEmpty，
        -- 所以原版那個判準看不到它——必須另外查
        getFluidContainer = function()
            if o._fluid == nil then return nil end
            return { isEmpty = function() return (o._fluid or 0) <= 0 end }
        end,
    }
    table.insert(sq._objs, o)
    return o
end

local function newPlayer(x, y, z, opts)
    opts = opts or {}
    return { _name = opts.name,
             getX = function() return x end,
             getY = function() return y end,
             getZ = function() return z end,
             isDead = function() return opts.dead == true end }
end

--- 蓋一張 2x2 的桌子，錨點 (ox,oy,oz)。回傳 grid, 成員表（key "x,y"）
local function buildTable(ox, oy, oz)
    local spriteMap = {}
    for x = 0, 1 do for y = 0, 1 do
        spriteMap[x .. "," .. y .. ",0"] = newSprite(x, y, 0)
    end end
    local grid = newGrid(2, 2, 1, spriteMap)
    local members = {}
    for x = 0, 1 do for y = 0, 1 do
        local sq = getSquare(ox + x, oy + y, oz) or newSquare(ox + x, oy + y, oz)
        members[x .. "," .. y] = place(sq, spriteMap[x .. "," .. y .. ",0"], grid)
    end end
    return grid, members
end

--- 蓋一張桌子並打掉右下角，做成殘骸
local function buildWreck(base)
    local grid, m = buildTable(base, base, 0)
    m["1,1"]:getSquare():transmitRemoveItemFromSquare(m["1,1"], false)
    removedLog = {}
    return grid, m
end

-- ── 載入待測檔 ─────────────────────────────────────────────────
assert(loadfile(MOD .. "shared/Fixes/MDFX_SpriteGrid.lua"), "找不到 MDFX_SpriteGrid.lua（請從 repo 根目錄執行）")()
assert(loadfile(MOD .. "server/Fixes/MDFX_MultiTileFurniture.lua"), "找不到 MDFX_MultiTileFurniture.lua")()

local G = MDFX_SpriteGrid
local onCmd = assert(handlers["OnClientCommand"] and handlers["OnClientCommand"][1],
    "伺服器端未註冊 OnClientCommand")
assert(handlers["OnObjectAboutToBeRemoved"] == nil and handlers["OnTick"] == nil,
    "自動斷根應已移除，不該再註冊 OnObjectAboutToBeRemoved / OnTick")

local function cleanup(base, player)
    onCmd("MDFX", "cleanupBrokenFurniture", player, { x = base, y = base, z = 0 })
end

-- ══ 群組判定 ═══════════════════════════════════════════════════

-- 1. 錨點回推：任一成員都要算出同一個錨點
local _, m1 = buildTable(100, 100, 0)
for _, obj in pairs(m1) do
    local ox, oy, oz = G.originOf(obj)
    assert(ox == 100 and oy == 100 and oz == 0,
        "錨點應為 100,100,0，實際 " .. tostring(ox) .. "," .. tostring(oy))
end

-- 2. 完整群組 → complete，且不算殘缺
local grid2, m2 = buildTable(200, 200, 0)
local present2, complete2 = G.scan(grid2, 200, 200, 0)
assert(complete2 == true and #present2 == 4, "完整 2x2 應找到 4 個成員")
assert(G.inspect(m2["0,0"]) == false, "完整群組不得被判為殘缺")

-- 3. 缺一格 → 殘缺，且 present 只剩 3
local grid3, m3 = buildWreck(300)
local present3, complete3 = G.scan(grid3, 300, 300, 0)
assert(complete3 == false and #present3 == 3, "缺一格應為殘缺且剩 3 個成員")
assert(G.inspect(m3["0,0"]) == true, "殘骸必須被判為殘缺")

-- 4. 同格有別的物件（sprite 不符）不得被誤認成成員
local grid4, m4 = buildTable(400, 400, 0)
place(m4["0,0"]:getSquare(), newSprite(9, 9, 9), nil)   -- 掉落物之類
local present4, complete4 = G.scan(grid4, 400, 400, 0)
assert(complete4 == true and #present4 == 4, "無關物件不得被算進群組")

-- 5. removeMembers 必須用非 safe 版，否則原版 all-or-nothing 檢查會讓移除靜默失敗
removedLog = {}
G.removeMembers(present3)
assert(#removedLog == 3, "應移除 3 個殘骸成員，實際 " .. #removedLog)
for _, r in ipairs(removedLog) do
    assert(r.safelyRemove == false, "必須走非 safe 版")
end

-- 6. ⚠ 未載入的格子絕不能被當成缺角（會誤判跨 chunk 邊界的完好家具）
local grid6, m6 = buildTable(600, 600, 0)
world["601,601,0"] = nil                       -- 模擬相鄰 chunk 尚未載入
local present6, _, unknown6 = G.scan(grid6, 600, 600, 0)
assert(unknown6 == true, "未載入的格子必須回報 unknown")
assert(#present6 == 3, "其餘 3 個成員仍應被找到")
assert(G.inspect(m6["0,0"]) == false, "unknown 時不得判為可清除")

-- 7. ⚠ grid 內有重複 sprite → 錨點無法判定，必須整組放棄
--    原版 getSpriteGridPosX 只回第一個相符位置（IsoSpriteGrid.java:52）
local dupSprite = newSprite(0, 0, 0)
local dupGrid = newGrid(2, 1, 1, { ["0,0,0"] = dupSprite, ["1,0,0"] = dupSprite })
local dupA = place(newSquare(700, 700, 0), dupSprite, dupGrid)
place(newSquare(701, 700, 0), dupSprite, dupGrid)
assert(G.originOf(dupA) == nil, "重複 sprite 的 grid 必須回報無法判定")
assert(G.inspect(dupA) == false, "無法判定錨點時不得判為可清除")

-- ══ 內容物保全 ═════════════════════════════════════════════════
-- 原版 RemoveTileObject 完全不管這些，刪了就等於毀掉玩家的東西

local contentCases = {
    { base = 800,  label = "primary 容器有東西",        apply = function(o) o._containers = { makeContainer(7) } end },
    { base = 900,  label = "secondary 容器有東西",      apply = function(o) o._containers = { makeContainer(0), makeContainer(3) } end },
    { base = 1000, label = "未探索容器（戰利品未生成）", apply = function(o) o._containers = { makeContainer(0, false) } end },
    { base = 1100, label = "component 狀態非空（乾燥架類）", apply = function(o) o._componentBusy = true end },
    { base = 1200, label = "流體非空（餵食槽類）",      apply = function(o) o._fluid = 5 end },
}
for _, case in ipairs(contentCases) do
    local _, mc = buildWreck(case.base)
    case.apply(mc["1,0"])
    assert(G.inspect(mc["0,0"]) == false, "有內容物時不得判為可清除：" .. case.label)
    cleanup(case.base, newPlayer(case.base + 1, case.base + 1, 0))
    assert(#removedLog == 0, "手動清除必須放過：" .. case.label)
end

-- ══ 指令信任邊界 ═══════════════════════════════════════════════

-- 13. 距離過遠一律拒絕
local _, _ = buildWreck(1300)
cleanup(1300, newPlayer(0, 0, 0))
assert(#removedLog == 0, "距離過遠的清除請求必須被拒絕")

-- 14. 近距離且確實殘缺 → 放行
cleanup(1300, newPlayer(1301, 1301, 0))
assert(#removedLog == 3, "近距離的殘骸清除應放行，實際 " .. #removedLog)

-- 15. 完好家具不得被指令拆掉
removedLog = {}
buildTable(1400, 1400, 0)
cleanup(1400, newPlayer(1401, 1401, 0))
assert(#removedLog == 0, "完好的家具不得被清除指令拆掉")

-- 16. 畸形封包與死亡玩家都要擋下，且不得拋例外
buildWreck(1500)
local near = newPlayer(1501, 1501, 0)
onCmd("MDFX", "cleanupBrokenFurniture", near, nil)
onCmd("MDFX", "cleanupBrokenFurniture", nil, { x = 1500, y = 1500, z = 0 })
for _, bad in ipairs({ "x", { x = "1500", y = 1500, z = 0 }, { x = 1500 }, {} }) do
    onCmd("MDFX", "cleanupBrokenFurniture", near, bad)
end
cleanup(1500, newPlayer(1501, 1501, 0, { dead = true }))
assert(#removedLog == 0, "畸形封包與死亡玩家的請求都必須被擋下")

-- ══ 安全屋授權 ═════════════════════════════════════════════════

-- 17. 非授權玩家不得清安全屋內的殘骸
buildWreck(1600)
for x = 1600, 1601 do for y = 1600, 1601 do
    safehouses[x .. "," .. y .. ",0"] = { allowed = { alice = true } }
end end
cleanup(1600, newPlayer(1602, 1602, 0, { name = "mallory" }))
assert(#removedLog == 0, "非授權玩家不得清安全屋內的殘骸")

-- 18. 授權玩家照常可以清
cleanup(1600, newPlayer(1602, 1602, 0, { name = "alice" }))
assert(#removedLog == 3, "授權玩家應可清除，實際 " .. #removedLog)
for x = 1600, 1601 do for y = 1600, 1601 do safehouses[x .. "," .. y .. ",0"] = nil end end

-- 19. ⚠ 跨界繞道：指令那格在屋外，但 sibling 在未授權安全屋內 → 整組擋下
--     只驗指令那一格的話，站在屋外就能清掉別人屋裡的東西
buildWreck(1700)                                             -- 缺角在 (1701,1701)
-- 安全屋只罩住其中一個**存活**的 sibling；指令指定的 (1700,1700) 在屋外
safehouses["1701,1700,0"] = { allowed = { alice = true } }
cleanup(1700, newPlayer(1700, 1700, 0, { name = "mallory" }))
assert(#removedLog == 0, "有 sibling 在未授權安全屋內時，必須整組擋下")
safehouses["1701,1700,0"] = nil

-- ══ 客戶端右鍵選單 ═════════════════════════════════════════════

assert(loadfile(MOD .. "client/Fixes/MDFX_MultiTileFurnitureMenu.lua"), "找不到 MDFX_MultiTileFurnitureMenu.lua")()
local onFill = assert(handlers["OnFillWorldObjectContextMenu"][1], "客戶端未註冊 OnFillWorldObjectContextMenu")

local menuPos = { x = 0, y = 0 }
local menuPlayer = {
    getX = function() return menuPos.x end,
    getY = function() return menuPos.y end,
    getZ = function() return 0 end,
    isDead = function() return false end,
}
function getSpecificPlayer(_) return menuPlayer end
local function standNear(base) menuPos.x, menuPos.y = base + 1, base + 1 end

local captured = nil
local fakeContext = { addOption = function(_, _, _, fn) captured = fn end }

local function openMenuOn(obj) captured = nil; onFill(0, fakeContext, { obj }, false) end

-- 20. ⚠ TOCTOU：建立選單後群組被補回完整 → 點下去不得再刪
local grid20, m20 = buildWreck(1800)
standNear(1800)
openMenuOn(m20["0,0"])
assert(captured, "殘缺群組應該要出現清除選項")
place(getSquare(1801, 1801, 0), m20["1,1"]:getSprite(), grid20)   -- 點擊前被補回來了
captured()
assert(#removedLog == 0, "點擊時應重新判定；沿用舊清單會刪掉已經完好的家具")

-- 21. ⚠ TOCTOU：建立選單後容器被塞了東西 → 點下去不得再刪
local _, m21 = buildWreck(1900)
standNear(1900)
openMenuOn(m21["0,0"])
assert(captured, "殘缺群組應該要出現清除選項")
m21["1,0"]._containers = { makeContainer(5) }
captured()
assert(#removedLog == 0, "點擊時應重新判定；否則會吃掉剛放進去的儲物")

-- 22. 情況未變 → 點下去照常清掉
local _, m22 = buildWreck(2000)
standNear(2000)
openMenuOn(m22["0,0"])
assert(captured, "殘缺群組應該要出現清除選項")
captured()
assert(#removedLog == 3, "情況未變時應正常清掉 3 格，實際 " .. #removedLog)

-- 23. MP 分支：客戶端不得本地刪除，只送指令，payload 要正確
sentCommands = {}
clientMode = true
local _, m23 = buildWreck(2100)
standNear(2100)
openMenuOn(m23["0,0"])
assert(captured, "MP 下殘缺群組也應出現清除選項")
captured()
assert(#removedLog == 0, "MP 下客戶端不得自己刪，必須交給伺服器")
assert(#sentCommands == 1, "應送出一筆 client command，實際 " .. #sentCommands)
local cmd = sentCommands[1]
assert(cmd.module == "MDFX" and cmd.command == "cleanupBrokenFurniture", "指令名稱錯誤")
assert(cmd.args.x == 2100 and cmd.args.y == 2100 and cmd.args.z == 0, "座標 payload 錯誤")
clientMode = false

-- 24. 選單本身也要擋安全屋，避免「選項點得下去、伺服器靜默拒絕」
local _, m24 = buildWreck(2200)
safehouses["2201,2200,0"] = { allowed = { alice = true } }   -- 罩住存活的 sibling
menuPlayer._name = "mallory"
standNear(2200)
openMenuOn(m24["0,0"])
assert(captured == nil, "未授權安全屋的殘骸不得出現清除選項")
safehouses["2201,2200,0"] = nil

print("MDFX_MultiTileFurniture: 24 checks OK")
