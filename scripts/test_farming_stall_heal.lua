-- MDFX_FarmingStallHeal 離線自我檢查
-- 用法（repo 根目錄）： lua scripts/test_farming_stall_heal.lua
--
-- 以最小假 vanilla SFarmingSystem（class 表的 checkPlant2(self, luaObject)，SFarmingSystem.lua:264；
-- 系統實例只帶 hoursElapsed，:11）、假 farming_vegetableconf.props（以 typeOfSeed 為鍵、
-- timeToGrow／rotTime 欄位，farming_vegetableconf.lua:284、:392；SPlantGlobalObject.lua:71）與
-- 假排程函式（calcNextGrowing／calcNextTimeFactor／randomGrowthOffset／badPlant 全域、
-- farming_vegetableconf.grow；來源由假 getFilenameOfClosure 回報）驗證：
--   * isClient() 為真時完全不安裝
--   * 正常 seeded 作物原樣透傳、原函式恰呼叫一次、收到的 self 是系統實例
--   * nextGrowing 停在舊時鐘 → nextGrowing = H + timeToGrow、lastWaterHour 不動；多株只印一次診斷
--   * lastWaterHour > H → 設回 H；nextGrowing 只往前改（已比 H + timeToGrow 早就不動、不是數字就寫）
--   * LIMIT = max(timeToGrow + 50, rotTime 或 floor(timeToGrow/2), 50) × 10 + 12 的精確邊界
--     （最大值分別來自 timeToGrow + 50 與 rotTime 兩組 props）
--   * 排程函式任一不是原版檔（MOD 路徑、別的檔、缺席、查不到來源、getFilenameOfClosure 缺席或拋錯）
--     → 遠期判斷整段關掉、診斷一次、只算一次；lastWaterHour 觸發照常；Windows 反斜線路徑認得
--   * 非 seeded 狀態不碰、未知種子只重設 lastWaterHour、debug FastGrow → H + 1、
--     hoursElapsed 不是數字不碰
--   * 判斷本身拋錯 → 照跑原函式、診斷一次；原函式拋錯原樣外洩；luaObject 為 nil 直接透傳
--   * 形狀不符 → NOT installed、什麼都不動；重複載入不疊；後載 MOD 替換後 OnGameBoot 把他的版本再包一層

local S = dofile("scripts/_stub.lua")
local T = S.checker()
local FIX = S.SERVER_FIXES .. "MDFX_FarmingStallHeal.lua"

local H = 1000
local STALE = H + 30941 -- 正式服實例：比現在多約 30,900 遊戲小時
local HEALED_MSG = "was scheduled on an older farming clock"
local ERROR_MSG = "could not check a crop"
local LIMIT_OFF_MSG = "far-future nextGrowing check disabled"

-- 原版檔（Windows 反斜線、大寫 Farming：本檔要先換斜線、轉小寫才認得）
local VANILLA_FILE = "D:\\PZ\\media\\lua\\server\\Farming\\farming_vegetableconf.lua"
local MOD_FILE = "C:/Users/x/Zomboid/mods/X/42/media/lua/server/Farming/farming_vegetableconf.lua"
local OTHER_FILE = "D:\\PZ\\media\\lua\\server\\Farming\\SFarmingSystem.lua"
local SCHEDULE = { "calcNextGrowing", "calcNextTimeFactor", "randomGrowthOffset", "badPlant", "farming_vegetableconf.grow" }

-- 最大值來自 timeToGrow + 50：Tomato 200 + 50 = 250 → LIMIT = 2512
local PROPS_GROW = function()
    return {
        Carrots = { timeToGrow = 100, rotTime = 60 },
        Tomato = { timeToGrow = 200 }, -- rotTime 缺席 → floor(200/2) = 100
    }
end
local LIMIT_GROW = 250 * 10 + 12
-- 最大值來自 rotTime：Pumpkin rotTime 400 > 100 + 50 → LIMIT = 4012
local PROPS_ROT = function()
    return { Pumpkin = { timeToGrow = 100, rotTime = 400 } }
end
local LIMIT_ROT = 400 * 10 + 12

local calls
local debugFlags
local FILES
local closureLookups

-- ── 假環境 ───────────────────────────────────────────────────────
local function resetEnv(opts)
    opts = opts or {}
    S.reset()
    isClient = function() return opts.client == true end
    package.loaded["Farming/SFarmingSystem"] = true
    package.loaded["Farming/farming_vegetableconf"] = true
    debugFlags = { debug = false, fastGrow = false }
    getCore = function()
        return { getDebug = function(self) return debugFlags.debug end }
    end
    getDebugOptions = function()
        return { getBoolean = function(self, name) return name == "Cheat.Farming.FastGrow" and debugFlags.fastGrow end }
    end
    farming_vegetableconf = { props = (opts.props or PROPS_GROW)() }
    -- 排程函式：每個都是新 closure，來源預設是原版檔
    FILES = {}
    closureLookups = 0
    calcNextGrowing = function() end
    calcNextTimeFactor = function() end
    randomGrowthOffset = function() end
    badPlant = function() end
    farming_vegetableconf.grow = function() end
    for _, fn in ipairs({ calcNextGrowing, calcNextTimeFactor, randomGrowthOffset, badPlant, farming_vegetableconf.grow }) do
        FILES[fn] = VANILLA_FILE
    end
    getFilenameOfClosure = function(fn)
        closureLookups = closureLookups + 1
        return FILES[fn]
    end
    calls = {}
    local C = {}
    function C.checkPlant2(self, luaObject)
        calls[#calls + 1] = { self = self, obj = luaObject,
            nextGrowing = luaObject and luaObject.nextGrowing, lastWaterHour = luaObject and luaObject.lastWaterHour }
        if luaObject and luaObject.boom then error("vanilla checkPlant2 boom") end
    end
    SFarmingSystem = C
    return C
end

-- 依名稱取排程函式（全域或 farming_vegetableconf.grow）
local function scheduleFn(name)
    if name == "farming_vegetableconf.grow" then return farming_vegetableconf.grow end
    return _G[name]
end

local function plant(fields)
    local p = { x = 10, y = 20, z = 0, state = "seeded", typeOfSeed = "Carrots", nextGrowing = H + 5, lastWaterHour = H - 3 }
    for k, v in pairs(fields or {}) do p[k] = v end
    return p
end

local function system(hours)
    return { hoursElapsed = hours }
end

-- ── 1. client：完全不安裝 ──────────────────────────────────────
T.section("[1] isClient() 為真時零介入")
local C = resetEnv({ client = true })
local orig = C.checkPlant2
S.load(FIX)
S.fireBoot()
T.check("1 checkPlant2 沒被換", C.checkPlant2 == orig)
T.check("1 沒有 marker", C.MDFX_stallHeal == nil)
T.check("1 不印任何診斷", not S.printed("[MinidoracatFixes]"))

-- ── 2. 安裝與正常作物透傳 ──────────────────────────────────────
T.section("[2] 安裝、正常作物")
C = resetEnv()
orig = C.checkPlant2
S.load(FIX)
T.check("2 checkPlant2 包上", C.checkPlant2 ~= orig and C.MDFX_stallHeal == C.checkPlant2)
local sys = system(H)
local p = plant()
C.checkPlant2(sys, p)
T.check("2 原函式恰呼叫一次、self 是系統實例", #calls == 1 and calls[1].self == sys and calls[1].obj == p)
T.check("2 正常作物不動", p.nextGrowing == H + 5 and p.lastWaterHour == H - 3)
T.check("2 不印診斷", not S.printed("[MinidoracatFixes]"))

-- ── 3. nextGrowing 停在舊時鐘 ──────────────────────────────────
T.section("[3] 舊時鐘 nextGrowing")
C = resetEnv()
S.load(FIX)
sys = system(H)
p = plant({ nextGrowing = STALE, lastWaterHour = H - 3 })
C.checkPlant2(sys, p)
T.check("3 nextGrowing = H + timeToGrow", p.nextGrowing == H + 100, tostring(p.nextGrowing))
T.check("3 lastWaterHour 沒領先 → 不動", p.lastWaterHour == H - 3, tostring(p.lastWaterHour))
T.check("3 原函式看到的是重設後的值", #calls == 1 and calls[1].nextGrowing == H + 100 and calls[1].lastWaterHour == H - 3)
T.check("3 診斷含座標、種子與前後值", S.printed("crop at 10,20,0 (Carrots)")
    and S.printed("nextGrowing " .. STALE .. " -> " .. (H + 100) .. ", lastWaterHour " .. (H - 3) .. " -> " .. (H - 3)))
local many = {}
for i = 1, 5 do
    many[i] = plant({ x = i, typeOfSeed = "Tomato", nextGrowing = STALE + i, lastWaterHour = H - i })
    C.checkPlant2(sys, many[i])
end
local allHealed = true
for i = 1, 5 do
    if many[i].nextGrowing ~= H + 200 or many[i].lastWaterHour ~= H - i then allHealed = false end
end
T.check("3 多株全部重設（Tomato timeToGrow 200）、lastWaterHour 各自保留", allHealed)
T.check("3 診斷整段只印一次", S.printCount(HEALED_MSG) == 1)
T.check("3 每株各呼叫原函式一次", #calls == 6)

-- ── 4. lastWaterHour 超前；nextGrowing 只往前改 ────────────────
T.section("[4] lastWaterHour 超前")
C = resetEnv()
S.load(FIX)
p = plant({ nextGrowing = H + 5, lastWaterHour = H + 1 })
C.checkPlant2(system(H), p)
T.check("4 lastWaterHour > H → 設回 H", p.lastWaterHour == H, tostring(p.lastWaterHour))
T.check("4 nextGrowing 已比 H + timeToGrow 早 → 不往後延", p.nextGrowing == H + 5, tostring(p.nextGrowing))
T.check("4 診斷顯示 lastWaterHour 前後值", S.printed("lastWaterHour " .. (H + 1) .. " -> " .. H))
p = plant({ nextGrowing = H + 500, lastWaterHour = H + 1 })
C.checkPlant2(system(H), p)
T.check("4 nextGrowing 比 H + timeToGrow 晚（未達 LIMIT）→ 提前到 H + timeToGrow", p.nextGrowing == H + 100 and p.lastWaterHour == H)
p = plant({ nextGrowing = H + 100, lastWaterHour = H + 1 })
C.checkPlant2(system(H), p)
T.check("4 nextGrowing == H + timeToGrow → 不動", p.nextGrowing == H + 100)
p = plant({ lastWaterHour = H + 1 })
p.nextGrowing = nil
C.checkPlant2(system(H), p)
T.check("4 nextGrowing 不是數字 → 寫 H + timeToGrow", p.nextGrowing == H + 100 and p.lastWaterHour == H)
p = plant({ nextGrowing = H + 5, lastWaterHour = H })
C.checkPlant2(system(H), p)
T.check("4 lastWaterHour == H 不算超前", p.nextGrowing == H + 5 and p.lastWaterHour == H)

-- ── 5. LIMIT 邊界：最大值來自 timeToGrow + 50 ──────────────────
T.section("[5] LIMIT 邊界（timeToGrow + 50）")
C = resetEnv({ props = PROPS_GROW })
S.load(FIX)
p = plant({ nextGrowing = H + LIMIT_GROW, lastWaterHour = H })
C.checkPlant2(system(H), p)
T.check("5 nextGrowing - H == LIMIT（2512）不動", p.nextGrowing == H + LIMIT_GROW, tostring(p.nextGrowing))
p = plant({ nextGrowing = H + LIMIT_GROW + 1, lastWaterHour = H })
C.checkPlant2(system(H), p)
T.check("5 LIMIT + 1 → 重設", p.nextGrowing == H + 100, tostring(p.nextGrowing))
T.check("5 診斷帶出 limit", S.printed("limit " .. LIMIT_GROW))
T.check("5 原版來源不印關閉診斷", not S.printed(LIMIT_OFF_MSG))

-- ── 6. LIMIT 邊界：最大值來自 rotTime ──────────────────────────
T.section("[6] LIMIT 邊界（rotTime）")
C = resetEnv({ props = PROPS_ROT })
S.load(FIX)
p = plant({ typeOfSeed = "Pumpkin", nextGrowing = H + LIMIT_ROT, lastWaterHour = H })
C.checkPlant2(system(H), p)
T.check("6 nextGrowing - H == LIMIT（4012）不動", p.nextGrowing == H + LIMIT_ROT, tostring(p.nextGrowing))
p = plant({ typeOfSeed = "Pumpkin", nextGrowing = H + LIMIT_ROT + 1, lastWaterHour = H })
C.checkPlant2(system(H), p)
T.check("6 LIMIT + 1 → 重設", p.nextGrowing == H + 100, tostring(p.nextGrowing))

-- ── 7. 排程函式來源 ───────────────────────────────────────────
T.section("[7] 排程函式不是原版 → 遠期判斷關掉")
-- 每一個排程函式各自換成 MOD 版本都要關掉
for _, name in ipairs(SCHEDULE) do
    C = resetEnv()
    S.load(FIX)
    FILES[scheduleFn(name)] = MOD_FILE
    p = plant({ nextGrowing = STALE, lastWaterHour = H - 3 })
    C.checkPlant2(system(H), p)
    T.check("7 " .. name .. " 來自 mods/ → 舊時鐘 nextGrowing 不動、診斷指出它",
        p.nextGrowing == STALE and p.lastWaterHour == H - 3 and S.printCount(LIMIT_OFF_MSG) == 1
        and S.printed(name .. " comes from " .. MOD_FILE) and not S.printed(HEALED_MSG))
end

C = resetEnv()
S.load(FIX)
FILES[badPlant] = MOD_FILE
sys = system(H)
for i = 1, 3 do C.checkPlant2(sys, plant({ nextGrowing = STALE, lastWaterHour = H - 3 })) end
local lookupsAfterFirst = closureLookups
p = plant({ nextGrowing = H + 5, lastWaterHour = H + 1 })
C.checkPlant2(sys, p)
T.check("7 關掉時 lastWaterHour 觸發照常重設", p.lastWaterHour == H and p.nextGrowing == H + 5)
p = plant({ nextGrowing = STALE, lastWaterHour = H + 1 })
C.checkPlant2(sys, p)
T.check("7 關掉時 lastWaterHour 觸發仍把舊 nextGrowing 提前", p.lastWaterHour == H and p.nextGrowing == H + 100)
T.check("7 關閉診斷整段只印一次", S.printCount(LIMIT_OFF_MSG) == 1)
T.check("7 來源只查一輪（整個 session 算一次）", closureLookups == lookupsAfterFirst and closureLookups <= #SCHEDULE,
    tostring(closureLookups))
T.check("7 診斷帶出 limit false", S.printed("limit false"))

local variants = {
    { "別的檔案", function() FILES[calcNextGrowing] = OTHER_FILE end, "calcNextGrowing comes from " .. OTHER_FILE },
    { "getFilenameOfClosure 缺席", function() getFilenameOfClosure = nil end, "getFilenameOfClosure is unavailable" },
    { "getFilenameOfClosure 拋錯", function() getFilenameOfClosure = function() error("closure boom") end end,
        "calcNextGrowing has no known source" },
    { "查不到來源（回 nil）", function() FILES[calcNextTimeFactor] = nil end, "calcNextTimeFactor has no known source" },
    { "排程函式缺席", function() randomGrowthOffset = nil end, "randomGrowthOffset is missing" },
    { "grow 缺席", function() farming_vegetableconf.grow = nil end, "farming_vegetableconf.grow is missing" },
}
for _, v in ipairs(variants) do
    C = resetEnv()
    S.load(FIX)
    v[2]()
    p = plant({ nextGrowing = STALE, lastWaterHour = H - 3 })
    local okV = pcall(C.checkPlant2, system(H), p)
    T.check("7 " .. v[1] .. " → 不炸、不動、診斷說明原因",
        okV and p.nextGrowing == STALE and #calls == 1 and S.printed(v[3]) and not S.printed(ERROR_MSG), v[3])
end

C = resetEnv()
S.load(FIX)
FILES[calcNextGrowing] = "/opt/game/media/lua/server/farming/farming_vegetableconf.lua"
p = plant({ nextGrowing = STALE, lastWaterHour = H - 3 })
C.checkPlant2(system(H), p)
T.check("7 正斜線原版路徑也認得 → 照常重設", p.nextGrowing == H + 100 and not S.printed(LIMIT_OFF_MSG))

-- ── 8. 非 seeded 狀態 ─────────────────────────────────────────
T.section("[8] 非 seeded 不碰")
C = resetEnv()
S.load(FIX)
local untouched = true
local states = { "dead", "rotten", "plow", "destroyed", "harvested", "destroy" }
for _, st in ipairs(states) do
    p = plant({ state = st, nextGrowing = STALE, lastWaterHour = H + 500 })
    C.checkPlant2(system(H), p)
    if p.nextGrowing ~= STALE or p.lastWaterHour ~= H + 500 then untouched = false end
end
T.check("8 dead／rotten／plow／destroyed／harvested／destroy 的舊值都不動", untouched)
T.check("8 原函式照常逐株呼叫", #calls == #states)
T.check("8 不印診斷", not S.printed("[MinidoracatFixes]"))

-- ── 9. 未知種子 ───────────────────────────────────────────────
T.section("[9] 未知 typeOfSeed")
C = resetEnv()
S.load(FIX)
p = plant({ typeOfSeed = "Mystery", nextGrowing = STALE, lastWaterHour = H + 7 })
C.checkPlant2(system(H), p)
T.check("9 nextGrowing 不動、只重設 lastWaterHour", p.nextGrowing == STALE and p.lastWaterHour == H)
T.check("9 不走錯誤路徑", not S.printed(ERROR_MSG) and #calls == 1)

-- ── 10. debug FastGrow ────────────────────────────────────────
T.section("[10] debug FastGrow")
C = resetEnv()
S.load(FIX)
debugFlags.debug, debugFlags.fastGrow = true, true
p = plant({ nextGrowing = STALE, lastWaterHour = H - 3 })
C.checkPlant2(system(H), p)
T.check("10 debug + FastGrow → nextGrowing = H + 1", p.nextGrowing == H + 1, tostring(p.nextGrowing))
p = plant({ nextGrowing = H + 5, lastWaterHour = H + 1 })
C.checkPlant2(system(H), p)
T.check("10 FastGrow 目標更早 → H + 5 也提前到 H + 1", p.nextGrowing == H + 1 and p.lastWaterHour == H)
debugFlags.debug, debugFlags.fastGrow = true, false
p = plant({ nextGrowing = STALE, lastWaterHour = H - 3 })
C.checkPlant2(system(H), p)
T.check("10 debug 但 FastGrow 關 → H + timeToGrow", p.nextGrowing == H + 100)
debugFlags.debug, debugFlags.fastGrow = false, true
p = plant({ nextGrowing = STALE, lastWaterHour = H - 3 })
C.checkPlant2(system(H), p)
T.check("10 非 debug 時 FastGrow 無效 → H + timeToGrow", p.nextGrowing == H + 100)

-- ── 11. hoursElapsed 不是數字 ─────────────────────────────────
T.section("[11] hoursElapsed 不是數字")
C = resetEnv()
S.load(FIX)
p = plant({ nextGrowing = STALE, lastWaterHour = H + 7 })
C.checkPlant2(system(nil), p)
C.checkPlant2(system("1000"), p)
T.check("11 nil／字串時鐘 → 不動", p.nextGrowing == STALE and p.lastWaterHour == H + 7)
T.check("11 原函式照跑、不印診斷", #calls == 2 and not S.printed("[MinidoracatFixes]"))

-- ── 12. 判斷拋錯、原函式拋錯、nil luaObject ─────────────────────
T.section("[12] 錯誤與邊界")
C = resetEnv()
setmetatable(farming_vegetableconf.props, { __index = function(_, k)
    if k == "Boom" then error("props lookup boom") end
end })
S.load(FIX)
p = plant({ typeOfSeed = "Boom", nextGrowing = STALE, lastWaterHour = H })
local ok = pcall(C.checkPlant2, system(H), p)
T.check("12 判斷拋錯 → 不外洩", ok)
T.check("12 原函式照跑", #calls == 1 and calls[1].obj == p)
pcall(C.checkPlant2, system(H), plant({ typeOfSeed = "Boom", nextGrowing = STALE }))
T.check("12 錯誤診斷只印一次、含原因", S.printCount(ERROR_MSG) == 1 and S.printed("props lookup boom"))

C = resetEnv()
S.load(FIX)
local okBoom, err = pcall(C.checkPlant2, system(H), plant({ boom = true }))
T.check("12 原函式拋錯原樣外洩", not okBoom and tostring(err):find("vanilla checkPlant2 boom", 1, true) ~= nil)
T.check("12 原函式的錯不算判斷失敗", not S.printed(ERROR_MSG))

C = resetEnv()
S.load(FIX)
sys = system(H)
ok = pcall(C.checkPlant2, sys, nil)
T.check("12 luaObject 為 nil → 直接交給原函式", ok and #calls == 1 and calls[1].self == sys and calls[1].obj == nil)
T.check("12 nil 不印診斷", not S.printed("[MinidoracatFixes]"))

-- ── 13. 形狀不符 ──────────────────────────────────────────────
T.section("[13] 形狀不符")
resetEnv()
SFarmingSystem = nil
ok = pcall(S.load, FIX)
T.check("13 SFarmingSystem 不存在 → 不炸、不建假表", ok and SFarmingSystem == nil)
T.check("13 印 NOT installed", S.printed("MDFX_FarmingStallHeal NOT installed"))

C = resetEnv()
C.checkPlant2 = "not a function"
S.load(FIX)
T.check("13 checkPlant2 不是 function → 不動", C.checkPlant2 == "not a function" and C.MDFX_stallHeal == nil
    and S.printed("MDFX_FarmingStallHeal NOT installed"))

C = resetEnv()
orig = C.checkPlant2
farming_vegetableconf.props = nil
S.load(FIX)
T.check("13 props 不存在 → 不裝", C.checkPlant2 == orig and C.MDFX_stallHeal == nil
    and S.printed("MDFX_FarmingStallHeal NOT installed"))

C = resetEnv()
orig = C.checkPlant2
farming_vegetableconf = nil
S.load(FIX)
T.check("13 farming_vegetableconf 不存在 → 不裝", C.checkPlant2 == orig and S.printed("MDFX_FarmingStallHeal NOT installed"))

-- ── 14. 冪等與後載替換 ─────────────────────────────────────────
T.section("[14] 冪等與鏈接")
C = resetEnv()
S.load(FIX)
local w1 = C.checkPlant2
S.load(FIX)
T.check("14 本檔重跑不疊第二層", C.checkPlant2 == w1)
S.fireBoot()
T.check("14 OnGameBoot 復查不疊", C.checkPlant2 == w1)
p = plant({ nextGrowing = STALE, lastWaterHour = H })
C.checkPlant2(system(H), p)
T.check("14 原函式恰呼叫一次", #calls == 1)

C = resetEnv()
S.load(FIX)
local laterCalls = {}
local later = function(self, luaObject)
    laterCalls[#laterCalls + 1] = { self = self, nextGrowing = luaObject and luaObject.nextGrowing }
end
C.checkPlant2 = later
S.fireBoot()
T.check("14 後載 MOD 替換後，OnGameBoot 再包一層", C.checkPlant2 ~= later and C.MDFX_stallHeal == C.checkPlant2)
sys = system(H)
p = plant({ nextGrowing = STALE, lastWaterHour = H })
C.checkPlant2(sys, p)
T.check("14 新 original 是後載版本、看到重設後的值", #laterCalls == 1 and laterCalls[1].self == sys
    and laterCalls[1].nextGrowing == H + 100 and #calls == 0)

T.finish()
