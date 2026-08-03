-- MDFX_AnimalTrailerSize 離線自我檢查
-- 用法（repo 根目錄）： lua scripts/test_animal_trailer_size.lua
--
-- 以最小 stub 模擬 PZ 端 API，驗證補欄位邏輯、逐具隔離，
-- 以及「補資料出錯不得讓原本補得到的屍體漏掉」的契約。

local MOD_LUA = "MOD/MinidoracatFixesFor42/Contents/mods/MinidoracatFixesFor42/"
    .. "42/media/lua/client/Fixes/MDFX_AnimalTrailerSize.lua"

-- ── stub：PZ 全域 ───────────────────────────────────────────────
AnimalDefinitions = { animals = {
    cow = { trailerBaseSize = 400 },
    hen = { trailerBaseSize = 30 },
} }

local squares = {}
function getSquare(x, y, z) return squares[x .. "," .. y .. "," .. z] end

-- 原版 doAnimalSubMenu 自己也會走 vehicle:getSquare() 掃同一片區域
-- （ISVehicleMenu.lua:775）。stub 必須照做，否則「壞 vehicle」類測試會變成
-- 假陽性——看起來是本修復擋下了，其實原版根本也活不過那一行。
local vanillaCalls = 0
ISVehicleMenu = {}
function ISVehicleMenu.doAnimalSubMenu(subMenu, playerObj, vehicle)
    vanillaCalls = vanillaCalls + 1
    local _ = vehicle:getSquare()
    return "vanilla-ran"
end

-- ── stub：物件 ─────────────────────────────────────────────────
local function newBody(animalType, animalSize, modData)
    return {
        modData = modData or {},
        isAnimal = function() return animalType ~= nil end,
        getAnimalType = function() return animalType end,
        getAnimalSize = function() return animalSize end,
        getModData = function(self) return self.modData end,
    }
end

local function newSquare(bodies)
    return { getDeadBodys = function()
        return { size = function() return #bodies end,
                 get = function(_, i) return bodies[i + 1] end }
    end }
end

local function newSquareXYZ(x, y, z)
    return { getX = function() return x end,
             getY = function() return y end,
             getZ = function() return z end }
end

-- ── 載入待測檔 ─────────────────────────────────────────────────
local chunk = assert(loadfile(MOD_LUA), "找不到 " .. MOD_LUA .. "（請從 repo 根目錄執行）")
chunk()

-- ── 檢查 ───────────────────────────────────────────────────────
local M = MDFX_AnimalTrailerSize

-- 1. 缺欄位 → 補成 trailerBaseSize * animalSize
local cow = newBody("cow", 1.2)
assert(M.backfill(cow) == true)
assert(math.abs(cow.modData["animalTrailerSize"] - 480) < 1e-6,
    "cow 應為 400 * 1.2 = 480，實際 " .. tostring(cow.modData["animalTrailerSize"]))

-- 2. 已有數值 → 不覆蓋（伺服器同步過來的正確值優先）
local hen = newBody("hen", 1.0, { animalTrailerSize = 12345 })
assert(M.backfill(hen) == false)
assert(hen.modData["animalTrailerSize"] == 12345)

-- 3. 已有值但不是數字（壞資料）→ 覆寫成正確值，否則原版 round() 照樣炸
local corrupt = newBody("hen", 1.0, { animalTrailerSize = "30" })
assert(M.backfill(corrupt) == true)
assert(corrupt.modData["animalTrailerSize"] == 30)

-- 4. 非動物屍體（人類／殭屍）→ 完全不碰
local human = newBody(nil, 1.0)
assert(M.backfill(human) == false)
assert(human.modData["animalTrailerSize"] == nil)

-- 5. 未知（模組）動物 → 補 0。這是本 MOD 的取捨，不是 Java parity：
--    KahluaTableImpl.rawgetFloat 缺鍵時實際回 -1.0，但 -1 當佔用空間無法顯示。
local unknown = newBody("dragon", 3.0)
assert(M.backfill(unknown) == true)
assert(unknown.modData["animalTrailerSize"] == 0)

-- 6. 包一層之後：地面屍體被補到，且原版函式照樣被呼叫並回傳原值
local ground = newBody("hen", 2.0)
squares["10,10,0"] = newSquare({ ground })
local vehicle = { getSquare = function() return newSquareXYZ(16, 16, 0) end }  -- 10 落在 16-6 ～ 16+5
local player = { getPrimaryHandItem = function() return nil end }
assert(ISVehicleMenu.doAnimalSubMenu({}, player, vehicle) == "vanilla-ran")
assert(vanillaCalls == 1)
assert(ground.modData["animalTrailerSize"] == 60, "hen 應為 30 * 2.0 = 60")

-- 7. 逐具隔離：同一格的第一具屍體拋錯，不得害後面那具漏補
--    （整批中斷的話，後面那些屍體仍是 nil，原版還是會崩——等於沒修）
local exploding = { isAnimal = function() error("壞屍體") end }
local survivor = newBody("cow", 1.0)
squares["12,12,0"] = newSquare({ exploding, survivor })
assert(ISVehicleMenu.doAnimalSubMenu({}, player, vehicle) == "vanilla-ran")
assert(vanillaCalls == 2)
assert(survivor.modData["animalTrailerSize"] == 400,
    "第一具拋錯後，同格第二具仍必須補到 400")

-- 8. 手上拿著的屍體也要補（原版 ISVehicleMenu.lua:755 同樣沒防護）
local inHand = newBody("cow", 1.0)
local playerHolding = { getPrimaryHandItem = function()
    return { getDeadBodyObject = function() return inHand end }
end }
ISVehicleMenu.doAnimalSubMenu({}, playerHolding, vehicle)
assert(inHand.modData["animalTrailerSize"] == 400)

-- 9. 重複載入（開發時 reloadLuaFile）不得把 wrapper 一層層疊上去
local before = vanillaCalls
chunk()
local fresh = newBody("hen", 1.0)
squares["13,13,0"] = newSquare({ fresh })
ISVehicleMenu.doAnimalSubMenu({}, player, vehicle)
assert(vanillaCalls == before + 1, "重複載入後原版仍應只被呼叫一次，實際 "
    .. tostring(vanillaCalls - before))
assert(fresh.modData["animalTrailerSize"] == 30, "重複載入後補值仍須生效")

print("MDFX_AnimalTrailerSize: 9 checks OK")
