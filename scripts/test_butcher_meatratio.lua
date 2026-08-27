-- MDFX_ButcherMeatRatio 離線自我檢查
-- 用法（repo 根目錄）： lua scripts/test_butcher_meatratio.lua
--
-- 以最小 stub 模擬 vanilla ButcheringUtil 與壞屍體，驗證：
--   * 正常屍體完全透傳（參數、回傳值、原函式恰被呼叫一次）
--   * 缺 meatRatio／非 number meatRatio／carcass=nil 都被擋下（fail-closed）
--   * 診斷每 session 只印一次（畸形 NetTimedAction 不能拿來洗 log）
--   * meatRatio 為 0 這類合法數值不被誤攔
--   * getModData 拋錯時 fail-open 交還 vanilla（無法判斷就不介入）
--   * 重複載入不疊 wrapper；後載 MOD 整支替換後 OnGameBoot 復查會重新包裝
--   * vanilla 結構缺席時不亂補、不炸
--   * 除了 sentinel 與被包函式外，不動 ButcheringUtil 任何既有成員

local MOD_LUA = "MOD/MinidoracatFixesFor42/Contents/mods/MinidoracatFixesFor42/"
    .. "42/media/lua/server/Fixes/MDFX_ButcherMeatRatio.lua"

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
local prints, originalCalls, bootHandlers

local function newCarcass(modData)
    return {
        getModData = function() return modData end,
        getAnimalSize = function() return 1.0 end,
    }
end

-- 模擬 vanilla butcherAnimalFromGround 的關鍵形狀：
-- 開頭就對 modData["meatRatio"] 做字串串接（缺欄位＝拋錯）
local function vanillaButcher(carcass, player, keepCorpse)
    originalCalls[#originalCalls + 1] = { carcass = carcass, player = player, keepCorpse = keepCorpse }
    local text = "Meat ratio: " .. carcass:getModData()["meatRatio"] .. "\r\n"
    return text
end

local function resetEnv()
    prints, originalCalls, bootHandlers = {}, {}, {}
    ButcheringUtil = { butcherAnimalFromGround = vanillaButcher, someOtherMember = "keep" }
    Events = { OnGameBoot = { Add = function(fn) bootHandlers[#bootHandlers + 1] = fn end } }
    print = function(...)
        local parts = {}
        for i = 1, select("#", ...) do parts[i] = tostring(select(i, ...)) end
        prints[#prints + 1] = table.concat(parts, " ")
    end
end

local function loadFix()
    dofile(MOD_LUA)
end

local function fireBoot()
    for i = 1, #bootHandlers do bootHandlers[i]() end
end

local function printCount(needle)
    local n = 0
    for i = 1, #prints do
        if prints[i]:find(needle, 1, true) then n = n + 1 end
    end
    return n
end

local function printed(needle) return printCount(needle) > 0 end

local player, keep = { name = "p" }, true

-- ── 1. 正常屍體：完全透傳 ──────────────────────────────────────
realPrint("[1] 正常屍體透傳")
resetEnv()
loadFix()
local goodCarcass = newCarcass({ meatRatio = 0.5, AnimalType = "cow" })
local ret = ButcheringUtil.butcherAnimalFromGround(goodCarcass, player, keep)
check("1 原函式恰被呼叫一次", #originalCalls == 1)
check("1 參數原樣透傳", originalCalls[1].carcass == goodCarcass
    and originalCalls[1].player == player and originalCalls[1].keepCorpse == keep)
check("1 回傳值透傳", ret == "Meat ratio: 0.5\r\n")
check("1 不印診斷", not printed("[MinidoracatFixes]"))

-- ── 2. 壞屍體：擋下、診斷一次、不拋 ────────────────────────────
realPrint("[2] 缺 meatRatio 的壞屍體")
resetEnv()
loadFix()
local badCarcass = newCarcass({ AnimalType = "modded_deer", parts = false })
local ok, ret2 = pcall(ButcheringUtil.butcherAnimalFromGround, badCarcass, player, false)
check("2 不拋例外", ok, tostring(ret2))
check("2 回 nil（比照 vanilla 對未知動物的早退）", ret2 == nil)
check("2 原函式未被呼叫", #originalCalls == 0)
check("2 印診斷含 AnimalType", printed("[MinidoracatFixes]") and printed("modded_deer"))
pcall(ButcheringUtil.butcherAnimalFromGround, badCarcass, player, false)
pcall(ButcheringUtil.butcherAnimalFromGround, newCarcass({ AnimalType = "x" }), player, false)
check("2 診斷每 session 只印一次", printCount("[MinidoracatFixes]") == 1)

-- 對照組：沒裝補丁時 vanilla 對同一屍體確實會炸
resetEnv()
local okVanilla = pcall(vanillaButcher, badCarcass, player, false)
check("2 對照組：vanilla 對壞屍體確實拋錯", not okVanilla)

-- ── 3. 值型別判準 ──────────────────────────────────────────────
realPrint("[3] meatRatio 型別判準")
resetEnv()
loadFix()
ButcheringUtil.butcherAnimalFromGround(newCarcass({ meatRatio = 0 }), player, false)
check("3 meatRatio=0 是合法數值，不攔", #originalCalls == 1)
pcall(ButcheringUtil.butcherAnimalFromGround, newCarcass({ meatRatio = "0.5" }), player, false)
check("3 字串值攔下（:279 比較會炸）", #originalCalls == 1)
pcall(ButcheringUtil.butcherAnimalFromGround, newCarcass({ meatRatio = true }), player, false)
check("3 boolean 值攔下（:70 串接會炸）", #originalCalls == 1)

-- ── 4. carcass=nil：fail-closed ────────────────────────────────
realPrint("[4] carcass=nil 擋下")
resetEnv()
loadFix()
ok = pcall(ButcheringUtil.butcherAnimalFromGround, nil, player, false)
check("4 不拋例外", ok)
check("4 原函式未被呼叫（ISGetAnimalBones 沒有 body guard，這裡補上）", #originalCalls == 0)
check("4 診斷標明 carcass=nil", printed("carcass=nil"))

-- ── 5. getModData 拋錯：fail-open ──────────────────────────────
realPrint("[5] getModData 拋錯時 fail-open")
resetEnv()
loadFix()
local hostile = { getModData = function() error("boom") end }
pcall(ButcheringUtil.butcherAnimalFromGround, hostile, player, false)
check("5 原函式仍被呼叫（無法判斷就不介入，堆疊指向 vanilla）", #originalCalls == 1)

-- ── 6. 重複載入不疊 wrapper ────────────────────────────────────
realPrint("[6] 重複載入")
resetEnv()
loadFix()
local wrapped = ButcheringUtil.butcherAnimalFromGround
loadFix()
check("6 第二次載入不再包裝", ButcheringUtil.butcherAnimalFromGround == wrapped)
fireBoot()
check("6 OnGameBoot 復查也不重複包裝", ButcheringUtil.butcherAnimalFromGround == wrapped)
ButcheringUtil.butcherAnimalFromGround(newCarcass({ meatRatio = 1 }), player, false)
check("6 原函式仍恰被呼叫一次", #originalCalls == 1)

-- ── 7. 後載 MOD 整支替換 → OnGameBoot 重新包裝 ────────────────
realPrint("[7] 後載 MOD 替換")
resetEnv()
loadFix()
local otherModCalls = 0
ButcheringUtil.butcherAnimalFromGround = function(carcass, player2, keepCorpse)
    otherModCalls = otherModCalls + 1
    return "other-mod"
end
fireBoot() -- 復查：發現被替換，把「他的版本」當新 original 再包一層
ok = pcall(ButcheringUtil.butcherAnimalFromGround, newCarcass({ AnimalType = "y" }), player, false)
check("7 壞屍體仍被擋下（guard 恢復）", ok and otherModCalls == 0)
ret = ButcheringUtil.butcherAnimalFromGround(newCarcass({ meatRatio = 2 }), player, false)
check("7 正常屍體透傳到後載 MOD 的版本", ret == "other-mod" and otherModCalls == 1)

-- ── 8. vanilla 缺席：不亂補、不炸 ──────────────────────────────
realPrint("[8] vanilla 缺席")
resetEnv()
ButcheringUtil = nil
local okMissing = pcall(loadFix)
check("8 表不存在時不炸", okMissing)
check("8 印未安裝警告", printed("NOT installed"))
check("8 不建立假表", ButcheringUtil == nil)

resetEnv()
ButcheringUtil = { someOtherMember = "keep" }
okMissing = pcall(loadFix)
check("8 函式不存在時不炸", okMissing)
check("8 不新增函式", ButcheringUtil.butcherAnimalFromGround == nil)

-- ── 9. 不動其他成員 ────────────────────────────────────────────
realPrint("[9] 成員快照")
resetEnv()
local before = {}
for k in pairs(ButcheringUtil) do before[k] = true end
loadFix()
local extra = {}
for k in pairs(ButcheringUtil) do
    if not before[k] and k ~= "MDFX_meatRatioGuard" then
        extra[#extra + 1] = tostring(k)
    end
end
check("9 只新增 sentinel", #extra == 0, table.concat(extra, ","))
check("9 既有成員保留", ButcheringUtil.someOtherMember == "keep")

-- ── 結果 ───────────────────────────────────────────────────────
print = realPrint
realPrint("")
realPrint(string.format("%d checks, %d failed", checks, failures))
os.exit(failures == 0 and 0 or 1)
