-- MDFX_SledgehammerGuard 離線自我檢查
-- 用法（repo 根目錄）： lua scripts/test_sledgehammer_guard.lua [--mutants]
--
-- 照載本機遊戲的原版 shared/TimedActions/ISDestroyStuffAction.lua（PZ_HOME 可改安裝目錄），大錘完成的那一段全部由原版做；
-- Java 端用 Lua 照形狀模擬：格子的物件清單、多格圖塊組（SpriteGrid）、getCell():getGridSquare（沒建過的格子＝沒載入）、
-- transmitRemoveItemFromSquare 的一個參數版（多格時整組找得齊才移除，找不齊回 -1；IsoGridSquare.java:5933-5960）
-- 與兩個參數版（false＝只移除那一片）。
-- 驗證：
--   * 對照組（不載補丁）重現：完整的 2x2 巨石敲一下整組消失；只剩兩片的巨石 complete 回 true、物件還在
--   * 修正組：完整的照原版（引擎只被呼叫一次）；缺片的敲哪片少哪片、回傳值不變、診斷行恰一次
--   * 原版或外層／內層的包裝回 false（安全屋限定、權限拒絕）時不動
--   * 原函式被整支換成沒有原版伺服器規則的版本時，照原版規則先擋（沒大錘、太遠、限定安全屋、目標已不在）；拒絕記 log
--     （每個連線有上限、名稱淨化、目標已不在不記）；檢查本身出錯時原樣重拋、不呼叫原函式
--   * 原版回 true 而留著的不是多格圖塊（別的 MOD 原地換牆）、或留著的是整組都在的多格物件：不動
--   * 缺的那幾格沒載入：不當成缺片；確定缺片而引擎這次移得掉：照引擎的結果；單片移除沒成功：報失敗、不報 removed
--   * 有 component 的殘片不動（原版沒倒 component 的內容）
--   * 自己那段拋錯：照回原版結果、只印一次；原版拋錯原樣外洩
--   * 形狀不符印 NOT installed；重複載入不疊；後載 MOD 替換後 OnInitGlobalModData 再包一層（OnGameBoot 在單人載 server/ 前就觸發過，不算）；多人客戶端不安裝
--   * 官方修好（引擎不再拒絕）時補丁不介入
-- --mutants：逐一抽掉每道防線，確認至少一項檢查轉紅。

local PZ_HOME = os.getenv("PZ_HOME") or "D:/SteamLibrary/steamapps/common/ProjectZomboid"
local VANILLA = PZ_HOME .. "/media/lua/shared/TimedActions/ISDestroyStuffAction.lua"
local FIX = "MOD/MinidoracatFixesFor42/Contents/mods/MinidoracatFixesFor42/42/media/lua/server/Fixes/MDFX_SledgehammerGuard.lua"

local realPrint = print

local function readFile(path)
    local f = assert(io.open(path, "rb"))
    local s = f:read("*a")
    f:close()
    return s
end

local SOURCES = { vanilla = readFile(VANILLA), fix = readFile(FIX) }

-- ── 假 Java 端 ─────────────────────────────────────────────────────
local prints, bootHandlers, W, opts

-- 格子與圖塊組位置的鍵：底層沿用 "x,y"，其他樓層是 "x,y,z"
local function key(x, y, z)
    return (z or 0) == 0 and x .. "," .. y or x .. "," .. y .. "," .. z
end

-- names 依樓層、y、x 排；levels 省略＝1 層
local function makeGrid(w, h, names, levels)
    local grid = { w = w, h = h, levels = levels or 1, cells = {} }
    function grid:getWidth() return self.w end
    function grid:getHeight() return self.h end
    function grid:getLevels() return self.levels end
    function grid:getSpriteGridPosX(spr) return spr.gx end
    function grid:getSpriteGridPosY(spr) return spr.gy end
    function grid:getSpriteGridPosZ(spr) return spr.gz end
    function grid:getSprite(x, y, z) return self.cells[key(x, y, z)] end
    for gz = 0, grid.levels - 1 do
        for gy = 0, h - 1 do
            for gx = 0, w - 1 do
                local name = names[gz * w * h + gy * w + gx + 1]
                if name then -- 沒有名字＝圖塊組在這個位置沒有圖塊
                    local props = { has = function() return false end }
                    local spr = { name = name, grid = grid, gx = gx, gy = gy, gz = gz }
                    function spr:getName() return self.name end
                    function spr:getSpriteGrid() return self.grid end
                    function spr:getProperties() return props end
                    grid.cells[key(gx, gy, gz)] = spr
                end
            end
        end
    end
    return grid
end


local function plainSprite(name)
    local props = { has = function() return false end }
    return { name = name, getName = function() return name end, getSpriteGrid = function() return nil end,
        getProperties = function() return props end }
end

local function newWorld()
    local world = { squares = {}, safe = 0, single = 0, dumps = 0, engineFixed = false }
    local function indexOf(sq, obj)
        for i = 1, #sq.objs do
            if sq.objs[i] == obj then return i end
        end
        return nil
    end
    local function removeOne(obj)
        local sq = obj.sq
        table.remove(sq.objs, indexOf(sq, obj))
    end
    -- IsoObjectUtils.getSpriteGridMultiTileObjects：每一格都要有那一格的圖塊，缺一片就整組找不齊
    local function findAll(obj)
        local grid, spr, found = obj.sprite.grid, obj.sprite, {}
        for gz = 0, grid.levels - 1 do
            for gx = 0, grid.w - 1 do
                for gy = 0, grid.h - 1 do
                    local sq = world.squares[key(obj.sq.x - spr.gx + gx, obj.sq.y - spr.gy + gy, obj.sq.z - spr.gz + gz)]
                    local hit = nil
                    for i = 1, sq and #sq.objs or 0 do
                        if sq.objs[i].sprite == grid.cells[key(gx, gy, gz)] then hit = sq.objs[i] break end
                    end
                    if not hit then return nil end
                    found[#found + 1] = hit
                end
            end
        end
        return found
    end
    function world.square(x, y, z)
        local k = key(x, y, z)
        local sq = world.squares[k]
        if sq then return sq end
        sq = { x = x, y = y, z = z or 0, objs = {} }
        function sq:getX() return self.x end
        function sq:getY() return self.y end
        function sq:getZ() return self.z end
        function sq:getWall() return nil end
        function sq:getObjects()
            local objs = self.objs
            return { size = function() return #objs end, get = function(_, i) return objs[i + 1] end }
        end
        function sq:transmitRemoveItemFromSquare(obj, safely)
            if safely == nil then safely = true end
            if safely then world.safe = world.safe + 1 else world.single = world.single + 1 end
            local index = obj and indexOf(self, obj)
            if not index then return -1 end
            if safely and obj.sprite.grid then
                local parts = findAll(obj)
                if parts then
                    for i = 1, #parts do removeOne(parts[i]) end
                    return index - 1
                end
                if not world.engineFixed then return -1 end
            end
            if not safely and world.singleBroken then return nil end -- Java 端例外：Lua 拿到 nil，物件沒動
            removeOne(obj)
            return index - 1
        end
        world.squares[k] = sq
        return sq
    end
    function world.object(x, y, sprite, z)
        local sq = world.square(x, y, z)
        local o = { _class = "IsoObject", sprite = sprite, sq = sq }
        function o:getSprite() return self.sprite end
        function o:getSpriteGrid()
            if self.throwGrid then error("boom grid") end
            return self.sprite:getSpriteGrid()
        end
        function o:getSquare() return self.sq end
        function o:getProperties() return self.sprite:getProperties() end
        function o:getObjectIndex() return (indexOf(self.sq, self) or 0) - 1 end
        function o:dumpContentsInSquare() world.dumps = world.dumps + 1 end
        function o:componentSize() return self.components or 0 end
        sq.objs[#sq.objs + 1] = o
        return o
    end
    function world.has(x, y, name)
        local sq = world.squares[x .. "," .. y]
        for i = 1, sq and #sq.objs or 0 do
            if sq.objs[i].sprite.name == name then return true end
        end
        return false
    end
    return world
end

local BOULDER = { "boulders_19", "boulders_18", "boulders_16", "boulders_17" } -- 0,0／1,0／0,1／1,1

-- 完整巨石在 (1..2, 0..1)；殘缺巨石只剩 (4,0) 的 19 與 (4,1) 的 16，缺的 (5,0)、(5,1) 載入了、上面是別的東西；
-- (7,0) 是不屬於多格圖塊組的牆
local function buildWorld()
    W = newWorld()
    local g1, g2 = makeGrid(2, 2, BOULDER), makeGrid(2, 2, BOULDER)
    local t = {}
    t.full = W.object(1, 0, g1.cells["0,0"])
    W.object(2, 0, g1.cells["1,0"])
    W.object(1, 1, g1.cells["0,1"])
    t.fullFar = W.object(2, 1, g1.cells["1,1"])
    t.half19 = W.object(4, 0, g2.cells["0,0"])
    t.half16 = W.object(4, 1, g2.cells["0,1"])
    W.object(5, 0, plainSprite("vegetation_groundcover_01_0"))
    W.object(5, 1, plainSprite("vegetation_groundcover_01_1"))
    t.wall = W.object(7, 0, plainSprite("walls_exterior_house_01_0"))
    return t
end

local SLEDGE = { broken = false }
function SLEDGE.isBroken() return SLEDGE.broken end
function SLEDGE.getType() return "Sledgehammer" end
function SLEDGE.hasTag() return true end
function SLEDGE.damageCheck()
    if opts.breakOnHit then SLEDGE.broken = true end -- 這一下把大錘用壞
    return false
end

-- opts.noSledge＝背包沒有大錘；opts.buildCheat＝建造作弊；opts.privileged＝角色的身分有 UseBuildCheat；opts.name＝客戶端給的名稱；
-- SteamID 固定 76561198000000016（16 的倍數，轉成浮點數不失真）。
-- 多人的一般玩家有身分、只是沒有那項權限；單人沒有身分（nil）
local function player(x, y)
    local inv = { getFirstEvalRecurse = function(_, pred) return not opts.noSledge and pred(SLEDGE) and SLEDGE or nil end }
    local role = { hasCapability = function(_, cap) return opts.privileged == true and cap == "UseBuildCheat" end }
    return { _class = "IsoPlayer", isBuildCheat = function() return opts.buildCheat == true end, isTimedActionInstant = function() return false end,
        getPerkLevel = function() return 5 end, getInventory = function() return inv end, getPrimaryHandItem = function() return SLEDGE end,
        getRole = function() return not opts.sp and role or nil end, getX = function() return x end, getY = function() return y end,
        getZ = function() return 0 end, getUsername = function() return opts.name or "tester" end,
        getOnlineID = function() return opts.onlineID or 7 end, getSteamID = function() return 76561198000000016 end }
end

-- 重設全域、載原版，再視需要載補丁。o.client＝多人客戶端；o.sp＝單人；o.safehouseOnly＝伺服器選項 SledgehammerOnlyInSafehouse；
-- o.safeAllowed＝那一格在安全屋裡（true／false＝這位玩家可不可以用），nil＝不在安全屋
local function setup(srcs, withFix, o)
    opts = o or {}
    SLEDGE.broken = false
    prints, bootHandlers = {}, {}
    print = function(...)
        local t = {}
        for i = 1, select("#", ...) do t[#t + 1] = tostring((select(i, ...))) end
        prints[#prints + 1] = table.concat(t, " ")
    end
    local name = function(_, k) return k end
    require = function() end
    isClient = function() return opts.client == true end
    isServer = function() return not opts.client and not opts.sp end
    getDebug = function() return false end
    instanceof = function(obj, class) return type(obj) == "table" and obj._class == class end
    IsoFlagType = setmetatable({}, { __index = name })
    IsoDirections = setmetatable({}, { __index = name })
    ItemTag = setmetatable({}, { __index = name })
    Capability = setmetatable({}, { __index = name })
    Perks = setmetatable({}, { __index = name })
    CharacterActionAnims = setmetatable({}, { __index = name })
    Metabolics = setmetatable({}, { __index = name })
    getServerOptions = function()
        if opts.optionsThrow then error("boom options") end
        return { getBoolean = function(_, k) return k == "SledgehammerOnlyInSafehouse" and opts.safehouseOnly == true end }
    end
    SafeHouse = { isSafeHouse = function()
        if opts.safeAllowed == nil then return nil end
        return { playerAllowed = function() return opts.safeAllowed end }
    end }
    SCampfireSystem = { instance = { getLuaObjectOnSquare = function() return nil end } }
    local none = function() return {} end
    buildUtil = { getStairObjects = none, getDoubleDoorObjects = none, getGarageDoorObjects = none, getGraveObjects = none }
    addSound = function() end
    ItemUtils = { checkWeapon = function() end }
    getCell = function()
        return { getGridSquare = function(_, x, y, z) return W.squares[key(x, y, z)] end }
    end
    -- OnGameBoot 在單人載 server/ 之前就觸發過了：登記在上面的函式不會再被叫到
    Events = { OnGameBoot = { Add = function() end }, OnInitGlobalModData = { Add = function(f) bootHandlers[#bootHandlers + 1] = f end } }
    ISBaseTimedAction = {}
    function ISBaseTimedAction:derive(type)
        local cls = { Type = type }
        cls.__index = cls
        return cls
    end
    function ISBaseTimedAction.new(cls, character)
        return setmetatable({ character = character }, cls)
    end
    ISDestroyStuffAction = nil
    assert(load(srcs.vanilla, "=ISDestroyStuffAction.lua"))()
    if withFix then assert(load(srcs.fix, "=MDFX_SledgehammerGuard.lua"))() end
end

local function loadFix(srcs)
    assert(load(srcs.fix, "=MDFX_SledgehammerGuard.lua"))()
end

local function fireInit()
    for i = 1, #bootHandlers do bootHandlers[i]() end
end

local function printCount(needle)
    local n = 0
    for i = 1, #prints do
        if string.find(prints[i], needle, 1, true) then n = n + 1 end
    end
    return n
end

-- 站在目標西邊一格敲一下，回 complete 的回傳值
local function hit(obj)
    return ISDestroyStuffAction:new(player(obj.sq.x - 0.5, obj.sq.y + 0.5), obj):complete()
end

local function fullGone()
    return not (W.has(1, 0, "boulders_19") or W.has(2, 0, "boulders_18") or W.has(1, 1, "boulders_16") or W.has(2, 1, "boulders_17"))
end

-- ── 檢查 ───────────────────────────────────────────────────────────
local function runAll(srcs, quiet)
    local checks, failures = 0, 0
    local function check(cond, label)
        checks = checks + 1
        if not cond then
            failures = failures + 1
            if not quiet then realPrint("FAIL " .. label) end
        end
    end
    local function scenario(fn)
        local ok, err = pcall(fn)
        check(ok, "scenario threw: " .. tostring(err))
    end

    -- 對照組：原版的正常情況與缺陷
    scenario(function()
        setup(srcs, false)
        local t = buildWorld()
        check(string.find(srcs.vanilla, "self.item:getSquare():transmitRemoveItemFromSquare(self.item)", 1, true) ~= nil,
            "vanilla still removes the target with the one-argument call")
        check(hit(t.full) == true and fullGone() and W.safe == 1, "control: one hit removes a complete 2x2 boulder")
        check(hit(t.half19) == true and W.has(4, 0, "boulders_19") and W.has(4, 1, "boulders_16"),
            "control: a half boulder survives the hit although complete returns true")
        check(hit(t.half16) == true and W.has(4, 1, "boulders_16"), "control: the other piece survives too")
        check(W.single == 0 and W.dumps == 3, "control: vanilla dumps the contents and never removes a single piece")
    end)

    -- 修正組：完整的照原版，引擎只被呼叫一次
    scenario(function()
        setup(srcs, true)
        local t = buildWorld()
        check(hit(t.full) == true and fullGone(), "fix: a complete 2x2 boulder still goes in one hit")
        check(W.safe == 1 and W.single == 0, "fix: the engine is asked once on the normal path")
        check(hit(t.wall) == true and not W.has(7, 0, "walls_exterior_house_01_0") and W.safe == 2 and W.single == 0,
            "fix: a single-tile object is removed by vanilla alone")
        check(printCount("MDFX_SledgehammerGuard") == 0, "fix: nothing logged when the guard does not act")
    end)

    -- 修正組：建造作弊（不經過原版的大錘檢查）敲完整的，原版移掉之後補丁不再碰
    scenario(function()
        setup(srcs, true, { buildCheat = true, noSledge = true })
        local t = buildWorld()
        check(hit(t.full) == true and fullGone() and W.safe == 1 and W.single == 0 and printCount("MDFX_SledgehammerGuard") == 0,
            "fix: with build cheat a target vanilla already removed is left alone")
    end)

    -- 修正組：缺片的敲哪片少哪片
    scenario(function()
        setup(srcs, true)
        local t = buildWorld()
        check(hit(t.half19) == true, "fix: the hit on a half boulder still returns true")
        check(not W.has(4, 0, "boulders_19") and W.has(4, 1, "boulders_16"), "fix: the piece that was hit is gone, the other one stays")
        check(W.safe == 2 and W.single == 1, "fix: vanilla call, one re-ask, one single-piece removal")
        check(printCount("MDFX_SledgehammerGuard vanilla left boulders_19 at 4,0,0 standing") == 1, "fix: one diagnostic line with sprite and square")
        check(hit(t.half16) == true and not W.has(4, 1, "boulders_16"), "fix: the second piece goes on its own hit")
        check(printCount("MDFX_SledgehammerGuard") == 1, "fix: the second removal is not logged again")
        check(fullGone() == false and W.has(1, 0, "boulders_19"), "fix: the complete boulder next to it is untouched")
    end)

    -- 原版自己回 false（伺服器選項「大錘只能在安全屋用」）：不動
    scenario(function()
        setup(srcs, true, { safehouseOnly = true })
        local t = buildWorld()
        check(hit(t.half19) == false and W.has(4, 0, "boulders_19") and W.safe == 0 and W.single == 0,
            "fix: vanilla refusing the hit leaves the half boulder alone")
    end)

    -- 開服之後才包上來的權限檢查（在外層）拒絕：原函式與補丁都不跑
    scenario(function()
        setup(srcs, true)
        local t = buildWorld()
        local inner = ISDestroyStuffAction.complete
        ISDestroyStuffAction.complete = function(self) return false end
        check(hit(t.half19) == false and W.has(4, 0, "boulders_19") and W.safe == 0 and W.single == 0,
            "fix: an outer permission wrapper that denies keeps the piece")
        ISDestroyStuffAction.complete = inner
    end)

    -- 比補丁早包的拒絕（補丁在外層）：回 false 就不看
    scenario(function()
        setup(srcs, false)
        local t = buildWorld()
        ISDestroyStuffAction.complete = function(self) return false end
        loadFix(srcs)
        check(hit(t.half19) == false and W.has(4, 0, "boulders_19") and W.safe == 0 and W.single == 0,
            "fix: an inner wrapper that returns false is not overridden")
        ISDestroyStuffAction.complete = function(self) return nil end
        loadFix(srcs)
        check(hit(t.half19) == nil and W.safe == 0 and W.single == 0, "fix: a nil result is passed through untouched")
    end)

    -- 整支取代 complete、沒有原版伺服器規則的 MOD（照樣用一個參數的移除、回 true）：本補丁照原版規則先擋，不呼叫它
    scenario(function()
        local calls
        local function replaced(o)
            setup(srcs, false, o)
            local t = buildWorld()
            calls = 0
            ISDestroyStuffAction.complete = function(self)
                calls = calls + 1
                self.item:getSquare():transmitRemoveItemFromSquare(self.item)
                return true
            end
            loadFix(srcs)
            return t
        end
        local t = replaced({ noSledge = true })
        check(hit(t.full) == false and not fullGone() and calls == 0 and W.safe == 0,
            "fix: no sledgehammer by vanilla's rule: refused before the replacement runs, the boulder stays")
        check(printCount("refused a sledgehammer hit (no usable sledgehammer within reach) on boulders_19 at 1,0,0"
            .. " by player=\"tester\" onlineID=7 steamid~76561198000000016 (#1)") == 1,
            "fix: the refusal is logged with rule, target, name, onlineID and SteamID")
        t = replaced({ safehouseOnly = true })
        check(hit(t.full) == false and not fullGone() and calls == 0, "fix: SledgehammerOnlyInSafehouse outside a safehouse: refused")
        check(printCount("(SledgehammerOnlyInSafehouse outside an allowed safehouse)") == 1, "fix: the safehouse refusal names its rule")
        t = replaced({ safehouseOnly = true, safeAllowed = false })
        check(hit(t.full) == false and not fullGone() and calls == 0, "fix: a safehouse that does not allow the player: refused")
        t = replaced({ safehouseOnly = true, sp = true })
        check(hit(t.full) == false and calls == 0, "fix: a character without a role is not privileged")
        t = replaced({ safehouseOnly = true, safeAllowed = true })
        check(hit(t.full) == true and fullGone() and calls == 1, "fix: inside a safehouse that allows the player the hit goes through")
        t = replaced({ safehouseOnly = true, privileged = true })
        check(hit(t.full) == true and fullGone(), "fix: a role with UseBuildCheat is not bound by the safehouse option")
        t = replaced({ noSledge = true, buildCheat = true })
        check(hit(t.full) == true and fullGone(), "fix: build cheat needs no sledgehammer, as in vanilla")
        t = replaced({ buildCheat = true, safehouseOnly = true })
        check(hit(t.full) == false and not fullGone() and calls == 0,
            "fix: build cheat does not exempt from SledgehammerOnlyInSafehouse, as in vanilla")
        t = replaced({})
        check(hit(t.half19) == true and not W.has(4, 0, "boulders_19") and calls == 1 and W.single == 1,
            "fix: an allowed hit on a leftover piece goes through the replacement and the piece is removed")
        check(printCount("refused") == 0, "fix: allowed hits are not logged as refusals")
        t = replaced({})
        check(ISDestroyStuffAction:new(player(t.full.sq.x + 3, t.full.sq.y + 0.5), t.full):complete() == false
            and not fullGone() and calls == 0, "fix: too far from the target by vanilla's rule: refused")
        check(printCount("refused a sledgehammer hit (no usable sledgehammer within reach)") == 1, "fix: the distance refusal is logged")
        t = replaced({})
        table.remove(t.half19.sq.objs, 1) -- 別人先拆掉了：目標已經不在格子上
        check(hit(t.half19) == false and calls == 0 and printCount("refused") == 0,
            "fix: a target already gone is refused like vanilla, without a refusal line")
        replaced({ noSledge = true })
        local weird = ISDestroyStuffAction:new(player(0.5, 0.5), {})
        local ok, r = pcall(weird.complete, weird)
        check(ok and r == false and calls == 0 and printCount("could not log a refused sledgehammer hit") == 1,
            "fix: a failure while logging a refusal still refuses, without an error")
        t = replaced({})
        local nobody = setmetatable({ item = t.full }, ISDestroyStuffAction)
        ok = pcall(nobody.complete, nobody)
        check(not ok and calls == 0 and not fullGone(), "fix: a nil character fails like vanilla, without calling the replacement")
    end)

    -- 拒絕的 log：每個連線每次開機最多 LOG_LIMIT 行，之後一行說明；客戶端給的名稱去掉控制字元與引號
    scenario(function()
        setup(srcs, true, { noSledge = true, name = "bad\nna\"me" })
        local t = buildWorld()
        for _ = 1, 23 do hit(t.half19) end
        check(printCount("refused a sledgehammer hit") == 20 and printCount("reached LOG_LIMIT for player=\"bad?na?me\" onlineID=7") == 1,
            "fix: refusals are logged up to the limit per connection, then one note")
        check(printCount("by player=\"bad?na?me\"") == 20, "fix: control characters and quotes in the name are replaced")
        check(W.has(4, 0, "boulders_19") and W.safe == 0, "fix: nothing is removed by refused hits")
        opts.onlineID = 8
        hit(t.half19)
        check(printCount("refused a sledgehammer hit") == 21 and printCount("onlineID=8 steamid~") == 1,
            "fix: another connection still gets its refusals logged")
    end)

    -- 規則檢查本身出錯（引擎 API 變了）：原版 complete 在同一處也會出錯。原樣重拋、只印一次，不呼叫原函式
    scenario(function()
        setup(srcs, false, { optionsThrow = true })
        local t = buildWorld()
        local calls = 0
        ISDestroyStuffAction.complete = function(self)
            calls = calls + 1
            self.item:getSquare():transmitRemoveItemFromSquare(self.item)
            return true
        end
        loadFix(srcs)
        local ok, err = pcall(hit, t.wall)
        check(not ok and string.find(tostring(err), "boom options", 1, true) and calls == 0
            and W.has(7, 0, "walls_exterior_house_01_0"), "fix: a failing rule check is re-thrown and the replacement does not run")
        ok = pcall(hit, t.full)
        check(not ok and calls == 0 and not fullGone(), "fix: a complete object stays when the rule check fails")
        check(printCount("could not check the server rules for a sledgehammer hit; NOT masking it (re-throwing): ") == 1,
            "fix: the failing check is logged once")
    end)

    -- 目標是 nil：不檢查，交給原函式（原版回 false）
    scenario(function()
        setup(srcs, true)
        buildWorld()
        local a = ISDestroyStuffAction:new(player(0.5, 0.5), nil)
        check(a:complete() == false and printCount("MDFX_SledgehammerGuard") == 0, "fix: a nil target is left to the original")
    end)

    -- 這一下把大錘用壞：規則在原函式之前就過了，和原版一樣這一下照拆
    scenario(function()
        setup(srcs, true, { breakOnHit = true })
        local t = buildWorld()
        check(hit(t.half19) == true and not W.has(4, 0, "boulders_19") and W.single == 1,
            "fix: the hit that breaks the sledgehammer still removes the piece, as vanilla does for a complete object")
    end)

    -- 原版回 true 而物件留著，但不是多格圖塊（別的 MOD 原地換牆）：不動
    scenario(function()
        setup(srcs, false)
        local t = buildWorld()
        ISDestroyStuffAction.complete = function(self) return true end
        loadFix(srcs)
        check(hit(t.wall) == true and W.has(7, 0, "walls_exterior_house_01_0") and W.safe == 0 and W.single == 0,
            "fix: a single-tile object another mod kept in place is not removed")
        -- 留著的是整組都在的多格物件（內層刻意不拆）：沒有缺片的證據，不碰，也不拿移除呼叫去問引擎
        check(hit(t.fullFar) == true and not fullGone() and W.has(2, 1, "boulders_17") and W.safe == 0 and W.single == 0,
            "fix: a complete group another mod kept in place is not removed")
        check(printCount("MDFX_SledgehammerGuard") == 0, "fix: neither case is logged")
    end)

    -- 缺的那幾格沒載入：分不出是缺片還是沒載入，不動
    scenario(function()
        setup(srcs, true)
        local t = buildWorld()
        W.squares["5,0"], W.squares["5,1"] = nil, nil
        check(hit(t.half19) == true and W.has(4, 0, "boulders_19") and W.safe == 1 and W.single == 0
            and printCount("MDFX_SledgehammerGuard") == 0, "fix: pieces on squares that are not loaded do not count as missing")
    end)

    -- 確定缺片、但引擎這次移得掉（內層沒要求過移除）：照引擎的結果，不再補單片移除
    scenario(function()
        setup(srcs, false)
        local t = buildWorld()
        ISDestroyStuffAction.complete = function(self) return true end
        loadFix(srcs)
        W.engineFixed = true
        check(hit(t.half19) == true and not W.has(4, 0, "boulders_19") and W.safe == 1 and W.single == 0
            and printCount("MDFX_SledgehammerGuard") == 0, "fix: when the engine removes the piece on the re-ask nothing else is done")
    end)

    -- 單片移除沒成功（Java 端例外，Lua 拿到 nil）：報失敗，不報 removed
    scenario(function()
        setup(srcs, true)
        local t = buildWorld()
        W.singleBroken = true
        check(hit(t.half19) == true and W.has(4, 0, "boulders_19") and W.single == 1, "fix: a failed single-piece removal keeps the vanilla result")
        check(hit(t.half19) == true and W.has(4, 0, "boulders_19") and W.single == 2, "fix: the next hit tries again")
        check(printCount("vanilla left") == 0 and printCount("could not check for or remove a leftover piece") == 1
            and printCount("boulders_19 at 4,0,0 is still on its square") == 1, "fix: a removal that did not happen is reported once as a failure, not as removed")
    end)

    -- 跨樓層的圖塊組（1×1、兩層）：整組都在時從上層那一片看也是齊的；下層不見了才算缺片
    scenario(function()
        setup(srcs, false)
        buildWorld()
        local g = makeGrid(1, 1, { "tall_0", "tall_1" }, 2)
        local low = W.object(13, 0, g.cells["0,0"], 0)
        local high = W.object(13, 0, g.cells["0,0,1"], 1)
        ISDestroyStuffAction.complete = function(self) return true end
        loadFix(srcs)
        check(hit(high) == true and high:getObjectIndex() ~= -1 and low:getObjectIndex() ~= -1 and W.safe == 0 and W.single == 0,
            "fix: a complete two-level group is complete when seen from its upper piece")
        table.remove(low.sq.objs)
        check(hit(high) == true and high:getObjectIndex() == -1 and W.single == 1, "fix: with the lower piece gone the upper one is a leftover")
    end)

    -- 圖塊組本來就有空位置（L 形）：引擎對這種圖塊組一律找不齊，完整的也敲不掉。空位置不算缺片，不把完整的拆成單片
    scenario(function()
        setup(srcs, true)
        buildWorld()
        local g = makeGrid(2, 2, { "lshape_0", "lshape_1", "lshape_2", nil })
        local a = W.object(10, 0, g.cells["0,0"])
        W.object(11, 0, g.cells["1,0"])
        local c = W.object(10, 1, g.cells["0,1"])
        W.square(11, 1)
        check(hit(a) == true and W.has(10, 0, "lshape_0") and W.safe == 1 and W.single == 0 and printCount("MDFX_SledgehammerGuard") == 0,
            "fix: an empty position in the sprite grid is not a missing piece")
        table.remove(W.squares["11,0"].objs)
        check(hit(c) == true and not W.has(10, 1, "lshape_2") and W.has(10, 0, "lshape_0") and W.single == 1,
            "fix: a sparse group that really lost a piece is still handled")
    end)

    -- 有 component 的殘片（建造選單蓋的設施、裝液體的物件）：原版沒倒 component 的內容，不動
    scenario(function()
        setup(srcs, true)
        local t = buildWorld()
        t.half19.components = 2
        check(hit(t.half19) == true and W.has(4, 0, "boulders_19") and W.safe == 1 and W.single == 0
            and printCount("MDFX_SledgehammerGuard") == 0, "fix: a leftover piece that carries components is left as vanilla")
        check(hit(t.half16) == true and not W.has(4, 1, "boulders_16"), "fix: the piece without components next to it still goes")
    end)

    -- 自己那段拋錯：照回原版結果，只印一次
    scenario(function()
        setup(srcs, true)
        local t = buildWorld()
        t.half19.throwGrid, t.half16.throwGrid = true, true
        local ok, result = pcall(hit, t.half19)
        check(ok and result == true and W.has(4, 0, "boulders_19"), "fix: an error in the guard keeps the vanilla result")
        pcall(hit, t.half16)
        check(printCount("MDFX_SledgehammerGuard could not check for or remove a leftover piece") == 1 and printCount("boom grid") == 1,
            "fix: the guard's own error is logged once")
    end)

    -- 原版拋錯：原樣外洩
    scenario(function()
        setup(srcs, false)
        local t = buildWorld()
        ISDestroyStuffAction.complete = function(self) error("vanilla boom") end
        loadFix(srcs)
        local ok, err = pcall(hit, t.half19)
        check(not ok and string.find(tostring(err), "vanilla boom", 1, true) ~= nil, "fix: a vanilla error is not swallowed")
        check(printCount("MDFX_SledgehammerGuard") == 0 and W.single == 0, "fix: nothing logged or removed for a vanilla error")
    end)

    -- 安裝：形狀不符、重複載入、後載 MOD 替換、多人客戶端
    scenario(function()
        setup(srcs, false)
        ISDestroyStuffAction = nil
        local ok = pcall(loadFix, srcs)
        fireInit()
        check(ok and printCount("MDFX_SledgehammerGuard NOT installed") == 1, "missing class: NOT installed once, no error")
        setup(srcs, false)
        ISDestroyStuffAction.complete = nil
        ok = pcall(loadFix, srcs)
        check(ok and printCount("MDFX_SledgehammerGuard NOT installed") == 1, "missing method: NOT installed, no error")
    end)
    scenario(function()
        setup(srcs, false)
        local vanilla = ISDestroyStuffAction.complete
        loadFix(srcs)
        local first = ISDestroyStuffAction.complete
        check(first ~= vanilla and ISDestroyStuffAction.MDFX_SledgehammerGuard == first, "the wrapper is installed and remembered")
        loadFix(srcs)
        fireInit()
        check(ISDestroyStuffAction.complete == first, "loading twice or OnInitGlobalModData does not stack a second wrapper")
    end)
    scenario(function()
        setup(srcs, true)
        local t = buildWorld()
        local replaced = function(self)
            self.item:getSquare():transmitRemoveItemFromSquare(self.item)
            return true
        end
        ISDestroyStuffAction.complete = replaced
        check(hit(t.half19) == true and W.has(4, 0, "boulders_19"), "a later mod replacing complete removes the guard")
        fireInit()
        check(ISDestroyStuffAction.complete ~= replaced and hit(t.half19) == true and not W.has(4, 0, "boulders_19"),
            "OnInitGlobalModData wraps a replacement that loaded after the guard")
    end)
    scenario(function()
        setup(srcs, false, { client = true })
        local vanilla = ISDestroyStuffAction.complete
        loadFix(srcs)
        fireInit()
        check(ISDestroyStuffAction.complete == vanilla and ISDestroyStuffAction.MDFX_SledgehammerGuard == nil and #prints == 0,
            "MP client: not installed, nothing printed")
    end)

    -- 單人（isServer、isClient 都是 false）：照樣安裝、照樣修
    scenario(function()
        setup(srcs, true, { sp = true })
        local t = buildWorld()
        check(ISDestroyStuffAction.MDFX_SledgehammerGuard == ISDestroyStuffAction.complete and hit(t.half19) == true
            and not W.has(4, 0, "boulders_19") and W.has(4, 1, "boulders_16"), "single player: installed and removes the piece that was hit")
    end)

    -- 官方修好（引擎不再拒絕缺片的整組）時不介入
    scenario(function()
        setup(srcs, true)
        local t = buildWorld()
        W.engineFixed = true
        check(hit(t.half19) == true and not W.has(4, 0, "boulders_19") and W.safe == 1 and W.single == 0
            and printCount("MDFX_SledgehammerGuard") == 0, "retire: with the engine fixed vanilla removes the piece and the guard stays out")
    end)

    return checks, failures
end

-- ── 突變 ───────────────────────────────────────────────────────────
local MUTANTS = {
    { "act even when the original did not return true", "        if result == true then\n", "        if true then\n" },
    { "no rule check before the original",
        "            if not pcall(logRefusal, self, why) then warnOnce(\"log\", \"could not log a refused sledgehammer hit.\") end\n            return false\n",
        "            if not pcall(logRefusal, self, why) then warnOnce(\"log\", \"could not log a refused sledgehammer hit.\") end\n" },
    { "refusal logging without pcall", "if not pcall(logRefusal, self, why) then", "if logRefusal(self, why) then" },
    { "log refusals of targets already gone", "    if item:getObjectIndex() == -1 then return end -- 目標已經不在格子上", "    -- " },
    { "a failed rule check passes to the original", "            error(why)\n", "" },
    { "check a nil target", "    if item == nil then return nil end", "" },
    { "one quota for everyone", "local key = sid ~= \"none\" and (sid .. \"|\" .. id) or (id .. \"|\" .. tostring(p:getUsername()))", "local key = \"all\"" },
    { "do not check that the target is still on its square", "if item == nil or item:getObjectIndex() == -1 then return end",
        "if item == nil then return end" },
    { "do not check for a multi-tile sprite", "item:getSpriteGrid() == nil or ", "" },
    { "do not check for components", " or item:componentSize() > 0", "" },
    { "do not require evidence of a missing piece", "    if not hasMissingPiece(item, sq) then return end\n", "" },
    { "no sledgehammer rule", 'return "no usable sledgehammer within reach"', "return nil" },
    { "build cheat does not exempt from the sledgehammer rule", "not character:isBuildCheat() and ", "" },
    { "ignore SledgehammerOnlyInSafehouse", 'if getServerOptions():getBoolean("SledgehammerOnlyInSafehouse") then', "if false then" },
    { "a privileged role is not exempt", "if not (role and role:hasCapability(Capability.UseBuildCheat)) then", "if true then" },
    { "any role counts as privileged", "role and role:hasCapability(Capability.UseBuildCheat)", "role" },
    { "check a different capability", "role:hasCapability(Capability.UseBuildCheat)", "role:hasCapability(Capability.SeePlayersConnected)" },
    { "any safehouse is enough", "if not (safe and safe:playerAllowed(character)) then", "if not safe then" },
    { "refusals not limited", "    if n > LOG_LIMIT then\n", "    if false then\n" },
    { "names not cleaned", '"[%c\\"]", "?"', '"[%z]", "?"' },
    { "count a square that is not loaded as a missing piece", "if other ~= nil then", "if true then" },
    { "an empty position in the sprite grid counts as a missing piece", "want ~= nil and cell:getGridSquare", "cell:getGridSquare" },
    { "any object on the square counts as the piece", "if objects:get(i):getSprite() == want then", "if true then" },
    { "ignore where the piece sits in its group (x)", "sq:getX() - grid:getSpriteGridPosX(sprite)", "sq:getX()" },
    { "ignore where the piece sits in its group (y)", "sq:getY() - grid:getSpriteGridPosY(sprite)", "sq:getY()" },
    { "ignore where the piece sits in its group (z)", "sq:getZ() - grid:getSpriteGridPosZ(sprite)", "sq:getZ()" },
    { "report removed without checking",
        '    if item:getObjectIndex() ~= -1 then return failed(where .. " is still on its square after the single-piece removal") end\n', "" },
    { "skip the vanilla re-ask", "if sq:transmitRemoveItemFromSquare(item) ~= -1 then return end", "" },
    { "act when the re-ask succeeded instead", "if sq:transmitRemoveItemFromSquare(item) ~= -1 then return end",
        "if sq:transmitRemoveItemFromSquare(item) == -1 then return end" },
    { "safe removal instead of the single piece", "sq:transmitRemoveItemFromSquare(item, false)", "sq:transmitRemoveItemFromSquare(item, true)" },
    { "never remove", "    sq:transmitRemoveItemFromSquare(item, false)\n", "" },
    { "log every time", "    warned[key] = true\n", "" },
    { "after-step without pcall", "local ok, err = pcall(afterComplete, self)", "local ok, err = true, afterComplete(self)" },
    { "swallow the guard's own error silently", "if not ok then", "if false then" },
    { "return true instead of the original result", "        return result\n", "        return true\n" },
    { "no shape check", 'if type(cls) ~= "table" or type(cls.complete) ~= "function" then', "if false then" },
    { "no sentinel check", "if cls[NAME] == cls.complete then return end", "" },
    { "sentinel never stored", "    cls[NAME] = wrapper\n", "" },
    { "wrapper never installed", "    cls.complete = wrapper\n", "" },
    { "re-check on OnGameBoot, which fired before server/ loads in single player", "    Events.OnInitGlobalModData.Add(install)\n",
        "    Events.OnGameBoot.Add(install)\n" },
    { "installed on the MP client", 'if type(isClient) ~= "function" or isClient() then return end', "" },
    { "installed on the dedicated server only", "isClient() then return end", "isClient() or not isServer() then return end" },
}

local function mutate(src, from, to)
    local s, e = string.find(src, from, 1, true)
    assert(s, "mutant target not found: " .. from)
    assert(not string.find(src, from, e + 1, true), "mutant target not unique: " .. from)
    return string.sub(src, 1, s - 1) .. to .. string.sub(src, e + 1)
end

local checks, failures = runAll(SOURCES, false)
print = realPrint
print(string.format("MDFX_SledgehammerGuard: %d checks, %d failed", checks, failures))
if failures > 0 then os.exit(1) end

if arg[1] == "--mutants" then
    local survived = 0
    for _, m in ipairs(MUTANTS) do
        local _, failed = runAll({ vanilla = SOURCES.vanilla, fix = mutate(SOURCES.fix, m[2], m[3]) }, true)
        print = realPrint
        if failed == 0 then
            survived = survived + 1
            print("SURVIVED " .. m[1])
        end
    end
    print(string.format("mutants: %d, survived %d", #MUTANTS, survived))
    if survived > 0 then os.exit(1) end
end
