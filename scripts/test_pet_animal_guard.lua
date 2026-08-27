-- MDFX_PetAnimalGuard 離線自我檢查
-- 用法（repo 根目錄）： lua scripts/test_pet_animal_guard.lua
--
-- 以最小 stub 模擬 vanilla ISPetAnimal 與 NetTimedAction 生命週期，驗證：
--   * 動物存在時 serverStart / animEvent / complete 全部原樣透傳
--   * 動物為 nil 時：
--       serverStart → 不呼叫原函式、netAction:forceComplete() 恰一次、診斷一次
--       animEvent("pettingFinished") → 靜默略過；其他 event 照常透傳
--       complete → 回 false（ISButcherAnimal:51 的 vanilla 先例；Java 端走
--                  Reject 流程通知 client 移除 action）
--   * netAction 也為 nil 時不炸
--   * 重複載入不疊 wrapper；後載 MOD 整支替換後 OnGameBoot 復查會重新包裝
--   * vanilla 結構缺席時不亂補、不炸
--   * 除了 sentinel 與三個被包函式外，不動 ISPetAnimal 任何既有成員

local MOD_LUA = "MOD/MinidoracatFixesFor42/Contents/mods/MinidoracatFixesFor42/"
    .. "42/media/lua/server/Fixes/MDFX_PetAnimalGuard.lua"

local realPrint = print
local failures = 0
local checks = 0

local function check(label, cond, detail)
    checks = checks + 1
    if cond then
        realPrint(string.format("  PASS  %s", label))
    else
        failures = failures + 1
        realPrint(string.format("  FAIL  %s%s", label, detail and ("  — " .. detail) or ""))
    end
end

-- ── stub 環境 ──────────────────────────────────────────────────
local prints, calls, bootHandlers

local function vanillaServerStart(self)
    calls.serverStart = calls.serverStart + 1
end

local function vanillaAnimEvent(self, event, parameter)
    calls.animEvent[#calls.animEvent + 1] = { event = event, parameter = parameter }
    if event == "pettingFinished" then
        -- 重現 vanilla :88：對 nil 動物解參考
        self.animal:petAnimal(self.character)
    end
end

local function vanillaComplete(self)
    calls.complete = calls.complete + 1
    self.animal:petAnimal(self.character)
    return true
end

local function resetEnv()
    prints, bootHandlers = {}, {}
    calls = { serverStart = 0, animEvent = {}, complete = 0 }
    ISPetAnimal = {
        serverStart = vanillaServerStart,
        animEvent = vanillaAnimEvent,
        complete = vanillaComplete,
        someOtherMember = "keep",
    }
    Events = { OnGameBoot = { Add = function(fn) bootHandlers[#bootHandlers + 1] = fn end } }
    print = function(...)
        local parts = {}
        for i = 1, select("#", ...) do parts[i] = tostring(select(i, ...)) end
        prints[#prints + 1] = table.concat(parts, " ")
    end
end

local function loadFix() dofile(MOD_LUA) end
local function fireBoot() for i = 1, #bootHandlers do bootHandlers[i]() end end

local function printCount(needle)
    local n = 0
    for i = 1, #prints do
        if prints[i]:find(needle, 1, true) then n = n + 1 end
    end
    return n
end
local function printed(needle) return printCount(needle) > 0 end

local function newAction(withAnimal, withNetAction)
    local a = { character = { name = "p" }, forceCompleteCalls = 0 }
    if withAnimal then
        a.animal = { petCalls = 0 }
        a.animal.petAnimal = function(_, chr) a.animal.petCalls = a.animal.petCalls + 1 end
    end
    if withNetAction then
        a.netAction = { forceComplete = function() a.forceCompleteCalls = a.forceCompleteCalls + 1 end }
    end
    return a
end

-- ── 1. 動物存在：全部透傳 ──────────────────────────────────────
realPrint("[1] 動物存在時透傳")
resetEnv()
loadFix()
local act = newAction(true, true)
ISPetAnimal.serverStart(act)
check("1 serverStart 透傳", calls.serverStart == 1)
local ok = pcall(ISPetAnimal.animEvent, act, "pettingFinished", nil)
check("1 animEvent 透傳且動物被撫摸", ok and #calls.animEvent == 1 and act.animal.petCalls == 1)
local ret = ISPetAnimal.complete(act)
check("1 complete 透傳回 true", ret == true and calls.complete == 1)
check("1 不印診斷", not printed("[MinidoracatFixes]"))

-- ── 2. 動物為 nil：serverStart 主閘 ────────────────────────────
realPrint("[2] animal=nil 的 serverStart")
resetEnv()
loadFix()
act = newAction(false, true)
ok = pcall(ISPetAnimal.serverStart, act)
check("2 不拋例外", ok)
check("2 原函式未被呼叫", calls.serverStart == 0)
check("2 forceComplete 恰一次", act.forceCompleteCalls == 1)
check("2 印診斷", printed("[MinidoracatFixes]") and printed("ISPetAnimal"))
pcall(ISPetAnimal.serverStart, newAction(false, true))
check("2 診斷每 session 只印一次", printCount("[MinidoracatFixes]") == 1)

-- ── 3. animal 與 netAction 都 nil：不炸 ────────────────────────
realPrint("[3] netAction 也 nil")
resetEnv()
loadFix()
act = newAction(false, false)
ok = pcall(ISPetAnimal.serverStart, act)
check("3 不拋例外", ok)

-- ── 4. animal=nil 的 animEvent ─────────────────────────────────
realPrint("[4] animal=nil 的 animEvent")
resetEnv()
loadFix()
act = newAction(false, true)
ok = pcall(ISPetAnimal.animEvent, act, "pettingFinished", nil)
check("4 pettingFinished 被靜默略過", ok and #calls.animEvent == 0)
ok = pcall(ISPetAnimal.animEvent, act, "someFutureEvent", "x")
check("4 其他 event 照常透傳", ok and #calls.animEvent == 1
    and calls.animEvent[1].event == "someFutureEvent"
    and calls.animEvent[1].parameter == "x")

-- 對照組：沒裝補丁時 vanilla 對 nil 動物確實會炸
resetEnv()
ok = pcall(vanillaAnimEvent, newAction(false, true), "pettingFinished", nil)
check("4 對照組：vanilla 對 nil 動物確實拋錯", not ok)

-- ── 5. animal=nil 的 complete ──────────────────────────────────
realPrint("[5] animal=nil 的 complete")
resetEnv()
loadFix()
act = newAction(false, true)
ok, ret = pcall(ISPetAnimal.complete, act)
check("5 不拋例外", ok)
check("5 回 false（ISButcherAnimal:51 先例）", ret == false)
check("5 原函式未被呼叫", calls.complete == 0)

-- ── 6. 重複載入／後載 MOD 替換 ─────────────────────────────────
realPrint("[6] 重複載入與後載替換")
resetEnv()
loadFix()
local wrappedStart = ISPetAnimal.serverStart
local wrappedEvent = ISPetAnimal.animEvent
local wrappedComplete = ISPetAnimal.complete
loadFix()
check("6 serverStart 不再包裝", ISPetAnimal.serverStart == wrappedStart)
check("6 animEvent 不再包裝", ISPetAnimal.animEvent == wrappedEvent)
check("6 complete 不再包裝", ISPetAnimal.complete == wrappedComplete)
fireBoot()
check("6 OnGameBoot 復查也不重複包裝", ISPetAnimal.serverStart == wrappedStart)
act = newAction(true, true)
ISPetAnimal.serverStart(act)
check("6 原函式仍恰被呼叫一次", calls.serverStart == 1)

local otherModCalls = 0
ISPetAnimal.serverStart = function(self)
    otherModCalls = otherModCalls + 1
end
fireBoot() -- 復查：把後載 MOD 的版本當新 original 再包一層
ok = pcall(ISPetAnimal.serverStart, newAction(false, true))
check("6 替換後壞形狀仍被擋下", ok and otherModCalls == 0)
ISPetAnimal.serverStart(newAction(true, true))
check("6 替換後正常路徑透傳到後載 MOD 的版本", otherModCalls == 1)

-- ── 7. vanilla 缺席：不亂補、不炸 ──────────────────────────────
realPrint("[7] vanilla 缺席")
resetEnv()
ISPetAnimal = nil
ok = pcall(loadFix)
check("7 表不存在時不炸", ok)
check("7 印未安裝警告", printed("NOT installed"))
check("7 不建立假表", ISPetAnimal == nil)

resetEnv()
ISPetAnimal.complete = nil -- 部分缺席
ok = pcall(loadFix)
check("7 部分缺席時不炸", ok)
check("7 部分缺席時不包裝任何函式", ISPetAnimal.serverStart == vanillaServerStart)

-- ── 8. 不動其他成員 ────────────────────────────────────────────
realPrint("[8] 成員快照")
resetEnv()
local before = {}
for k in pairs(ISPetAnimal) do before[k] = true end
loadFix()
local extra = {}
for k in pairs(ISPetAnimal) do
    if not before[k] and k ~= "MDFX_petAnimalGuard" then
        extra[#extra + 1] = tostring(k)
    end
end
check("8 只新增 sentinel", #extra == 0, table.concat(extra, ","))
check("8 既有成員保留", ISPetAnimal.someOtherMember == "keep")

-- ── 結果 ───────────────────────────────────────────────────────
print = realPrint
realPrint("")
realPrint(string.format("%d checks, %d failed", checks, failures))
os.exit(failures == 0 and 0 or 1)
