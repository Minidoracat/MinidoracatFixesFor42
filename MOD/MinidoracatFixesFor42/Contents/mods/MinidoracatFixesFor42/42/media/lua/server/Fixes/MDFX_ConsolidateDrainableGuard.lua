--[[
MDFX_ConsolidateDrainableGuard — 液體合併「來源扣了、目的物沒填」的部分更新

【缺陷】
`ISConsolidateDrainable:update`（`shared/TimedActions/ISConsolidateDrainable.lua:13-40`）
在 server 端先扣來源、再填目的物，中間沒有任何型別驗證：

    :25  if self.drainable:getCurrentUsesFloat() <= 0 then …            -- 基類方法，安全
    :33  self.drainable:setUsedDelta(fromDelta);                        -- 來源：扣量成功
    :35  self.intoItem:setUsedDelta(intoDelta);                         -- 目的物：方法不存在 → 當場拋
    :36-38  sendItemStats(self.intoItem); sendItemStats(self.drainable) -- 兩邊都沒送出

`getCurrentUsesFloat` 在 `InventoryItem` 基類（`InventoryItem.java:2594`），對任何
物品都安全；`setUsedDelta` **不在基類**，只有 `DrainableComboItem.java:78`、
`Clothing.java:1313`、`WeaponPart.java:301` 有。目的物是其他型別的 `InventoryItem`
時 `:35` 拋 `Object tried to call nil in update`（正式服 log 實據，12 次／3 天）。
堆疊：

    Lua(Vanilla).update(ISConsolidateDrainable.lua:35)
    Lua(Vanilla).animEvent(ISConsolidateDrainable.lua:46)
    → AnimEventEmulator.update(AnimEventEmulator.java:60)

**這不是「來源為 nil」**：`:25` 已經成功讀過來源、`:33` 已經對來源寫入。

【為什麼不合型別的目的物進得來】
vanilla client 端的選單 gate（`ISInventoryPaneContextMenu.checkConsolidate`
:2156）只驗來源 `drainable:canConsolidate()`，候選目的物是
`getItemsFromType(drainable:getType())`——**按 script type 名稱**撈，不是按 class。
server 端更寬：`NetTimedAction.parse`（`NetTimedAction.java:142-171`）用物件 id
反序列化引數，解析到的可以是任何 `InventoryItem`。而 `new()`（:126-140）只用
基類安全的 `getCurrentUsesFloat` 所以照樣建得起來，`start()`（:55-66，內含
`DrainableComboItem` 專屬的 `canConsolidate()`）**在 server 端不會執行**
（server 走 `serverStart()`），於是 vanilla 自己那道隱含的型別要求整個被跳過。

【後果】
**部分更新**：來源每個週期被扣、目的物沒填、`sendItemStats` 兩邊都沒送——
液體憑空消失，而且 client 端看到的量與 server 不一致。這是本批修復裡唯一
有資產損失風險的一項（頻率只有 12 次／3 天，但每次都在毀液體）。

【本補丁】
包裝 `update` 與 `complete`（只在 `isServer()`），在**任何寫入之前**驗證
兩邊都是 `DrainableComboItem`：

| method | 不合法時 | 依據 |
|--------|---------|------|
| `update` | 一個位元都不寫，`netAction:forceComplete()` 乾淨結束 | vanilla :26-30 對「來源已空」就是用 `forceComplete()` 收場的既定寫法 |
| `complete` | 回 false | `:111 self.drainable:getCurrentUsesFloat()` 對 nil 來源會再炸一次；回 false 比照 `ISButcherAnimal:complete`（:51-53）的 vanilla 先例，`NetTimedAction.perform`（`NetTimedAction.java:131-139`）把 false 傳回 `ActionManager` 走 Reject |

判準用 `instanceof(x, "DrainableComboItem")` 而不是「探測 setUsedDelta 存不存在」，
因為 vanilla 自己的合法路徑就已經要求兩邊都是 `DrainableComboItem`——
`start():61` 無條件呼叫 `self.intoItem:canConsolidate()`，而 `canConsolidate`
只在 `DrainableComboItem.java:516`。也就是說這個判準**拒絕不到任何現在能
正常跑完的組合**（client／單人一定經過 `start()`，非 Drainable 目的物在那裡
就已經炸了）。

nil 也一併擋下、而且不需要另外寫 nil 檢查：`instanceof` 的 Java 實作
（`LuaManager.instof`，`LuaManager.java:2948-2951`）第一件事就是
`if (obj == null) return false;`——對 nil 回 false、不拋。

【零行為差異】
兩邊都是 `DrainableComboItem` 時 `update`／`complete` 全部原樣透傳，合併量的
公式（`new()` :133-138 的 `fromTarget`／`intoTarget`）一個位元都沒動。
client／單人不安裝（`MDFX_Guard.onServer` 的 `isServer()` 閘門）——那兩端
`update` 的寫入段在 `if not isClient()` 內，且一定先過 `start():61` 的隱含型別要求。

【不遮蔽不認識的錯誤】
前置判準，不是 pcall 包裝：合法就原樣呼叫原函式，原函式自己拋的錯原樣外洩。

【安裝機制】
`shared/Fixes/MDFX_Guard.lua`：`isServer()` 閘門、形狀檢查、marker 冪等
（錨在 `update`，兩個 method 同批安裝）、`OnGameBoot` 復查、診斷節流。

【退場條件】
官方在 `:33` 之前驗證兩邊型別（或把 `setUsedDelta` 提到 `InventoryItem` 基類、
或在 `serverStart()` 補上 `start():61` 那道隱含檢查）。
遊戲更新後跑 `python scripts/check_vanilla_alignment.py` 確認 vanilla 形狀是否已變。
]]

MDFX_Guard.wrap({
    name = "consolidateDrainableGuard",
    class = "ISConsolidateDrainable",
    methods = { "update", "complete" },
    build = function(originals)
        -- instanceof 對 nil 回 false（LuaManager.java:2948-2951），所以這一行就是
        -- 「兩邊都在、且都是可裝液體的容器」的完整判準
        local function bothUsable(self)
            return instanceof(self.drainable, "DrainableComboItem")
                and instanceof(self.intoItem, "DrainableComboItem")
        end
        local MSG = "ISConsolidateDrainable: source or target is not a DrainableComboItem; aborting before any write so the source is not drained into nothing (vanilla ISConsolidateDrainable.lua:33-35). Further occurrences suppressed this session. See docs/fixes.md MDFX_ConsolidateDrainableGuard"
        return {
            update = function(self)
                if bothUsable(self) then return originals.update(self) end
                MDFX_Guard.warnOnce("consolidateDrainableGuard", MSG)
                if self.netAction then self.netAction:forceComplete() end
            end,
            complete = function(self)
                if bothUsable(self) then return originals.complete(self) end
                MDFX_Guard.warnOnce("consolidateDrainableGuard", MSG)
                return false
            end,
        }
    end,
})
