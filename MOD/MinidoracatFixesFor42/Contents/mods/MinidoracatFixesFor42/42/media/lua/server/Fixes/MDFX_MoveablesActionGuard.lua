--[[
MDFX_MoveablesActionGuard — 擺放家具動作在 server 端解析不到物品時拋錯

【缺陷】
`ISMoveablesAction:new`（`shared/Moveables/ISMoveablesAction.lua:271-343`）在
`place` 模式下無條件解參考傳入的物品：

    :307  if o.mode == "place" then
    :308      local worldSpriteName = item:getWorldSprite();

server 以 `NetTimedAction.parse`（`NetTimedAction.java:142-171`）用物件 id
反序列化 `new` 的引數，要擺放的物品已被丟棄／消耗／不在同步範圍時解析結果
是 nil，`:308` 拋 `attempted index: getWorldSprite of non-table: null`
（正式服 log 實據，16 次／3 天）。

【後果】
**只有 log 噪音，沒有玩家可見的損失**——這一點是本補丁刻意只做最小守衛的
理由。`NetTimedAction.parse`（`NetTimedAction.java:159-163`）對
「`new` 拋錯」與「`new` 回 nil」的處理**完全相同**：

    LuaReturn result = LuaManager.caller.protectedCall(…, functionObject, arguments);
    if (!result.isSuccess() || result.getFirst() == null) {
        this.action = null;
        return;
    }

也就是說例外已經被 Java 端接住、action 被丟棄，擺放動作本來就被拒。

【本補丁】
包裝 `ISMoveablesAction.new`（只在 `isServer()`）：`mode == "place"` 且物品為
nil 時印一次診斷、回 nil，不呼叫原函式；其餘一切原樣透傳（八個參數依原簽名
逐一轉交）。回 nil 與現況走的是 `NetTimedAction.parse` 的**同一條分支**
（`this.action = null`），所以這道守衛的行為差異嚴格為零，只是把「例外」
換成「乾淨的 nil」。

【取捨：只守 place + item=nil】
`new` 是 70 行的建構子，另外兩條分支也有無條件解參考（`:282`
`ISMoveableSpriteProps.fromObject(object)`、`:324` `object:getSprite()`），
但正式服 log 對它們零實據。整支複製替換是 70 行的漂移面（違反本 repo
「不整函式複製替換」的既定取捨，見 MDFX_ReloadSpeedGuard 檔頭），
所以只登記實際觀測到的那一個形狀。

client／單人不安裝（`MDFX_Guard.onServer` 的 `isServer()` 閘門）：那兩端
`item` 來自 `ISMoveableCursor` 的本地引用，這個形狀只存在於 server 端的封包重建。

【不遮蔽不認識的錯誤】
前置判準，不是 pcall 包裝：形狀不吻合就原樣呼叫原函式，原函式自己拋的任何
錯誤都原樣外洩、堆疊仍指向 vanilla 行號。

【安裝機制】
`shared/Fixes/MDFX_Guard.lua`：`isServer()` 閘門、形狀檢查、marker 冪等、
`OnGameBoot` 復查、診斷節流。

【退場條件】
官方在 `:308` 之前檢查 `item`（或在 `:307` 的 gate 併入 `item ~= nil`）。
遊戲更新後跑 `python scripts/check_vanilla_alignment.py` 確認 vanilla 形狀是否已變。
]]

MDFX_Guard.wrap({
    name = "moveablesActionGuard",
    class = "ISMoveablesAction",
    methods = { "new" },
    build = function(originals)
        return {
            -- 簽名照 vanilla :271 逐一轉交（NetTimedAction.parse 是按位置傳引數的）
            new = function(self, character, square, mode, origSpriteName, object, direction, item, moveCursor)
                if mode ~= "place" or item ~= nil then return originals.new(self, character, square, mode, origSpriteName, object, direction, item, moveCursor) end
                MDFX_Guard.warnOnce("moveablesActionGuard", "ISMoveablesAction.new: place-mode item resolved to nil; returning nil (same branch NetTimedAction.parse already takes for a throwing new, NetTimedAction.java:159-163) instead of crashing at ISMoveablesAction.lua:308. Further occurrences suppressed this session. See docs/fixes.md MDFX_MoveablesActionGuard")
                return nil
            end,
        }
    end,
})
