--[[
MDFX_LockDoorsGuard — 車門上鎖遇到「沒有門的乘客門部件」時拋錯

【缺陷】
`ISLockDoors:complete`（`shared/Vehicles/TimedActions/ISLockDoors.lua:33-67`）
的乘客門迴圈自己寫了一道防護，但那道防護的錯誤訊息本身就是爆點：

    :37      local part = self.vehicle:getPassengerDoor(seat-1)
    :45      if not part:getDoor() then
    :46          print('part ' .. part .. ' has no door')      ← 對 userdata 做 ..
    :47          return
    :48      end

`part` 是 `VehiclePart`（Java 物件），Kahlua 的 `..` 對它沒有 `__concat`，
拋 `__concat not defined for operands: VehiclePart and " has no door"`
（正式服 log 實據，2 次／8 天）。也就是說 vanilla 想印「這個部件沒有門」
並乾淨早退，卻在印訊息時先炸掉。隔壁 `:42` 的 `print('no such part '..tostring(part))`
有 `tostring`，`:46` 漏了。

堆疊上面那層是 W900 Semi-Truck 的 `complete` 包裝，但**那個 MOD 不是觸發者**：
`rSemiTruck_TrunkDoorLockSync.lua:61-68` 是先呼叫原版 `complete`、成功才做自己
的同步，爆點在原版 `:46`，MOD 的同步根本還沒執行。

【後果】
那次上鎖／解鎖在第一個無門部件處中止：該部件之後的乘客門、以及第三方 MOD
的連動門（W900 的貨櫃門）都沒鎖上，而且——比 vanilla 自己的 `return` 更糟——
`:39-51` 的迴圈是**邊走邊寫**，無門部件之前的座位已經 `setLocked` 並
`transmitPartDoor` 出去了，形成部分更新。

【本補丁】
包裝 `ISLockDoors.complete`（只在 `isServer()`）：先**預掃**所有乘客門部件，
任何一個 `part:getDoor()` 為 nil 就印一次安全訊息（用 `tostring(part:getId())`
與 `tostring(vehicle:getScriptName())`，不對 userdata 做 `..`）並回 false，
**一扇門都不動**；全部有門才原樣呼叫原函式。

取捨兩處寫明：

1. **照 vanilla 的既定語意「早退」，不改成「跳過無門部件、繼續鎖其他門」。**
   `:46-47` 官方寫的是 `print` ＋ `return`——中止就是它的意圖。改成跳過會讓
   「無門部件之後的門終於鎖上」，聽起來更好，但那是在 vanilla 沒有定義行為的
   地方發明行為，違反本 repo 的零行為差異鐵則。
2. **預掃而不是邊走邊擋**，是為了不留部分更新：vanilla 現況會把無門部件
   之前的座位鎖起來然後拋錯，本補丁改成一致的「整批不做」。這是這條分支
   唯一的可觀測差異，而該分支現況是拋例外（`NetTimedAction.perform` 的
   protectedCallBoolean 吞成 false），本來就沒有「成功」的語意可保。

`self.vehicle` 為 nil 時原樣透傳——vanilla `:34-36` 自己就回 false。

client／單人不安裝（`MDFX_Guard.onServer` 的 `isServer()` 閘門）：無門部件在
單人同樣會炸，但正式服 log 的實據都在 server 端（MP 的 `NetTimedAction` 路徑），
而且 `:56` 之後的 JoypadState 段落只有非 server 端會走——不猜、不擴大承接範圍。

【不遮蔽不認識的錯誤】
前置判準，不是 pcall 包裝：所有部件都有門就原樣呼叫原函式，原函式自己拋的
任何錯誤都原樣外洩、堆疊仍指向 vanilla 行號。預掃呼叫的 `getMaxPassengers`／
`getPassengerDoor`／`getDoor` 就是 vanilla `:37`／`:45` 自己在用的同三個方法
（`BaseVehicle.java:1797`／`:1948`、`VehiclePart.java:494`），所以不加 pcall；
真的拋了就原樣外洩，不掩蓋。

【安裝機制】
`shared/Fixes/MDFX_Guard.lua`：`isServer()` 閘門、形狀檢查、marker 冪等、
`OnGameBoot` 復查（後載 MOD 整支替換時把「他的版本」當新 original 再包一層
——W900 Semi-Truck 就是這種包裝）、診斷節流。

【退場條件】
官方把 `:46` 的 `part` 包上 `tostring`（像 `:42` 那樣），或改掉那道防護的寫法。
遊戲更新後跑 `python scripts/check_vanilla_alignment.py` 確認 vanilla 形狀是否已變。
]]

MDFX_Guard.wrap({
    name = "lockDoorsGuard",
    class = "ISLockDoors",
    methods = { "complete" },
    build = function(originals)
        -- 回傳第一個「有部件但沒有門」的 VehiclePart，沒有就回 nil
        local function doorlessPart(vehicle)
            for seat = 1, vehicle:getMaxPassengers() do
                local part = vehicle:getPassengerDoor(seat - 1)
                if part and not part:getDoor() then return part end
            end
        end
        return {
            complete = function(self)
                local doorless = self.vehicle and doorlessPart(self.vehicle)
                if not doorless then return originals.complete(self) end
                MDFX_Guard.warnOnce("lockDoorsGuard", "ISLockDoors.complete: a passenger-door part has no door ("
                    .. tostring(doorless:getId()) .. "@" .. tostring(self.vehicle:getScriptName())
                    .. "); aborting without touching any door instead of crashing at ISLockDoors.lua:46. Further occurrences suppressed this session. See docs/fixes.md MDFX_LockDoorsGuard")
                return false
            end,
        }
    end,
})
