-- MDFX_SpriteGrid / MDFX_MultiTileFurniture 離線自我檢查
-- 用法（repo 根目錄）： lua scripts/test_multitile_furniture.lua
--
-- 重點驗的是兩個會出事的地方：
--   1. 殘缺判準必須與原版 getSpriteGridMultiTileObjects 一致（不多清、不漏清）
--   2. 延後確認必須放過「原版蓄意單格移除後立刻替換」的流程
--      （MOFeedingTrough 就是這樣，當場展開會弄壞餵食槽）

local MOD = "MOD/MinidoracatFixesFor42/Contents/mods/MinidoracatFixesFor42/42/media/lua/"

-- ── stub：PZ 全域 ───────────────────────────────────────────────
function require(_) end
function isServer() return true end
function isClient() return false end

local handlers = {}
Events = setmetatable({}, { __index = function(t, name)
    local h = { Add = function(fn) handlers[name] = handlers[name] or {}; table.insert(handlers[name], fn) end }
    rawset(t, name, h)
    return h
end })

local world = {}
function getSquare(x, y, z) return world[x .. "," .. y .. "," .. z] end

-- 預設：沒有安全屋。個別檢查會就地換掉。
SafeHouse = { getSafeHouse = function(_) return nil end }

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

--- containers：容器陣列（模擬 primary + secondaryContainers）
local function place(sq, sprite, grid, containers)
    containers = containers or {}
    local o
    o = {
        _sq = sq,
        _containers = containers,
        getSprite = function() return sprite end,
        getSquare = function() return o._sq end,
        hasSpriteGrid = function() return grid ~= nil end,
        getSpriteGrid = function() return grid end,
        getContainerCount = function() return #o._containers end,
        getContainerByIndex = function(_, i) return o._containers[i + 1] end,
    }
    table.insert(sq._objs, o)
    return o
end

local function newPlayer(x, y, z, dead)
    return { getX = function() return x end,
             getY = function() return y end,
             getZ = function() return z end,
             isDead = function() return dead == true end }
end

--- 蓋一張 2x2 的桌子，錨點 (ox,oy,oz)。回傳 grid, 成員表（key "x,y"）
local function buildTable(ox, oy, oz)
    local spriteMap, grid = {}, nil
    for x = 0, 1 do for y = 0, 1 do
        spriteMap[x .. "," .. y .. ",0"] = newSprite(x, y, 0)
    end end
    grid = newGrid(2, 2, 1, spriteMap)
    local members = {}
    for x = 0, 1 do for y = 0, 1 do
        local sq = getSquare(ox + x, oy + y, oz) or newSquare(ox + x, oy + y, oz)
        members[x .. "," .. y] = place(sq, spriteMap[x .. "," .. y .. ",0"], grid)
    end end
    return grid, members
end

-- ── 載入待測檔 ─────────────────────────────────────────────────
assert(loadfile(MOD .. "shared/Fixes/MDFX_SpriteGrid.lua"), "找不到 MDFX_SpriteGrid.lua（請從 repo 根目錄執行）")()
assert(loadfile(MOD .. "server/Fixes/MDFX_MultiTileFurniture.lua"), "找不到 MDFX_MultiTileFurniture.lua")()

local G = MDFX_SpriteGrid
local onRemove = assert(handlers["OnObjectAboutToBeRemoved"][1], "伺服器端未註冊 OnObjectAboutToBeRemoved")
local onTick = assert(handlers["OnTick"][1], "伺服器端未註冊 OnTick")
local onCmd = assert(handlers["OnClientCommand"][1], "伺服器端未註冊 OnClientCommand")

local function tick(n) for _ = 1, n do onTick() end end

-- ── 檢查 ───────────────────────────────────────────────────────

-- 1. 錨點回推：任一成員都要算出同一個錨點
local _, m = buildTable(100, 100, 0)
for _, obj in pairs(m) do
    local ox, oy, oz = G.originOf(obj)
    assert(ox == 100 and oy == 100 and oz == 0,
        "錨點應為 100,100,0，實際 " .. tostring(ox) .. "," .. tostring(oy) .. "," .. tostring(oz))
end

-- 2. 完整群組 → complete，且不算殘缺
local grid2, m2 = buildTable(200, 200, 0)
local present, complete = G.scan(grid2, 200, 200, 0)
assert(complete == true and #present == 4, "完整 2x2 應找到 4 個成員")
assert(G.inspect(m2["0,0"]) == false, "完整群組不得被判為殘缺")

-- 3. 缺一格 → 殘缺，且 present 只剩 3
local grid3, m3 = buildTable(300, 300, 0)
m3["1,1"]:getSquare():transmitRemoveItemFromSquare(m3["1,1"], false)
local present3, complete3 = G.scan(grid3, 300, 300, 0)
assert(complete3 == false and #present3 == 3, "缺一格應為殘缺且剩 3 個成員")
assert(G.inspect(m3["0,0"]) == true, "殘骸必須被判為殘缺")

-- 4. 同格有別的物件（sprite 不符）不得被誤認成成員
local grid4, m4 = buildTable(400, 400, 0)
place(m4["0,0"]:getSquare(), newSprite(9, 9, 9), nil)   -- 掉落物之類
local present4, complete4 = G.scan(grid4, 400, 400, 0)
assert(complete4 == true and #present4 == 4, "無關物件不得被算進群組")

-- 5. removeMembers 必須用非 safe 版（safelyRemove=false），否則原版整組檢查會擋下來
removedLog = {}
G.removeMembers(present3)
assert(#removedLog == 3, "應移除 3 個殘骸成員，實際 " .. #removedLog)
for _, r in ipairs(removedLog) do
    assert(r.safelyRemove == false, "必須走非 safe 版，否則 all-or-nothing 檢查會讓移除靜默失敗")
end

-- 6. 斷根：大槌打掉一格且沒人補回來 → 延後確認後清掉剩餘 3 格
removedLog = {}
local _, m6 = buildTable(500, 500, 0)
local victim = m6["0,1"]
onRemove(victim)                                                   -- 原版：刪除前觸發
victim:getSquare():transmitRemoveItemFromSquare(victim, false)      -- 原版真的刪掉它
removedLog = {}                                                     -- 只看本 MOD 之後刪了什麼
tick(59); assert(#removedLog == 0, "確認期未到不得動手")
tick(1)
assert(#removedLog == 3, "確認期滿且仍殘缺，應清掉剩下 3 格，實際 " .. #removedLog)

-- 7. 不誤傷原版蓄意的「單格移除→立刻替換」（MOFeedingTrough 模式）
--    當場展開的話這裡會把餵食槽另一半刪掉，正是本設計要避免的
removedLog = {}
local grid7, m7 = buildTable(600, 600, 0)
local replaced = m7["1,0"]
local sameSprite = replaced:getSprite()
local sq7 = replaced:getSquare()
onRemove(replaced)
sq7:transmitRemoveItemFromSquare(replaced, false)
place(sq7, sameSprite, grid7)          -- 同一幀補回同 sprite 的功能物件
removedLog = {}
tick(60)
assert(#removedLog == 0, "群組已被補回完整，不得清除（否則會弄壞餵食槽／兔籠）")

-- 8. 重入 guard：清除過程中自己觸發的移除不得再排隊，避免無限滾雪球
removedLog = {}
local _, m8 = buildTable(700, 700, 0)
local hookedSquare = m8["0,0"]:getSquare()
local origTransmit = hookedSquare.transmitRemoveItemFromSquare
hookedSquare.transmitRemoveItemFromSquare = function(selfSq, obj, safe)
    onRemove(obj)                       -- 模擬 Java 端刪除時再次觸發同一個 event
    return origTransmit(selfSq, obj, safe)
end
local v8 = m8["1,1"]
onRemove(v8)
v8:getSquare():transmitRemoveItemFromSquare(v8, false)
removedLog = {}
tick(60)
local firstSweep = #removedLog
assert(firstSweep == 3, "第一次掃描應清 3 格，實際 " .. firstSweep)
removedLog = {}
tick(120)
assert(#removedLog == 0, "重入 guard 失效：清除動作又把自己排進佇列了")

-- 9. 客戶端指令必須重驗——距離過遠一律拒絕
removedLog = {}
local _, m9 = buildTable(800, 800, 0)
m9["1,1"]:getSquare():transmitRemoveItemFromSquare(m9["1,1"], false)
removedLog = {}
onCmd("MDFX", "cleanupBrokenFurniture", newPlayer(0, 0, 0), { x = 800, y = 800, z = 0 })
assert(#removedLog == 0, "距離過遠的清除請求必須被拒絕")

-- 10. 近距離且確實殘缺 → 放行
onCmd("MDFX", "cleanupBrokenFurniture", newPlayer(801, 801, 0), { x = 800, y = 800, z = 0 })
assert(#removedLog == 3, "近距離的殘骸清除應放行，實際 " .. #removedLog)

-- 11. 群組完整時，客戶端指令不得被用來拆掉完好的家具
removedLog = {}
buildTable(900, 900, 0)
onCmd("MDFX", "cleanupBrokenFurniture", newPlayer(901, 901, 0), { x = 900, y = 900, z = 0 })
assert(#removedLog == 0, "完好的家具不得被清除指令拆掉")

-- 12. 畸形封包不得在 event 迴圈裡拋例外，也不得刪任何東西
removedLog = {}
local _, m12 = buildTable(1000, 1000, 0)
m12["1,1"]:getSquare():transmitRemoveItemFromSquare(m12["1,1"], false)
removedLog = {}
local near12 = newPlayer(1001, 1001, 0)
onCmd("MDFX", "cleanupBrokenFurniture", near12, nil)            -- args 缺席
onCmd("MDFX", "cleanupBrokenFurniture", nil, { x = 1000, y = 1000, z = 0 })  -- player 缺席
for _, bad in ipairs({ "x", { x = "1000", y = 1000, z = 0 }, { x = 1000 }, {} }) do
    onCmd("MDFX", "cleanupBrokenFurniture", near12, bad)
end
onCmd("MDFX", "cleanupBrokenFurniture", newPlayer(1001, 1001, 0, true), { x = 1000, y = 1000, z = 0 })
assert(#removedLog == 0, "畸形封包與死亡玩家的請求都必須被擋下")

-- 13. ⚠ 未載入的格子絕不能被當成缺角——照抄 Java 的 boolean 會誤刪跨 chunk 邊界的完好家具
removedLog = {}
local grid13, m13 = buildTable(1100, 1100, 0)
world["1101,1101,0"] = nil                      -- 模擬相鄰 chunk 尚未載入
local present13, _, unknown13 = G.scan(grid13, 1100, 1100, 0)
assert(unknown13 == true, "未載入的格子必須回報 unknown")
assert(#present13 == 3, "未載入那格之外的 3 個成員仍應被找到")
assert(G.inspect(m13["0,0"]) == false, "unknown 時不得判為可清除")
onRemove(m13["0,0"])
tick(60)
assert(#removedLog == 0, "有格子未載入時絕不能刪除任何成員（會誤刪完好家具）")
-- 但等格子載回來、且確實殘缺時，重試要能補上
world["1101,1101,0"] = newSquare(1101, 1101, 0)  -- 載回來，但成員真的不見了
tick(60)
assert(#removedLog == 3, "格子載回後確認仍殘缺，重試應清掉剩餘 3 格，實際 " .. #removedLog)

-- 14~16. 容器保護。原版 RemoveTileObject 不管容器，刪了就等於毀掉儲物。
--        三種都必須擋下，少一種就會誤刪玩家的東西。
local containerCases = {
    { base = 1200, label = "primary 容器有東西",
      containers = { makeContainer(7) } },
    { base = 1300, label = "secondary 容器有東西（只查 getContainer() 會漏掉）",
      containers = { makeContainer(0), makeContainer(3) } },
    { base = 1400, label = "未探索容器（戰利品還沒生成，size 是 0）",
      containers = { makeContainer(0, false) } },
}
for _, case in ipairs(containerCases) do
    local b = case.base
    local _, mc = buildTable(b, b, 0)
    mc["1,0"]._containers = case.containers
    mc["1,1"]:getSquare():transmitRemoveItemFromSquare(mc["1,1"], false)
    removedLog = {}
    onRemove(mc["0,0"])
    tick(60)
    assert(#removedLog == 0, "自動清掃必須放過：" .. case.label)
    onCmd("MDFX", "cleanupBrokenFurniture", newPlayer(b + 1, b + 1, 0), { x = b, y = b, z = 0 })
    assert(#removedLog == 0, "手動清除指令必須放過：" .. case.label)
end

-- 17. 安全屋授權：不在允許名單的玩家不得清別人安全屋裡的家具
--     （原版右鍵有 safehouseAllowInteract gate，但那是客戶端的，惡意封包繞得過）
removedLog = {}
local _, m17 = buildTable(1500, 1500, 0)
m17["1,1"]:getSquare():transmitRemoveItemFromSquare(m17["1,1"], false)
removedLog = {}
local allowedNames = { alice = true }
SafeHouse = { getSafeHouse = function(_) return {
    playerAllowed = function(_, p) return allowedNames[p._name] == true end
} end }
local mallory = newPlayer(1501, 1501, 0); mallory._name = "mallory"
onCmd("MDFX", "cleanupBrokenFurniture", mallory, { x = 1500, y = 1500, z = 0 })
assert(#removedLog == 0, "非授權玩家不得清安全屋內的殘骸")

-- 18. 安全屋授權：允許名單內的玩家照常可以清
local alice = newPlayer(1501, 1501, 0); alice._name = "alice"
onCmd("MDFX", "cleanupBrokenFurniture", alice, { x = 1500, y = 1500, z = 0 })
assert(#removedLog == 3, "授權玩家應可清除，實際 " .. #removedLog)
SafeHouse = { getSafeHouse = function(_) return nil end }   -- 還原成無安全屋

-- ── 客戶端右鍵選單（TOCTOU）────────────────────────────────────
-- isClient() 為 false ＝ 單人模式，沒有伺服器那道重驗，是最脆弱的路徑。
function getText(k) return k end
local menuPos = { x = 0, y = 0 }
local menuPlayer = {
    getX = function() return menuPos.x end,
    getY = function() return menuPos.y end,
    getZ = function() return 0 end,
    isDead = function() return false end,
}
function getSpecificPlayer(_) return menuPlayer end
--- 把測試玩家挪到該組旁邊，否則選單的距離檢查會先擋下來
local function standNear(base) menuPos.x, menuPos.y = base + 1, base + 1 end

assert(loadfile(MOD .. "client/Fixes/MDFX_MultiTileFurnitureMenu.lua"), "找不到 MDFX_MultiTileFurnitureMenu.lua")()
local onFill = assert(handlers["OnFillWorldObjectContextMenu"][1], "客戶端未註冊 OnFillWorldObjectContextMenu")

local captured = nil
local fakeContext = { addOption = function(_, _, _, fn) captured = fn end }

-- 19. 建立選單後世界變了（群組被補回完整）→ 點下去不得再刪
removedLog = {}
standNear(1600)
local grid19, m19 = buildTable(1600, 1600, 0)
local gone = m19["1,1"]
local sq19 = gone:getSquare()
sq19:transmitRemoveItemFromSquare(gone, false)
removedLog = {}
captured = nil
onFill(0, fakeContext, { m19["0,0"] }, false)
assert(captured, "殘缺群組應該要出現清除選項")
place(sq19, gone:getSprite(), grid19)      -- 點擊前，別人把它修好了／或本來就還在
captured()
assert(#removedLog == 0, "點擊時應重新判定；沿用建立選單當下的清單會刪掉已經完好的家具")

-- 20. 建立選單後容器被塞了東西 → 點下去不得再刪
removedLog = {}
standNear(1700)
local _, m20 = buildTable(1700, 1700, 0)
m20["1,1"]:getSquare():transmitRemoveItemFromSquare(m20["1,1"], false)
removedLog = {}
captured = nil
onFill(0, fakeContext, { m20["0,0"] }, false)
assert(captured, "殘缺群組應該要出現清除選項")
m20["1,0"]._containers = { makeContainer(5) }   -- 點擊前有人把東西放進去了
captured()
assert(#removedLog == 0, "點擊時應重新判定；否則會吃掉剛放進去的儲物")

-- 21. 世界沒變 → 點下去照常清掉
removedLog = {}
standNear(1800)
local _, m21 = buildTable(1800, 1800, 0)
m21["1,1"]:getSquare():transmitRemoveItemFromSquare(m21["1,1"], false)
removedLog = {}
captured = nil
onFill(0, fakeContext, { m21["0,0"] }, false)
assert(captured, "殘缺群組應該要出現清除選項")
captured()
assert(#removedLog == 3, "情況未變時應正常清掉 3 格，實際 " .. #removedLog)

print("MDFX_MultiTileFurniture: 21 checks OK")
