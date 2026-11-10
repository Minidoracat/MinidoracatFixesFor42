-- MDFX_WindowFaceGuard 離線自我檢查
-- 用法（repo 根目錄）： lua scripts/test_window_face_guard.lua [--mutants]
--
-- 照載本機遊戲的原版 shared/Moveables/ISMoveableSpriteProps.lua（PZ_HOME 可改安裝目錄），判斷全部由原版那一段做；
-- Java 端用 Lua 照形狀模擬：圖塊屬性（has／get）、格子（物件清單、has、getWindow）、角色（技能、背包裡的工具）。
-- 驗證：
--   * 對照組（不載補丁）重現：沒有換面資料的北向窗在北牆窗框被拒、在西牆窗框被放行；西向窗與舊 tileset 的窗正常
--   * 修正組：北向窗在北牆窗框放得上，回傳值、facing、診斷行（恰一次）；原版放得上的情況只呼叫原版一次、結果不變
--   * 沒有窗框、已有窗、沒工具、技能不足照樣放不上；西向窗、牆上物件不受影響
--   * 第二次呼叫拋錯時回原版結果並還原 facing；第一次呼叫拋錯原樣外洩
--   * 形狀不符印 NOT installed；重複載入不疊；後載 MOD 替換後 OnGameBoot 再包一層
--   * 官方修好（補換面資料，或 :1941 不再看 hasFaces）時補丁不介入
-- --mutants：逐一抽掉每道防線，確認至少一項檢查轉紅。

local PZ_HOME = os.getenv("PZ_HOME") or "D:/SteamLibrary/steamapps/common/ProjectZomboid"
local VANILLA = PZ_HOME .. "/media/lua/shared/Moveables/ISMoveableSpriteProps.lua"
local FIX = "MOD/MinidoracatFixesFor42/Contents/mods/MinidoracatFixesFor42/42/media/lua/shared/Fixes/MDFX_WindowFaceGuard.lua"

local realPrint = print

local function readFile(path)
    local f = assert(io.open(path, "rb"))
    local s = f:read("*a")
    f:close()
    return s
end

local SOURCES = { vanilla = readFile(VANILLA), fix = readFile(FIX) }
local VANILLA_ISNORTH = 'local isNorth = (self:hasFaces() and self.facing == "N" or self.facing == "S") or false;'
local FIXED_ISNORTH = 'local isNorth = (self.facing == "N" or self.facing == "S") or false;'

-- ── 假 Java 端 ─────────────────────────────────────────────────────
local prints, bootHandlers, calls, throwOn

local function sprite(name, values)
    local props = {}
    function props:has(k) return values[k] ~= nil end
    function props:get(k) return values[k] end
    local spr = {}
    function spr:getName() return name end
    function spr:getProperties() return props end
    function spr:getSpriteGrid() return nil end
    return spr
end

local function object(spr, class)
    return { _class = class, getSprite = function() return spr end }
end

local function square(x, y, sprites)
    local objs = {}
    for i = 1, #sprites do objs[i] = object(sprites[i]) end
    local list = { size = function() return #objs end, get = function(_, i) return objs[i + 1] end }
    local sq = { _class = "IsoGridSquare", windows = {}, neighbors = {} }
    function sq:getObjects() return list end
    function sq:has(flag)
        for i = 1, #objs do
            if objs[i]:getSprite():getProperties():has(flag) then return true end
        end
        return false
    end
    function sq:getTileInDirection(dir) return self.neighbors[dir] end
    function sq:getWindow(dir) return self.windows[dir] end
    function sq:isVehicleIntersecting() return false end
    function sq:getFloor() return objs[1] end
    function sq:getX() return x end
    function sq:getY() return y end
    function sq:getZ() return 0 end
    return sq
end

local HAMMER = { name = "hammer" }

local function player(level, hasHammer)
    local inv = { getFirstTypeRecurse = function(_, t) return hasHammer and t == "Base.Hammer" and HAMMER or nil end }
    return { _class = "IsoPlayer", isMovablesCheat = function() return false end, getPerkLevel = function() return level end,
        getInventory = function() return inv end }
end

local function windowSprite(name, facing, extra)
    local v = { IsMoveAble = "", MoveType = "Window", Facing = facing, PickUpLevel = "2", PickUpTool = "Crowbar", PlaceTool = "Hammer",
        PickUpWeight = "200", CustomName = "Window", GroupName = "White Window" }
    v[facing == "N" and "WindowN" or "WindowW"] = ""
    for k, val in pairs(extra or {}) do v[k] = val end
    return sprite(name, v)
end

-- 重設全域、載原版（vanillaSrc 可換成改過的）、掛計數器，再視需要載補丁
local function setup(srcs, withFix, vanillaSrc)
    prints, bootHandlers, calls, throwOn = {}, {}, 0, nil
    print = function(...)
        local t = {}
        for i = 1, select("#", ...) do t[#t + 1] = tostring((select(i, ...))) end
        prints[#prints + 1] = table.concat(t, " ")
    end
    local name = function(_, k) return k end
    IsoFlagType = setmetatable({}, { __index = name })
    IsoPropertyType = setmetatable({}, { __index = name })
    IsoDirections = setmetatable({}, { __index = name })
    GridSquareEdgeFacingDirection = { NORTH_SOUTH = "NS", EAST_WEST = "EW" }
    IsoGridSquare = { ignoreBlockingSprites = { add = function() end } }
    getCore = function() return { getGoodHighlitedColor = function() end, getBadHighlitedColor = function() end } end
    instanceof = function(o, class) return type(o) == "table" and o._class == class end
    Events = { OnGameBoot = { Add = function(f) bootHandlers[#bootHandlers + 1] = f end }, OnDynamicMovableRecipe = { Add = function() end } }
    local tools = { Hammer = { perk = "Woodwork", perkName = "Carpentry", items = { "Base.Hammer" } } }
    ISMoveableDefinitions = { cheat = false }
    function ISMoveableDefinitions:getInstance() return { getToolDefinition = function(tool) return tools[tool] end } end
    ISMoveableSpriteProps, ISThumpableSpriteProps = nil, nil
    assert(load(vanillaSrc or srcs.vanilla, "=ISMoveableSpriteProps.lua"))()
    local real = ISMoveableSpriteProps.canPlaceMoveableInternal
    ISMoveableSpriteProps.canPlaceMoveableInternal = function(self, ...)
        calls = calls + 1
        if throwOn and throwOn(self) then error("boom") end
        return real(self, ...)
    end
    if withFix then assert(load(srcs.fix, "=MDFX_WindowFaceGuard.lua"))() end
    return real
end

local function fireBoot()
    for i = 1, #bootHandlers do bootHandlers[i]() end
end

local function printCount(needle)
    local n = 0
    for i = 1, #prints do
        if string.find(prints[i], needle, 1, true) then n = n + 1 end
    end
    return n
end

local function world()
    local floor = sprite("floors_01_0", {})
    local w = {
        whiteN = windowSprite("fixtures_windows_white_25", "N"),
        whiteW = windowSprite("fixtures_windows_white_24", "W"),
        oldN = windowSprite("fixtures_windows_01_25", "N", { Woffset = "-1" }),
        wallThing = sprite("walls_decoration_01_1", { IsMoveAble = "", MoveType = "WallObject", Facing = "N" }),
    }
    w.northFrame = square(5, 7, { floor, sprite("walls_exterior_house_06_25", { WindowN = "" }) })
    w.westFrame = square(8, 7, { floor, sprite("walls_exterior_house_06_24", { WindowW = "" }) })
    w.empty = square(9, 9, { floor })
    w.northWall = square(3, 3, { floor, sprite("walls_exterior_house_06_1", { WallN = "" }) })
    w.player = player(10, true)
    return w
end

local function can(spr, sq, chr)
    local props = ISMoveableSpriteProps.new(spr)
    return props:canPlaceMoveable(chr, sq, nil), props
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

    -- 對照組：原版的缺陷與正常情況
    scenario(function()
        setup(srcs, false)
        local w = world()
        check(string.find(srcs.vanilla, VANILLA_ISNORTH, 1, true) ~= nil, "vanilla still has the hasFaces() isNorth line")
        check(not can(w.whiteN, w.northFrame, w.player), "control: N window without faces is refused on a north frame")
        check(can(w.whiteN, w.westFrame, w.player) == HAMMER, "control: N window without faces is accepted on a west frame")
        check(can(w.whiteW, w.westFrame, w.player) == HAMMER, "control: W window is accepted on a west frame")
        check(not can(w.whiteW, w.northFrame, w.player), "control: W window is refused on a north frame")
        check(can(w.oldN, w.northFrame, w.player) == HAMMER, "control: N window with faces is accepted on a north frame")
    end)

    -- 修正組：北向窗回到北牆窗框
    scenario(function()
        setup(srcs, true)
        local w = world()
        local result, props = can(w.whiteN, w.northFrame, w.player)
        check(result == HAMMER, "fix: N window without faces is accepted on a north frame, same value vanilla returns")
        check(props.facing == "N", "fix: facing is restored after the re-check")
        check(calls == 2, "fix: vanilla is asked twice for the refused N window")
        check(printCount("MDFX_WindowFaceGuard: vanilla refused north-facing window fixtures_windows_white_25") == 1
            and printCount("accepted at 5,7,0") == 1, "fix: one diagnostic line with the sprite and the square")
        check(can(w.whiteN, w.northFrame, w.player) == HAMMER and printCount("MDFX_WindowFaceGuard") == 1,
            "fix: second acceptance is not logged again")
        check(can(w.whiteN, w.northFrame, nil) == true, "fix: accepted without a character too (vanilla skips skill and tool)")
    end)

    -- 修正組：原版放得上的、不該管的，都只問原版一次
    scenario(function()
        setup(srcs, true)
        local w = world()
        local function once(spr, sq, label, expectTruthy)
            local before = calls
            local result = can(spr, sq, w.player)
            check((result == HAMMER) == expectTruthy and (expectTruthy or not result), label .. ": result unchanged")
            check(calls == before + 1, label .. ": vanilla asked once")
        end
        once(w.whiteN, w.westFrame, "fix: N window on a west frame (vanilla accepts)", true)
        once(w.whiteW, w.westFrame, "fix: W window on a west frame", true)
        once(w.whiteW, w.northFrame, "fix: W window on a north frame", false)
        once(w.oldN, w.northFrame, "fix: N window with faces on a north frame", true)
        once(w.wallThing, w.northWall, "fix: north-facing wall object on a square whose own north wall is not its wall", false)
        check(printCount("MDFX_WindowFaceGuard") == 0, "fix: nothing logged when the guard does not act")
    end)

    -- 修正組：照北向判也放不上的，照樣放不上
    scenario(function()
        setup(srcs, true)
        local w = world()
        local before = calls
        check(not can(w.whiteN, w.empty, w.player), "fix: no frame, still refused")
        check(calls == before + 2, "fix: no frame costs exactly one re-check")
        w.northFrame.windows.NS = object(w.whiteN, "IsoWindow")
        check(not can(w.whiteN, w.northFrame, w.player), "fix: frame already has a window, still refused")
        w.northFrame.windows.NS = nil
        check(not can(w.whiteN, w.northFrame, player(10, false)), "fix: no hammer, still refused")
        check(not can(w.whiteN, w.northFrame, player(1, true)), "fix: carpentry too low, still refused")
        check(printCount("MDFX_WindowFaceGuard") == 0, "fix: refusals are not logged")
    end)

    -- 第二次呼叫拋錯：回原版結果、還原 facing、只印一次
    scenario(function()
        setup(srcs, true)
        local w = world()
        throwOn = function(self) return self.facing == "S" end
        local ok, result, props = pcall(can, w.whiteN, w.northFrame, w.player)
        check(ok and not result, "fix: a throwing re-check keeps the vanilla refusal")
        check(ok and props.facing == "N", "fix: facing is restored when the re-check throws")
        pcall(can, w.whiteN, w.northFrame, w.player)
        check(printCount("MDFX_WindowFaceGuard: the north-facing re-check threw") == 1, "fix: re-check failure logged once")
        check(printCount("vanilla refused north-facing window") == 0, "fix: no acceptance logged when the re-check throws")
    end)

    -- 第一次呼叫拋錯：原樣外洩
    scenario(function()
        setup(srcs, true)
        local w = world()
        throwOn = function() return true end
        check(not pcall(can, w.whiteN, w.northFrame, w.player), "fix: a vanilla error on the first call is not swallowed")
        check(printCount("MDFX_WindowFaceGuard") == 0, "fix: nothing logged for a vanilla error")
    end)

    -- 安裝：形狀不符、重複載入、後載 MOD 替換
    scenario(function()
        setup(srcs, false)
        ISMoveableSpriteProps = nil
        local ok = pcall(function() assert(load(srcs.fix, "=MDFX_WindowFaceGuard.lua"))() end)
        fireBoot()
        check(ok and printCount("MDFX_WindowFaceGuard NOT installed") == 1, "missing class: NOT installed once, no error")
        setup(srcs, false)
        ISMoveableSpriteProps.canPlaceMoveableInternal = nil
        ok = pcall(function() assert(load(srcs.fix, "=MDFX_WindowFaceGuard.lua"))() end)
        check(ok and printCount("MDFX_WindowFaceGuard NOT installed") == 1, "missing method: NOT installed, no error")
    end)
    scenario(function()
        setup(srcs, true)
        assert(load(srcs.fix, "=MDFX_WindowFaceGuard.lua"))()
        fireBoot()
        local w = world()
        local before = calls
        check(not can(w.whiteN, w.empty, w.player) and calls == before + 2, "loading twice does not stack a second wrapper")
    end)
    scenario(function()
        local real = setup(srcs, true)
        local w = world()
        ISMoveableSpriteProps.canPlaceMoveableInternal = real
        check(not can(w.whiteN, w.northFrame, w.player), "a later mod replacing the method removes the guard")
        fireBoot()
        check(can(w.whiteN, w.northFrame, w.player) == HAMMER, "OnGameBoot wraps the replacement again")
    end)

    -- 官方修好時不介入
    scenario(function()
        setup(srcs, true)
        local w = world()
        local fixedN = windowSprite("fixtures_windows_white_25", "N", { Woffset = "-1" })
        local before = calls
        check(can(fixedN, w.northFrame, w.player) == HAMMER and calls == before + 1 and printCount("MDFX_WindowFaceGuard") == 0,
            "retire: with face offsets vanilla accepts and the guard stays out")
    end)
    scenario(function()
        local patched, n = string.gsub(srcs.vanilla, VANILLA_ISNORTH:gsub("%p", "%%%0"), (FIXED_ISNORTH:gsub("%%", "%%%%")))
        check(n == 1, "retire: the vanilla isNorth line was found once")
        setup(srcs, true, patched)
        local w = world()
        local before = calls
        check(can(w.whiteN, w.northFrame, w.player) == HAMMER and calls == before + 1 and printCount("MDFX_WindowFaceGuard") == 0,
            "retire: with isNorth fixed vanilla accepts and the guard stays out")
        check(not can(w.whiteN, w.westFrame, w.player), "retire: with isNorth fixed the N window stays refused on a west frame")
    end)

    return checks, failures
end

-- ── 突變 ───────────────────────────────────────────────────────────
local MUTANTS = {
    { "re-check even when vanilla accepts", 'if result or self.type ~= "Window"', 'if self.type ~= "Window"' },
    { "re-check non-window types", 'self.type ~= "Window" or ', "" },
    { "re-check other facings", ' or self.facing ~= "N" then return result end', " then return result end" },
    { "do not switch facing", 'self.facing = "S"', "" },
    { "do not restore facing", 'self.facing = "N"', "" },
    { "re-check without pcall", "local ok, second = pcall(original, self, character, square, item, forceTypeObject)",
        "local ok, second = true, original(self, character, square, item, forceTypeObject)" },
    { "accept whatever the re-check says", "if ok and second then", "if ok then" },
    { "return true instead of the vanilla value", "return second", "return true" },
    { "log every acceptance", "warnedAccepted = true", "" },
    { "log every re-check failure", "warnedRetryFailed = true", "" },
    { "log a failure for every refusal", "if not ok and not warnedRetryFailed then", "if not warnedRetryFailed then" },
    { "no shape check", 'if type(props) ~= "table" or type(props.canPlaceMoveableInternal) ~= "function" then', "if false then" },
    { "log NOT installed every time", "warnedNotInstalled = true", "" },
    { "no sentinel check", "if props.MDFX_windowFaceGuard == props.canPlaceMoveableInternal then", "if false then" },
    { "sentinel never stored", "props.MDFX_windowFaceGuard = wrapper", "" },
    { "wrapper never installed", "props.canPlaceMoveableInternal = wrapper", "" },
    { "no OnGameBoot re-check", "Events.OnGameBoot.Add(install)", "" },
}

local function mutate(src, from, to)
    local s, e = string.find(src, from, 1, true)
    assert(s, "mutant target not found: " .. from)
    assert(not string.find(src, from, e + 1, true), "mutant target not unique: " .. from)
    return string.sub(src, 1, s - 1) .. to .. string.sub(src, e + 1)
end

local checks, failures = runAll(SOURCES, false)
print = realPrint
print(string.format("MDFX_WindowFaceGuard: %d checks, %d failed", checks, failures))
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
