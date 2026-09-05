-- MDFX_LockDoorsGuard 離線自我檢查
-- 用法（repo 根目錄）： lua scripts/test_lock_doors_guard.lua
--
-- 以最小 stub 重現 vanilla ISLockDoors:complete 的乘客門迴圈（:37-51，含 :46
-- 對 VehiclePart 做 .. 的爆點與邊走邊寫的部分更新），驗證：
--   * isServer() 為假時完全不安裝（client／單人零介入）
--   * 所有乘客門都有門時完全透傳（每扇門都上鎖、回傳值原樣、不印診斷）
--   * 有部件沒有門時：原函式不被呼叫、回 false、**一扇門都沒被動**（無部分更新）、
--     診斷恰一次、訊息用 getId()／getScriptName() 而不是對 userdata 做 ..
--   * vehicle 為 nil 時原樣透傳（vanilla :34-36 自己回 false）
--   * 原函式因其他原因拋錯時原樣外洩（不吞不認識的錯誤）
--   * 重複載入不疊 wrapper；後載 MOD 整支替換後 OnGameBoot 復查會重新包裝
--   * vanilla 結構缺席時不亂補、不炸
--   * 除了 marker 與 complete 外，不動 ISLockDoors 任何既有成員
--   * 對照組：stub vanilla 對無門部件確實拋 __concat，且之前的門已經被鎖（部分更新）

local S = dofile("scripts/_stub.lua")
local T = S.checker()
local FIX = S.SERVER_FIXES .. "MDFX_LockDoorsGuard.lua"

local calls
local vanillaComplete

-- vanilla :33-67 的乘客門迴圈（保留邊走邊寫與 :46 的 concat 爆點）
vanillaComplete = function(self)
    calls.complete = calls.complete + 1
    if self.vehicle == nil then
        return false
    end
    for seat = 1, self.vehicle:getMaxPassengers() do
        local part = self.vehicle:getPassengerDoor(seat - 1)
        if part then
            if not part:getDoor() then
                -- vanilla :46：對 VehiclePart 做 .. → __concat not defined
                print('part ' .. part .. ' has no door')
                return
            end
            if not part:getDoor():isLockBroken() then
                part:getDoor():setLocked(self.locked)
            end
            self.vehicle:transmitPartDoor(part)
        end
    end
    return true
end

local function resetEnv(asServer)
    S.reset({ server = asServer })
    calls = { complete = 0 }
    ISLockDoors = {
        complete = vanillaComplete,
        someOtherMember = "keep",
    }
end

-- VehiclePart stub：hasDoor=false 重現「有部件、沒有門」；
-- 對它做 .. 會像 Kahlua 的 userdata 一樣拋錯（Lua 5.4 對無 __concat 的 table 同樣拋）
local function newPart(id, hasDoor)
    local p = { lockedTo = nil, transmits = 0 }
    p.getId = function() return id end
    if hasDoor then
        local door = {}
        door.isLockBroken = function() return false end
        door.setLocked = function(_, v) p.lockedTo = v end
        p.getDoor = function() return door end
    else
        p.getDoor = function() return nil end
    end
    return p
end

-- parts: array of VehiclePart stub or false（該座位沒有門部件）
local function newAction(parts)
    local a = { locked = true }
    if parts then
        a.vehicle = {
            getMaxPassengers = function() return #parts end,
            getPassengerDoor = function(_, seat)
                local p = parts[seat + 1]
                if p == false then return nil end
                return p
            end,
            transmitPartDoor = function(_, part) part.transmits = part.transmits + 1 end,
            getScriptName = function() return "W900" end,
        }
    end
    return a
end

-- ── 1. client／單人：完全不安裝 ────────────────────────────────
T.section("[1] isServer() 為假時零介入")
resetEnv(false)
S.load(FIX)
T.check("1 不包裝 complete", ISLockDoors.complete == vanillaComplete)
T.check("1 不留 marker", ISLockDoors.MDFX_lockDoorsGuard == nil)

-- ── 2. 全部有門：完全透傳 ──────────────────────────────────────
T.section("[2] 每個乘客門都有門 → 透傳")
resetEnv(true)
S.load(FIX)
local p1, p2 = newPart("door1", true), newPart("door2", true)
local act = newAction({ p1, p2 })
local ok, ret = pcall(ISLockDoors.complete, act)
T.check("2 不拋例外", ok)
T.check("2 原函式恰一次", calls.complete == 1)
T.check("2 回傳值原樣", ret == true)
T.check("2 兩扇門都上鎖並同步", p1.lockedTo == true and p2.lockedTo == true
    and p1.transmits == 1 and p2.transmits == 1)
T.check("2 不印診斷", not S.printed("[MinidoracatFixes]"))

resetEnv(true)
S.load(FIX)
p1 = newPart("door1", true)
act = newAction({ false, p1, false })
ok, ret = pcall(ISLockDoors.complete, act)
T.check("2 座位沒有門部件時照樣透傳", ok and ret == true and p1.lockedTo == true)
T.check("2 不印診斷", not S.printed("[MinidoracatFixes]"))

-- ── 3. 有部件沒有門：主閘 ──────────────────────────────────────
T.section("[3] 部件沒有門")
resetEnv(true)
S.load(FIX)
p1 = newPart("door1", true)
local bad = newPart("trunkdoor", false)
p2 = newPart("door2", true)
act = newAction({ p1, bad, p2 })
ok, ret = pcall(ISLockDoors.complete, act)
T.check("3 不拋例外", ok)
T.check("3 回 false（vanilla :47 的中止語意）", ret == false)
T.check("3 原函式未被呼叫", calls.complete == 0)
T.check("3 一扇門都沒被動（無部分更新）",
    p1.lockedTo == nil and p2.lockedTo == nil and p1.transmits == 0 and p2.transmits == 0)
T.check("3 印診斷", S.printed("[MinidoracatFixes]") and S.printed("ISLockDoors"))
T.check("3 診斷帶定位資訊（part id ＋ 車型）", S.printed("trunkdoor@W900"))
pcall(ISLockDoors.complete, newAction({ newPart("x", false) }))
T.check("3 診斷每 session 只印一次", S.printCount("[MinidoracatFixes]") == 1)

-- 對照組：同一形狀直打 stub vanilla → 拋錯，且第一扇門已經被鎖（部分更新）
resetEnv(true)
p1 = newPart("door1", true)
act = newAction({ p1, newPart("trunkdoor", false) })
ok = pcall(vanillaComplete, act)
T.check("3 對照組：vanilla :46 確實拋錯", not ok)
T.check("3 對照組：之前的門已被鎖 → 這就是要防的部分更新", p1.lockedTo == true)

-- ── 4. vehicle 為 nil：原樣透傳 ───────────────────────────────
T.section("[4] vehicle 為 nil")
resetEnv(true)
S.load(FIX)
ok, ret = pcall(ISLockDoors.complete, newAction(nil))
T.check("4 交還 vanilla（vanilla :34-36 自己回 false）", ok and ret == false and calls.complete == 1)
T.check("4 不印診斷", not S.printed("[MinidoracatFixes]"))

-- ── 5. 原函式因其他原因拋錯 → 原樣外洩 ───────────────────────
T.section("[5] 不吞不認識的錯誤")
resetEnv(true)
ISLockDoors.complete = function(self) error("some future vanilla problem") end
S.load(FIX)
local err
ok, err = pcall(ISLockDoors.complete, newAction({ newPart("door1", true) }))
T.check("5 錯誤原樣外洩", not ok and tostring(err):find("some future vanilla problem", 1, true) ~= nil)
T.check("5 不印診斷", not S.printed("[MinidoracatFixes]"))

-- ── 6. 重複載入／後載 MOD 替換 ─────────────────────────────────
T.section("[6] 重複載入與後載替換")
resetEnv(true)
S.load(FIX)
local wrapped = ISLockDoors.complete
S.load(FIX)
T.check("6 不再包裝", ISLockDoors.complete == wrapped)
S.fireBoot()
T.check("6 OnGameBoot 復查也不重複包裝", ISLockDoors.complete == wrapped)
pcall(ISLockDoors.complete, newAction({ newPart("door1", true) }))
T.check("6 原函式仍恰被呼叫一次", calls.complete == 1)

-- 後載 MOD 整支替換（例如 W900 Semi-Truck 的 complete 包裝）
local otherModCalls = 0
ISLockDoors.complete = function(self) otherModCalls = otherModCalls + 1; return true end
S.fireBoot()
ok, ret = pcall(ISLockDoors.complete, newAction({ newPart("x", false) }))
T.check("6 替換後壞形狀仍被擋下", ok and ret == false and otherModCalls == 0)
pcall(ISLockDoors.complete, newAction({ newPart("door1", true) }))
T.check("6 替換後正常路徑透傳到後載 MOD 的版本", otherModCalls == 1)

-- ── 7. vanilla 缺席：不亂補、不炸 ──────────────────────────────
T.section("[7] vanilla 缺席")
resetEnv(true)
ISLockDoors = nil
ok = pcall(S.load, FIX)
T.check("7 表不存在時不炸", ok)
T.check("7 印未安裝警告", S.printed("NOT installed"))
T.check("7 不建立假表", ISLockDoors == nil)

resetEnv(true)
ISLockDoors.complete = nil
ok = pcall(S.load, FIX)
T.check("7 complete 缺席時不炸也不亂補", ok and ISLockDoors.complete == nil)

-- ── 8. 不動其他成員 ────────────────────────────────────────────
T.section("[8] 成員快照")
resetEnv(true)
local before = S.snapshotKeys(ISLockDoors)
S.load(FIX)
local extra = S.extraKeys(ISLockDoors, before, "MDFX_lockDoorsGuard")
T.check("8 只新增 marker", #extra == 0, table.concat(extra, ","))
T.check("8 既有成員保留", ISLockDoors.someOtherMember == "keep")

T.finish()
