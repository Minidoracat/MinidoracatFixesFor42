--[[
    MDFX_AnimalTrailerSize —— 動物屍體 animalTrailerSize 欄位缺失修復

    症狀
      拖車的動物門開著時右鍵載具、或按拖車動物 UI 的「加入動物」鈕，
      整段車輛右鍵選單消失、死掉的動物裝不上拖車。console.txt 出現：

        java.lang.RuntimeException: __mul not defined for operands in round
          Lua(Vanilla).round(luautils.lua:709)
          Lua(Vanilla).doAnimalSubMenu(ISVehicleMenu.lua:806)

    根因
      原版 ISVehicleMenu.doAnimalSubMenu（42.20 第 755 / 806 行）直接把
      body:getModData()["animalTrailerSize"] 丟給 round()，缺欄位時 nil * mult 直接拋例外。
      該欄位全遊戲唯一寫入點是 ButcheringUtil.lua 的 setAnimalBodyData()（第 45 行），
      但那個函式第 19 行才剛判斷 AnimalPartsDefinitions 的 def 可能是 nil，
      第 27 行卻無條件 `if def.feather`——def 為 nil 時就在寫入 animalTrailerSize 之前拋錯。
      Java 端 IsoDeadBody.setAnimalData() 是 protectedCall，錯誤被吞掉後照樣寫入 animalType，
      於是屍體變成「isAnimal() 為 true、但 modData 缺欄位」的永久壞資料；
      早於此欄位存在的舊屍體同理。

      doAnimalSubMenu 位在 OnFillWorldObjectContextMenu 的
      ISVehicleMenu.FillMenuOutsideVehicle 鏈上，一炸就整段車輛選單不見，
      不只是「加不了動物」。

    修法
      呼叫原版函式之前，把掃描範圍內缺欄位的動物屍體補回
      AnimalDefinitions.animals[type].trailerBaseSize * body:getAnimalSize()
      —— 與 Java IsoAnimal.getAnimalTrailerSize() 同式，值精確。
      原版 30 種動物全都有 trailerBaseSize；未知（模組）動物補 0，
      與 Java 端 BaseVehicle.canAddAnimalInTrailer 用 rawgetFloat 缺鍵時的行為一致。

    只補顯示端資料即可，不需要伺服器配合：屍體真的裝上拖車後，
    BaseVehicle.recalcAnimalSize() 走 IsoAnimal.getAnimalTrailerSize() 重算，不看 modData。
]]

MDFX_AnimalTrailerSize = MDFX_AnimalTrailerSize or {}

-- 原版掃描半徑（ISVehicleMenu.doAnimalSubMenu：載具格 -6 ～ +5）
local SCAN_MIN = -6
local SCAN_MAX = 5

--- 與 zombie.characters.animals.IsoAnimal#getAnimalTrailerSize 同式。
--- 抽成可注入 defs 是為了離線測試（scripts/test_animal_trailer_size.lua）。
function MDFX_AnimalTrailerSize.computeSize(body, defs)
    defs = defs or (AnimalDefinitions and AnimalDefinitions.animals)
    local def = defs and defs[body:getAnimalType()]
    local base = def and def.trailerBaseSize or 0
    return base * body:getAnimalSize()
end

--- 缺欄位才補；已有數值一律不動（不覆蓋伺服器同步過來的正確值）。
function MDFX_AnimalTrailerSize.backfill(body, defs)
    if not body or not body:isAnimal() then return false end
    local modData = body:getModData()
    if not modData or type(modData["animalTrailerSize"]) == "number" then return false end
    modData["animalTrailerSize"] = MDFX_AnimalTrailerSize.computeSize(body, defs)
    return true
end

function MDFX_AnimalTrailerSize.backfillNearVehicle(playerObj, vehicle)
    -- 手上拿著的屍體（原版第 755 行同樣沒防護）
    local item = playerObj and playerObj:getPrimaryHandItem()
    if item then
        MDFX_AnimalTrailerSize.backfill(item:getDeadBodyObject())
    end

    local vsq = vehicle and vehicle:getSquare()
    if not vsq then return end
    local vz = vsq:getZ()
    for x = vsq:getX() + SCAN_MIN, vsq:getX() + SCAN_MAX do
        for y = vsq:getY() + SCAN_MIN, vsq:getY() + SCAN_MAX do
            local sq = getSquare(x, y, vz)
            if sq then
                local bodies = sq:getDeadBodys()
                for i = 0, bodies:size() - 1 do
                    MDFX_AnimalTrailerSize.backfill(bodies:get(i))
                end
            end
        end
    end
end

local vanillaDoAnimalSubMenu = ISVehicleMenu.doAnimalSubMenu

function ISVehicleMenu.doAnimalSubMenu(subMenu, playerObj, vehicle)
    -- 補資料若出錯，絕不能連累原版選單——原版就是這樣整段炸掉的
    pcall(MDFX_AnimalTrailerSize.backfillNearVehicle, playerObj, vehicle)
    return vanillaDoAnimalSubMenu(subMenu, playerObj, vehicle)
end
