-- MDFX_PetAnimalGuard 離線自我檢查
-- 用法（repo 根目錄）： lua scripts/test_pet_animal_guard.lua
--
-- 以最小 stub 模擬 vanilla ISPetAnimal 與 NetTimedAction 生命週期，驗證：
--   * isServer() 為假時完全不安裝（單人／客戶端零介入；那兩端 self.animal 是
--     new() 當下的本地引用，不會是 nil）
--   * 動物存在時 serverStart / animEvent / complete 全部原樣透傳
--   * 動物為 nil 時：
--       serverStart → 不呼叫原函式、netAction:forceComplete() 恰一次、診斷一次
--       animEvent("pettingFinished") → 靜默略過；其他 event 照常透傳
--       complete → 回 false（ISButcherAnimal:51 的 vanilla 先例；Java 端走
--                  Reject 流程通知 client 移除 action）
--   * netAction 也為 nil 時不炸
--   * 重複載入不疊 wrapper；後載 MOD 整支替換後 OnGameBoot 復查會重新包裝
--   * vanilla 結構缺席時不亂補、不炸
--   * 除了 marker 與三個被包函式外，不動 ISPetAnimal 任何既有成員

local S = dofile("scripts/_stub.lua")
local T = S.checker()
local FIX = S.SERVER_FIXES .. "MDFX_PetAnimalGuard.lua"

local calls
local vanillaServerStart, vanillaAnimEvent, vanillaComplete

vanillaServerStart = function(self)
    calls.serverStart = calls.serverStart + 1
end

vanillaAnimEvent = function(self, event, parameter)
    calls.animEvent[#calls.animEvent + 1] = { event = event, parameter = parameter }
    if event == "pettingFinished" then
        -- 重現 vanilla :88：對 nil 動物解參考
        self.animal:petAnimal(self.character)
    end
end

vanillaComplete = function(self)
    calls.complete = calls.complete + 1
    self.animal:petAnimal(self.character)
    return true
end

local function resetEnv(asServer)
    S.reset({ server = asServer })
    calls = { serverStart = 0, animEvent = {}, complete = 0 }
    ISPetAnimal = {
        serverStart = vanillaServerStart,
        animEvent = vanillaAnimEvent,
        complete = vanillaComplete,
        someOtherMember = "keep",
    }
end

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

-- ── 1. client／單人：完全不安裝 ────────────────────────────────
T.section("[1] isServer() 為假時零介入")
resetEnv(false)
S.load(FIX)
T.check("1 不包裝 serverStart", ISPetAnimal.serverStart == vanillaServerStart)
T.check("1 不留 marker", ISPetAnimal.MDFX_petAnimalGuard == nil)

-- ── 2. 動物存在：全部透傳 ──────────────────────────────────────
T.section("[2] 動物存在時透傳")
resetEnv(true)
S.load(FIX)
local act = newAction(true, true)
ISPetAnimal.serverStart(act)
T.check("2 serverStart 透傳", calls.serverStart == 1)
local ok = pcall(ISPetAnimal.animEvent, act, "pettingFinished", nil)
T.check("2 animEvent 透傳且動物被撫摸", ok and #calls.animEvent == 1 and act.animal.petCalls == 1)
local ret = ISPetAnimal.complete(act)
T.check("2 complete 透傳回 true", ret == true and calls.complete == 1)
T.check("2 不印診斷", not S.printed("[MinidoracatFixes]"))

-- ── 3. 動物為 nil：serverStart 主閘 ────────────────────────────
T.section("[3] animal=nil 的 serverStart")
resetEnv(true)
S.load(FIX)
act = newAction(false, true)
ok = pcall(ISPetAnimal.serverStart, act)
T.check("3 不拋例外", ok)
T.check("3 原函式未被呼叫", calls.serverStart == 0)
T.check("3 forceComplete 恰一次", act.forceCompleteCalls == 1)
T.check("3 印診斷", S.printed("[MinidoracatFixes]") and S.printed("ISPetAnimal"))
pcall(ISPetAnimal.serverStart, newAction(false, true))
T.check("3 診斷每 session 只印一次", S.printCount("[MinidoracatFixes]") == 1)

-- ── 4. animal 與 netAction 都 nil：不炸 ────────────────────────
T.section("[4] netAction 也 nil")
resetEnv(true)
S.load(FIX)
ok = pcall(ISPetAnimal.serverStart, newAction(false, false))
T.check("4 不拋例外", ok)

-- ── 5. animal=nil 的 animEvent ─────────────────────────────────
T.section("[5] animal=nil 的 animEvent")
resetEnv(true)
S.load(FIX)
act = newAction(false, true)
ok = pcall(ISPetAnimal.animEvent, act, "pettingFinished", nil)
T.check("5 pettingFinished 被靜默略過", ok and #calls.animEvent == 0)
ok = pcall(ISPetAnimal.animEvent, act, "someFutureEvent", "x")
T.check("5 其他 event 照常透傳", ok and #calls.animEvent == 1
    and calls.animEvent[1].event == "someFutureEvent"
    and calls.animEvent[1].parameter == "x")

resetEnv(true)
ok = pcall(vanillaAnimEvent, newAction(false, true), "pettingFinished", nil)
T.check("5 對照組：vanilla 對 nil 動物確實拋錯", not ok)

-- ── 6. animal=nil 的 complete ──────────────────────────────────
T.section("[6] animal=nil 的 complete")
resetEnv(true)
S.load(FIX)
act = newAction(false, true)
ok, ret = pcall(ISPetAnimal.complete, act)
T.check("6 不拋例外", ok)
T.check("6 回 false（ISButcherAnimal:51 先例）", ret == false)
T.check("6 原函式未被呼叫", calls.complete == 0)

-- ── 7. 重複載入／後載 MOD 替換 ─────────────────────────────────
T.section("[7] 重複載入與後載替換")
resetEnv(true)
S.load(FIX)
local wrappedStart = ISPetAnimal.serverStart
local wrappedEvent = ISPetAnimal.animEvent
local wrappedComplete = ISPetAnimal.complete
S.load(FIX)
T.check("7 serverStart 不再包裝", ISPetAnimal.serverStart == wrappedStart)
T.check("7 animEvent 不再包裝", ISPetAnimal.animEvent == wrappedEvent)
T.check("7 complete 不再包裝", ISPetAnimal.complete == wrappedComplete)
S.fireBoot()
T.check("7 OnGameBoot 復查也不重複包裝", ISPetAnimal.serverStart == wrappedStart)
ISPetAnimal.serverStart(newAction(true, true))
T.check("7 原函式仍恰被呼叫一次", calls.serverStart == 1)

local otherModCalls = 0
ISPetAnimal.serverStart = function(self) otherModCalls = otherModCalls + 1 end
S.fireBoot() -- 復查：把後載 MOD 的版本當新 original 再包一層
ok = pcall(ISPetAnimal.serverStart, newAction(false, true))
T.check("7 替換後壞形狀仍被擋下", ok and otherModCalls == 0)
ISPetAnimal.serverStart(newAction(true, true))
T.check("7 替換後正常路徑透傳到後載 MOD 的版本", otherModCalls == 1)

-- ── 8. vanilla 缺席：不亂補、不炸 ──────────────────────────────
T.section("[8] vanilla 缺席")
resetEnv(true)
ISPetAnimal = nil
ok = pcall(S.load, FIX)
T.check("8 表不存在時不炸", ok)
T.check("8 印未安裝警告", S.printed("NOT installed"))
T.check("8 不建立假表", ISPetAnimal == nil)

resetEnv(true)
ISPetAnimal.complete = nil -- 部分缺席
ok = pcall(S.load, FIX)
T.check("8 部分缺席時不炸", ok)
T.check("8 部分缺席時不包裝任何函式", ISPetAnimal.serverStart == vanillaServerStart)

-- ── 9. 不動其他成員 ────────────────────────────────────────────
T.section("[9] 成員快照")
resetEnv(true)
local before = S.snapshotKeys(ISPetAnimal)
S.load(FIX)
local extra = S.extraKeys(ISPetAnimal, before, "MDFX_petAnimalGuard")
T.check("9 只新增 marker", #extra == 0, table.concat(extra, ","))
T.check("9 既有成員保留", ISPetAnimal.someOtherMember == "keep")

T.finish()
