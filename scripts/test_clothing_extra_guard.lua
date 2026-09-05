-- MDFX_ClothingExtraGuard 離線自我檢查
-- 用法（repo 根目錄）： lua scripts/test_clothing_extra_guard.lua
--
-- 以最小 stub 重現 vanilla ISClothingExtraAction 的 complete → createItemNew(:67)
-- 對 nil 衣物解參考，驗證：
--   * isServer() 為假時完全不安裝（client／單人零介入）
--   * self.item 存在時完全透傳（原函式恰一次、回傳值原樣、不印診斷）
--   * self.item 為 nil 時：原函式不被呼叫、回 false、診斷恰一次且節流
--   * 不擴大承接 isBroken()：壞掉但非 nil 的衣物照樣透傳
--   * 原函式因其他原因拋錯時原樣外洩（不吞不認識的錯誤）
--   * 重複載入不疊 wrapper；後載 MOD 整支替換後 OnGameBoot 復查會重新包裝
--   * vanilla 結構缺席時不亂補、不炸
--   * 除了 marker 與 complete 外，不動 ISClothingExtraAction 任何既有成員
--   * 對照組：stub vanilla 對 nil 衣物確實拋錯

local S = dofile("scripts/_stub.lua")
local T = S.checker()
local FIX = S.SERVER_FIXES .. "MDFX_ClothingExtraGuard.lua"

local calls
local vanillaComplete

-- vanilla :121-151（:125 → createItemNew:67 的 item:getVisual()）
vanillaComplete = function(self)
    calls.complete = calls.complete + 1
    self.character:removeFromHands(self.item)
    local _ = self.item:getVisual()
    return true
end

local function resetEnv(asServer)
    S.reset({ server = asServer })
    calls = { complete = 0 }
    ISClothingExtraAction = {
        complete = vanillaComplete,
        someOtherMember = "keep",
    }
end

local function newAction(withItem, broken)
    local a = { character = { removeFromHands = function() end } }
    if withItem then
        a.item = {
            getVisual = function() return { tint = 1 } end,
            isBroken = function() return broken == true end,
        }
    end
    return a
end

-- ── 1. client／單人：完全不安裝 ────────────────────────────────
T.section("[1] isServer() 為假時零介入")
resetEnv(false)
S.load(FIX)
T.check("1 不包裝 complete", ISClothingExtraAction.complete == vanillaComplete)
T.check("1 不留 marker", ISClothingExtraAction.MDFX_clothingExtraGuard == nil)

-- ── 2. 衣物存在：完全透傳 ──────────────────────────────────────
T.section("[2] 衣物存在 → 透傳")
resetEnv(true)
S.load(FIX)
local ok, ret = pcall(ISClothingExtraAction.complete, newAction(true))
T.check("2 不拋例外", ok)
T.check("2 原函式恰一次", calls.complete == 1)
T.check("2 回傳值原樣", ret == true)
T.check("2 不印診斷", not S.printed("[MinidoracatFixes]"))

ok, ret = pcall(ISClothingExtraAction.complete, newAction(true, true))
T.check("2 壞衣物照樣透傳（不擴大承接 isBroken）", ok and ret == true and calls.complete == 2)

-- ── 3. 衣物為 nil：主閘 ────────────────────────────────────────
T.section("[3] 衣物為 nil")
resetEnv(true)
S.load(FIX)
ok, ret = pcall(ISClothingExtraAction.complete, newAction(false))
T.check("3 不拋例外", ok)
T.check("3 回 false（比照 isValid:6 的判準與 ISButcherAnimal:51 的先例）", ret == false)
T.check("3 原函式未被呼叫", calls.complete == 0)
T.check("3 印診斷", S.printed("[MinidoracatFixes]") and S.printed("ISClothingExtraAction"))
pcall(ISClothingExtraAction.complete, newAction(false))
T.check("3 診斷每 session 只印一次", S.printCount("[MinidoracatFixes]") == 1)

resetEnv(true)
ok = pcall(vanillaComplete, newAction(false))
T.check("3 對照組：vanilla :67 對 nil 衣物確實拋錯", not ok)

-- ── 4. 原函式因其他原因拋錯 → 原樣外洩 ───────────────────────
T.section("[4] 不吞不認識的錯誤")
resetEnv(true)
ISClothingExtraAction.complete = function(self) error("some future vanilla problem") end
S.load(FIX)
local err
ok, err = pcall(ISClothingExtraAction.complete, newAction(true))
T.check("4 錯誤原樣外洩", not ok and tostring(err):find("some future vanilla problem", 1, true) ~= nil)
T.check("4 不印診斷", not S.printed("[MinidoracatFixes]"))

-- ── 5. 重複載入／後載 MOD 替換 ─────────────────────────────────
T.section("[5] 重複載入與後載替換")
resetEnv(true)
S.load(FIX)
local wrapped = ISClothingExtraAction.complete
S.load(FIX)
T.check("5 不再包裝", ISClothingExtraAction.complete == wrapped)
S.fireBoot()
T.check("5 OnGameBoot 復查也不重複包裝", ISClothingExtraAction.complete == wrapped)
pcall(ISClothingExtraAction.complete, newAction(true))
T.check("5 原函式仍恰被呼叫一次", calls.complete == 1)

-- 後載 MOD 整支替換（例如 Alice's Weapon Sling 的 complete 包裝）
local otherModCalls = 0
ISClothingExtraAction.complete = function(self) otherModCalls = otherModCalls + 1; return true end
S.fireBoot()
ok, ret = pcall(ISClothingExtraAction.complete, newAction(false))
T.check("5 替換後壞形狀仍被擋下", ok and ret == false and otherModCalls == 0)
pcall(ISClothingExtraAction.complete, newAction(true))
T.check("5 替換後正常路徑透傳到後載 MOD 的版本", otherModCalls == 1)

-- ── 6. vanilla 缺席：不亂補、不炸 ──────────────────────────────
T.section("[6] vanilla 缺席")
resetEnv(true)
ISClothingExtraAction = nil
ok = pcall(S.load, FIX)
T.check("6 表不存在時不炸", ok)
T.check("6 印未安裝警告", S.printed("NOT installed"))
T.check("6 不建立假表", ISClothingExtraAction == nil)

resetEnv(true)
ISClothingExtraAction.complete = nil
ok = pcall(S.load, FIX)
T.check("6 complete 缺席時不炸也不亂補", ok and ISClothingExtraAction.complete == nil)

-- ── 7. 不動其他成員 ────────────────────────────────────────────
T.section("[7] 成員快照")
resetEnv(true)
local before = S.snapshotKeys(ISClothingExtraAction)
S.load(FIX)
local extra = S.extraKeys(ISClothingExtraAction, before, "MDFX_clothingExtraGuard")
T.check("7 只新增 marker", #extra == 0, table.concat(extra, ","))
T.check("7 既有成員保留", ISClothingExtraAction.someOtherMember == "keep")

T.finish()
