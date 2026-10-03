# 修復清單

本 MOD 每加一項修復，就在這裡登記一筆：症狀、根因、修法、驗證方式、可退場條件。
「可退場」= 官方哪天修好了，就從 MOD 移除該檔並在此標記為已退場。

---

## MDFX_ButcherMeatRatio — 屠宰壞屍體（modData 缺 `meatRatio`）

| 項目 | 內容 |
|------|------|
| 檔案 | `server/Fixes/MDFX_ButcherMeatRatio.lua` |
| 影響版本 | Build 42.20.4（更早版本同樣有此寫法） |
| 端 | server（單人同樣載入；vanilla 函式開頭 `if isClient() then return end`，與爆點同端） |
| 狀態 | **現役** |

### 症狀

屠宰特定動物屍體：玩家花完整段屠宰動作（900 − 技能×20 ticks）、動畫演完、
一塊肉都拿不到、屍體留在原地；同一隻動物每次重試都一樣。伺服器 log：

```
__concat not defined for operands: null
  Lua(Vanilla).butcherAnimalFromGround(ButcheringUtil.lua:70)
→ NetTimedAction.perform Exception → NPE(NetTimedAction.java:140)
```

來源伺服器 log 七日觀測 0–20 次/天，長期存在；已實掃確認該伺服器啟用的
所有 MOD 均未覆蓋此檔，堆疊的 `Lua(Vanilla)` 標記亦證明執行的是原版檔案。

### 根因（兩層）

**壞屍體怎麼產生的**：`setAnimalBodyData`（`shared/Definitions/animal/`
`ButcheringUtil.lua:12-57`）在 :18 查 `AnimalPartsDefinitions.animals[fullName]`，
模組動物查不到時 def 為 nil，:19 誠實寫下 `modData["parts"] = def ~= nil`，
:27 卻無條件解參考 `def.feather` 拋錯——而 `meatRatio` 要到 :40 才寫入。
Java 端 `IsoDeadBody.setAnimalData` 是 protectedCallVoid，錯誤吞掉後屍體照樣
生成，成為「`isAnimal()` 為 true、modData 永久缺 `meatRatio`」的壞資料。
**與已退場的 MDFX_AnimalTrailerSize 同根因、不同下游爆點**（見該節）。

**爆點**：`ButcheringUtil.butcherAnimalFromGround` 在給任何產出之前先組除錯字串：

```lua
-- ButcheringUtil.lua:70
text = text .. "Meat ratio: " .. carcass:getModData()["meatRatio"] .. "\r\n";
```

缺欄位時 Kahlua 對 nil 串接直接拋。爆點位於給肉（:97-102）、給骨（:91-94）、
屍體處置（:153-167）全部之前，所以整段屠宰零產出。

**為什麼動作發起得了**：`ISButcherAnimal:isValid()`（:6）要求
`modData["parts"] ~= nil`——壞屍體的 `parts` 是 **false**（有值，非 nil），
所以過得了 isValid、進得了爆點；更舊的「欄位時代之前」屍體 `parts` 為 nil，
根本進不來。

### 修法

包裝 `ButcheringUtil.butcherAnimalFromGround`：屍體為 nil、或 modData 的
`meatRatio` **不是 number**（nil／string／boolean 都算——vanilla 的 :70 串接、
:279 比較、:287-288 乘法對非 number 一律拋錯）時，印一次
`[MinidoracatFixes]` 診斷（含 AnimalType，幫管理員定位壞屍體來源 MOD）
後直接 return；其餘一律原樣透傳。取捨：

1. **不補預設值**——`meatRatio` 會進 `addAnimalPart` 的產出量乘法
   （`ButcheringUtil.lua:287-288`），任何預設值都是在改產出平衡。
2. **不複製函式體「跳過除錯字串」**——實戰可達的壞屍體形狀只有
   「`parts=false` 的模組動物」，官方就算修好 :70，同一屍體也會在 :74 的
   `partDef` 檢查早退（`getAnimalDef` 查的是當初就查不到的同一個 key），
   所以早退與「修好後的 vanilla」行為等價；而繼續往下跑反而踩更多缺欄位
   地雷（:279 `meatRatio <= 0` 對 nil 比較、:134 `AddItems` 吃 nil 數量、
   :156 `2 - modData["animalRotStage"]`）；骨架路徑（:92 `getAnimalBones` →
   :470 逐骨呼叫 `addAnimalPart`）同樣繞不開 :279。
3. **carcass 為 nil 也擋（fail-closed）**——`ISGetAnimalBones:complete()`（:49）
   沒有 `ISButcherAnimal:complete()`（:51）那道 body guard，MP 物件解析競態下
   body 為 nil 會直達本函式，vanilla :69 對 nil 索引必炸。與 MDFX_PetAnimalGuard
   的 nil 解析是同一機制（NetTimedAction 封包重建）。
4. **判準檢查自身拋錯時 fail-open**——`getModData` 拋錯等「guard 自己也無法
   判斷」的形狀交還 vanilla，讓堆疊指向原始行號，不掩蓋。
5. **診斷每 session 只印一次**——登入客戶端可重複送畸形 NetTimedAction，
   診斷行不能成為 log 洗版放大器。

**安裝機制**：sentinel 存 wrapper 自身引用（不是 boolean）。`Core.ResetLua`
重載時 vanilla 重建整張表、sentinel 隨之消失、本檔重跑重新包裝；後載 MOD
整支替換目標函式時，`OnGameBoot` 復查會發現 sentinel 與現任不符，把「他的
版本」當新 original 再包一層（chain，兩邊行為都保留）。比本補丁更晚的替換
不在保證範圍。

### 已知同根因殘留（不在本 MOD 範圍）

同一批壞屍體在 MP 純客戶端還有其他缺欄位爆點：`animalTrailerSize`
（拖車選單，之前由 MDFX_AnimalTrailerSize 覆蓋、已於 0.4.0 退場）與
`animalSize`（`ISButcherAnimal.lua:81` 的 `isLargeAnimal`，僅在動物 MOD 有註冊
AnimalAvatarDefinition＋hook 時可達）。兩者都是 client 端、無 server log 實據，
本次刻意不收；症狀出現時參照 MDFX_AnimalTrailerSize 的記錄另案評估。

### 驗證

`lua scripts/test_butcher_meatratio.lua` — 30 項，全綠。涵蓋：正常屍體完全透傳
（參數、回傳、呼叫次數）、壞屍體擋下＋診斷恰一次、`meatRatio=0` 不誤攔而
string／boolean 攔下、carcass=nil 擋下、getModData 拋錯時 fail-open、重複載入
不疊 wrapper、後載 MOD 整支替換後 `OnGameBoot` 復查重新包裝（壞形狀恢復被擋、
正常路徑透傳到替換版）、vanilla 缺席不亂補、成員快照（只新增 sentinel）。
含對照組：同一壞屍體直打 stub vanilla 確實拋錯。

carcass=nil 時診斷不再進 `pcall` 取 `AnimalType`：正式服 42.21 實見 `ISGetAnimalBones.lua:49` 以 nil 屍體呼叫，
診斷那段 `pcall` 對 nil 解參考，錯誤雖被接住，Kahlua 仍印整段 `attempted index: getModData of non-table` ERROR 堆疊
（家族 `pitfalls.md`：包在 `pcall` 裡只會印一段堆疊）。測試 [4] 以計數版 `pcall` 斷言補丁內部沒有被接住的錯誤。

**mutation 驗證**（`抽掉防線 → 對應檢查轉紅 → 還原全綠`）：

| 突變 | 轉紅 |
|------|------|
| 早退 gate 改 `if false then` | 12 項（例外外洩、原函式被呼叫、診斷缺席…） |
| 型別判準退化回 `== nil` | 2 項（string／boolean 放行） |
| OnGameBoot 復查永遠自認在位 | 2 項（替換後 guard 未恢復） |
| 診斷的 `carcass ~= nil` 檢查拿掉 | 1 項（補丁內部出現被 pcall 接住的錯誤） |

遊戲內：對缺欄位屍體發起屠宰——修復前 server log 出現 `__concat` 例外且零產出；
修復後動作正常完成、log 出現一行 `[MinidoracatFixes] butcher aborted`、不再有例外。

### 可退場條件

官方修好 `setAnimalBodyData` 的 nil 解參考（壞屍體不再產生）**且**對 :70 加
防護或移除該除錯字串（既有壞屍體不再炸）。只修前者救不了世界上已存在的壞屍體。
遊戲更新後跑 `python scripts/check_vanilla_alignment.py`：爆點行、
`butcherAnimalFromGround` 符號、`isClient()` 前提任一變動都會報 CHANGED。

---

## MDFX_ReloadSpeedGuard — `setReloadSpeed` 對「手持非槍械」缺防護

| 項目 | 內容 |
|------|------|
| 檔案 | `shared/Fixes/MDFX_ReloadSpeedGuard.lua` |
| 影響版本 | Build 42.20.4 |
| 端 | shared（server／client／單人同一段程式碼同一爆點，三端都保護） |
| 狀態 | **現役** |

### 症狀

特定裝備組合下按裝彈完全沒反應：子彈不消耗、彈匣不填充、沒有動畫。伺服器 log
（正式服實測 7 次/輪）：

```
java.lang.RuntimeException: Object tried to call nil in setReloadSpeed
  Lua(Vanilla).setReloadSpeed(ISReloadWeaponAction.lua:95)
```

### 根因

`ISReloadWeaponAction.setReloadSpeed`（`shared/TimedActions/`
`ISReloadWeaponAction.lua:75-114`）把 `character:getPrimaryHandItem()`（:86）
當「槍」用，:90 的 gate 只檢查「手上有東西＋穿彈藥背帶（`AMMO_STRAP`）或帶
`RELOAD_FAST_*` 標籤裝備」，沒檢查那東西是不是槍械：

```lua
-- :93  基類方法，安全（InventoryItem.java:3901，非槍回 null）
if gun:getAmmoType() == AmmoType.SHOTGUN_SHELLS then
-- :95  只有 HandWeapon 有（HandWeapon.java:2020）→ 非武器 call nil，當場拋
elseif gun:getMagazineType() then
```

觸發不需要手持槍：對彈匣裝子彈（`ISLoadBulletsInMagazine`）手上拿什麼都行。
server 端 `serverStart()`（:69-78）→ `initVars()`（:53-55）→ `setReloadSpeed`
在三個 `emulateAnimEvent` 註冊**之前**拋出——裝彈流程沒開始就中斷，action 掛著
直到 timeout。單人與 MP 客戶端走 `start()` → `initVars()`（:23）同樣會炸，
所以修在 shared。

順帶記錄一個**尚未修**的隔壁地雷：:100/:102 在 `reloadFast` 為 true、沒穿背帶時
`strap:getClothingItemName()` 對 nil 解參考。要到達那裡需要手持 shell/bullets
型**槍械**＋帶 RELOAD_FAST tag＋沒穿背帶＋tag 細項全不匹配，實戰 log 零實據。
該形狀手持的是槍械、不吻合本補丁的辨識條件，會走「重拋」路徑原樣暴露——
刻意不擴大承接範圍。

### 修法

包裝 `ISReloadWeaponAction.setReloadSpeed`（static，7 個 caller 全部表查呼叫：
Reload／Eject／Insert／LoadBullets／UnloadFirearm／UnloadMagazine 的 initVars
以 rack=false、`ISRackFirearm` 以 rack=true）：

1. 先 `pcall` 原函式，成功即結束——**正常玩家的裝彈速度公式一個位元都沒動**，
   vanilla 更新公式時正常路徑自動跟進。
2. 原函式拋出時**正面辨識已知壞形狀**：手持物存在且
   `not instanceof(gun, "HandWeapon")`。吻合才以 vanilla `:76-83`／`:109-112`
   的「無背帶加成」語意重算：`0.8 ＋ 裝填技能×0.10 － 恐慌×0.05`（rack 時
   `＋技能×0.04`、不扣恐慌）、駕駛中再 `×0.8`，寫入 `ReloadSpeed` 後印一次
   診斷。背帶那段（:85-108）本來就只對「手持槍械」有意義，跳過它是這個
   形狀下的正確語意，不是少算。重算再失敗整體退 1.0（下游
   `getReloadTime`（:70）`getVariableFloat("ReloadSpeed", 1.0)` 的預設值），
   不用算到一半的值。
3. 原函式因**其他原因**拋出（未來版本的新問題、或連辨識都失敗）→ 印一次
   警告後把原始錯誤**原樣重拋**——本補丁只承接它能辨識的形狀，不冒充、
   不掩蓋新的 regression。

不整函式替換：40 行複製面在遊戲更新時就是 40 行漂移風險；fallback 公式只在
「vanilla 自己已經炸掉、且確認是已知形狀」時承重，過期的最壞後果是壞形狀下
速度略偏，正常玩家永遠不受影響。公式係數已登記進 `check_vanilla_alignment.py`，
vanilla 改係數會被抓到。

server 端能連炸 7 次到 :95 也順帶證明了 fallback 用的
`getMoodles()`／`getPerkLevel()` 在 server 端安全（:79-:82 每次都先執行過）。

**安裝機制**：sentinel 存 wrapper 自身引用；`Core.ResetLua` 重載時重新包裝、
後載 MOD 整支替換時 `OnGameBoot` 復查把「他的版本」當新 original 再包一層。
與另兩檔同款，詳見 MDFX_ButcherMeatRatio 節。

### 驗證

`lua scripts/test_reload_speed_guard.lua` — 29 項，全綠。涵蓋：原函式成功時
完全透傳（不重算、不多寫變數、不印診斷）、已知壞形狀 fallback 三種精確值
（rack=false：`0.8+4×0.10−2×0.05=1.1`；rack=true：`0.8+5×0.04=1.0` 恐慌不參與；
駕駛：`×0.8`）、診斷恰一次、未知原因（手持槍械卻拋／辨識自身拋錯／空手拋錯）
原樣重拋且不寫變數、fallback 也炸整體退 1.0、`setVariable` 拋錯不外洩、
重複載入不疊、後載 MOD 替換後復查重裝（正常路徑透傳到替換版＋壞形狀恢復被擋）、
vanilla 缺席不亂補、成員快照。

**mutation 驗證**（`抽掉防線 → 對應檢查轉紅 → 還原全綠`）：

| 突變 | 轉紅 |
|------|------|
| 抽掉 `pcall` 保護 | 4 項（例外外洩、fallback 缺席） |
| 辨識永真（吞掉一切 exception） | 6 項（未知原因該重拋的全部失守） |
| fallback 係數 0.10→0.20 | 2 項（精確值 1.5≠1.1） |
| OnGameBoot 復查永遠自認在位 | 1 項（替換後 guard 未恢復） |

遊戲內：手持手電筒＋穿彈藥背帶對彈匣裝彈——修復前 log 出現
`Object tried to call nil in setReloadSpeed` 且裝彈無反應；修復後裝彈正常完成、
log 出現一行 `[MinidoracatFixes] setReloadSpeed crashed ... fallback`。
手持槍械正常裝彈速度不變。

### 可退場條件

官方在 :95 前檢查手持物是否槍械（`check_vanilla_alignment.py` 對
`instanceof(gun, "HandWeapon")` 形狀有 exithint），或改用基類安全的查法。

---

## MDFX_PetAnimalGuard — 撫摸動作 server 端解析不到動物

| 項目 | 內容 |
|------|------|
| 檔案 | `server/Fixes/MDFX_PetAnimalGuard.lua` |
| 影響版本 | Build 42.20.4 |
| 端 | server，且只在 `isServer()` 安裝（此形狀只存在於 server 端的封包重建；單人／客戶端的 `self.animal` 是 `new()` 當下的本地物件引用，不會是 nil） |
| 狀態 | **現役** |

### 症狀

MP 下撫摸動物，動物在 3 秒撫摸期間死亡／卸載／離開同步範圍：撫摸加成沒生效
（動物都沒了，本來就給不了），伺服器留下髒例外（正式服實測 1 次/輪）：

```
java.lang.RuntimeException: attempted index: petAnimal of non-table: null
  Lua(Vanilla).animEvent(ISPetAnimal.lua:88)
```

### 根因

server 以 `NetTimedAction.parse`（`NetTimedAction.java:142-171`）重建 action：
以 `new` 的參數名從封包反序列化引數（`:41-51` 用 prototype locvars 對應），
`ISPetAnimal.new(character, animal)` 的 animal 由序列化物件 id 解析，動物已
死亡／卸載時解析結果是 nil。`new()`（:95-101）只做欄位賦值所以照樣成功；
`serverStart()`（:81-84）不碰 `self.animal`，只註冊 3 秒後的模擬事件
（`emulateAnimEventOnce` → `AnimEventEmulator`，`LuaManager.java:12189`）。
3 秒到，`animEvent`（:86-93）在 :88 對 nil 解參考拋錯；之後 timeout →
`NetTimedAction.perform` → `complete()`（:69-72）同一行再炸一次
（protectedCall 包住，log 再髒一次）。

**vanilla 自己知道這形狀該怎麼防**——隔壁檔 `ISLoadBulletsInMagazine:serverStart()`
（:70-73）就有一模一樣的 guard：

```lua
if not self.magazine then self.netAction:forceComplete() return end
```

`ISPetAnimal` 少寫了這段。

### 修法

比照 vanilla 自家慣例，包裝三個 method（class 表替換；PZ fork 的
`KahluaTableImpl.rawget` 走 metatable 鏈——`KahluaTableImpl.java:98`——所以
Java 端 `serverStart`／`complete`／`animEvent` 的 rawget 派發都拿得到包裝版）：

| method | animal 為 nil 時 | 依據 |
|--------|-----------------|------|
| `serverStart` | 印一次診斷、`netAction:forceComplete()`、不註冊模擬事件 | 主閘，`ISLoadBulletsInMagazine:70-73` 同款 |
| `animEvent` | 只攔 `pettingFinished` 靜默略過；**其他 event 原樣透傳**（未來 vanilla 新增的行為照常暴露，本修復不隱藏未知問題） | 第二道保險 |
| `complete` | 回 `false` | `ISButcherAnimal:complete` 對「屍體被別人撿走」的 vanilla 先例（:51-53）；Java 端 `NetTimedAction.perform` 把 false 傳回 `ActionManager`（`ActionManager.java:64`），action 走 Reject 流程通知 client 移除——比回 true 更正確（`forceComplete()` 只更新 `endTime`，不代表成功） |

動物存在的正常撫摸三個 method 全部原樣透傳，零行為差異。
診斷每 session 只印一次（與另兩檔同款節流）。

**安裝機制**：0.6.0 起改走共用骨架 `shared/Fixes/MDFX_Guard.lua`——`isServer()`
閘門、形狀檢查（三個 method 都要在）＋一次性 `NOT installed` 診斷、marker 冪等
（錨在 `serverStart`，三個 method 同批安裝）、立即安裝＋`OnGameBoot` 復查、
診斷節流。行為與 0.5.0 相同，只多了 `isServer()` 閘門（單人不再安裝——那一端
本來就永遠不會觸發）。

### 驗證

`lua scripts/test_pet_animal_guard.lua` — 32 項，全綠。涵蓋：`isServer()` 為假
時零介入、動物存在時三個 method 全透傳、nil 時 serverStart 擋下＋`forceComplete`
恰一次＋診斷恰一次、`netAction` 也 nil 不炸、`pettingFinished` 靜默略過而其他
event 照常透傳、complete 回 false、重複載入不疊、後載 MOD 替換後復查重裝
（壞形狀恢復被擋＋正常路徑透傳到替換版）、vanilla 缺席／部分缺席不亂補、
成員快照。含對照組：stub vanilla 對 nil 動物確實拋錯。

**mutation 驗證**（`抽掉防線 → 對應檢查轉紅 → 還原全綠`）：

| 突變 | 轉紅 |
|------|------|
| serverStart 主閘拆掉 | 4 項 |
| complete 改回 true | 3 項 |
| animEvent 第二道保險拆掉 | 2 項 |
| `MDFX_Guard` 拆掉 `isServer()` 閘門 | 2 項 |
| `MDFX_Guard` 拆掉冪等 marker | 4 項 |
| `MDFX_Guard` 拆掉診斷節流 | 1 項 |

遊戲內：MP 撫摸動物並讓另一管理端立即移除該動物——修復前 3 秒後 server log
出現 `attempted index: petAnimal` 例外；修復後 log 出現一行
`[MinidoracatFixes] ISPetAnimal.serverStart: animal resolved to nil`、無例外。

### 可退場條件

官方在 `ISPetAnimal:serverStart` 補上與 `ISLoadBulletsInMagazine` 同款的
nil guard（`check_vanilla_alignment.py` 對 `if not self.animal then` 形狀有
exithint）。

---

## 0.6.0 的六條 server 端 vanilla 守衛 — 索引

六條都是同一型：dedicated server 的封包重建路徑（`NetTimedAction.parse`，
`NetTimedAction.java:142-171`）餵進 vanilla 沒防到的形狀，於是在 server 端拋錯。
共用骨架 `shared/Fixes/MDFX_Guard.lua` 負責 `isServer()` 閘門、形狀檢查＋
一次性 `NOT installed` 診斷、marker 冪等、`OnGameBoot` 復查、診斷節流。

**完整根因、取捨、行號出處與「為什麼不那樣修」都寫在各 `.lua` 檔頭**——這裡
只留索引，避免同一份推導維護兩份。爆點行與依賴符號登記在
`scripts/check_vanilla_alignment.py`（`MDFX_WorldObjectCheckWeapon` 42.21 退場後，改登記「官方修正仍在」的 4 條 retired 指紋：`ItemUtils.checkWeapon` 與三個呼叫點）。

| 修復 | 檔案（`server/Fixes/`） | 爆點 | 頻率 | 玩家可見後果 | 退場條件 | 測試 |
|------|------|------|------|------|------|------|
| MDFX_WorldObjectCheckWeapon | `MDFX_WorldObjectCheckWeapon.lua` | 全域 `ISWorldObjectContextMenu` 在 server 上是 nil；`ISDestroyStuffAction.lua:312`、`ISPickUpGroundCoverItem.lua:35`、`ISRemoveBush.lua:79` 無條件呼叫 `checkWeapon` | 20–140 次/天（最大單項） | 工具最後一擊用壞時動作沒收尾、壞工具不卸裝 | **42.21 已退場**：官方把 `checkWeapon` 搬成 `shared/Items/ItemUtils.lua` 的 `ItemUtils.checkWeapon`，三個呼叫點改呼叫它；偵測到就不安裝 | `test_world_object_check_weapon.lua`（37 項） |
| MDFX_MilkAnimalGuard | `MDFX_MilkAnimalGuard.lua` | `ISMilkAnimal.lua:70`（同形狀另有 `:92`、`stress():41`） | 爆發日 50–320 次 | 擠奶動畫演完、桶子沒有奶 | 判準改成「桶子存在**且**有流體容器」並修掉 `:41` | `test_milk_animal_guard.lua`（43 項） |
| MDFX_ConsolidateDrainableGuard | `MDFX_ConsolidateDrainableGuard.lua` | `ISConsolidateDrainable.lua:33` 扣來源、`:35` 目的物缺 `setUsedDelta` | 12 次/3 天 | **部分更新**：液體憑空消失、client 與 server 量不一致（本批唯一資產風險） | `:33` 之前驗兩邊型別，或 `setUsedDelta` 提到 `InventoryItem` 基類 | `test_consolidate_drainable_guard.lua`（41 項） |
| MDFX_ClothingExtraGuard | `MDFX_ClothingExtraGuard.lua` | `ISClothingExtraAction.lua:67`（`complete:125` 缺 `isValid:6` 那道 nil guard） | 9 次/3 天 | 換裝失敗＋髒堆疊（衣物本來也不在了） | `complete()` 入口補上 `isValid:6` 同款 nil guard | `test_clothing_extra_guard.lua`（26 項） |
| MDFX_MoveablesActionGuard | `MDFX_MoveablesActionGuard.lua` | `ISMoveablesAction.lua:308`（`place` 模式 `item` 為 nil） | 16 次/3 天 | 無——引擎本來就當「動作被拒」（`NetTimedAction.java:159-163`），只有 log 噪音 | `:308` 之前檢查 `item` | `test_moveables_action_guard.lua`（28 項） |
| MDFX_LockDoorsGuard | `MDFX_LockDoorsGuard.lua` | `ISLockDoors.lua:46` 對 `VehiclePart` 做 `..` | 2 次/8 天 | 車門只鎖到一半（邊走邊寫留下部分更新） | `:46` 的 `part` 包上 `tostring`（像 `:42`） | `test_lock_doors_guard.lua`（33 項） |

**`MDFX_WorldObjectCheckWeapon` 42.21 退場**：42.21 的 `ItemUtils.checkWeapon`（`ItemUtils.lua:16-34`）與舊版
`ISWorldObjectContextMenu.checkWeapon` 等價（含同一個 `isServer()` 分支），`ISWorldObjectContextMenu.checkWeapon` 整支刪除，
`ISDestroyStuffAction.lua:340-341`、`ISPickUpGroundCoverItem.lua:34-35`、`ISRemoveBush.lua:78-79` 改呼叫它。補丁在
`onServer` 先看 `ItemUtils.checkWeapon`，是 function 就不建立 server 端的 `ISWorldObjectContextMenu` 全域、不印診斷，
保留為 regression 保險（mutation：拿掉這道檢查 → [7b] 3 項轉紅）。正式服 42.21 第一場（約 3 小時）仍有一次
`checkWeapon called on the server`：原版已不呼叫舊名，呼叫者是 NicksSledgehammerFix（整支覆寫
`ISDestroyStuffAction:complete`，自帶 `if ISWorldObjectContextMenu then` 檢查）。退場後 server 上表是 nil，它照自己的
設計跳過換裝、不拋錯，回到本 MOD 0.6.0 之前的狀態；該 MOD 在 42.21 單人（客戶端有表、沒有 `checkWeapon`）會拋錯，屬它自己要跟進的改名。

### 共用骨架的驗證

`MDFX_Guard` 本身沒有獨立測試檔——它的每一項責任都被上面六支（＋
`test_pet_animal_guard.lua`）覆蓋，mutation 也直接打在 `MDFX_Guard.lua` 上：

| 突變（`MDFX_Guard.lua`） | 轉紅 |
|------|------|
| 拆掉 `isServer()` 閘門 | 七支測試的 [1] 段全紅（2–3 項/支，client／單人被介入） |
| 拆掉冪等 marker 比對 | 走 `wrap` 的六支全紅（2–4 項/支，wrapper 疊第二層） |

各守衛自己的防線 mutation 見下表（`抽掉防線 → 對應檢查轉紅 → 還原全綠`）：

| 修復 | 突變 | 轉紅 |
|------|------|------|
| （`MDFX_Guard`） | 拆掉診斷節流 | 七支各 1 項（log 洪水） |
| WorldObjectCheckWeapon | 「不覆蓋既有版本」的檢查拆掉 | 2 項後中斷（蓋掉別人的實作） |
| WorldObjectCheckWeapon | 耐久 gate `<= 0` 反轉成 `>= 0` | 3 項（正常路徑不再空轉） |
| WorldObjectCheckWeapon | 診斷節流拆掉 | 1 項 |
| MilkAnimalGuard | 形狀判準永真（吞掉一切） | 15 項 |
| MilkAnimalGuard | 形狀判準永假（守衛失效） | 12 項 |
| MilkAnimalGuard | 診斷節流拆掉 | 1 項 |
| ConsolidateDrainableGuard | 型別判準永真（守衛失效） | 14 項（部分更新全部復發） |
| ConsolidateDrainableGuard | 只驗來源、不驗目的物 | 11 項 |
| ConsolidateDrainableGuard | `complete` 那道防線拆掉 | 3 項 |
| ClothingExtraGuard | nil 判準拆掉 | 7 項 |
| ClothingExtraGuard | 回傳值改成 true（不走 Reject） | 2 項 |
| MoveablesActionGuard | 形狀判準拆掉 | 7 項 |
| MoveablesActionGuard | 判準少了 `mode == "place"` 這半 | 2 項（其他模式被誤擋） |
| LockDoorsGuard | 無門部件的預掃拆掉 | 9 項 |
| LockDoorsGuard | 中止改成照樣呼叫原函式（恢復部分更新） | 9 項 |
| LockDoorsGuard | 回傳值改成 true | 2 項 |

### 殘留風險

`ISConsolidateDrainable` 實際被當成目的物的是什麼型別，log 判斷不出來
（只知道它沒有 `setUsedDelta`）。玩家實際損失量要在隔離環境實測才能宣稱，
不做量化推測。

---

## MDFX_FarmingSyncDedupe — 原版農作物同步改成「有變才送」

| 項目 | 內容 |
|------|------|
| 檔案 | `server/Fixes/MDFX_FarmingSyncDedupe.lua` |
| 影響版本 | Build 42.20.4 |
| 端 | server，只在 `isServer()` 安裝（單人的 `transmitModData` 本來就不送，`IsoObject.java:4805-4815`；客戶端不載入 `SPlantGlobalObject`） |
| 類型 | **不是例外**，是原版的重複同步：內容沒變也照送 |
| 狀態 | **現役**（42.20.4-0.7.0 起） |

### 症狀

多人伺服器上，玩家走過農地時伺服器出向流量明顯墊高。正式服唯讀抓包（60 秒出向）
裡含作物 modData 鍵名的封包 6,952 個、5.2 MB，佔出向 3.4%；其中 6,918 個是地圖內建
枯作物（`state=destroyed`、名稱「Destroyed Farming_none」）的載入時重送，幾乎全送給同一位
正在穿越農地的玩家、整分鐘約 100 包/秒。同批另外三份較短取樣佔 0.6–0.9%。

### 根因

伺服器在兩個時機把作物的名稱、sprite、整份 modData 無條件重送給範圍內所有連線
（`GameServer.java:2887-2890`、`:2899-2905` → `INetworkPacket.sendToRelative:173-182`；
範圍是連線的 chunk map＋`relevantRange` 8–12 chunk，`UdpConnection.java:211-232`、
`GameServer.java:2772-2773`）：

1. **載入時**。`SPlantGlobalObject:stateFromIsoObject`（`server/Farming/SPlantGlobalObject.lua:43-56`）
   與 `stateToIsoObject`（`:58-87`）在 `isServer()` 時固定送三包（`:51-55`、`:82-86`）。
   呼叫者是 `SGlobalObjectSystem:loadIsoObject`（`server/Map/SGlobalObjectSystem.lua:133-149`）；
   `MOFarming.lua:126-137` 把枯作物 `vegetation_farming_01_13/14` 與各作物的 sprite／unhealthy／
   dying／dead 四組 sprite 掛在 `MapObjects.OnLoadWithSprite`，所以伺服器每載入一個 cell
   （`ServerMap.java:950-956` RecalcAll2 → `IsoChunk.java:3825` `MapObjects.loadGridSquare`），
   格內每株作物三包。
   - 這三包沒有人收得到：伺服器只卸載「沒有任何連線 `isRelevantTo`」的 cell
     （`ServerMap.java:539`、`:589-615`），客戶端的 chunk 要等伺服器端 `loaded` 後才從
     記憶體現場序列化（`PlayerDownloadServer.java:158-164`、`:234`）。載入當下沒有客戶端
     持有這個 chunk，封包被 `ObjectModDataPacket.parse` 以 object is null 丟掉（`:50-56`），
     客戶端之後拿到的 chunk 本來就含載入後的狀態。
   - `stateFromIsoObject` 本身只讀 iso object、不寫，那三包只是 `:48-49` 註解說的
     「MapObjects 載入程式可能改過 iso object」保險，而那也發生在同一個 chunk 載入流程裡。
2. **定期**。`SFarmingSystem:EveryTenMinutes`（`SFarmingSystem.lua:87-128`）每次都
   `checkPlant` → 每株非 destroyed／harvested 作物 `checkPlant2`（`:264-290`）→
   最後無條件 `saveData`（`SPlantGlobalObject.lua:771-777`）→ `transmitModData`（`:775`）。
   翻土、枯死、腐爛的作物值不會變，照樣每 10 遊戲分鐘整份重送。地圖內建枯作物還沒被踩過時
   `NewDestroyed` 寫的是 `state = "destroy"`（`MOFarming.lua:43`），`isAlive()` 把它當活的，
   所以它們也在這條路上。

`ObjectModDataPacket` 每次送整份 modData（`:38-47`），客戶端載入前先 wipe
（`KahluaTableImpl.java:292-294`）；一株作物約 22–26 個鍵、0.5–0.8 KB。

### 修法

只在 `isServer()` 安裝，而且**只包原版自己的函式**：`getFilenameOfClosure`
（`LuaManager.java:7321-7323`）要指向原版 `SPlantGlobalObject.lua`、路徑不含 `/mods/`
（與 `LuaClosure.java:170` 判斷 Vanilla／MOD 的方式相同）。別的 MOD 已覆寫的 method 不碰、
印一行 `NOT installed`——這個 wrapper 會擋掉原函式的送包，包到別人的版本等於吞掉對方的同步。
三個 method 各自判斷、各自安裝。

| method | 原版 | 修正後 |
|---|---|---|
| `stateFromIsoObject`／`stateToIsoObject` | `isServer()` 時固定送 NAME、SPRITE、modData | 原函式本體照跑，但用 `setfenv` 給它一張自己的全域表，本體裡的 `isServer()` 回 false、那三包不送（`BaseLib.java:152-180`：只改這一個 closure 的 env；`KahluaThread.java:272-275` GETGLOBAL 查 `closure.env`，它呼叫的其他函式不受影響）。wrapper 比對呼叫前後，名稱變了送 NAME、sprite 物件換了送 SPRITE、modData 內容變了送 modData，順序同原版 |
| `saveData` | 無條件 `transmitModData` | 先做原版的 `toModData`（`:774`）；「寫入前後相同」**而且**「和這一格上次實際送出的相同」才不送，其餘交給原函式照原版送 |

幾個判準的理由：

1. **`saveData` 不能只比寫入前後**。`setSpriteName`／`setObjectName`（`:108-121`、`:93-106`）
   先把整份 modData 寫進 iso object 卻只送 SPRITE／NAME（`:118`、`:103`），播種（`:732-733`）、
   生長（`SFarmingSystem.lua:288-289`、`farming_vegetableconf.lua:124-128`）、枯死與踩爛
   （→ `deadPlant` 的 `:765`）都是這樣接著 `saveData`。到了 `saveData` 裡寫入前後幾乎總是相同，
   只比前後會把這些真正有變的同步全部吞掉（離線突變實測：8 項轉紅）。所以基準是「上次實際送出」。
2. **寫入前後也要比**。客戶端送來的 `ObjectModData` 會先改掉伺服器的 iso modData 再轉給其他人
   （`ObjectModDataPacket.java:50-96`），`toModData` 蓋回原值之後只有「寫入前」看得到差異。
3. **sprite 比物件本身**。`setSpriteFromName` 不更新 `spriteName` 欄位
   （`IsoObject.java:1979-1982`、`getSpriteName` 的 `:2235-2237`），用名稱比會漏掉 sprite 變化。
4. **比內容不比 table identity**。照 `KahluaTableImpl.save`（`:210-231`、`:379-401`）實際會上線的
   型別（鍵 string／number，值 string／number／boolean）組成帶長度的字串、排序後比較，跟走訪
   順序無關、分得出 `"1"` 與 `1`。遇到巢狀 table 或比對本身拋錯就當「看不出來」，照原版送。

不做陷阱與營火：陷阱（`STrapGlobalObject.lua:30-98`）載入時同款三包，但數量遠少於作物、
modData 帶巢狀 `zones`，抓包裡沒有它的份量；點燃的營火每遊戲分鐘 `fuelAmt` 都在變
（`SCampfireSystem.lua:135-145` → `SCampfireGlobalObject.lua:262-263`），「有變才送」省不到，
要省只能降頻，那會讓客戶端看到舊的燃料量。

**安裝機制**：`MDFX_Guard.onServer`（立即一次＋`OnGameBoot` 復查）。本 session 裝過的 method
記下來之後就不再動：後載 MOD 包了我們或換掉我們，都不接回去。`Core.ResetLua` 重載時 vanilla
重建 class、本檔重跑，重新安裝。

### 殘留風險

- **基準表**按座標存上次送出的 modData 指紋（一格一條幾百字元的字串），本 session 不清；
  上限是本 session 走過 `saveData`（且當時 iso object 在記憶體裡）的作物格數；地圖內建枯作物還是
  `destroy` 狀態時每 10 遊戲分鐘都會走、會佔一格，踩爛成 `destroyed` 之後就不再走定期那條。
- **被踩爛的地圖枯作物仍會送 SPRITE**。`typeOfSeed = "none"` 的作物被踩時 `destroyThis` 取不到
  sprite，原版 `setSpriteName(nil)` 把 luaObject 的 `spriteName` 變成 nil；之後每次載入，引擎照
  iso 的 `spriteName` 欄位另建一個 sprite（`IsoObject.java:1301-1303`），`stateToIsoObject` 又
  `setSpriteFromName(nil)` 換成無名 placeholder（`IsoSpriteManager.java:47-48`、`:77-81`），sprite
  物件每次都真的換了。照「有變才送」規則仍送這一包小的 SPRITE，NAME 與 modData 不送。
- **客戶端自己改的本地 modData 不會再被定期覆蓋**。原版每 10 遊戲分鐘整份重送，順帶把客戶端的
  本地改動蓋回去；修正後只有伺服器端真的有變才送。原版客戶端不改作物 modData（`CGlobalObject.lua:46-50`
  只讀），只有自己改又不送的第三方 MOD 會看到差異。
- **GOS 新增物件的廣播不在範圍內**：新建作物 luaObject 時 `newLuaObjectOnClient` →
  `addGlobalObjectOnClient` 送給**所有**連線（`SGlobalObjectNetwork.java:91-103` → `sendPacket` `:39-62`），
  每株作物一生一次、內容只有座標（farming 沒設 `objectSyncKeys`）。

### 驗證

`lua scripts/test_farming_sync_dedupe.lua` — 58 項，全綠。涵蓋：`isServer()` 為假時零介入（連原函式的
全域表都不動）、安裝只換三個 method 不加成員、載入時沒變零封包而原版同狀態固定三包（對照組）、
名稱／sprite 物件／modData 各自變化只補送那一項且順序同原版、`stateFromIsoObject` 零封包、
`saveData` 無基準照送／沒變不送不呼叫原函式、`setSpriteName`／`setObjectName` 之後的
`saveData` 必須送、iso modData 被外部改寫（客戶端轉送、MOD 直寫額外鍵）必須送、指紋與走訪順序
無關、分得出 `"1"` 與 `1`、不上線的值變動不算變、巢狀 table 與比對失敗照原版送、基準按座標分開、
原函式拋錯原樣外洩、別的 MOD 覆寫的 method 不碰（含 Windows 反斜線路徑的原版判斷）、形狀不符不裝、
本檔重跑與 `OnGameBoot` 不疊、後載 MOD 換掉後不接回去、診斷一 session 一次。

**mutation 驗證**（`抽掉防線 → 對應檢查轉紅 → 還原全綠`）：

| 突變 | 轉紅 |
|------|------|
| `saveData` 只比寫入前後（交接提案的判準） | 8 項（播種、`setObjectName` 後、額外鍵、無基準首送全部漏掉） |
| `saveData` 只比上次送出、不比寫入前 | 1 項（客戶端轉送後不蓋回） |
| 不送的路徑不做 `toModData` | 2 項 |
| 拿掉 `setfenv`（原函式照送三包） | 7 項 |
| 載入時不比名稱／不比 modData | 各 2 項 |
| sprite 改比 `getSpriteName` | 2 項 |
| 指紋不排序／巢狀 table 當成不上線／不分字串與數字 | 1／2／1 項 |
| 指紋拿掉 `pcall` | 3 項（例外外洩） |
| 來源判斷永真／不看 `/mods/`／不正規化反斜線 | 4／3／1 項 |
| 拿掉 `installed` 冪等 | 1 項（復查把自己的 wrapper 當成別人的） |
| （`MDFX_Guard`）拆掉 `isServer()` 閘門／診斷節流 | 3／4 項 |

**實機**（`fixes-e2e` 的 `farming-sync`，no-Steam 專用伺服器＋MP 客戶端，同一份情境跑兩輪：
對照組把修正檔從該輪快照拿掉＝原版，修正組照常）。在 Muldraugh 蓋 30 株作物（翻土、生長中、
枯死、踩爛各 6，另 6 株仿地圖內建枯作物），離開到伺服器卸載再回來算一次 cell 載入，數伺服器端
實際呼叫的送包；10 分鐘週期在客戶端的本地 modData 放哨兵，收到 `ObjectModData` 會被整份 wipe。

| 量測 | 原版（對照組） | 修正後 |
|---|---|---|
| 第一次重載（仿地圖作物走 `stateFromIsoObject`，其餘 `stateToIsoObject`），18 次載入呼叫 | 54 包（3×18） | 0 包 |
| 第二次重載（仿地圖作物一半踩成 `destroyed`），18 次載入呼叫 | 54 包 | 3 包（只有被踩爛的 "none" 枯作物的 SPRITE，見殘留風險） |
| 10 分鐘週期 `saveData`（翻土／生長中／枯死／`destroy` 狀態） | 84 次呼叫、84 包 | 63 次呼叫、0 包 |
| 客戶端哨兵保留（沒收到重送） | 翻土 0／6、枯死 0／6 | 全部 6／6 |

兩輪都驗了澆水、施肥、生長、播種（翻土→播種）、踩爛、枯死、踩爛地圖枯作物（`destroy`→
`destroyed`，名稱變、sprite 不變）七種變化：每一種伺服器端都真的變了，客戶端的名稱、sprite、
modData 在下一次輪詢（約 0.5 秒）就與伺服器逐鍵相同。修正組伺服器 log 有 `installed` 與兩行
首次 skip 診斷；兩輪收回的 console 都沒有 Lua 例外（只有開機期固定雜訊與原版 `MOWoodenWalFrame`
的 `IsoThumpable not found`，對照組同樣出現）。

### 可退場條件

官方把載入時的三包與 `saveData` 的送包改成比對後才送，或拿掉載入時那三包。
遊戲更新後跑 `python scripts/check_vanilla_alignment.py`：`:43-56`、`:58-87` 的本體（`isServer()`
只用在結尾三包、之後直接結束）、`:771-777` 整個 `saveData` 本體、`MOFarming.lua` 的載入註冊、
`SFarmingSystem.lua` 的定期觸發，任一改變都會 CHANGED，要人工重核。

---

## 農作物存檔三件 — `MDFX_FarmingGosPrune`／`MDFX_FarmingClockBackup`／`MDFX_FarmingStallHeal`

| 項目 | 內容 |
|------|------|
| 檔案 | `server/Fixes/MDFX_FarmingGosPrune.lua`、`MDFX_FarmingClockBackup.lua`、`MDFX_FarmingStallHeal.lua` |
| 影響版本 | Build 42.20.4 |
| 端 | server：dedicated server 與單人都生效（存檔機制兩邊相同）；MP 客戶端在檔頭 `isClient()` 早退 |
| 類型 | **原版存檔上限造成的整份資料遺失**，以及它的兩個後遺症 |
| 狀態 | **現役**（42.20.4-0.8.0 起） |

三支各有一個獨立的缺陷與退場條件，但來自同一次事故，放在同一節。每支的完整推導、行號出處
與「為什麼不那樣修」寫在各自的 `.lua` 檔頭；這裡記事故、決策與驗證。

### 症狀（正式服唯讀調查）

- 某次例行存檔時伺服器記錄連續 6 次 `BufferOverflowException`（堆疊經過 `KahluaTableImpl.save`），
  `gos_farming.bin` 變成 0 byte；下一次開機 `SGlobalObjectSystem.load> Exception thrown`
  （`newLimit < 0: (-1 < 0)`），農作物系統從空狀態啟動。
- 事故前 4 小時的備份裡，檔案從 7.67 MB（15,412 個物件）長到 9.93 MB（20,100 個，
  上限的 94.7%）。新增的 4,724 個有 2,470 個集中在同一個 256×256 區域，是地圖內建農田第一次被
  載入時整片登記。20,100 個裡 destroyed 70%、rotten 14%、seeded 6%、dead 4%、plow 2%、
  harvested 2%。
- 清空後作物隨玩家移動重新登記。之後的檔案裡 241 株生長中作物有 189 株的 `nextGrowing`
  比時鐘多約 30,900 小時；其中 4 株在這一局被澆過水，原版的補救已經觸發不了。

### 根因

1. **存檔撐破固定緩衝、而且先截斷檔案**（`MDFX_FarmingGosPrune` 處理累積、`MDFX_FarmingClockBackup`
   處理後果）。`SGlobalObjectSystem.save()`（`SGlobalObjectSystem.java:273-298`）在 `:279` 先開
   `FileOutputStream`，才往 10,485,760 byte 的 `SliceY.SliceBuffer`（`SliceY.java:10`）序列化；溢出的
   例外在 `:294` 被吞掉，檔案停在 0 byte。原版把載入過的每株作物永久留在檔案裡，會移出的只有
   `plowFadeCheck`（`SFarmingSystem.lua:253-262`：30 天後、有載入時、每 10 遊戲分鐘 1/20000），
   實際上只增不減。
2. **時鐘歸零**。時鐘 `hoursElapsed` 只存在這個檔案（`SFarmingSystem.lua:27`），讀不到時
   `:11` 把它設成 0；從地圖物件重新登記的作物帶著舊時鐘的 `nextGrowing`。
3. **原版補救有缺口**（`MDFX_FarmingStallHeal`）。補救只寫在 `stateToIsoObject`
   （`SPlantGlobalObject.lua:66-76`），第一次重新登記走的 `stateFromIsoObject`（`:43-56`）沒有；
   觸發條件 `lastWaterHour > hoursElapsed` 一遇到下雨（`SFarmingSystem.lua:309`）或澆水
   （`SPlantGlobalObject.lua:513`）就失效。
4. **踩爛／已收成作物回不來**（`MDFX_FarmingGosPrune` 的重建部分）。它們用 `trampledSprite`，
   `MOFarming.lua:126-137` 沒替這組註冊 OnLoad（394 個名稱，與已註冊的四組零重疊）；失去 GOS
   登記後農作選單（`ISFarmingMenu.lua` 一律 `getLuaObjectOnSquare`）找不到，那格無法移除或翻土。

### 修法

| 修復 | 做什麼 | 關鍵判準 |
|---|---|---|
| `MDFX_FarmingGosPrune` | ① 常駐重建：對每種作物的 trampledSprite／deadSprite 註冊 OnLoad（priority 4242），格子載入時地圖物件是 destroyed／harvested／dead／rotten、`modData.spriteName` 等於畫面 sprite、這格沒有 luaObject，就 `fromModData` 原樣重建並通知客戶端。② 移出：每 10 遊戲分鐘掃一次，所在格沒載入的這四種作物，先前在載入時確認過「地圖物件能重建出逐鍵相同的條目」、之後沒變，連續兩次掃到且相隔 ≥30 秒真實時間，才用原版 `removeLuaObject` 移出，每次最多 100 株 | 只移出 hook 一定能重建成一模一樣的；伴生作物（`nbOfGrow >= 3` 且有 `*Bane`）與 `-nosave` 不移出 |
| `MDFX_FarmingClockBackup` | 每 10 遊戲分鐘把時鐘抄進 GlobalModData；開機時 `loadedWorldVersion()` 還是 -1（沒讀完）且備份比現在大就還原 | 備份與 GOS 同一輪存檔；新世界沒有備份 |
| `MDFX_FarmingStallHeal` | 包 `checkPlant2`：生長中作物 `lastWaterHour` 領先時鐘，或 `nextGrowing` 遠過原版在任何沙盒下排得出來的上限（`max(T) × 10 + 12`，原版 14,952 小時），就把 `nextGrowing` 拉回 `hoursElapsed + timeToGrow` | 只會提前、不會延後；`lastWaterHour` 領先才重設；排程函式被別的 MOD 換掉時遠期判斷關閉 |

**設計審查**（實作前交給 oracle 對照原版與反編譯原始碼逐條核對，C 直接通過，A、B 依意見修改後通過）：

- B 的移出判準與重建 hook 共用同一個 `rebuildable`：`fromModData` 在 `modData.spriteName` 為 nil 時
  會自己補值（`SPlantGlobalObject.lua:807-809`），只比重建結果會把 hook 拒絕重建的作物也移出，
  從此回不來。
- B 排除伴生作物：`diseaseThis`（`SFarmingSystem.lua:396-405`）替鄰格擋病蟲害時只看鄰居
  `nbOfGrow >= 3` 與 `*Bane`、不看 state，收成過的洋蔥、大蒜田在原版會一直保護旁邊的活作物。
  原版 55 種作物有 11 種帶 bane。
- B 的 priority 從 6 改成 4242：同 priority 會互相取代（`MapObjects.java:148-151`），6 是
  「比原版高一格」最常見的選擇，被別的 MOD 取代時 hook 會靜默消失。
- B 的等待理由是 `ServerChunkLoader` 的競態：已被存檔執行緒拿走、正在寫的 chunk 不會被之後的讀取
  等待；再加 30 秒真實時間，是因為全員睡覺快轉時 10 遊戲分鐘可能不到 1 秒。
- A 只往前調：時鐘由 C 還原後，最後一次存檔之後才卸載的 chunk 可能帶著略新的 `lastWaterHour`，
  照原版無條件寫會把本來幾小時後就要長的作物往後延幾百小時。

### 與原版的差異與殘留風險

- **移出期間，dead／rotten 每 10 遊戲分鐘 1/5000 變成 destroyed 的外觀轉換暫停**，格子再載入後照常。
  這也讓它們較晚進入 `plowFadeCheck` 的清除範圍。這是本 MOD 唯一看得到的行為差異，使用者已同意。
- **移出之後 chunk 是唯一的來源**：chunk 存檔失敗（`ServerChunkLoader.java:449-463` 只記 log；
  `IsoChunk.java:4280-4282` 先記 checksum 再寫檔，之後同內容的存檔會被跳過），或改過的客戶端在最後一次
  掃描到卸載之間改了那格的 modData（`ObjectModDataPacket.java:21-27,46-58` 不驗來源），重建出來的就是
  那份內容。原版客戶端不送農作物 modData。
- **整個 MOD 移除時**，被移出、所在區域之後沒再載入過的踩爛／已收成作物會變回原版的孤兒；
  dead／rotten 會由原版 `LoadPlant` 走 `stateFromIsoObject` 重新登記。移出部分可以先單獨退場，
  重建部分要等官方替 trampledSprite 註冊 OnLoad。三份 Workshop 描述都有寫。
- **效益只及於本 session 載入又卸載過的區域**，而且 `spriteName` 為 nil 的條目永遠不移出
  （例如還沒播種就被踩的翻土格：`trampledSprite["none"]` 不存在，`getSpriteName` 回 nil）。
  事故時的 20,100 個物件裡，這類 destroyed 有 236 個。
- **重建時的新增封包送給所有連線**，一個 cell 載入的封包數＝該 cell 被移出的作物數×連線數；
  移出每次最多 100 株，重建端沒有上限。
- **原版翻土格（`vegetation_farming_01_1`）也沒註冊 OnLoad**，失去 GOS 登記後同樣回不來；
  它不在移出範圍、也不是本節三支要修的，E2E 第二場次只記數量不判定。

### 驗證

離線測試（假環境照原版形狀，mutation 一律「抽掉防線 → 轉紅 → 還原後 sha256 相同」）：

| 測試 | 項數 | mutation（全部轉紅） |
|---|---|---|
| `test_farming_gos_prune.lua` | 108 | 拿掉伴生檢查、`isNoSave`、兩次掃描等待、30 秒下限、移出前再比一次、驗證時的比對、`rebuildable` 的 spriteName 檢查、只認註冊過的 sprite、每次上限、hook 的「已有 luaObject」檢查、hook 的狀態檢查、失敗時的回滾、priority 改回 5、逐種 pcall，共 14 項 |
| `test_farming_clock_backup.lua` | 38 | 拿掉 `isClient` 閘門、`loadedWorldVersion` 判斷、「備份比時鐘大」判斷、備份型別檢查、record 的 `checked` 防線、`checked = true`、兩處 pcall、instance 型別檢查，共 10 項 |
| `test_farming_stall_heal.lua` | 72 | 拿掉 seeded 判斷、兩個觸發條件、LIMIT 的 ×10／+12／+50／rotTime、FastGrow、pcall、marker、「只往前」、「lastWaterHour 領先才重設」、原版來源檢查（整段、`/mods/`、反斜線、大小寫、檔名、pcall）等，共 32 項 |

`python scripts/check_vanilla_alignment.py` 為三支登記了爆點、依賴符號與公式係數（`SandboxOptions.java:232`
的 FarmingSpeedNew 下限 0.1 是 Java，腳本查不到，記在 `MDFX_FarmingStallHeal.lua` 檔頭）。

**實機**（`fixes-e2e` 的 `farming-gos`，no-Steam 專用伺服器＋MP 客戶端，同一輪兩個場次；另跑一次單人）：
時鐘先設 30000 模擬老伺服器，在 Muldraugh 蓋 25 株（生長中 4、枯死 4、腐爛 4、踩爛 4、已收成 4、翻土 2，
另 3 株 `nextGrowing` 設在 30,900 小時後，其中 1 株 `lastWaterHour` 也領先時鐘）。

| 場次 | 做什麼 | 結果 |
|---|---|---|
| 1 | 一次 `EveryTenMinutes` | 3 株錯位作物拉回 432 小時後（`timeToGrow`），4 株健康作物 `nextGrowing` 不變；時鐘備份＝30000 |
| 1 | 傳送 828 格外、伺服器卸載農地後每 10 秒掃一次 | 35–45 秒後四類 16 株全部移出，其餘 9 株留著；附近地圖農田的 102 株枯／腐作物一起移出（第一批剛好 100）；客戶端鏡像只少了這些 |
| 1 | 回到農地 | 16 株重建，26 鍵與離開前逐一相同；客戶端鏡像補回；客戶端地圖物件的名稱／sprite／modData 與伺服器一致 |
| 1→2 | RCON quit 正常存檔，把 `gos_farming.bin` 截成 0 byte | 開機出現與正式服同一行 `SGlobalObjectSystem.load> … newLimit < 0: (-1 < 0)` |
| 2 | 開機＋回到農地 | 時鐘 0 → 30000（`loadedWorldVersion = -1`）；四類 16 株由 hook 重建、與上一場次逐鍵相同；7 株生長中作物（原版 `LoadPlant` 重新登記）沒有一株卡在舊時鐘；翻土格 0/2（原版缺口，見上） |

單人跑第一場次同樣全部通過（25 項）。MP 兩個場次的伺服器 log（`SERVER STARTED` 之後）與兩種模式的客戶端 log 都沒有
`already an object at`、`NOT installed` 或堆疊帶本 MOD 路徑的例外。

### 可退場條件

- `MDFX_FarmingGosPrune` 移出：官方讓 GOS 存檔不再受 10 MiB 緩衝限制，或不再先截斷檔案。
  重建：官方替 trampledSprite 註冊 OnLoad。
- `MDFX_FarmingClockBackup`：官方讓讀檔失敗不再把時鐘歸零（或存檔不再留下 0 byte 檔）。
- `MDFX_FarmingStallHeal`：官方在 `stateFromIsoObject` 也補上時鐘補救、補救不再只看 `lastWaterHour`；
  或讀檔失敗不再讓時鐘歸零。

遊戲更新後跑 `python scripts/check_vanilla_alignment.py`，任一條 CHANGED 都要人工重核。

---

## MDFX_StaleRoomGuard — 自建建築改建後，指著已移除房間的格子讓客戶端斷線

| 項目 | 內容 |
|------|------|
| 檔案 | `client/Fixes/MDFX_StaleRoomGuard.lua` |
| 影響版本 | Build 42.20.4（42.21 已由官方修正成因） |
| 端 | client：MP 客戶端與單人都生效；專用伺服器不執行（爆點與成因都在 `!GameServer.server` 分支，本檔在 `client/`） |
| 類型 | 原版留下的**壞格子資料**，在原版讀到之前修好；不包裝任何原版函式 |
| 狀態 | **已退場**（42.21 官方修正成因；補丁沒有失效格子時不做事，保留為 regression 保險） |

### 症狀（正式服唯讀調查）

- 玩家回報「靠近某棟玩家建築就跳錯並被踢出伺服器」「在那裡拆牆或蓋牆就一直跳錯然後斷線」。
  伺服器連線紀錄是客戶端自己送出的斷線（`disconnection-notification`），伺服器沒有踢人；
  同一棟建築附近的玩家約 3 小時內各斷線十多次，常常 2–4 人在幾秒內一起斷線。
- 玩家 `console.txt`：

  ```
  ERROR: General ... IngameState.updateInternal> Exception thrown
    java.lang.NullPointerException: Cannot invoke "zombie.iso.RoomDef.getArea()" because the return value of
    "zombie.iso.areas.IsoRoom.getRoomDef()" is null at ParameterFirearmRoomSize.getRoomSize(ParameterFirearmRoomSize.java:42).
      ... IsoGameCharacter.updateEmitter ← IsoPlayer.updateInternal2 ← IsoCell.ProcessObjects
  LOG  : Lua ... removing all player data
  LOG  : General ... STATE: exit zombie.gameStates.IngameState
  ```

- 同一份 log 前面大量的 `Error with packet of type: ItemStats`（`ContainerID.findObject` 的 `containingItem`
  是 null）只是噪音：`GameClient.mainLoopDealWithNetData` 對單一封包的例外只記錄並丟掉那個封包
  （`GameClient.java:562-581`），不會斷線。

### 根因（兩層，行號為 42.20.4 反編譯快照）

1. **爆點**：`ParameterFirearmRoomSize.getRoomSize`（`:38-39`）對玩家腳下格子的房間直接
   `getRoomDef().getArea()`，沒有 null 檢查。客戶端每一幀替每一位玩家（本地與遠端都算，
   `IsoPlayer.java:2135-2136` 的 `if (!GameServer.server) updateEmitter()`）更新聲音參數時都會算它；
   例外傳到 `IngameState.updateInternal`，原版存一份當機副本後 `doDisconnect("crash")`
   （`IngameState.java:1553-1588`）。所以只要一位玩家站在這種格子上，所有看得到他的客戶端會同時斷線。
2. **成因**：牆／地板變動後，客戶端的 `WorldRegionToMetaGrid.clientProcessBuildings`（`:59`）把附近的
   自建建築整批移除再重建。移除時 `removeIsoRoom`（`:432-434`）把舊房間的 `def` 設成 null，之後的
   `updateSquares`（`:601-610`）卻只重設被標記的區塊；標記只來自「仍掛著建築的區域」
   （`removeUserDefinedBuildingsFromCell`，`:206-214`）與新建築的區域。區域資料又是兩份 `DataRoot`
   輪流交換（`IsoRegions.java:206-214`），建築只指派給當時上線的那一份，而 `processDirtyChunks`
   重算前還會先清掉變動區塊的建築（`DataRoot.java:200`）——拆牆後房間不再封閉時，原本房間的格子常常
   一格都沒被標記：`roomId` 還是舊值，`getRoom()`（`IsoGridSquare.java:9643-9645`）回傳那個 `def` 已是
   null 的舊房間。實機 E2E：3×3 房間拆掉一面牆，9 格全部變成這種狀態。

### 修法

在 `OnTick` 修好每位玩家周圍的失效格子。引擎每一幀依序是 `IsoCell.update`（玩家移動、讀聲音參數＝爆點）
→ `IsoRegions.update`（重建房間＝失效格子在這裡產生）（`IsoWorld.java:2935-2937`）→ Lua `OnTick`
（`IngameState.java:1507`、`:1534`），`OnTick` 剛好落在「產生」與「下一幀讀取」之間。

- **修什麼**：格子的房間 `getRoomDef()` 是 nil，而且地圖上這個位置已經沒有房間（`IsoMetaGrid.getRoomAt` 回 nil）
  → `setRoomID(-1)`，再 `RecalcProperties()` 讓室外旗標跟著更新（`IsoGridSquare.java:7703`）。這就是原版
  `updateSquares` 對有被標記的格子做的事。地圖上仍有房間的形狀不該出現，遇到就不動、印一行診斷：
  房間 id 大於 2^53（`RoomID.java:4-7`），經過 Lua 數字會失真，不自己拼回去。
- **什麼時候查**（不是每幀掃描）：
  1. 每位玩家每幀只比對腳下格子換了沒（MP：`getOnlinePlayers()` 清單的 `get` ＋ `getCurrentSquare`，
     每人 2 次 Java 呼叫；清單是 `GameClient` 快取、5 秒沒更新的遠端玩家會被移出，`GameClient.java:520-530`、`:1614-1623`）。
  2. 換格子時檢查新位置上下三層、周圍 3×3 共 27 格。一幀移動不到一格，腳下與下一步踩得到的格子永遠是檢查過的。
  3. 房間只會在重建時失效，而重建前一定交換 `DataRoot`；兩份各有自己的 `DataChunk` 物件（`DataRoot.java:18-66`），
     所以每幀只問一次某個已知區塊的 `IsoRegions.getDataChunk` 是不是同一個物件，換了就重新檢查所有玩家周圍。
     MP 客戶端的區域資料是全伺服器的（登入時要完整資料，之後伺服器對所有連線廣播變動，
     `IsoRegionWorker.java:305-331`），任何一處施工都會觸發交換，重新檢查的成本見下表。
  4. 還沒找到任何區域資料時，每 30 幀在玩家所在與相鄰區塊找一次；找到的當下全部重新檢查一次
     （它可能在被看到之前就重建過）。
- 自己出錯：`pcall` 包住，印一行 `disabled for this session` 後本次開機停用，不外洩、不洗版。

### 效能（實機量測）

多人客戶端（42.20.4，E2E `stale-room --define mode=bench`）在遊戲裡直接呼叫補丁的每幀函式，以
`getTimestampMs` 量 1 萬–20 萬次取平均、扣掉空迴圈。GameProfiler 的 span 只到 `Lua - OnTick` 這一層，
分不出單一 callback 的次微秒成本，所以用放大量測。量測時同一台機器還有其他 PZ 程序在跑（非獨佔），數字偏保守。

| 項目 | 成本 |
|------|------|
| Java 呼叫（getSquare／getRoom／getCurrentSquare） | 0.19／0.14／0.12 µs |
| 每幀固定成本：1／10／30 位玩家 | 1.5／6.7／28.9 µs |
| 玩家換格子時的 27 格檢查（每次） | 13.8 µs |
| 最壞情況：10 位玩家每幀都換格子 | 138 µs／幀 |

60 FPS 一幀 16,700 µs：平常 10 位玩家約 0.04%，30 位約 0.17%。一般走動每人每秒換 2–5 格，10 人約每幀 0.5 次檢查（約 7 µs）。
區域資料交換時的全面重新檢查＝玩家數 × 13.8 µs，只發生在有人施工的那一幀。

### 已知限制

- 一幀內移動超過一格（傳送、網路校正、極快的載具）時，落點若剛好是失效格子，仍會走原版的崩潰路徑。
- 只修玩家周圍的格子；沒有玩家靠近的失效格子留著不動（原版只在有人站上去時才會出錯）。

### 驗證

`lua scripts/test_stale_room_guard.lua` — 34 項，全綠。假引擎照每一幀的順序（玩家移動並讀腳下房間 →
區域資料交換與重建 → OnTick）跑：靜止玩家腳下／身旁的房間失效、走進很早以前失效的格子（東西向與南北向）、
上樓踏進上層失效格子、探針晚到、移動中取得探針、探針區塊消失、地圖上仍有房間、單人、玩家離開後可被回收、
自身錯誤只印一次並停用，以及「靜止 100 幀零逐格查詢、每人每幀 2 次呼叫、換一格只查 27 格」的成本不變式。

**mutation 驗證**（`lua scripts/test_stale_room_guard.lua --mutants`，13 個全部抓到）：

| 突變 | 轉紅 |
|------|------|
| 拿掉區域資料交換偵測 | 9 項 |
| 只查腳下這一欄（x）／這一列（y） | 3 項／6 項 |
| 只查同一層 | 2 項 |
| 不看地圖就重設 | 3 項 |
| 不跑 RecalcProperties／先 RecalcProperties 再 setRoomID | 各 1 項 |
| 拿掉 pcall | 3 項 |
| 不清掉離開玩家的格位 | 1 項 |
| 每幀都全部重查（效能退化） | 3 項 |
| 探針到手不補查／不定期找探針／移動時不順手取探針 | 1／2／1 項 |

實機 E2E（`fixes-e2e` skill 的 `stale-room`）：伺服器在玩家腳下蓋一間 3×3、有屋頂的自建房間，客戶端確認房間
成立後拆掉南牆中段。

| 場次 | 結果 |
|------|------|
| MP 對照組（修正檔從本輪拿掉） | 拆牆後下一幀 `ParameterFirearmRoomSize.getRoomSize` NPE → `removing all player data` → 回主選單，堆疊與正式服玩家的 log 相同；伺服器連線紀錄是客戶端送出的 `disconnection-notification` |
| MP 修正組 | 9 格失效格子在重建的同一幀就修好（每幀巡視的情境 hook 一次都沒看到失效格子），沒有例外，房間消失後繼續玩 5 秒 |
| 單人修正組 | 同上，9 格全部修好、沒有例外 |

情境要先在同一帶放一面孤立的牆，讓伺服器先「發現」這些區塊，再蓋房間；在從未變動過的區塊第一次施工時，
實測客戶端收到的區域資料沒有牆（伺服器端有），房間根本不成立。這是原版區域同步的另一個問題，與本修正無關。

`python scripts/check_vanilla_alignment.py` 以 `javap` 反組譯本機 jar 比對 Java 指紋：爆點（`getRoomDef` 後直接
`getArea`）、成因的官方修正（retired：`removeUserDefinedBuildingsFromCell` 呼叫 `markBuildingChunksDirty`、`updateSquares`
只看 `chunkIsDirty`）、兩個前提（`IsoRegions.update` 先交換再重建、`IsoWorld.updateWorld` 先更新玩家再重建）與依賴的 API。

### 42.21 退場

42.21 的 `WorldRegionToMetaGrid.removeUserDefinedBuildingsFromCell` 在移除每棟自建建築之前先
`markBuildingChunksDirty(buildingDef)`，把建築 `overlappedChunks`（`BuildingDef.CalculateBounds` 由所有房間 rect 外擴一格算出，
`addRoomsOf` 合併樓層時重算）的每個 chunk 標成 dirty；`updateSquares` 因此會以 `getRoomAt` 重設舊房間覆蓋的每一格。
42.20.4 的缺口正是這些格子沒被標記（見上方「根因」第 2 點）。`removeIsoRoom` 清 `def` 的動作搬進新的 `IsoRoom.clear(boolean)`，行為不變。

實機：42.21 跑 `stale-room` 對照組（修正檔從本輪拿掉），房間成立（`enclosed=true roofed=1 size=9 building=true`）、拆掉南牆後
30 秒內沒有崩潰，情境每幀巡視看到失效格子 **0 幀**（42.20.4 同一情境拆牆後下一幀就斷線）。

爆點 `ParameterFirearmRoomSize.getRoomSize` 仍沒有 null 檢查，所以補丁不刪：它只在找到失效格子時才動作，42.21 下平常只剩每幀的腳下比對。

### 可退場條件

已達成（42.21 官方修正成因）。`check_vanilla_alignment.py` 的 retired 指紋若轉 CHANGED，表示官方撤回或改寫了這段修正，
要重跑 `stale-room` 對照組確認失效格子是否復發；爆點若補上 null 檢查（exithint），補丁可整支移除。

---

## MDFX_GiveWaterAnimalGuard — 餵水動作在伺服器找不到動物或水容器時每 400 ms 拋錯、停不下來

| 項目 | 內容 |
|------|------|
| 檔案 | `server/Fixes/MDFX_GiveWaterAnimalGuard.lua` |
| 影響版本 | Build 42.21.0 |
| 端 | server，且只在 `isServer()` 安裝（單人與客戶端的動物與水容器是 `new()` 當下的本地物件，不會是 nil） |
| 類型 | 前置判準包裝原版 `animEvent`／`complete`，每個動作記一行診斷 |
| 狀態 | **現役**（42.21.0-0.11.0 起） |

### 症狀

多人遊戲對一隻伺服器不認得的動物餵水（client 手上的動物物件，伺服器用它的 online ID 查不到）：伺服器每 400 ms
拋一次錯，直到玩家取消、做別的動作、離線或伺服器重啟才停；玩家的動作卡在進度條尾端，動物沒喝到水、水也沒少。
正式服 log 實據：平常 0 次，出事時單次最多約兩千次例外，一路持續到伺服器重啟。

```
attempted index: getStats of non-table: null
    Lua(Vanilla).animEvent(ISGiveWaterToAnimal.lua:85)
    zombie.core.NetTimedAction.animEvent(NetTimedAction.java:199)
    zombie.network.server.AnimEventEmulator.update(AnimEventEmulator.java:60)
```

同一段時間原版的牽繩（`ISAttachAnimalToPlayer.complete`）與裝拖車（`ISAddAnimalInTrailer.complete`）也因為同樣的
原因對 nil 動物拋錯，但各只一次（由 `MDFX_AnimalCompleteGuard` 處理）；沒裝任何畜牧介面 MOD 的時期也出現過。問題在
伺服器不認得 client 指定的動物，與發起動作的介面無關。client 為什麼會拿著伺服器不認得的動物還沒查到，本修正的
診斷紀錄就是為了追它。

同一支 `animEvent` 還有另一個形狀：動物在、但伺服器找不到 client 指定的水容器。原版每 400 ms 先扣動物 0.05 口渴
才拋錯，一滴水都沒用就把動物餵到不渴，30 分鐘到時還以成功結束。這個形狀沒有正式服實據，與動物 nil 同一種成因、
同一個迴圈，使用者同意一併處理。

### 根因（行號為 42.21.0 原版 Lua 與反編譯快照）

1. **動作照樣建立**：client 把動物寫成 online ID（`PZNetKahluaTableImpl.java:404-407`），server 以
   `AnimalInstanceManager.get(id)` 解回（`AnimalID.java:22-25`），查不到就是 nil（`PZNetKahluaTableImpl.java:598-601`）；
   水容器以「容器＋物品 ID」傳送，server 在那個容器裡 `getItemWithID` 找不到也是 nil（`:473-478`）。參數表照位置保留
   nil（`load` 直接寫入底層 map，`:516-522`），後面的參數不會錯位。`NetTimedAction.parse`（`NetTimedAction.java:142-171`）
   用它們呼叫 `new()`（`ISGiveWaterToAnimal.lua:124-133`）：只做欄位賦值，`getDuration()` 在 server 第一行就回 -1
   （`:102-105`），兩個都不碰，所以 `new()` 成功、動作被接受。
2. **每 400 ms 拋一次**：`serverStart`（`:97-100`）以 `emulateAnimEvent` 每 `timePerUse × 20`＝400 ms 模擬一次 `update`。
   `animEvent` 第一行（`:85`）對動物取值、第二行（`:86`）對水容器取值，後面「喝飽或水用完就
   `self.netAction:forceComplete()`」（`:90-92`）永遠到不了。水容器 nil 時 `:85` 已經扣掉口渴。
3. **不會自己結束**：時長 -1 經 `NetTimedAction.getDuration`（`:78`）原樣保留，`Action.setTimeData`（`Action.java:30-31`）
   把它換成 `AnimEventEmulator.getDurationMax()`＝30 分鐘。在那之前只有 client 取消（`GeneralActionPacket.java:44` →
   `ActionManager.remove`，`ActionManager.java:160-191`）、同一玩家開始新動作（`NetTimedActionPacket.java:70`）、
   玩家斷線（`GameServer.java:4440` → `ActionManager.disconnectPlayer`，`:245-256`）或伺服器重啟會結束它。
   30 分鐘到時模擬事件被移除（`AnimEventEmulator.java:46`），`perform` 呼叫 `complete`：動物 nil 時 `:77` 再拋一次，
   `pcallBoolean` 回 null（`KahluaThread.java:1329-1338`）、拆箱例外被 `NetTimedAction.perform`（`:132-139`）接住回 false，
   走 Reject；水容器 nil 時 `complete` 只碰動物、回 true，以成功結束。client 的動作在 `waitForFinished` 下一直等伺服器
   結果（`BaseAction.java:174-176`）。伺服器上若有 MOD 改寫 `getDuration`（例如把 client 算好的 maxTime 帶到 server 的
   時長同步修正），時長就不是 -1，動作會在那個時間到時走 `complete`。本修正不依賴時長：先到的是模擬事件還是
   `complete`，都會結束並拒絕動作。

server 端會被呼叫的 Lua 只有 `getDuration`（含 `adjustMaxTime`，-1 不調整）、`serverStart`、`animEvent`、`complete`；
`ISGiveWaterToAnimal` 與 `ISBaseTimedAction` 都沒有 `serverStop`。`isUsingTimeout`（`NetTimedAction.java:53`）只在 client
建立封包時呼叫，server 的動作管理也不看它。

### 修法

只在 `isServer()` 包裝兩個 method（共用骨架 `MDFX_Guard`）：

| method | 動物或水容器為 nil 時 | 依據 |
|--------|---------------------|------|
| `animEvent` | event 是 `"update"`：`netAction:forceComplete()`、記一行、return，不呼叫原函式（所以也不會先扣口渴）；**其他 event 原樣透傳** | vanilla `:90-92` 自己的結束方式；原版對其他 event 什麼都不做（`:84`） |
| `complete` | 記一行（同一動作已記過就不再記）、回 `false` | `NetTimedAction.perform` 把 false 交給 `ActionManager.update`（`ActionManager.java:87-97`）走 Reject、通知 client 取消。動物 nil：原版在這裡拋錯也被接成 false，結局相同。水容器 nil：原版會回 true，但伺服器其實沒做這個動作，拒絕才對，也與動物 nil 一致 |

`forceComplete` 把結束時間設成現在（`NetTimedAction.java:173-175`）。server 每幀先跑含模擬事件的 `UpdateStuff`
（`IngameState.java:1559`，模擬事件在 `:662`），再跑 `updateManagers`（`:1645`，`ActionManager.update` 在 `:1659`），
所以同一幀就呼叫 `complete`：一個動作只走一次 `animEvent`，client 送出後約 0.4 秒收到拒絕。
動物與水容器都在時兩個 method 原樣透傳，正常餵水零行為差異。

刻意不做的事：

- 物品在、但不是流體容器（`getFluidContainer()` 回 nil，同樣在 `:86` 拋錯）不處理：成因是物品被換掉，不是伺服器
  解析不到，沒有實據，照原版外洩。
- 不替 client 找附近另一隻動物接手：伺服器不認得玩家指定的動物，猜一隻等於發明行為。
- 不攔 `serverStart`：爆點與原版的結束路徑都在 `animEvent`，多等的 0.4 秒不影響結果。

### 診斷紀錄

為了追查 client 為什麼拿著伺服器不認得的動物，這一項不照本 repo「一 session 一次」的慣例：**每個動作記一行**
（旗標掛在動作表上，`animEvent` 之後的 `complete` 不再記），每 session 最多 20 行，超過後由 `MDFX_Guard.warnOnce`
印一次上限提示，之後照樣拒絕、不再記錄。正式服每輪 0–3 次，上限只防異常時洗版。

```
[MinidoracatFixes] MDFX_GiveWaterAnimalGuard nilAnimal n=<本 session 第幾個> player="<帳號>" x=<格> y=<格> z=<層> item=<物品全名|nil> via=<animEvent|complete>; the server has no such animal, so the watering action is rejected instead of erroring every 400 ms. See docs/fixes.md MDFX_GiveWaterAnimalGuard
[MinidoracatFixes] MDFX_GiveWaterAnimalGuard nilItem n=<本 session 第幾個> player="<帳號>" x=<格> y=<格> z=<層> animal=<種類>#<online ID> via=<animEvent|complete>; the server cannot find the water container in the player's inventory, so the watering action is rejected instead of watering for free and erroring every 400 ms. See docs/fixes.md MDFX_GiveWaterAnimalGuard
[MinidoracatFixes] MDFX_GiveWaterAnimalGuard limit=20 reached; further watering actions the server cannot resolve are still rejected but not logged this session. See docs/fixes.md MDFX_GiveWaterAnimalGuard
```

- grep：`MDFX_GiveWaterAnimalGuard nil` 抓每個動作那一行（兩種）；`MDFX_GiveWaterAnimalGuard` 連上限提示一起抓。
- 欄位以空白分隔、固定順序；`player` 一律加雙引號（帳號可以有空白），座標是玩家所在格（`math.floor`），
  角色是 nil 時寫 `player=? x=? y=? z=?`。動物與水容器都 nil 時記成 `nilAnimal ... item=nil`。
  `nilItem` 的 `animal=` 是伺服器上那頭動物的種類與 online ID（client 指定的就是它）。
- 時間用 console 每行開頭的時間戳。`via=animEvent` 是正常路徑；`via=complete` 表示動作沒走過模擬事件就到了 `complete`。
- 訊息刻意不寫原版檔名行號：監控用 `grep 'ISGiveWaterToAnimal.lua'` 數原版錯誤時，不會把這行算進去。
- **沒有 client 指定的動物 ID**：它在 `AnimalID.parse` 就只剩解析結果，Lua 拿不到；要記 ID 得在 Java 端
  （`NetTimedActionPacket` 解析參數時）處理。

### 同形狀掃描（42.21.0）

條件：server 時長 -1、`serverStart` 用 `emulateAnimEvent`（重複，不是 `Once`）、`animEvent` 沒檢查就對 `self.animal` 取值。
原版 33 個呼叫 `emulateAnimEvent` 的動作裡，`animEvent` 會對 `self.animal` 取值的只有三個，真正同形狀的只有本項：

| 動作 | server 時長 | nil 動物能不能走到 `animEvent` |
|------|------------|------------------------------|
| `ISGiveWaterToAnimal` | -1（`:102-105`） | **能**：`new()` 不碰動物 → 本修正 |
| `ISMilkAnimal` | -1（`:218-246`） | 不能：`new()` 在 `:266` 先對 `animal:getMilkAnimPreset()` 取值，`parse` 時拋一次錯（記一次堆疊）就被拒絕（`NetTimedAction.java:159-163`）；`serverStart` 也在 `:212` 先取值 |
| `ISShearAnimal` | 正數，由 `getDuration`（`:138-143`）對動物取值算出 | 不能：`new()` 在 `:160` 呼叫 `getDuration`，`parse` 時拋一次錯就被拒絕 |

`ISLureAnimal` 時長也是 -1、也重複模擬事件，但 server 端不用 `self.animal`。

只拋一次、不會重複的動物動作（時長是正數、沒有模擬事件，`new()` 不碰動物，到時間 `complete` 對 nil 取值拋一次）：
牽繩、拴樹、裝拖車、手餵，見下一節 `MDFX_AnimalCompleteGuard`。`ISPickupAnimal.complete` 先以 `isValid()`（`:6`）擋掉
nil 動物（`:42-44`），不會拋錯。擠奶與剪毛在 parse 時那一次錯沒有正式服實據，不處理。

### 驗證

`lua scripts/test_give_water_animal_guard.lua` — 81 項，全綠。假引擎照 42.21.0 反編譯快照驅動 server 端整條路徑
（`parse` → `setTimeData` → `serverStart` → 每幀 100 ms 先模擬事件、再動作管理 → `perform`／Reject），原版
`ISGiveWaterToAnimal` 的 server 端 method 照行號抄成 stub。涵蓋：`isServer()` 為假時零介入；正常餵水兩種結束（喝飽、
水用完）與原版逐事件相同（口渴、水量、XP、時間、Done、`setThirst`）；動物為 nil 時只走一次模擬事件、零例外、
在 0.4 秒以 Reject 結束並通知 client、水量與 XP 不變、診斷恰一行且欄位齊全；對照組（不載入修正）每 400 ms 拋一次、
動作一直掛著，30 分鐘上限到時 `complete` 再拋一次、`perform` 失敗走 Reject；動物在、水容器 nil 時修正一樣在 0.4 秒拒絕、
不扣口渴、記一行 `nilItem`，對照組則每次事件白扣口渴再拋錯、30 分鐘時以 Done 結束；`netAction` 為 nil 時走到上限由
`complete` 記一行；同一動作重複事件只記一行；25 個動作只記 20 行＋一次上限提示；物品不是流體容器、原函式自己拋錯照原版
外洩，非 `update` 事件照常交給原函式；重複載入不疊、後載 MOD 替換後復查重裝；vanilla 缺席／部分缺席不亂補；成員快照；
角色與物品都是 nil 時診斷不炸；別的 MOD 把 server 時長改成正數時（例如帶 client 的 maxTime），修正照樣在第一個模擬事件
結束、時長比 0.4 秒短則由 `complete` 先擋下。

**mutation 驗證**（`lua scripts/test_give_water_animal_guard.lua --mutants`，15 個全部抓到；含拿掉整支修正與共用骨架三道防線）：

| 突變 | 轉紅 |
|------|------|
| 不載入修正 | 30 項 |
| `animEvent` 不判 nil（一律交給原函式） | 22 項 |
| `animEvent` 攔下所有 event | 1 項 |
| `animEvent` 只判動物、不判水容器 | 3 項 |
| `animEvent` 不 `forceComplete` | 10 項 |
| `animEvent` 不記診斷 | 3 項 |
| `complete` 不判 nil | 12 項 |
| `complete` 只判動物、不判水容器 | 2 項 |
| `complete` 回 true | 7 項 |
| 每個動作不只記一次 | 4 項 |
| 水容器 nil 也記成 `nilAnimal` | 1 項 |
| 沒有 session 上限 | 2 項 |
| `MDFX_Guard` 拆掉 `isServer()` 閘門／冪等 marker／診斷節流 | 3／2／1 項 |

`python scripts/check_vanilla_alignment.py` 登記 5 條爆點（server 時長 -1、`update` 模擬事件、`animEvent` 第一行對動物取值、
`:85-87` 先扣口渴再對水容器取值、`complete` 取值）、3 個依賴符號與「官方補上動物或水容器 nil 檢查」的退場提示。

實機 E2E（`fixes-e2e` skill 的 `give-water`，MP 專用伺服器，42.21.0，修正組與對照組各跑兩輪）：伺服器在玩家旁生牛，客戶端直接排原版
餵水動作。動物 nil 用「舊物件」重現：伺服器 `removeAnimal` 後，客戶端拿手上原本那個 IsoAnimal 排動作，伺服器 `AnimalID.parse`
查無此 ID——與正式服同一條解析路徑。水容器 nil 用客戶端自己 `AddItem` 的水桶（伺服器沒有這個物品 ID）。

| 場次 | 結果 |
|------|------|
| 對照組，動物 nil | 排入後約 0.45 秒起，每約 0.48 秒一次 `Lua(Vanilla).animEvent> Exception thrown`（`attempted index: getStats of non-table: null`、`ISGiveWaterToAnimal.lua:85`，堆疊與正式服相同），8 秒內 16 次；客戶端動作 8 秒後仍在跑，情境取消後才停；水量、XP 不變（兩輪相同） |
| 對照組，水容器 nil | 8 秒內 17 次例外（`getFluidContainer of non-table: null`、`:86`）；伺服器端牛的口渴 0.90 → 0.50（4 秒）→ 0.10（7.5 秒），取消後停在 0.05，真水桶 1 L 沒少——白餵實機確認 |
| 修正組，動物 nil | 排入約 0.45 秒後伺服器記一行 `MDFX_GiveWaterAnimalGuard nilAnimal n=1 player="test" … item=Base.Bucket via=animEvent`（座標與客戶端排入時相同），客戶端 0.5 秒內被拒絕結束；水量、XP 不變（兩輪相同） |
| 修正組，水容器 nil | 記一行 `nilItem n=2 … animal=cow#<那頭牛的 online ID> via=animEvent`，客戶端 0.48 秒被拒絕；伺服器端口渴 0.90 → 0.90、真水桶與 XP 不變 |
| 修正組整體 | `SERVER STARTED` 之後排除 `[MinidoracatFixes]` 行，沒有任何 `Exception thrown`／`NOT installed`／`Perform failed` |
| 正常餵水（四次各兩種） | 喝飽結束（口渴 0.12、水 1 L）與水用完結束（口渴 0.9、水 0.15 L）四次逐字相同：都是 3 次事件，口渴 -0.12／-0.15、水 -0.15 L、Husbandry XP +1.5 |

數原版例外要用 `Lua(Vanilla).animEvent> Exception thrown`：每次例外 `getStats of non-table` 印兩行、`ISGiveWaterToAnimal.lua:85`
印三行。

### 可退場條件

官方在 `animEvent`（或 `serverStart`）與 `complete` 補上動物與水容器的 nil 檢查（`check_vanilla_alignment.py` 對
`if not self.animal then`／`if not self.item then` 形狀有 exithint）。官方只補一半時（例如只在 `animEvent` 結束動作），
`complete` 仍會對 nil 取值拋一次，屆時評估只留 `complete` 那一半。

---

## MDFX_AnimalCompleteGuard — 牽繩、拴樹、裝拖車、手餵在伺服器找不到動物時 complete 拋錯

| 項目 | 內容 |
|------|------|
| 檔案 | `server/Fixes/MDFX_AnimalCompleteGuard.lua` |
| 影響版本 | Build 42.21.0 |
| 端 | server，且只在 `isServer()` 安裝（同上，單人與客戶端的動物是本地物件） |
| 類型 | 前置判準包裝四個原版動作的 `complete`，每個動作記一行診斷 |
| 狀態 | **現役**（42.21.0-0.11.0 起） |

### 症狀

多人遊戲對一隻伺服器不認得的動物牽繩、拴樹、裝進拖車或手餵：動作跑完後伺服器拋一次錯（整段堆疊＋`Perform failed`），
動作被拒絕，什麼都沒發生。正式服 log 實據：牽繩（`ISAttachAnimalToPlayer.lua:42`）與裝拖車（`ISAddAnimalInTrailer.lua:76`）
在 `MDFX_GiveWaterAnimalGuard` 出事的同一段時間各出現過，沒裝畜牧介面 MOD 的時期也有；拴樹、手餵是同形狀，使用者同意一併處理。

### 根因（行號為 42.21.0 原版 Lua 與反編譯快照）

成因與上一節相同：client 指定的動物，server 用 online ID 查不到（`AnimalID.java:22-25`），`NetTimedAction.parse` 照樣用 nil
建立動作。這四個動作的 `new()` 都不碰動物、`getDuration()` 回正數（只看 `isTimedActionInstant`），server 端也沒有
`serverStart`／`animEvent`，所以時間到時 `complete` 第一次對動物取值才拋錯：

| 動作 | 爆點 |
|------|------|
| `ISAttachAnimalToPlayer`（牽繩） | `:42` 牽上、`:50` 解開：`self.animal:getData()` |
| `ISAttachAnimalToTree`（拴樹） | `:42` 解開、`:47` 拴上：`self.animal:getData()` |
| `ISAddAnimalInTrailer`（裝拖車） | `:76` 從地上：`self.animal:getSquare()`；`:66` 從手上：交給 `addAnimalFromHandsInTrailer` |
| `ISFeedAnimalFromHand`（手餵） | `:46`：`self.animal:getBehavior()` |

`pcallBoolean` 回 null、`NetTimedAction.perform` 的 catch 回 false，動作走 Reject（`ActionManager.java:87-97`），client 收到後
取消。從手上放入時，`addAnimalFromHandsInTrailer` 的 `IsoAnimal` 多載第一行就把參數加進拖車的動物清單
（`BaseVehicle.java:10614-10616`），下一行才對它取值；Kahlua 對 nil 選到這個多載的話，拖車清單會留下一個 null（推論，未實測）。

### 修法

只在 `isServer()` 包裝四個 class 的 `complete`：`self.animal` 是 nil → 記一行、回 `false`（同樣走 Reject），不呼叫原函式；
動物存在時原樣透傳。結局與原版相同，只是不拋錯、不會碰到上面那個多載，並留下玩家與位置供追查。
裝拖車原版在取值前先跑 `self.vehicle:updateParts()`（`:63`），nil 時本修正不跑：它只為「新加入的動物」結算經過的時間，
沒有動物加入就沒有要結算的對象，車輛之後的更新照常處理。四個 class 各自 `wrap`（各自的形狀檢查、`NOT installed`、
marker），某一個形狀變了只影響它自己。

刻意不做的事：

- 裝拖車從手上放入、而玩家物品欄裡有動物物品時，`new()` 的 `getAnimalInventoryItem(animal)`（`:101`，
  `ItemContainer.java:796-810`）就會對 nil 取值，在 parse 時拋一次錯就被拒絕。那不在 `complete`，也沒有正式服實據，不包 `new`。
- `ISPickupAnimal.complete` 先以 `isValid()` 擋掉 nil 動物（`:42-44`），不需要。

### 診斷紀錄

與 `MDFX_GiveWaterAnimalGuard` 同一套：每個動作一行（`complete` 每個動作只走一次），每 session 最多 20 行（四個動作共用），
超過後由 `MDFX_Guard.warnOnce` 印一次上限提示，之後照樣拒絕、不再記錄。訊息同樣不寫原版檔名行號。

```
[MinidoracatFixes] MDFX_AnimalCompleteGuard nilAnimal n=<本 session 第幾個> action=<ISAttachAnimalToPlayer|ISAttachAnimalToTree|ISAddAnimalInTrailer|ISFeedAnimalFromHand> player="<帳號>" x=<格> y=<格> z=<層> [remove=<true|false>|fromHand=<true|false>]; the server has no such animal, so the action is rejected instead of erroring in complete. See docs/fixes.md MDFX_AnimalCompleteGuard
[MinidoracatFixes] MDFX_AnimalCompleteGuard limit=20 reached; further animal actions without a server-side animal are still rejected but not logged this session. See docs/fixes.md MDFX_AnimalCompleteGuard
```

`remove` 是牽繩／拴樹的「解開」，`fromHand` 是裝拖車的「從手上放入」，手餵沒有額外欄位。玩家與座標欄位格式同上一節。

### 驗證

`lua scripts/test_animal_complete_guard.lua` — 45 項，全綠。四個 `complete` 照原版行號抄成 stub，`perform` 以 pcall 模擬
`pcallBoolean`（出錯或不是 true 都是 Reject）。涵蓋：`isServer()` 為假時零介入；動物存在時四個都原樣透傳（回傳值、牽上／解開、
拴上、進拖車、餵到）；動物為 nil 時四個都回 false、不拋錯、不呼叫原函式、各記一行且欄位齊全、拖車清單與 `updateParts` 都沒動；
對照組四個都拋錯，裝拖車從手上放入時 `IsoAnimal` 多載先把 nil 加進清單；四個共用每 session 20 行上限＋一次提示；動物存在時
原函式的錯（例如載具解析不到）照原版外洩；重複載入不疊、後載 MOD 替換後復查重裝；缺一個 class 只影響它自己；成員快照；
角色也是 nil 時診斷不炸。

**mutation 驗證**（`lua scripts/test_animal_complete_guard.lua --mutants`，10 個全部抓到）：

| 突變 | 轉紅 |
|------|------|
| 不載入修正 | 26 項 |
| `complete` 不判 nil | 22 項 |
| `complete` 回 true | 7 項 |
| 不記診斷 | 8 項 |
| `remove`／`fromHand` 欄位拿掉 | 3 項 |
| 沒有 session 上限 | 2 項 |
| 漏包手餵 | 13 項 |
| `MDFX_Guard` 拆掉 `isServer()` 閘門／冪等 marker／診斷節流 | 1／1／1 項 |

`python scripts/check_vanilla_alignment.py` 每個動作一條：`complete` 的爆點行（裝拖車另登記 `:66`）、「server 端沒有
`serverStart`／`animEvent`」的前提、`complete` 依賴符號與 nil 檢查的退場提示。

實機 E2E（同一個 `give-water` 情境）：客戶端用 `addAnimal`＋`addToWorld` 在自己這邊生一頭伺服器沒有的牛（client 的 online ID
伺服器查不到），旁邊擺一棵樹與一台牲畜拖車，依序排牽繩、拴樹、裝拖車（從地上）、手餵（伺服器給的蘋果）。

| 場次 | 結果 |
|------|------|
| 對照組 | 每個動作兩次 `Exception thrown`：先是 `Lua(Vanilla).complete> … attempted index: getData／getData／getSquare／getBehavior of non-table: null`（`ISAttachAnimalToPlayer.lua:42`、`ISAttachAnimalToTree.lua:47`、`ISAddAnimalInTrailer.lua:76`、`ISFeedAnimalFromHand.lua:46`），接著 `NetTimedAction.perform> … NullPointerException … Perform failed`；動作都被拒絕結束 |
| 修正組 | 四行 `MDFX_AnimalCompleteGuard nilAnimal n=1..4 action=<Class> player="test" …`（牽繩、拴樹帶 `remove=false`，裝拖車帶 `fromHand=false`），沒有任何例外；動作都在 0.8–3.1 秒內被拒絕結束，沒牽上、蘋果沒被吃掉 |
| 安裝面 | 修正組伺服器上四個 marker 都是現任 `complete`；客戶端不安裝 |

### 可退場條件

四個各自獨立：官方在哪個 class 的 `complete`（或 `isValid`）補上 `self.animal` 的 nil 檢查，就把那一個移出。

---

## MDFX_ModOptionsPersist — 原版 MOD 設定存檔把別的 MOD 的設定黏成一行、或整檔清空

| 項目 | 內容 |
|------|------|
| 檔案 | `client/Fixes/MDFX_ModOptionsPersist.lua` |
| 影響版本 | Build 42.21.0（原版 `PZAPI.ModOptions` 推出以來同一寫法） |
| 端 | 純客戶端（選項檔在每位玩家自己的 `Zomboid/Lua/ModOptions.ini`；dedicated server 對 `client/` 只算 checksum） |
| 狀態 | **現役**（42.21.0-0.12.0 起） |

### 症狀

MOD 的設定（ESC → 選項 → MOD）重開遊戲就回到預設，而且只發生在某些 MOD 上；或整份 MOD 設定一次全部消失。
`ModOptions.ini` 裡可以看到一行裡黏著幾十筆 `<型別>|<modid>|<optid>|<值>`（作者本機 2026-10-02 實例：一行 48 筆，
AutoDrive 全部 19 個選項、CleanUI、Economy、NoticeBoard、MirageWardrobeZoom）。不會有任何錯誤訊息。

觸發條件：主選單與存檔啟用的 MOD 不同（每個存檔各自選 MOD），在當下沒載入某些 MOD 的狀態下按了選項的套用／確定；
或主選單根本沒有任何 MOD 建選項時按了套用。

### 根因

所有 MOD 的選項存在同一個檔，一筆一行（`client/PZAPI/ModOptions.lua`）：

1. **load 收、save 不加換行**：load（`:292-333`）用 `readLine` 逐行讀，對不上已註冊選項的行原樣收進
   `PZAPI.ModOptions.OtherOptions`（`:330`）。`readLine` 已經去掉行尾，save（`:259-290`）寫已註冊選項時有補
   `"\r\n"`（`:282`），寫回 OtherOptions 卻是 `fileOutput:write(line)`（`:286-288`），全部黏成檔尾的一行。
2. **黏行只看第一筆**：下次 load 用 `luautils.split(line, "|")` 只取 `t[2]`／`t[3]`（`:304-305`）。第一筆屬於已註冊
   選項時整行走 if 分支、只套第一筆，其餘全部丟掉，而且這行不進 OtherOptions，下一次 save 就永久消失；第一筆不屬於
   已註冊選項時整行進 OtherOptions，裡面每一筆的值都套不到，而且之後的 save 會把更多行接上去。
3. **主選單沒有 MOD 選項時清空**：`MainOptions:create` 只在 `#PZAPI.ModOptions.Data ~= 0` 時建 MOD 頁並 load
   （`client/OptionScreens/MainOptions.lua:409-411` → `addModOptionsPanel` 的 `:2796`）；`apply` 在 `:3766` 無條件 save，
   寫出的只有空的 Data 與還是初始空表的 OtherOptions，`getFileWriter(…, true, false)`（`:260`）先截斷檔案。

離線照載原版檔重現（`scripts/test_modoptions_persist.lua` 的對照組）：黏行第一筆屬已註冊選項時那幾個值留在預設、save
後未載入 MOD 的那筆消失；第一筆屬未註冊選項時值套不到；主選單沒有 MOD 選項時 save 後檔案是空的。

### 修法

包裝 `PZAPI.ModOptions.load`／`save`，不取代原函式：

1. **load**：先呼叫原 load——原版解析、舊 combobox 行把索引寫進同 id 新選項 `.selected`（`:320`，MiniMap 的
   combobox→slider 遷移靠這個訊號）、其他 MOD 的包裝鏈都照舊。再直接讀檔找黏行：**不能只看 OtherOptions**，第一筆屬
   已註冊選項的黏行根本不進 OtherOptions。有黏行就把檔案改寫成一筆一行，`getFileReader` 讀回逐行比對
   （`getFileWriter` 寫失敗不報錯，家族 `pitfalls.md`），相同才再呼叫一次原 load 把值套上。原版 load 不寫檔，第一次
   load 漏掉的值由第二次補回；讀回不符就把原內容逐行寫回（只差行尾）、不做第二次 load。
2. **save**：把 OtherOptions 暫時換成「每行補上 `\r\n`」的複本、呼叫原 save、再換回原表（`pcall` 保護，原 save 拋錯
   也先換回再原樣重拋）。不永久改 OtherOptions：EquipmentUI（3780682550）load 後會用 `string.find` 在裡面找自己的舊行移除。
3. **save 先於 load**：OtherOptions 還是原版檔案建立時那張表（原版 load 第一行就換新表，`:294`）＝這個 Lua 環境還沒
   load 過。這時先讀檔，把沒註冊的行（黏行先拆開）接在 OtherOptions 後面一起寫回：已註冊的跳過、完全相同的行去重。
   **不動已註冊選項在記憶體裡的值**——有 MOD 會程式設值後直接 save（例：MiniMap 的一次性遷移），整個 load 會把它蓋回舊值。

**黏行切分規則**：每筆以 save 會寫的七種型別（`:264-281`：`textentry`／`tickbox`／`multipletickbox`／`slider`／
`combobox`／`colorpicker`／`keybind`）加 `|modid|optid|` 起頭，從左往右每次取最左邊的起頭——`multipletickbox` 的起頭
比它裡面的 `tickbox` 早，所以不會被切開。一行切出兩筆以上時，每筆的值都要是原版 save 寫得出來的形狀，否則整檔不改
（印一行 `glued line N has an unrecognised record`）：tickbox `true`／`false`、slider／combobox／keybind 是數字
（含 Kahlua 的科學記號字串 `1.0E-4`）、multipletickbox 是一串「`true `／`false `」（結尾有空格）、colorpicker 四個數字
以空格分隔、textentry 不限；任何型別都接受原版對 nil 寫出的 `nil`。行首不是起頭的行原樣保留。

**零行為差異**：沒有黏行時 load 只多讀一次檔、不寫檔；OtherOptions 是空的時 save 與原版位元組相同；有未註冊行時只差每行
補上 `\r\n`（這就是修正）。OtherOptions 裡的空字串不傳給原 save（原版寫空字串本來就沒有輸出）。

**安裝時機**：本檔載入時就包好，早於第一次 load。原版 client 檔排在所有 MOD 之前執行（`LuaManager.java:1192-1193`），
`PZAPI.ModOptions` 一定已經存在；`MainOptions:create` 只從 MainScreen 的 `OnMainMenuEnter`／`OnGameStart` 處理器呼叫
（`MainScreen.lua:2178`、`:2180` → `instantiate` → `:694`），這些事件都在 `LuaManager.LoadDirBase` 之後才觸發
（`Core.java:3949` → `:3962-3963`；回主選單 `IngameState.java:1070` → `:1077`；開機 `GameWindow.java:993` 之後才進
`MainScreenState`，`:396` 觸發 `OnMainMenuEnter`）。每次 `LoadDirBase` 原版檔重建整張表，marker 隨之消失、本檔重新包裝；
同一張表上重複執行由 marker 擋下。形狀不符（`PZAPI.ModOptions`、`load`／`save`、`OtherOptions`／`Dict`、
`getFileReader`／`getFileWriter`）印一次 `NOT installed` 並放棄。不做 `OnGameBoot` 復查：會包裝 load／save 的已知 MOD
（EquipmentUI、ContextMenuCleanup 3780688809）都先呼叫原函式，前後順序都串得起來；整支取代而不呼叫原函式的 MOD 會讓本修正失效，
那種 MOD 本身就已經改掉原版存讀。

診斷（一 session 一次，前綴 `[MinidoracatFixes] MDFX_ModOptionsPersist`）：`split N glued records into one per line`、
`glued line N has an unrecognised record; file left unchanged`、`rewrite not verified; original lines written back`、
`repair failed (…)`／`could not prepare other lines (…)`（自身出錯，退回原版行為）。

### 已知限制

- **已經遺失的設定救不回**：被原版清空的檔、或黏行第一筆屬已註冊選項而被原版丟掉後又存過一次的那些筆，檔案裡已經沒有了。
- **主選單要啟用本 MOD** 才擋得住主選單的套用；多人遊戲進服後只載伺服器 `Mods=` 的 MOD，伺服器沒裝本 MOD 時遊戲內不生效。
- textentry 的值若剛好含「型別`|x|y|`合法值」形狀的字串，會被當成黏行切開（實務上沒見過）。
- save 期間內層包裝若改動 OtherOptions，改動會隨換回原表而丟失（已知 MOD 都沒有這樣做）。

### 驗證

`lua scripts/test_modoptions_persist.lua` — 52 項，全綠。照載本機原版 `client/PZAPI/ModOptions.lua` 與 `shared/luautils.lua`，
記憶體檔案系統照 `LuaManager.java:5936-5964`、`:6727-6763`（副檔名白名單、`FileOutputStream` 一開就截斷、`BufferedReader.readLine`
三種行尾）。涵蓋：黏行第一筆屬已註冊／未註冊兩種（含七種型別、科學記號、multipletickbox 結尾空格；值套上、檔案一筆一行、
下次 save 一筆一行、換場次值仍在；各有原版對照組）、save 先於 load（沒有 MOD 選項時不清空且可重入；有選項時寫記憶體裡的值、
檔案舊值不重複寫回、相同行去重）、無黏行（load 不寫檔；只有已註冊行時與原版位元組相同；有未註冊行時只差 `\r\n`）、EquipmentUI 的
load 包裝照抄、在本補丁內層／外層 × 舊行獨立／黏住四種組合都找到並移除舊行、combobox→slider `.selected` 訊號（獨立行與黏行）、
切不出合法筆數不改檔、寫入被靜默丟掉時寫回原內容且不做第二次 load、修補讀檔拋錯與準備 OtherOptions 拋錯都退回原版、原 save
拋錯照樣外洩且 OtherOptions 換回、形狀不符 `NOT installed`、重複載入不疊包裝；另把原版 `:287` 改成補換行模擬官方先修一半，
驗證未註冊行之後只多一個空行、連存三次不會越存越多。

**mutation 驗證**（`lua scripts/test_modoptions_persist.lua --mutants`）：21 個突變全部被抓到——拿掉整支修正、修好檔案後不再
load、load 修補不包 `pcall`、沒有黏行也改寫、起頭不取最左、多筆不驗值、寫完不讀回比對、讀回不符不寫回原內容、save 不補行尾、
save 不換回原表、原 save 的錯誤不重拋、準備 OtherOptions 不包 `pcall`、load 過也補檔案裡的行、save 先於 load 不保留檔案內容、
save 先於 load 不拆黏行、已註冊的行也寫回、不去重、空行也傳給 save、拆掉形狀檢查、拆掉冪等 marker、診斷不節流。

實機 E2E（`fixes-e2e` 的 `modoptions-sp`，2026-10-02，42.21.0）：

| 場次 | 結果 |
|------|------|
| `glued`（＋AutoDrive，兩次冷啟動） | 本輪 `ModOptions.ini` 換成三行 fixture：AutoDrive 三個非預設值一半藏在未載入 MOD 那筆後面、一半黏在它前面。主選單一開就印 `split 5 glued records into one per line`；進場 VoiceEnabled=false／VoiceLanguage=3／UTurnMode=2 都套上、檔案 6 行沒有黏行，save 後 106 行一筆一行、未載入 MOD 的兩筆各一行；結束到桌面再開，三個值與兩筆都還在、沒有再印 split。12＋12 個 CHECK，零例外 |
| `noopts`（只有本 MOD） | 沒有任何 MOD 建選項（`Data` 為空、原版不 load，檔案仍有兩行黏行），呼叫套用時同一個 save：3 行變 6 行一筆一行、六筆各一行。9 個 CHECK，零例外 |

### 可退場條件

官方把 `ModOptions.lua:287` 改成寫入時補換行，**且**主選單沒有 MOD 選項時不再以空內容覆寫（先 load 或不 save）。只修前者
擋不住清空；`check_vanilla_alignment.py` 對補換行的寫法有 exithint。官方補了換行而本補丁還沒退場時，未註冊行之後各多一個空行
（本補丁補一次、原版再補一次），空行不再傳給 save，所以不會越存越多。

---

## MDFX_CleanUIConfigLoad — CleanUI 缺失的 `CleanUIConfig.loadConfig`

| 項目 | 內容 |
|------|------|
| 檔案 | `client/Fixes/MDFX_CleanUIConfigLoad.lua` |
| 影響版本 | Build 42.20.4 ＋ CleanUI v2.7.8（workshop 3437629766） |
| 端 | 純客戶端 |
| 狀態 | **已退場**（CleanUI v2.7.9 官方修復；補丁自動不介入，保留為 regression 保險） |

### 症狀

背包與戰利品視窗完全不建立。角色能移動、能聊天、moodle 正常，但整個物品欄介面
不存在。`console.txt` 出現兩筆
`java.lang.RuntimeException: Object tried to call nil in getConfig`：

```
Lua((MOD:CleanUI)).getConfig(CleanUIConfig.lua:410)
Lua((MOD:CleanUI)).new(ISInventoryPane.lua:344)
Lua((MOD:CleanUI)).createChildren(ISInventoryPage.lua:359)
Lua(Vanilla).instantiate(ISUIElement.lua:1007)
Lua(Vanilla).setUIName(ISUIElement.lua:1785)
Lua(Vanilla).createInventoryInterface(ISPlayerDataObject.lua:30)
Lua(Vanilla).createPlayerData(ISPlayerData.lua:172)
```

第一筆更早，來自 `Events.OnGameBoot`（`CleanUIConfig.lua:456` 註冊 `getConfig`），
在連線時的 `Core.ResetLua` 觸發。log 只有兩筆不是間歇性——第一次建構就中斷，
後面的 `getConfig` 呼叫點（`ISInventoryPage.lua:777/788/811`、
`ISInventoryPane.lua:1609/1631`、`HideEquippedItems.lua:63/88`）根本沒機會執行。

### 根因（兩層）

**① vanilla 的 API break**：42.20.4 的
`se.krka.kahlua.j2se.J2SEPlatform.setupEnvironment` 刪掉了 `LuaCompiler.register(env)`
與 serialize.lua 載入（42.20.3 該呼叫在 `J2SEPlatform.java:59`）。`LuaCompiler` class
還在 jar 內，但沒人再 `register`，等於 **Lua 環境不再有 `loadstring`／`loadstream`**。
任何用它讀設定或反序列化的 mod 都當場失效。

**② CleanUI hotfix 的 regression**：作者當日（2026-08-26）發 v2.7.8，自寫 restricted
parser 取代 `loadstring`（change note 自述「the Build 42.20.4 security change that
removed loadstring/loadstream」）。但發佈包**沒有**外層 `CleanUIConfig.loadConfig`：
六個版本目錄（42.12–42.16、42.19）＋`common/` 全 grep 零定義，只留下零 caller 的
`loadConfigFile(fileName)`（`:375`），以及沒有讀取者的 `configCache`（`:2`/`:360`）
與 `legacyConfigFileName`（`:353`）——正是那層 wrapper 該用的材料。
而 `getConfig`（`:410`）與 `updateConfig`（`:446`）都還在呼叫它。

**為什麼整個物品欄消失**：`ISInventoryPane:new()` 在 `:344`
（`CleanUIConfig.getConfig()["hideEquipped"]`）拋出，`return o`（`:345`）沒執行；
vanilla `ISUIElement:instantiate()` 對 `createChildren()` 的呼叫**沒有 pcall 保護**
（`ISUIElement.lua:1007`），例外一路外逃到 Java 的 `protectedCall`，於是
`ISPlayerDataObject:createInventoryInterface` 在 `:30`（`setUIName`）之後全部不執行——
`addToUIManager()`、戰利品面板 `panel3`、`UIManager.setPlayerInventory()` 都沒跑。
掛在同一段初始化流程上的其他 mod 也一併中斷（實測 tsarslib 的
`ISPlayerDataTuning.lua:24` 先呼叫原函式，它的 tuning UI 因此沒建）。

**同作者的對照組（判定 regression 的最硬證據）**：CleanHotBar 同日做了字面相同的
改寫（`chbconfig.lua:252-253` 註解逐字提到 42.20.4 移除 loadstring），但它的
`CHBConfig.loadConfig`（`:287-311`）存在（cache → `.txt` → legacy `.lua`＋回寫遷移）
且每個 I/O 都包 `pcall` ⇒ 零錯誤。同一改寫，差一個外層函式。

### 修法

只補回缺失的那一個函式，形狀沿用 CleanHotBar 的正解，材料全部取自 CleanUI 自己
已存在的成員（`configCache` → `loadConfigFile(configFileName)` →
`loadConfigFile(legacyConfigFileName)`）。不改 CleanUI 任何既有行為。

三個刻意的取捨：

1. **不依賴 mod 載入順序。** 本檔晚於 CleanUI 載入時直接安裝；早於 CleanUI 時改在
   `OnGameBoot` 補裝——vanilla `Core.ResetLua` 先跑完 `LuaManager.LoadDirBase()`
   才觸發 `OnGameBoot`（`Core.java:3948` / `:3962`），那時 CleanUI 一定已載入，
   而我們的 handler 因為先註冊所以先執行，仍早於 CleanUI 自己那個 `getConfig`。
   `loadModAfter=` **不能**用來保證順序：42.20.4 雖有解析
   （`ChooseGameInfo.java:227-228`），但 `getLoadAfter` 全 jar 零 caller。
2. **不建立假的 `CleanUIConfig` 空表**去搶順序。有其他 mod 以全域表存在與否偵測
   CleanUI（log 實測 ProximityInventory 會印 `CleanUI detected -> skipping …`），
   建空表會造成誤判。
3. **不主動寫檔遷移** legacy 設定。CleanUI 的 `getConfig`／`updateConfig` 會在真的
   需要時自己呼叫 `saveConfig`，本修復保持零檔案副作用。但 `configCache` 一定要填
   ——`getConfig` 會被 `ISInventoryPage:isPagelocked()`（`ISInventoryPage.lua:811`）
   這類每幀路徑呼叫，不填等於每幀讀檔。

### 驗證

`lua scripts/test_cleanui_config_load.lua` — 40 項，全綠。十一組 stub 情境涵蓋
**四種「載入順序 × CleanUI 是否已修好」的組合**、快取命中不重讀檔、legacy 退回、
檔名為 nil、`loadConfigFile` 拋出不外洩例外、零 `saveConfig` 呼叫，以及
「只新增 `loadConfig`、不改動任何既有成員」（`pairs` 快照比對）。

第十組直接 `dofile` 真實的 `CleanUIConfig.lua`，並依檔案內容自適應版本：
v2.7.8 世代先以對照組重現「未安裝本修復時 `getConfig` 拋出」再驗證修好；
v2.7.9+ 則驗證對真實官方版本自動退場，並雙向比對「官方 `loadConfig`」與
「本補丁」對同一份設定檔讀出的結果是否相同。

**mutation 驗證**（證明退場守衛承重）：抽掉
`if type(CleanUIConfig.loadConfig) == "function" then return true end` 三行後，
情境 2 與 11 共 6 個檢查轉紅（官方版本被覆寫、印出安裝訊息、多讀一次檔）；
還原後全綠、檔案逐位元一致。

### 退場記錄（2026-08-27）

CleanUI **v2.7.9**（台北 2026-08-27 01:36 發佈）已補回 `loadConfig`，change note
逐字寫「Restored the missing configuration loader **accidentally omitted** in 2.7.8」
——與本節的「打包漏檔」判定一致。

**逐行 diff（v2.7.8 `md5 e748fe75` → v2.7.9 `md5 b829ffd8`）：作者在
`CleanUIConfig.lua` 裡只加了 24 行 `loadConfig`（另補了檔尾換行），結構與本補丁
完全相同**——cache 短路 → 先讀 `.txt` → 退回 legacy `.lua` → 填 `configCache`。
兩邊都是從同作者同日的 CleanHotBar `CHBConfig.loadConfig`（`chbconfig.lua:287-311`）
反推出來的，所以收斂到同一形狀。作者的三行註解也對應本節推導時用的三個線索。

實質差異只有兩點：

1. 作者在 legacy 讀成功後呼叫 `saveConfig` 做遷移；本補丁刻意不寫檔（臨時補丁保持
   零檔案副作用，遷移交給官方版接手時自然發生）。對正式修復而言作者的選擇更完整。
2. 本補丁多了 `pcall` 與 `type` 檢查（比作者保守）。

v2.7.9 另修了 `42.15/42.16/42.19` 的 `ISInventoryPaneContextMenu.lua`（context-menu
dispatcher 的 `loadstring` 殘留），那塊本補丁從來沒碰——只有官方版本有。

**行為等價已實測**：同一份設定檔，一邊跑官方 `loadConfig`、一邊把官方的抽掉讓本補丁
接手，雙向比對兩個 table 的每個 key，結果相同（`test_cleanui_config_load.lua` 情境 10）。

處置：正式服 `pzserver.ini` 的 `Mods=` 與 `WorkshopItems=` 已移除本 MOD
（移除後與安裝前逐行相同，80/80）。MOD 檔案保留——它對 v2.7.9 是完全 no-op
（已用真實 v2.7.9 驗證自動退場），留著等於零成本的 regression 保險。

### 原始的可退場條件（已滿足）

CleanUI 官方補上自己的 `loadConfig`（或改掉 caller）。屆時本修復的
`type(CleanUIConfig.loadConfig) == "function"` 檢查會成立、自動不介入，
**不需要玩家做任何事**。

已回報作者（Steam workshop discussion），內容含 stack、缺失符號的 grep 證據、
CleanHotBar 對照組，以及兩個順帶發現：`loadConfigFile` 用
`getFileReader(fileName, true)` 的第二參數是 `createIfNull`，讀 legacy 路徑會建空檔；
以及該函式缺 `pcall` 保護（CleanHotBar 有）。這兩點 v2.7.9 都還沒動。

---

## MDFX_MultiTileFurniture — 多格家具缺角殘骸鎖死

| 項目 | 內容 |
|------|------|
| 檔案 | `shared/Fixes/MDFX_SpriteGrid.lua`、`server/Fixes/MDFX_MultiTileFurniture.lua`、`client/Fixes/MDFX_MultiTileFurnitureMenu.lua` |
| 影響版本 | 42.20.0（殘骸鎖死自 42.10 引入） |
| 端 | server（權威執行）＋ client（右鍵選項） |
| 狀態 | **已於 0.4.0 移出 MOD**（不再隨遊戲版本維護；本節保留為記錄） |

### 症狀

野餐桌／鋼琴／鍛造爐等多格家具被大槌砸、被搬運撿取、或被殭屍打壞後，地上留下
一兩格殘骸。此後大槌打不掉、拆解不了、也搬不走，且**完全沒有任何提示**，永久卡住。

### 根因（兩層）

**缺角怎麼產生的（MP）**：客戶端破壞／撿取時本地整組移除，送出的封包卻只帶單格
`(x, y, z, index)`。伺服器端 `RemoveItemFromSquarePacket.removeItemFromMap` 只對
`GARAGE_DOOR` / `DOUBLE_DOOR` 做整組展開（:169-171），其餘一律單格刪 → 存檔只少一格。
三條路徑收斂於此：MP 大槌（`GameClient.destroy`）、MP 搬運撿取
（`ISMoveableSpriteProps.lua:1177` 第二格起連封包都不送）、殭屍打壞玩家搬過的家具。

**殘骸為什麼鎖死**：`IsoObjectUtils.getSpriteGridMultiTileObjects` 是 all-or-nothing，
缺任一格就 `return false`，`safelyRemoveTileObjectFromSquare` 回 -1、什麼都不刪且完全靜默。
Lua 端搬運／拆解 gate 同構，連 movables cheat 都繞不過。

### 範圍：只清殘骸，不做斷根

曾經實作過自動斷根——掛 `OnObjectAboutToBeRemoved` 記下群組錨點，延後 60 tick
再回頭掃，仍殘缺就清掉剩餘成員。**那條路走不通，已整段移除。**

第一個問題是 `OnObjectAboutToBeRemoved` 對**所有**移除都會觸發，包含原版蓄意的
單格手術：`MOFeedingTrough.lua:21` 在地圖載入時單格移除再替換成 `IsoFeedingTrough`，
而餵食槽本身就用 sprite grid（`IsoFeedingTrough.java:79-87`）。當場展開會在 chunk
載入時把餵食槽的另一半刪掉。延後確認能繞過這一個案例——因為原版**目前恰好**同幀完成。

但那不是 API 契約。獨立審查用延遲替換 probe 把合法的 replacement 拖過 60 tick，
結果就是不可逆刪掉三個仍有效的成員（`delayed_replacement_removed=3`），
而當時 27 項測試全綠。

根本問題是**沒有行為人、也拿不到操作意圖**：事後掃描只看得到「現在缺一格」，
分不出那是永久殘骸還是延遲完成的替換。加長 timeout、記 identity snapshot、
掛 `OnObjectAdded` 取消機制，都只能縮小視窗，無法證明零資料損失。

所以新的缺角仍會產生，但玩家隨時能用右鍵清掉。要真正斷根，該在 Java 端
`removeItemFromMap` 比照車庫門直接展開——**那裡才拿得到明確的操作意圖**。

判準是 `getSpriteGridMultiTileObjects` 的逐格 sprite 身分比對，與原版鎖死用的那道
gate 同構——但**有一處必須刻意不照抄**，見下。

### ⚠ 為什麼不能照抄 Java 那個 boolean

`getSpriteGridMultiTileObjects` 在「格子沒載入」與「格子缺成員」兩種情況都回 `false`。
原版拿它當**許可 gate**：回 false 就是「無法確認 → 不准移除」，fail-closed。
本 MOD 反過來拿判準當**刪除依據**——照抄的話「還沒載入的格子」會被當成缺角，
跨 chunk 邊界或相鄰 chunk 未載入的**完好家具會被直接刪掉**。

所以 `MDFX_SpriteGrid.scan` 把兩者分開回報：

| 情況 | 回報 | 後果 |
|------|------|------|
| 格子有載入、但缺該成員 | `complete = false` | 真殘缺，可清 |
| 格子沒載入 | `unknown = true` | **絕不清**（無法確認就不動） |
| 稀疏 grid（該格無預期 sprite） | `unknown = true` | **絕不清**（原版是讓它永遠撿不起來） |

殘骸留著沒關係，等格子載回來再清一次就好；誤刪完好家具才是不可逆的。

### 容器內容物

原版 `RemoveTileObject` 完全不管容器，移除就等於把裡面的東西一起毀掉。玩家用大槌拆是他自己的決定，
但本 MOD 這個「清殘骸」選項不該順手吃掉裡面的東西。因此群組內只要還有內容，
清除指令一律放過它。玩家把東西拿出來後就能清——殘骸擋的是「移除」，
不擋「開箱拿東西」。

判定**直接用原版自己的 `isObjectNoContainerOrEmpty()`**（`IsoObject.java:6692`），
不要自己重寫——它已經涵蓋：

- 所有 `ItemContainer`（`getContainerCount()` ＝ primary ＋ `secondaryContainers`）
- **未探索**的容器（戰利品還沒生成，`size()` 是 0 但「將會」有東西）
- **部分** component 狀態 —— 涵蓋範圍見下

⚠ **不可宣稱「涵蓋所有 component 狀態」**。`isObjectNoContainerOrEmpty` 只是逐一詢問
每個 component，而 `Component.isNoContainerOrEmpty()` 的預設實作直接回 `true`
（`Component.java:125`）。42.20 只有兩個實質 override：`CraftLogic`
（`CraftLogic.java:670`）與 `Resources`（`Resources.java:449`，且只保護
`ResourceType.Item`）。巢狀 fluid/resource、沒有 override 的 stateful component、
自訂 `modData` 都不在保證範圍內。原版目前已知配置落在受保護路徑上，
但**第三方家具或未來新增的 component 不保證**。

它另外**漏掉流體**，必須自己查：`FluidContainer` 雖然是 component（`ComponentType:62`），
卻沒有 override `isNoContainerOrEmpty()`，會走 `Component` 的預設實作。
餵食槽有水時 primary `ItemContainer` 甚至是 `nil`，內容全在 `FluidContainer`
（`IsoFeedingTrough.java:59`）；原版判「有沒有流體」的寫法見 `IsoObject.java:2650`。

### 錨點必須唯一

`originOf` 用 `getSpriteGridPosX(sprite)` 回推群組錨點，但原版那個方法走
`getSpriteIndex`，只回**第一個**相符的位置（`IsoSpriteGrid.java:52`），
而 `validate()` 不檢查唯一性。grid 內若有重複 sprite，錨點就會算錯、掃描範圍偏移到隔壁，
把**完好群組**的成員刪掉。因此掃描前先數該 sprite 在 grid 內的出現次數，
不等於 1 一律回 `nil`（＝無法判定，呼叫端不得刪除）。

原版資產目前沒發現重複 grid，但第三方 MOD 或異常資產會命中。

移除走 `square:transmitRemoveItemFromSquare(obj, false)` 兩參數非 safe 版
（`IsoGridSquare.java:6319`），繞過整組檢查；原版自己就在用（`MOHutch.lua:99`、
`MOFeedingTrough.lua:21`）。在伺服器端會走 `GameServer.RemoveItemFromMap`：
廣播給相關客戶端＋伺服器自刪，同步正確。

**清舊殘骸**：世界上既有的殘骸不會再觸發 event，需要人工清。右鍵選單補一個
「清除卡住的家具殘骸」，只在該物件確實屬於殘缺群組時出現；MP 下經 `sendClientCommand`
交由伺服器權威執行。伺服器端把這條指令當**信任邊界**處理：
`module` / `command` / 座標 / 玩家狀態全部由客戶端送來，一律重驗——

- 座標型別驗證（畸形封包不得在 event 迴圈裡拋例外，整段 `pcall` 包住）
- 玩家存在且未死亡
- 距離 ≤ 12 格、Z 差 ≤ 1
- **安全屋授權，逐一檢查每個待刪成員**：原版右鍵選單本身被 `safehouseAllowInteract`
  擋著（`ISWorldObjectContextMenu.lua:211`），但那是**客戶端**的 gate——惡意客戶端
  可以直接送這條指令繞過去。伺服器端用 `SafeHouse.isSafehouseAllowInteract(sq, player)`
  （`SafeHouse.java:245`，與原版 UI 同一套 policy，含管理員 capability 與交戰中對手）
  再擋一次。

  ⚠ **不能只驗指令指定的那一格**。安全屋是矩形範圍，而實際被刪的是 `inspect` 回傳的
  整組成員——只驗一格就會出現「站在屋外，對屋內的 sibling 下手」的繞道。

- 最終能不能刪由**伺服器自己重新掃描**決定，不看客戶端說了什麼；
  `inspect` 已涵蓋「不得未載入」「不得錨點模糊」「不得完好」「不得有內容物」四道，
  所以這條指令拆不掉完好家具，也吃不掉玩家的儲物

**點擊時重新判定（TOCTOU）**：右鍵選單建立當下抓到的成員清單不能拿去刪。
選單建好到玩家點擊之間世界可能已經變了——別人補好了、chunk 卸載了、有人往容器裡塞東西。
MP 有伺服器那道重驗擋著，**單人沒有**，沿用舊清單就會直接刪錯東西。
因此點擊時一律重跑 `inspect`，用當下的結果決定。

### 已知殘留

出手者自己的客戶端可能短暫少顯示同格的其他物件：`GameServer.RemoveItemFromMap` 以
`obj.getObjectIndex()` 定址廣播，且 `sendToRelative(..., null, ...)` 不排除出手者，
而出手者本地早已整組移除、索引已位移。不過 `processClient`（:85）有
`index < sq.getObjects().size()` 邊界檢查，家具是該格最後一個物件時（最常見）
直接 no-op；只有家具之後還排著其他物件才會誤刪，且純本地暫態、chunk 重載自癒、
不碰伺服器存檔。要連這個都乾淨才需要 Java patch（在 `removeItemFromMap` 比照
車庫門直接展開）。

### 驗證

```
lua scripts/test_multitile_furniture.lua
```

25 項離線檢查，涵蓋每一條會造成**不可逆刪除**的路徑：
錨點回推、完整群組不誤判、缺一格判殘缺、同格無關物件不算成員、移除走非 safe 版、
**未載入格子回報 unknown 且不得清除**、**重複 sprite 的 grid 判為無法判定**、
**五種內容物一律放過**（primary／secondary／未探索容器、component 狀態、流體）、
距離驗證、完好家具不得被指令拆掉、畸形封包與死亡玩家被擋、
**安全屋授權**（未授權擋下、授權放行、**跨界繞道整組擋下**）、
**點擊時重新判定**（補回完整／容器被塞 → 不刪；情況未變 → 正常清）、
**MP 分支不本地刪除且 payload 正確**、選單本身也擋安全屋。

**event 白名單防迴歸**：所有待測檔載入完之後，斷言註冊的 event 只有
`OnClientCommand` 與 `OnFillWorldObjectContextMenu`（兩者都由玩家動作觸發，
都有行為人）。任何定時或世界事件的註冊都會讓測試失敗——不論它掛在 `OnTick`、
`EveryOneMinute` 或 `OnObjectAboutToBeRemoved`，也不論寫在 server 還是 client。

只黑名單 `OnTick` / `OnObjectAboutToBeRemoved` 是不夠的：獨立審查實測，
改用 `EveryOneMinute`、或改在 client 端註冊，都能繞過黑名單版本。

每一道會造成不可逆刪除的防線都做過 mutation test——把該防線改回錯誤行為後，
對應檢查立即失敗：

| 突變 | 失敗的檢查 |
|------|-----------|
| 未載入格子當成缺角 | 未載入的格子必須回報 unknown |
| 拿掉重複 sprite 檢查 | 重複 sprite 的 grid 必須回報無法判定 |
| 拿掉容器／component 檢查 | 有內容物時不得判為可清除（primary 容器） |
| 拿掉流體檢查 | 有內容物時不得判為可清除（流體非空） |
| 安全屋永不阻擋 | 非授權玩家不得清安全屋內的殘骸 |
| 安全屋只驗指令那一格 | 有 sibling 在未授權安全屋內時必須整組擋下 |
| TOCTOU：點擊時不重驗 | 點擊時應重新判定 |
| server 注入 `OnTick` | 註冊了白名單外的 event |
| server 注入 `OnObjectAboutToBeRemoved` | 註冊了白名單外的 event |
| client 注入 `OnTick` | 註冊了白名單外的 event |
| server 改用 `EveryOneMinute` | 註冊了白名單外的 event |

### 可退場條件

官方在 `removeItemFromMap` 比照 `GARAGE_DOOR` 對 sprite grid 做整組展開
（那也同時斷了根），或讓 `safelyRemoveTileObjectFromSquare` 對殘缺群組不再靜默失敗。

### 待辦

斷根若要做，走 Java patch（`MinidoracatJavaPatchFor42`）：在 `removeItemFromMap`
拿得到明確的操作意圖，不需要猜延遲，也沒有 Lua 這邊那些 guard 問題。

---

## MDFX_AnimalTrailerSize — 動物屍體 `animalTrailerSize` 欄位缺失

| 項目 | 內容 |
|------|------|
| 檔案 | `42/media/lua/client/Fixes/MDFX_AnimalTrailerSize.lua` |
| 影響版本 | 42.20.0（更早版本同樣有此寫法） |
| 端 | 純客戶端 |
| 狀態 | **已於 0.4.0 移出 MOD**（不再隨遊戲版本維護；本節保留為記錄） |

### 症狀

拖車的動物門開著時右鍵載具、或按拖車動物 UI 的「加入動物」鈕：整段車輛右鍵選單消失、
死掉的動物裝不上拖車。`console.txt`：

```
java.lang.RuntimeException: __mul not defined for operands in round
  Lua(Vanilla).round(luautils.lua:709)
  Lua(Vanilla).doAnimalSubMenu(ISVehicleMenu.lua:806)
  Lua(Vanilla).FillMenuOutsideVehicle(ISVehicleMenu.lua:709)
  Lua(Vanilla).createMenu(ISWorldObjectContextMenu.lua:213)
```

按拖車動物 UI 的鈕時則是 `onAddAnimal(ISVehicleAnimalUI.lua:189)` 那條堆疊。

### 根因

原版 `ISVehicleMenu.doAnimalSubMenu`（42.20 第 755 / 806 行）直接把
`body:getModData()["animalTrailerSize"]` 丟給 `round()`，而 `round()` 是
`math.floor(num * mult + 0.5)` —— 欄位缺失時 `nil * mult` 直接拋例外。

該欄位全遊戲唯一寫入點是 `ButcheringUtil.lua` 的 `setAnimalBodyData()` 第 45 行。
問題是那個函式：

```lua
local def = AnimalPartsDefinitions.animals[fullName];
modData["parts"] = def ~= nil;      -- 第 19 行：明知 def 可能是 nil
...
if def.feather then                 -- 第 27 行：卻無條件解參考
```

`def` 為 nil 時就在寫入 `animalTrailerSize` 之前拋錯。Java 端
`IsoDeadBody.setAnimalData()` 是 `protectedCallVoid`，錯誤被吞掉後照樣往下寫
`this.animalType`，於是屍體變成「`isAnimal()` 為 true、但 modData 缺欄位」的
**永久壞資料**；早於此欄位存在的舊屍體同理。

`AnimalPartsDefinitions` 涵蓋原版全部 30 種動物 × 品種共 63 個 key，
所以 def 為 nil 通常來自模組動物或舊存檔屍體。

### 為什麼是客戶端修復

Java 端對缺欄位是容忍的：

- `BaseVehicle.canAddAnimalInTrailer(IsoDeadBody)` 用 `rawgetFloat`，缺鍵回 `-1.0`（`KahluaTableImpl.java:128`），不會炸
- 真的裝上車之後 `recalcAnimalSize()` 走 `IsoAnimal.getAnimalTrailerSize()`
  （`adef.trailerBaseSize × animalSize`）重算，根本不看 modData
- `BaseVehicle.testCollisionWithCorpse` 對 `corpseLength` / `corpseSize` 都有做
  null 檢查 —— 官方自己知道這些欄位可能缺

也就是說伺服器不會崩、資料也不會壞，**只有客戶端那行組字串的 Lua 沒防護**。
伺服器端 Java patch 就算補上寫入，也只救得了新屍體，救不了世界上既有的壞屍體。

### 修法

呼叫原版函式前，把掃描範圍（載具格 -6 ～ +5，與原版同）內缺欄位的動物屍體補回：

```
AnimalDefinitions.animals[type].trailerBaseSize * body:getAnimalSize()
```

與 Java `IsoAnimal.getAnimalTrailerSize()` 同式，值精確（原版 30 種動物全都有
`trailerBaseSize`）。已有正確數值一律不覆蓋；已有值但不是數字則覆寫（否則 `round()` 照樣炸）。
手上拿著的屍體（原版第 755 行同樣沒防護）一併補。

未知（模組）動物補 **0**，這是**本 MOD 的取捨，不是 Java parity**：
`KahluaTableImpl.rawgetFloat`（`KahluaTableImpl.java:128`）缺鍵時實際回 `-1.0F` 而非 0，
但 −1 當「佔用空間」在 `canAddAnimalInTrailer` 裡是負佔用、也無法顯示；
0 是最接近該寬鬆語意又不會顯示成負數的值。

逐具隔離：每具屍體各自 `pcall`。若整批共用一個 `pcall`，第三具出問題時
第四具之後全部漏補、原版照樣崩——等於沒修。

補資料整段包在 `pcall` 裡 —— 修復本身絕不能變成新的選單殺手。但不靜默失敗：
接住錯誤後印一次 `[MinidoracatFixes]` 診斷行（每 session 一次，右鍵不洗版）。
本修復若因後續 build 的 API 變動而失效，症狀會原封不動退回原本的 `__mul` 崩潰，
console.txt 必須留得下指向本 MOD 的線索。

### 驗證

```
lua scripts/test_animal_trailer_size.lua
```

9 項離線檢查：正常補值、不覆蓋既有正確值、既有值非數字時覆寫、非動物屍體不碰、
未知動物補 0、包裝後原版函式照常回傳、**同格第一具拋錯不害第二具漏補**、
手上屍體也補到、**重複載入不疊 wrapper**。

> 測試的 vanilla stub 會照原版一樣呼叫 `vehicle:getSquare()`（原版
> `ISVehicleMenu.lua:775` 自己也走這條）。少了這一步，「壞 vehicle」類測試會變成
> 假陽性——看起來是本修復擋下了，其實原版根本也活不過那一行。

遊戲內：把有問題的動物屍體丟在開著動物門的拖車旁，右鍵載具 —— 修復前整段
車輛選單消失，修復後選單完整且「加入動物」可點。

### 可退場條件

官方在 `ISVehicleMenu.doAnimalSubMenu` 對 `animalTrailerSize` 加上 nil 防護，
或修掉 `ButcheringUtil.setAnimalBodyData` 第 27 行的無條件解參考。

### 待查

無法從客戶端 log 判定該伺服器上的壞屍體是「模組動物」還是「舊存檔屍體」——
要看伺服器端 log 有沒有 `setAnimalBodyData` 的 Lua 錯誤。不影響本修復是否正確，
但若是模組動物，代表壞屍體會持續產生。
