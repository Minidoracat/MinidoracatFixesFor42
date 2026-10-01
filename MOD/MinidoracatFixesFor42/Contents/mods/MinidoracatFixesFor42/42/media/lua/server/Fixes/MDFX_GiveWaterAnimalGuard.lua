--[[
MDFX_GiveWaterAnimalGuard — 餵水動作在伺服器找不到動物或水容器時每 400 ms 拋錯、停不下來

【缺陷】
MP 下 client 送出餵水動作，server 以 `NetTimedAction.parse`（`NetTimedAction.java:142-171`）
重建 `ISGiveWaterToAnimal.new(character, animal, item)`。動物以 online ID 傳送
（`PZNetKahluaTableImpl.java:404-407`），server 用 `AnimalInstanceManager` 查不到這個 ID 就解析成
nil（`AnimalID.java:22-25`、`PZNetKahluaTableImpl.java:598-601`）；水容器以「容器＋物品 ID」傳送，
server 在那個容器裡找不到這個 ID 也是 nil（`PZNetKahluaTableImpl.java:473-478` 的 `getItemWithID`）。
動作照樣建立：`new()`（`shared/TimedActions/Animals/ISGiveWaterToAnimal.lua:124-133`）只做欄位賦值，
`getDuration()` 在 server 第一行就回 -1（`:102-105`），兩個都不碰。

`serverStart`（`:97-100`）每 400 ms 模擬一次 `update` 事件（`emulateAnimEvent` → `AnimEventEmulator`），
`animEvent` 前兩行無條件取值：

    self.animal:getStats():remove(CharacterStat.THIRST, 0.05 * self.animal:getThirstBoost());   -- :85
    self.item:getFluidContainer():removeFluid(0.05, false);                                       -- :86

動物是 nil 時 `:85` 拋 `attempted index: getStats of non-table: null`；動物在、水容器是 nil 時 `:85` 先扣掉
口渴、`:86` 才拋錯。後面「喝飽或水用完就 `self.netAction:forceComplete()`」（`:90-92`）永遠到不了，
動作不會自己結束。`complete`（`:77-78`）只碰動物。

【後果】
時長 -1 的動作只在這幾種情況結束：client 取消（`GeneralActionPacket.java:44` → `ActionManager.java:160-191`）、
同一玩家開始新動作（`NetTimedActionPacket.java:70`）、玩家斷線（`GameServer.java:4440` →
`ActionManager.java:245-256`）、伺服器重啟，或 30 分鐘上限：`Action.java:30-31` 把 -1 換成
`AnimEventEmulator.getDurationMax()`（1,800,000 ms），到時模擬事件被移除（`AnimEventEmulator.java:46`）、
呼叫 `complete`。在那之前每 400 ms 拋一次錯（動物 nil：正式服 log 實據，單次最多約兩千次例外，一路持續到
伺服器重啟）。client 的動作在 `waitForFinished` 下一直等伺服器結果（`BaseAction.java:174-176`），進度條停在
尾端。動物 nil：動物沒喝到水、水也沒少，30 分鐘到時 `complete` 在 `:77` 再拋一次、`perform` 回 false 走
Reject。水容器 nil：每 400 ms 白白扣掉動物 0.05 口渴、一滴水都沒用，30 分鐘到時 `complete` 回 true、以成功結束。

【本補丁】
只在 `isServer()` 包裝兩個 method：
- `animEvent`：動物或水容器是 nil、而且 event 是 `"update"` → `self.netAction:forceComplete()`（vanilla
  `:91` 自己的結束方式）、記一筆診斷後 return，不呼叫原函式（所以也不會先扣口渴）。其他 event 原樣透傳。
- `complete`：動物或水容器是 nil → 記一筆診斷（同一動作已記過就不再記）後回 false。
  `NetTimedAction.perform`（`:132-139`）把 false 交給 `ActionManager.update`（`ActionManager.java:87-97`）
  走 Reject 並通知 client 取消動作。動物 nil 時 vanilla 在這裡拋錯，`pcallBoolean` 回 null
  （`KahluaThread.java:1329-1338`）、`perform` 的 catch 同樣回 false，結局相同；水容器 nil 時 vanilla 會回 true，
  但伺服器其實沒做這個動作，拒絕才對，也與動物 nil 一致。
`forceComplete` 把結束時間設成現在（`NetTimedAction.java:173-175`）；同一幀稍後的
`ActionManager.update`（`IngameState.java:1559` 先跑含模擬事件的 `UpdateStuff`，`:1645` 才跑
`updateManagers`）就呼叫 `complete`，所以一個動作只走一次 `animEvent`，client 送出後約 0.4 秒收到拒絕。
動物與水容器都在時兩個 method 全部原樣透傳，正常餵水零行為差異。

**單人／MP 客戶端不安裝**（`MDFX_Guard.onServer` 的 `isServer()` 閘門）：那兩端的動物與水容器是
`new()` 當下的本地物件，不會是 nil。

【診斷紀錄】
目的是收集證據，追查 client 為什麼拿著伺服器不認得的動物，所以不照本 repo「一 session 一次」的
慣例：每個動作記一行（旗標掛在動作表上，`animEvent` 與 `complete` 都走到也只記一次），每 session
最多 `LOG_LIMIT` 行，超過後由 `MDFX_Guard.warnOnce` 印一次「不再記錄」、照樣拒絕。正式服每輪
0–3 次，上限只防異常時洗版。格式固定（grep `MDFX_GiveWaterAnimalGuard nil`）：

    [MinidoracatFixes] MDFX_GiveWaterAnimalGuard nilAnimal n=<本 session 第幾個> player="<帳號>" x=<格> y=<格> z=<層> item=<物品全名|nil> via=<animEvent|complete>; ...
    [MinidoracatFixes] MDFX_GiveWaterAnimalGuard nilItem n=<本 session 第幾個> player="<帳號>" x=<格> y=<格> z=<層> animal=<種類>#<online ID> via=<animEvent|complete>; ...

座標是玩家所在格（`math.floor`）。動物和水容器都 nil 時記成 `nilAnimal ... item=nil`。client 送來的動物 ID
在 Java 解析時就丟了（`AnimalID.parse` 只留解析結果），Lua 拿不到。訊息不寫原版檔名行號
（`ISGiveWaterToAnimal.lua:85` 之類），grep 原版錯誤的監控才不會把這行算進去。

【取捨】
- 只攔 `"update"`：vanilla 對其他 event 什麼都不做（`:84`），攔了等於替未來新增的事件決定行為。
- 物品在、但不是流體容器（`getFluidContainer()` 回 nil，同樣在 `:86` 拋錯）不處理：成因是物品被換掉，
  不是伺服器解析不到，沒有實據，照原版外洩。
- 不替 client 找「附近另一隻動物」接手：伺服器不認得玩家指定的動物，猜一隻等於發明行為。
- 診斷不包 pcall：只呼叫 `IsoPlayer`／`InventoryItem`／`IsoAnimal` 的取值方法並先判 nil；Kahlua 被 pcall
  接住的錯誤仍會印整段堆疊（見 `MDFX_ButcherMeatRatio`），包了也不會更安靜。`animEvent` 先
  `forceComplete` 再記錄，診斷就算出錯，動作也已經會結束。

【不遮蔽不認識的錯誤】
前置判準不是 pcall 包裝：判準不吻合就原樣呼叫原函式，原函式自己拋的錯誤（例如物品不是流體容器、
`self.animal` 不是動物）原樣外洩、堆疊仍指向 vanilla 行號。

【安裝機制】
`shared/Fixes/MDFX_Guard.lua`：`isServer()` 閘門、形狀檢查（`animEvent`／`complete` 都要在）、marker 冪等
（錨在 `animEvent`）、`OnGameBoot` 復查（`Core.ResetLua` 重載與後載 MOD 整支替換都靠這一輪重新接管）。

【退場條件】
官方在 `animEvent`（或 `serverStart`）與 `complete` 補上動物與水容器的 nil 檢查。
遊戲更新後跑 `python scripts/check_vanilla_alignment.py` 確認 vanilla 形狀是否已變。
]]

local LOG_LIMIT = 20
local logged = 0

local function where(chr)
    if not chr then return "player=? x=? y=? z=?" end
    return 'player="' .. tostring(chr:getUsername()) .. '" x=' .. math.floor(chr:getX())
        .. " y=" .. math.floor(chr:getY()) .. " z=" .. math.floor(chr:getZ())
end

-- 每個動作只記一行；animEvent 先走到時 complete 不會再記
local function record(self, via)
    if self.MDFX_giveWaterUnresolved then return end
    self.MDFX_giveWaterUnresolved = true
    logged = logged + 1
    if logged > LOG_LIMIT then
        MDFX_Guard.warnOnce("giveWaterAnimalGuard:limit", "MDFX_GiveWaterAnimalGuard limit=" .. LOG_LIMIT
            .. " reached; further watering actions the server cannot resolve are still rejected but not logged this session. See docs/fixes.md MDFX_GiveWaterAnimalGuard")
        return
    end
    local line
    if not self.animal then
        line = "nilAnimal n=" .. logged .. " " .. where(self.character)
            .. " item=" .. (self.item and tostring(self.item:getFullType()) or "nil") .. " via=" .. via
            .. "; the server has no such animal, so the watering action is rejected instead of erroring every 400 ms."
    else
        line = "nilItem n=" .. logged .. " " .. where(self.character)
            .. " animal=" .. tostring(self.animal:getAnimalType()) .. "#" .. tostring(self.animal:getOnlineID()) .. " via=" .. via
            .. "; the server cannot find the water container in the player's inventory, so the watering action is rejected instead of watering for free and erroring every 400 ms."
    end
    print("[MinidoracatFixes] MDFX_GiveWaterAnimalGuard " .. line .. " See docs/fixes.md MDFX_GiveWaterAnimalGuard")
end

MDFX_Guard.wrap({
    name = "giveWaterAnimalGuard",
    class = "ISGiveWaterToAnimal",
    methods = { "animEvent", "complete" },
    build = function(originals)
        return {
            animEvent = function(self, event, parameter)
                -- 已知壞形狀：server 解析不到動物（vanilla :85）或水容器（:86），每次 update 事件都拋錯
                if (self.animal and self.item) or event ~= "update" then return originals.animEvent(self, event, parameter) end
                if self.netAction then self.netAction:forceComplete() end
                record(self, "animEvent")
            end,
            complete = function(self)
                if self.animal and self.item then return originals.complete(self) end
                record(self, "complete")
                return false
            end,
        }
    end,
})
