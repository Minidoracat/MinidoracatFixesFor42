-- MDFX_ReloadSpeedGuard 離線自我檢查
-- 用法（repo 根目錄）： lua scripts/test_reload_speed_guard.lua
--
-- 以最小 stub 模擬 vanilla setReloadSpeed 與角色，驗證：
--   * 原函式成功時完全透傳：不重算、不多寫變數、不印診斷
--   * 原函式拋錯且「手持非 HandWeapon」（已知壞形狀）時 fallback 公式正確：
--       rack=false → 0.8 ＋ 技能×0.10 － 恐慌×0.05
--       rack=true  → 0.8 ＋ 技能×0.04（不扣恐慌）
--       駕駛中再 ×0.8
--   * 原函式因其他原因拋錯（手持 HandWeapon／判斷不了）→ 原樣重拋，不冒充
--   * fallback 自己也炸（getMoodles 缺）→ 整體退 1.0，例外不外洩
--   * 診斷每 session 只印一次
--   * 重複載入不疊 wrapper；後載 MOD 整支替換後 OnGameBoot 復查會重新包裝
--   * vanilla 結構缺席時不亂補、不炸
--   * 除了 sentinel 與被包函式外，不動 ISReloadWeaponAction 任何既有成員

local MOD_LUA = "MOD/MinidoracatFixesFor42/Contents/mods/MinidoracatFixesFor42/"
    .. "42/media/lua/shared/Fixes/MDFX_ReloadSpeedGuard.lua"

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

local function near(a, b) return type(a) == "number" and math.abs(a - b) < 1e-9 end

-- ── stub 環境 ──────────────────────────────────────────────────
Perks = { Reloading = "Reloading" }
MoodleType = { PANIC = "PANIC" }

-- PZ 的 instanceof：以 stub 物件的 __kind 欄位模擬
function instanceof(obj, className)
    return type(obj) == "table" and obj.__kind == className
end

local prints, originalCalls, bootHandlers

-- opts.hand: nil＝空手；"gun"＝HandWeapon；"flashlight"＝非武器物品
local function newCharacter(opts)
    opts = opts or {}
    local c = { vars = {}, setVariableCalls = 0 }
    if opts.hand == "gun" then
        c.primary = { __kind = "HandWeapon" }
    elseif opts.hand then
        c.primary = { __kind = "InventoryItem" }
    end
    c.getPrimaryHandItem = function()
        if opts.getPrimaryThrows then error("primary boom") end
        return c.primary
    end
    c.getPerkLevel = function(_, perk) return opts.perk or 0 end
    if not opts.noMoodles then
        c.getMoodles = function()
            return { getMoodleLevel = function(_, t) return opts.panic or 0 end }
        end
    end
    c.getVehicle = function()
        if not opts.driving then return nil end
        return { getDriver = function() return c end }
    end
    c.setVariable = function(_, key, value)
        if opts.setVariableThrows then error("setVariable boom") end
        c.setVariableCalls = c.setVariableCalls + 1
        c.vars[key] = value
    end
    return c
end

-- 模擬 vanilla setReloadSpeed：character.crashy 時重現 :95 的 call-nil
local function vanillaSetReloadSpeed(character, rack)
    originalCalls[#originalCalls + 1] = { character = character, rack = rack }
    if character.crashy then
        error("Object tried to call nil in setReloadSpeed")
    end
    character:setVariable("ReloadSpeed", 42) -- 哨兵值，代表「vanilla 自己算的結果」
end

local function resetEnv()
    prints, originalCalls, bootHandlers = {}, {}, {}
    ISReloadWeaponAction = { setReloadSpeed = vanillaSetReloadSpeed, someOtherMember = "keep" }
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

-- ── 1. 正常路徑：完全透傳 ──────────────────────────────────────
realPrint("[1] 原函式成功時透傳")
resetEnv()
loadFix()
local c = newCharacter({ hand = "gun", perk = 4 })
ISReloadWeaponAction.setReloadSpeed(c, false)
check("1 原函式恰被呼叫一次", #originalCalls == 1)
check("1 rack 參數透傳", originalCalls[1].rack == false)
check("1 變數是 vanilla 寫的值", c.vars.ReloadSpeed == 42)
check("1 不重複寫變數", c.setVariableCalls == 1)
check("1 不印診斷", not printed("[MinidoracatFixes]"))

-- ── 2. 已知壞形狀：fallback 公式（rack=false） ─────────────────
realPrint("[2] fallback：手持非槍械、裝彈（rack=false）")
resetEnv()
loadFix()
c = newCharacter({ hand = "flashlight", perk = 4, panic = 2 })
c.crashy = true
local ok = pcall(ISReloadWeaponAction.setReloadSpeed, c, false)
check("2 不外洩例外", ok)
check("2 速度=0.8+4*0.10-2*0.05=1.1", near(c.vars.ReloadSpeed, 1.1),
    tostring(c.vars.ReloadSpeed))
check("2 印診斷", printed("[MinidoracatFixes]") and printed("non-firearm"))
c.vars.ReloadSpeed = nil
pcall(ISReloadWeaponAction.setReloadSpeed, c, false)
check("2 第二次仍 fallback 但不再印", near(c.vars.ReloadSpeed, 1.1)
    and printCount("[MinidoracatFixes]") == 1)

-- ── 3. fallback 公式（rack=true：不扣恐慌） ────────────────────
realPrint("[3] fallback：拉槍機（rack=true）")
resetEnv()
loadFix()
c = newCharacter({ hand = "flashlight", perk = 5, panic = 3 })
c.crashy = true
ISReloadWeaponAction.setReloadSpeed(c, true)
check("3 速度=0.8+5*0.04=1.0（恐慌不參與）", near(c.vars.ReloadSpeed, 1.0),
    tostring(c.vars.ReloadSpeed))

-- ── 4. fallback：駕駛中 ×0.8 ───────────────────────────────────
realPrint("[4] fallback：駕駛中")
resetEnv()
loadFix()
c = newCharacter({ hand = "flashlight", perk = 0, panic = 0, driving = true })
c.crashy = true
ISReloadWeaponAction.setReloadSpeed(c, false)
check("4 速度=0.8*0.8=0.64", near(c.vars.ReloadSpeed, 0.64), tostring(c.vars.ReloadSpeed))

-- ── 5. 未知原因拋錯：原樣重拋、不冒充 ──────────────────────────
realPrint("[5] 未知原因 → 重拋")
resetEnv()
loadFix()
c = newCharacter({ hand = "gun", perk = 4 }) -- 手持槍械卻拋 → 不是已知形狀
c.crashy = true
local okUnknown, err = pcall(ISReloadWeaponAction.setReloadSpeed, c, false)
check("5 例外原樣外洩", not okUnknown)
check("5 原始錯誤訊息保留", tostring(err):find("Object tried to call nil", 1, true) ~= nil,
    tostring(err))
check("5 不寫變數（不冒充已知形狀）", c.vars.ReloadSpeed == nil)
check("5 印 unrecognized 警告且含原始錯誤全文（Kahlua error 會洗堆疊，log 保真）",
    printed("unrecognized") and printed("Object tried to call nil"))

resetEnv()
loadFix()
c = newCharacter({ hand = "flashlight", getPrimaryThrows = true })
c.crashy = true
okUnknown = pcall(ISReloadWeaponAction.setReloadSpeed, c, false)
check("5 連辨識都失敗 → 一樣重拋", not okUnknown)

-- 空手：vanilla :90 gate 過不了、原函式本不該拋；若拋了也屬未知 → 重拋
resetEnv()
loadFix()
c = newCharacter({ perk = 1 }) -- 空手
c.crashy = true
okUnknown = pcall(ISReloadWeaponAction.setReloadSpeed, c, false)
check("5 空手拋錯也屬未知 → 重拋", not okUnknown)

-- ── 6. fallback 也炸 → 1.0 ─────────────────────────────────────
realPrint("[6] fallback 也炸時整體退 1.0")
resetEnv()
loadFix()
c = newCharacter({ hand = "flashlight", perk = 2, noMoodles = true })
c.crashy = true
ok = pcall(ISReloadWeaponAction.setReloadSpeed, c, false)
check("6 不外洩例外", ok)
check("6 退 getVariableFloat 的預設 1.0", near(c.vars.ReloadSpeed, 1.0),
    tostring(c.vars.ReloadSpeed))

-- ── 7. setVariable 拋錯不外洩 ──────────────────────────────────
realPrint("[7] setVariable 拋錯")
resetEnv()
loadFix()
c = newCharacter({ hand = "flashlight", perk = 1, setVariableThrows = true })
c.crashy = true
ok = pcall(ISReloadWeaponAction.setReloadSpeed, c, false)
check("7 不外洩例外", ok)

-- ── 8. 重複載入／後載 MOD 替換 ─────────────────────────────────
realPrint("[8] 重複載入與後載替換")
resetEnv()
loadFix()
local wrapped = ISReloadWeaponAction.setReloadSpeed
loadFix()
check("8 第二次載入不再包裝", ISReloadWeaponAction.setReloadSpeed == wrapped)
fireBoot()
check("8 OnGameBoot 復查也不重複包裝", ISReloadWeaponAction.setReloadSpeed == wrapped)

local otherModCalls = 0
ISReloadWeaponAction.setReloadSpeed = function(character, rack)
    otherModCalls = otherModCalls + 1
    -- 模擬後載 MOD 照抄 vanilla 的壞寫法：對 crashy 形狀一樣拋
    if character.crashy then
        error("Object tried to call nil in setReloadSpeed")
    end
    character:setVariable("ReloadSpeed", 77)
end
fireBoot() -- 復查：把後載 MOD 的版本當新 original 再包一層
c = newCharacter({ hand = "gun" })
ISReloadWeaponAction.setReloadSpeed(c, false)
check("8 正常路徑透傳到後載 MOD 的版本", c.vars.ReloadSpeed == 77 and otherModCalls == 1)
c = newCharacter({ hand = "flashlight", perk = 4, panic = 2 })
c.crashy = true
ok = pcall(ISReloadWeaponAction.setReloadSpeed, c, false)
check("8 替換後壞形狀仍被擋下（guard 恢復）", ok and near(c.vars.ReloadSpeed, 1.1),
    tostring(c.vars.ReloadSpeed))

-- ── 9. vanilla 缺席：不亂補、不炸 ──────────────────────────────
realPrint("[9] vanilla 缺席")
resetEnv()
ISReloadWeaponAction = nil
ok = pcall(loadFix)
check("9 表不存在時不炸", ok)
check("9 印未安裝警告", printed("NOT installed"))
check("9 不建立假表", ISReloadWeaponAction == nil)

-- ── 10. 不動其他成員 ───────────────────────────────────────────
realPrint("[10] 成員快照")
resetEnv()
local before = {}
for k in pairs(ISReloadWeaponAction) do before[k] = true end
loadFix()
local extra = {}
for k in pairs(ISReloadWeaponAction) do
    if not before[k] and k ~= "MDFX_reloadSpeedGuard" then
        extra[#extra + 1] = tostring(k)
    end
end
check("10 只新增 sentinel", #extra == 0, table.concat(extra, ","))
check("10 既有成員保留", ISReloadWeaponAction.someOtherMember == "keep")

-- ── 結果 ───────────────────────────────────────────────────────
print = realPrint
realPrint("")
realPrint(string.format("%d checks, %d failed", checks, failures))
os.exit(failures == 0 and 0 or 1)
