-- MDFX_WorldObjectCheckWeapon 離線自我檢查
-- 用法（repo 根目錄）： lua scripts/test_world_object_check_weapon.lua
--
-- 驗證：
--   * isServer() 為假時完全不安裝、不建立任何全域（client／單人零介入）
--   * 全域缺席時建表並只填 checkWeapon，印一次 installed 診斷
--   * 全域已存在（別的 MOD 先建了表）時只補 checkWeapon，不動其他成員
--   * checkWeapon 已由別人提供時不覆蓋（官方修好／後載 MOD 自帶）
--   * 補上的實作與 vanilla :896-912 等價：
--       手持物耐久 > 0 → 整段不做事（零行為差異）
--       耐久 <= 0 或空手 → removeFromHands → getBestWeapon → 裝備（雙手武器補副手）
--                          → sendServerCommand('ui','dirtyUI')
--       撈到的最佳武器耐久 0 → 不裝備
--   * 首次被呼叫印一次診斷、之後靜音
--   * 重複載入／OnGameBoot 復查不換函式引用
--   * 對照組：沒有本補丁時三個 vanilla 呼叫點確實拋 checkWeapon of non-table

local S = dofile("scripts/_stub.lua")
local T = S.checker()
local FIX = S.SERVER_FIXES .. "MDFX_WorldObjectCheckWeapon.lua"

local serverCommands

local function resetEnv(asServer)
    S.reset({ server = asServer })
    serverCommands = {}
    ISWorldObjectContextMenu = nil
    sendServerCommand = function(chr, module, command, args)
        serverCommands[#serverCommands + 1] = { chr = chr, module = module, command = command, args = args }
    end
end

local function newItem(condition, twoHand)
    return {
        getCondition = function() return condition end,
        isTwoHandWeapon = function() return twoHand == true end,
    }
end

local function newChar(opts)
    opts = opts or {}
    local chr = {
        removed = {},
        primary = opts.weapon,
        secondary = opts.secondary,
        bestWeapon = opts.bestWeapon,
        setPrimaryCalls = 0,
        setSecondaryCalls = 0,
    }
    chr.getPrimaryHandItem = function() return chr.primary end
    chr.getSecondaryHandItem = function() return chr.secondary end
    chr.removeFromHands = function(_, item) chr.removed[#chr.removed + 1] = item or "<nil>" end
    chr.getDescriptor = function() return "desc" end
    chr.getInventory = function() return { getBestWeapon = function() return chr.bestWeapon end } end
    chr.setPrimaryHandItem = function(_, item)
        chr.setPrimaryCalls = chr.setPrimaryCalls + 1
        chr.primary = item
    end
    chr.setSecondaryHandItem = function(_, item)
        chr.setSecondaryCalls = chr.setSecondaryCalls + 1
        chr.secondary = item
    end
    return chr
end

local function callCheckWeapon(chr)
    return pcall(ISWorldObjectContextMenu.checkWeapon, chr)
end

-- ── 1. client／單人：完全不安裝 ────────────────────────────────
T.section("[1] isServer() 為假時零介入")
resetEnv(false)
S.load(FIX)
T.check("1 不建立全域", ISWorldObjectContextMenu == nil)
T.check("1 不印任何診斷", not S.printed("[MinidoracatFixes]"))
S.fireBoot()
T.check("1 OnGameBoot 復查也不建立", ISWorldObjectContextMenu == nil)

-- ── 2. server：全域缺席時補上 ──────────────────────────────────
T.section("[2] server 上補齊缺席的 checkWeapon")
resetEnv(true)
S.load(FIX)
T.check("2 建立全域表", type(ISWorldObjectContextMenu) == "table")
T.check("2 填入 checkWeapon", type(ISWorldObjectContextMenu.checkWeapon) == "function")
T.check("2 印一次 installed 診斷", S.printCount("installed") == 1)

-- ── 3. 零行為差異：耐久 > 0 整段不做事 ─────────────────────────
T.section("[3] 手持物還有耐久 → 不做事")
resetEnv(true)
S.load(FIX)
local chr = newChar({ weapon = newItem(50), bestWeapon = newItem(90) })
local ok = callCheckWeapon(chr)
T.check("3 不拋例外", ok)
T.check("3 沒有卸手", #chr.removed == 0)
T.check("3 沒有換裝", chr.setPrimaryCalls == 0 and chr.setSecondaryCalls == 0)
T.check("3 沒有送 dirtyUI", #serverCommands == 0)

-- ── 4. 耐久歸零 → 卸手＋換裝＋dirtyUI ─────────────────────────
T.section("[4] 手持物耐久歸零")
resetEnv(true)
S.load(FIX)
local broken, best = newItem(0), newItem(80)
chr = newChar({ weapon = broken, bestWeapon = best })
ok = callCheckWeapon(chr)
T.check("4 不拋例外", ok)
T.check("4 卸掉壞武器", #chr.removed == 1 and chr.removed[1] == broken)
T.check("4 裝備最佳武器", chr.setPrimaryCalls == 1 and chr.primary == best)
T.check("4 單手武器不設副手", chr.setSecondaryCalls == 0)
T.check("4 送出 server dirtyUI", #serverCommands == 1
    and serverCommands[1].module == "ui" and serverCommands[1].command == "dirtyUI")
T.check("4 印一次呼叫診斷", S.printCount("called on the server") == 1)
callCheckWeapon(newChar({ weapon = newItem(0), bestWeapon = newItem(80) }))
T.check("4 診斷每 session 只印一次", S.printCount("called on the server") == 1)

-- ── 5. 空手／雙手武器／壞掉的最佳武器 ─────────────────────────
T.section("[5] 邊界：空手、雙手武器、最佳武器也壞了")
resetEnv(true)
S.load(FIX)
chr = newChar({ bestWeapon = newItem(70, true) })
ok = callCheckWeapon(chr)
T.check("5 空手也走換裝路徑且不炸", ok and chr.setPrimaryCalls == 1)
T.check("5 雙手武器補副手", chr.setSecondaryCalls == 1 and chr.secondary == chr.primary)

resetEnv(true)
S.load(FIX)
chr = newChar({ weapon = newItem(0), bestWeapon = newItem(0) })
ok = callCheckWeapon(chr)
T.check("5 最佳武器耐久 0 → 不裝備", ok and chr.setPrimaryCalls == 0)
T.check("5 仍送 dirtyUI（vanilla :907-908 在 if 內無條件執行）", #serverCommands == 1)

resetEnv(true)
S.load(FIX)
chr = newChar({ weapon = newItem(0) })
ok = callCheckWeapon(chr)
T.check("5 背包撈不到武器 → 不裝備、不炸", ok and chr.setPrimaryCalls == 0)

-- ── 6. 不覆蓋別人的版本 ────────────────────────────────────────
T.section("[6] 已有 checkWeapon 時不介入")
resetEnv(true)
local theirCalls = 0
ISWorldObjectContextMenu = {
    checkWeapon = function() theirCalls = theirCalls + 1 end,
    someOtherMember = "keep",
}
local theirs = ISWorldObjectContextMenu.checkWeapon
S.load(FIX)
T.check("6 不覆蓋既有 checkWeapon", ISWorldObjectContextMenu.checkWeapon == theirs)
T.check("6 不印 installed 診斷", not S.printed("installed"))
ISWorldObjectContextMenu.checkWeapon(nil)
T.check("6 呼叫到的是對方的版本", theirCalls == 1)

resetEnv(true)
ISWorldObjectContextMenu = { fetchVars = {}, someOtherMember = "keep" }
local before = S.snapshotKeys(ISWorldObjectContextMenu)
S.load(FIX)
local extra = S.extraKeys(ISWorldObjectContextMenu, before, "checkWeapon")
T.check("6 只新增 checkWeapon", #extra == 0, table.concat(extra, ","))
T.check("6 既有成員保留", ISWorldObjectContextMenu.someOtherMember == "keep"
    and type(ISWorldObjectContextMenu.fetchVars) == "table")

-- ── 7. 重複載入／OnGameBoot 復查 ───────────────────────────────
T.section("[7] 冪等")
resetEnv(true)
S.load(FIX)
local installed = ISWorldObjectContextMenu.checkWeapon
S.load(FIX)
T.check("7 重複載入不換函式", ISWorldObjectContextMenu.checkWeapon == installed)
S.fireBoot()
T.check("7 OnGameBoot 復查不換函式", ISWorldObjectContextMenu.checkWeapon == installed)
T.check("7 installed 診斷仍只印一次", S.printCount("installed") == 1)

theirCalls = 0
ISWorldObjectContextMenu.checkWeapon = function() theirCalls = theirCalls + 1 end
local replacement = ISWorldObjectContextMenu.checkWeapon
S.fireBoot()
T.check("7 後載 MOD 的版本不被蓋掉", ISWorldObjectContextMenu.checkWeapon == replacement)

-- ── 8. 對照組：沒有本補丁時三個呼叫點確實會炸 ──────────────────
T.section("[8] 對照組")
resetEnv(true)
-- 重現 vanilla ISDestroyStuffAction.lua:312 / ISPickUpGroundCoverItem.lua:35
-- / ISRemoveBush.lua:79 的呼叫形狀
local function vanillaCallSite(character)
    ISWorldObjectContextMenu.checkWeapon(character)
end
ok = pcall(vanillaCallSite, newChar({ weapon = newItem(0) }))
T.check("8 未安裝時呼叫點確實拋錯", not ok)
S.load(FIX)
ok = pcall(vanillaCallSite, newChar({ weapon = newItem(0) }))
T.check("8 安裝後同一呼叫點不再拋錯", ok)

T.finish()
