-- MDFX_ConsolidateDrainableGuard 離線自我檢查
-- 用法（repo 根目錄）： lua scripts/test_consolidate_drainable_guard.lua
--
-- 以最小 stub 重現 vanilla ISConsolidateDrainable 的 :25/:33/:35（先扣來源、
-- 再填目的物）與 :111（complete 讀來源），驗證：
--   * isServer() 為假時完全不安裝（client／單人零介入）
--   * 兩邊都是 DrainableComboItem 時 update／complete 完全透傳（含扣量、填量、sendItemStats）
--   * 目的物不是 DrainableComboItem 時：**一個位元都不寫**（來源沒被扣）、
--     netAction:forceComplete() 恰一次、診斷恰一次
--   * 來源不是 DrainableComboItem、任一邊為 nil 時同樣擋下
--     （instanceof 對 nil 回 false — LuaManager.java:2948-2951）
--   * complete 對不合法組合回 false 且不呼叫原函式
--   * 原函式因其他原因拋錯時原樣外洩（不吞不認識的錯誤）
--   * 重複載入不疊 wrapper；後載 MOD 整支替換後 OnGameBoot 復查會重新包裝
--   * vanilla 結構缺席／部分缺席時不亂補、不炸
--   * 除了 marker 與兩個被包函式外，不動 ISConsolidateDrainable 任何既有成員
--   * 對照組：vanilla 對不合型別目的物確實拋錯，**而且來源已經被扣**（部分更新）

local S = dofile("scripts/_stub.lua")
local T = S.checker()
local FIX = S.SERVER_FIXES .. "MDFX_ConsolidateDrainableGuard.lua"

local calls
local vanillaUpdate, vanillaComplete

-- vanilla :13-40 的 server 寫入段
vanillaUpdate = function(self)
    calls.update = calls.update + 1
    if self.drainable:getCurrentUsesFloat() <= 0 then
        if self.netAction then self.netAction:forceComplete() end
    end
    self.drainable:setUsedDelta(self.fromTarget)
    self.intoItem:setUsedDelta(self.intoTarget)
    calls.sendItemStats = calls.sendItemStats + 2
end

-- vanilla :110-116
vanillaComplete = function(self)
    calls.complete = calls.complete + 1
    if self.drainable:getCurrentUsesFloat() <= 0.0001 then
        self.drainable = nil
    end
    return true
end

local function resetEnv(asServer)
    S.reset({ server = asServer })
    calls = { update = 0, complete = 0, sendItemStats = 0 }
    ISConsolidateDrainable = {
        update = vanillaUpdate,
        complete = vanillaComplete,
        someOtherMember = "keep",
    }
end

-- kind: "drainable"（DrainableComboItem）| "plain"（基類物品，沒有 setUsedDelta）
local function newItem(kind, uses)
    local it = { _class = (kind == "drainable") and "DrainableComboItem" or "InventoryItem",
                 writes = 0 }
    it.getCurrentUsesFloat = function() return uses or 0.5 end
    if kind == "drainable" then
        it.setUsedDelta = function(_, v) it.writes = it.writes + 1; it.lastDelta = v end
    end
    return it
end

local function newAction(drainableKind, intoKind)
    local a = { forceCompleteCalls = 0, fromTarget = 0.2, intoTarget = 0.8 }
    a.netAction = { forceComplete = function() a.forceCompleteCalls = a.forceCompleteCalls + 1 end }
    if drainableKind then a.drainable = newItem(drainableKind) end
    if intoKind then a.intoItem = newItem(intoKind) end
    return a
end

-- ── 1. client／單人：完全不安裝 ────────────────────────────────
T.section("[1] isServer() 為假時零介入")
resetEnv(false)
S.load(FIX)
T.check("1 不包裝 update", ISConsolidateDrainable.update == vanillaUpdate)
T.check("1 不包裝 complete", ISConsolidateDrainable.complete == vanillaComplete)
T.check("1 不留 marker", ISConsolidateDrainable.MDFX_consolidateDrainableGuard == nil)

-- ── 2. 兩邊合法：完全透傳 ──────────────────────────────────────
T.section("[2] 兩邊都是 DrainableComboItem → 透傳")
resetEnv(true)
S.load(FIX)
local act = newAction("drainable", "drainable")
local ok = pcall(ISConsolidateDrainable.update, act)
T.check("2 update 不拋例外", ok)
T.check("2 原 update 恰一次", calls.update == 1)
T.check("2 來源扣量", act.drainable.writes == 1 and act.drainable.lastDelta == 0.2)
T.check("2 目的物填量", act.intoItem.writes == 1 and act.intoItem.lastDelta == 0.8)
T.check("2 sendItemStats 兩邊都送", calls.sendItemStats == 2)
local ret
ok, ret = pcall(ISConsolidateDrainable.complete, act)
T.check("2 complete 透傳回 true", ok and ret == true and calls.complete == 1)
T.check("2 不印診斷", not S.printed("[MinidoracatFixes]"))

-- ── 3. 目的物不合型別：主閘，零寫入 ───────────────────────────
T.section("[3] 目的物不是 DrainableComboItem")
resetEnv(true)
S.load(FIX)
act = newAction("drainable", "plain")
ok = pcall(ISConsolidateDrainable.update, act)
T.check("3 不拋例外", ok)
T.check("3 原函式未被呼叫", calls.update == 0)
T.check("3 來源一個位元都沒被扣（無部分更新）", act.drainable.writes == 0)
T.check("3 forceComplete 恰一次", act.forceCompleteCalls == 1)
T.check("3 印診斷", S.printed("[MinidoracatFixes]") and S.printed("ISConsolidateDrainable"))
pcall(ISConsolidateDrainable.update, newAction("drainable", "plain"))
T.check("3 診斷每 session 只印一次", S.printCount("[MinidoracatFixes]") == 1)

-- 對照組：同一形狀直打 stub vanilla → 拋錯，而且來源已經被扣（部分更新）
resetEnv(true)
act = newAction("drainable", "plain")
ok = pcall(vanillaUpdate, act)
T.check("3 對照組：vanilla 確實拋錯", not ok)
T.check("3 對照組：來源已被扣 → 這就是要防的部分更新", act.drainable.writes == 1)

-- ── 4. 來源不合型別／任一邊 nil：一樣擋下 ─────────────────────
T.section("[4] 其他不合法組合")
resetEnv(true)
S.load(FIX)
act = newAction("plain", "drainable")
ok = pcall(ISConsolidateDrainable.update, act)
T.check("4 來源不合型別擋下", ok and calls.update == 0 and act.forceCompleteCalls == 1)

resetEnv(true)
S.load(FIX)
act = newAction(nil, "drainable")
ok = pcall(ISConsolidateDrainable.update, act)
T.check("4 來源為 nil 擋下（instanceof 對 nil 回 false）", ok and calls.update == 0)

resetEnv(true)
S.load(FIX)
act = newAction("drainable", nil)
ok = pcall(ISConsolidateDrainable.update, act)
T.check("4 目的物為 nil 擋下", ok and calls.update == 0)

-- ── 5. complete 的不合法組合 ──────────────────────────────────
T.section("[5] complete")
resetEnv(true)
S.load(FIX)
act = newAction("drainable", "plain")
ok, ret = pcall(ISConsolidateDrainable.complete, act)
T.check("5 不拋例外", ok)
T.check("5 回 false（ISButcherAnimal:51 先例）", ret == false)
T.check("5 原函式未被呼叫", calls.complete == 0)

resetEnv(true)
S.load(FIX)
act = newAction(nil, "drainable")
ok, ret = pcall(ISConsolidateDrainable.complete, act)
T.check("5 來源為 nil 也回 false（vanilla :111 會炸）", ok and ret == false)
resetEnv(true)
ok = pcall(vanillaComplete, newAction(nil, "drainable"))
T.check("5 對照組：vanilla :111 對 nil 來源確實拋錯", not ok)

-- ── 6. 原函式因其他原因拋錯 → 原樣外洩 ───────────────────────
T.section("[6] 不吞不認識的錯誤")
resetEnv(true)
ISConsolidateDrainable.update = function(self) error("some future vanilla problem") end
S.load(FIX)
local err
ok, err = pcall(ISConsolidateDrainable.update, newAction("drainable", "drainable"))
T.check("6 錯誤原樣外洩", not ok and tostring(err):find("some future vanilla problem", 1, true) ~= nil)
T.check("6 不印診斷", not S.printed("[MinidoracatFixes]"))

-- ── 7. 重複載入／後載 MOD 替換 ─────────────────────────────────
T.section("[7] 重複載入與後載替換")
resetEnv(true)
S.load(FIX)
local wrappedUpdate = ISConsolidateDrainable.update
local wrappedComplete = ISConsolidateDrainable.complete
S.load(FIX)
T.check("7 update 不再包裝", ISConsolidateDrainable.update == wrappedUpdate)
T.check("7 complete 不再包裝", ISConsolidateDrainable.complete == wrappedComplete)
S.fireBoot()
T.check("7 OnGameBoot 復查也不重複包裝", ISConsolidateDrainable.update == wrappedUpdate)
pcall(ISConsolidateDrainable.update, newAction("drainable", "drainable"))
T.check("7 原函式仍恰被呼叫一次", calls.update == 1)

local otherModCalls = 0
ISConsolidateDrainable.update = function(self) otherModCalls = otherModCalls + 1 end
S.fireBoot()
ok = pcall(ISConsolidateDrainable.update, newAction("drainable", "plain"))
T.check("7 替換後壞形狀仍被擋下", ok and otherModCalls == 0)
pcall(ISConsolidateDrainable.update, newAction("drainable", "drainable"))
T.check("7 替換後正常路徑透傳到後載 MOD 的版本", otherModCalls == 1)

-- ── 8. vanilla 缺席：不亂補、不炸 ──────────────────────────────
T.section("[8] vanilla 缺席")
resetEnv(true)
ISConsolidateDrainable = nil
ok = pcall(S.load, FIX)
T.check("8 表不存在時不炸", ok)
T.check("8 印未安裝警告", S.printed("NOT installed"))
T.check("8 不建立假表", ISConsolidateDrainable == nil)

resetEnv(true)
ISConsolidateDrainable.complete = nil -- 部分缺席
ok = pcall(S.load, FIX)
T.check("8 部分缺席時不炸", ok)
T.check("8 部分缺席時不包裝", ISConsolidateDrainable.update == vanillaUpdate)

-- ── 9. 不動其他成員 ────────────────────────────────────────────
T.section("[9] 成員快照")
resetEnv(true)
local before = S.snapshotKeys(ISConsolidateDrainable)
S.load(FIX)
local extra = S.extraKeys(ISConsolidateDrainable, before, "MDFX_consolidateDrainableGuard")
T.check("9 只新增 marker", #extra == 0, table.concat(extra, ","))
T.check("9 既有成員保留", ISConsolidateDrainable.someOtherMember == "keep")

T.finish()
