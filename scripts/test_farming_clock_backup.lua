-- MDFX_FarmingClockBackup 離線自我檢查
-- 用法（repo 根目錄）： lua scripts/test_farming_clock_backup.lua
--
-- 以最小假 vanilla SFarmingSystem（instance.hoursElapsed、instance.system:loadedWorldVersion()，
-- 照 SFarmingSystem.lua:7-27、:87-93、SGlobalObjectSystem.java:207）與假 GlobalModData
-- （ModData.exists／get／getOrCreate 靜態方法）驗證：
--   * isClient() 為真時完全不安裝
--   * 存檔正常讀到（version 249）：時鐘不動；EveryTenMinutes 把時鐘抄進 ModData
--   * 讀檔失敗（version -1）＋備份比時鐘大 → 還原並印一次診斷；之後備份跟著時鐘走
--   * 沒有備份、備份不大於時鐘、備份不是數字 → 不動
--   * 開機沒有 instance → NOT installed；這一局沒確認存檔讀到就不寫備份
--   * loadedWorldVersion 拋錯、getOrCreate 拋錯 → 不炸、不還原、診斷只一次
--   * 診斷每 session 只印一次

local S = dofile("scripts/_stub.lua")
local T = S.checker()
local FIX = S.SERVER_FIXES .. "MDFX_FarmingClockBackup.lua"
local KEY = "MinidoracatFixes_FarmingClock"

-- 事件依註冊順序觸發（LuaEventManager）
local function newEvent()
    local ev = { handlers = {} }
    function ev.Add(fn) ev.handlers[#ev.handlers + 1] = fn end
    function ev.fire()
        for i = 1, #ev.handlers do ev.handlers[i]() end
    end
    return ev
end

local STORE
local W -- 這一局存檔讀完的樣子：clock（gos_farming.bin 讀到的時鐘）、version、noInstance

-- 假 GlobalModData（ModData 是 exposed 靜態類別，用 . 呼叫）
local function newModData(getOrCreateThrows)
    return {
        exists = function(tag) return STORE[tag] ~= nil end,
        get = function(tag) return STORE[tag] end,
        getOrCreate = function(tag)
            if getOrCreateThrows then error("ModData boom") end
            STORE[tag] = STORE[tag] or {}
            return STORE[tag]
        end,
    }
end

local function newInstance(clock, version)
    return {
        hoursElapsed = clock,
        system = { loadedWorldVersion = function(self)
            if version == "throw" then error("loadedWorldVersion boom") end
            return version
        end },
    }
end

-- 每段都是新的一局：vanilla 的兩個 handler 先註冊（fix 的 require 讓原版先跑）
local function resetEnv(opts)
    opts = opts or {}
    S.reset()
    local client = opts.client == true
    isClient = function() return client end
    package.loaded["Farming/SFarmingSystem"] = true
    Events.OnSGlobalObjectSystemInit = newEvent()
    Events.EveryTenMinutes = newEvent()
    STORE = opts.store or {}
    ModData = newModData(opts.getOrCreateThrows)
    W = { clock = opts.clock or 0, version = opts.version, noInstance = opts.noInstance }
    SFarmingSystem = {}
    -- 原版 initSystems → SFarmingSystem:new()：沒讀到檔時 hoursElapsed = 0（SFarmingSystem.lua:11）
    Events.OnSGlobalObjectSystemInit.Add(function()
        if W.noInstance then return end
        SFarmingSystem.instance = newInstance(W.clock, W.version)
    end)
    -- 原版 EveryTenMinutes（SFarmingSystem.lua:582-586、:93；這裡每次都當成換了一小時）
    Events.EveryTenMinutes.Add(function()
        SFarmingSystem.instance.hoursElapsed = SFarmingSystem.instance.hoursElapsed + 1
    end)
end

local function fire(ev)
    local ok, err = pcall(ev.fire)
    return ok, tostring(err)
end

local function clock() return SFarmingSystem.instance.hoursElapsed end
local function backup() return STORE[KEY] and STORE[KEY].hoursElapsed end

-- ── 1. client：完全不安裝 ────────────────────────────────────────
T.section("[1] isClient() 為真時零介入")
resetEnv({ client = true })
S.load(FIX)
T.check("1 不註冊 OnSGlobalObjectSystemInit", #Events.OnSGlobalObjectSystemInit.handlers == 1)
T.check("1 不註冊 EveryTenMinutes", #Events.EveryTenMinutes.handlers == 1)

-- ── 2. 存檔正常讀到 ─────────────────────────────────────────────
T.section("[2] 正常讀檔（version 249）")
resetEnv({ clock = 100, version = 249, store = { [KEY] = { hoursElapsed = 30104 } } })
S.load(FIX)
T.check("2 註冊兩個 handler、排在原版之後", #Events.OnSGlobalObjectSystemInit.handlers == 2
    and #Events.EveryTenMinutes.handlers == 2)
local ok = fire(Events.OnSGlobalObjectSystemInit)
T.check("2 開機不炸", ok)
T.check("2 備份比時鐘大也不動時鐘", clock() == 100, tostring(clock()))
fire(Events.EveryTenMinutes)
T.check("2 EveryTenMinutes 在原版 +1 之後抄時鐘", backup() == 101, tostring(backup()))
T.check("2 不印任何診斷", not S.printed("[MinidoracatFixes]"))

-- ── 3. 讀檔失敗、有備份 → 還原 ───────────────────────────────────
T.section("[3] 讀檔失敗（version -1）＋備份 30104")
resetEnv({ clock = 0, version = -1, store = { [KEY] = { hoursElapsed = 30104 } } })
S.load(FIX)
ok = fire(Events.OnSGlobalObjectSystemInit)
T.check("3 開機不炸", ok)
T.check("3 時鐘還原成 30104", clock() == 30104, tostring(clock()))
T.check("3 還原診斷印一次", S.printCount("farming clock restored from backup") == 1)
T.check("3 診斷帶前後值", S.printed("hoursElapsed 0 -> 30104"))
fire(Events.EveryTenMinutes)
T.check("3 之後備份跟著還原後的時鐘走", backup() == 30105 and clock() == 30105, tostring(backup()))

-- ── 4. 讀檔失敗、沒有備份（新世界）─────────────────────────────
T.section("[4] 讀檔失敗、沒有備份")
resetEnv({ clock = 0, version = -1 })
S.load(FIX)
ok = fire(Events.OnSGlobalObjectSystemInit)
T.check("4 開機不炸、時鐘不動", ok and clock() == 0)
fire(Events.EveryTenMinutes)
T.check("4 開始寫備份", backup() == 1, tostring(backup()))
T.check("4 不印還原診斷", not S.printed("restored"))

-- ── 5. 備份不大於時鐘 ──────────────────────────────────────────
T.section("[5] 備份 <= 時鐘")
for _, saved in ipairs({ 500, 400 }) do
    resetEnv({ clock = 500, version = -1, store = { [KEY] = { hoursElapsed = saved } } })
    S.load(FIX)
    ok = fire(Events.OnSGlobalObjectSystemInit)
    T.check("5 備份 " .. saved .. " → 時鐘 500 不動", ok and clock() == 500, tostring(clock()))
    T.check("5 備份 " .. saved .. " → 不印還原診斷", not S.printed("restored"))
end

-- ── 6. 備份不是數字 ────────────────────────────────────────────
T.section("[6] 備份不是數字")
for _, case in ipairs({ { "string", { hoursElapsed = "30104" } }, { "nil", {} } }) do
    local label, rec = case[1], case[2]
    resetEnv({ clock = 0, version = -1, store = { [KEY] = rec } })
    S.load(FIX)
    local okInit, err = fire(Events.OnSGlobalObjectSystemInit)
    T.check("6 " .. label .. " → 不炸", okInit, err)
    T.check("6 " .. label .. " → 時鐘不動", clock() == 0, tostring(clock()))
    T.check("6 " .. label .. " → 不印還原診斷", not S.printed("restored"))
end

-- ── 7. 開機時沒有 instance ─────────────────────────────────────
T.section("[7] OnSGlobalObjectSystemInit 時 instance 不存在")
resetEnv({ noInstance = true, store = { [KEY] = { hoursElapsed = 30104 } } })
S.load(FIX)
ok = fire(Events.OnSGlobalObjectSystemInit)
fire(Events.OnSGlobalObjectSystemInit)
T.check("7 不炸、NOT installed 只印一次", ok and S.printCount("MDFX_FarmingClockBackup NOT installed") == 1)
SFarmingSystem.instance = newInstance(0, -1) -- 之後才出現、存檔也沒讀到
ok = fire(Events.EveryTenMinutes)
T.check("7 version -1 → 不拿歸零的時鐘蓋掉備份", ok and backup() == 30104, tostring(backup()))
SFarmingSystem.instance = newInstance(0, "throw")
ok = fire(Events.EveryTenMinutes)
T.check("7 loadedWorldVersion 拋錯 → 不炸、也不寫", ok and backup() == 30104, tostring(backup()))
SFarmingSystem.instance = newInstance(700, 249)
fire(Events.EveryTenMinutes)
T.check("7 version 249 → 寫備份", backup() == 701, tostring(backup()))

-- ── 8. loadedWorldVersion 拋錯 ─────────────────────────────────
T.section("[8] loadedWorldVersion 拋錯")
resetEnv({ clock = 0, version = "throw", store = { [KEY] = { hoursElapsed = 30104 } } })
S.load(FIX)
local err
ok, err = fire(Events.OnSGlobalObjectSystemInit)
T.check("8 開機不炸", ok, err)
T.check("8 判斷不了就不還原", clock() == 0, tostring(clock()))
ok, err = fire(Events.EveryTenMinutes)
T.check("8 EveryTenMinutes 不炸", ok, err)

-- ── 9. getOrCreate 拋錯 ────────────────────────────────────────
T.section("[9] ModData.getOrCreate 拋錯")
resetEnv({ clock = 10, version = 249, getOrCreateThrows = true })
S.load(FIX)
fire(Events.OnSGlobalObjectSystemInit)
ok, err = fire(Events.EveryTenMinutes)
T.check("9 不炸", ok, err)
fire(Events.EveryTenMinutes)
fire(Events.EveryTenMinutes)
T.check("9 診斷跨多次 tick 只印一次", S.printCount("could not write the clock backup") == 1)
T.check("9 診斷帶原因", S.printed("ModData boom"))
T.check("9 原版時鐘照走", clock() == 13, tostring(clock()))

-- ── 10. 診斷每 session 一次 ────────────────────────────────────
T.section("[10] 診斷節流")
resetEnv({ clock = 0, version = -1, store = { [KEY] = { hoursElapsed = 30104 } } })
S.load(FIX)
fire(Events.OnSGlobalObjectSystemInit)
fire(Events.OnSGlobalObjectSystemInit) -- 原版 handler 再建一次 instance，時鐘又是 0：第二輪也真的還原
T.check("10 第二次 init 也還原", clock() == 30104, tostring(clock()))
T.check("10 還原診斷只印一次", S.printCount("farming clock restored from backup") == 1)

T.finish()
