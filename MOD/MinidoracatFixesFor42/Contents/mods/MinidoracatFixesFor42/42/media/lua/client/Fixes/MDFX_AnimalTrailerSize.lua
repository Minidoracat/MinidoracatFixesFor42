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
      原版 30 種動物全都有 trailerBaseSize。

    只補顯示端資料即可，不需要伺服器配合：屍體真的裝上拖車後，
    BaseVehicle.recalcAnimalSize() 走 IsoAnimal.getAnimalTrailerSize() 重算，不看 modData。
]]

MDFX_AnimalTrailerSize = MDFX_AnimalTrailerSize or {}

-- 原版掃描半徑（ISVehicleMenu.doAnimalSubMenu：載具格 -6 ～ +5）
local SCAN_MIN = -6
local SCAN_MAX = 5

--- 未知（模組）動物的替代尺寸。這是**本 MOD 的取捨**，不是原版行為：
--- Java 的 KahluaTableImpl.rawgetFloat 缺鍵時回 -1.0，拿 -1 當「佔用空間」在
--- BaseVehicle.canAddAnimalInTrailer 裡會變成負佔用（比不限制還寬鬆），
--- 也不可能拿來顯示。0 是最接近該寬鬆語意又不會顯示成負數的值。
local UNKNOWN_SIZE = 0

--- 與 zombie.characters.animals.IsoAnimal#getAnimalTrailerSize 同式。
--- 抽成可注入 defs 是為了離線測試（scripts/test_animal_trailer_size.lua）。
function MDFX_AnimalTrailerSize.computeSize(body, defs)
    defs = defs or (AnimalDefinitions and AnimalDefinitions.animals)
    local def = defs and defs[body:getAnimalType()]
    if not def or not def.trailerBaseSize then return UNKNOWN_SIZE end
    return def.trailerBaseSize * body:getAnimalSize()
end

--- 缺欄位（或欄位不是數字）才補；已有正確數值一律不動，
--- 不覆蓋伺服器同步過來的值。
function MDFX_AnimalTrailerSize.backfill(body, defs)
    if not body or not body:isAnimal() then return false end
    local modData = body:getModData()
    if not modData or type(modData["animalTrailerSize"]) == "number" then return false end
    modData["animalTrailerSize"] = MDFX_AnimalTrailerSize.computeSize(body, defs)
    return true
end

--- 本修復一旦因後續 build 的 API 變動而失效，症狀會原封不動退回原本的 __mul 崩潰，
--- console.txt 必須留得下指向本 MOD 的線索。每 session 只報一次，右鍵不洗版。
local reportedFailure = false
local function report(err)
    if reportedFailure then return end
    reportedFailure = true
    print("[MinidoracatFixes] MDFX_AnimalTrailerSize 補欄位失敗，動物拖車選單可能仍會崩潰: "
        .. tostring(err))
end

--- 逐具隔離：某一具屍體有問題時只跳過它，不能讓整批 12x12 的補值中斷——
--- 否則後面那些本來補得到的屍體仍是 nil，原版照樣崩。
local function safeBackfill(body)
    local ok, err = pcall(MDFX_AnimalTrailerSize.backfill, body)
    if not ok then report(err) end
end

function MDFX_AnimalTrailerSize.backfillNearVehicle(playerObj, vehicle)
    -- 手上拿著的屍體（原版第 755 行同樣沒防護）
    local item = playerObj and playerObj:getPrimaryHandItem()
    if item then
        safeBackfill(item:getDeadBodyObject())
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
                    safeBackfill(bodies:get(i))
                end
            end
        end
    end
end

-- 只包一次：開發時 reloadLuaFile 會重跑本檔，沒有這道 guard 會一層層疊上去。
if not MDFX_AnimalTrailerSize.installed then
    MDFX_AnimalTrailerSize.installed = true
    local vanillaDoAnimalSubMenu = ISVehicleMenu.doAnimalSubMenu

    function ISVehicleMenu.doAnimalSubMenu(subMenu, playerObj, vehicle)
        -- 外層再包一次：連 vehicle:getSquare() 之類的框架呼叫失敗也不能讓
        -- 原版選單少建（原版就是這樣整段炸掉的）。
        local ok, err = pcall(MDFX_AnimalTrailerSize.backfillNearVehicle, playerObj, vehicle)
        if not ok then report(err) end
        return vanillaDoAnimalSubMenu(subMenu, playerObj, vehicle)
    end
end
