--[[
MDFX_WindowFaceGuard — 沒有換面資料的北向窗拆下後裝不回北牆窗框（三端）

【缺陷】
vanilla `ISMoveableSpriteProps:canPlaceMoveableInternal`（shared/Moveables/
ISMoveableSpriteProps.lua:1736-1965）判斷窗能不能放時，在 :1941 這樣決定找哪一道牆的窗框：

    local isNorth = (self:hasFaces() and self.facing == "N" or self.facing == "S") or false;

`hasFaces()`（:258-276）要圖塊有 Noffset／Woffset 等換面資料才回 true。這份資料由引擎在讀圖塊定義時
替「同一個 tileset 裡 GroupName＋CustomName 相同」的一組圖互寫，一組超過 4 張就整組不寫
（IsoWorld.java:1316-1338）。Build 42 新增的四個窗 tileset（fixtures_windows_white／_metal／
_church／_wood）整個 tileset 都用同一組名稱（各約 100 張），所以這 396 張窗都沒有換面資料：
北向的那 198 張 `isNorth` 算成 false，原版去找西牆的窗框（:1942），北牆的窗框找不到。
放下去的那一段（`placeMoveableInternal` :2077）與走過去的那一段（`walkToAndEquip` :3081）
都直接照 Facing 判斷，只有 :1941 多看了 `hasFaces()`。

【後果】
這些北向的窗用撬棍拆下來之後，放置游標指回原本的北牆窗框永遠是紅色，裝不回去。
多人遊戲時伺服器完成放置動作會再判一次（`placeMoveable` :2050），所以只修客戶端也放不上。
舊 tileset（fixtures_windows_01，每款兩張一組）有換面資料，不受影響。

【本補丁】
包裝 `ISMoveableSpriteProps.canPlaceMoveableInternal`：

1. 先原樣呼叫原函式；原版說放得上就照原版，任何原本放得上的情況都不變。
2. 原版說放不上、而且這張是 Facing=N 的窗時，照北向再判一次：暫時把這個實例的 facing 改成 "S"
   再呼叫原函式一次，呼叫完立刻改回 "N"。原版在 :1941 自己就把 "S" 當北向，"S" 與 "N" 找的是
   同一道北牆窗框（:1942、:1944）；窗框、已有窗、技能、工具的檢查全部還是原版那一段在做，
   原版以後改這些條件會自動跟進。有換面資料的北向窗原版本來就照北向判，再判一次結果相同。
3. 第二次呼叫拋錯（原版第一次沒有拋）→ 印一次警告、回原版第一次的結果。

【取捨】
- 不複製 Window 那一支的判斷：複製的那幾行在遊戲更新時會和原版走偏。
- 不補圖塊的換面資料：那會改 396 張圖塊的屬性，其他讀這些屬性的 MOD 會跟著變。
  所以這些窗仍然不能像舊窗那樣在北、西之間換面：北向的只能裝到北牆窗框，西向的只能裝到西牆窗框。
- 原版把這些北向的窗放到西牆窗框那格的行為不動（原本放得上的照樣放得上）。

【安裝機制】
sentinel 存 wrapper 自身引用：Core.ResetLua 重載時 vanilla 重建表、本檔重跑重新包裝；後載 MOD
整支替換時 OnGameBoot 復查把「他的版本」當新 original 再包一層。比本補丁更晚的替換不在保證範圍。

【退場條件】
官方替這四個 tileset 補上換面資料，或 :1941 不再看 `hasFaces()`。兩種情況原版在第 1 步就回放得上，
本補丁自動不介入（診斷行不再出現）。
遊戲更新後跑 `python scripts/check_vanilla_alignment.py` 確認 vanilla 形狀是否已變。
]]

local warnedAccepted = false
local warnedRetryFailed = false
local warnedNotInstalled = false

local function install()
    local props = ISMoveableSpriteProps
    if type(props) ~= "table" or type(props.canPlaceMoveableInternal) ~= "function" then
        if not warnedNotInstalled then
            warnedNotInstalled = true
            print("[MinidoracatFixes] MDFX_WindowFaceGuard NOT installed: vanilla ISMoveableSpriteProps shape changed; re-check docs/fixes.md")
        end
        return
    end
    if props.MDFX_windowFaceGuard == props.canPlaceMoveableInternal then
        return
    end

    local original = props.canPlaceMoveableInternal

    local function wrapper(self, character, square, item, forceTypeObject)
        local result = original(self, character, square, item, forceTypeObject)
        if result or self.type ~= "Window" or self.facing ~= "N" then return result end

        self.facing = "S"
        local ok, second = pcall(original, self, character, square, item, forceTypeObject)
        self.facing = "N"

        if ok and second then
            if not warnedAccepted then
                warnedAccepted = true
                print("[MinidoracatFixes] MDFX_WindowFaceGuard: vanilla refused north-facing window " .. tostring(self.spriteName)
                    .. " on its north frame (it looked for a west frame); accepted at " .. square:getX() .. "," .. square:getY()
                    .. "," .. square:getZ() .. ". Further occurrences not logged this session. See docs/fixes.md MDFX_WindowFaceGuard")
            end
            return second
        end
        if not ok and not warnedRetryFailed then
            warnedRetryFailed = true
            print("[MinidoracatFixes] MDFX_WindowFaceGuard: the north-facing re-check threw; keeping the vanilla answer: "
                .. tostring(second) .. " - see docs/fixes.md MDFX_WindowFaceGuard")
        end
        return result
    end

    props.canPlaceMoveableInternal = wrapper
    props.MDFX_windowFaceGuard = wrapper
end

install()
if Events and Events.OnGameBoot then
    Events.OnGameBoot.Add(install)
end
