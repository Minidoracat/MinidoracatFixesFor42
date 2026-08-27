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

`lua scripts/test_butcher_meatratio.lua` — 29 項，全綠。涵蓋：正常屍體完全透傳
（參數、回傳、呼叫次數）、壞屍體擋下＋診斷恰一次、`meatRatio=0` 不誤攔而
string／boolean 攔下、carcass=nil 擋下、getModData 拋錯時 fail-open、重複載入
不疊 wrapper、後載 MOD 整支替換後 `OnGameBoot` 復查重新包裝（壞形狀恢復被擋、
正常路徑透傳到替換版）、vanilla 缺席不亂補、成員快照（只新增 sentinel）。
含對照組：同一壞屍體直打 stub vanilla 確實拋錯。

**mutation 驗證**（`抽掉防線 → 對應檢查轉紅 → 還原全綠`）：

| 突變 | 轉紅 |
|------|------|
| 早退 gate 改 `if false then` | 12 項（例外外洩、原函式被呼叫、診斷缺席…） |
| 型別判準退化回 `== nil` | 2 項（string／boolean 放行） |
| OnGameBoot 復查永遠自認在位 | 2 項（替換後 guard 未恢復） |

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
| 端 | server（此形狀只存在於 server 端的封包重建；單人／客戶端的 `self.animal` 是 `new()` 當下的本地物件引用，不會是 nil） |
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

**安裝機制**：sentinel 存 serverStart wrapper 引用（三個 method 同批安裝、
同批判斷）；`Core.ResetLua` 重載時重新包裝、後載 MOD 整支替換時 `OnGameBoot`
復查把「他的版本」當新 original 再包一層。與另兩檔同款，詳見
MDFX_ButcherMeatRatio 節。

### 驗證

`lua scripts/test_pet_animal_guard.lua` — 30 項，全綠。涵蓋：動物存在時三個
method 全透傳、nil 時 serverStart 擋下＋`forceComplete` 恰一次＋診斷恰一次、
`netAction` 也 nil 不炸、`pettingFinished` 靜默略過而其他 event 照常透傳、
complete 回 false、重複載入不疊、後載 MOD 替換後復查重裝（壞形狀恢復被擋＋
正常路徑透傳到替換版）、vanilla 缺席／部分缺席不亂補、成員快照。
含對照組：stub vanilla 對 nil 動物確實拋錯。

**mutation 驗證**（`抽掉防線 → 對應檢查轉紅 → 還原全綠`）：

| 突變 | 轉紅 |
|------|------|
| serverStart gate 改 `if false and ...` | 6 項 |
| complete 改回 true | 1 項（先例檢查） |
| OnGameBoot 復查永遠自認在位 | 2 項（替換後 guard 未恢復） |

遊戲內：MP 撫摸動物並讓另一管理端立即移除該動物——修復前 3 秒後 server log
出現 `attempted index: petAnimal` 例外；修復後 log 出現一行
`[MinidoracatFixes] ISPetAnimal.serverStart: animal resolved to nil`、無例外。

### 可退場條件

官方在 `ISPetAnimal:serverStart` 補上與 `ISLoadBulletsInMagazine` 同款的
nil guard（`check_vanilla_alignment.py` 對 `if not self.animal then` 形狀有
exithint）。

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
