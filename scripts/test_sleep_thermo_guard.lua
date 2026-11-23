-- MDFX_SleepThermoGuard 離線自我檢查
-- 用法（repo 根目錄）： lua scripts/test_sleep_thermo_guard.lua [--mutants]      需要 Lua 5.3+（string.pack 模擬 Java float）
-- 先跑不帶 --mutants 的確認全綠：基準有紅的時候 mutants 會全部顯示 KILLED，是假的。
-- 假引擎照 42.22.2 反編譯快照的形狀：GameTime.getMultiplier 的乘法順序（GameTime.java:963-981）、
-- Thermoregulator 的全域模擬倍率與 update() 裡兩個計時（:535-544、:626-659）、伺服器主迴圈的先後
-- （玩家更新 → OnTick → setFastForward → fpsMultiplier，GameServer.java:1060-1158）。
local SRC_PATH = "MOD/MinidoracatFixesFor42/Contents/mods/MinidoracatFixesFor42/"
    .. "42/media/lua/server/Fixes/MDFX_SleepThermoGuard.lua"

local function readFile(path)
    local f = assert(io.open(path, "rb"))
    local s = f:read("*a")
    f:close()
    return s
end
local SOURCE = readFile(SRC_PATH)
local realPrint = print
local loadSource = loadstring or load
local function f32(x) return (string.unpack("f", string.pack("f", x))) end
local BODY_HEAT = f32(2.5e-4)

local W

local function newWorld(o)
    o = o or {}
    local mode = o.mode or "server"
    W = { mpd = o.mpd or 1440, ffOpt = o.ff or 40, sleepAllowed = true, fast = false, mult = 1, fps = f32(o.fps or 6.03),
        sim = 1, writes = 0, prints = {}, players = {}, handlers = {}, minMult = 1 }
    MDFX_SleepThermoGuard = nil
    print = function(...)
        local parts = {}
        for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
        W.prints[#W.prints + 1] = table.concat(parts, "\t")
    end
    isServer = function() return mode == "server" end
    isClient = function() return mode == "client" end
    Events = { OnTick = { Add = function(fn) W.handlers[#W.handlers + 1] = fn end } }
    local gt = {}
    function gt:getDeltaMinutesPerDay() return f32(30 / W.mpd) end
    function gt:getMultiplier()
        local x = 1
        if W.fast then x = f32(W.ffOpt / self:getDeltaMinutesPerDay()) end
        return f32(f32(f32(x * W.mult) * W.fps) * f32(0.8))
    end
    function gt:getTrueMultiplier() return W.mult end
    function gt:setMultiplier(v)
        W.mult = f32(v)
        if W.mult < W.minMult then W.minMult = W.mult end
    end
    function gt:worldSeconds() return self:getMultiplier() / 0.8 / 60 * (1440 / W.mpd) end
    W.gt = gt
    getGameTime = function() return gt end
    local options = {
        getBoolean = function(_, key) if key == "SleepAllowed" then return W.sleepAllowed end end,
        getDouble = function(_, key) if key == "FastForwardMultiplier" then return W.ffOpt end end,
    }
    getServerOptions = function() return options end
    getOnlinePlayers = function()
        if W.failPlayers then error("boom players") end
        local list = W.players
        return { size = function() return #list end, get = function(_, i) return list[i + 1] end }
    end
    Thermoregulator = { setSimulationMultiplier = function(v)
        W.sim = f32(v)
        W.writes = W.writes + 1
    end }
    if o.noPlayersApi then getOnlinePlayers = nil end
    if o.noGameTime then getGameTime = nil end
    if o.noOptions then getServerOptions = nil end
    if o.noThermo then Thermoregulator = nil end
    if o.noSetter then Thermoregulator = {} end
    if o.noEvent then Events = {} end
end

local function player(o)
    o = o or {}
    local p = { asleep = o.asleep or false, dead = o.dead, god = o.god, square = not o.noSquare and {} or nil,
        steps = {}, dmgSteps = 0, dmgCounter = 0, duration = 0, roc = 0, rocHits = 0 }
    local th = {}
    function th:getSimulationMultiplier() return W.sim end
    function th:update()
        if p.failUpdate then error("boom update") end
        local m = W.gt:getMultiplier()
        p.roc = p.roc + m
        if p.roc > 100 then
            p.roc = 0
            p.rocHits = p.rocHits + 1
        end
        p.steps[#p.steps + 1] = f32(f32(m * BODY_HEAT) * W.sim)
        p.dmgCounter = p.dmgCounter + W.gt:worldSeconds()
        if p.dmgCounter > 1 then
            p.duration = p.duration + p.dmgCounter
            p.dmgCounter = 0
            p.dmgSteps = p.dmgSteps + 1
        end
    end
    local body = { getThermoregulator = function() return not o.noThermo and th or nil end }
    function p:getBodyDamage() return body end
    function p:isDead() return self.dead end
    function p:isGodMod() return self.god end
    function p:isAsleep() return self.asleep end
    function p:getCurrentSquare() return self.square end
    p.th = th
    W.players[#W.players + 1] = p
    return p
end

-- 一個伺服器 tick；nextFps：這一 tick 結束時伺服器算出的新 fpsMultiplier。回傳每位玩家這一 tick 的紀錄
local function frame(nextFps)
    local rec = {}
    for _, p in ipairs(W.players) do
        p.steps = {}
        rec[p] = { d0 = p.dmgSteps, r0 = p.rocHits, dur0 = p.duration, m = W.gt:getMultiplier(), sim0 = W.sim }
        if not p.dead and not p.god and p.square then p.th:update() end
    end
    for _, fn in ipairs(W.handlers) do fn() end
    for _, p in ipairs(W.players) do
        local r, sum, max = rec[p], 0, 0
        for _, s in ipairs(p.steps) do
            sum = sum + s
            if s > max then max = s end
        end
        r.count, r.sum, r.max = #p.steps, sum, max
        r.dmg, r.rocN, r.dur = p.dmgSteps - r.d0, p.rocHits - r.r0, p.duration - r.dur0
        r.full = r.m * BODY_HEAT -- 原版（模擬倍率 1）這一 tick 的步長
    end
    local alive, asleep = 0, 0
    for _, p in ipairs(W.players) do
        if not p.dead then
            alive = alive + 1
            if p.asleep then asleep = asleep + 1 end
        end
    end
    W.fast = W.sleepAllowed and alive > 0 and asleep == alive
    if nextFps then W.fps = f32(nextFps) end
    return rec
end

local function printed(needle)
    local n = 0
    for _, line in ipairs(W.prints) do
        if line:find(needle, 1, true) then n = n + 1 end
    end
    return n
end
local function near(a, b, rel) return math.abs(a - b) <= math.abs(b) * (rel or 1e-5) end

local function runSuite(src, quiet)
    local checks, failures = 0, 0
    local function check(label, cond, detail)
        checks = checks + 1
        if not cond then failures = failures + 1 end
        if not quiet then
            realPrint(string.format("  %s  %s%s", cond and "PASS" or "FAIL", label,
                (not cond and detail ~= nil) and ("  — " .. tostring(detail)) or ""))
        end
    end
    local function load(o)
        newWorld(o)
        assert(loadSource(src, "MDFX_SleepThermoGuard"))()
    end

    -- 1 單人與多人客戶端：不安裝
    load({ mode = "client" })
    check("1 多人客戶端不掛事件、不印", #W.handlers == 0 and #W.prints == 0)
    load({ mode = "sp" })
    check("1 單人不掛事件、不印", #W.handlers == 0 and #W.prints == 0)

    -- 2 引擎形狀不符：不安裝、印一行
    for _, opt in ipairs({ "noPlayersApi", "noGameTime", "noOptions", "noThermo", "noSetter", "noEvent" }) do
        load({ [opt] = true })
        check("2 " .. opt .. "：不安裝、印 NOT installed", #W.handlers == 0 and printed("NOT installed") == 1)
    end

    -- 3 伺服器掛一個 OnTick；重複載入不再掛
    load()
    check("3 掛一個 OnTick", #W.handlers == 1 and #W.prints == 0)
    assert(loadSource(src, "MDFX_SleepThermoGuard"))()
    check("3 重複載入不再掛", #W.handlers == 1)

    -- 4 醒著：不寫模擬倍率、不補步
    load()
    local p = player()
    local r
    for _ = 1, 5 do r = frame()[p] end
    check("4 醒著每 tick 1 步、不寫、不印", r.count == 1 and W.writes == 0 and #W.prints == 0 and MDFX_SleepThermoGuard.ticks == 0)

    -- 5 即時制：入睡 → 快轉 → 醒來
    load()
    p = player()
    frame()
    p.asleep = true
    r = frame()[p]
    check("5 入睡那一 tick 原版照走 1 步", r.count == 1 and r.m < 10, r.m)
    check("5 已先把下一 tick 設成 1/17", near(W.sim, 1 / 17), W.sim)
    local okSum, okMax, okDmg, okRoc, okDur, okCount, okMult, first = true, true, true, true, true, true, true, nil
    local firstDur
    for i = 1, 20 do
        r = frame(6.02 + (i % 3) * 0.01)[p]
        first = first or r
        if not near(r.sum, r.full) then okSum = false end
        if r.max > STEP_LIMIT then okMax = false end
        if r.dmg ~= 1 then okDmg = false end
        if r.rocN ~= 1 then okRoc = false end
        -- 第一個快轉 tick 會帶進醒著時還沒滿 1 秒的零頭（原版也一樣），從第二個起比
        if i > 1 and not near(r.dur, r.m / 0.8 / 60, 1e-3) then okDur = false end
        if i == 1 then firstDur = r.dur - r.m / 0.8 / 60 end
        if r.count ~= 17 then okCount = false end
        if W.mult ~= 1 then okMult = false end
    end
    check("5 第一個快轉 tick 就切成 17 步（沒有整步）", first.count == 17 and first.max <= STEP_LIMIT and first.m > 9000, first.max / BODY_HEAT)
    check("5 每 tick 17 步", okCount)
    check("5 每 tick 的總步長和原版相同", okSum)
    check("5 每一步不超過 STEP_MAX（容 1% 浮動）", okMax)
    check("5 凍傷／燒傷計時每 tick 只算一次", okDmg)
    check("5 凍傷累計的秒數和原版相同", okDur)
    check("5 第一個快轉 tick 多出來的只有醒著時的零頭（不到 1 秒）", firstDur >= 0 and firstDur < 1, firstDur)
    check("5 體溫變化箭頭每 tick 只取樣一次", okRoc)
    check("5 每 tick 結束時 GameTime 倍率已還原", okMult)
    check("5 補步時 GameTime 倍率縮到 1e-5 以下", W.minMult < 1e-5, W.minMult)
    check("5 補過步的 tick 數", MDFX_SleepThermoGuard.ticks == 20, MDFX_SleepThermoGuard.ticks)
    p.asleep = false
    r = frame()[p]
    check("5 醒來那一 tick 還在快轉，照樣 17 步、總步長相同", r.count == 17 and near(r.sum, r.full), r.count)
    check("5 醒來那一 tick 就把模擬倍率還原", W.sim == 1, W.sim)
    local writes = W.writes
    r = frame()[p]
    check("5 醒後原版 1 步、整步長", r.count == 1 and near(r.sum, r.full) and r.m < 10)
    frame() frame()
    check("5 醒後不再寫模擬倍率", W.writes == writes and W.sim == 1)
    check("5 診斷一行（倍率與步數）", #W.prints == 1 and printed("is sub-stepping body temperature") == 1
        and printed("17 steps per tick") == 1, table.concat(W.prints, " | "))
    -- 第二次睡覺：照樣切步，不再印
    p.asleep = true
    frame()
    r = frame()[p]
    check("5 第二次睡覺照樣切步、不再印", r.count == 17 and #W.prints == 1)

    -- 6 預設日長（快轉倍率約 583）：完全不動
    load({ mpd = 91 })
    p = player({ asleep = true })
    local touched = false
    for _ = 1, 10 do
        r = frame()[p]
        if r.count ~= 1 then touched = true end
    end
    check("6 預設日長不寫、不補步、不印", not touched and W.writes == 0 and #W.prints == 0 and r.m > 500
        and MDFX_SleepThermoGuard.ticks == 0, r.m)

    -- 7 6 小時日長（約 2315，剛過門檻）：5 步
    load({ mpd = 360 })
    p = player({ asleep = true })
    frame()
    r = frame()[p]
    check("7 6 小時日長切 5 步、總步長相同", r.count == 5 and near(r.sum, r.full) and r.m > 2304 and r.max <= STEP_LIMIT, r.count)

    -- 8 倍率剛好等於 TRIGGER（2304）：不介入；多一點就切
    load({ mpd = 480, ff = 36, fps = 5 })
    p = player({ asleep = true })
    for _ = 1, 4 do r = frame()[p] end
    check("8 倍率剛好 2304：不寫、不補步", r.m == 2304 and r.count == 1 and W.writes == 0, r.m)
    frame(5.01)
    frame(5.01)
    r = frame(5.01)[p]
    check("8 倍率 2308：切 5 步", r.count == 5 and r.m > 2304, r.count)

    -- 9 倍率異常大：步數有上限，總步長仍相同
    load({ fps = 6000 })
    p = player({ asleep = true })
    frame()
    r = frame()[p]
    check("9 倍率異常大時最多 64 步、總步長相同", r.count == 64 and near(r.sum, r.full), r.count)

    -- 10 多位玩家：各自補步；無敵、死亡、所在格沒載入、沒有體溫模擬的不補
    load()
    local g = player({ asleep = true, god = true }) -- 排第一：模擬倍率照樣讀得到
    local a, b = player({ asleep = true }), player({ asleep = true })
    local d = player({ dead = true })
    local ns = player({ asleep = true, noSquare = true })
    local nt = player({ asleep = true, noThermo = true })
    frame()
    local rr = frame()
    check("10 兩位各 17 步", rr[a].count == 17 and rr[b].count == 17)
    check("10 無敵的不補", rr[g].count == 0, rr[g].count)
    check("10 死亡的不補", rr[d].count == 0, rr[d].count)
    check("10 所在格沒載入的不補", rr[ns].count == 0, rr[ns].count)
    check("10 沒有體溫模擬的跳過、不出錯", rr[nt].count == 1 and printed("disabled") == 0, rr[nt].count)

    -- 11 有人醒著：伺服器不快轉，不寫
    load()
    a, b = player({ asleep = true }), player()
    for _ = 1, 4 do rr = frame() end
    check("11 有人醒著不寫、不補步", W.writes == 0 and rr[a].count == 1 and rr[a].m < 10)

    -- 12 死亡的不算人數：一位睡著、一位死亡，伺服器照樣快轉，第一個快轉 tick 就切步
    load()
    a, d = player({ asleep = true }), player({ dead = true })
    frame()
    r = frame()[a]
    check("12 死亡的不算：第一個快轉 tick 就切步", r.count == 17 and r.m > 9000, r.count)

    -- 13 沒有活著的玩家：不寫
    load()
    d = player({ dead = true, asleep = true })
    for _ = 1, 3 do frame() end
    check("13 沒有活著的玩家不寫", W.writes == 0)

    -- 14 SleepAllowed 關：全員睡著伺服器也不快轉，不寫
    load()
    W.sleepAllowed = false
    p = player({ asleep = true })
    for _ = 1, 4 do r = frame()[p] end
    check("14 SleepAllowed 關：不寫、不補步", W.writes == 0 and r.count == 1)

    -- 15 模擬倍率原本不是 1：以它為準、離開時還原
    load()
    W.sim = 0.5
    p = player({ asleep = true })
    frame()
    r = frame()[p]
    check("15 原值 0.5：這一 tick 用 0.5/17、切 17 步、總步長是原值的那一步", near(r.sim0, 0.5 / 17) and r.count == 17
        and near(r.sum, r.full * 0.5), r.sim0)
    r = frame()[p]
    check("15 第二個快轉 tick 仍是 0.5/17（不拿切過的值再切）", near(r.sim0, 0.5 / 17) and near(r.sum, r.full * 0.5), r.sim0)
    p.asleep = false
    frame()
    check("15 離開時還原成 0.5", W.sim == 0.5, W.sim)

    -- 16 切步期間模擬倍率被別人改掉：不補步、不還原、印一行、之後不再寫
    load()
    p = player({ asleep = true })
    frame() frame()
    W.sim = 0.5
    writes = W.writes
    r = frame()[p]
    check("16 被別人改掉：不補步、不還原", r.count == 1 and W.sim == 0.5, r.count)
    check("16 印一行 disabled（原因與兩個值）", printed("something else changed") == 1 and printed("found 0.5") == 1,
        table.concat(W.prints, " | "))
    frame() frame()
    check("16 之後不再寫、不再補步", W.writes == writes and W.sim == 0.5 and #W.prints == 2)

    -- 17 補步中出錯（Lua 層的錯：用到的方法不見了、型別對不上）：不外洩、GameTime 倍率與模擬倍率都還原、印一行、停用。
    --    update() 本體丟的 Java 例外不走這條：引擎接住後回 nil，補步照跑完、倍率照樣還原，不會停用
    load()
    W.mult = 3 -- 管理員調過時間倍率：還原的是當時的值
    p = player({ asleep = true })
    frame() frame()
    p.failUpdate = true
    local ok = pcall(function() for _, fn in ipairs(W.handlers) do fn() end end)
    check("17 錯誤不外洩", ok)
    check("17 GameTime 倍率還原成原值", W.mult == 3, W.mult)
    check("17 模擬倍率還原成切步前的值", W.sim == 1, W.sim)
    check("17 印一行 disabled after an internal error", printed("disabled after an internal error") == 1
        and printed("boom update") == 1, table.concat(W.prints, " | "))
    p.failUpdate = false
    writes = W.writes
    r = frame()[p]
    check("17 之後照原版", r.count == 1 and W.writes == writes and #W.prints == 2)

    -- 18 補步以外的地方出錯（切步期間）：模擬倍率還原、停用
    load()
    p = player({ asleep = true })
    frame() frame()
    W.failPlayers = true
    ok = pcall(function() for _, fn in ipairs(W.handlers) do fn() end end)
    check("18 錯誤不外洩、模擬倍率還原、印一行", ok and W.sim == 1 and printed("disabled after an internal error") == 1, W.sim)
    W.failPlayers = false
    writes = W.writes
    frame()
    check("18 之後不再執行", W.writes == writes and #W.prints == 2)

    -- 19 切步期間玩家全部離線：不出錯、模擬倍率還原
    load()
    p = player({ asleep = true })
    frame() frame() frame()
    W.players = {}
    frame()
    check("19 全部離線：還原、不停用", W.sim == 1 and printed("disabled") == 0, W.sim)

    -- 20 快轉中倍率變動讓步數改變：每 tick 的總步長仍相同
    load({ fps = 6 })
    p = player({ asleep = true })
    frame()
    local okVar, seen = true, {}
    for i = 1, 8 do
        r = frame(i % 2 == 0 and 5.9 or 6.2)[p]
        seen[r.count] = true
        if not near(r.sum, r.full) then okVar = false end
    end
    check("20 步數在 16 與 17 之間變動時總步長仍相同", okVar and seen[16] and seen[17])

    -- 21 醒著時倍率再高也不介入（管理員把時間倍率調得很高）
    load()
    W.mult = 600
    p = player()
    for _ = 1, 4 do r = frame()[p] end
    check("21 醒著、倍率 2894：不寫、不補步", r.m > 2304 and r.count == 1 and W.writes == 0, r.m)

    -- 22 全員睡著但讀不到任何一位的體溫模擬：不出錯、不寫
    load()
    player({ asleep = true, noThermo = true })
    frame() frame() frame()
    check("22 讀不到體溫模擬：不寫、不停用", W.writes == 0 and #W.prints == 0, table.concat(W.prints, " | "))

    return checks, failures
end

STEP_LIMIT = 576 * 1.01 * BODY_HEAT

local MUTANTS = {
    { name = "拿掉防重複載入", subs = { { "if MDFX_SleepThermoGuard then return end", "" } } },
    { name = "單人與客戶端也安裝", subs = { { ' or not isServer() then return end', ' then return end' } } },
    { name = "形狀檢查不看事件", subs = { { "if not (event and event.Add and getOnlinePlayers", "if not (getOnlinePlayers" } } },
    { name = "形狀檢查不看 getOnlinePlayers", subs = { { "event.Add and getOnlinePlayers and getGameTime", "event.Add and getGameTime" } } },
    { name = "形狀檢查不看 getGameTime", subs = { { "getOnlinePlayers and getGameTime and getServerOptions", "getOnlinePlayers and getServerOptions" } } },
    { name = "形狀檢查不看 getServerOptions", subs = { { "getGameTime and getServerOptions\n", "getGameTime\n" } } },
    { name = "形狀檢查不看 Thermoregulator", subs = { { "        and Thermoregulator and Thermoregulator.setSimulationMultiplier) then", "        ) then" } } },
    { name = "形狀檢查不看 setSimulationMultiplier", subs = { { "and Thermoregulator and Thermoregulator.setSimulationMultiplier) then", "and Thermoregulator) then" } } },
    { name = "門檻放寬到 4608", subs = { { "local TRIGGER = 2304", "local TRIGGER = 4608" } } },
    { name = "門檻降到 576（預設日長也切）", subs = { { "local TRIGGER = 2304", "local TRIGGER = 576" } } },
    { name = "小步上限放寬到 1152", subs = { { "local STEP_MAX = 576", "local STEP_MAX = 1152" } } },
    { name = "小步上限縮到 288", subs = { { "local STEP_MAX = 576", "local STEP_MAX = 288" } } },
    { name = "介入後拿門檻當小步上限", subs = { { "math.ceil(nextM / STEP_MAX)", "math.ceil(nextM / TRIGGER)" } } },
    { name = "步數無條件捨去", subs = { { "math.ceil(nextM / STEP_MAX)", "math.floor(nextM / STEP_MAX)" } } },
    { name = "步數沒有上限", subs = { { "math.min(math.ceil(nextM / STEP_MAX), N_MAX)", "math.ceil(nextM / STEP_MAX)" } } },
    { name = "補 N 步（多一步）", subs = { { "for _ = 2, stepN do", "for _ = 1, stepN do" } } },
    { name = "不補步", subs = { { "for _ = 2, stepN do th:update() end", "" } } },
    { name = "補步時不縮 GameTime 倍率也不放大模擬倍率", subs = {
        { "gt:setMultiplier(keep * EPS)", "gt:setMultiplier(keep)" },
        { "Thermoregulator.setSimulationMultiplier(stepSim / EPS)", "Thermoregulator.setSimulationMultiplier(stepSim)" } } },
    { name = "只縮 GameTime 倍率", subs = { { "Thermoregulator.setSimulationMultiplier(stepSim / EPS)", "Thermoregulator.setSimulationMultiplier(stepSim)" } } },
    { name = "只放大模擬倍率", subs = { { "gt:setMultiplier(keep * EPS)", "gt:setMultiplier(keep)" } } },
    { name = "EPS 不夠小", subs = { { "local EPS = 1 / 1048576", "local EPS = 1 / 64" } } },
    { name = "補步後不還原 GameTime 倍率", subs = { { "        gt:setMultiplier(keep)\n", "" } } },
    { name = "補步出錯不處理", subs = { { "        if not ok then return fail(err) end\n", "" } } },
    { name = "拿掉補步的 pcall", subs = { { "local ok, err = pcall(substeps, gt, players, keep)", "local ok, err = true, substeps(gt, players, keep)" } } },
    { name = "死亡的也補", subs = { { "if player and not player:isDead() and not player:isGodMod()", "if player and not player:isGodMod()" } } },
    { name = "無敵的也補", subs = { { " and not player:isGodMod() and player:getCurrentSquare() then", " and player:getCurrentSquare() then" } } },
    { name = "所在格沒載入的也補", subs = { { " and not player:isGodMod() and player:getCurrentSquare() then", " and not player:isGodMod() then" } } },
    { name = "不檢查有沒有體溫模擬", subs = { { "            if th then\n                for _ = 2, stepN do th:update() end\n            end\n", "            for _ = 2, stepN do th:update() end\n" } } },
    { name = "不檢查模擬倍率有沒有被別人改", subs = { { "if found ~= stepSim then", "if false then" } } },
    { name = "被別人改掉後不停用", subs = { { "disabled, stepN = true, nil", "stepN = nil" } } },
    { name = "被別人改掉不印", subs = { { '            say(string.format("disabled: something else', '            tostring(string.format("disabled: something else' } } },
    { name = "記寫入的值而不是讀回的值", subs = { { "stepN, stepSim = n, probe:getSimulationMultiplier()", "stepN, stepSim = n, base / n" } } },
    { name = "剛好等於門檻也切", subs = { { "nextM > TRIGGER and", "nextM >= TRIGGER and" } } },
    { name = "不估下一 tick（剛睡著時只看這一 tick）", subs = { { "nextM = wasAll and m or m * getServerOptions()", "nextM = wasAll and m or m + 0 * getServerOptions()" } } },
    { name = "已在快轉還再乘一次快轉倍率", subs = { { "nextM = wasAll and m or m * getServerOptions()", "nextM = m * getServerOptions()" } } },
    { name = "有人醒著也切", subs = { { "    if all and probe then\n", "    if probe then\n" } } },
    { name = "醒著但倍率高也切", subs = { { "    if all and probe then\n", "    if (all or m > TRIGGER) and probe then\n" } } },
    { name = "讀不到體溫模擬照樣切", subs = { { "    if all and probe then\n", "    if all then\n" } } },
    { name = "不記上一 tick 的全員睡著", subs = { { "    wasAll = all\n", "" } } },
    { name = "快轉倍率不除一天長度", subs = { { ' / gt:getDeltaMinutesPerDay()', '' } } },
    { name = "不看 SleepAllowed", subs = { { '    if getServerOptions():getBoolean("SleepAllowed") ~= true then return false end\n', "" } } },
    { name = "死亡的也算人數", subs = { { "        if player and not player:isDead() then\n", "        if player then\n" } } },
    { name = "有人醒著也算全員睡著", subs = { { "            if not player:isAsleep() then return false end\n", "" } } },
    { name = "沒有活人也算全員睡著", subs = { { "    return alive > 0\n", "    return true\n" } } },
    { name = "原值一律當 1", subs = { { "if not stepN then base = probe:getSimulationMultiplier() end", "base = 1" } } },
    { name = "每 tick 重讀原值", subs = { { "if not stepN then base = probe:getSimulationMultiplier() end", "base = probe:getSimulationMultiplier()" } } },
    { name = "不寫 1/N", subs = { { "        Thermoregulator.setSimulationMultiplier(base / n)\n", "" } } },
    { name = "離開時不還原", subs = { { "        Thermoregulator.setSimulationMultiplier(base)\n        stepN, stepSim, base = nil, nil, nil", "        stepN, stepSim, base = nil, nil, nil" } } },
    { name = "離開時不清狀態", subs = { { "        Thermoregulator.setSimulationMultiplier(base)\n        stepN, stepSim, base = nil, nil, nil", "        Thermoregulator.setSimulationMultiplier(base)" } } },
    { name = "沒有玩家時照樣補", subs = { { "if stepN and probe then", "if stepN then" } } },
    { name = "診斷每 tick 都印", subs = { { "if not logged then", "if true then" } } },
    { name = "不印診斷", subs = { { '            say(string.format("is sub-stepping', '            tostring(string.format("is sub-stepping' } } },
    { name = "不計補過步的 tick", subs = { { "        G.ticks = G.ticks + 1\n", "" } } },
    { name = "拿掉外層 pcall", subs = { { "local ok, err = pcall(tick)", "local ok, err = true, tick()" } } },
    { name = "出錯後不停用", subs = { { "local function fail(err)\n    disabled = true\n", "local function fail(err)\n" } } },
    { name = "出錯後不還原模擬倍率", subs = { { "    if stepN then pcall(function() Thermoregulator.setSimulationMultiplier(base) end) end\n", "" } } },
    { name = "停用後照樣執行", subs = { { "    if disabled then return end\n", "" } } },
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
