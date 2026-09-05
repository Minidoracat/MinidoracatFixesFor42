-- MDFX_MoveablesActionGuard 離線自我檢查
-- 用法（repo 根目錄）： lua scripts/test_moveables_action_guard.lua
--
-- 以最小 stub 重現 vanilla ISMoveablesAction:new 的 :307-308（place 模式對
-- item 無條件解參考），驗證：
--   * isServer() 為假時完全不安裝（client／單人零介入）
--   * place 模式且 item 存在 → 完全透傳（八個參數逐一原樣到位、回傳原物件）
--   * pickup／scrap／repair／rotate 模式即使 item 為 nil 也完全透傳（不擴大承接）
--   * place 模式且 item 為 nil → 原函式不被呼叫、回 nil、診斷恰一次且節流
--   * 原函式因其他原因拋錯時原樣外洩（不吞不認識的錯誤）
--   * 重複載入不疊 wrapper；後載 MOD 整支替換後 OnGameBoot 復查會重新包裝
--   * vanilla 結構缺席時不亂補、不炸
--   * 除了 marker 與 new 外，不動 ISMoveablesAction 任何既有成員
--   * 對照組：stub vanilla 對 place + nil item 確實拋錯

local S = dofile("scripts/_stub.lua")
local T = S.checker()
local FIX = S.SERVER_FIXES .. "MDFX_MoveablesActionGuard.lua"

local calls
local vanillaNew

-- vanilla :271-343 的關鍵形狀（只保留 place 分支的解參考）
vanillaNew = function(self, character, square, mode, origSpriteName, object, direction, item, moveCursor)
    calls.new = calls.new + 1
    calls.args = { self = self, character = character, square = square, mode = mode,
                   origSpriteName = origSpriteName, object = object,
                   direction = direction, item = item, moveCursor = moveCursor }
    if mode == "place" then
        local _ = item:getWorldSprite()
    end
    return { built = true, mode = mode }
end

local function resetEnv(asServer)
    S.reset({ server = asServer })
    calls = { new = 0 }
    ISMoveablesAction = {
        new = vanillaNew,
        someOtherMember = "keep",
    }
end

local function newItem()
    return { getWorldSprite = function() return "sprite_name" end }
end

-- ── 1. client／單人：完全不安裝 ────────────────────────────────
T.section("[1] isServer() 為假時零介入")
resetEnv(false)
S.load(FIX)
T.check("1 不包裝 new", ISMoveablesAction.new == vanillaNew)
T.check("1 不留 marker", ISMoveablesAction.MDFX_moveablesActionGuard == nil)

-- ── 2. place ＋物品存在：完全透傳 ──────────────────────────────
T.section("[2] place 模式且物品存在 → 透傳")
resetEnv(true)
S.load(FIX)
local item, cursor = newItem(), { cursorFacing = "N" }
local ok, ret = pcall(ISMoveablesAction.new, ISMoveablesAction, "chr", "sq", "place",
    "origSprite", "obj", 3, item, cursor)
T.check("2 不拋例外", ok)
T.check("2 原函式恰一次", calls.new == 1)
T.check("2 回傳原物件", type(ret) == "table" and ret.built == true and ret.mode == "place")
local a = calls.args
T.check("2 八個參數逐一到位", a.self == ISMoveablesAction and a.character == "chr"
    and a.square == "sq" and a.mode == "place" and a.origSpriteName == "origSprite"
    and a.object == "obj" and a.direction == 3 and a.item == item and a.moveCursor == cursor)
T.check("2 不印診斷", not S.printed("[MinidoracatFixes]"))

-- ── 3. 其他模式即使 item 為 nil 也透傳 ─────────────────────────
T.section("[3] 其他模式不擴大承接")
resetEnv(true)
S.load(FIX)
local modes = { "pickup", "scrap", "repair", "rotate" }
local allPassed = true
for i = 1, #modes do
    local okMode, retMode = pcall(ISMoveablesAction.new, ISMoveablesAction, "chr", "sq",
        modes[i], nil, "obj", 1, nil, nil)
    if not (okMode and type(retMode) == "table" and retMode.mode == modes[i]) then
        allPassed = false
    end
end
T.check("3 pickup／scrap／repair／rotate 全部透傳", allPassed and calls.new == #modes)
T.check("3 不印診斷", not S.printed("[MinidoracatFixes]"))

-- ── 4. place ＋ item 為 nil：主閘 ──────────────────────────────
T.section("[4] place 模式且物品為 nil")
resetEnv(true)
S.load(FIX)
ok, ret = pcall(ISMoveablesAction.new, ISMoveablesAction, "chr", "sq", "place",
    "origSprite", "obj", 3, nil, nil)
T.check("4 不拋例外", ok)
T.check("4 回 nil（NetTimedAction.parse:159-163 的同一分支）", ret == nil)
T.check("4 原函式未被呼叫", calls.new == 0)
T.check("4 印診斷", S.printed("[MinidoracatFixes]") and S.printed("ISMoveablesAction"))
pcall(ISMoveablesAction.new, ISMoveablesAction, "chr", "sq", "place", nil, nil, nil, nil, nil)
T.check("4 診斷每 session 只印一次", S.printCount("[MinidoracatFixes]") == 1)

resetEnv(true)
ok = pcall(vanillaNew, ISMoveablesAction, "chr", "sq", "place", nil, nil, nil, nil, nil)
T.check("4 對照組：vanilla :308 對 nil 物品確實拋錯", not ok)

-- ── 5. 原函式因其他原因拋錯 → 原樣外洩 ───────────────────────
T.section("[5] 不吞不認識的錯誤")
resetEnv(true)
ISMoveablesAction.new = function() error("some future vanilla problem") end
S.load(FIX)
local err
ok, err = pcall(ISMoveablesAction.new, ISMoveablesAction, "chr", "sq", "place",
    nil, nil, nil, newItem(), nil)
T.check("5 錯誤原樣外洩", not ok and tostring(err):find("some future vanilla problem", 1, true) ~= nil)
T.check("5 不印診斷", not S.printed("[MinidoracatFixes]"))

-- ── 6. 重複載入／後載 MOD 替換 ─────────────────────────────────
T.section("[6] 重複載入與後載替換")
resetEnv(true)
S.load(FIX)
local wrapped = ISMoveablesAction.new
S.load(FIX)
T.check("6 不再包裝", ISMoveablesAction.new == wrapped)
S.fireBoot()
T.check("6 OnGameBoot 復查也不重複包裝", ISMoveablesAction.new == wrapped)
pcall(ISMoveablesAction.new, ISMoveablesAction, "chr", "sq", "place", nil, nil, nil, newItem(), nil)
T.check("6 原函式仍恰被呼叫一次", calls.new == 1)

local otherModCalls = 0
ISMoveablesAction.new = function() otherModCalls = otherModCalls + 1; return { built = true } end
S.fireBoot()
ok, ret = pcall(ISMoveablesAction.new, ISMoveablesAction, "chr", "sq", "place", nil, nil, nil, nil, nil)
T.check("6 替換後壞形狀仍被擋下", ok and ret == nil and otherModCalls == 0)
pcall(ISMoveablesAction.new, ISMoveablesAction, "chr", "sq", "place", nil, nil, nil, newItem(), nil)
T.check("6 替換後正常路徑透傳到後載 MOD 的版本", otherModCalls == 1)

-- ── 7. vanilla 缺席：不亂補、不炸 ──────────────────────────────
T.section("[7] vanilla 缺席")
resetEnv(true)
ISMoveablesAction = nil
ok = pcall(S.load, FIX)
T.check("7 表不存在時不炸", ok)
T.check("7 印未安裝警告", S.printed("NOT installed"))
T.check("7 不建立假表", ISMoveablesAction == nil)

resetEnv(true)
ISMoveablesAction.new = nil
ok = pcall(S.load, FIX)
T.check("7 new 缺席時不炸也不亂補", ok and ISMoveablesAction.new == nil)

-- ── 8. 不動其他成員 ────────────────────────────────────────────
T.section("[8] 成員快照")
resetEnv(true)
local before = S.snapshotKeys(ISMoveablesAction)
S.load(FIX)
local extra = S.extraKeys(ISMoveablesAction, before, "MDFX_moveablesActionGuard")
T.check("8 只新增 marker", #extra == 0, table.concat(extra, ","))
T.check("8 既有成員保留", ISMoveablesAction.someOtherMember == "keep")

T.finish()
