-- MDFX_GiveWaterAnimalGuard 離線自我檢查
-- 用法（repo 根目錄）： lua scripts/test_give_water_animal_guard.lua [--mutants]
--
-- 假引擎照 42.21.0 反編譯快照驅動 server 端整條路徑，不是只呼叫 wrapper：
--   NetTimedAction.parse 以 new() 重建動作（NetTimedAction.java:142-171）
--   → ActionManager.start：setTimeData 把 getDuration 的 -1 換成 30 分鐘上限（Action.java:27-35），
--     再 serverStart 註冊每 400 ms 的 update 模擬事件（NetTimedAction.java:95-104）
--   → 每幀 100 ms（GameServer 鎖 10 FPS，GameServer.java:839-840）：先 AnimEventEmulator.update
--     （IngameState.java:1559 的 UpdateStuff），再 ActionManager.update（:1645 的 updateManagers）；
--     結束時間到了就 perform → complete，true＝Done、false 或拋錯＝Reject，兩者都通知 client
--     （ActionManager.java:64-113）。
-- vanilla ISGiveWaterToAnimal 在 server 會被呼叫的 method 照原版行號抄成 stub。驗證：
--   * isServer() 為假時完全不安裝
--   * 正常餵水（喝飽結束、水用完結束）與原版逐事件相同：口渴、水量、XP、事件數、Done、setThirst
--   * 動物為 nil：只走一次模擬事件、零例外、以 Reject 結束並通知 client、診斷恰一行且欄位齊全
--   * 對照組：原版每個模擬事件都拋錯、動作一直掛著；30 分鐘上限到時 complete 再拋一次、perform 失敗走 Reject
--   * 每個動作只記一行（animEvent 之後的 complete、同一動作重複事件都不再記）；每 session 上限 20 行＋一次上限提示
--   * 不吞不認識的錯誤：self.item 為 nil、原函式自己拋錯都照原版外洩；非 update 事件照常交給原函式
--   * 重複載入不疊 wrapper；後載 MOD 整支替換後 OnGameBoot 復查重新包裝
--   * vanilla 缺席／部分缺席時不亂補、不炸；除 marker 外不動 class 既有成員
--   * 別的 MOD 把 server 時長改成正數時照樣在第一個模擬事件結束；時長短於 0.4 秒由 complete 先擋下
-- --mutants：逐一抽掉每道防線（含整支修正與 MDFX_Guard 骨架），確認至少一項檢查轉紅。

local S = dofile("scripts/_stub.lua")
local realPrint = S.realPrint

local function readFile(path)
    local f = assert(io.open(path, "rb"))
    local s = f:read("*a")
    f:close()
    return s
end

local SOURCES = {
    fix = readFile(S.SERVER_FIXES .. "MDFX_GiveWaterAnimalGuard.lua"),
    guard = readFile(S.GUARD),
}

-- ── 假引擎（server 端 Java 生命週期）────────────────────────────
local DURATION_MAX = 1800000 -- AnimEventEmulator.getDurationMax（AnimEventEmulator.java:19-21）
local FRAME_MS = 100

local E -- 每段一份

local function newEngine()
    E = { now = 0, actions = {}, events = {}, errors = {}, verdicts = {}, verdictAt = {},
        fired = 0, xp = 0, commands = {}, performFailed = 0, trace = {} }
end

-- LuaCaller.protectedCall*：Lua 錯誤由引擎印出，不往外丟
local function protected(fn, ...)
    local ok, r = pcall(fn, ...)
    if not ok then E.errors[#E.errors + 1] = tostring(r) end
    return ok, r
end

-- 原版全域
function emulateAnimEvent(netAction, duration, event, parameter) -- LuaManager.java:12227-12231 → AnimEventEmulator.java:23-26
    E.events[#E.events + 1] = { action = netAction, duration = duration, start = E.now, time = E.now,
        event = event, parameter = parameter }
end
function addXp(chr, perk, amount) E.xp = E.xp + amount end
function sendServerCommandV(module, command, ...)
    E.commands[#E.commands + 1] = { module = module, command = command, args = { ... } }
end
Perks = { Husbandry = "Husbandry" }
CharacterStat = { THIRST = "THIRST" }

-- NetTimedAction：forceComplete 把結束時間設成現在（NetTimedAction.java:173-175）
local function newNetAction(action)
    local na = { action = action, state = "Request", forceCompletes = 0 }
    function na:forceComplete()
        self.forceCompletes = self.forceCompletes + 1
        self.endTime = E.now
    end
    return na
end

-- client 送來一個餵水動作：parse（new 失敗或回 nil 就拒絕，NetTimedAction.java:159-163）→ start → Accept
local function request(character, animal, item, opts)
    opts = opts or {}
    local ok, action = protected(ISGiveWaterToAnimal.new, ISGiveWaterToAnimal, character, animal, item)
    if not ok or action == nil then
        E.verdicts[#E.verdicts + 1] = "Reject"
        return nil
    end
    local na = newNetAction(action)
    if not opts.noNetAction then action.netAction = na end
    na.startTime = E.now
    -- getDuration（NetTimedAction.java:71-83）：-1 原樣保留（adjustMaxTime 只調整 > 1，ISBaseTimedAction.lua:99-100）
    local okD, d = protected(action.getDuration, action)
    na.duration = okD and (d == -1 and -1 or d * 20) or 0
    na.endTime = na.duration < 0 and (E.now + DURATION_MAX) or (E.now + na.duration)
    if action.serverStart then protected(action.serverStart, action) end
    na.state = "Accept"
    E.actions[#E.actions + 1] = na
    return na
end

local function frame()
    E.now = E.now + FRAME_MS
    -- AnimEventEmulator.update（AnimEventEmulator.java:33-47）
    for _, ev in ipairs(E.events) do
        if ev.action ~= nil and E.now >= ev.time + ev.duration then
            E.fired = E.fired + 1
            local fn = ev.action.action.animEvent -- NetTimedAction.animEvent（:187-192），rawget 走 metatable
            if fn then protected(fn, ev.action.action, ev.event, ev.parameter) end
            if E.sample then E.trace[#E.trace + 1] = E.sample() end
            ev.time = E.now
        end
    end
    local keep = {}
    for _, ev in ipairs(E.events) do
        if E.now < ev.start + DURATION_MAX then keep[#keep + 1] = ev end
    end
    E.events = keep
    -- ActionManager.update（ActionManager.java:64-113）
    for _, na in ipairs(E.actions) do
        if na.state == "Accept" and na.endTime <= E.now then
            -- perform（NetTimedAction.java:132-139）：pcallBoolean 出錯或不是 boolean 都是 null，拆箱 NPE 被 catch 成 false
            local ok, r = protected(na.action.complete, na.action)
            if not ok then E.performFailed = E.performFailed + 1 end
            na.state = (ok and r == true) and "Done" or "Reject"
            E.verdicts[#E.verdicts + 1] = na.state
            E.verdictAt[#E.verdictAt + 1] = E.now
        end
    end
    local alive = {}
    for _, na in ipairs(E.actions) do
        if na.state == "Done" or na.state == "Reject" then
            local k = {} -- AnimEventEmulator.remove（:28-30）
            for _, ev in ipairs(E.events) do
                if ev.action ~= na then k[#k + 1] = ev end
            end
            E.events = k
        else
            alive[#alive + 1] = na
        end
    end
    E.actions = alive
end

local function runFor(ms)
    for _ = 1, math.floor(ms / FRAME_MS) do frame() end
end

-- ── vanilla stub（shared/TimedActions/Animals/ISGiveWaterToAnimal.lua）─────────
local V -- 原函式呼叫次數
local vanilla = {}

vanilla.new = function(self, character, animal, item) -- :124-133（ISBaseTimedAction.new 的 metatable 寫法）
    local o = setmetatable({}, self)
    self.__index = self
    o.character = character
    o.maxTime = -1
    o.animal = animal
    o.item = item
    o.timePerUse = 20
    o.maxTime = o:getDuration()
    o.timer = 0
    o.lastTimer = 0
    return o
end

vanilla.getDuration = function(self) -- :102-116，本測試只跑 server 分支
    if isServer() then
        return -1
    end
    error("client branch not modelled")
end

vanilla.serverStart = function(self) -- :97-100
    local period = self.timePerUse * 20
    emulateAnimEvent(self.netAction, period, "update", nil)
end

vanilla.animEvent = function(self, event, parameter) -- :82-95
    V.animEvent = V.animEvent + 1
    if isServer() then
        if event == "update" then
            self.animal:getStats():remove(CharacterStat.THIRST, 0.05 * self.animal:getThirstBoost()) -- :85
            self.item:getFluidContainer():removeFluid(0.05, false) -- :86
            self.item:sendSyncEntity(nil) -- :87
            addXp(self.character, Perks.Husbandry, 2) -- :88
            if self.animal:getStats():get(CharacterStat.THIRST) <= 0 or self.item:getFluidContainer():isEmpty() then -- :90
                self.netAction:forceComplete() -- :91
            end
        end
    end
end

vanilla.complete = function(self) -- :75-80
    V.complete = V.complete + 1
    sendServerCommandV("animal", "setThirst",
        "id", self.animal:getOnlineID(),
        "value", self.animal:getThirst())
    return true
end

local function newAnimal(thirst, id)
    local stats = { thirst = thirst }
    function stats:remove(stat, v) self.thirst = math.max(0, self.thirst - v) end
    function stats:get(stat) return self.thirst end
    local a = { stats = stats }
    function a:getStats() return stats end
    function a:getThirstBoost() return 1.0 end -- 牛：AnimalDefinitions.java:129 預設 1.0
    function a:getOnlineID() return id or 7 end
    function a:getThirst() return stats.thirst end
    return a
end

-- 流體以整數 ml 記，避免浮點殘量；isEmpty＝量為 0（FluidContainer.java:522-524）
local function newItem(ml)
    local fc = { ml = ml }
    function fc:removeFluid(liters, createConsume) self.ml = math.max(0, self.ml - math.floor(liters * 1000 + 0.5)) end
    function fc:isEmpty() return self.ml == 0 end
    local it = { fc = fc, syncs = 0 }
    function it:getFluidContainer() return fc end
    function it:sendSyncEntity(_) self.syncs = self.syncs + 1 end
    function it:getFullType() return "Base.WaterBottle" end
    return it
end

local function newPlayer(name, x, y, z)
    return {
        getUsername = function() return name end,
        getX = function() return x end,
        getY = function() return y end,
        getZ = function() return z end,
    }
end

-- ── 測試套件（--mutants 以突變後的原始碼重跑同一套）──────────────────
local function runSuite(srcs, quiet)
    local checks, failures = 0, 0
    local function check(label, cond, detail)
        checks = checks + 1
        if cond then
            if not quiet then realPrint("  PASS  " .. label) end
        else
            failures = failures + 1
            if not quiet then realPrint("  FAIL  " .. label .. (detail and ("  — " .. tostring(detail)) or "")) end
        end
    end
    local function section(title)
        if not quiet then realPrint(title) end
    end

    local function resetEnv(asServer)
        S.reset({ server = asServer })
        MDFX_Guard = nil
        assert(load(srcs.guard, "=MDFX_Guard.lua"))()
        newEngine()
        V = { animEvent = 0, complete = 0 }
        ISGiveWaterToAnimal = {
            new = vanilla.new,
            getDuration = vanilla.getDuration,
            serverStart = vanilla.serverStart,
            animEvent = vanilla.animEvent,
            complete = vanilla.complete,
            someOtherMember = "keep",
        }
    end
    local function loadFix()
        assert(load(srcs.fix, "=MDFX_GiveWaterAnimalGuard.lua"))()
    end
    local function diagCount()
        return S.printCount("MDFX_GiveWaterAnimalGuard nilAnimal n=")
    end

    -- 一次完整的正常餵水，逐事件記下口渴／水量／XP
    local function waterRun(withFix, thirst, ml)
        resetEnv(true)
        if withFix then loadFix() end
        local animal, item = newAnimal(thirst, 7), newItem(ml)
        E.sample = function()
            return string.format("%d:%.4f/%d/%d", E.now, animal.stats.thirst, item.fc.ml, E.xp)
        end
        request(newPlayer("tester", 10.7, 20.2, 0), animal, item)
        runFor(60000)
        local cmd = E.commands[1]
        return {
            trace = table.concat(E.trace, " "),
            events = V.animEvent, completes = V.complete,
            thirst = animal.stats.thirst, ml = item.fc.ml, syncs = item.syncs, xp = E.xp,
            verdicts = table.concat(E.verdicts, ","), errors = #E.errors, left = #E.actions + #E.events,
            cmd = cmd and string.format("%s.%s %s=%s %s=%.4f", cmd.module, cmd.command,
                tostring(cmd.args[1]), tostring(cmd.args[2]), tostring(cmd.args[3]), cmd.args[4]) or "none",
            prints = S.printCount("[MinidoracatFixes]"),
        }
    end

    -- 1 ───────────────────────────────────────────────────────────
    section("[1] isServer() 為假時零介入")
    resetEnv(false)
    loadFix()
    S.fireBoot()
    check("1 不包裝 animEvent", ISGiveWaterToAnimal.animEvent == vanilla.animEvent)
    check("1 不包裝 complete", ISGiveWaterToAnimal.complete == vanilla.complete)
    check("1 不留 marker", ISGiveWaterToAnimal.MDFX_giveWaterAnimalGuard == nil)
    check("1 不印任何訊息", #S.prints == 0, table.concat(S.prints, " | "))

    -- 2 ───────────────────────────────────────────────────────────
    section("[2] 正常餵水：喝飽結束")
    local base = waterRun(false, 0.12, 1000)
    local fixed = waterRun(true, 0.12, 1000)
    check("2 原版：3 次事件後喝飽、Done", base.events == 3 and base.thirst == 0 and base.verdicts == "Done",
        base.events .. " " .. base.thirst .. " " .. base.verdicts)
    check("2 逐事件與原版相同（口渴／水量／XP／時間）", fixed.trace == base.trace, fixed.trace .. " vs " .. base.trace)
    check("2 原函式 animEvent 3 次、complete 1 次", fixed.events == 3 and fixed.completes == 1)
    check("2 口渴降到 0", fixed.thirst == 0)
    check("2 水量扣 3 × 50 ml、每次都同步物品", fixed.ml == 850 and fixed.syncs == 3)
    check("2 XP 加 3 × 2", fixed.xp == 6)
    check("2 以 Done 結束並通知 client", fixed.verdicts == "Done")
    check("2 complete 送出 setThirst（動物 id 與最終口渴）", fixed.cmd == base.cmd and fixed.cmd == "animal.setThirst id=7 value=0.0000", fixed.cmd)
    check("2 零例外、動作與模擬事件都清空", fixed.errors == 0 and fixed.left == 0)
    check("2 不印診斷", fixed.prints == 0)

    -- 3 ───────────────────────────────────────────────────────────
    section("[3] 正常餵水：水用完結束")
    base = waterRun(false, 0.9, 150)
    fixed = waterRun(true, 0.9, 150)
    check("3 原版：3 次事件後水用完、Done", base.events == 3 and base.ml == 0 and base.verdicts == "Done")
    check("3 逐事件與原版相同", fixed.trace == base.trace, fixed.trace .. " vs " .. base.trace)
    check("3 水量歸零", fixed.ml == 0)
    check("3 口渴下降 3 × 0.05", math.abs(fixed.thirst - 0.75) < 1e-9, fixed.thirst)
    check("3 XP 加 3 × 2", fixed.xp == 6)
    check("3 以 Done 結束、setThirst 與原版相同", fixed.verdicts == "Done" and fixed.cmd == base.cmd, fixed.cmd)
    check("3 零例外、不印診斷", fixed.errors == 0 and fixed.prints == 0)

    -- 4 ───────────────────────────────────────────────────────────
    section("[4] 動物為 nil：拒絕結束、只記一行")
    resetEnv(true)
    loadFix()
    local item = newItem(1000)
    local na = request(newPlayer("tester", 10.7, 20.2, 0), nil, item)
    check("4 原版照樣建立動作（server 的 getDuration 先回 -1，不碰動物）",
        na ~= nil and na.state == "Accept" and na.duration == -1 and #E.events == 1)
    runFor(60000)
    check("4 零例外", #E.errors == 0, table.concat(E.errors, " | "))
    check("4 模擬事件只觸發一次", E.fired == 1, E.fired)
    check("4 原版 animEvent／complete 都沒被呼叫", V.animEvent == 0 and V.complete == 0)
    check("4 forceComplete 恰一次", na and na.forceCompletes == 1)
    check("4 以 Reject 結束並通知 client", table.concat(E.verdicts, ",") == "Reject", table.concat(E.verdicts, ","))
    check("4 在第一個模擬事件那一幀（0.4 秒）就結束", E.verdictAt[1] == 400, E.verdictAt[1])
    check("4 perform 沒失敗（complete 回 false 而不是拋錯）", E.performFailed == 0)
    check("4 動作與模擬事件都清空", #E.actions == 0 and #E.events == 0)
    check("4 水量、XP 不變，沒送 setThirst", item.fc.ml == 1000 and item.syncs == 0 and E.xp == 0 and #E.commands == 0)
    check("4 診斷恰一行（animEvent 記了，complete 不再記）", diagCount() == 1, diagCount())
    check("4 診斷欄位：編號、玩家、所在格、物品、路徑",
        S.printed('[MinidoracatFixes] MDFX_GiveWaterAnimalGuard nilAnimal n=1 player="tester" x=10 y=20 z=0 item=Base.WaterBottle via=animEvent;'),
        S.prints[1])

    -- 同一動作重複事件（例如 forceComplete 沒生效）也只記一行
    resetEnv(true)
    loadFix()
    local act = ISGiveWaterToAnimal.new(ISGiveWaterToAnimal, newPlayer("tester", 1, 2, 0), nil, newItem(1000))
    act.netAction = newNetAction(act)
    local ok1 = pcall(ISGiveWaterToAnimal.animEvent, act, "update", nil)
    local ok2 = pcall(ISGiveWaterToAnimal.animEvent, act, "update", nil)
    local ok3, ret = pcall(ISGiveWaterToAnimal.complete, act)
    check("4 同一動作兩次事件＋complete 都不拋錯", ok1 and ok2 and ok3)
    check("4 同一動作只記一行", diagCount() == 1, diagCount())
    check("4 complete 回 false（不是 nil）", ret == false)

    -- 5 ───────────────────────────────────────────────────────────
    section("[5] 對照組：原版（不載入修正）")
    resetEnv(true)
    item = newItem(1000)
    na = request(newPlayer("tester", 10.7, 20.2, 0), nil, item)
    runFor(10000)
    check("5 原版每個模擬事件都拋錯（10 秒 25 次）", E.fired == 25 and #E.errors == 25, E.fired .. "/" .. #E.errors)
    check("5 錯誤是 :85 對 nil 動物取值", E.errors[1] ~= nil and E.errors[1]:find("animal", 1, true) ~= nil, E.errors[1])
    check("5 動作一直是 Accept、client 等不到結果", na.state == "Accept" and #E.verdicts == 0)
    runFor(DURATION_MAX)
    check("5 30 分鐘上限前每 400 ms 拋一次（共 4500 次）", E.fired == DURATION_MAX / 400, E.fired)
    check("5 上限到時 complete 再拋一次、perform 失敗走 Reject",
        E.performFailed == 1 and E.verdicts[1] == "Reject" and E.verdictAt[1] == DURATION_MAX and #E.errors == E.fired + 1)
    check("5 原版不印本補丁的診斷", not S.printed("[MinidoracatFixes]"))

    -- 6 ───────────────────────────────────────────────────────────
    section("[6] netAction 為 nil（模擬事件不會觸發，走到 30 分鐘上限）")
    resetEnv(true)
    loadFix()
    na = request(newPlayer("tester", 10.7, 20.2, 0), nil, newItem(1000), { noNetAction = true })
    runFor(DURATION_MAX + 1000)
    check("6 模擬事件綁不到動作、從未觸發", E.fired == 0)
    check("6 上限到時 complete 回 false 走 Reject、零例外",
        E.verdicts[1] == "Reject" and E.performFailed == 0 and #E.errors == 0, table.concat(E.errors, " | "))
    check("6 由 complete 記一行", diagCount() == 1 and S.printed("via=complete;"), S.prints[1])

    -- 7 ───────────────────────────────────────────────────────────
    section("[7] 每 session 上限")
    resetEnv(true)
    loadFix()
    for _ = 1, 25 do
        request(newPlayer("tester", 10.7, 20.2, 0), nil, newItem(1000))
        runFor(1000)
    end
    local rejects = 0
    for _, v in ipairs(E.verdicts) do
        if v == "Reject" then rejects = rejects + 1 end
    end
    check("7 25 個動作全部 Reject、零例外", rejects == 25 and #E.errors == 0)
    check("7 只記前 20 行", diagCount() == 20, diagCount())
    check("7 第 20 行編號正確", S.printed("nilAnimal n=20 "))
    check("7 上限提示恰一次", S.printCount("MDFX_GiveWaterAnimalGuard nilAnimal limit=20 reached") == 1)

    -- 8 ───────────────────────────────────────────────────────────
    section("[8] 不吞不認識的錯誤")
    local function nilItemRun(withFix)
        resetEnv(true)
        if withFix then loadFix() end
        local animal = newAnimal(0.5, 7)
        request(newPlayer("tester", 10.7, 20.2, 0), animal, nil)
        runFor(2000)
        return #E.errors, E.fired, animal.stats.thirst, S.printCount("[MinidoracatFixes]"), E.errors[1]
    end
    local e0, f0, t0 = nilItemRun(false)
    local e1, f1, t1, p1, err1 = nilItemRun(true)
    check("8 self.item 為 nil：照原版每次事件在 :86 拋錯（不遮蔽）", e1 == f1 and e1 == e0 and f1 == f0 and e1 == 5,
        e1 .. "/" .. f1 .. " vs " .. e0 .. "/" .. f0)
    check("8 self.item 為 nil：錯誤指向物品、口渴照原版變化", err1 ~= nil and err1:find("item", 1, true) ~= nil and t1 == t0, err1)
    check("8 self.item 為 nil：不印本補丁的診斷", p1 == 0)

    resetEnv(true)
    loadFix()
    act = ISGiveWaterToAnimal.new(ISGiveWaterToAnimal, newPlayer("tester", 1, 2, 0), nil, newItem(1000))
    act.netAction = newNetAction(act)
    local ok = pcall(ISGiveWaterToAnimal.animEvent, act, "someFutureEvent", "x")
    check("8 動物為 nil 時非 update 事件照常交給原函式",
        ok and V.animEvent == 1 and act.netAction.forceCompletes == 0 and diagCount() == 0)

    resetEnv(true)
    ISGiveWaterToAnimal.animEvent = function() error("some future vanilla problem") end
    ISGiveWaterToAnimal.complete = function() error("another vanilla problem") end
    loadFix()
    act = ISGiveWaterToAnimal.new(ISGiveWaterToAnimal, newPlayer("tester", 1, 2, 0), newAnimal(0.5), newItem(1000))
    act.netAction = newNetAction(act)
    local okA, errA = pcall(ISGiveWaterToAnimal.animEvent, act, "update", nil)
    local okC, errC = pcall(ISGiveWaterToAnimal.complete, act)
    check("8 動物存在時原函式自己拋的錯原樣外洩（animEvent）",
        not okA and tostring(errA):find("some future vanilla problem", 1, true) ~= nil)
    check("8 動物存在時原函式自己拋的錯原樣外洩（complete）",
        not okC and tostring(errC):find("another vanilla problem", 1, true) ~= nil)
    check("8 不印診斷", not S.printed("[MinidoracatFixes]"))

    -- 9 ───────────────────────────────────────────────────────────
    section("[9] 重複載入與後載替換")
    resetEnv(true)
    loadFix()
    local wrappedEvent, wrappedComplete = ISGiveWaterToAnimal.animEvent, ISGiveWaterToAnimal.complete
    check("9 安裝後兩個 method 都換成 wrapper", wrappedEvent ~= vanilla.animEvent and wrappedComplete ~= vanilla.complete)
    loadFix()
    check("9 重複載入不再包裝", ISGiveWaterToAnimal.animEvent == wrappedEvent and ISGiveWaterToAnimal.complete == wrappedComplete)
    S.fireBoot()
    check("9 OnGameBoot 復查也不重複包裝",
        ISGiveWaterToAnimal.animEvent == wrappedEvent and ISGiveWaterToAnimal.complete == wrappedComplete)
    local animal = newAnimal(0.12, 7)
    request(newPlayer("tester", 1, 2, 0), animal, newItem(1000))
    runFor(5000)
    check("9 原函式每個事件恰被呼叫一次", V.animEvent == 3 and V.complete == 1)

    local otherEvents = 0
    ISGiveWaterToAnimal.animEvent = function(self, event, parameter) otherEvents = otherEvents + 1 end
    S.fireBoot()
    act = ISGiveWaterToAnimal.new(ISGiveWaterToAnimal, newPlayer("tester", 1, 2, 0), nil, newItem(1000))
    act.netAction = newNetAction(act)
    ok = pcall(ISGiveWaterToAnimal.animEvent, act, "update", nil)
    check("9 後載 MOD 整支替換後，壞形狀仍被擋下", ok and otherEvents == 0 and act.netAction.forceCompletes == 1)
    act = ISGiveWaterToAnimal.new(ISGiveWaterToAnimal, newPlayer("tester", 1, 2, 0), newAnimal(0.5), newItem(1000))
    act.netAction = newNetAction(act)
    ISGiveWaterToAnimal.animEvent(act, "update", nil)
    check("9 正常路徑透傳到後載 MOD 的版本", otherEvents == 1)

    -- 10 ──────────────────────────────────────────────────────────
    section("[10] vanilla 缺席")
    resetEnv(true)
    ISGiveWaterToAnimal = nil
    ok = pcall(loadFix)
    check("10 表不存在時不炸", ok)
    check("10 印一次 NOT installed", S.printCount("giveWaterAnimalGuard NOT installed") == 1)
    check("10 不建立假表", ISGiveWaterToAnimal == nil)

    resetEnv(true)
    ISGiveWaterToAnimal.complete = nil
    ok = pcall(loadFix)
    check("10 部分缺席時不炸、不包裝", ok and ISGiveWaterToAnimal.animEvent == vanilla.animEvent)

    -- 11 ──────────────────────────────────────────────────────────
    section("[11] 成員快照")
    resetEnv(true)
    local before = S.snapshotKeys(ISGiveWaterToAnimal)
    loadFix()
    local extra = S.extraKeys(ISGiveWaterToAnimal, before, "MDFX_giveWaterAnimalGuard")
    check("11 只新增 marker", #extra == 0, table.concat(extra, ","))
    check("11 marker 錨在 animEvent", ISGiveWaterToAnimal.MDFX_giveWaterAnimalGuard == ISGiveWaterToAnimal.animEvent)
    check("11 其他 method 與成員不動", ISGiveWaterToAnimal.serverStart == vanilla.serverStart
        and ISGiveWaterToAnimal.getDuration == vanilla.getDuration and ISGiveWaterToAnimal.new == vanilla.new
        and ISGiveWaterToAnimal.someOtherMember == "keep")

    -- 12 ──────────────────────────────────────────────────────────
    section("[12] 診斷自己不炸")
    resetEnv(true)
    loadFix()
    act = ISGiveWaterToAnimal.new(ISGiveWaterToAnimal, nil, nil, nil)
    act.netAction = newNetAction(act)
    ok = pcall(ISGiveWaterToAnimal.animEvent, act, "update", nil)
    check("12 角色與物品都是 nil 也不炸、照樣結束", ok and act.netAction.forceCompletes == 1)
    check("12 欄位以 ? 與 nil 標示", S.printed("nilAnimal n=1 player=? x=? y=? z=? item=nil via=animEvent;"), S.prints[1])

    -- 13 ──────────────────────────────────────────────────────────
    section("[13] 別的 MOD 把 server 時長改成正數（例如帶 client 算好的 maxTime）")
    local function overrideRun(withFix, ticks)
        resetEnv(true)
        ISGiveWaterToAnimal.getDuration = function(self) return ticks end
        if withFix then loadFix() end
        request(newPlayer("tester", 10.7, 20.2, 0), nil, newItem(1000))
        runFor(10000)
    end
    overrideRun(false, 205)
    check("13 原版：時長（4.1 秒）到之前每 400 ms 拋一次，到時 complete 再拋一次、perform 失敗走 Reject",
        E.fired == 10 and #E.errors == 11 and E.performFailed == 1 and E.verdicts[1] == "Reject" and E.verdictAt[1] == 4100,
        E.fired .. "/" .. #E.errors .. "/" .. tostring(E.verdictAt[1]))
    overrideRun(true, 205)
    check("13 修正：照樣在第一個模擬事件以 Reject 結束、零例外、記一行",
        E.verdictAt[1] == 400 and E.verdicts[1] == "Reject" and #E.errors == 0 and diagCount() == 1)
    overrideRun(true, 5)
    check("13 時長比 0.4 秒短：complete 先到，回 false 走 Reject、由 complete 記一行",
        E.fired == 0 and E.verdictAt[1] == 100 and E.verdicts[1] == "Reject" and #E.errors == 0 and S.printed("via=complete;"))

    return checks, failures
end

-- ── 主程式 ───────────────────────────────────────────────────────
local MUTANTS = {
    { name = "不載入修正", whole = "fix" },
    { name = "animEvent 不判 nil（一律交給原函式）", file = "fix",
        from = 'if self.animal or event ~= "update" then', to = "if true then" },
    { name = "animEvent 攔下所有 event", file = "fix",
        from = 'if self.animal or event ~= "update" then', to = "if self.animal then" },
    { name = "animEvent 不 forceComplete", file = "fix",
        from = "                if self.netAction then self.netAction:forceComplete() end\n", to = "" },
    { name = "animEvent 不記診斷", file = "fix", from = '                record(self, "animEvent")\n', to = "" },
    { name = "complete 不判 nil", file = "fix",
        from = "if self.animal then return originals.complete(self) end", to = "if true then return originals.complete(self) end" },
    { name = "complete 回 true", file = "fix", from = "                return false\n", to = "                return true\n" },
    { name = "每個動作不只記一次", file = "fix", from = "    if self.MDFX_giveWaterNilAnimal then return end\n", to = "" },
    { name = "沒有 session 上限", file = "fix", from = "if logged > LOG_LIMIT then", to = "if false then" },
    { name = "MDFX_Guard 拆掉 isServer() 閘門", file = "guard",
        from = 'if type(isServer) == "function" and isServer() then', to = "if true then" },
    { name = "MDFX_Guard 拆掉冪等 marker", file = "guard", from = "if cls[marker] == cls[anchor] then", to = "if false then" },
    { name = "MDFX_Guard 拆掉診斷節流", file = "guard", from = "if warned[key] then", to = "if false then" },
}

local function mutate(m)
    local srcs = { fix = SOURCES.fix, guard = SOURCES.guard }
    if m.whole then
        srcs[m.whole] = ""
        return srcs
    end
    local src = srcs[m.file]
    local s, e = src:find(m.from, 1, true)
    if not s then return nil, "pattern not found: " .. m.from end
    if src:find(m.from, e + 1, true) then return nil, "pattern not unique: " .. m.from end
    srcs[m.file] = src:sub(1, s - 1) .. m.to .. src:sub(e + 1)
    return srcs
end

if arg and arg[1] == "--mutants" then
    local survived, broken = 0, 0
    for _, m in ipairs(MUTANTS) do
        local srcs, why = mutate(m)
        if not srcs then
            broken = broken + 1
            realPrint("  BROKEN    " .. m.name .. " — " .. why)
        else
            local ok, checks, failures = pcall(runSuite, srcs, true)
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

local checks, failures = runSuite(SOURCES, false)
print = realPrint
realPrint("")
realPrint(string.format("%d checks, %d failed", checks, failures))
os.exit(failures == 0 and 0 or 1)
