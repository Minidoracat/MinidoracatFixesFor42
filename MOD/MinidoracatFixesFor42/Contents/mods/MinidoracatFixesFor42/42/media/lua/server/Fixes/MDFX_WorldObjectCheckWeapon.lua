--[[
MDFX_WorldObjectCheckWeapon — dedicated server 缺 ISWorldObjectContextMenu.checkWeapon

【缺陷】
`ISWorldObjectContextMenu.checkWeapon`（`client/ISUI/ISWorldObjectContextMenu.lua`
:895-913）自己就寫了 server 分支：

    :907  if isServer() then
    :908      sendServerCommand(chr, 'ui', 'dirtyUI', { });
    :909  else
    :910      ISInventoryPage.dirtyUI();
    :911  end

也就是官方明確預期它會在 server 端被呼叫。但檔案放在 `client/`，dedicated
server 只算 checksum 不執行 → 整個 `ISWorldObjectContextMenu` 全域在 server 上
是 nil。三個 **shared** 動作在「工具這一擊剛好把耐久打完（`damageCheck` 回真）」
時無條件呼叫它：

    shared/TimedActions/ISDestroyStuffAction.lua:311-312   （complete，:320 才 return true）
    shared/TimedActions/ISPickUpGroundCoverItem.lua:34-35  （animEvent 'Chop' 末尾）
    shared/TimedActions/ISRemoveBush.lua:78-79            （animEvent 'Chop'，:69 已自帶 isServer() 分支）

Kahlua 拋 `attempted index: checkWeapon of non-table: null`（正式服 log 實據，
7 日 20–140 次／天，是 `NetTimedAction.perform` 的 protectedCallBoolean 總帳
最大單項）。

【後果】
拆除／清地被已在 `:298`／`:301` 完成，但 `ISDestroyStuffAction:complete()` 沒能
跑到 `:320 return true` → `NetTimedAction.perform`（`NetTimedAction.java:131-139`）
的 protectedCallBoolean 吞下例外回 false，action 走 Reject；`ISRemoveBush` 那條
連 `useEndurance` 之後的收尾都斷掉。另外武器耐久歸零時 server 端不會卸裝，
玩家手上留著一把 condition 0 的工具。

【本補丁】
**補上缺席的函式本體，不包裝任何 vanilla 函式**（取捨見下）：
`isServer()` 為真、且 `ISWorldObjectContextMenu.checkWeapon` 不存在時，建立
（或沿用既有的）`ISWorldObjectContextMenu` 表並填入 vanilla :896-912 的等價
實作。三個呼叫點與任何第三方 shared 碼的同名呼叫一次全數受益。
vanilla :909-911 的 `ISInventoryPage.dirtyUI()` 分支不複製——本檔只在
`isServer()` 為真時安裝，那條分支永遠到不了，留著只是一行死碼。

【取捨：為什麼不用 pcall 包三個呼叫者】
另一種修法是包裝 `ISDestroyStuffAction.complete`／`ISPickUpGroundCoverItem.animEvent`／
`ISRemoveBush.animEvent`，pcall 原版、比對錯誤文字 `checkWeapon of non-table`
再補做 checkWeapon 並回 true。它要追三個 vanilla 函式的形狀（三倍漂移面）、
要依賴 Kahlua 錯誤訊息字面（訊息格式一改就失效），而且**照樣得寫一份
server 端的 checkWeapon 等價實作**——成本三倍、承接面更窄（別的 MOD 的
shared 呼叫點不受益）。

代價是本補丁在 dedicated server 上讓 `ISWorldObjectContextMenu` 從 nil 變成
「只有 checkWeapon 的表」。已實掃本機 Workshop 快取（`grep -rl ISWorldObjectContextMenu`
排除 `lua/client/`，共 14 檔）：沒有任何 MOD 拿這個全域的存在與否當「我在
client 端」的判準去 gate 無關邏輯；兩處真的做存在檢查的（NicksSledgehammerFix
`if ISWorldObjectContextMenu then`、家族私有 MinidoracatFixMultipleFor42
`if ISWorldObjectContextMenu and ISWorldObjectContextMenu.checkWeapon then`）
守的正好就是 checkWeapon 呼叫，補上之後它們是「終於能正常執行」。
其餘無條件索引別的成員的（Bandits `.fetchVars`、Ladders `.onClimbSheetRope`、
FoodDrying `.checkWeapon`）本來就在炸，補完後 checkWeapon 那條會好、
另兩條換成同一類的 nil 失敗（不會更糟）。

【零行為差異】
函式本體是 vanilla 的等價實作，不加預設值、不改條件：手上的工具還有耐久
（`getCondition() > 0`）時 vanilla 本體整段不做事，本補丁一樣不做事。
client／單人完全不安裝（`MDFX_Guard.onServer` 的 `isServer()` 閘門），
那兩端的 vanilla 檔本來就會載入。

【安裝機制】
冪等：只在 `checkWeapon` 不是 function 時填入，所以重複載入、`Core.ResetLua`
重載、`OnGameBoot` 復查都不會疊第二層；官方哪天把檔案搬到 shared／server，
或別的 MOD 自己補了一份，本補丁自動不介入（讓位給對方）。
安裝時機與診斷節流由 `shared/Fixes/MDFX_Guard.lua` 提供。

【退場條件】
官方把 `checkWeapon` 移到 `shared/`（或在三個 shared 呼叫點自己加存在檢查）。
遊戲更新後跑 `python scripts/check_vanilla_alignment.py` 確認 vanilla 形狀是否已變。
]]

-- vanilla client/ISUI/ISWorldObjectContextMenu.lua:896-912 的等價實作
local function serverCheckWeapon(chr)
    MDFX_Guard.warnOnce("worldObjectCheckWeapon:invoked", "ISWorldObjectContextMenu.checkWeapon called on the server (vanilla ships it client-only; ISDestroyStuffAction.lua:312 / ISPickUpGroundCoverItem.lua:35 / ISRemoveBush.lua:79 would have thrown). Further occurrences suppressed this session. See docs/fixes.md MDFX_WorldObjectCheckWeapon")

    local weapon = chr:getPrimaryHandItem()
    if not weapon or weapon:getCondition() <= 0 then
        chr:removeFromHands(weapon)
        weapon = chr:getInventory():getBestWeapon(chr:getDescriptor())
        if weapon and weapon ~= chr:getPrimaryHandItem() and weapon:getCondition() > 0 then
            chr:setPrimaryHandItem(weapon)
            if weapon:isTwoHandWeapon() and not chr:getSecondaryHandItem() then
                chr:setSecondaryHandItem(weapon)
            end
        end
        sendServerCommand(chr, 'ui', 'dirtyUI', { })
    end
end

MDFX_Guard.onServer(function()
    -- 已經有人提供（官方修好、別的 MOD 補了、或本檔上一輪裝過）→ 不介入。
    if type(ISWorldObjectContextMenu) == "table" and type(ISWorldObjectContextMenu.checkWeapon) == "function" then return end
    ISWorldObjectContextMenu = ISWorldObjectContextMenu or {}
    ISWorldObjectContextMenu.checkWeapon = serverCheckWeapon
    MDFX_Guard.warnOnce("worldObjectCheckWeapon:installed", "MDFX_WorldObjectCheckWeapon installed: supplied server-side ISWorldObjectContextMenu.checkWeapon (vanilla file is client-only). See docs/fixes.md MDFX_WorldObjectCheckWeapon")
end)
