--[[
MDFX_AnimalCompleteGuard — 牽繩、拴樹、裝拖車、手餵在伺服器找不到動物時 complete 拋錯

【缺陷】
成因與 `MDFX_GiveWaterAnimalGuard` 相同：client 指定的動物，server 用 online ID 在 `AnimalInstanceManager`
查不到（`AnimalID.java:22-25`），`NetTimedAction.parse`（`NetTimedAction.java:142-171`）照樣用 nil 建立動作。
這四個動作的 `new()` 都不碰動物、`getDuration()` 回正數（只看 `isTimedActionInstant`），server 端也沒有
`serverStart`／`animEvent`，所以時間到時 `complete` 第一次對動物取值才拋錯
（`shared/TimedActions/Animals/` 下）：

    ISAttachAnimalToPlayer.lua:42（牽上；解開走 :50）   self.animal:getData()
    ISAttachAnimalToTree.lua:42（解開；拴上走 :47）     self.animal:getData()
    ISAddAnimalInTrailer.lua:76（從地上；從手上走 :66） self.animal:getSquare()
    ISFeedAnimalFromHand.lua:46                         self.animal:getBehavior()

`pcallBoolean` 回 null、`NetTimedAction.perform` 的 catch 回 false（`KahluaThread.java:1329-1338`、
`NetTimedAction.java:132-139`），動作走 Reject（`ActionManager.java:87-97`），client 收到後取消。

【後果】
每個動作拋一次錯（整段堆疊＋`Perform failed`），結果本來就是拒絕：沒牽上、沒拴上、沒裝進、沒餵到。
正式服 log 實據：牽繩與裝拖車在餵水出事的同一段時間各出現過，沒裝畜牧介面 MOD 的時期也有。
裝拖車從手上放入（`:66`）時，`addAnimalFromHandsInTrailer` 的 `IsoAnimal` 多載第一行就把參數加進拖車的
動物清單（`BaseVehicle.java:10615`），下一行才對它取值；Kahlua 對 nil 選到這個多載的話，拖車清單會留下
一個 null（推論，未實測）。

【本補丁】
只在 `isServer()` 包裝四個 class 的 `complete`：`self.animal` 是 nil → 記一行診斷、回 false（同樣走 Reject），
不呼叫原函式；動物存在時原樣透傳。結局與原版相同，只是不拋錯、不會碰到上面那個多載，並留下玩家與位置
供追查。`ISAddAnimalInTrailer` 原版在取值前先跑 `self.vehicle:updateParts()`（`:63`），nil 時本補丁不跑：
它只為「新加入的動物」結算經過的時間，沒有動物加入就沒有要結算的對象，車輛之後的更新照常處理。

【診斷紀錄】
與 `MDFX_GiveWaterAnimalGuard` 同一套：每個動作一行（`complete` 每個動作只走一次），每 session 最多
`LOG_LIMIT` 行（四個動作共用），超過後由 `MDFX_Guard.warnOnce` 印一次「不再記錄」、照樣拒絕。
格式固定（grep `MDFX_AnimalCompleteGuard nilAnimal n=`）：

    [MinidoracatFixes] MDFX_AnimalCompleteGuard nilAnimal n=<本 session 第幾個> action=<動作> player="<帳號>" x=<格> y=<格> z=<層> [remove=<true|false>|fromHand=<true|false>]; ...

`remove` 是牽繩／拴樹的「解開」，`fromHand` 是裝拖車的「從手上放入」。訊息不寫原版檔名行號，grep 原版錯誤
的監控才不會把這行算進去。

【取捨】
- 只包 `complete`：這四個動作在 server 只有 `complete` 碰動物。
- 裝拖車從手上放入、而玩家物品欄裡有動物物品時，`new()` 的 `getAnimalInventoryItem(animal)`（`:101`，
  `ItemContainer.java:796-810`）就會對 nil 取值，在 parse 拒絕並拋一次錯。那不在 `complete`，也沒有正式服
  實據，不包 `new`。
- `ISPickupAnimal.complete` 先以 `isValid()`（`:6`）擋掉 nil 動物（`:42-44`），不需要。

【不遮蔽不認識的錯誤】
前置判準不是 pcall 包裝：動物存在時原函式拋的錯（例如載具或樹解析不到）原樣外洩。

【安裝機制】
`shared/Fixes/MDFX_Guard.lua`，每個 class 各自 `wrap`：各自的形狀檢查與 `NOT installed`、marker（錨在
`complete`）、`OnGameBoot` 復查。某個 class 形狀變了只影響它自己。

【退場條件】
四個各自獨立：官方在哪個 class 的 `complete`（或 `isValid`）補上 `self.animal` 的 nil 檢查，就把那一個移出。
遊戲更新後跑 `python scripts/check_vanilla_alignment.py` 確認 vanilla 形狀是否已變。
]]

local LOG_LIMIT = 20
local logged = 0

local function where(chr)
    if not chr then return "player=? x=? y=? z=?" end
    return 'player="' .. tostring(chr:getUsername()) .. '" x=' .. math.floor(chr:getX())
        .. " y=" .. math.floor(chr:getY()) .. " z=" .. math.floor(chr:getZ())
end

local function guard(name, class, flag)
    MDFX_Guard.wrap({
        name = name,
        class = class,
        methods = { "complete" },
        build = function(originals)
            return {
                complete = function(self)
                    if self.animal then return originals.complete(self) end
                    logged = logged + 1
                    if logged <= LOG_LIMIT then
                        print("[MinidoracatFixes] MDFX_AnimalCompleteGuard nilAnimal n=" .. logged .. " action=" .. class
                            .. " " .. where(self.character) .. (flag and (" " .. flag .. "=" .. tostring(self[flag] == true)) or "")
                            .. "; the server has no such animal, so the action is rejected instead of erroring in complete. See docs/fixes.md MDFX_AnimalCompleteGuard")
                    else
                        MDFX_Guard.warnOnce("animalCompleteGuard:limit", "MDFX_AnimalCompleteGuard limit=" .. LOG_LIMIT
                            .. " reached; further animal actions without a server-side animal are still rejected but not logged this session. See docs/fixes.md MDFX_AnimalCompleteGuard")
                    end
                    return false
                end,
            }
        end,
    })
end

guard("attachAnimalToPlayerGuard", "ISAttachAnimalToPlayer", "remove")
guard("attachAnimalToTreeGuard", "ISAttachAnimalToTree", "remove")
guard("addAnimalInTrailerGuard", "ISAddAnimalInTrailer", "fromHand")
guard("feedAnimalFromHandGuard", "ISFeedAnimalFromHand")
