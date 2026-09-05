-- MDFX_MilkAnimalGuard 離線自我檢查
-- 用法（repo 根目錄）： lua scripts/test_milk_animal_guard.lua
--
-- 以最小 stub 重現 vanilla ISMilkAnimal 的 :41（stress 倒奶）與 :70（可用容器判準）
-- 兩處對 getFluidContainer() 的解參考，驗證：
--   * isServer() 為假時完全不安裝（client／單人零介入）
--   * 桶子正常（有流體容器）時完全透傳：原函式恰一次、擠奶照做、不印診斷
--   * 桶子為 nil 時**不介入**（vanilla :70 的 not self.bucket 自己短路得了）
--   * 桶子存在但沒有流體容器時：原函式不被呼叫（連 stress():41 都不會踩到）、
--     setJobDelta(0.0) 恰一次、netAction:forceComplete() 恰一次、診斷恰一次
--   * netAction 也為 nil 時不炸
--   * 原函式因其他原因拋錯時原樣外洩（不吞不認識的錯誤）
--   * 重複載入不疊 wrapper；後載 MOD 整支替換後 OnGameBoot 復查會重新包裝
--   * vanilla 結構缺席／部分缺席時不亂補、不炸
--   * 除了 marker 與被包函式外，不動 ISMilkAnimal 任何既有成員

local S = dofile("scripts/_stub.lua")
local T = S.checker()
local FIX = S.SERVER_FIXES .. "MDFX_MilkAnimalGuard.lua"

local calls
local vanillaStress, vanillaMilk

-- vanilla :39-49 的倒奶段（壓力觸發時對 getFluidContainer() 無條件解參考）
vanillaStress = function(self)
    calls.stress = calls.stress + 1
    if self.stressed then
        self.bucket:getFluidContainer():removeFluid()
        return true
    end
    return false
end

-- vanilla :56-113 的關鍵路徑（:58 呼叫 stress、:70 的可用容器判準）
vanillaMilk = function(self)
    calls.milk = calls.milk + 1
    if self:stress() then return end
    if not self.bucket or self.bucket:getFluidContainer():isFull() then
        if self.netAction then self.netAction:forceComplete() end
        return
    end
    calls.milked = calls.milked + 1
end

local function resetEnv(asServer)
    S.reset({ server = asServer })
    calls = { milk = 0, stress = 0, milked = 0 }
    ISMilkAnimal = {
        milk = vanillaMilk,
        stress = vanillaStress,
        someOtherMember = "keep",
    }
end

-- bucketKind: "ok" | "nofluid" | "throws" | nil（沒有桶子）
local function newAction(bucketKind, withNetAction, stressed)
    -- action 實例透過 class 表解析 method（PZ 是 ISBaseTimedAction:derive 的
    -- metatable 鏈），所以 vanillaMilk 裡的 self:stress() 才找得到
    local a = setmetatable({ forceCompleteCalls = 0, stressed = stressed == true },
        { __index = ISMilkAnimal })
    if bucketKind then
        local b = { jobDeltaCalls = 0, removeFluidCalls = 0 }
        b.setJobDelta = function(_, v) b.jobDeltaCalls = b.jobDeltaCalls + 1; b.lastDelta = v end
        if bucketKind == "ok" then
            local fc = {}
            fc.isFull = function() return false end
            fc.removeFluid = function() b.removeFluidCalls = b.removeFluidCalls + 1 end
            b.getFluidContainer = function() return fc end
        elseif bucketKind == "nofluid" then
            b.getFluidContainer = function() return nil end
        else
            b.getFluidContainer = function() error("probe blew up") end
        end
        a.bucket = b
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
T.check("1 不包裝 milk", ISMilkAnimal.milk == vanillaMilk)
T.check("1 不留 marker", ISMilkAnimal.MDFX_milkAnimalGuard == nil)
T.check("1 不印診斷", not S.printed("[MinidoracatFixes]"))

-- ── 2. 桶子正常：完全透傳 ──────────────────────────────────────
T.section("[2] 桶子有流體容器 → 透傳")
resetEnv(true)
S.load(FIX)
local act = newAction("ok", true)
local ok = pcall(ISMilkAnimal.milk, act)
T.check("2 不拋例外", ok)
T.check("2 原函式恰一次", calls.milk == 1)
T.check("2 擠奶照做", calls.milked == 1)
T.check("2 不動 jobDelta", act.bucket.jobDeltaCalls == 0)
T.check("2 不 forceComplete", act.forceCompleteCalls == 0)
T.check("2 不印診斷", not S.printed("[MinidoracatFixes]"))

act = newAction("ok", true, true)
ok = pcall(ISMilkAnimal.milk, act)
T.check("2 壓力路徑透傳且倒奶", ok and act.bucket.removeFluidCalls == 1)

-- ── 3. 桶子為 nil：不介入（vanilla 自己擋得了） ────────────────
T.section("[3] 桶子為 nil → 不介入")
resetEnv(true)
S.load(FIX)
act = newAction(nil, true)
ok = pcall(ISMilkAnimal.milk, act)
T.check("3 不拋例外", ok)
T.check("3 原函式仍被呼叫", calls.milk == 1)
T.check("3 走 vanilla 的結束路徑", act.forceCompleteCalls == 1)
T.check("3 不印診斷（不是本補丁的形狀）", not S.printed("[MinidoracatFixes]"))

-- ── 4. 桶子沒有流體容器：主閘 ──────────────────────────────────
T.section("[4] 桶子沒有流體容器")
resetEnv(true)
S.load(FIX)
act = newAction("nofluid", true)
ok = pcall(ISMilkAnimal.milk, act)
T.check("4 不拋例外", ok)
T.check("4 原函式未被呼叫", calls.milk == 0)
T.check("4 stress() 也沒被踩到（:41 同形狀爆點）", calls.stress == 0)
T.check("4 setJobDelta(0.0) 恰一次", act.bucket.jobDeltaCalls == 1 and act.bucket.lastDelta == 0.0)
T.check("4 forceComplete 恰一次", act.forceCompleteCalls == 1)
T.check("4 印診斷", S.printed("[MinidoracatFixes]") and S.printed("ISMilkAnimal"))
pcall(ISMilkAnimal.milk, newAction("nofluid", true))
T.check("4 診斷每 session 只印一次", S.printCount("[MinidoracatFixes]") == 1)

resetEnv(true)
S.load(FIX)
act = newAction("nofluid", true, true)
ok = pcall(ISMilkAnimal.milk, act)
T.check("4 壓力觸發時也擋下（vanilla 會先炸 :41）", ok and calls.stress == 0)

resetEnv(true)
ok = pcall(vanillaMilk, newAction("nofluid", true))
T.check("4 對照組：vanilla :70 對無流體容器桶子確實拋錯", not ok)
ok = pcall(vanillaMilk, newAction("nofluid", true, true))
T.check("4 對照組：vanilla :41 同形狀也拋錯", not ok)

-- ── 5. netAction 也 nil：不炸 ──────────────────────────────────
T.section("[5] netAction 也 nil")
resetEnv(true)
S.load(FIX)
act = newAction("nofluid", false)
ok = pcall(ISMilkAnimal.milk, act)
T.check("5 不拋例外", ok)
T.check("5 仍收尾 jobDelta", act.bucket.jobDeltaCalls == 1)

-- ── 6. 判準本身拋錯 → 原樣外洩（不掩蓋） ──────────────────────
T.section("[6] 判準本身拋錯")
resetEnv(true)
S.load(FIX)
act = newAction("throws", true)
local err
ok, err = pcall(ISMilkAnimal.milk, act)
T.check("6 錯誤原樣外洩", not ok and tostring(err):find("probe blew up", 1, true) ~= nil)
T.check("6 不印診斷（不冒充已知形狀）", not S.printed("[MinidoracatFixes]"))

-- ── 7. 原函式因其他原因拋錯 → 原樣外洩 ───────────────────────
T.section("[7] 不吞不認識的錯誤")
resetEnv(true)
ISMilkAnimal.milk = function(self) error("some future vanilla problem") end
S.load(FIX)
ok, err = pcall(ISMilkAnimal.milk, newAction("ok", true))
T.check("7 錯誤原樣外洩", not ok and tostring(err):find("some future vanilla problem", 1, true) ~= nil)
T.check("7 不印診斷", not S.printed("[MinidoracatFixes]"))

-- ── 8. 重複載入／後載 MOD 替換 ─────────────────────────────────
T.section("[8] 重複載入與後載替換")
resetEnv(true)
S.load(FIX)
local wrapped = ISMilkAnimal.milk
S.load(FIX)
T.check("8 不再包裝", ISMilkAnimal.milk == wrapped)
S.fireBoot()
T.check("8 OnGameBoot 復查也不重複包裝", ISMilkAnimal.milk == wrapped)
pcall(ISMilkAnimal.milk, newAction("ok", true))
T.check("8 原函式仍恰被呼叫一次", calls.milk == 1)

local otherModCalls = 0
ISMilkAnimal.milk = function(self) otherModCalls = otherModCalls + 1 end
S.fireBoot()
ok = pcall(ISMilkAnimal.milk, newAction("nofluid", true))
T.check("8 替換後壞形狀仍被擋下", ok and otherModCalls == 0)
pcall(ISMilkAnimal.milk, newAction("ok", true))
T.check("8 替換後正常路徑透傳到後載 MOD 的版本", otherModCalls == 1)

-- ── 9. vanilla 缺席：不亂補、不炸 ──────────────────────────────
T.section("[9] vanilla 缺席")
resetEnv(true)
ISMilkAnimal = nil
ok = pcall(S.load, FIX)
T.check("9 表不存在時不炸", ok)
T.check("9 印未安裝警告", S.printed("NOT installed"))
T.check("9 不建立假表", ISMilkAnimal == nil)

resetEnv(true)
ISMilkAnimal.stress = nil -- 部分缺席
ok = pcall(S.load, FIX)
T.check("9 部分缺席時不炸", ok)
T.check("9 部分缺席時不包裝", ISMilkAnimal.milk == vanillaMilk)

-- ── 10. 不動其他成員 ───────────────────────────────────────────
T.section("[10] 成員快照")
resetEnv(true)
local before = S.snapshotKeys(ISMilkAnimal)
S.load(FIX)
local extra = S.extraKeys(ISMilkAnimal, before, "MDFX_milkAnimalGuard")
T.check("10 只新增 marker", #extra == 0, table.concat(extra, ","))
T.check("10 既有成員保留", ISMilkAnimal.someOtherMember == "keep")
T.check("10 stress 未被包裝", ISMilkAnimal.stress == vanillaStress)

T.finish()
