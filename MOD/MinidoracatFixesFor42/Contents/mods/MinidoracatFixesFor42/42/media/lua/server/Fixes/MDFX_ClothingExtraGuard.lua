--[[
MDFX_ClothingExtraGuard — 換裝動作在 server 端解析不到衣物時拋錯

【缺陷】
`ISClothingExtraAction:isValid()`（`shared/TimedActions/ISClothingExtraAction.lua:5-9`）
自己就有 nil guard：

    :6  if not self.item or self.item:isBroken() then return false end

但 `complete()`（:121-151）沒有。server 以 `NetTimedAction.parse`
（`NetTimedAction.java:142-171`）用物件 id 重建 action，衣物已被丟棄／換掉／
不在同步範圍時解析結果是 nil；`new()`（:168-175）只做欄位賦值故照樣成功，
`isValid()` 在 server 端的 action 生命週期裡不再被複查，於是：

    :122  self.character:removeFromHands(self.item)   -- nil 參數，Java 端安全
    :123  self.character:removeWornItem(self.item, false)
    :125  local newItem = self:createItem(self.item, self.extra)
                → createItemNew(:66-67)  local visual = item:getVisual()   ← 當場拋

Kahlua 拋 `attempted index: getVisual of non-table: null`（正式服 log 實據，
9 次／3 天）。堆疊上面那層是 Alice's Weapon Sling 的 `complete` 包裝，但**那個
MOD 只是路過**：它的 server 分支是純透傳（`ISClothingExtraAction_AliceWeaponSling.lua:188`
的 `if … isServer() then return nil end`，`:327` 直接呼叫 vanilla），爆點在原版 `:67`。

【後果】
換裝失敗（本來也換不了，衣物都不在了），server 留下髒例外堆疊；
`NetTimedAction.perform`（`NetTimedAction.java:131-139`）的 protectedCallBoolean
吞下例外回 false，action 走 Reject。

【本補丁】
包裝 `ISClothingExtraAction.complete`（只在 `isServer()`）：`self.item` 為 nil
→ 印一次診斷、回 false，不呼叫原函式。判準與回傳值都是抄 vanilla 自己的
寫法——`isValid():6` 就是同一個 nil 判準，回 false 比照 `ISButcherAnimal:complete`
（`ISButcherAnimal.lua:51-53`）對「屍體被別人撿走」的先例。
`complete` 回 false 與現況（例外被 protectedCallBoolean 吞成 false）**結果完全
相同**，差別只在少一份髒堆疊，所以這道守衛沒有任何行為風險。

刻意不承接 `self.item:isBroken()` 那半邊：`isValid` 連壞掉的衣物也擋，但
「壞掉」不是本次登記的爆點形狀（`isBroken()` 對非 nil 物品安全、不會拋），
擴大承接等於在 vanilla 沒炸的地方改行為。

client／單人不安裝（`MDFX_Guard.onServer` 的 `isServer()` 閘門）：那兩端
`self.item` 是 `new()` 當下的本地物件引用，且 `start():24` 還會用 id 重取一次，
這個形狀只存在於 server 端的封包重建。

【不遮蔽不認識的錯誤】
前置判準，不是 pcall 包裝：`self.item` 非 nil 就原樣呼叫原函式，原函式自己
拋的任何錯誤（含 `createItemNew` 內別的 nil）都原樣外洩、堆疊仍指向 vanilla 行號。

【安裝機制】
`shared/Fixes/MDFX_Guard.lua`：`isServer()` 閘門、形狀檢查、marker 冪等、
`OnGameBoot` 復查（後載 MOD 整支替換時把「他的版本」當新 original 再包一層
——Alice's Weapon Sling 就是這種替換）、診斷節流。

【退場條件】
官方在 `complete()` 入口補上與 `isValid():6` 同款的 nil guard。
遊戲更新後跑 `python scripts/check_vanilla_alignment.py` 確認 vanilla 形狀是否已變。
]]

MDFX_Guard.wrap({
    name = "clothingExtraGuard",
    class = "ISClothingExtraAction",
    methods = { "complete" },
    build = function(originals)
        return {
            complete = function(self)
                if self.item then return originals.complete(self) end
                MDFX_Guard.warnOnce("clothingExtraGuard", "ISClothingExtraAction.complete: item resolved to nil (dropped/replaced/out of sync range); returning false instead of crashing at ISClothingExtraAction.lua:67. Further occurrences suppressed this session. See docs/fixes.md MDFX_ClothingExtraGuard")
                return false
            end,
        }
    end,
})
