-- MDFX_ConsumedContainerGuard 離線自我檢查
-- 用法（repo 根目錄）： lua scripts/test_consumed_container_guard.lua [--mutants]
--
-- 假引擎照 42.22.2 反編譯快照的形狀模擬：ItemContainer 的 getItems（活的清單）／isEmpty／getContainingItem／Remove／
-- AddItem（先從舊容器拿掉，ItemContainer.java:515-539）／getCharacter（沿容器物品往外找，:3327-3345）／getParent／getVehiclePart、
-- InventoryItem 的 getContainer／getWorldItem／getFullType、InventoryContainer 的 getInventory、
-- IsoWorldInventoryObject 的 getWorldObjectIndex／getSquare／getOffX/Y/Z／getItem、
-- IsoGridSquare.AddWorldInventoryItem（不會自己把物品從舊容器拿掉；Java 端出錯時 Lua 拿到 nil）與 getWorldObjects、
-- ItemUser.RemoveItem（地上的物品移除後引用還留著）。驗證：
--   * 空袋被用掉、袋子沒被用掉（還在容器、還在地上）：什麼都不做
--   * 袋子被用掉而裡面還有東西：在容器裡的放回那個容器並送給客戶端，在地上的放回同一格同一個位置；不多出一份
--   * 動作開始後才放到角色旁邊地上的袋子（不在 logic 的清單裡）也算
--   * 原本所在的容器自己也被用掉（袋中袋）：改放主背包
--   * 原本所在的容器送不到客戶端（車上或箱子裡的背包的內部、非玩家身上的袋子）：照樣放回原處，再把往外第一件「所在容器送得到」的
--     容器物品先送移除、再送加入；鏈斷了不送
--   * 放回的地方在車上（含車上背包的內部）就重算那個車容器的內容量；地上放不成的塞回袋裡、記失敗、不記成放回了；已經落地的不塞回
--   * 兩個完成端各用自己的 logic 欄位；參數與回傳值原樣；原函式的錯原樣外洩
--   * 自己出錯不外洩、只印一次；Java 端沒搬走的讀回來才知道；每種配方記一行、有上限
--   * 多人客戶端不安裝；形狀不符不安裝（兩個完成端各自判斷）；重複安裝不重包、被整支替換後再包
-- --mutants：逐一抽掉每道防線，確認至少一項檢查轉紅。

local SRC_PATH = "MOD/MinidoracatFixesFor42/Contents/mods/MinidoracatFixesFor42/"
    .. "42/media/lua/server/Fixes/MDFX_ConsumedContainerGuard.lua"
local NAME = "MDFX_ConsumedContainerGuard"

local function readFile(path)
    local f = assert(io.open(path, "rb"))
    local s = f:read("*a")
    f:close()
    return s
end
local SOURCE = readFile(SRC_PATH)
local realPrint = print
local loadSource = loadstring or load

-- ── 假引擎 ─────────────────────────────────────────────────────
local W

local function onGround(it) return it.worldItem ~= nil and it.worldItem.onSquare end

local Container = {}
Container.__index = Container
function Container:getItems()
    local c = self
    return { size = function() return #c.items end, get = function(_, i) return c.items[i + 1] end }
end
function Container:isEmpty() return #self.items == 0 end
function Container:getContainingItem() return self.holder end
function Container:getParent() return self.owner or self.parent end -- 角色的主背包 parent 就是角色
function Container:getVehiclePart() return self.part end
function Container:getOutermostContainer() -- ItemContainer.java:3614-3632
    local c = self
    for _ = 1, 16 do
        local outer = c.holder and c.holder.container
        if outer == nil or outer == self then break end
        c = outer
    end
    return c
end
function Container:getCapacityWeight() return #self.items end
function Container:getCharacter() -- ItemContainer.java:3327-3345
    local c = self
    for _ = 1, 16 do
        if c.owner then return c.owner end
        if not c.holder then break end
        c = c.holder.container
        if c == self or c == nil then break end
    end
    return nil
end
function Container:Remove(item) -- ItemContainer.java:2084-2120
    for i, it in ipairs(self.items) do
        if it == item then
            table.remove(self.items, i)
            item.container = nil
            return
        end
    end
end
-- item.stuck 模擬 Java 端出錯：物品沒搬走，Lua 這邊也收不到錯誤（已消失的袋子自己的容器不受影響：塞回去要成功）
function Container:AddItem(item)
    if self.boom then error("boom") end
    W.adds[#W.adds + 1] = { to = self, item = item }
    if item.stuck and not self.holder then return nil end
    if item.container then item.container:Remove(item) end
    item.container = self
    self.items[#self.items + 1] = item
    return item
end

-- extra：owner（角色）、parent（世界物件）、part（車的部件）
local function container(name, holder, extra)
    local c = setmetatable({ name = name, items = {}, holder = holder }, Container)
    for k, v in pairs(extra or {}) do c[k] = v end
    return c
end

local Item = {}
Item.__index = Item
function Item:getContainer() return self.container end
function Item:getWorldItem() return self.worldItem end
function Item:getFullType() return self.type end

local function item(type, into)
    local it = setmetatable({ type = type or "Base.Screwdriver" }, Item)
    if into then into:AddItem(it) end
    return it
end

-- 容器物品：getInventory 只有它有（一般物品呼叫會拋錯，和 Kahlua 對不存在的方法一樣）
local function bag(type, into)
    local it = item(type or "Base.Garbagebag", into)
    it._class = "InventoryContainer"
    it.inv = container("inside:" .. it.type, it)
    it.getInventory = function(self)
        if self.broken then error("boom") end
        return self.inv
    end
    return it
end

local Square = {}
Square.__index = Square
function Square:getX() return self.x end
function Square:getY() return self.y end
function Square:getZ() return self.z end
function Square:getWorldObjects()
    local s = self
    return { size = function() return #s.objects end, get = function(_, i) return s.objects[i + 1] end }
end
-- IsoGridSquare.java:6066-6138：建世界物件、設到物品上；不碰物品原本的容器。it.dropFail 模擬 Java 端出錯（什麼都沒做，Lua 拿到 nil）；
-- it.dropHalf 模擬物品落地之後才出錯（世界物件已經在格子上，Lua 一樣拿到 nil）
function Square:AddWorldInventoryItem(it, x, y, z)
    if it.dropFail then return nil end
    W.drops[#W.drops + 1] = { sq = self, item = it, x = x, y = y, z = z, stillInside = it.container }
    it.worldItem = { sq = self, item = it, x = x, y = y, z = z, onSquare = true,
        getWorldObjectIndex = function(wi) return wi.onSquare and 0 or -1 end,
        getSquare = function(wi) return wi.sq end, getItem = function(wi) return wi.item end,
        getOffX = function(wi) return wi.x end, getOffY = function(wi) return wi.y end, getOffZ = function(wi) return wi.z end }
    self.objects[#self.objects + 1] = it.worldItem
    if it.dropHalf then return nil end
    return it
end
-- 角色站在 (100,100,0)；dx、dy 是離角色幾格，z 是樓層
local function square(dx, dy, z)
    local sq = setmetatable({ x = 100 + (dx or 0), y = 100 + (dy or 0), z = z or 0, objects = {} }, Square)
    W.grid[sq.x .. "," .. sq.y .. "," .. sq.z] = sq
    return sq
end

-- ItemUser.RemoveItem（ItemUser.java:123-180）：地上的從格子移除（物品上的引用留著）；容器裡的從容器拿掉
local function use(it)
    local wi = it.worldItem
    if wi and wi.onSquare then
        wi.onSquare = false
        for i, o in ipairs(wi.sq.objects) do
            if o == wi then table.remove(wi.sq.objects, i) break end
        end
    end
    if it.container then it.container:Remove(it) end
end

local function printed(needle)
    local n = 0
    for _, line in ipairs(W.prints) do
        if line:find(needle, 1, true) then n = n + 1 end
    end
    return n
end

-- opts.mode："server"（預設）、"sp"（單人）、"client"（多人客戶端）
local function newWorld(opts)
    opts = opts or {}
    local mode = opts.mode or "server"
    W = { prints = {}, adds = {}, drops = {}, sends = {}, init = {}, grid = {}, parts = {}, calls = 0 }
    W.at = square(0, 0)
    print = function(...)
        local parts = {}
        for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
        W.prints[#W.prints + 1] = table.concat(parts, "\t")
    end
    Events = { OnInitGlobalModData = { Add = function(fn) W.init[#W.init + 1] = fn end } }
    isServer = function() return mode == "server" end
    isClient = function() return mode == "client" end
    instanceof = function(obj, class) return type(obj) == "table" and obj._class == class end
    sendAddItemToContainer = function(c, it) W.sends[#W.sends + 1] = { to = c, item = it, kind = "add" } end
    sendRemoveItemFromContainer = function(c, it) W.sends[#W.sends + 1] = { to = c, item = it, kind = "remove" } end
    local cell = { getGridSquare = function(_, x, y, z) return W.grid[x .. "," .. y .. "," .. z] end }
    getCell = function() return cell end
    -- 原版的兩個完成端：W.vanilla 決定這次「用掉」什麼
    local function vanilla(self, ...)
        W.calls = W.calls + 1
        W.args = { ... }
        if W.vanilla then return W.vanilla(self, ...) end
    end
    ISBuildIsoEntity = { create = vanilla }
    ISHandcraftAction = { performRecipe = vanilla }
    if opts.noBuild then ISBuildIsoEntity = nil end
    if opts.badCraft then ISHandcraftAction.performRecipe = "x" end
    if opts.noSend then sendAddItemToContainer = nil end
    if opts.noRemoveSend then sendRemoveItemFromContainer = nil end
    if opts.noInstanceof then instanceof = nil end
    if opts.noCell then getCell = nil end
end

-- 一位玩家（containers[1] 是他的主背包）與一次建造：containers 是這次配方的容器清單
local function build(containers, recipe)
    local main = containers[1]
    local logic = { getContainers = function()
        if W.failContainers then error("boom") end
        return { size = function() return #containers end, get = function(_, i) return containers[i + 1] end }
    end }
    local who = { _class = "IsoPlayer",
        getInventory = function()
            if W.failInventory then error("boom") end
            return main
        end,
        getSquare = function() return not W.noSquare and W.at or nil end }
    main.owner = who
    if recipe == nil then recipe = "RainCollectorRound" end
    return { character = who, buildPanelLogic = logic, craftRecipe = recipe and { getName = function() return recipe end } }
end

-- ── 測試套件（mutant 模式重跑同一套）────────────────────────────
local function runSuite(src, quiet)
    local checks, failures = 0, 0
    local function check(label, cond, detail)
        checks = checks + 1
        if not cond then failures = failures + 1 end
        if not quiet then
            realPrint(string.format("  %s  %s%s", cond and "PASS" or "FAIL", label,
                (not cond and detail) and ("  — " .. tostring(detail)) or ""))
        end
    end
    local function load(opts)
        newWorld(opts)
        assert(loadSource(src, NAME))()
    end
    local function log() return table.concat(W.prints, " | ") end

    -- 1 多人客戶端：不安裝
    load({ mode = "client" })
    check("1 多人客戶端不包、不掛事件、不印", ISBuildIsoEntity[NAME] == nil and ISHandcraftAction[NAME] == nil
        and #W.init == 0 and #W.prints == 0)

    -- 2 形狀不符：那一個不裝、印一行；另一個照裝
    load({ noBuild = true })
    check("2 缺 ISBuildIsoEntity：印一行 NOT installed、手工製作照裝", printed("NOT installed: vanilla ISBuildIsoEntity") == 1
        and #W.prints == 1 and ISHandcraftAction[NAME] ~= nil, log())
    load({ badCraft = true })
    check("2 performRecipe 不是函式：不動它、印一行、建造照裝", ISHandcraftAction.performRecipe == "x"
        and printed("NOT installed: vanilla ISHandcraftAction") == 1 and ISBuildIsoEntity[NAME] ~= nil, log())
    load({ noSend = true })
    check("2 缺 sendAddItemToContainer：兩個都不裝、印一行", ISBuildIsoEntity[NAME] == nil and ISHandcraftAction[NAME] == nil
        and printed("NOT installed: engine API") == 1 and #W.prints == 1, log())
    load({ noInstanceof = true })
    check("2 缺 instanceof：兩個都不裝", ISBuildIsoEntity[NAME] == nil and ISHandcraftAction[NAME] == nil and printed("NOT installed") == 1)
    load({ noCell = true })
    check("2 缺 getCell：兩個都不裝", ISBuildIsoEntity[NAME] == nil and ISHandcraftAction[NAME] == nil and printed("NOT installed") == 1)
    load({ noRemoveSend = true })
    check("2 缺 sendRemoveItemFromContainer：兩個都不裝", ISBuildIsoEntity[NAME] == nil and ISHandcraftAction[NAME] == nil
        and printed("NOT installed") == 1)

    -- 3 重複安裝不重包；被整支替換後復查再包
    load()
    local first = ISBuildIsoEntity.create
    check("3 掛一個 OnInitGlobalModData", #W.init == 1)
    for _, fn in ipairs(W.init) do fn() end
    check("3 復查不重包", ISBuildIsoEntity.create == first and ISBuildIsoEntity[NAME] == first)
    ISBuildIsoEntity.create(build({ container("main") }))
    check("3 原函式只跑一次", W.calls == 1)
    local replaced = 0
    ISBuildIsoEntity.create = function() replaced = replaced + 1 return "theirs" end
    for _, fn in ipairs(W.init) do fn() end
    check("3 被整支替換後再包一層", ISBuildIsoEntity.create ~= first and ISBuildIsoEntity[NAME] == ISBuildIsoEntity.create
        and ISBuildIsoEntity.create(build({ container("main") })) == "theirs" and replaced == 1)

    -- 4 參數與回傳值原樣；沒有 logic 照跑
    load()
    local main = container("main")
    W.vanilla = function() return false end
    check("4 回傳 false 照回", ISBuildIsoEntity.create(build({ main }), 1, 2, 3, true, "s") == false)
    check("4 五個參數都傳到", #W.args == 5 and W.args[1] == 1 and W.args[4] == true and W.args[5] == "s")
    W.vanilla = function() return nil end
    check("4 回傳 nil 照回", ISBuildIsoEntity.create(build({ main })) == nil)
    local bare = build({ main })
    bare.buildPanelLogic = nil
    W.vanilla = function() return "old path" end
    check("4 沒有 buildPanelLogic 照跑、不印", ISBuildIsoEntity.create(bare) == "old path" and #W.prints == 0, log())

    -- 5 對照：空袋被用掉，什麼都不做
    load()
    main = container("main")
    local empty = bag(nil, main)
    local driver = item(nil, main)
    W.adds = {}
    W.vanilla = function() use(empty) end
    ISBuildIsoEntity.create(build({ main }))
    check("5 空袋被用掉：不搬、不送、不印", #W.adds == 0 and #W.sends == 0 and #W.prints == 0 and driver.container == main, log())

    -- 6 袋子在主背包，袋裡有材料（被用掉）與一把螺絲起子
    load()
    main = container("main")
    local sack = bag(nil, main)
    local plank = item("Base.Plank", sack.inv)
    driver = item(nil, sack.inv)
    W.adds = {}
    W.vanilla = function() use(plank) use(sack) end
    ISBuildIsoEntity.create(build({ main, sack.inv }))
    check("6 螺絲起子回到主背包", driver.container == main and sack.inv:isEmpty())
    check("6 只搬那一件、不多出一份", #W.adds == 1 and #main.items == 1, #W.adds .. "/" .. #main.items)
    check("6 送給客戶端一次（主背包、那一件）", #W.sends == 1 and W.sends[1].to == main and W.sends[1].item == driver)
    check("6 用掉的材料與袋子不回來", plank.container == nil and sack.container == nil)
    check("6 診斷行：配方、袋子、件數、放回容器", printed('recipe="RainCollectorRound" used up Base.Garbagebag that still held 1 item(s);'
        .. ' put them back in the container it was in.') == 1 and #W.prints == 1, log())

    -- 7 袋子在地上（角色旁邊一格）：放回同一格同一個位置
    load()
    main = container("main")
    local floor = container("floor")
    local sq = square(1, 0)
    sack = bag()
    floor.items[1] = sack -- 地上的物品列在地面容器裡，自己的 container 是 nil
    sq:AddWorldInventoryItem(sack, 0.3, 0.4, 0.1)
    driver = item(nil, sack.inv)
    W.adds, W.drops = {}, {}
    W.vanilla = function() use(sack) end
    ISBuildIsoEntity.create(build({ main, floor, sack.inv }))
    check("7 螺絲起子在同一格的地上", onGround(driver) and driver.worldItem.sq == sq and #W.drops == 1 and #sq.objects == 1)
    check("7 位置和袋子原本一樣", #W.drops == 1 and W.drops[1].x == 0.3 and W.drops[1].y == 0.4 and W.drops[1].z == 0.1)
    check("7 先從袋子拿掉才放到地上", #W.drops == 1 and W.drops[1].stillInside == nil and driver.container == nil and sack.inv:isEmpty())
    check("7 不放進容器、不另外送", #W.adds == 0 and #W.sends == 0)
    check("7 診斷行寫 on its square", printed("put them back on its square.") == 1 and #W.prints == 1, log())

    -- 8 袋子在背包、裡面多件：全部回來
    load()
    main = container("main")
    sack = bag(nil, main)
    local a, b, c = item("Base.Plank", sack.inv), item("Base.Nails", sack.inv), item(nil, sack.inv)
    W.adds = {}
    W.vanilla = function() use(sack) end
    ISBuildIsoEntity.create(build({ main }))
    check("8 三件都回主背包", a.container == main and b.container == main and c.container == main and sack.inv:isEmpty())
    check("8 各搬一次、各送一次", #W.adds == 3 and #W.sends == 3, #W.adds .. "/" .. #W.sends)
    check("8 件數 3、主背包不是車上的容器", printed("still held 3 item(s)") == 1 and #W.parts == 0, log())

    -- 9 袋子沒被用掉（還在背包）：不動
    load()
    main = container("main")
    sack = bag(nil, main)
    driver = item(nil, sack.inv)
    W.adds = {}
    ISBuildIsoEntity.create(build({ main, sack.inv }))
    check("9 袋子還在背包：裡面的不動", driver.container == sack.inv and #W.adds == 0 and #W.sends == 0 and #W.prints == 0, log())

    -- 10 地上的袋子沒被用掉：不動
    load()
    main = container("main")
    floor = container("floor")
    sq = square(1, 0)
    sack = bag()
    floor.items[1] = sack
    sq:AddWorldInventoryItem(sack, 0.5, 0.5, 0)
    driver = item(nil, sack.inv)
    W.adds, W.drops = {}, {}
    ISBuildIsoEntity.create(build({ main, floor }))
    check("10 袋子還在地上：裡面的不動", driver.container == sack.inv and #W.adds == 0 and #W.drops == 0 and #W.prints == 0, log())

    -- 11 袋子被原函式搬到別的容器（不是用掉）：不動
    load()
    main = container("main")
    local crate = container("crate", nil, { parent = {} })
    sack = bag(nil, main)
    driver = item(nil, sack.inv)
    W.vanilla = function() crate:AddItem(sack) end
    ISBuildIsoEntity.create(build({ main }))
    check("11 袋子被搬到別處：裡面的不動", driver.container == sack.inv and sack.container == crate and #W.sends == 0)

    -- 12 袋子原本在箱子裡：放回箱子
    load()
    main = container("main")
    crate = container("crate", nil, { parent = {} })
    sack = bag(nil, crate)
    driver = item(nil, sack.inv)
    W.vanilla = function() use(sack) end
    ISBuildIsoEntity.create(build({ main, crate }))
    check("12 放回箱子、送的是箱子", driver.container == crate and #W.sends == 1 and W.sends[1].to == crate and #main.items == 0
        and printed("in the container it was in.") == 1, log())

    -- 13 袋中袋（外層在玩家身上）
    load()
    main = container("main")
    local outer = bag(nil, main)
    local inner = bag(nil, outer.inv)
    driver = item(nil, inner.inv)
    W.vanilla = function() use(inner) use(outer) end
    ISBuildIsoEntity.create(build({ main, outer.inv }))
    check("13 外層也被用掉：改放主背包、診斷行照寫", driver.container == main and #W.sends == 1 and W.sends[1].to == main
        and printed("put them back in the player's main inventory.") == 1, log())
    load()
    main = container("main")
    outer = bag(nil, main)
    inner = bag(nil, outer.inv)
    driver = item(nil, inner.inv)
    W.vanilla = function() use(inner) end
    ISBuildIsoEntity.create(build({ main, outer.inv }))
    check("13 外層還在玩家身上：放回外層", driver.container == outer.inv and #W.sends == 1 and W.sends[1].to == outer.inv)

    -- 14 清單裡的過期項目（動作開始後被別的途徑移除，已經不在任何地方）：原版完成時不會用到它，不是這次用掉的
    load()
    main = container("main")
    floor = container("floor")
    sack = bag()
    floor.items[1] = sack
    driver = item(nil, sack.inv)
    W.adds = {}
    ISBuildIsoEntity.create(build({ main, floor }))
    check("14 過期項目：裡面的東西不動、不印", driver.container == sack.inv and #W.adds == 0 and #W.sends == 0 and #W.prints == 0, log())

    -- 15 記錄那一段出錯：原函式照跑、回傳照回、只印一次
    load()
    main = container("main")
    W.failContainers = true
    W.vanilla = function() return "done" end
    local ok, ret = pcall(ISBuildIsoEntity.create, build({ main }))
    check("15 錯誤不外洩、原函式照跑、回傳照回", ok and ret == "done" and W.calls == 1)
    pcall(ISBuildIsoEntity.create, build({ main }))
    check("15 只印一行", printed("could not keep what a used-up container held") == 1 and #W.prints == 1, log())

    -- 16 放回那一段出錯：不外洩、只印一次
    load()
    main = container("main")
    sack = bag(nil, main)
    driver = item(nil, sack.inv)
    main.boom = true
    W.vanilla = function() use(sack) return "done" end
    ok, ret = pcall(ISBuildIsoEntity.create, build({ main }))
    check("16 放回出錯不外洩、回傳照回", ok and ret == "done")
    check("16 印一行", printed("could not keep what a used-up container held") == 1 and #W.prints == 1, log())

    -- 17 Java 端沒搬走（Lua 收不到錯誤）：讀回才知道
    load()
    main = container("main")
    sack = bag(nil, main)
    driver = item(nil, sack.inv)
    driver.stuck = true
    W.vanilla = function() use(sack) end
    ISBuildIsoEntity.create(build({ main }))
    check("17 一件都沒搬走：印 still inside、不印 used up", printed("1 item(s) are still inside a used-up Base.Garbagebag") == 1
        and printed("used up Base.Garbagebag that") == 0, log())
    load()
    main = container("main")
    sack = bag(nil, main)
    driver = item(nil, sack.inv)
    driver.stuck = true
    a = item("Base.Plank", sack.inv)
    W.vanilla = function() use(sack) end
    ISBuildIsoEntity.create(build({ main }))
    check("17 搬走一件、卡住一件：兩行、件數 1", a.container == main and printed("1 item(s) are still inside") == 1
        and printed("still held 1 item(s)") == 1 and #W.prints == 2, log())

    -- 18 每種配方記一行、有上限
    load()
    local function consume(recipe)
        local m = container("main")
        local s = bag(nil, m)
        local d = item(nil, s.inv)
        W.vanilla = function() use(s) end
        ISBuildIsoEntity.create(build({ m }, recipe))
        return d.container == m
    end
    for _ = 1, 30 do consume("ScrapSack") end
    check("18 同一種配方 30 次只記一行、不算進上限", printed('recipe="ScrapSack"') == 1 and #W.prints == 1, log())
    for i = 1, 19 do consume("R" .. i) end
    check("18 20 種配方各一行", #W.prints == 20 and printed("not logging further") == 0, #W.prints)
    local kept = consume("R20") and consume("R21")
    check("18 第 21 種起只印一次提示、照樣放回", kept and #W.prints == 21 and printed("not logging further recipes") == 1
        and printed('recipe="R20"') == 0, log())

    -- 19 原函式的錯原樣外洩、之後不搬
    load()
    main = container("main")
    sack = bag(nil, main)
    driver = item(nil, sack.inv)
    W.adds = {}
    W.vanilla = function() use(sack) error("vanilla broke", 0) end
    ok, ret = pcall(ISBuildIsoEntity.create, build({ main }))
    check("19 原函式的錯原樣外洩", not ok and ret == "vanilla broke", tostring(ret))
    check("19 之後不搬、不印", #W.adds == 0 and #W.prints == 0)

    -- 20 手工製作用 self.logic；建造不把 self.logic 當成自己的
    load()
    main = container("main")
    sack = bag("Base.EmptySandbag", main)
    driver = item(nil, sack.inv)
    local scissors = item("Base.Scissors", sack.inv)
    local action = build({ main, sack.inv }, "ScrapSack")
    action.logic, action.buildPanelLogic = action.buildPanelLogic, nil
    W.vanilla = function() use(sack) end
    ISHandcraftAction.performRecipe(action)
    check("20 手工製作：螺絲起子與剪刀回主背包", driver.container == main and scissors.container == main and #W.sends == 2)
    check("20 診斷行", printed('recipe="ScrapSack" used up Base.EmptySandbag that still held 2 item(s)') == 1, log())
    load()
    main = container("main")
    sack = bag(nil, main)
    driver = item(nil, sack.inv)
    action = build({ main })
    action.logic, action.buildPanelLogic = action.buildPanelLogic, nil
    W.vanilla = function() use(sack) end
    ISBuildIsoEntity.create(action)
    check("20 建造只認 buildPanelLogic", driver.container == sack.inv and #W.sends == 0)

    -- 21 單人也安裝、同一套
    load({ mode = "sp" })
    main = container("main")
    sack = bag(nil, main)
    driver = item(nil, sack.inv)
    W.vanilla = function() use(sack) end
    ISBuildIsoEntity.create(build({ main }))
    check("21 單人：放回主背包", ISBuildIsoEntity[NAME] ~= nil and driver.container == main)

    -- 22 同一個袋子在清單裡出現兩次：只搬一次
    load()
    main = container("main")
    sack = bag(nil, main)
    driver = item(nil, sack.inv)
    W.adds = {}
    W.vanilla = function() use(sack) end
    ISBuildIsoEntity.create(build({ main, main }))
    check("22 重複列出只搬一次、只記一行", #W.adds == 1 and #W.sends == 1 and #W.prints == 1, log())

    -- 23 配方名：拿不到寫 ?；引號與控制字元換掉、截 48 字
    load()
    main = container("main")
    sack = bag(nil, main)
    driver = item(nil, sack.inv)
    W.vanilla = function() use(sack) end
    ISBuildIsoEntity.create(build({ main }, false))
    check("23 沒有配方物件：recipe=\"?\"、照樣放回、沒有錯誤行", driver.container == main and printed('recipe="?" used up') == 1
        and printed("could not") == 0, log())
    consume('bad"name\n' .. string.rep("x", 60))
    check("23 引號與換行換成 ?、截 48 字", printed('recipe="bad?name?' .. string.rep("x", 39) .. '" used up') == 1, log())

    -- 24 動作開始後才放到角色旁邊地上的袋子：不在 logic 的清單裡，完成時原版照樣會用到
    load()
    main = container("main")
    sq = square(-1, 1)
    sack = bag()
    sq:AddWorldInventoryItem(sack, 0.2, 0.7, 0)
    driver = item(nil, sack.inv)
    W.drops = {}
    W.vanilla = function() use(sack) end
    ISBuildIsoEntity.create(build({ main }))
    check("24 清單沒列的地上袋子：螺絲起子放回它那一格", onGround(driver) and driver.worldItem.sq == sq and #W.drops == 1
        and W.drops[1].x == 0.2 and W.drops[1].y == 0.7 and #sq.objects == 1, log())
    load()
    main = container("main")
    sack = bag(nil, main)
    driver = item(nil, sack.inv)
    W.noSquare = true
    W.vanilla = function() use(sack) end
    ISBuildIsoEntity.create(build({ main }))
    check("24 角色沒有所在格：清單裡的照樣處理、沒有錯誤行", driver.container == main and printed("could not") == 0, log())
    -- 角色在二樓：只看同一層。一樓同座標那個袋子沒被掃到，被用掉也不管（原版完成時也只收同一層）
    load()
    main = container("main")
    W.at = square(0, 0, 1)
    sq = square(1, 0, 1)
    sack = bag()
    sq:AddWorldInventoryItem(sack, 0.5, 0.5, 0)
    driver = item(nil, sack.inv)
    local below = bag()
    square(1, 0, 0):AddWorldInventoryItem(below, 0.5, 0.5, 0)
    other = item("Base.Hammer", below.inv)
    W.vanilla = function() use(sack) use(below) end
    ISBuildIsoEntity.create(build({ main }))
    check("24 二樓：同一層的袋子放回它那一格、樓下的沒被記到", onGround(driver) and driver.worldItem.sq == sq and other.container == below.inv
        and #W.prints == 1, log())

    -- 25 車廂（或箱子）裡的背包裡的袋子：背包的內部送不到客戶端。照樣放回背包，再把背包從車廂整件重送（先移除再加入）
    load()
    main = container("main")
    crate = container("crate", nil, { parent = {} })
    local pack = bag("Base.Bag_Schoolbag", crate)
    sack = bag(nil, pack.inv)
    driver = item(nil, sack.inv)
    W.vanilla = function() use(sack) end
    ISBuildIsoEntity.create(build({ main, crate, pack.inv }))
    check("25 放回背包、診斷行寫放回原容器", driver.container == pack.inv and #main.items == 0
        and printed("put them back in the container it was in.") == 1, log())
    check("25 背包整件重送：先移除再加入，都送到它所在的容器", #W.sends == 3
        and W.sends[2].kind == "remove" and W.sends[2].to == crate and W.sends[2].item == pack
        and W.sends[3].kind == "add" and W.sends[3].to == crate and W.sends[3].item == pack, #W.sends)

    -- 車廂裡的背包裡的背包裡的袋子：往外找到第一件「所在容器送得到」的（最外面那個背包）重送
    load()
    main = container("main")
    crate = container("crate", nil, { parent = {} })
    pack = bag("Base.Bag_Schoolbag", crate)
    local pouch = bag("Base.Bag_FannyPackFront", pack.inv)
    sack = bag(nil, pouch.inv)
    driver = item(nil, sack.inv)
    W.vanilla = function() use(sack) end
    ISBuildIsoEntity.create(build({ main, pouch.inv }))
    check("25 兩層背包：放回內層背包、重送最外面那個背包", driver.container == pouch.inv and #W.sends == 3
        and W.sends[2].kind == "remove" and W.sends[2].to == crate and W.sends[2].item == pack
        and W.sends[3].kind == "add" and W.sends[3].item == pack, #W.sends)

    -- 同一個送不到的背包裡兩個袋子一次被用掉：每放回一袋就重送一次，最後一次重送時兩袋的東西都已經在背包裡
    load()
    main = container("main")
    crate = container("crate", nil, { parent = {} })
    pack = bag("Base.Bag_Schoolbag", crate)
    sack = bag(nil, pack.inv)
    local sack2 = bag(nil, pack.inv)
    driver = item(nil, sack.inv)
    other = item("Base.Hammer", sack2.inv)
    W.vanilla = function() use(sack) use(sack2) end
    ISBuildIsoEntity.create(build({ main, pack.inv }))
    local last = W.sends[#W.sends]
    check("25 同一個背包兩袋：兩件都放回、重送兩次、最後一個封包是加入那個背包", driver.container == pack.inv and other.container == pack.inv
        and #W.sends == 6 and W.sends[5].kind == "remove" and last.kind == "add" and last.item == pack and last.to == crate, #W.sends)

    -- 26 地上的背包裡的袋子：背包還在地上就放回背包；背包也被用掉（引用還留著）就改放主背包
    load()
    main = container("main")
    sq = square(0, 1)
    outer = bag()
    sq:AddWorldInventoryItem(outer, 0.5, 0.5, 0)
    inner = bag(nil, outer.inv)
    driver = item(nil, inner.inv)
    W.vanilla = function() use(inner) end
    ISBuildIsoEntity.create(build({ main, outer.inv }))
    check("26 地上的背包還在：放回背包、送的是它的內部", driver.container == outer.inv and #W.sends == 1 and W.sends[1].to == outer.inv, log())
    load()
    main = container("main")
    sq = square(0, 1)
    outer = bag()
    sq:AddWorldInventoryItem(outer, 0.5, 0.5, 0)
    inner = bag(nil, outer.inv)
    driver = item(nil, inner.inv)
    local other = item("Base.Nails", outer.inv)
    W.vanilla = function() use(inner) use(outer) end
    ISBuildIsoEntity.create(build({ main, outer.inv }))
    check("26 地上的背包也被用掉：內層的東西改放主背包、外層自己的東西留在那一格", driver.container == main and onGround(other)
        and other.worldItem.sq == sq, log())
    -- 地上的袋子 A 裡的背包 B 裡的袋子 C：B 的內部送不到，重送 B 到 A 的內部（A 在地上，送得到）
    load()
    main = container("main")
    sq = square(0, 1)
    outer = bag()
    sq:AddWorldInventoryItem(outer, 0.5, 0.5, 0)
    local mid = bag("Base.Bag_Schoolbag", outer.inv)
    inner = bag(nil, mid.inv)
    driver = item(nil, inner.inv)
    W.vanilla = function() use(inner) end
    ISBuildIsoEntity.create(build({ main, mid.inv }))
    check("26 地上袋子裡的背包裡的袋子：放回背包、把背包重送到地上那個袋子裡", driver.container == mid.inv and #W.sends == 3
        and W.sends[2].kind == "remove" and W.sends[2].to == outer.inv and W.sends[2].item == mid
        and W.sends[3].kind == "add" and W.sends[3].to == outer.inv and W.sends[3].item == mid, #W.sends)
    -- 同上，但地上的 A 也被用掉（引用還留著）：鏈斷了，不重送、不出錯；B 連同放回去的東西跟著 A 的內容回到那一格
    load()
    main = container("main")
    sq = square(0, 1)
    outer = bag()
    sq:AddWorldInventoryItem(outer, 0.5, 0.5, 0)
    mid = bag("Base.Bag_Schoolbag", outer.inv)
    inner = bag(nil, mid.inv)
    driver = item(nil, inner.inv)
    W.vanilla = function() use(inner) use(outer) end
    ISBuildIsoEntity.create(build({ main, mid.inv, outer.inv }))
    local resent = 0
    for _, s in ipairs(W.sends) do if s.kind == "remove" then resent = resent + 1 end end
    check("26 外層的外層也被用掉：不重送、沒有錯誤行、背包回到那一格", driver.container == mid.inv and onGround(mid) and mid.worldItem.sq == sq
        and resent == 0 and printed("could not") == 0, resent .. " | " .. log())

    -- 27 不是玩家的角色身上的袋子裡：送不到客戶端（那一條只認玩家），放回後把外層那個袋子重送
    load()
    main = container("main")
    local body = container("npc", nil, { owner = { _class = "IsoZombie" } })
    outer = bag(nil, body)
    sack = bag(nil, outer.inv)
    driver = item(nil, sack.inv)
    W.vanilla = function() use(sack) end
    ISBuildIsoEntity.create(build({ main, outer.inv }))
    check("27 非玩家角色身上的袋子裡：放回原處、外層袋子重送", driver.container == outer.inv and #W.sends == 3
        and W.sends[2].kind == "remove" and W.sends[2].item == outer and W.sends[3].kind == "add" and W.sends[3].to == body, #W.sends)

    -- 28 地上放不成（Java 端出錯，Lua 拿到 nil）：塞回袋裡、記失敗、不記成放回了
    load()
    main = container("main")
    sq = square(1, 1)
    sack = bag()
    sq:AddWorldInventoryItem(sack, 0.5, 0.5, 0)
    driver = item(nil, sack.inv)
    driver.dropFail = true
    a = item("Base.Plank", sack.inv)
    W.vanilla = function() use(sack) end
    ISBuildIsoEntity.create(build({ main }))
    check("28 放不成的那件還在袋裡、另一件照樣放到地上", driver.container == sack.inv and not onGround(driver) and onGround(a), log())
    check("28 記失敗一行、放回的只算一件", printed("1 item(s) are still inside a used-up Base.Garbagebag") == 1
        and printed("still held 1 item(s); put them back on its square.") == 1 and #W.prints == 2, log())

    -- 物品落地之後 Java 端才出錯：已經在地上，不塞回袋裡（不然同一件既在地上又在已經用掉的袋裡）
    load()
    main = container("main")
    sq = square(1, 1)
    sack = bag()
    sq:AddWorldInventoryItem(sack, 0.5, 0.5, 0)
    driver = item(nil, sack.inv)
    driver.dropHalf = true
    W.vanilla = function() use(sack) end
    ISBuildIsoEntity.create(build({ main }))
    check("28 落地後才出錯：留在地上、不在袋裡、沒有失敗行", onGround(driver) and driver.container == nil and #sack.inv.items == 0
        and printed("could not") == 0 and printed("put them back on its square.") == 1, log())

    -- 29 車上的容器：放回後照原版重算內容量
    load()
    main = container("main")
    local part = { setContainerContentAmount = function(_, v) W.parts[#W.parts + 1] = v end }
    local trunk = container("trunk", nil, { parent = {}, part = part })
    part.getItemContainer = function() return trunk end
    sack = bag(nil, trunk)
    driver = item(nil, sack.inv)
    a = item("Base.Plank", sack.inv)
    W.vanilla = function() use(sack) end
    ISBuildIsoEntity.create(build({ main, trunk }))
    check("29 放回車廂、重算一次、值是放回後的內容量", driver.container == trunk and a.container == trunk and #W.parts == 1 and W.parts[1] == 2,
        #W.parts .. ":" .. tostring(W.parts[1]))
    -- 車廂裡的書包裡的袋子：放回書包，重算的是最外層那個車廂（客戶端收到重送的封包也會重算，兩端要一樣）
    load()
    main = container("main")
    trunk = container("trunk", nil, { parent = {}, part = part })
    pack = bag("Base.Bag_Schoolbag", trunk)
    sack = bag(nil, pack.inv)
    driver = item(nil, sack.inv)
    W.vanilla = function() use(sack) end
    ISBuildIsoEntity.create(build({ main, trunk, pack.inv }))
    check("29 車廂裡的書包裡的袋子：放回書包、車廂重算一次、書包重送", driver.container == pack.inv and #W.parts == 1 and W.parts[1] == 1
        and #W.sends == 3 and W.sends[3].kind == "add" and W.sends[3].to == trunk, #W.parts .. "/" .. #W.sends)
    -- 袋裡的東西都是材料、全被這次配方用掉：沒有要放回的，什麼都不做
    load()
    main = container("main")
    trunk = container("trunk", nil, { parent = {}, part = part })
    sack = bag(nil, trunk)
    a = item("Base.Plank", sack.inv)
    W.vanilla = function() use(a) use(sack) end
    ISBuildIsoEntity.create(build({ main, trunk }))
    check("29 袋裡的東西全被用掉：不重算、不送、不印", #W.parts == 0 and #W.sends == 0 and #W.prints == 0, log())

    -- 30 兩個袋子，第一個放回時出錯：第二個照樣放回
    load()
    main = container("main")
    local s1, s2 = bag(nil, main), bag(nil, main)
    local d1, d2 = item(nil, s1.inv), item("Base.Nails", s2.inv)
    W.vanilla = function() use(s1) use(s2) s1.broken = true return "done" end
    ok, ret = pcall(ISBuildIsoEntity.create, build({ main }))
    check("30 第一個出錯不外洩、第二個照樣放回", ok and ret == "done" and d1.container == s1.inv and d2.container == main, log())
    check("30 錯誤一行、放回一行", printed("could not keep what a used-up container held") == 1 and printed("still held 1 item(s)") == 1
        and #W.prints == 2, log())

    return checks, failures
end

-- ── 主程式 ───────────────────────────────────────────────────────
local MUTANTS = {
    { name = "多人客戶端也安裝", subs = { { ' or isClient() then return end', ' then return end' } } },
    { name = "API 形狀不看 sendAddItemToContainer", subs = { { 'type(instanceof) == "function" and type(sendAddItemToContainer) == "function"', 'type(instanceof) == "function"' } } },
    { name = "API 形狀不看 instanceof", subs = { { 'type(instanceof) == "function" and type(sendAddItemToContainer) == "function"', 'type(sendAddItemToContainer) == "function"' } } },
    { name = "API 形狀不看 sendRemoveItemFromContainer", subs = { { 'and type(sendRemoveItemFromContainer) == "function" and', "and" } } },
    { name = "API 形狀不看 getCell", subs = { { ' and type(getCell) == "function") then', ") then" } } },
    { name = "不檢查類別是不是表", subs = { { 'if type(cls) ~= "table" or ', "if " } } },
    { name = "不檢查方法是不是函式", subs = { { ' or type(cls[method]) ~= "function" then', " then" } } },
    { name = "形狀不符不印", subs = { { '        warnOnce("shape:" .. className, "NOT installed: vanilla " .. className .. " shape changed; re-check docs/fixes.md.")\n', "" } } },
    { name = "重複安裝照樣再包", subs = { { "    if cls[NAME] == cls[method] then return end\n", "" } } },
    { name = "不存 sentinel", subs = { { "    cls[NAME] = wrapper\n", "" } } },
    { name = "不掛復查事件", subs = { { "    Events.OnInitGlobalModData.Add(install)\n", "" } } },
    { name = "建造也用 logic 欄位", subs = { { 'wrap(ISBuildIsoEntity, "ISBuildIsoEntity", "create", "buildPanelLogic")', 'wrap(ISBuildIsoEntity, "ISBuildIsoEntity", "create", "logic")' } } },
    { name = "手工製作用 buildPanelLogic 欄位", subs = { { 'wrap(ISHandcraftAction, "ISHandcraftAction", "performRecipe", "logic")', 'wrap(ISHandcraftAction, "ISHandcraftAction", "performRecipe", "buildPanelLogic")' } } },
    { name = "不傳參數給原函式", subs = { { "local result = original(self, ...)", "local result = original(self)" } } },
    { name = "不回傳原函式的結果", subs = { { "        return result\n", "        return true\n" } } },
    { name = "pcall 原函式（吞掉它的錯）", subs = { { "local result = original(self, ...)", "local _, result = pcall(original, self, ...)" } } },
    { name = "沒有 logic 也記錄", subs = { { "        if logic then\n", "        if true then\n" } } },
    { name = "記錄那段不 pcall", subs = { { "ok, held = pcall(snapshot, logic, self.character)", "ok, held = true, snapshot(logic, self.character)" } } },
    { name = "放回那段不 pcall", subs = { { "local done, err = pcall(putBack, self, held[i])", "local done, err = true, putBack(self, held[i])" } } },
    { name = "出錯不印", subs = { { "                if not done then failed(err) end\n", "" } } },
    { name = "一個袋子出錯後面的就不處理", subs = { { "if not done then failed(err) end", "if not done then failed(err) break end" } } },
    { name = "記錄出錯不印", subs = { { "            if not ok then failed(held) end\n", "" } } },
    { name = "警告不節流", subs = { { "    if warned[key] then return end\n", "" } } },
    { name = "一般物品也當容器", subs = { { 'if not instanceof(item, "InventoryContainer") or item:getInventory():isEmpty() then return end', "if item:getInventory():isEmpty() then return end" } } },
    { name = "已經移出格子的世界物件也算在地上", subs = { { "if wi and wi:getWorldObjectIndex() ~= -1 then return wi end", "if wi then return wi end" } } },
    { name = "用掉的判斷不看地上", subs = { { "return item:getContainer() == nil and worldItemOf(item) == nil", "return item:getContainer() == nil" } } },
    { name = "用掉的判斷不看容器", subs = { { "return item:getContainer() == nil and worldItemOf(item) == nil", "return worldItemOf(item) == nil" } } },
    { name = "袋子還在也搬", subs = { { "    if not gone(bag) then return end\n", "" } } },
    { name = "過期項目也記", subs = { { "        if rec.home == nil then return end\n", "" } } },
    { name = "地上的袋子記成在容器裡", subs = { { "    if wi then\n", "    if false then\n" } } },
    { name = "不看角色旁邊的地上", subs = { { "    local at = character:getSquare()\n", "    local at = nil\n" } } },
    { name = "只看角色腳下那一格（x）", subs = { { "for x = at:getX() - 1, at:getX() + 1 do", "for x = at:getX(), at:getX() do" } } },
    { name = "只看角色腳下那一格（y）", subs = { { "for y = at:getY() - 1, at:getY() + 1 do", "for y = at:getY(), at:getY() do" } } },
    { name = "角色沒有所在格不防", subs = { { "    if at then\n", "    if true then\n" } } },
    { name = "格子沒載入不防", subs = { { "local objects = sq and sq:getWorldObjects()", "local objects = sq:getWorldObjects()" } } },
    { name = "地上放回固定位置", subs = { { "rec.sq:AddWorldInventoryItem(item, rec.x, rec.y, rec.z)", "rec.sq:AddWorldInventoryItem(item, 0.5, 0.5, 0)" } } },
    { name = "放到地上前不從袋子拿掉", subs = { { "            inv:Remove(item)\n", "" } } },
    { name = "放回容器不送給客戶端", subs = { { "            sendAddItemToContainer(home, item)\n", "" } } },
    { name = "一律放主背包", subs = { { "if home == nil or (outer and gone(outer)) then", "if true then" } } },
    { name = "袋中袋不改道", subs = { { "if home == nil or (outer and gone(outer)) then", "if home == nil then" } } },
    { name = "原本在地上的沒有備用容器", subs = { { "if home == nil or (outer and gone(outer)) then", "if outer and gone(outer) then" } } },
    { name = "外層還在也改放主背包", subs = { { "(outer and gone(outer))", "outer" } } },
    { name = "袋裡的東西全被用掉也往下跑", subs = { { "    if inv:isEmpty() then return end", "" } } },
    { name = "地上的只掃一樓", subs = { { "local sq = cell:getGridSquare(x, y, at:getZ())", "local sq = cell:getGridSquare(x, y, 0)" } } },
    { name = "車上背包的內部不重算車廂", subs = { { "home:getOutermostContainer():getVehiclePart()", "home:getVehiclePart()" } } },
    { name = "已經落地的也塞回袋裡", subs = { { " and worldItemOf(item) == nil then inv:AddItem(item) end", " then inv:AddItem(item) end" } } },
    { name = "放不成的不塞回袋裡", subs = { { " and worldItemOf(item) == nil then inv:AddItem(item) end", " then end" } } },
    { name = "送不到也不重送", subs = { { "    if not reachable(home) then resend(home) end\n", "" } } },
    { name = "送得到也重送", subs = { { "if not reachable(home) then resend(home) end", "resend(home)" } } },
    { name = "重送只加入不先移除", subs = { { "            sendRemoveItemFromContainer(outer, top)\n", "" } } },
    { name = "重送只移除不加入", subs = { { "            sendAddItemToContainer(outer, top)\n", "" } } },
    { name = "重送先加入再移除", subs = { {
        "            sendRemoveItemFromContainer(outer, top)\n            sendAddItemToContainer(outer, top)\n",
        "            sendAddItemToContainer(outer, top)\n            sendRemoveItemFromContainer(outer, top)\n" } } },
    { name = "鏈斷了不防", subs = { { "        if outer == nil then return end\n", "" } } },
    { name = "重送不往外找", subs = { { "        top = outer:getContainingItem()\n", "        top = nil\n" } } },
    { name = "送得到的判斷拿掉玩家那一條", subs = { { '    if who and instanceof(who, "IsoPlayer") then return true end\n', "" } } },
    { name = "不看是不是玩家", subs = { { 'if who and instanceof(who, "IsoPlayer") then return true end', "if who then return true end" } } },
    { name = "送得到的判斷拿掉世界物件那一條", subs = { { "    if container:getParent() then return true end\n", "" } } },
    { name = "送得到的判斷拿掉地上袋子那一條", subs = { { "return holder ~= nil and worldItemOf(holder) ~= nil", "return false" } } },
    { name = "地上袋子那一條不看還在不在格子上", subs = { { "return holder ~= nil and worldItemOf(holder) ~= nil", "return holder ~= nil and holder:getWorldItem() ~= nil" } } },
    { name = "車上的容器不重算內容量", subs = { { "    if part then part:setContainerContentAmount(part:getItemContainer():getCapacityWeight()) end\n", "" } } },
    { name = "由前往後搬", subs = { { "for j = count - 1, 0, -1 do", "for j = 0, count - 1 do" } } },
    { name = "不讀回有沒有搬走", subs = { { "    if left > 0 then failed(", "    if false then failed(" } } },
    { name = "一件都沒搬也記成放回了", subs = { { "if left < count then report(", "if true then report(" } } },
    { name = "件數不扣沒搬走的", subs = { { "report(action, bag, count - left, where)", "report(action, bag, count, where)" } } },
    { name = "不記診斷行", subs = { { "    if left < count then report(action, bag, count - left, where) end\n", "" } } },
    { name = "地上的也寫成容器", subs = { { 'local where = rec.sq and "on its square" or home == rec.home', "local where = home == rec.home" } } },
    { name = "改道的也寫成放回原容器", subs = { { 'home == rec.home and "in the container it was in" or "in the player\'s main inventory"', '"in the container it was in"' } } },
    { name = "同一種配方重複算進上限", subs = { { '    if warned["used:" .. name] then return end\n', "" } } },
    { name = "診斷行沒有上限", subs = { { "if logged >= LOG_LIMIT then", "if false then" } } },
    { name = "不累計已記的配方數", subs = { { "    logged = logged + 1\n", "" } } },
    { name = "上限少一種", subs = { { "local LOG_LIMIT = 20", "local LOG_LIMIT = 19" } } },
    { name = "沒有配方物件時不防", subs = { { 'recipe and recipe:getName() or "?"', "recipe:getName()" } } },
    { name = "配方名不清引號", subs = { { 'local name = clip(recipe and recipe:getName() or "?")', 'local name = tostring(recipe and recipe:getName() or "?")' } } },
    { name = "配方名不截短", subs = { { '"[%c\\"]", "?")), 1, 48))', '"[%c\\"]", "?")), 1, 480))' } } },
}

local function applySubs(src, subs)
    for _, sub in ipairs(subs) do
        local from, to = sub[1], sub[2]
        local s, e = src:find(from, 1, true)
        if not s then return nil, "pattern not found: " .. from end
        if src:find(from, e + 1, true) then return nil, "pattern not unique: " .. from end
        src = src:sub(1, s - 1) .. to .. src:sub(e + 1)
    end
    return src
end

if arg and arg[1] == "--mutants" then
    local survived, broken = 0, 0
    for _, m in ipairs(MUTANTS) do
        local src, why = applySubs(SOURCE, m.subs)
        if not src then
            broken = broken + 1
            realPrint("  BROKEN    " .. m.name .. " — " .. why)
        else
            local ok, checks, failures = pcall(runSuite, src, true)
            print = realPrint
            if ok and failures == 0 then
                survived = survived + 1
                realPrint(string.format("  SURVIVED  %s（%d 項全綠）", m.name, checks))
            else
                realPrint(string.format("  KILLED    %s（%s）", m.name,
                    ok and (failures .. "/" .. checks .. " 項轉紅") or ("拋錯 " .. tostring(checks))))
            end
        end
    end
    realPrint("")
    realPrint(string.format("%d mutants, %d survived, %d broken", #MUTANTS, survived, broken))
    os.exit((survived == 0 and broken == 0) and 0 or 1)
end

local checks, failures = runSuite(SOURCE, false)
print = realPrint
realPrint("")
realPrint(string.format("%d checks, %d failed", checks, failures))
os.exit(failures == 0 and 0 or 1)
