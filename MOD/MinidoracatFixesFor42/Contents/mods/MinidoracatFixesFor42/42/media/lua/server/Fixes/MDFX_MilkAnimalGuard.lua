--[[
MDFX_MilkAnimalGuard — 擠奶的桶子不是流體容器時 server 端拋錯

【缺陷】
`ISMilkAnimal:milk`（`shared/TimedActions/Animals/ISMilkAnimal.lua:56-113`）的
「沒有可用容器」判準只檢查了 `self.bucket` 存不存在，沒檢查它還是不是流體容器：

    :70  if not self.bucket or self.bucket:getFluidContainer():isFull() or self.character:hasFullInventory() then

`getFluidContainer()` 回 nil（桶子已被 MilkReplaceItem 換掉、或 server 以
`NetTimedAction.parse`（`NetTimedAction.java:142-171`）用物件 id 解析到的
根本不是流體容器物品）時，`:isFull()` 對 null 解參考，Kahlua 拋
`attempted index: isFull of non-table: null`（正式服 log 實據，爆發日 50–320 次、
平常 0 次，集中在少數畜牧玩家）。堆疊：

    Lua(Vanilla).milk(ISMilkAnimal.lua:70)
    Lua(Vanilla).animEvent(ISMilkAnimal.lua:203)
    → AnimEventEmulator.update(AnimEventEmulator.java:60)

同一形狀在 `:92`（換桶後的複查）與 `stress()` 的 `:41`
（`self.bucket:getFluidContainer():removeFluid()`，倒掉桶裡的奶）都會炸；
`stress()` 在 `milk()` 開頭 `:58` 就被呼叫，所以動物壓力大於 40 時先炸 `:41`。

【後果】
擠奶的模擬事件在 `emulateAnimEvent` 週期內每次都拋錯，這次擠奶零產出
（`:111 self.animal:milkAnimal(...)` 永遠到不了），動作掛著等 timeout；
玩家看到動畫演完、桶子沒有奶。

【本補丁】
包裝 `ISMilkAnimal.milk`（只在 `isServer()`）：桶子存在但 `getFluidContainer()`
為 nil 時，走 vanilla 自己「沒有可用容器」的結束路徑（`:87-95`）——
`self.bucket:setJobDelta(0.0)`（比照 vanilla :72-74 的收尾，`setJobDelta` 在
`InventoryItem` 基類上，對任何物品安全）後 `netAction:forceComplete()` 並 return。
其餘一律原樣呼叫原函式。

【取捨：為什麼不把 self.bucket 設成 nil 去走原版換桶路】
把欄位清成 nil 確實能讓 `:70` 短路、走進 `:75-90` 的換桶搜尋（搜尋本身安全：
`getFirstAvailableFluidContainer` 回的一定是流體容器）。但 `stress()` 的 `:41`
對 `self.bucket` 是**無條件解參考**，下一個模擬事件週期若壓力觸發，就會拋
`attempted index: getFluidContainer of non-table`——用一個新的當機路徑換一次
換桶機會，違反「修復本身不能變成新的當機來源」。而且壞掉的桶子是玩家自己
選的那一個，乾淨結束、讓玩家換個好桶重下指令，就是 vanilla 在同一判準下
既定的結局（`:89-95` 的 `forceComplete`）。

攔在原函式**之前**也順帶蓋掉 `stress():41` 這條同形狀爆點：本補丁認定的形狀
下 `stress()` 不會被執行。代價是動物不會因為這次擠奶而受驚逃跑——但 vanilla
在同一形狀下是拋錯，逃跑本來也沒發生過。

**單人／MP 客戶端不安裝**：`MDFX_Guard.onServer` 的 `isServer()` 閘門。那兩端
走 `update()` 的 `if not isClient()` 分支同樣會碰到 `:70`，但正式服 log 零實據，
而且結束路徑不同（`self:forceStop()` 而非 `netAction:forceComplete()`）——不猜、
不擴大承接範圍，比照 MDFX_ReloadSpeedGuard 對 `:100/:102` 的處理方式登記在
docs/fixes.md 而不動手。

【不遮蔽不認識的錯誤】
本補丁是**前置判準**不是 pcall 包裝：判準不吻合就原樣呼叫原函式，原函式
自己拋的任何錯誤都原樣外洩、堆疊仍指向 vanilla 行號。判準本身只呼叫
`InventoryItem` 基類的 `getFluidContainer()`（對任何物品安全、不會拋），
所以不加 pcall；真的拋了就原樣外洩，不掩蓋。

【安裝機制】
`shared/Fixes/MDFX_Guard.lua`：`isServer()` 閘門、形狀檢查（`milk`／`stress`
都要在）、marker 冪等、`OnGameBoot` 復查（`Core.ResetLua` 重載與後載 MOD
整支替換都靠這一輪重新接管）、診斷節流。

【退場條件】
官方把 `:70`／`:92` 的判準改成「桶子存在**且**有流體容器」（或改用
`getFluidContainer()` 的 nil 安全查法），並修掉 `stress():41`。
遊戲更新後跑 `python scripts/check_vanilla_alignment.py` 確認 vanilla 形狀是否已變。
]]

MDFX_Guard.wrap({
    name = "milkAnimalGuard",
    class = "ISMilkAnimal",
    methods = { "milk", "stress" },
    build = function(originals)
        return {
            milk = function(self)
                -- 已知壞形狀：桶子存在，但它不是流體容器（vanilla :70 對它 index nil）
                if not self.bucket or self.bucket:getFluidContainer() then return originals.milk(self) end
                self.bucket:setJobDelta(0.0)
                if self.netAction then self.netAction:forceComplete() end
                MDFX_Guard.warnOnce("milkAnimalGuard", "ISMilkAnimal.milk: bucket has no fluid container; ending the action the vanilla way instead of crashing at ISMilkAnimal.lua:70. Further occurrences suppressed this session. See docs/fixes.md MDFX_MilkAnimalGuard")
            end,
        }
    end,
})
