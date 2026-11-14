# 修復清單

本 MOD 每加一項修復，就在這裡登記一筆：症狀、根因、修法、驗證方式、可退場條件。
「可退場」= 官方哪天修好了，就從 MOD 移除該檔並在此標記為已退場。

## 42.22.2 對版（2026-11-10）

以 42.22.2 原版 Lua 與反編譯快照 `42.22.2-20261109` 逐項比對 42.21.0（各節行號仍以標示的版本為準）；`check_vanilla_alignment.py` 77 條全部對齊。

| 修復 | 42.22.2 | 依據 |
|---|---|---|
| `MDFX_ReloadSpeedGuard` | 還需要，**擴充**：42.22 新增一種原版錯誤（形狀二，見該節） | `ISReloadWeaponAction.lua:90`、`:100`／`:102` |
| `MDFX_HutchNullSlotGuard` | 崩潰路徑官方已修（`IsoHutch.removeFromWorld` 判 null）；客戶端仍寫入 null 格，本修復保留，繼續清（使用者 2026-11-10 裁定，退場條件已改） | 見該節「42.22 對版」 |
| `MDFX_HealthCheatPermission` | 還需要：42.22 官方補上了權限驗證，但參數不對時原版仍會出錯；本修復照樣安裝 | 見該節「42.22 對版」 |
| `MDFX_ButcherMeatRatio` | 還需要：42.22 的 `ISButcherAnimal:complete` 多擋了已撿走的屍體，壞屍體仍在 `ButcheringUtil.lua:70` 出錯 | `ISButcherAnimal.lua:51-57` |
| `MDFX_FarmingGosPrune` | 還需要；移出前的等待原本防的 chunk 讀寫競態，42.22 官方已補上，等待保留當保險 | 見該節「設計審查」 |
| `MDFX_DeathSync` | 還需要：殭屍拖倒致死仍只在客戶端判定，42.22 的命中改動沒碰這條 | `PlayerHitReactionState`、`Bite` 兩版相同 |
| 其餘現役 14 支、已退場 3 支 | 原版 Lua 檔沒改或改動與修復無關；依賴的 Java 類別沒改或只改行號，現役的還需要、已退場的仍不介入 | — |

實機（42.22.2，`fixes-e2e` skill 的情境，輪次名 `fx4222-*`，跑完 33 輪；各輪判定寫在該 skill 的狀態表）：安裝面兩端沒有 `NOT installed`；
修正組全部通過（裝彈兩種形狀的單人與多人、農作物同步、農作物存檔三件的單人與多人、餵水與動物動作、MOD 選項三種、雞舍、全域物件重複新增、
充電器、多人死亡同步、健康作弊）。原版對照組（把修正檔拿掉）照樣重現的有：裝彈形狀二、農作物重複同步、餵水與動物動作、MOD 選項被清空、
全域物件重複新增、充電器每幀重算、多人死亡沒同步、健康作弊參數不對時出錯；不再重現的有：雞舍卸載崩潰（42.22 官方已修）、失效房間崩潰（42.21 已修）、
健康作弊的權限缺口（42.22 官方已修）。沒有實機重現的（封包重建時物件剛好消失這類時序）照舊只驗安裝面與離線測試：撫摸、擠奶、倒液體、換裝、擺家具、鎖車門、屠宰。
裝彈形狀一與多人死亡同步的修正組第一次沒過，原因都在情境（探針把被接住的原版錯誤算成失敗；這次的伺服器範本沒有進場隱身，角色太早被殺），改情境後重跑通過。
死亡同步第一次那輪，走原版路徑的 B 屍體在死後 6.5 秒就不在了（推測是被咬死後屍變，沒有直接證據），重跑那輪 3 秒與 12 秒都在；和本修復無關（B 不經過修復），記在 skill 的情境專屬坑。

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

## MDFX_ReloadSpeedGuard — `setReloadSpeed` 對「手持非槍械」與「沒穿彈藥背帶」缺防護

| 項目 | 內容 |
|------|------|
| 檔案 | `shared/Fixes/MDFX_ReloadSpeedGuard.lua` |
| 影響版本 | 形狀一（手持非槍械）Build 42.20.4 起；形狀二（穿 `RELOAD_FAST_MAGAZINES` 裝備、沒穿彈藥背帶）Build 42.22.0 起，42.22.2 仍在 |
| 端 | shared（server／client／單人同一段程式碼同一爆點，三端都保護） |
| 狀態 | **現役** |

### 症狀

特定裝備組合下按裝彈完全沒反應：子彈不消耗、彈匣不填充、沒有動畫。伺服器 log
（正式服實測 7 次/輪）：

```
java.lang.RuntimeException: Object tried to call nil in setReloadSpeed
  Lua(Vanilla).setReloadSpeed(ISReloadWeaponAction.lua:95)
```

42.22 起另一種：穿肩掛槍套、胸掛或 ALICE 腰帶吊帶，沒穿彈藥背帶時，裝填左輪、散彈槍、
栓動步槍等不吃彈匣的槍（或手拿近戰武器對彈匣裝子彈）一開始就出錯：
`attempted index: getClothingItemName of non-table: null`，一顆都裝不進去，之後裝彈動作每幀再出一個錯誤，直到動作被取消
（42.22.2 實機對照組，見「驗證」）。官方論壇 42.22.0 已有回報（topic 102797，ALICE 腰帶吊帶＋左輪）。
正式服 log 實據：2026-11-09 升到 42.22.2 後的第一個場次（約 85 分鐘）出現 20 次，都在 `:100`（散彈槍），13 次由裝彈
（`ISReloadWeaponAction:serverStart`）、7 次由上膛（`ISRackFirearm:serverStart`）進來；當時線上的 0.17.0 還不認得這種形狀，
照設計印一行 `NOT masking it (re-throwing): attempted index: getClothingItemName of non-table: null java.lang.RuntimeException` 後原樣重拋
（這串就是形狀二辨識比對的實際訊息）。之後三個深夜場次是 0 次。

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

42.22 的 :88／:90 多看 `RELOAD_FAST_MAGAZINES`：:88 看手上（`hasEquippedTag`），:90 的 gate 另加
`character:hasWornTag(ItemTag.RELOAD_FAST_MAGAZINES)`（`IsoGameCharacter.java:5099`，看身上穿的）。
原版帶這個標籤的是 `HolsterShoulder`（shoulderholster）、`Bag_ChestRig`(`_Tarp`)、`Bag_ALICE_BeltSus`(`_Camo`、`_Green`)（webbing），
都不在 `AMMO_STRAP`。穿著它們、沒穿彈藥背帶時 gate 也會進來；槍吃彈匣就在 :98 結束，
不吃彈匣時（散彈槍走 :100，左輪、栓動步槍與手持近戰武器走 :102）前面的標籤都不符，
就對 nil 的 `strap` 呼叫 `getClothingItemName()`（**形狀二**）。42.21 這兩行也在，但要手上拿著
帶 `RELOAD_FAST_*` 標籤的東西才進得來，正式服沒有紀錄；42.22 起一般裝備就會踩到。

### 修法

包裝 `ISReloadWeaponAction.setReloadSpeed`（static，7 個 caller 全部表查呼叫：
Reload／Eject／Insert／LoadBullets／UnloadFirearm／UnloadMagazine 的 initVars
以 rack=false、`ISRackFirearm` 以 rack=true）：

1. 先 `pcall` 原函式，成功即結束——**正常玩家的裝彈速度公式一個位元都沒動**，
   vanilla 更新公式時正常路徑自動跟進。
2. 原函式拋出時**正面辨識已知壞形狀**：
   - 形狀一：手持物存在且 `not instanceof(gun, "HandWeapon")`；
   - 形狀二：`getWornItem(ItemBodyLocation.AMMO_STRAP)` 是 nil，而且錯誤訊息含 Kahlua 對 nil 取值的完整訊息
     `attempted index: getClothingItemName of non-table: null`（`KahluaThread.java:1134-1137`；只比方法名稱會連別的 `getClothingItemName` 錯誤一起吞掉）。
   吻合才以 vanilla `:76-83`／`:109-112`
   的「無背帶加成」語意重算：`0.8 ＋ 裝填技能×0.10 － 恐慌×0.05`（rack 時
   `＋技能×0.04`、不扣恐慌）、駕駛中再 `×0.8`，寫入 `ReloadSpeed` 後各印一次
   診斷（兩種形狀分開）。形狀一：背帶那段（:85-108）本來就只對「手持槍械」有意義，跳過它是這個
   形狀下的正確語意，不是少算。形狀二：走到 strap 取值＝前面的標籤都不符，沒穿背帶時原版本來就是
   無加成，fallback 等於原版本來要給的值。重算再失敗整體退 1.0（下游
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

**已知限制：原版的錯誤堆疊照樣進 log**。Kahlua 在拋出的當下就把錯誤與 Lua 堆疊寫進 log、錯誤計數加一，`pcall` 接住也一樣
（`KahluaThread.java:893-896`；家族 `pitfalls.md`「包在 `pcall` 裡只會印一段堆疊」）。所以每次走 fallback，`console.txt`／
`server-console.txt` 仍有一段 `setReloadSpeed` 的原版堆疊（堆疊裡多一框 `MDFX_ReloadSpeedGuard.lua` 的 `wrapper`），裝彈照常完成；
本 MOD 自己的診斷才是一 session 一次。2026-11-10 42.22.2 實機 `fx4222-reload-sp` 的 `client1/console.txt` 可見。玩家畫面沒有提示（錯誤計數在原版只有
除錯用的錯誤視窗 `DebugErrorsWindow.lua` 在讀）。要讓堆疊消失得改成「先判斷、不呼叫原版」，那要把原版 :86-:104 的分支抄進來，沒做。
看 log 數原版錯誤時，帶 `wrapper(MDFX_ReloadSpeedGuard.lua` 這一框的是已被接住的。

**安裝機制**：sentinel 存 wrapper 自身引用；`Core.ResetLua` 重載時重新包裝、
後載 MOD 整支替換時 `OnGameBoot` 復查把「他的版本」當新 original 再包一層。
與另兩檔同款，詳見 MDFX_ButcherMeatRatio 節。

### 驗證

`lua scripts/test_reload_speed_guard.lua` — 38 項，全綠。涵蓋：原函式成功時
完全透傳（不重算、不多寫變數、不印診斷）、已知壞形狀 fallback 三種精確值
（rack=false：`0.8+4×0.10−2×0.05=1.1`；rack=true：`0.8+5×0.04=1.0` 恐慌不參與；
駕駛：`×0.8`）、診斷恰一次、未知原因（手持槍械卻拋／辨識自身拋錯／空手拋錯）
原樣重拋且不寫變數、fallback 也炸整體退 1.0、`setVariable` 拋錯不外洩、
重複載入不疊、後載 MOD 替換後復查重裝（正常路徑透傳到替換版＋壞形狀恢復被擋）、
vanilla 缺席不亂補、成員快照；形狀二：手持槍械、沒穿背帶、對 nil 取 `getClothingItemName` 的錯誤走 fallback（rack 與否都對），
兩種形狀的診斷各印一次、新的診斷不寫原版檔名行號；穿著背帶卻同樣拋錯、沒穿背帶但錯誤不是 `getClothingItemName`、
或方法名稱相同但不是對 nil 取值（`non-table: false`、其他訊息）都原樣重拋。

**mutation 驗證**（`抽掉防線 → 對應檢查轉紅 → 還原全綠`；2026-11-10 對現行 38 項重量）：

| 突變 | 轉紅 |
|------|------|
| 抽掉 `pcall` 保護（直接呼叫原函式） | 測試在第 [3] 節中斷（例外外洩） |
| 辨識永真（吞掉一切 exception） | 10 項（未知原因該重拋的全部失守） |
| fallback 係數 0.10→0.20 | 4 項（精確值 1.5≠1.1） |
| OnGameBoot 復查永遠自認在位 | 1 項（替換後 guard 未恢復） |
| 形狀二不看有沒有穿背帶 | 1 項（穿著背帶的同樣錯誤被吞） |
| 形狀二不看錯誤訊息 | 7 項（別的錯誤被吞） |
| 形狀二只比方法名稱 | 2 項（同方法名、不是對 nil 取值的錯誤被吞） |
| 拿掉形狀二 | 5 項（42.22 的錯誤外洩） |
| 兩種形狀共用一次診斷旗標 | 1 項（第二種形狀不印） |
| 形狀二印形狀一的訊息 | 3 項 |

遊戲內：手持手電筒＋穿彈藥背帶對彈匣裝彈——修復前 log 出現
`Object tried to call nil in setReloadSpeed` 且裝彈無反應；修復後裝彈正常完成、
log 出現一行 `[MinidoracatFixes] setReloadSpeed crashed ... fallback`。
手持槍械正常裝彈速度不變。

形狀二實機（2026-11-10，42.22.2，`fixes-e2e` skill 的 `reload-strap --define kit=holster`：穿肩掛槍套、沒穿彈藥背帶、手持空的左輪，走原版介面裝 6 顆）：

- 對照組（修正檔拿掉）單人 `fx4222-rlh-ctl-sp`、多人 `fx4222-rlh-ctl-mp`：`start()` → `initVars()` → `setReloadSpeed`（`ISReloadWeaponAction.lua:102`）
  拋 `attempted index: getClothingItemName of non-table: null`，多人伺服器的 `serverStart()`（:164）同樣拋；20 秒內一顆都沒裝進去，
  之後 `update`（:13）每幀再拋 `__sub not defined for operands`（單人 20 秒約 4,800 次，console.txt 開頭被洗掉，完整記錄在 `launcher.txt`）。
- 修正組單人 `fx4222-rlh-sp-final`、多人 `fx4222-rlh-mp-final`：`ReloadSpeed=0.800` 等於無背帶公式，6 顆裝滿、子彈扣 6 顆；診斷行
  `setReloadSpeed crashed on a missing ammo strap` 每端恰一行（多人的伺服器與客戶端各一行），沒有 `NOT masking it`。

形狀一同日在 42.22.2 重跑（`kit=strap`：彈藥背帶＋手持手電筒，對彈匣裝 5 顆）：單人 `fx4222-reload-sp2`、多人 `fx4222-reload-mp2` 都 PASS，
診斷行 `setReloadSpeed crashed on a non-firearm` 每端恰一行。

### 可退場條件

形狀一：官方在 :95 前檢查手持物是否槍械（`check_vanilla_alignment.py` 對
`instanceof(gun, "HandWeapon")` 形狀有 exithint），或改用基類安全的查法。
形狀二：官方在 :100／:102 對 `strap` 判 nil（exithint：`strap and strap:getClothingItemName()`）。
兩種都修好才移出；只修一種時，把那一種的辨識拿掉。

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
- B 的等待理由原本是 `ServerChunkLoader` 的競態：42.21 已被存檔執行緒拿走、正在寫的 chunk 不會被之後的讀取
  等待。42.22 起讀 chunk 時改拿存檔執行緒手上那份（`ServerChunkLoader` `getPendingChunkData`，佇列與正在寫的都找），
  這個競態已由官方補上；等待保留當保險，程式不改。再加 30 秒真實時間，是因為全員睡覺快轉時 10 遊戲分鐘可能不到 1 秒。
- A 只往前調：時鐘由 C 還原後，最後一次存檔之後才卸載的 chunk 可能帶著略新的 `lastWaterHour`，
  照原版無條件寫會把本來幾小時後就要長的作物往後延幾百小時。

### 與原版的差異與殘留風險

- **移出期間，dead／rotten 每 10 遊戲分鐘 1/5000 變成 destroyed 的外觀轉換暫停**，格子再載入後照常。
  這也讓它們較晚進入 `plowFadeCheck` 的清除範圍。這是本修復唯一看得到的行為差異，使用者已同意。
- **移出之後 chunk 是唯一的來源**：chunk 存檔失敗（`ServerChunkLoader` 存檔執行緒只記 log），或改過的客戶端在最後一次
  掃描到卸載之間改了那格的 modData（`ObjectModDataPacket.java:21-27,46-58` 不驗來源），重建出來的就是
  那份內容。原版客戶端不送農作物 modData。42.21 另有「`IsoChunk` 先記 checksum 再寫檔、之後同內容的存檔被跳過」，
  42.22 起專用伺服器的卸載與存檔改走 `ServerChunkLoader.writeChunk`（先寫檔再記 checksum），不再適用。
- **整個 MOD 移除時**，被移出、所在區域之後沒再載入過的踩爛／已收成作物會變回原版的孤兒；
  dead／rotten 會由原版 `LoadPlant` 走 `stateFromIsoObject` 重新登記。移出部分可以先單獨退場，
  重建部分要等官方替 trampledSprite 註冊 OnLoad。三份 Workshop 描述都有寫。
- **效益只及於本 session 載入又卸載過的區域**，而且 `spriteName` 為 nil 的條目永遠不移出
  （例如還沒播種就被踩的翻土格：`trampledSprite["none"]` 不存在，`getSpriteName` 回 nil）。
  事故時的 20,100 個物件裡，這類 destroyed 有 236 個。
- **重建時的新增封包送給所有連線**，一個 cell 載入的封包數＝該 cell 被移出的作物數×連線數；
  移出每次最多 100 株，重建端沒有上限。
- **重建的新增封包撞上還在登入的玩家**（2026-10-03 正式服，見 `MDFX_GosDuplicateNewGuard`）：伺服器把連線加進廣播表
  （`GameServer.java:4427-4436`）比打包連線清單（`ConnectionDetails.java:38`）早一段登入驗證（Steam 實測 1.9 秒），
  這段時間重建的作物同時出現在清單與延後的新增封包，原版客戶端進遊戲時每株跳兩條錯誤（資料沒壞）。原版種植、蓋營火也有
  同一缺口，本修復讓它從零星變成整批；由客戶端的 `MDFX_GosDuplicateNewGuard` 承接。
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
的 FarmingSpeedNew 下限 0.1 是 Java，腳本查不到，記在 `MDFX_FarmingStallHeal.lua` 檔頭）；42.22.2 起另以 `javap` 登記
兩條 Java 前提：`SliceY` 的 10,485,760 byte 緩衝、`SGlobalObjectSystem.save()` 先開 `FileOutputStream` 才序列化。

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
| 狀態 | **現役**（42.21.0-0.12.0 起；備份補回整個不見的 MOD 42.21.0-0.15.1 起） |

### 症狀

MOD 的設定（ESC → 選項 → MOD）重開遊戲就回到預設，而且只發生在某些 MOD 上；或整份 MOD 設定一次全部消失。
`ModOptions.ini` 裡可以看到一行裡黏著幾十筆 `<型別>|<modid>|<optid>|<值>`（作者本機 2026-10-02 實例：一行 48 筆，
AutoDrive 全部 19 個選項、CleanUI、Economy、NoticeBoard、MirageWardrobeZoom）。不會有任何錯誤訊息。

觸發條件：主選單與存檔啟用的 MOD 不同（每個存檔各自選 MOD），在當下沒載入某些 MOD 的狀態下按了選項的套用／確定；
或主選單根本沒有任何 MOD 建選項時按了套用。多人玩家最常見後者：伺服器的 MOD 進服後才載入，主選單常常一個 MOD 都沒啟用。
2026-10-23 正式服玩家（Discord）回報「小地圖所有設定莫名變成預設、不是每次重登都會」，截圖的設定視窗八個分類開關全是預設值。

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
4. **備份補回**：同一個資料夾的 `ModOptions_MDFX_backup.ini` 跟著 `ModOptions.ini` 走——每次 load 對完檔案、每次 load
   過之後的 save，內容不同就照抄一份（空行不抄；同樣寫入讀回比對，不符就寫回上一份）。load 時某個 MOD 在 `ModOptions.ini`
   裡一筆都沒有、備份裡有，就把備份裡它的每一筆接到檔尾（同上的寫入讀回比對），成功再 load 一次。**只補整個不見的 MOD**：
   檔案裡還有它任何一筆就以檔案為準，MOD 自己從 OtherOptions 移除的舊行（EquipmentUI）、改了型別的舊行（MiniMap 的
   combobox→slider，`.selected` 遷移訊號）不會復活。**這個 Lua 環境還沒 load 過的 save 不更新備份**（已註冊選項在記憶體裡
   可能還是預設值）；save 之後讀不到檔案、讀到空的也不更新。主選單沒有啟用本 MOD 時觸發 3 照樣發生，由下次有本 MOD 的 load
   補回——之前只能要求玩家在主選單也啟用本 MOD。

**黏行切分規則**：每筆以 save 會寫的七種型別（`:264-281`：`textentry`／`tickbox`／`multipletickbox`／`slider`／
`combobox`／`colorpicker`／`keybind`）加 `|modid|optid|` 起頭，從左往右每次取最左邊的起頭——`multipletickbox` 的起頭
比它裡面的 `tickbox` 早，所以不會被切開。一行切出兩筆以上時，每筆的值都要是原版 save 寫得出來的形狀，否則整檔不改
（印一行 `glued line N has an unrecognised record`）：tickbox `true`／`false`、slider／combobox／keybind 是數字
（含 Kahlua 的科學記號字串 `1.0E-4`）、multipletickbox 是一串「`true `／`false `」（結尾有空格）、colorpicker 四個數字
以空格分隔、textentry 不限；任何型別都接受原版對 nil 寫出的 `nil`。行首不是起頭的行原樣保留。

**零行為差異**：沒有黏行、沒有要補的 MOD 時 load 不改寫 `ModOptions.ini`（多讀一次檔案與備份，備份內容不同才寫備份）；
OtherOptions 是空的時 save 與原版位元組相同；有未註冊行時只差每行補上 `\r\n`（這就是修正）。OtherOptions 裡的空字串不傳給
原 save（原版寫空字串本來就沒有輸出）。唯一看得到的差異是補回：玩家手動刪掉 `ModOptions.ini` 想重設時，設定會從備份回來
（使用者 2026-10-23 同意，見知識庫 `client.md`）。

**安裝時機**：本檔載入時就包好，早於第一次 load。原版 client 檔排在所有 MOD 之前執行（`LuaManager.java:1192-1193`），
`PZAPI.ModOptions` 一定已經存在；`MainOptions:create` 只從 MainScreen 的 `OnMainMenuEnter`／`OnGameStart` 處理器呼叫
（`MainScreen.lua:2178`、`:2180` → `instantiate` → `:694`），這些事件都在 `LuaManager.LoadDirBase` 之後才觸發
（`Core.java:3949` → `:3962-3963`；回主選單 `IngameState.java:1070` → `:1077`；開機 `GameWindow.java:993` 之後才進
`MainScreenState`，`:396` 觸發 `OnMainMenuEnter`）。每次 `LoadDirBase` 原版檔重建整張表，marker 隨之消失、本檔重新包裝；
同一張表上重複執行由 marker 擋下。形狀不符（`PZAPI.ModOptions`、`load`／`save`、`OtherOptions`／`Dict`、
`getFileReader`／`getFileWriter`）印一次 `NOT installed` 並放棄。不做 `OnGameBoot` 復查：會包裝 load／save 的已知 MOD
（EquipmentUI、ContextMenuCleanup 3780688809、AreaTasks 3793163745）都先呼叫原函式，前後順序都串得起來；整支取代而不呼叫原函式的 MOD 會讓本修正失效，
那種 MOD 本身就已經改掉原版存讀。MOD 依 `Mods=` 順序載入（`LuaManager.java:1151-1193`）：比本 MOD 先載入、在檔案載入時就
自己 load 的 MOD，那一次是原版 load、讀到還沒補回的檔案，補回發生在之後第一次經過本補丁的 load。正式服 2026-10-20 的
`Mods=` 裡本 MOD 排第 79／142 項：在檔案載入時就 load 的 VehicleManager（136）、PackThrow（140）排在後面，補回就發生在
它們那一次 load；排在前面又自己 load 的 CleanUI、Neat_Crafting、Neat_Building、CleanHotBar（5–9）都在 `OnGameBoot` 才註冊與
load，那時本 MOD 已裝好。

診斷（一 session 一次，前綴 `[MinidoracatFixes] MDFX_ModOptionsPersist`）：`split N glued records into one per line`、
`restored N records of M mod(s) missing from ModOptions.ini (backup ModOptions_MDFX_backup.ini)`、
`glued line N has an unrecognised record; file left unchanged`、`rewrite not verified; original lines written back`、
`backup rewrite not verified; previous backup written back`、`repair failed (…)`／`could not prepare other lines (…)`／
`backup not updated (…)`（自身出錯，退回原版行為；備份不動）。

### 已知限制

- **沒有備份時救不回**：備份在更新到有備份的版本後，第一次經過本補丁的 load 才建立；在那之前被原版清空、或黏行第一筆屬已註冊
  選項而被原版丟掉後又存過一次的那些筆，檔案與備份裡都沒有了。
- **只補整個不見的 MOD**：清空後先進了沒有本 MOD、但有那個 MOD 的存檔或伺服器，又在那裡存過設定，那個 MOD 就以那次存的值為準
  （通常是預設值），備份補不回。被截斷在某個 MOD 中間的檔案，那個 MOD 缺的行也不補。
- **主選單沒有啟用本 MOD 時，主選單的套用照樣清空檔案**，由下次有本 MOD 的 load 補回；多人遊戲進服後只載伺服器 `Mods=` 的 MOD，
  伺服器沒裝本 MOD 時遊戲內不生效、也不補回。家族 MOD 接上 UI 框架 rev 23 的 `UI.ModOptionsBackup` 後，各自從
  `Zomboid/Lua/MinidoracatUI/` 的備份補回自己的設定，不靠本 MOD；兩邊都只補檔案裡缺的行，同時在也不會寫出重複的行。
- **刪檔重設要連備份一起刪**：只刪 `ModOptions.ini`，下次 load 會把每個 MOD 從備份補回。
- **比本 MOD 先載入、在檔案載入時就 load 並把值記進變數的 MOD**：補回的那一場仍照預設，下次進遊戲才跟上（選項值本身已補回）。
  家族的 VehicleManager（`showButton`）、PackThrow（`showDock`）是這種寫法；正式服它們排在本 MOD 之後、不受影響。這兩個 MOD 的下一版
  在自己的 load 前用 UI 框架 rev 23 補回，之後排在本 MOD 前面也照常。
- textentry 的值若剛好含「型別`|x|y|`合法值」形狀的字串，會被當成黏行切開（實務上沒見過）。
- save 期間內層包裝若改動 OtherOptions，改動會隨換回原表而丟失（已知 MOD 都沒有這樣做）。

### 驗證

`lua scripts/test_modoptions_persist.lua` — 66 項，全綠。照載本機原版 `client/PZAPI/ModOptions.lua` 與 `shared/luautils.lua`，
記憶體檔案系統照 `LuaManager.java:5936-5964`、`:6727-6763`（副檔名白名單、`FileOutputStream` 一開就截斷、`BufferedReader.readLine`
三種行尾）。涵蓋：黏行第一筆屬已註冊／未註冊兩種（含七種型別、科學記號、multipletickbox 結尾空格；值套上、檔案一筆一行、
下次 save 一筆一行、換場次值仍在；各有原版對照組）、save 先於 load（沒有 MOD 選項時不清空且可重入；有選項時寫記憶體裡的值、
檔案舊值不重複寫回、相同行去重）、無黏行（load 不改寫檔案；只有已註冊行時與原版位元組相同；有未註冊行時只差 `\r\n`）、EquipmentUI 的
load 包裝照抄、在本補丁內層／外層 × 舊行獨立／黏住四種組合都找到並移除舊行、combobox→slider `.selected` 訊號（獨立行與黏行）、
切不出合法筆數不改檔、寫入被靜默丟掉時寫回原內容且不做第二次 load、修補讀檔拋錯與準備 OtherOptions 拋錯都退回原版、原 save
拋錯照樣外洩且 OtherOptions 換回、形狀不符 `NOT installed`、重複載入不疊包裝；另把原版 `:287` 改成補換行模擬官方先修一半，
驗證未註冊行之後只多一個空行、連存三次不會越存越多。備份：第一次 load 就建立且不改寫檔案、load 過的 save 讓備份跟上、原版
清空（對照組）後下次 load 補回三個值與每一筆並印一行診斷、檔案裡還有 AutoDrive 時只補整個不見的兩個 MOD 且備份跟上、改了型別的
舊行不復活、load 前的 save 不更新備份、save 後讀不到檔案或讀檔拋錯都不洗掉備份（後者 save 不外洩）、備份寫入被丟時寫回上一份。

**mutation 驗證**（`lua scripts/test_modoptions_persist.lua --mutants`）：31 個突變全部被抓到——拿掉整支修正、修好檔案後不再
load、load 修補不包 `pcall`、沒有黏行也沒有要補的 MOD 也改寫、起頭不取最左、多筆不驗值、寫完不讀回比對、讀回不符不寫回原內容、
save 不補行尾、save 不換回原表、原 save 的錯誤不重拋、準備 OtherOptions 不包 `pcall`、load 過也補檔案裡的行、save 先於 load
不保留檔案內容、save 先於 load 不拆黏行、已註冊的行也寫回、不去重、空行也傳給 save、拆掉形狀檢查、拆掉冪等 marker、診斷不節流、
不從備份補回、MOD 還在檔案裡也從備份補、補回不印診斷、沒有變化時不建立備份、沒有變化的 load 之後 save 不更新備份、補回後不更新
備份、load 前的 save 也更新備份、檔案是空的也抄成備份、備份讀回不符不寫回上一份、存檔後更新備份不包 `pcall`。

實機 E2E（`fixes-e2e` 的 `modoptions-sp`，2026-10-02，42.21.0）：

| 場次 | 結果 |
|------|------|
| `glued`（＋AutoDrive，兩次冷啟動） | 本輪 `ModOptions.ini` 換成三行 fixture：AutoDrive 三個非預設值一半藏在未載入 MOD 那筆後面、一半黏在它前面。主選單一開就印 `split 5 glued records into one per line`；進場 VoiceEnabled=false／VoiceLanguage=3／UTurnMode=2 都套上、檔案 6 行沒有黏行，save 後 106 行一筆一行、未載入 MOD 的兩筆各一行；結束到桌面再開，三個值與兩筆都還在、沒有再印 split。12＋12 個 CHECK，零例外。2026-10-23 加備份後重跑：同樣通過，兩次 save 後檔案與備份都是 132 行（選項比 10-02 多），18＋18 個 CHECK，零例外 |
| `noopts`（只有本 MOD） | 沒有任何 MOD 建選項（`Data` 為空、原版不 load，檔案仍有兩行黏行），呼叫套用時同一個 save：3 行變 6 行一筆一行、六筆各一行。9 個 CHECK，零例外。2026-10-23 加備份後重跑：同樣 6 行，且沒有寫出備份（還沒 load 過），10 個 CHECK |
| `noopts-control`（2026-10-23，本 MOD 從本輪刪掉） | 原版對照：同一個 fixture、同一個 save，`ModOptions.ini` 從 3 行變成 0 行——玩家在主選單按套用的清空，實機重現。3 個 CHECK |
| `wiped-control`（2026-10-23，＋MiniMap，本 MOD 從本輪刪掉） | `ModOptions.ini` 截成 0 byte、備份放 MiniMap 殭屍／動物／載具開著的 6 筆＋未載入 MOD 2 筆：原版不讀備份，三個圖層都是預設的關、檔案仍 0 行；設定視窗截圖三個開關都是關。10 個 CHECK |
| `wiped`（2026-10-23，＋MiniMap） | 同一個 fixture：主選單（`f:0`）印 `restored 8 records of 2 mod(s) missing from ModOptions.ini`，進場三個圖層都是開、檔案 8 行一筆一行、備份 8 行；設定視窗截圖三個開關都是開。20 個 CHECK，零例外 |
| `wiped`（2026-10-23，多人，＋MiniMap） | 同一個 fixture。客戶端主選單只啟用測試探針——本 MOD 與 MiniMap 都要連上伺服器才載入，和玩家主選單沒啟用 MOD 的情況相同。連線後載入本 MOD、印 `restored 8 records of 2 mod(s) missing from ModOptions.ini`，進場三個圖層都是開、檔案與備份各 8 行；設定視窗截圖三個開關都是開。20 個 CHECK；客戶端例外只有測試探針缺 `AnimSets`／`actiongroups` 目錄的 `AdvancedAnimator` 17 個（每輪多人 E2E 都有） |

### 可退場條件

官方把 `ModOptions.lua:287` 改成寫入時補換行，**且**主選單沒有 MOD 選項時不再以空內容覆寫（先 load 或不 save）。只修前者
擋不住清空；`check_vanilla_alignment.py` 對補換行的寫法有 exithint。官方補了換行而本補丁還沒退場時，未註冊行之後各多一個空行
（本補丁補一次、原版再補一次），空行不再傳給 save，所以不會越存越多。退場後 `ModOptions_MDFX_backup.ini` 留在玩家資料夾、
不再更新，原版不讀它。

---

## MDFX_HutchNullSlotGuard — 多人客戶端卸載雞舍時，格位裡的 null 讓遊戲崩潰斷線

| 項目 | 內容 |
|------|------|
| 檔案 | `client/Fixes/MDFX_HutchNullSlotGuard.lua` |
| 影響版本 | Build 42.21.0（爆點的迴圈是 42.21 新增；寫入 null 的同步路徑 42.20.4 就有） |
| 端 | client：只在 MP 客戶端（`isClient()` 為真才登記雞舍）。單人與專用伺服器不經過寫入 null 的兩條同步路徑 |
| 類型 | 原版留下的**壞資料**（`animalInside` 的 null 值），在原版讀到之前清掉；不包裝任何原版函式 |
| 狀態 | **現役**（42.21.0-0.13.0 起） |

### 症狀（玩家 log）

- 玩家回報「一進某個鎮就彈飛」「報錯被踢回主選單」，重新連線可以進去。兩位玩家、兩天的 `console.txt` 是同一個堆疊，
  只差捲動方向；一位進遊戲約 6 秒、往東移動時，另一位玩了約 55 分鐘、往北移動時。兩人都沒有裝任何 Java 修補。

  ```
  ERROR: General ... IngameState.updateInternal> Exception thrown
    java.lang.NullPointerException: Cannot invoke "zombie.characters.animals.IsoAnimal.removeFromUpdateLists()"
    because "animal" is null at IsoHutch.removeFromWorld(IsoHutch.java:1095).
      ... IsoObject.removeFromWorldToMeta ← IsoChunk.removeFromWorld ← IsoChunkMap.Right（另一位是 Up）← ProcessChunkPos
  LOG  : Lua ... removing all player data
  LOG  : General ... STATE: exit zombie.gameStates.IngameState
  ```

### 根因（行號為 42.21.0 反編譯快照）

1. **爆點**：`IsoHutch.removeFromWorld`（`:983-990`）在 `HutchManager.remove` 之後新增一個迴圈，對 `animalInside.values()`
   的每個值呼叫 `IsoAnimal.removeFromUpdateLists()`，沒有 null 檢查。42.20.4 的 `removeFromWorld` 到 `HutchManager.remove`
   就結束；`removeFromUpdateLists` 本身也是 42.21 新增的方法。
2. **成因**：多人客戶端自己的動物同步把 null 寫進 `animalInside`，從不 remove 那個 key：
   - `NetworkPlayerAI.parse(AnimalPacket)`（`:361-396`）：雞舍裡的動物，若客戶端記的 `hutchPosition` 不是 -1，先
     `put(舊格, null)`，再依封包放進新格或巢箱。進巢箱（封包 `hutchPosition` -1）時舊格留著 null，而且這個分支不重設
     `hutchPosition`；換格時舊格也留著 null。母雞進巢箱下蛋就會發生。
   - `AnimalUpdatePacket.parse`（`:192-195`）：回應客戶端的動物請求時先 `put(封包的格, null)`，再呼叫
     `addAnimalInside(animal, false)` 並丟掉回傳值；加入失敗或重骰到別格時同樣留下 null。
   其他讀者都用 `get()`，null 等於空格，所以這些 null 在 42.20.4 沒有後果。
3. **觸發**：`IsoChunkMap.Left`／`Right`／`Up`／`Down`（越過 chunk 邊界時移除最遠的一欄或一列）與 `Unload`（一次移動
   `chunkGridWidth` 個 chunk 以上，例如傳送）都走 `IsoChunk.removeFromWorld` → 每個物件 `removeFromWorldToMeta`
   （`IsoChunk.java:3248-3251`），全都在 `ProcessChunkPos` 裡、`IngameState.updateInternal` 的 catch 之內；原版在那裡存檔後
   `doDisconnect("crash")`（`IngameState.java:1582-1620`）。
4. **巢箱母雞會一再寫回 null**：`removeFromWorld` 只對 `animalInside` 的值 `removeFromUpdateLists`，巢箱裡的母雞留在客戶端的
   `AnimalInstanceManager`，`hutchPosition` 也還是舊值；雞舍重新載入後，她的下一則更新又對舊格 put null（E2E 實測）。

### 修法

- **只登記雞舍，不掃格子**：`MapObjects.OnLoadWithSprite` 登記 `HutchDefinitions` 的全部圖塊（主格、附屬格、開門、蛋門），
  Java 依圖塊名分派，只有雞舍圖塊會呼叫到 Lua（`MapObjects.java:184-218`，客戶端載入 chunk 也分派，`IsoChunk.java:3829`）；
  建造中新增的雞舍走 `OnObjectAdded`（`AddItemToMapPacket.java:94`）。登記主雞舍，以及主雞舍格上第一個 IsoHutch——
  封包用 `IsoHutch.getHutch(x, y, z)` 解析雞舍，取的是那一格的第一個（`IsoGridSquare.java:11235-11240`）。
  `isClient()` 為假時不登記；第一座雞舍登記後才掛 `OnTick`。
- **每幀每座雞舍一次 `containsValue(nil)`**；為真時才取 key 清單（`ArrayList:addAll(keySet())`），以 `getAnimal(k)` 找出 null 格。
- **怎麼刪**：Integer key 經過 Lua 一律變成 double（`KahluaNumberConverter.java:103-116`），`HashMap.remove(Object)` 拿 double
  對不到 Integer key；`values()`／`keySet()` 回傳的集合也沒有暴露給 Lua，呼叫不到 `remove`（E2E probe 實測）。所以把 key 寫進
  一隻暫用母雞的 `hutchPosition`，呼叫原版 `IsoHutch.removeAnimal`（`:538-544`）——它以 int 自動裝箱 remove，尾端的
  `sendAnimalUpdate` 只在伺服器送封包（`:685-696`），客戶端呼叫不送任何東西。暫用母雞在 (0,0,0) 建立、不進世界、整個 session 共用一隻，
  呼叫後 `hutch`／`hutchPosition` 回到 nil／-1。
- **不動的**：null 格裡有屍體時不清（`removeAnimal` 會一併拿掉屍體），印一行診斷；清不掉的 null（有屍體，或別的 MOD 以 Lua
  數字 put 進來、不是 Integer 的 key）冷卻 `QUIET` 幀再看，不每幀重跑。移除數以 `size()` 前後差計。
- **放掉**：每 `PRUNE_EVERY` 幀放掉 chunk 已卸載（格子的 chunk 是 null，`IsoChunk.java:3260`）或已移除的雞舍。
- 自己出錯：`pcall` 包住，印一行 `disabled for this session` 後本次開機停用。

### 與原版的差異

拿掉 null 格後，`animalInside.size()` 只算真的動物。原版雞舍選單判斷「已滿」（`ISHutchMenu.lua:57`）與畜牧區介面的動物數
（`ISDesignationAnimalZoneUI.lua:286`）都用 `size()`，原版會把 null 格算進去，本修復之後不會。這是本修復唯一看得到的差異，使用者 2026-10-03 同意（等於順帶修正「沒滿卻顯示已滿」）。

### 效能（實機量測）

多人客戶端（42.21.0，E2E `hutch-null --define mode=bench`）：伺服器另外蓋 9 座雞舍，客戶端登記到 11 座後（情境的 10 座，另一座推定是起點附近原本就有的雞舍：進場時就登記到 2 座，主雞舍格上只有情境的那一座），
在遊戲裡直接呼叫補丁的每幀函式，以 `getTimestampMs` 量 2 萬–10 萬次取平均、扣掉空迴圈。GameProfiler 在不帶 `-debug` 的 MP 客戶端不會啟用
（`DebugFileWatcher` 的條件是 `Core.debug || !GameClient.client`），span 也只到 `Lua - OnTick` 這一層，分不出單一 callback 的次微秒成本，
所以比照 `MDFX_StaleRoomGuard` 用放大量測。非獨佔（同一台機器有其他 PZ 程序），數字偏保守。

| 項目 | 成本 |
|------|------|
| `containsValue(null)`（4 隻雞的雞舍） | 0.135／0.150 µs（兩輪） |
| 每幀固定成本：11 座雞舍 | 2.46／3.20 µs（每座 0.22／0.29 µs） |
| 附近沒有雞舍、單人、專用伺服器 | 0（不掛 `OnTick`） |

60 FPS 一幀 16,700 µs：11 座雞舍約 0.02%。清除只在出現 null 時跑一次（取一次 key 清單、最多 20 次 `getAnimal`／`removeAnimal`），
頻率是每隻母雞每次進巢箱或換格一次。

### 已知限制

- 每幀的順序是 `GameClient.update`（處理封包＝寫進 null）→ `IngameState.updateInternal`（`ProcessChunkPos`＝卸載）→ `OnTick`
  （`GameWindow.java:284-363`）。同一幀內剛寫進 null、又剛好卸載那座雞舍時，仍走原版崩潰路徑。
- null 格裡同時有屍體時不清（見上）。

### 驗證

`lua scripts/test_hutch_null_slot_guard.lua` — 50 項，全綠。假引擎照每一幀的順序（封包寫入 null → 卸載走過 `values()` → OnTick）跑，
假 `HashMap` 照 Kahlua 規則對 Lua 傳入的 key 一律查不到、只有 `removeAnimal` 刪得掉：母雞進巢箱、換格、兩座雞舍三個 null 都在卸載前清掉
且活雞、巢箱、屍體不動（同流程不載補丁的對照組崩潰）；有屍體與刪不掉的 null 只冷卻；10 座雞舍每幀恰 10 次 `containsValue`、沒有 null 時
不取 key；單人不登記也不掛 OnTick；新蓋雞舍（`OnObjectAdded`）、蛋門圖塊、主雞舍格上第一個是附屬格；卸載後放掉且可被回收；
自身錯誤只印一次並停用；形狀不符不安裝。

**mutation 驗證**（`--mutants`，14 個全部抓到）：直接 `HashMap.remove`、不檢查屍體、拿掉 `containsValue` 快速路徑、沒有冷卻、
不看 `size()` 差就當成移除、不登記 `OnObjectAdded`、只登記 baseSprite、不放掉卸載的雞舍、拿掉 pcall、單人也登記、
不追主雞舍格上的第一個、附屬格也登記、暫用母雞每次重建、載入時就掛 OnTick。

實機 E2E（`fixes-e2e` skill 的 `hutch-null`，MP）：伺服器在 Muldraugh 主街旁蓋一座雞舍、放 4 隻母雞，客戶端看到 4 隻後，
伺服器讓 0 號格的母雞進巢箱（`null=nest`）或換到 10 號格（`null=move`），客戶端再往東離開（`path=scroll`：40／80／120 格三段傳送，
chunk 地圖逐格捲動；`path=jump`：一次 400 格）。

| 場次 | 結果 |
|------|------|
| 對照組 `nest`＋`scroll`（修正檔從本輪拿掉） | 進巢箱 205 ms 後客戶端出現 null（`size=4 live=3 nest=1`）；第二段傳送時 `IsoChunkMap.Right` → `IsoHutch.removeFromWorld` NPE → `removing all player data` → 回主選單，堆疊與玩家 log 相同；伺服器連線紀錄是客戶端送出的 `disconnection-notification` |
| 對照組 `move`＋`jump` | 換格後客戶端 `size=5`（舊格 null）；傳送當下 `IsoChunkMap.Unload` → 同一個 NPE → 回主選單 |
| probe（原版，情境自己清） | `keySet` 取到的 key 是 Lua number；`getAnimal(k)` 找得到 null 格；暫用母雞 `removeAnimal` 拿掉恰一個 key、活雞與巢箱不動、暫用母雞回到 -1；`values():remove(nil)` 丟 `attempted index: remove of non-table`。離開不崩潰；回來後新雞舍又有 null（巢箱母雞寫回） |
| 修正組 `nest`＋`scroll` | 修正在 null 出現後約 100 ms 內清掉（`removed=1`），三段傳送不崩潰，回來 4 隻都在 |
| 修正組 `move`＋`jump`（bench） | 同上；離開後放掉兩座雞舍（`tracked=0`），回來重新登記 |
| 修正組 `nest`＋`scroll`（bench，最終版） | 同上；回來後巢箱母雞又寫回一個 null，修正再清一次（`removed=2`） |

各輪 `SERVER STARTED` 之後除了開機固定雜訊（`AdvancedAnimator`）與 probe 刻意觸發的那一個 `pcall`，客戶端與伺服器都沒有例外。

`python scripts/check_vanilla_alignment.py` 以 `javap` 比對：爆點（`removeFromWorld` 的 `checkcast IsoAnimal` → `removeFromUpdateLists` 中間沒有
null 檢查，有 exithint）、兩個成因（`NetworkPlayerAI.parse` 的 `aconst_null`→`HashMap.put`、`AnimalUpdatePacket.parse` 的 put null 後
`addAnimalInside(..., false)` 的回傳被 pop）、依賴（`removeAnimal` 以 `Integer.valueOf(getHutchPosition())` remove、`sendAnimalUpdate`
只在伺服器、`getAnimalInside`／`getAnimal(Integer)`／`getDeadBody(Integer)`／`isSlave`、`MapObjects.OnLoadWithSprite(KahluaTable, …)`、
`IsoChunk` 分派 `MapObjects.loadGridSquare`、`AddItemToMapPacket` 觸發 `OnObjectAdded`、`IsoGridSquare.getHutch`）與 `HutchDefinitions.lua` 的圖塊欄位。

### 42.22 對版

- **崩潰路徑官方已修**：42.22.2 `IsoHutch.removeFromWorld`（`IsoHutch.java:1016-1025`）與 `releaseAllAnimals`（`:1036-1044`）
  先判 null 才用；官方 QA 在論壇也說雞舍崩潰在 42.22 已修（topic 102995「Chicken Hutch Crash」）。`check_vanilla_alignment.py`
  改登記成 retired 指紋（官方判 null 還在）。
- **成因還在**：客戶端仍寫入 null 格（`NetworkPlayerAI.java:392`、`AnimalUpdatePacket.java:197`）。原版雞舍選單「已滿」
  （`ISHutchMenu.lua:57`）與畜牧區動物數（`ISDesignationAnimalZoneUI.lua:286`）照樣把 null 格算進去，本修復照樣把 null 清掉。
- **保留**（使用者 2026-11-10 裁定）：照原本「兩者擇一」的退場條件已可移出，但移出後「沒滿卻顯示已滿」會回來（2026-10-03 使用者同意的差異）。
  本修復在 42.22 的作用只剩這一項；退場條件改成下方寫的那一條。

### 可退場條件

官方讓客戶端兩條同步路徑（`NetworkPlayerAI.parse(AnimalPacket)`、`AnimalUpdatePacket.parse`）改成 remove 舊格、不再 put null。
`IsoHutch.removeFromWorld` 略過 null（42.22 已達成）只解決崩潰，不算退場條件：null 格還在，「已滿」判斷與畜牧區動物數照樣多算。
官方修好後，已載入的雞舍裡還有 null，要等玩家重新載入那一帶才消失。`check_vanilla_alignment.py` 登記了兩條寫入路徑的指紋，轉 CHANGED 時回頭看。

---

## MDFX_GosDuplicateNewGuard — 登入那幾秒內伺服器新增的全域物件，進遊戲時每個各跳兩條錯誤

| 項目 | 內容 |
|------|------|
| 檔案 | `client/Fixes/MDFX_GosDuplicateNewGuard.lua` |
| 影響版本 | Build 42.21.0 實測；相關 Java 類別（`GlobalObjectSystem`、`CGlobalObjectSystem`、`CGlobalObjects`、`SGlobalObjectNetwork`、`ConnectionDetails`、`GlobalObjectsPacket`）與 42.20.4 反編譯快照逐位元組相同 |
| 端 | client＋單人（dedicated server 不執行）；登入的時間差只在多人 |
| 類型 | 原版**同步時序缺口**：連線清單與延後的新增封包重複；包裝 `CGlobalObjectSystem.newLuaObjectAt`，同座標已有物件就沿用 |
| 狀態 | **現役**（42.21.0-0.14.0 起） |

### 症狀（玩家 log＋正式服唯讀調查）

- 玩家在 Discord 問「你們這裡有一直彈 error 嗎？」，附 Error Magnifier 截圖（9 項，合併自 60 條）。`console.txt` 在
  `Waiting for player-connect response from server` → `Processing delayed packets...` 之後連續 30 組，每組一個 Java 例外加一個 Lua 錯誤：

  ```
  ERROR: General ... Lua(Vanilla).newLuaObjectAt> Exception thrown
    java.lang.IllegalStateException: already an object at <x>,<y>,0 at GlobalObjectSystem.newObject(GlobalObjectSystem.java:40).
      ... CGlobalObjectSystem.receiveNewLuaObjectAt ← CGlobalObjectNetwork.receive ← GlobalObjectsPacket.parse ← GameClient.update ← IngameState.enter
  attempted index: getModData of non-table: null
    Lua(Vanilla).new(CGlobalObject.lua:16) ← Lua(Vanilla).new(CPlantGlobalObject.lua:6)
  ```

  30 個座標各一次，是相鄰 3 個 chunk 裡的一塊農田；之後整段遊玩沒有再出現。
- 伺服器（唯讀）：這條連線的 `Connection add`（user log）到送出 `connection-details` 相隔 1.9 秒（Steam 登入驗證）。這段時間另一位
  玩家開自動駕駛從那塊農田北邊約 75 格經過，伺服器載入那一帶；存檔裡這 30 株是 29 株 destroyed（踩爛 sprite）＋1 株 dead。原版不替
  踩爛 sprite 註冊 OnLoad，區域載入時替它們重新登記並廣播新增的只有 `MDFX_FarmingGosPrune` 的重建。登入的玩家本人在約 4,000 格外進場。

### 根因（行號為 42.21.0 原版 Lua 與反編譯快照）

1. **兩條同步路徑沒對齊**：
   - 整份清單在登入被接受時才打包進 ConnectionDetails（`GameServer.receiveClientConnect` → `RequestDataPacket.sendConnectingDetails`，
     `GameServer.java:2718-2719`；`ConnectionDetails.java:38` → `SGlobalObjects.saveInitialStateForClient`，`SGlobalObjects.java:103-135`），
     客戶端載入世界時照它建物件（`CGlobalObjects.registerSystem`，`CGlobalObjects.java:28-68`；`GameLoadingState.java:313-314`）。
   - 新增／移除／更新封包由 `SGlobalObjectNetwork.sendPacket`（`SGlobalObjectNetwork.java:39-61`）廣播給 `udpEngine.connections` 的每一條，
     不看連線狀態；連線在 RakNet 接上後就加進這張表（`GameServer$DelayedConnection.connect`，`GameServer.java:4427-4436`），比清單早一段登入驗證。
2. **客戶端延後處理**：`GlobalObjectsPacket` 的 `handlingType = 3` 沒有載入中處理（`PacketTypes.java:809-811`），載入期間收到的全部放進
   `LoadingMainLoopNetData`（`GameClient.java:370-378`），送出 player-connect 後才依序處理（`GameClient.java:380-385`，log 的
   `Processing delayed packets...`）。這時清單裡的物件已經建好；「連線加進廣播表」到「打包清單」之間新增的物件，會先在清單裡、再收到一次新增。
3. **原版不容許重複新增**：`CGlobalObjectSystem:newLuaObjectAt`（`CGlobalObjectSystem.lua:69-72`）直接 `newObject`；Java 對已有物件拋
   `already an object at`（`GlobalObjectSystem.java:36-45`），Kahlua 的 `MethodCaller.call` 記下例外、不推回傳值（`MethodCaller.java:34-43`），
   Lua 拿到 nil 繼續跑，`CGlobalObject.new` 對 nil 取 `getModData`（`CGlobalObject.lua:16`）再錯一次。
4. **資料沒壞**：`CGlobalObjectSystem.receiveNewLuaObjectAt`（`CGlobalObjectSystem.java:34-50`）不看 Lua 的結果，照樣把封包內容逐鍵寫進
   `getObjectAt` 拿到的既有物件。農作物系統沒有 sync key（`SFarmingSystem:initSystem` 不呼叫 `setObjectSyncKeys`），新增封包本來就不帶資料；
   原版五個系統裡只有餵食槽有（`SFeedingTroughSystem.lua:22`）。
5. **為什麼最近才成批**：原版的新增多半是玩家種植、蓋營火，登入那幾秒碰上的機會很小；`MDFX_FarmingGosPrune` 在區域載入時整批重建
   被移出的作物，載入一塊廢棄農田就是幾十包新增。

### 修法

- 包裝 `CGlobalObjectSystem.newLuaObjectAt`：以 Java 的 `self.system:getObjectAt(x, y, z)` 查同座標，已有物件就回傳它的 modData、不再
  `newObject`，否則照原函式。Java 接著把封包內容寫進這個物件，結果與原版拋錯之後相同。
- 不用 Lua 的 `getLuaObjectAt` 查：它會先 `updateFromIsoObject` 從地圖物件抄 modData（`CGlobalObjectSystem.lua:84-92`），原版這條路徑沒有。
- 包在基底類別：原版五個系統（農作物、營火、雨水桶、陷阱、餵食槽）都沒有自己覆寫 `newLuaObjectAt`，一起受益；覆寫了的 MOD 系統
  （例如 PSR、ImmersiveSolarArrays 的電池組）照它自己的版本。
- 檔案載入時就包（原版 client 檔先於所有 MOD 執行）；marker 存 wrapper 本身，`Core.ResetLua` 重建類別表後重新安裝。查詢自己出錯時印一次、
  照原函式走；形狀不符印 `NOT installed`。
- 診斷每次開機只印第一次（帶系統名與座標）；攔到的次數記在全域 `MDFX_GosDuplicateNewGuard.kept`。訊息不含原版的 `already an object at`，
  數原版錯誤的監控不會算進去。

### 與原版的差異

只少了錯誤。物件本身、它的 Lua 類別與欄位接線、封包寫入的資料，都和原版拋錯之後逐一相同（離線測試以真原版 Lua 對照；實機兩組比對
餵食槽的 sync key）。

### 驗證

`lua scripts/test_gos_duplicate_new_guard.lua` — 32 項，全綠。照載本機原版 `ISBaseObject.lua`、`CGlobalObjectSystem.lua`、`CGlobalObject.lua`、
`CPlantGlobalObject.lua`、`CFarmingSystem.lua`；Java 端照形狀模擬（清單建物件、`newObject` 重複時記例外並回 nil、`receiveNewLuaObjectAt`
先 pcall 再寫入既有物件、`rawget` 沿 metatable 找方法）。對照組（不載補丁）重現正式服的兩條錯誤；修正組零錯誤且鏡像與對照組逐一相同；
新座標照原版建立；登入競態整段模擬（清單已含＋延後的重複新增、新增、更新、移除再新增）最終鏡像與原版相同；不從地圖物件抄 modData；
回傳既有物件；只印一次、每次都計數；單人照樣生效；覆寫了 `newLuaObjectAt` 的 MOD 系統不受影響；查詢出錯照原函式走；形狀不符不安裝；
重複載入不疊、ResetLua 後重新安裝。

**mutation 驗證**（`--mutants`，11 個全部抓到）：整個不載入、不檢查既有物件、既有物件仍呼叫原函式、既有物件回傳 nil、查詢不包 pcall、
改用 `getLuaObjectAt` 查、拆掉形狀檢查、拆掉 marker 檢查、不寫 marker、診斷不節流、不計數。

`python scripts/check_vanilla_alignment.py` 登記 9 條：爆點（`newLuaObjectAt` 本體，有 exithint）、第二條錯誤（`CGlobalObject.new`）、
農作物系統沒有自己的 `newLuaObjectAt`、Java `newObject` 重複就拋、`receiveNewLuaObjectAt` 在 pcall 之後寫入既有物件（零差異的前提）、
`GlobalObject.getModData`、成因三條（`sendPacket` 不看連線狀態，有 exithint；`DelayedConnection.connect` 一接上就加進廣播表；
`ConnectionDetails.write` 打包清單）。

實機 E2E（`fixes-e2e` skill 的 `gos-dup-new`，MP，42.21.0）：伺服器開服當下在地圖範圍的左上角（沒有人去）用原版 `newLuaObjectAt`
建 3 株踩爛作物＋1 個餵食槽（只有 GOS 登記），之後每 2 秒用原版 `newLuaObjectOnClient` 重送新增（伺服器重建、玩家種植時送的同一種封包），
餵食槽每輪 `water` 加 1。客戶端連線時清單裡已有它們，載入期間的重送延後到進遊戲才處理＝正式服的同一條路徑；進遊戲後停止重送，
再即時重送一次。

| 場次 | 結果 |
|------|------|
| 對照組（修正檔從本輪拿掉） | 20 次重複新增各兩條錯誤（共 40 條）：12 次在 `Processing delayed packets...` 的延後批次、4 次在等待 player-connect 的迴圈、4 次是即時重送；第一個的堆疊 `GameClient.update(GameClient.java:385)` ← `IngameState.enter(IngameState.java:796)` 與玩家 log 相同。4 個物件仍在、類別與系統接線正確、餵食槽 `water` 與伺服器一致（Java 在 Lua 失敗後照寫） |
| 修正組 | `Processing delayed packets...` 後緊接一行診斷，進遊戲時 `kept=12`（載入期間 3 輪 × 4 個物件全部接住）；停止後 4 個物件都在、接線正確、餵食槽 `water` 與伺服器一致；即時重送 `kept` 12 → 16。零 `already an object at` |

兩組伺服器 `SERVER STARTED` 之後零例外；客戶端除開機固定的 `AdvancedAnimator` 雜訊外，只有對照組的那 40 條。

### 可退場條件

官方讓 `newLuaObjectAt` 遇到已存在的物件不再拋錯（`check_vanilla_alignment.py` 有 exithint），或伺服器不再對還沒拿到清單的連線廣播
（`sendPacket` 的 exithint）。只修後者時，對既有物件重送新增的其他來源仍會讓原版報錯，確認沒有這類來源再移出。

---

## MDFX_ChargerIdleGuard — 沒在充電的汽車電池充電器讓附近發電機每幀重算用電清單

| 項目 | 內容 |
|------|------|
| 檔案 | `shared/Fixes/MDFX_ChargerIdleGuard.lua` |
| 影響版本 | Build 42.21.0 實測（反編譯快照 `42.21.0-20260928`；`projectzomboid.jar` sha256 `e1a69eb7…`） |
| 端 | 三端：dedicated server、MP 客戶端、單人（`IsoCell.ProcessIsoObject` 沒有 server 守衛，兩邊都每幀跑） |
| 類型 | 原版**每幀多餘重算**（效能，不拋錯）：沒啟動的充電器移出引擎每幀更新清單，一啟動就放回 |
| 狀態 | **現役**（42.21.0-0.15.0 起） |

### 症狀（正式服唯讀量測）

某基地（10 台充電器，約 8 台沒放電池、1 台電池沒電；10 台發電機，含 PSR 電池組）附近的玩家客戶端，JFR method-trace 60 秒內
`IsoGenerator.updateGenerator` 30,015 次、`setSurroundingElectricity` 23,345 次（3.39 秒 CPU），約佔客戶端記憶體配置的 73%（約 60 MB/s）。
沒有錯誤訊息，只有那一帶的卡頓與伺服器負載。

### 根因（行號為 42.21.0 反編譯快照與原版 Lua）

1. `IsoCarBatteryCharger.addToWorld`（`IsoCarBatteryCharger.java:111-114`）把每台充電器登記進 `IsoCell` 的每幀更新清單；
   `IsoCell.ProcessIsoObject`（`IsoCell.java:2194-2213`）每幀逐一 `update()`，伺服器與客戶端都跑。
2. `update()`（`IsoCarBatteryCharger.java:122-156`）在沒電池（`:131`）或有電池但格子沒電（`:136`）時每次都 `setActivated(false)`；
   `setActivated`（`:433-436`）不比對狀態就 `IsoGenerator.updateGenerator(square)`（javap：`putfield activated` 後直接 `invokestatic`）。
   同類的 `ClothingWasherLogic.setActivated`（`ClothingWasherLogic.java:287-291`）有 `activated != this.activated` 守衛。
3. `updateGenerator`（`IsoGenerator.java:693-705`）把半徑內每台發電機標成 `updateSurrounding`；下一幀伺服器的發電機 `update`（`:264-267`）、
   客戶端 `LightingJNI.checkLights` → `updateSurroundingNow`（`LightingJNI.java:253`、`IsoGenerator.java:683-691`）整份重跑
   `setSurroundingElectricity`（`:274-331`：每件用電物件 `Translator.getText`、現場編譯 `replaceAll("[\\D]","")`、`DecimalFormat`）。
4. 沒啟動時 `update()` 其餘的事只有 `lastUpdate = -1` 與 `stopChargingSound()`（`:129-141`），第一次之後就是定值。

### 修法

- **移出／放回**：連續 `IDLE_CHECKS`（2）次檢查（間隔 `CHECK_EVERY`＝10 tick）都看到 `isActivated()` 為 false，才
  `getCell():addToProcessIsoObjectRemove(obj)`（`IsoCell.java:2270-2276`，下一次 `ProcessIsoObject` 開頭才拿掉）。已移出的每 tick 查一次，
  `isActivated()` 就 `addToProcessIsoObject(obj)`（`:2261-2268`）放回；另包 `ISActivateCarBatteryChargerAction.complete`
  （`ISActivateCarBatteryChargerAction.lua:35-41`），原版跑完立即放回，伺服器／單人零延遲。不在世界上（square 為 nil、
  `square:getChunk()` 為 nil——chunk 卸載時物件仍留在 square 上，`IsoChunk.java:3248-3260`——或 `getObjectIndex()` 為 -1）就丟掉、不放回。
- **哪些轉換有事件、哪些只能檢查**：

  | 轉換 | 怎麼知道 | 為什麼 |
  |------|----------|--------|
  | 地圖載入帶進來的充電器 | `Events.LoadChunk`（`IsoChunk.java:3969`，同一個 `doLoadGridsquare` 先 `addToWorld`，`:3807`）→ 讀清單尾段 | 事件在物件進清單之後 |
  | 伺服器／單人放置 | 包 `ISPlaceCarBatteryChargerAction.complete`（`:41-49`，`AddSpecialObject` → `addToWorld`）→ 讀清單尾段 | 原版放置只有這條 |
  | 客戶端收到別人放的 | `Events.OnObjectAdded`（`AddItemToMapPacket.java:66`、`:94`）→ 直接看那個物件 | 事件帶物件 |
  | 玩家用動作打開 | 包 `ISActivateCarBatteryChargerAction.complete` → 立即放回 | 原版開關只有這條 |
  | MP 客戶端看到別人打開 | 已移出的每 tick 查 `isActivated()` | 只經 `syncIsoObjectReceive` 改欄位（`IsoCarBatteryCharger.java:380-393`），沒有 Lua 事件 |
  | 停電、拿掉電池時引擎自己關掉 | 清單上的每 `CHECK_EVERY` tick 查 | 在 `update()` 裡直接寫欄位，沒有事件；晚幾 tick 移出不影響行為 |
  | 拿走、chunk 卸載 | 每次檢查順便看在不在世界上 | `removeFromWorld` 沒有 Lua 事件 |

- **只讀清單新增的尾段**：`processIsoObject` 是 ArrayList，`addToProcessIsoObject` 只在尾端 `add`（Set 去重），`ProcessIsoObject` 開頭的
  `removeAll` 保持其餘元素相對順序。記住上次讀到的最後一個元素（錨點），從尾端往前讀到錨點為止；錨點已被移除就等於整份讀一次。第一個
  OnTick 讀一次（開局整份）。錨點離開世界時（週期檢查）先讀尾段再換錨點；要移出的充電器正好是錨點時先讀尾段、它仍是最後一個就改用前一個。
  讀漏的最壞後果是那台照原版跑；移出前一律重查 `isActivated()`，不會誤移出啟動中的充電器。
- 形狀不符（類別、動作的 `complete`、事件、`IsoCell` 三個方法、充電器方法不存在）印 `NOT installed` 不裝；自己的程式 `pcall`，出錯就停用並把
  移出的全部放回；同一個 Lua 環境重複載入不疊（檔頭全域判斷）。診斷一 session 一次：第一次移出時印
  `[MinidoracatFixes] MDFX_ChargerIdleGuard took an idle car battery charger at x,y,z off the per-frame update list …`，伺服器與客戶端各自印。

### 與原版的差異與已知限制

- 發電機用電清單不再被沒開的充電器每幀刷新，改在 `updateGenerator` 的其他呼叫點（燈、爐子、洗衣機、烘衣機、收音機開關，
  物件增減封包，chunk 載入）刷新，與附近沒有充電器的原版基地相同（待使用者確認，見知識庫 `open-issues.md`）。
- MP 客戶端上別人打開的充電器，在收到同步之後的那一個 OnTick 放回，下一幀才開始本機 update（原版同一幀）；伺服器端零延遲。
  客戶端本機的電量原版本來就不會漲（每幀增量被 `setCurrentUses` 的 int 截掉，`IsoCarBatteryCharger.java:150`），看到的是伺服器同步的值。
- 不經事件放進世界的充電器（其他 MOD 用 Lua 直接 `AddSpecialObject`）讀不到，照原版跑，直到它的 chunk 重新載入。
- `Core.ResetLua` 會丟掉追蹤；已移出的充電器要等 chunk 重新載入才回到清單。遊戲中不會 ResetLua。

### 效能（伺服器端 Lua 成本）

E2E `ciBench`（非獨佔）：伺服器每 tick 3.1 µs（追蹤 6 台、5 台移出；伺服器 10 tick/s，約 31 µs/s），沒有新物件時讀尾段 0.9 µs，
整份讀 0.22 µs／物件（90 個 20 µs；清單上萬個物件的伺服器約 2 ms，只在錨點遺失時發生）；客戶端每 tick 3.3 µs。整輪（含傳送 828 格再回來）
整份讀伺服器 7 次、客戶端 6 次，讀過的元素總數伺服器 554、客戶端 374。

### 驗證

`lua scripts/test_charger_idle_guard.lua` — 43 項，全綠。照載本機原版 `ISActivateCarBatteryChargerAction.lua`、`ISPlaceCarBatteryChargerAction.lua`；
Java 端照形狀模擬（`IsoCell` 清單尾端 add、Set 去重、延後移除；充電器 `update` 與不比對狀態的 `setActivated`；chunk 卸載留物件在 square 上；
`LoadChunk` 在 `addToWorld` 之後）。對照組每幀 3 次 `updateGenerator`；修正組第一次檢查後還在、第二次才移出，之後零呼叫、充電中的照常充電；
`complete` 當下放回、同步改欄位下一 tick 放回、被引擎關掉後再移出；啟動過就重算檢查次數；拿走與 chunk 卸載都丟掉、不放回；LoadChunk 只讀新增的
6 個（數 `get` 次數）、沒有新增只讀 2 次；錨點被移除時整份讀、錨點離開世界時換掉；漏抓照原版跑；OnObjectAdded 不讀清單；放置動作後立即追蹤；
自己出錯不外拋且全部放回；原版 `complete` 的錯照樣外洩；重複載入不疊；三種形狀不符都印 `NOT installed`、不動清單。

**mutation 驗證**（`--mutants`，28 個全部抓到）：不載入、一次檢查就移出、移出前不查 `isActivated`、已移出的不查 `isActivated`、已移出／清單上的
不查在不在世界、在世界不看 chunk、不看 objectIndex、`complete` 後不放回、`complete` 後不重算檢查次數、包裝不呼叫後段、包裝吞掉原版的錯、
讀清單不在錨點停、不更新錨點、開局不讀、錨點離開世界不換、移出錨點時不換錨點、不掛 LoadChunk、不掛 OnObjectAdded、不包放置動作、
拆掉重複載入判斷、拆掉載入時／`IsoCell`／充電器形狀檢查、已知的不去重、停用時不放回、自己的程式不包 pcall、診斷不節流。

`python scripts/check_vanilla_alignment.py` 登記 7 條：成因（`setActivated` 寫入後直接 `updateGenerator`、`update` 兩處呼叫 `setActivated`、
`updateGenerator` 標記 `updateSurrounding`）、依賴（`addToWorld` 登記清單、`isActivated`、`IsoCell` 清單三個方法＋尾端 add＋`removeAll`、
`doLoadGridsquare` 先 `addToWorld` 再觸發 `LoadChunk`、客戶端 `OnObjectAdded`、兩個動作的 `complete`）。

實機 E2E（`fixes-e2e` skill 的 `charger-idle`，MP，42.21.0）：發電機加油啟動，玩家用原版動作放 7 台充電器、把 10% 的電池接到第 7 台
（6 台空的＋1 台有電池沒開）。停 45 秒時對伺服器與客戶端 JVM 各錄 30 秒 JFR method-trace（`updateGenerator`、`setSurroundingElectricity`）。

| 30 秒 | 伺服器 `updateGenerator` | 伺服器 `setSurroundingElectricity` | 客戶端 `updateGenerator` | 客戶端 `setSurroundingElectricity` |
|------|------|------|------|------|
| 對照組（修正檔從本輪拿掉，`fixes-charger-control-1011a`） | 1,806（全來自 `IsoCarBatteryCharger.setActivated`） | 301（`IsoGenerator.update`） | 43,782（全來自 `setActivated`） | 7,297（`updateSurroundingNow`） |
| 修正組（`fixes-charger-fix-1011d`） | 0 | 0 | 0 | 0 |

兩組充電相同：打開後 41 秒伺服器電量 0.101 → 0.145，關掉時客戶端同步到 0.148；拿走一台空的不報錯；再打開、傳送 828 格外等兩邊卸載、回來後
伺服器 30 秒 +0.033（對照）／+0.034（修正）。修正組另驗：兩端 7 台都移出、打開當下兩端放回、關掉後兩端再移出、拿走與卸載後兩端都不再追蹤、
回來後空的 5 台重新找到並移出、打開的那台留在清單上。兩組伺服器 `SERVER STARTED` 之後零例外，客戶端只有開機的 `AdvancedAnimator`。

### 可退場條件

官方讓 `IsoCarBatteryCharger.setActivated` 比對狀態（或 `update` 不再對沒啟動的充電器呼叫 `setActivated`）：`check_vanilla_alignment.py`
的「成因：setActivated 不比對狀態」轉 CHANGED 就移出本檔。

---

## MDFX_DeathSync — 多人遊戲只有客戶端判定死亡、伺服器沒處理：沒有屍體，按重生後畫面全黑

| 項目 | 內容 |
|------|------|
| 檔案 | `shared/Fixes/MDFX_DeathSync.lua` |
| 影響版本 | Build 42.21.0 實測（反編譯快照 `42.21.0-20260928`；`projectzomboid.jar` sha256 `e1a69eb7…`）；Build 42.22.2 仍在（2026-11-10 實機，見「驗證」） |
| 端 | 多人：客戶端送指令、dedicated server 處理（兩半在同一檔，執行期以 `isClient()`／`isServer()` 分流）；單人不作用 |
| 類型 | 原版**多人死亡同步缺口**：伺服器沒處理到的死亡，由死者自己的客戶端通知後，照原版伺服器路徑補上 |
| 狀態 | **現役**（42.21.0-0.16.0 起） |

### 症狀（正式服唯讀調查）

- 2026-10-28／29 屍潮夜，兩位玩家回報「死掉後畫面全黑、只剩介面、按不了重生」。一位重新連線後角色還活著；另一位重連要建新角色，回到死亡地點找不到屍體。
- 伺服器 log：PerkLog 有該玩家的 `[Died]`（客戶端在 `OnPlayerDeath` 送的），`*_user.txt` 卻沒有 `user <名> died`（伺服器 `DoDeath` 寫的）；
  按重生那一刻 `server-console.txt` 有 `CreatePlayerPacket … position:`，後面沒有 `coop player=1/4 … replacing dead player`。
- 10-14～10-29 全服 188 次死亡有 10 次只有 PerkLog，其中 4 次在屍潮中、多人圍著同一群殭屍打的時候。

### 根因（行號為 42.21.0 反編譯快照與原版 Lua）

1. **拖倒致死由受害者的客戶端判定**：同時被 3 隻以上殭屍攻擊時（沙盒 `ZombiesDragDown`），`PlayerHitReactionState` 在 `Death` 動畫事件 `Kill`，
   條件是 `!GameServer.server`（`PlayerHitReactionState.java:83`）；`IsoPlayer.updateDeathDragDown` 找不到殭屍時也只在客戶端 `Kill`
   （`IsoPlayer.java:3436-3439`）。別的玩家擁有的殭屍也算進拖倒門檻（`IsoGameCharacter.java:13562-13576`）。
2. **伺服器要自己算出拖倒才跟著處理**：命中封包沒有拖倒旗標（`Bite.java:18-28`），伺服器收到命中後在 `AddRandomDamageFromZombie` 用自己看到的
   攻擊殭屍數重算拖倒（`BodyDamage.java:1269-1296`），算出拖倒才 `Kill(wielder)`（`Bite.java:89-94`）。命中只由「攻擊的殭屍與受害者都在本機」的
   客戶端送（`GameClient.java:1191-1194`），殭屍擁有權換手要間隔 2 秒（`NetworkZombieManager.java:61,91-97`）。命中整段沒送到、或伺服器算出的
   攻擊殭屍數不到門檻時，伺服器上的角色一直活著。正式服 log 分不出是哪一種（推測與多人圍同一群殭屍時的擁有權有關）；本修復不依賴它。
3. **客戶端單方面的死亡不通知伺服器**：`IsoPlayer.OnDeath` 在客戶端只觸發 Lua 的 `OnPlayerDeath`（只對本地玩家，`IsoPlayer.java:6568-6570`）；
   客戶端的 `die()` 只處理伺服器送來的死亡封包（`IsoGameCharacter.java:14630-14631`、`NetworkCharacterAI.java:196-209`）。
4. **按重生時，伺服器看到舊角色還活著就拒絕**：`ConnectCoopPacket`（`:69-70`）在 `getPlayerAt(index)` 不是 null 且沒死時回
   `Coop player 1/4 already exists`，客戶端的 `players[0]` 停在 null，世界不畫、只剩介面。重生鈕在死亡 3 秒後出現（`ISPostDeathUI.lua:73-84`）。
5. 重新連線時，伺服器那份還活著就回到原角色；那份之後被別的路徑變成死亡卻沒走 `die()` 時，重連要建新角色，而且沒有屍體、裝備全沒。

### 修法

- **客戶端**：`Events.OnPlayerDeath`（只對本地玩家）在 `isClient()` 時 `sendClientCommand(player, "MinidoracatFixes", "clientDied", {})`。
  伺服器已處理的死亡也照送（客戶端分不出來），由伺服器判斷。
- **伺服器**：`Events.OnClientCommand` 只接自己的 module／command，而且只在 `isServer()`。`player` 是寄件者連線上的角色（`GameServer.java:2280`，
  客戶端只能指到自己）。它還活著、沒開無敵（`isGodMod`）、出生滿 `MIN_SECONDS`（30）秒（見下）時：
  1. `player:Kill(nil)`：`onKilled` → `DoDeath`，寫 `user <名> died at (…) (non pvp)`、觸發 `OnCharacterDeath`（`IsoPlayer.java:8349-8370`、
     `IsoGameCharacter.java:2024-2036`）。攻擊者給 nil：`DoDeath` 依 `getAttackedBy()` 決定要不要記成 PvP 擊殺（`IsoGameCharacter.java:2026-2027`），
     不把這次死亡記到上一個攻擊者頭上。
  2. `player:die()`：伺服器丟下手上的物品、建屍體（其餘物品進屍體）、把 `PlayerDeath` 送給附近的客戶端（`IsoGameCharacter.java:14623-14646`、
     `IsoPlayer.java:8372-8381`），客戶端收到後 `dieNetwork` 建自己的屍體（`DeadCharacterPacket.java:174-180`）。伺服器自己的 `hitConsequences`
     也是直接 `die()`（`IsoGameCharacter.java:6222-6223`）。**只 `Kill` 不 `die`**：伺服器角色變成死亡、重生不再被拒，但沒有屍體，裝備全沒。
- 伺服器自己處理過的死亡（正常路徑）到這裡時 `isDead()` 已經是真，不做任何事；重複送達也一樣。
- **出生滿 30 秒才處理**：`ClientCommand` 與 `ConnectCoop` 都是 RELIABLE、不保證順序（`PacketTypes.java:510`、`ConnectCoopPacket.java:22-28`），
  正常死亡（伺服器已處理）送出的指令可能在玩家重生之後才到，連線上那時已是剛建的新角色。新角色可以同名，也可能出生在死亡點附近，名字與位置都分不出
  新舊。改看伺服器自己累加的存活時數：伺服器每幀替每位玩家加（`GameTime.java:539-545`）；新角色由伺服器建立、不帶時數，從 0 開始
  （`CreatePlayerPacket.java:288-302`）；舊角色是讀檔的值加上這一輪。
  30 秒依一遊戲天的實際分鐘數（`GameTime.getMinutesPerDay`，沙盒 `DayLength`，`SandboxOptions.java:410-419,452`）換成遊戲小時，不到就不處理、記一行。
  指令不帶資料，伺服器不採信客戶端給的任何值。
- 診斷：每次補處理一行 `[MinidoracatFixes] MDFX_DeathSync processed a death the server missed: player="<名>" x= y= z= n=`，擋下一行
  `ignored a death report for a character alive <h> game hours (< <門檻>): player="<名>" x= y= z= n=`，兩種各自每 session 最多 `LOG_LIMIT`（20）行，
  超過各印一次提示、照樣處理。不照「一 session 一次」：每一行都是一次原本會黑畫面的死亡（或一次被擋下的回報），分析 repo 用它數頻率。
- 形狀不符（`Events.OnPlayerDeath`／`OnClientCommand`、`sendClientCommand`、`isClient`／`isServer`、`getGameTime` 不存在）印 `NOT installed`、
  什麼都不登記。不包 pcall：這是前置判準型修復，`Kill`／`die` 的錯原樣交給事件分派印出。

### 與原版的差異

- 原版會黑畫面的那種死亡，結果改成和一般死亡相同：伺服器記錄死亡、留下屍體（裝備在屍體上）、重生正常。原版裡「重連後回到原角色」
  （伺服器那份還活著）的情況也一併改成死亡，和玩家畫面上看到的一致。使用者 2026-10-29 同意。
- 每次死亡多一個客戶端指令：伺服器 `*_cmd.txt` 多一行 `MinidoracatFixes.clientDied`。

### 已知限制

- 改過的客戶端可以用這個指令讓自己的角色死亡（只能是自己、而且要出生滿 30 秒），結果和被殭屍咬死相同。
- 指令要在玩家建好新角色、送出重生之前送到（重生鈕在死亡 3 秒後出現，按下後還要走建角頁）；網路慢到比這還久時，第一次重生仍會被拒、
  畫面全黑；重新連線後建新角色，屍體照樣在。
- 指令送到時伺服器那份已經是死亡狀態（`isDead()` 為真）卻還沒走 `die()` 的話，本修復不介入，屍體有沒有照原版決定。
- 角色出生不到 30 秒就這樣死亡時不補處理，照原版黑畫面，記一行 `ignored`。
- 舊指令比重生晚 30 秒以上才送到時，仍會讓剛重生的新角色死亡。要同一條連線上的可靠封包晚到「重生耗時＋30 秒」以上：送不到時 RakNet 會一直重送，
  整段不通約 8 秒就斷線（家族 E2E 實測），斷線後舊連線沒送完的封包不會帶到新連線（推論）。沒有用丟包實測過單一封包的延遲上限。
- 管理員用除錯指令 `setTimeSpeed`（要 `ConnectWithDebug` 權限，`SetTimeSpeedCommand.java:27-38`）把時間倍率調成 N 時，存活時數照 N 倍累加，
  30 秒的門檻跟著縮成 30/N 秒。其他活著的玩家全在睡、伺服器快轉時，新角色進場那一幀的快轉也算進存活時數：快轉倍率 40、10 FPS 時，
  一天 240 分鐘以上（`DayLength` ≥ 7）的伺服器一幀就會超過門檻（正式服一天 60 分鐘，一幀約 0.053 遊戲小時，門檻 0.2）。
- 坐在車上時被客戶端判定死亡的情況沒有實測：原版客戶端死亡時自己下車（`IsoPlayer.java:6572-6573`），伺服器的 `die()` 不處理下車。

### 驗證

`lua scripts/test_death_sync.lua` — 42 項，全綠。假 Java 端照快照形狀模擬 `Kill`（第一次才 `DoDeath`）、`die`（沒 `Kill` 過先 `Kill(getAttackedBy())`、
屍體只建一次）、`isDead`、伺服器累加的存活時數、一遊戲天的實際分鐘數、`sendClientCommand` 只送本地玩家、伺服器把指令交給寄件者連線上的角色。
涵蓋：多人客戶端死亡送一個指令、單人不送；往返後伺服器 `Kill` 恰一次而且不帶攻擊者、先 `Kill` 後 `die`、`DoDeath` 一次、一具屍體、一行帶玩家與
座標的診斷；重複送達、伺服器已處理的死亡、開無敵、別的指令、寄件者 nil、不是伺服器都不做事；舊角色正常死亡、玩家重生後，新角色收到舊回報不死並記一行，
差一點滿 30 秒擋下、剛好滿就處理，一天 15 分鐘與 24 小時的沙盒照樣以 30 秒為界；擋下與補處理各 25 次，各 20 行加一次上限提示、互不佔用；
三種形狀不符印 `NOT installed`、不登記；重複載入不疊。

**mutation 驗證**（`--mutants`，25 個全部抓到）：不載入、客戶端不看 `isClient`、客戶端不帶參數表、伺服器不看 `isServer`、不比對 module、
不比對 command、不檢查寄件者 nil、已死亡也處理、無敵也處理、不檢查存活時數、存活時數邊界改成 `<=`、不依一天長度換算、換算方向寫反、
形狀檢查不看 `getGameTime`、只 `die` 不先 `Kill(nil)`、`Kill` 帶上一個攻擊者、只 `Kill` 不 `die`、診斷不設上限、不印上限提示、
補處理與擋下共用上限、補處理不計數、擋下不計數、擋下不記錄、拆掉形狀檢查、拆掉重複載入防護。

`python scripts/check_vanilla_alignment.py` 登記 8 條：成因（`PlayerHitReactionState` 只在客戶端 `Kill`、`Bite` 只在伺服器自己算出拖倒時 `Kill`）、
後果（`ConnectCoopPacket` 在舊角色還活著時拒絕）、依賴（`OnDeath` 只對本地玩家觸發 `OnPlayerDeath`、`onKilled` → `DoDeath`、
`onDied` → `sendCharacterDeath`、`getHoursSurvived`、伺服器替每位玩家累加存活時數、`getMinutesPerDay`、伺服器建新角色時不設存活時數
（`CreatePlayerPacket.processServer`）、`Kill`／`die`（伺服器端 `becomeCorpse`）／`isDead`／`isGodMod`、`receiveClientCommand` 以連線取 player）。

實機 E2E（`fixes-e2e` skill 的 `death-sync`，MP，42.21.0，沙盒一天 60 分鐘）：A 在客戶端直接 `Kill` 自己（伺服器不知道的死亡）；B 衣物防禦歸 0、
被伺服器生的 6 隻殭屍拖倒（伺服器自己處理的正常路徑）。死前由伺服器發一支拿在手上的球棒、一個背著的書包（內有鐵鎚），記下物品欄全部物品 ID；
死後 3 秒、12 秒各問一次伺服器，比對死亡點 3 格內屍體與地上的物品 ID。之後按重生、走建角三頁；A 的新角色進場後再送一次 `clientDied`，模擬重生後才到的舊回報。

| 輪次 | 伺服器 | 客戶端 |
|------|------|------|
| 對照組 A（修正檔從本輪拿掉，`ds-control-1029c`） | 12 秒時仍 `dead=false hp=1.00`，沒有 `user died`、屍體 0 | 按重生被拒（`Coop player 1/4 already exists`），`players[0]` 68 秒都是 nil，畫面全黑只剩聊天框 |
| 修正組 A（`ds-fix-1029f`，最終程式碼與情境） | `processed a death the server missed: player="test" … n=1`、`user test died at (10722,9727,0) (non pvp)`，3 秒內 `dead=true`，屍體 1 具；死前 10 件物品（含手上的球棒、書包與鐵鎚）在屍體或地上各恰一份 | 看得到屍體；`coop player=1/4 … is replacing dead player`，新角色存活 |
| 修正組 A 的舊回報（同一輪） | 換上新角色 0.30 秒後收到，`ignored a death report for a character alive 0.001 game hours (< 0.200)`；3 秒後新角色仍 `dead=false hp=1.00` | 新角色存活 |
| 修正組 B（同一輪） | 伺服器自己寫 `user test2 died`，沒有補丁行，屍體 1 具；10 件物品各恰一份 | 看得到屍體；重生正常 |

前提（NEED）都成立：伺服器與客戶端都拿著球棒、A 死前出生已 0.39 遊戲小時（門檻 0.200）。`SERVER STARTED` 之後只有 B 重生時、B 屍體被殭屍啃食的
原版 `ReceiveEatBody: zombie … not found`（6 行；對照組沒有 B 就沒有），沒有其他例外。同一份程式碼先跑過 `ds-fix-1029d`（沒發球棒、書包）與
`ds-fix-1029e`（arm 步驟還沒有 NEED），結果相同。死後 3 秒與 12 秒兩次查詢之間（伺服器時間相隔約 9.5 秒）存活時數增加 0.064 遊戲小時＝一遊戲小時
約 149 秒，和沙盒換算相符。更早的 `ds-fix-1029a`～`c` 是舊版（沒有存活時數這道、或用死亡點距離），結果不再引用。

42.22.2（2026-11-10，同一份情境加上「A 先活過最小存活時間」的等待；這次用的伺服器範本一天 90 分鐘，門檻 0.133 遊戲小時）：

- 對照組 `fx4222-death-ctl`：伺服器角色 12 秒時仍 `dead=false hp=1.00`、屍體 0；按重生被拒（`Coop player 1/4 already exists`），`players[0]` 68 秒都是 nil。
  原版在 42.22.2 沒有修這條。（這一輪的 RESULT 是 `INCONCLUSIVE`：當時情境還沒有那段等待，A 的存活時間前提不成立；這個前提只影響修正組。）
- 修正組 `fx4222-death-fix2`：A 7 項、B 6 項全過。A：`processed a death the server missed … n=1`、`user test died at (10722,9727,0) (non pvp)`、屍體 1 具、
  12 件物品各恰一份、重生正常，舊回報 `ignored … alive 0.001 game hours (< 0.133)`。B 走原版路徑、沒有補丁行，14 件物品各恰一份。
- 42.22 的伺服器 `die()` 改呼叫 `dropHeldItemsServer()`（`IsoGameCharacter.java:14872-14892`），手上的東西照樣掉在地上、物品守恆不變；
  `GameServer.java:905-916` 新增「延遲斷線佇列裡已死亡的玩家補 `die()`」，和本修復不衝突（本修復只處理伺服器上還活著的角色）。

### 可退場條件

官方讓伺服器處理客戶端判定的死亡（例如拖倒致死改由伺服器判定，或客戶端死亡時送死亡封包），或 `ConnectCoopPacket` 遇到舊角色還活著時
改成替它處理死亡。`check_vanilla_alignment.py` 的「成因」或「後果」轉 CHANGED 時，重跑 E2E `death-sync` 的對照組：客戶端單方面死亡後，
伺服器自己就有 `user died` 與屍體、重生正常，就移出本檔。

---

## MDFX_HealthCheatPermission — 強化多人伺服器對健康作弊（管理員功能）的驗證

| 項目 | 內容 |
|------|------|
| 檔案 | `shared/Fixes/MDFX_HealthCheatPermission.lua` |
| 影響版本 | Build 42.21.0 實測（原版 `media/lua/server/ClientCommands.lua` sha256 `c9de3d3024a46e2b…`；反編譯快照 `42.21.0-20260928`） |
| 端 | 多人伺服器（dedicated server 與合作主機的伺服器程序；本檔放 `shared/` 只為了比原版 `server/` 先載入，客戶端與單人不作用） |
| 類型 | 原版**伺服器指令的驗證缺口**：沒有 `UseHealthCheat` 的寄件者不能用健康作弊；參數不對不再讓原版丟錯 |
| 狀態 | **現役**（42.21.0-0.17.0 起） |

> 本條是安全修正：依家族保密規則（`pz-family-docs/conventions.md`「保密紅線」與內容歸宿表），原版缺口的細節、繞過方式與正式服紀錄只寫在本機知識庫，
> 這裡只記修法、驗證與退場條件。

### 症狀

- 多人伺服器上有人像無敵一樣、被咬也不感染，或玩家無故受傷；伺服器記錄裡，沒有管理員權限的帳號送過健康作弊。
- 參數不對的健康作弊請求讓伺服器丟 Lua 錯誤。

### 根因（行號為 42.21.0 原版 Lua）

- 原版處理健康作弊的伺服器指令（`ClientCommands.lua:474-627`）驗證不完整，參數也沒檢查。
- 合法的寄件者有兩種：管理員對自己作弊時送 `onHealthCheatCurrentPlayer`；管理員對別人作弊時送 `onHealthCheat`，伺服器檢查管理員權限後把同一份參數轉給目標的客戶端
  （`:477`），目標的客戶端再替自己送 `onHealthCheatCurrentPlayer`（`ISHealthPanel.lua:329-332` → `:1964-1969` → `:191-195`，`id` 是自己）。
  第二種的寄件者是沒有權限的目標本人，所以不能只看寄件者有沒有權限：直接擋掉會讓管理員對別人的健康作弊失效。

### 修法

- **掛點**：原版的 `Commands` 是檔內 local，拿不到單一指令；改包整支分派器 `ClientCommands.OnClientCommand`（`:1296-1307`）。本檔放 `shared/`，
  專用伺服器先載入全部 `shared/` 再載入 `server/`（`GameServer.java:1469-1471`），所以早於原版檔：載入時暫換 `Events.OnClientCommand.Add`
  （`Events.X` 是一般 Lua 表，`Event.java:78-83`），以 `getFilenameOfClosure`（`LuaManager.java:7345-7347`）認出原版 `server/ClientCommands.lua`
  傳進來的函式（路徑不含 `/mods/`；別的 MOD 蓋掉這個檔時不包），換成包裝再交給引擎；其他函式原樣轉交。`OnGameBoot` 換回 `Add`，原版檔恰好登記一支才啟用，
  否則印 `NOT installed`、包裝照原版轉交。沿用 `MinidoracatServerPatchFor42` 的 `MSP_SemiTruckRestoreThrottle` 攔截註冊的做法。
- **包裝只看 `player` 模組的兩個指令**，其餘（含別的模組的同名指令）原樣交給原版，參數表不換：
  - `onHealthCheat`：原版會轉送時（`args.id` 是在線玩家、寄件者有 `UseHealthCheat`，與 `:476` 同一條件）先給目標記一張轉送票
    （部位、action、時間），再照原版處理。
  - `onHealthCheatCurrentPlayer`：寄件者有 `UseHealthCheat` 就照原版。沒有時只放行管理員轉給他的那一筆：`args.id` 是寄件者自己、部位與 action 和票上的相同、
    轉送後 `TICKET_MS`（30 秒）內。票只用一次，寄件者有權限時也照樣用掉（之後被撤權也不能拿來重放）。其餘拒絕，不改任何人。
  - 參數不合法一律拒絕、不丟錯，有權限也一樣：`args` 不是表、`args.id` 不是在線玩家的 onlineID（查到的玩家 `getOnlineID()` 要等於 `args.id`）、
    `bodyPartIndex` 不是 0～部位數-1 的整數。
- **自己的檢查包在 `pcall` 裡**：檢查本身出錯時，`onHealthCheatCurrentPlayer` 拒絕、`onHealthCheat` 照原版，各印一次。原版自己的錯原樣外洩（`onHealthCheat` 的壞參數照原版丟錯）。
- **診斷**：每次拒絕一行
  `[MinidoracatFixes] MDFX_HealthCheatPermission denied onHealthCheatCurrentPlayer (no UseHealthCheat): player="<名稱>" onlineID=<n> steamid~<數字> target=<args.id> action=<action> part=<部位>.`
  （壞參數是 `bad … (<原因>)`），每個連線（Steam 伺服器是 SteamID 加 onlineID，否則是 onlineID 加名稱）每 session 最多 `LOG_LIMIT`（20）行，超過印一次提示、照樣拒絕。不照「一 session 一次」：每一行都是一次被擋下的請求，分析 repo 拿它抓外掛。
  名稱由客戶端提供，不能當身分，認人看 `steamid~` 或 `_cmd.txt`；SteamID 是捨入值、相鄰的帳號會相同，onlineID 斷線後會給下一個人，所以額度兩個一起看。
  名稱與參數輸出前去掉控制字元與引號、最多 32 字，不能偽造 log 行。
  `steamid~` 是 `getSteamID()` 的 long 轉成 Lua double 後的值（`KahluaNumberConverter.java:106、113`），SteamID64 會被捨入到 16 的倍數；
  精確值看同一秒 `Logs/*_cmd.txt` 那一行（開頭是連線的 SteamID，`GameServer.java:2290-2305`）。非 Steam 伺服器寫 `none`。
- 形狀不符（`Events.OnClientCommand`／`OnGameBoot`、`getFilenameOfClosure`、`checkPermissions`、`getPlayerByOnlineID`、`getTimestampMs`、`Capability.UseHealthCheat` 不存在）
  印 `NOT installed`、不換 `Add`。

### 與原版的差異

- 沒有 `UseHealthCheat` 的帳號不論客戶端設定，都不能再用健康作弊，改自己也一樣；管理員對自己、對別人（含轉送）照原版。
  使用者 2026-11-06 同意（`MinidoracatServerAnalyze` 交接：沒有 `UseHealthCheat` 就拒絕、壞參數也拒絕）。
- 參數不對的請求原本讓伺服器丟一次 Lua 錯誤，現在印一行 `bad …`。

### 已知限制

- 轉送路徑仍信任目標客戶端回送的那一筆：管理員轉送後 30 秒內，目標可以把這一筆換成同一部位、同一 action 的作弊（本來就是管理員要做的那一筆）。
- 管理員對分割畫面的第 2～4 位玩家作弊時，原版客戶端用第 1 位玩家回送（`ISHealthPanel.lua:1967`，原版本來就套到錯的角色），本補丁拒絕並記成第 1 位玩家的 `denied`；
  回送晚於 30 秒時也記成 `denied`。分析 `denied` 行時，之前不久有管理員送過健康作弊的（`_cmd.txt` 的 `player.onHealthCheat`；分割畫面約在同一秒、
  逾時在 30 秒以上之前；`_cmd.txt` 不記參數，對象與部位對不出來），先當成這兩種。
- log 額度實際按玩家槽（onlineID）算：分割畫面每位玩家各一份；同一帳號重連分到別的槽（Steam 伺服器）、或重生後換名（非 Steam 伺服器）可能換一份 `LOG_LIMIT`，
  每次最多 20 行。拒絕不受影響。
- 攔不到原版的登記時印 `NOT installed`、照原版：別的 MOD 整份蓋掉原版 `ClientCommands.lua`、別的 MOD 在本檔載入前就 `require` 原版檔、
  晚於本檔的 `shared/` 檔換掉 `Events.OnClientCommand.Add` 又不轉交給換掉前的函式。伺服器中途重載 Lua 後沒有再觸發 `OnGameBoot` 時不啟用。
- 只處理健康作弊；同檔其他伺服器指令不在本修復範圍。

### 驗證

`lua scripts/test_health_cheat_permission.lua` — 82 項，全綠。假 Java 端照快照形狀模擬 `Events.X.Add`、`getFilenameOfClosure`、`checkPermissions`、
`getPlayerByOnlineID` 的數字轉換、`ArrayList.get` 的丟錯，與原版分派器（`onHealthCheat` 有權限才轉送）。
涵蓋：只包原版檔那一支（同目錄的原版 `VehicleCommands`、別的 MOD 的登記、MOD 蓋掉的 `ClientCommands.lua` 都原樣轉交）、`OnGameBoot` 換回 `Add`；
一般帳號改別人、改自己都拒絕並記一行；管理員對自己、對別人照原版；13 種壞參數拒絕、不丟錯、原版不被呼叫；
轉送：目標回送的那一筆放行一次、重放拒絕，部位不同、action 不同、拿票改別人、別人拿這張票都拒絕而且不消耗票，兩次轉送兩筆都放行、第三筆拒絕，
一般帳號送 `onHealthCheat` 不記票，剛好 30 秒放行、超過 1 ms 或時鐘倒退拒絕，有權限的目標回送也用掉票、撤權後重放拒絕；
其他指令與別的模組的同名指令原樣交給原版（同一張參數表）、原版的錯原樣外洩；自己的檢查出錯時作弊指令拒絕、轉送照原版，各印一次；
同一個連線 25 次拒絕印 20 行加一次上限提示、換名不換額度、捨入後 SteamID 相同的另一個連線與非 Steam 伺服器接手同一個 onlineID 的人照樣記，SteamID 以完整十進位輸出（不是科學記號），
參數與名稱去掉換行與引號、截到 32 字（拒絕行與上限提示都是）；
`OnGameBoot` 之前照原版；原版檔登記 0 支、2 支印 `NOT installed` 並照原版；客戶端／單人什麼都不動；缺 `getFilenameOfClosure` 印 `NOT installed`、不換 `Add`；重複載入不疊。

**mutation 驗證**（`--mutants`，38 個全部抓到）：每道防線各一個（權限、票的 id／部位／action／期限／時鐘倒退／消耗／有權限也用掉、轉送記票要看權限、
參數的表／數字／onlineID 複核／整數／上下限、計數、log 上限與額度的連線身分、參數與名稱的清理與截長、SteamID 文字化、`pcall` 與失敗時的放行方向、
啟用時機、原版登記數、`/mods/` 與檔名比對、換回 `Add`、形狀檢查、重複載入防護）。

`python scripts/check_vanilla_alignment.py` 登記 4 條：補丁前提（`onHealthCheatCurrentPlayer` 開頭的形狀）、依賴（`onHealthCheat` 的轉送條件、
分派器的呼叫形狀、全檔恰好一次 `Events.OnClientCommand.Add(ClientCommands.OnClientCommand)`、`ISHealthPanel` 回送的參數形狀與收到轉送後的呼叫、
`GameServer` 先載入 `shared/` 再載入 `server/`、`Event.register` 把 `Add` 放在一般表上），退場提示（`onHealthCheatCurrentPlayer` 裡出現權限檢查）。

實機（`fixes-e2e` skill 的 `health-cheat`，42.21.0 專用伺服器）：伺服器端安裝面 `fixes-hc-srv-1106g` 印
`MDFX_HealthCheatPermission installed (vanilla OnClientCommand dispatcher wrapped)`、沒有 `NOT installed`、`SERVER STARTED` 之後零例外。
2026-11-07 多人雙客戶端（A 管理員、B 一般帳號）：修正組 `fixes-hc-fix-1107a` 兩個客戶端都 `RESULT PASS`（A 8 個 CHECK、B 7 個），
伺服器的拒絕與壞參數 log 行數符合 skill 的判定，`SERVER STARTED` 之後零例外。對照組用加入本補丁前的版本（`--rev MinidoracatFixesFor42=dc709c1`，
`fixes-hc-ctl-1107a`）：`RESULT FAIL class=check`，原版缺口重現，壞參數讓伺服器丟 Lua 錯誤。

### 42.22 對版

42.22 官方已在原版指令補上權限驗證，管理員對別人用健康面板時也改由伺服器直接處理；細節照保密規則只寫在本機知識庫
`server-commands.md`。參數仍沒有驗證：2026-11-10 實機 `fx4222-hc-ctl`（42.22.2、修正檔拿掉）一般帳號改不了別人與自己，
但管理員送出 5 個參數不對的請求後，伺服器的 Lua 錯誤計數由 0 增加到 20。本修復在 42.22.2 照樣安裝（分派器形狀沒變），被拒的請求照樣記一行、
參數不對照樣擋下；轉送票只在 42.21 有作用。退場條件還沒達成，照舊保留。`check_vanilla_alignment.py` 把權限檢查改登記成 retired 指紋（官方驗證還在）。

修正組實機（2026-11-10，42.22.2，`fx4222-hc-fix`，情境已照 42.22 的原版行為改寫）：兩個客戶端 `RESULT PASS`（管理員 8 項、一般帳號 7 項）；
5 個參數不對的請求伺服器 Lua 錯誤 0 → 0、各記一行；一般帳號的請求被拒並記錄；管理員對自己、對別人照原版生效。
已知差異：管理員剛對某位玩家用過健康面板後 30 秒內，那位玩家自己送出同部位、同動作的請求時，本修復把它當成 42.21 的轉送交給原版，
原版照樣拒絕（不改任何人），只是這一筆不記 `denied`。

### 可退場條件

官方讓 `onHealthCheatCurrentPlayer` 自己驗證權限與參數，而且管理員對別人作弊的轉送路徑仍可用（42.22 的狀態見上一節）。
`check_vanilla_alignment.py` 的前提條目轉 CHANGED 或退場提示出現時，
重跑 E2E `health-cheat` 拿掉修正檔的那一輪：一般帳號改不了別人、管理員三項照樣過、壞參數不丟錯，就移出本檔。

## MDFX_VehicleSinkGuard — 多人遊戲開車時車掉到地板下（畫面全黑、車陷在地下、重登也一樣）

| 項目 | 內容 |
|------|------|
| 檔案 | `client/Fixes/MDFX_VehicleSinkGuard.lua` |
| 影響版本 | Build 42.22.2 實測（反編譯快照 `42.22.2-20261109`；`BaseVehicle.update` 的寫法 42.21 相同） |
| 端 | 多人遊戲的客戶端（`isClient()`；單人與伺服器不作用） |
| 類型 | 原版**不把掉到地板下的車放回地面**；事後放回，不處理車為什麼掉下去 |
| 狀態 | **現役**（`42.22.2-0.18.0` 起） |

### 症狀

- 多人遊戲開車時（高速行駛、碰撞，或畫面突然被拉回之後）畫面突然全黑，只剩介面與小地圖。
- 下車後車身陷在地面下、上不去；重新登入也一樣。
- 玩家回報紀錄與成因分析在 `MinidoracatServerAnalyze` 的事件報告（2026-11-10）。

### 根因（行號為 42.22.2 反編譯快照）

- 多人遊戲裡，車的物理只在駕駛（或開車撞到它的人）的客戶端算（`isLocalPhysicSim()`：授權 `Local`／`LocalCollide`）；伺服器照收客戶端回報的位置與高度
  （`VehiclePhysicsPacket.processServer` 直接寫入，沒有夾樓層）。
- 原生物理在一次碰撞、或車被拉到地面碰撞體還沒建好的地方時，可能把車推到地板下。`BaseVehicle.update()`（`BaseVehicle.java:3402-3451`）只用物理高度
  推算樓層，不把車放回地板以上；原版只有從存檔載入時（`BaseVehicle.load`，`:2738-2740`）把高度夾在樓層地板以上。
- 坐在車上時鏡頭跟著車的物理高度，原點在地板下就全黑；車一路往下掉（對照組 5 秒掉到 −145），伺服器照那個高度存檔，重新登入拿到的還是地下的車。

### 修法

- **掛點**：`OnTick`（`IngameState.updateInternal` 在 `IsoWorld.update` 之後才分派，所有車的 `update` 已跑完）。只在 `isClient()` 時做事。
- **看哪些車**：`getCell():getVehicles()`（回 `Set`，用一個重複使用的 `ArrayList:addAll` 取出）裡 `isLocalPhysicSim()` 的車。
- **判定**（和 `MinidoracatJavaPatchFor42` 的客戶端修補 W65 相同）：物理原點（`getWorldTransform():getOrigin():y()`）比所在樓層地板
  （`floor(getZ()) × 2.44949`）低 0.25 以上，而且那一格 `hasFloor()`。翻覆的車（`getUpVectorDot() < 0.8`，原版 `MINIMUM_DOT_UPRIGHT`）要低於地板一層以上才處理。
- **放回**：翻覆的先用原版 `setAngles(0, 車頭角度, 0)` 扶正（車頭角度由前向量的水平分量算出，方向不變）；再把原點的高度改成放回高度，
  用原版 `setWorldTransform` 寫回（客戶端走原生 `teleportVehicle`，速度一併歸零）。水平位置不動。本機下一則車輛物理封包就把地面上的高度送給伺服器。
- **放回前先 `setPhysicsActive(true)`**（2026-11-15 起）：有駕駛而靜止滿 1 秒的車，原版會把它的物理停掉（`CarController.checkShouldBeActive` 的 `atRestTimer`）；
  停掉的車在原生端被設成 kinematic（`PZVehicle::setStatic`，42.21 native 反編譯），`teleportVehicle` 設的姿勢留不住、之後讀回的還是地板下的值
  （推測是 Bullet 每次步進從 motion state 取 kinematic 物體的姿勢；實機現象相符，沒有讀到那段原生碼）。
  不先打開的話，這種車（例：已經陷在地下、玩家坐上去發動）要等原版自己重新打開物理後才放得回去，中間每幀各介入、各記一行（實機 2～3 次）。
  診斷行的授權描述取打開物理之前的值（`static=true active=false` 表示那台車當時物理是停掉的）。
- **放回高度**：樓層地板＋原版 `CarController` 生成車輛的算法 `−min(模型偏移＋第一個輪子偏移－輪半徑, 重心偏移－車身高÷2)`，至少 0.1。
- **自保**：每幀整段 `pcall`；出錯就停用本補丁並印一次。缺 `Transform`／`Vector3f`／`ArrayList`／`OnTick` 等印 `NOT installed`、不登記。
- **診斷**：每次放回印一行 `MDFX_VehicleSinkGuard vehicle <編號> <車型> at <x>,<y> (<授權描述>): physics height … is below the floor of level …; [flipped (up …), set upright keeping its heading, ]lifted to … (#n)`，
  每次啟動最多 20 行（之後照樣放回、不再記）。使用者要能從玩家 console 統計發生次數，所以不是一個 session 一次。

### 與 W65 的差異

- **放回高度的輪半徑用上限 0.5**：Lua 讀不到 `VehicleScript.Wheel.radius`（public 實例欄位、沒有 getter；Kahlua 只曝露方法與 public static 欄位）。
  原版 130 個有輪子的車輛腳本，輪半徑乘模型縮放最大 0.273，所以車放在比停放高度略高的地方、自己落回地面。實測 SUV：停放高度 0.320、放回 0.610，約 1.4 秒落定。
  官方替 `Wheel` 加 `getRadius` 之後改讀實際值（`check_vanilla_alignment.py` 有退場提示）。
- **不另外把速度歸零**：W65 自己清速度；Lua 沒有對應的 setter，靠原生 `teleportVehicle` 清（實測放回後下一拍速度 0.1～0.2、之後靜止）。
- **並存**：裝了修補包的客戶端，W65 在車的 `update` 裡先放回，本補丁在同一幀稍後看到的高度已經正常，不介入（實機 `fxvs-w65-1110a`，見「驗證」）。

### 與原版的差異

- 掉到地板下的本機模擬車會被放回地面（原版一路往下掉）。只在原版本來就壞掉的狀態下介入；沒掉下去的車、翻覆而只低一點的車照原版。使用者 2026-11-10 同意。

### 已知限制

- 不處理車為什麼掉下去；只在掉下去之後放回，放回時車從略高於地面的地方落下。
- 原點在地板下、那一格卻沒有地板的車（地圖邊緣、還沒載入的格子）照原版。
- 已經陷在地下、沒有人在開的車不處理：它不由任何客戶端模擬，伺服器重新從存檔載入那台車時原版會夾回地板。
- 單人遊戲的車不由客戶端授權模擬（`isLocalPhysicSim()` 恆為 false），本補丁不作用。
- 伺服器端沒有等價的防護：沒裝本 MOD 的客戶端（或改過的客戶端）回報的地下高度，伺服器照收。那是 `MinidoracatJavaPatchFor42` 伺服器修補 W64 的範圍。

### 驗證

`lua scripts/test_vehicle_sink_guard.lua` — 70 項，全綠。假 Java 端照快照形狀模擬車輛（物理原點、授權、朝上程度、前向量）、`setAngles`、`setWorldTransform`、
車輛腳本與 `Set` 形狀的車輛清單。涵蓋：淺於門檻不動、剛過門檻放回、樓上的車以該層地板為準、翻覆而不到一層不動、翻覆又超過一層扶正並保留車頭方向、
沒有地板或格子沒載入不動、非本機模擬不動、單人與伺服器不動、沒有輪子的車與模型偏移缺值的放回高度、同一幀已被放回的車不再動（W65 並存）、
log 上限與上限提示、出錯後停用並只印一次、缺 API 印 `NOT installed`、重複載入不疊、物理停掉的車（假引擎裡放車不生效）先打開物理再放回。

**mutation 驗證**（`--mutants`，37 個全部抓到）：每個判定條件、每個常數、放回高度公式的每一項、扶正角度、授權過濾、`isClient` 閘門、log 上限、`pcall` 與停用、放回前打開物理各一個以上。

`python scripts/check_vanilla_alignment.py` 登記 11 條（Java 指紋）：成因兩條（`BaseVehicle.update` 恰一個 `setWorldTransform`、沒有夾高度；
`VehiclePhysicsPacket.processServer` 沒有夾樓層）、放回高度公式的來源（`CarController` 建構子）、依賴（`VehicleScript`、`Wheel`、`Transform.getOrigin`、
`IsoGridSquare.hasFloor`、`IsoCell.getVehicles` 回 `Set`、`LuaManager$Exposer` 曝露 `Transform`／`Vector3f`、`BaseVehicle.setPhysicsActive`）、前提（`OnTick` 在 `IsoWorld.update` 之後）；
退場提示：`Wheel` 出現 `getRadius`。

實機（`fixes-e2e` skill 的 `vehicle-sink`，2026-11-10，42.22.2 專用伺服器＋一個客戶端，原版伺服器、沒有任何 Java 修補）：

- 修正組 `fxvs-fix-1110b`：`RESULT PASS steps=15 checks=19`（前一輪 `fxvs-fix-1110a` 沒有行駛步驟，14 步 17 項同樣通過，下面的數字取自它）。
  怠速、正常行駛（定速開 6 秒再煞停：7.8 公尺、最高 18.2 km/h）、原點在地板下 0.10、翻覆而在地板下 1.2 都不介入；翻覆的車掉過一層（−2.475）那一幀扶正放回；
  四輪朝天、車頭 30°、高度 −20 的車下一拍回到 0.610、朝上 1.000、車頭仍 30°，守衛恰好介入一次；之後 15 秒高度 0.320、速度 0、守衛沒有再介入，
  伺服器記的高度 0.320、朝上 1.000；正的車設到地板下 0.6 下一拍放回、不扶正。每幀成本：附近 4 台車時 4 µs（參考值）。兩端沒有 `NOT installed`、沒有停用訊息。
- 對照組 `fxvs-ctl-1110a`（把本檔拿掉）：同樣設到 −20，5 秒後高度 −145.8、仍四輪朝天、速度 50，畫面全黑只剩介面。
- 與修補包並存 `fxvs-w65-1110a`（客戶端另裝 `MinidoracatJavaPatchFor42` client 包 0.3.1 的 `core`＋`client-fixes-standard`，console 有
  `[MinidoracatPatches] installed=client-fixes-standard version=v3.8`）：`RESULT PASS steps=11 checks=15`。設到 −20、四輪朝天的車下一拍回到 0.383、扶正、車頭仍 30°，
  正的車設到地板下 0.6 也下一拍放回；整輪本補丁的計數都是 0（由 W65 處理），沒有重複介入。
- 坐上駕駛座但不發動引擎的車（`fxvs-park-1110a`）：`isLocalPhysicSim()` 30 秒都是 false，不是本機模擬，本補丁不看它（這一輪因此停在情境的前置步驟，沒有做下沉）。
- 2026-11-15 物理停掉的車（42.22.2，9950X3D；情境加了 `static-sink`，並在每個設姿勢的步驟前先讓物理保持啟用）：
  已發布的 `42.22.2-0.20.0`（`c3baf74`）`fxvs-red3-vehicle-sink-1115-010659-d3c0b5` `RESULT FAIL checks=22 failed=2`：物理停掉、在地板下 0.6 的車，守衛放車後物理還是停的，
  下一幀又介入一次（共 2 次；整套回歸 `lst-fix-vehicle-sink-1114-144706-7eba4e` 同一種狀態是 3 次）。車最後都回到地面。
  加了「放回前先打開物理」之後 `fxvs-green3-vehicle-sink-1115-010701-a0460d` `RESULT PASS steps=16 checks=22`：同一種狀態恰好介入一次、放車當下物理已打開、2 秒後高度 0.320。

### 可退場條件

官方在 `BaseVehicle.update()` 把掉到地板下的車放回地面，或伺服器收車輛高度時夾樓層。`check_vanilla_alignment.py` 的兩條成因任一轉 CHANGED 時，
重跑 E2E `vehicle-sink` 的對照組（`--define mode=control`）：車自己回到地面就移出本檔。

---

## MDFX_WindowFaceGuard — 北側牆上的新款窗拆下後裝不回去

| 項目 | 內容 |
|------|------|
| 檔案 | `shared/Fixes/MDFX_WindowFaceGuard.lua` |
| 影響版本 | Build 42.22.2 實測（原版 `shared/Moveables/ISMoveableSpriteProps.lua`，反編譯快照 `42.22.2-20261109`） |
| 端 | 三端、無閘門（客戶端的放置游標與完成端的 `placeMoveable` 都呼叫同一個判斷；多人的完成端是伺服器） |
| 類型 | 原版**判錯方向**；原版說放不上時照北向再問原版一次 |
| 狀態 | **現役**（`42.22.2-0.18.0` 起） |

### 症狀

- Build 42 新增的四個窗 tileset（`fixtures_windows_white`、`_metal`、`_church`、`_wood`）裡北向（`Facing=N`）的窗，用撬棍拆下來之後，
  放置游標指回原本的北牆窗框永遠是紅色，裝不回去。窗框還在、是空的，木工等級與鐵鎚都夠。單人與多人都一樣。
- 舊 tileset（`fixtures_windows_01`）的窗不受影響。
- 玩家回報（Discord，2026-11-10）：白色窗框拆下後裝不回原位。

### 根因（行號為 42.22.2 原版 Lua）

- `ISMoveableSpriteProps:canPlaceMoveableInternal` 的 Window 分支在 `:1941` 決定找哪一道牆的窗框：
  `local isNorth = (self:hasFaces() and self.facing == "N" or self.facing == "S") or false`。`Facing=N` 的窗要 `hasFaces()` 也是 true 才算北向。
- `hasFaces()`（`:258-276`）要圖塊有 `Noffset`／`Woffset` 這類換面資料。這份資料由引擎讀圖塊定義時，替同一個 tileset 裡 `GroupName`＋`CustomName`
  相同的一組圖互寫；一組超過 4 張就整組不寫（`IsoWorld.java:1316-1338`）。
- 四個新 tileset 各自整個 tileset 用同一組名稱，共 396 張窗都沒有換面資料：北向的 198 張 `isNorth` 算成 false，原版改找西牆的窗框（`:1942`），找不到。
- 放下去的那一段（`placeMoveableInternal` `:2077`）與走過去的那一段（`walkToAndEquip` `:3081`）都直接照 `Facing` 判斷，只有 `:1941` 多看了 `hasFaces()`。
- 多人遊戲時伺服器完成放置動作會再判一次（`placeMoveable` `:2050`），所以客戶端與伺服器都要修。

### 修法

包裝 `ISMoveableSpriteProps.canPlaceMoveableInternal`：

1. 先原樣呼叫原函式。原版說放得上就照原版。
2. 原版說放不上、而且這張是 `type == "Window"`、`facing == "N"` 時，暫時把這個實例的 `facing` 改成 `"S"`，以 `pcall` 再呼叫原函式一次，呼叫完立刻改回 `"N"`。
   原版在 `:1941` 自己把 `"S"` 當北向，找的是同一道北牆窗框。窗框、已有的窗、技能、工具都還是原版那一段在判。
3. 第二次說放得上才回它的結果，並印一次診斷行。第二次拋錯：印一次警告，回原版第一次的結果。

不複製 Window 分支的判斷（遊戲更新時會和原版走偏）。不補圖塊的換面資料（會改 396 張圖塊的屬性，其他讀這些屬性的 MOD 會跟著變）。

### 和原版的差異

- 原本放不上的北向新款窗，指到北牆的空窗框時變成放得上（使用者 2026-11-10 同意）。
- 原本放得上的情況不變：第 1 步原版回 true 就直接回。有換面資料的北向窗原版本來就照北向判，再判一次結果相同。
- 沒有改的原版行為：這些窗仍然不能在北、西之間換面（西向的新款窗指到北牆窗框照樣放不上）；北向的新款窗指到西牆窗框時，
  游標不是紅色但點下去不排任何動作（`walkToAndEquip` 照 `Facing` 找北牆窗框，找不到）。

### Log

- `[MinidoracatFixes] MDFX_WindowFaceGuard: vanilla refused north-facing window <圖塊> on its north frame (it looked for a west frame); accepted at <x>,<y>,<z>. Further occurrences not logged this session. …`
  ——每次開機第一次放行時印一行。多人遊戲時客戶端（`console.txt`）與伺服器（`server-console.txt`）各印各的。
- `[MinidoracatFixes] MDFX_WindowFaceGuard: the north-facing re-check threw; keeping the vanilla answer: …`——第二次呼叫拋錯（原版第一次沒拋），照原版結果，一次。
- `[MinidoracatFixes] MDFX_WindowFaceGuard NOT installed: vanilla ISMoveableSpriteProps shape changed; …`——包裝目標不在，回頭對版。

### 驗證

離線：`lua scripts/test_window_face_guard.lua`（照載原版 `ISMoveableSpriteProps.lua`，55 項）；`--mutants` 17 個突變都要被抓到。

實機（42.22.2，9950X3D，`fixes-e2e` 的 `window-faces` 情境；地點是玩家回報的房子，北向窗 `fixtures_windows_white_25` 在 7317,8541，西向窗 `_24` 在 7320,8539）：

- 原版對照（MOD 樹沒有本檔）多人 `fxwf-ctl-mp-1110e`、單人 `fxwf-ctl-sp-1110d`：`RESULT PASS steps=17 checks=12`。北向窗拆下後游標指回原窗框 `canCreate=false`；
  不經游標直接排放置動作，完成端 `canPlaceInternal=false`、不放、物品留在背包。西向窗拆下再放回成功。舊款西向窗指到同一個北牆窗框，游標自己換成北向並放得上。
  另外三組的北向窗（`fixtures_windows_metal_1`、`_church_1`、`_wood_1`）游標同樣被拒。四組實機都讀到 `hasFaces=false`。
- 修正組多人 `fxwf-fix-mp-1110f`、單人 `fxwf-fix-sp-1110d`（收錄的 commit `54055b5`）：`RESULT PASS steps=14 checks=10`。北向窗放回原窗框，伺服器那一格有 `fixtures_windows_white_25`；
  另外三組游標可放（沒有實際放）；西向窗與「北向窗指到西牆窗框」和對照組相同。客戶端與伺服器各一行診斷，沒有 `NOT installed`、`re-check threw`。

玩家另外回報的兩格（7320,8539、7322,8536）沒有重現：兩格都是西向的 `fixtures_windows_white_24`，拆下再放回都成功（7320,8539 多人、單人多輪；7322,8536 多人 `fxwf-fix-mp-1110g`）。
本補丁不碰西向窗，這兩格的結果就是原版的結果。玩家當時怎麼試的還不知道。

### 可退場條件

官方替這四個 tileset 補上換面資料，或 `:1941` 不再看 `hasFaces()`。兩種情況原版在第 1 步就回放得上，本補丁自動不介入。
`check_vanilla_alignment.py` 的爆點行轉 CHANGED 時，重跑 E2E `window-faces` 的對照組：`RESULT INCONCLUSIVE`（圖塊有換面資料了）或北向窗游標可放，就移出本檔。

---

## MDFX_StaleWornGuard — 把穿著的東西放到地上後，身上還畫著它、要重登（單人：重新讀檔）才好

| 項目 | 內容 |
|------|------|
| 檔案 | `server/Fixes/MDFX_StaleWornGuard.lua` |
| 影響版本 | Build 42.22.2 實測（原版 Lua 與反編譯快照 `42.22.2-20261109`）；玩家回報在 42.21.0 |
| 端 | 多人遊戲的伺服器與單人（載檔時 `isClient()` 就不安裝：多人客戶端不作用） |
| 類型 | 原版**放下物品時不清穿戴**；事後拿掉，不改放置的流程 |
| 狀態 | **現役**（`42.22.2-0.18.0` 起） |

### 症狀

- 多人遊戲用右鍵「放置物品」把穿著的背包（或衣物）放到地上：物品離開物品欄、地上有，但背上照畫，背包給的快捷列欄位不消失，重新登入才好。
- 玩家回報（Discord 影片，2026-11-10，42.21.0 正式服）：背包「脫不下來，需要重登解決」。原版 `Base.Bag_ALICEpack` 照同樣操作一樣會，不是物品 MOD 的問題。
- 單人：開著外觀類 MOD 時同樣會發生，重新讀檔才好；不開時原版先脫下再放，不會發生（實機見「驗證」）。
- 右鍵「扔掉」「解除裝備」不受影響。

### 根因（行號為 42.22.2 原版 Lua 與反編譯快照）

1. **要不要先脫下，由客戶端在排動作的那一刻判斷**：`ISPlace3DItemCursor:create`（`server/BuildingObjects/ISPlace3DItemCursor.lua:27`、`:38`）用
   `self.chr:isEquipped(item)` 決定要不要在 `ISDropWorldItemAction` 前面排 `ISUnequipAction`。
2. **伺服器放下時不碰穿戴**：`ISDropWorldItemAction:complete`（`shared/TimedActions/ISDropWorldItemAction.lua:81-91`）只 `AddWorldInventoryItem`、
   `getInventory():Remove`、`sendRemoveItemFromContainer`。客戶端沒排脫下，伺服器與客戶端的穿戴清單就都留著那件。
3. **主路徑：客戶端那一刻判斷錯**。外觀類 MOD（實測 Mirage Wardrobe，Workshop 3770186452）在 `OnTick` 到 `OnPostRender` 之間把角色的 WornItems
   換成複製品；放置游標是在繪製畫面時放下的（`DoTileBuilding`），那時 `isEquipped` 讀到複製品、回 false，只排放下。
4. **伺服器照收客戶端的穿戴清單**。`SyncClothingPacket.process`（`SyncClothingPacket.java:176-217`）把清單上伺服器沒穿著的編號穿回去（`:192-204`）；
   物品欄裡找不到該編號時，`InventoryItemFactory.CreateItem` 另建一件同編號的物件穿上（`:195-200`）。背包不是 `Clothing`，`:193` 的轉型恆為 null，
   所以清單上的背包每收到一次清單就重穿一次；物品欄裡沒有它時，每次都另建一件新的。兩個後果：
   - **次路徑**（不靠外觀 MOD）：脫下之後、放下之前到的舊清單把那件穿回，接著放下，結果和主路徑相同。
   - **真物品被換成另建的物件**：客戶端還當它穿著時，放下之後送來的每一份清單都把伺服器的穿戴換成另建的物件（不在任何容器、也不在地上）。
5. **重登會好**：存檔用物品欄索引記穿戴（讀檔 `IsoPlayer.java:1263-1264`），那件已不在物品欄。

### 修法

- **掛點**：伺服器 `OnTick`，每 `CHECK_MS`（1000 ms）檢查一次；其餘 tick 只比一次時間（`getTimestampMs` 是系統時鐘，被往回調超過一個間隔時不等它追上）。
- **單人**：同一支、同一套判定，看本機玩家（`getNumActivePlayers`／`getSpecificPlayer`，沒人的位置跳過），掛 `OnTickEvenPaused`、不掛 `OnTick`。
  外觀 MOD 在 `OnTick` 把穿戴清單換成複製品、`OnPostRender` 才換回，`OnTick` 裡讀到、改到的可能是複製品；`OnTickEvenPaused`（`IngameState.java:1346`）在
  `IsoWorld.update`（`:1535`）與 `OnTick`（`:1653`）之前，每幀一次更新接一次繪製（`GameWindow.java:667-691`），這時是真清單。單人沒有穿戴清單的封包，實際只會走「在地上／在別的容器」那一種。
  拿掉成功後補發 Lua 的 `OnClothingUpdated`（照 `ISUnequipAction:complete` `:132`）：`setWornItem` 自己不發，快捷列與物品欄靠它重算（`ISHotbar.lua:837-845`）；多人由客戶端收到新清單時發（`SyncClothingPacket.java:227`），伺服器不補。
  單人放到地上的物品，放下那一刻 `getContainer()` 是 nil，稍後變成地面的容器，`getWorldItem()` 一直有值（實機 `swe2e-sp-mir-1111a`：`DROP.complete` 當下 `container=nil worldItem=true`，8 秒後 `container=floor worldItem=true`；伺服器上一直是 nil）。
  所以判定先看 `getWorldItem()`，兩種形狀的診斷行都寫 `on the ground`。
- **記先例**：每位活著的玩家（伺服器 `getOnlinePlayers()`），逐件看 WornItems；穿著、而且 `getContainer()` 就是自己主物品欄的物品，把編號記在這位玩家名下。
  玩家離線就整份丟掉。
- **判定**：下面兩種算殘留，**同一個編號連兩次檢查都成立**才處理（照編號記，不照物件：另建的物件每收到一次清單就換一件）：
  - 它在別處，照這個順序看：`getWorldItem()` 不是 nil（在地上；這時 `getContainer()` 是 nil 或地面的容器），或 `getContainer()` 是別的容器（被撿走、被搬走）。
  - 不在任何容器、也不在地上（照清單另建的物件），而且這位玩家名下記過同一個編號。
- **處理**：`player:removeWornItem(item, false)`。它走原版 `setWornItem`（`IsoGameCharacter.java:3460-3518`），伺服器把新的穿戴清單送給所有客戶端
  （`IsoPlayer.syncClothing`，`IsoPlayer.java:8956-8959`），客戶端照清單拿掉（`SyncClothingPacket.java:181-190`），快捷列跟著重算。
  第二個參數必須是 false：true 時物品欄放不下就把這件再丟到地上一次（`IsoGameCharacter.java:3477-3487`）。
- **登記回每幀更新清單**：`setWornItem` 會把舊的那件排進 `IsoCell` 的移出清單（`:3464-3466`）；真物品這時已經在地上或別人的容器裡，
  拿掉後呼叫 `getCell():addToProcessItems(item)`（和 `ItemContainer.AddItem` `:540-542` 相同：取消移出，不需要更新的物品下一輪自己退出）。
  不補的話，被別人撿走的那件會停止更新（讀碼：例如設了鬧鐘的手錶，`AlarmClockClothing.java:106-140`）。另建的物件不登記。
- **拿不掉的不碰、不重試**：可以同時穿多件的部位（`BodyLocationGroup.isMultiItem`）不呼叫 `removeWornItem`：`WornItems.setItem` `:54-59` 在那裡不移除，`setWornItem` 還會把該部位的第一件（不一定是這一件）移出每幀更新清單。
  呼叫後那件還在穿戴清單的（Java 端出錯被 Kahlua 記錄後照常返回）一樣。兩種都記一行 `could not remove stale worn item …`（每次啟動只記第一件），這個編號之後不再處理，不讓伺服器每兩秒重送一次穿戴清單。
- **不動的**：沒有先例的另建物件。繃帶與傷口模型由客戶端建立（`IsoGameCharacter.java:17421-17429`，只在非伺服器端），伺服器照清單另建，
  在伺服器上從來不在物品欄裡；客戶端自己建物品穿上的 MOD 也是這個形狀。死亡的角色不看。
- **自保**：每次檢查整段 `pcall`；出錯就停用本補丁並印一次。缺事件（伺服器 `OnTick`、單人 `OnTickEvenPaused`）、玩家清單（伺服器 `getOnlinePlayers`、單人 `getNumActivePlayers`／`getSpecificPlayer`）、`getTimestampMs` 或 `getCell` 印 `NOT installed`、不登記。
- **診斷**：每次介入印一行 `MDFX_StaleWornGuard removed stale worn item <物品>#<編號> (on the ground|in another container|re-created from a client list) from player="<帳號>" at <x>,<y>,<z> (#n)`，
  每次啟動最多 20 行（之後照樣處理、不再記）。要能從伺服器 console 統計發生次數，所以不是一個 session 一次。

選輪詢、不包 `ISDropWorldItemAction:complete`：正式服那次回報走哪一條路還沒確認，輪詢只看結果（穿著的物品在別處），兩條路與之後才發現的路都接得住。

### 與原版的差異

- 已經在地上或別的容器裡、卻還穿著的物品（以及多人伺服器上頂替它的另建物件），一到兩秒內從穿戴拿掉（原版留到重新登入或讀檔）。使用者 2026-11-10 同意（Bags session 交接：「修法放家族 Fixes，做成伺服器端自動修復」），2026-11-11 同意單人也修（「單人也修」）。
- 正常的穿、脫、換穿、扔掉、放置都不經過本補丁；繃帶與傷口模型不動。

### 已知限制

- 介入要等一到兩次檢查（1–2 秒）；這段時間背上還畫著。客戶端在收到伺服器的新清單之前又送出舊清單時，伺服器會再穿回一次，下一到兩次檢查再拿掉。
- 穿上不到一次檢查（1 秒）就放下、而且伺服器的穿戴已被換成另建的物件時，沒有先例可比，不處理，照原版留到重登。
- 可以同時穿多件的部位（原版只有繃帶、傷口、殭屍傷痕三種）上的殘留拿不掉，記一行後不處理。
- 別的 MOD 若讓穿著的物品留在主物品欄以外的容器超過兩次檢查，會被本補丁脫下。原版的穿上（物品要在物品欄裡才穿）、脫下、換穿、搬移、交易都在同一步處理完（讀碼：`ISWearClothing.lua:13`、`:118-121`、
  `ISUnequipAction.lua:112`、`ISClothingExtraAction.lua:121-138`、`ISTransferAction.lua:86-92`），沒有這種狀態；目前沒有已知這樣做的 MOD。
- 單人遊戲裡，別的 MOD 若在 `OnTickEvenPaused` 之前就把穿戴清單換成複製品，本補丁看不到真清單、不會介入（Mirage Wardrobe 是在 `OnTick` 換，實機有效）。
  某一幀繪製後外觀 MOD 沒把清單換回時（讀碼：睡覺畫面全黑時不觸發 `OnPostRender`，`IngameState.java:1195-1200`；Mirage 另在 `OnPreUIDraw`、`OnRenderTick` 與下一次 `OnTick` 開頭補換回），那一次檢查看到的是複製品：複製品不在容器也不在地上、沒有先例，不動，等之後看到真清單再處理。這個情況沒有實測。
- 不處理客戶端為什麼判斷錯；外觀 MOD 與原版游標都不改。

### 驗證

`lua scripts/test_stale_worn_guard.lua` — 70 項，全綠。假 Java 端照快照形狀模擬 WornItems、物品的容器與地上物件、`removeWornItem(item, forceDropTooHeavy)`（含把該部位第一件移出每幀更新清單、多件部位不移除）、
`IsoCell.addToProcessItems`、線上玩家清單、本機玩家（含空位）、兩個事件的先後、伺服器照清單另建同編號物件。涵蓋：在自己物品欄的穿著不動；在地上、在別的容器的連兩次才拿掉、參數是 false、拿掉後仍在每幀更新清單；
只成立一次或不連續的兩次不動；另建的物件有先例才拿掉（物件每次換新也一樣、被穿回會再拿一次、不登記每幀更新）、沒有先例或只有別人的先例不動；死亡角色不看；
兩次檢查至少隔 1000 ms、系統時鐘往回調時不卡住；同一位玩家多件與多位玩家；拿不到穿戴清單或物品欄的角色跳過；多件部位不呼叫、同部位的物品都留在每幀更新清單；呼叫後還在的只試一次（物件每次換新也一樣）、真物品仍登記回每幀更新清單；兩種都只記一行、不算已處理；離線後不留先例；
log 上限與上限提示；出錯後停用並只印一次；多人客戶端不安裝；缺 API 印 `NOT installed`；重複載入不疊。
單人：掛 `OnTickEvenPaused`、不掛 `OnTick`（伺服器相反）；缺事件或本機玩家 API 不安裝；看本機玩家、空位跳過、不讀線上玩家清單；拿掉後對那位玩家發 `OnClothingUpdated`，沒拿掉的與伺服器不發。

**mutation 驗證**（`--mutants`，49 個全部抓到）：判定的每個分支與先後、先例的記錄（只記在物品欄裡的）／分玩家／離線清除、連兩次與可疑清單的換新、檢查間隔與時鐘往回、死亡與兩份清單的檢查、由後往前掃、
`removeWornItem` 的呼叫與第二個參數、多件部位不呼叫、呼叫後的確認與不重試（照編號記）、登記回每幀更新清單（真物品要、另建的不要、要在確認之前）、計數、log 上限、多人客戶端的閘門、
單人的事件／玩家清單／空位／`OnClothingUpdated`（單人要發、伺服器不發、沒拿掉不發）、形狀檢查、`pcall` 與停用各一個以上。

`python scripts/check_vanilla_alignment.py` 登記 14 條（單人兩條：`IngameState` 裡 `OnTickEvenPaused` 在 `IsoWorld.update` 與 `OnTick` 之前、`getNumActivePlayers`／`getSpecificPlayer`）：成因三條（`ISDropWorldItemAction:complete` 放下到移出物品欄之間沒有脫下、`ISPlace3DItemCursor:create` 用 `isEquipped` 決定排不排脫下、
`SyncClothingPacket.process` 對背包每次都重穿、照清單穿回並另建沿用編號的物件）、依賴（`removeWornItem`→`setWornItem`→`syncClothing` 與移出每幀更新清單、`isDead`、伺服器 `syncClothing` 的 `sendToAll`、
`WornItems.getItemByIndex`／`size`／`contains`／`getLocation`／`getBodyLocationGroup` 與 `setItem` 對多件部位不移除、`BodyLocationGroup.isMultiItem`、`InventoryItem.getContainer`／`getWorldItem`／`getID`、`IsoCell.addToProcessItems`、`getOnlinePlayers`）、前提兩條（`ItemContainer.Remove` 把 `container` 設成 null、
`IsoGridSquare.AddWorldInventoryItem` 會 `setWorldItem`）；退場提示兩條：`ISDropWorldItemAction.lua` 出現 `removeWornItem`／`setWornItem`／`getWornItems():remove`，或 `ItemContainer.Remove` 裡出現 `removeWornItem`。

實機（`fixes-e2e` skill 的 `stale-worn`，2026-11-10～11，42.22.2，9950X3D；多人是專用伺服器＋一個客戶端；只用原版物品 `Base.Bag_ALICEpack`，外觀 MOD 是 Mirage Wardrobe 的乾淨外觀）。多人：

- 原版對照 `swe2e-ctl-mir-1110b`（沒有本檔，開 Mirage）：`RESULT PASS steps=4 checks=1`。放置游標在繪製畫面時放下穿著的背包，伺服器 `DROP.complete` 之後那件仍穿著、已不在物品欄；
  8 秒後兩端都還穿著（伺服器穿著的就是地上那一件），背上照畫，快捷列 3→4→4 格。
- 修正組開 Mirage `swe2e-fix-mir-1110e`：`RESULT PASS steps=13 checks=41`。同樣的放置，伺服器 1,498 ms 後不再穿著、客戶端 1,514 ms 後不再穿著，快捷列回到 3 格，
  伺服器記 `removed stale worn item Base.Bag_ALICEpack#… (on the ground) … (#1)`。次路徑（從排動作到做完後 1 秒，客戶端每個 tick 送一次穿戴清單）：伺服器脫下後被穿回、放下後穿戴被換成另建的物件，
  1,203 ms 後拿掉，記 `(re-created from a client list) … (#2)`。不該介入的案計數都不變：先脫下再放下的正常放置、扔掉、解除裝備、同一件穿上→脫下→再穿上、腰包前後換穿各一次、
  開著 Mirage 站 30 秒並走動（伺服器的穿戴清單前後相同）。繃帶：伺服器上出現兩件照清單另建的 `Base.Bandage_LeftHand`，7 秒後還在，`removed`、`stuck` 不變；
  同一案在伺服器逐件讀 `isMultiItem`：繃帶部位 `true`，皮帶、上衣、褲子等七個一般部位 `false`。整輪 `stuck=0`，兩端沒有 `NOT installed`、`disabled after`、`could not remove`，伺服器開好之後沒有例外。
- 修正組不載 Mirage，只跑次路徑 `swe2e-spam-nomir-1110e`：`RESULT PASS steps=5 checks=8`，1,795 ms 後拿掉，記 `(re-created from a client list)`。
  不載 Mirage 的其餘各案是用更早一版守衛跑的（`swe2e-fix-nomir-1110d`，38 個 CHECK 全過：繪製路徑的放置原版自己先脫下，守衛不介入；那一輪次路徑沒有被穿回，整輪判 INCONCLUSIVE）。
- 加了單人之後的多人回歸（現行守衛）`swe2e-fix-mir-1111e`：`RESULT PASS steps=13 checks=42`。主路徑伺服器 1,496 ms、客戶端 1,513 ms 後不再穿著，次路徑 2,002／2,012 ms，
  兩行診斷仍是 `(on the ground)` 與 `(re-created from a client list)`；多人客戶端沒有安裝本檔；`stuck=0`。
- 每次檢查的成本：伺服器連續呼叫 2 萬次，每次約 6–7 µs（1 位玩家、穿 7–9 件；每秒只跑一次）。多位玩家時的成本沒有量。
- 第一版守衛（只認「在別處」的真物品、可疑清單照物件記）在 `swe2e-spam-nomir-1110a` 沒接住次路徑：放下後伺服器的穿戴每個 tick 被換成新的另建物件，5 秒後兩端仍穿著、計數 0。
  現行寫法（照編號記、另建的物件看先例）是照這一輪改的。

單人（2026-11-11，同一份情境的單人分支）：

- 原版對照（本檔還只在伺服器安裝時）開 Mirage `swe2e-sp-mir-1111a`：放置游標讀到 `isEquipped=false`、只排放下，8 秒後仍穿著、背包在地上。
  不載 Mirage `swe2e-sp-render-1111a`：原版先脫下再放，不會發生。重新讀檔 `swe2e-sp-reload-1111b`：讀檔後不再穿著，背包在地上。
- 修正組開 Mirage `swe2e-spfix-mir-1111e`：`RESULT PASS steps=13 checks=47`。同樣的放置，放下完成後 1,408 ms 真正的穿戴清單不再有它，
  `console.txt` 記 `removed stale worn item Base.Bag_ALICEpack#… (on the ground) … (#1)`；之後不做任何操作，3 秒後快捷列 2→1 格；看了 10 秒沒有被外觀 MOD 放回，乾淨外觀仍開著，背上不再畫。
  放下後立刻暫停 3 秒的案：暫停中就拿掉（暫停後 1,269 ms），快捷列一樣 2→1。不該介入的案計數都不變：正常放置、扔掉、解除裝備、穿脫循環、腰包前後換穿、
  開著 Mirage 站 30 秒並走動、繃帶（包紮 7 秒後模型還在）。整輪 `removed=2 stuck=0`，沒有 Lua 錯誤與例外。
- 修正組不載 Mirage `swe2e-spfix-nomir-1111e`：`RESULT PASS steps=12 checks=35`。本檔有安裝；繪製路徑的放置原版自己先脫下，整輪 `removed=0`。
- 沒有補發 `OnClothingUpdated` 的那一版 `swe2e-spfix-old-1111a`：守衛 1,863 ms 拿掉、真正的穿戴清單也沒有它，但 3 秒後快捷列仍是 2 格（2→2）。補發是照這一輪加的。
- 每次檢查的成本：單人 2 萬次，每次約 1.7 µs（量的時候角色沒穿東西，偏低）。

### 可退場條件

官方讓遊戲在物品離開物品欄時一併清掉穿戴（例如 `ISDropWorldItemAction:complete` 自己脫下，單人與伺服器跑的是同一支；`check_vanilla_alignment.py` 有退場提示），
而且 `SyncClothingPacket.process` 不再替物品欄裡沒有的編號另建穿戴物件（第三條成因轉 CHANGED）。
第一條成因轉 CHANGED 或退場提示出現時，重跑 E2E `stale-worn` 的多人對照組（`--define mode=control`）、不載外觀 MOD 的 `spam` 案，與單人開 Mirage 的對照（拿掉本檔跑單人分支）：放下後都不再穿著，就移出本檔。
官方只改伺服器（Java）而沒改那支 Lua 時，單人仍要本檔：不能只看多人那兩輪。

---

## MDFX_SledgehammerGuard — 缺片的多格物件用大錘拆不掉；強化伺服器端驗證（大錘拆除）

| 項目 | 內容 |
|------|------|
| 檔案 | `server/Fixes/MDFX_SledgehammerGuard.lua` |
| 影響版本 | Build 42.22.2 實測（原版 `shared/TimedActions/ISDestroyStuffAction.lua`，反編譯快照 `42.22.2-20261109`）；殘骸拆不掉在 42.20 就有（見 `MDFX_MultiTileFurniture`） |
| 端 | 多人伺服器與單人（放 `server/`，沒有 `isServer()` 閘門；多人客戶端不安裝：大錘的 `complete` 在伺服器跑） |
| 類型 | 一、原版**靜默不移除**：只在原版完成之後補移除被敲的那一片。二、強化伺服器端驗證：原函式之前照原版 42.22 的伺服器規則檢查一次 |
| 狀態 | **現役**（`42.22.2-0.18.0` 起） |

### 症狀

- 佔好幾格的物件（2×2 的大石頭、雙格長椅這類）少了其中幾片時，用大錘敲剩下的任何一片：游標是綠的、動作跑完、大錘照樣耗損，物件留在原地，沒有任何訊息。單人與多人都一樣。
- 玩家回報（Discord，2026-11-10）：路上三顆巨石大錘拆不掉。伺服器存檔裡那三顆都只剩兩片（`boulders_16`～`31` 每四片一顆），是世界生成只生成了一半。

### 根因（行號為 42.22.2 原版 Lua 與反編譯快照）

- 大錘完成時（`ISDestroyStuffAction:complete`，`:111-350`；多人由伺服器執行）一般物件走 `:330` 的 `self.item:getSquare():transmitRemoveItemFromSquare(self.item)`。
- 一個參數的版本固定要求安全移除（`IsoGridSquare.java:5929-5931`）。物件是多格的（`IsoObjectUtils.isObjectMultiSquare`，圖塊有 SpriteGrid 就算）時，
  伺服器先找齊整組（`getAllMultiTileObjects` → `getSpriteGridMultiTileObjects`，`IsoObjectUtils.java:83-155`：整組每一格都要有那一格的圖塊），
  找不齊就回 -1、什麼都不移除（`IsoGridSquare.java:5938-5956`）。單人走 `RemoveTileObject(obj, true)` → `safelyRemoveTileObjectFromSquare`（`:32-41`），同樣回 -1。
- 警告只在除錯模式印（`Core.debug`）。`complete` 不看回傳值，照常擲大錘耐久、回 true。
- 兩個參數的版本傳 `false` 就只移除那一片（伺服器 `GameServer.RemoveItemFromMap`，會送客戶端；客戶端收到後也只移除那一個物件，`RemoveItemFromSquarePacket.processClient`）。

### 修法

包裝 `ISDestroyStuffAction.complete`。

**原函式之前（強化伺服器端驗證）**：照原版 42.22.2 `:116-130` 的寫法檢查兩道規則：要帶著能用的大錘而且離目標夠近（`hasSledgehammerInRange`，建造作弊免檢）；
伺服器選項 `SledgehammerOnlyInSafehouse` 開著時，沒有 `UseBuildCheat` 的角色要在允許自己用的安全屋裡。不過就回 false，不呼叫原函式。
原版在這兩道之前沒有任何作用，所以原函式是原版時結果相同。整支取代 `complete` 的 MOD 不一定有這兩道，細節屬攻擊面分析，只寫在本機知識庫。
目標是 nil 時不檢查，交給原函式（原版自己回 false）。檢查本身出錯（引擎 API 變了）時印一次、原樣重拋，不呼叫原函式：檢查照原版的寫法，原版的 `complete` 在同一處也會出錯。
拒絕時每次記一行（每個連線有上限）；目標已經不在格子上（例：別人先拆掉了）時原版同樣回 false，不是違規，不記。

**原函式之後（缺片的多格物件）**：

1. 回傳值不是 `true` 就照回，不做任何事（原版或別的 MOD 判定不能拆）。
2. 回 `true` 而目標已經不在格子上（`getObjectIndex() == -1`）＝原版移掉了，不做任何事。
3. 目標還在格子上、圖塊屬於多格圖塊組（`getSpriteGrid() ~= nil`）、物件沒有 component（`componentSize() == 0`），而且**確定缺片**：
   照引擎找整組的走法（`IsoObjectUtils.java:115-155`）看這一組佔的每一格，有一格載入了卻沒有那一格的圖塊才算。格子沒載入不算；
   圖塊組裡本來就沒有圖塊的位置也不算。
4. 用原版同一個呼叫再問引擎一次。引擎找得齊，就照原版整組移除；仍回 -1 才呼叫 `transmitRemoveItemFromSquare(item, false)` 只移除被敲的那一片，
   確認它真的不在格子上之後印一次診斷行。

第 3 步只用來決定「要不要碰」，移除還是交給引擎：`IsoObjectUtils` 沒有曝露給 Lua，問引擎找不找得齊只能用會移除的那個呼叫，所以先要有缺片的證據才問。
整組都在的不管：原函式回 true 不代表它要求過移除（別的 MOD 可能刻意留著這個物件）。
不是多格圖塊的不管：原版回 true 而物件還在，是別的原因（例：NicksSledgehammerFix 把轉角牆原地換成半面牆）。
有 component 的物件不管：整組找不齊時，原版的 `dumpContentsInSquare`（`:132`）只倒了被敲那一片自己的容器就返回（`IsoObjectUtils.java:161-180`），
component 的內容（製作中的材料、液體）沒倒，單片移除會連內容一起刪。
自己那一段出錯、或單片移除之後物件還在（Java 端拋例外時 Lua 只拿到 nil，所以移除後讀回 `getObjectIndex()`）：印一次、照回原版的結果。

安裝：放 `server/`，載入時包一次；`OnInitGlobalModData` 再檢查一次，比本檔晚載入的 `server/` 檔整支替換 `complete` 時重新包上。
不掛 `OnGameBoot`：單人進場時才載 `server/`（`GameLoadingState.java:149`），那時 `OnGameBoot` 早就觸發過了。

### 和原版的差異

- 原本敲不掉的缺片多格圖塊物件（巨石、一般家具），敲哪一片就少哪一片；同一組剩下的其他片不動，要一片一片敲。
- 完整的多格物件、單格物件、被拒絕的大錘動作都照原版：正常情況引擎只被呼叫一次，結果不變。原函式回 true 卻留著整組都在的多格物件時也不碰。
- 原函式是原版時，原函式之前的檢查和原版自己的檢查結果相同。載入整支取代 `complete` 的 MOD 時，不符合原版 42.22 伺服器規則的大錘拆除照原版拒絕（使用者 2026-11-11 同意）。
- 除錯模式下背包沒有大錘時，原版的檢查會建一把臨時大錘（`:17-19`）；本補丁先檢查一次，等於多建一把。只在除錯模式。
- 一組的其他格子有沒載入的、而載入的那幾格都不缺時不介入，照原版敲不掉（分不出是缺片還是沒載入；玩家身邊的格子都載入，沒有實測到這種情況）。
- 沒有改的原版行為：缺片的多格家具仍然撿不起來、拆解不了（原版 `ISMoveableSpriteProps:getSpriteGridInfo` 找不齊就不給撿，實機 `canPickUpMoveable=false`）；
  殭屍或玩家打壞這類殘骸時照樣不會消失（同一個安全移除，讀碼）；有 component 的多格設施缺片時照樣拆不掉；
  圖塊組有空位置的多格物件，引擎連完整的也算找不齊（讀碼，沒查原版有沒有這種圖塊組），完整的照原版不動。

### 和 `MDFX_MultiTileFurniture`（0.4.0 移出）的差別

那一項在沒有行為人的情況下判斷「這是殘骸」再刪（事後掃描、右鍵選單），在 Lua 重寫找齊整組的掃描時，review 抓到「格子沒載入被當成缺片」。
這一項只接在玩家揮完大錘、原版已判定可拆之後，移除的就是玩家敲的那一片；缺片的判斷把沒載入的格子當成「不知道」，最後找不找得齊仍由引擎回答。
它不清別的片、不加選單、不處理撿起。

### 和其他 MOD

- NicksSledgehammerFix（3780532913）在 `shared/` 整支取代 `complete`；本檔在 `server/`，載入較晚，包到的是它的版本（實機一起載入通過）。
- MinidoracatSafehouseFor42 在開服時把 `complete` 再包一層（`Permissions.lua` 的 `wrapCompleteCells`），沒有建造權限時回 false、不呼叫內層：本補丁不會跑。
  包裝先後反過來也擋得住：本補丁在外層時，規則過了才呼叫內層，安全屋在內層照樣回 false；殘片處理看的是整條鏈的回傳值（離線測試兩種先後都驗，實機驗安全屋在外層）。

### Log

- `[MinidoracatFixes] MDFX_SledgehammerGuard vanilla left <圖塊> at <x>,<y>,<z> standing after a sledgehammer hit (a multi-tile object with missing pieces); removed that piece. Further ones not logged this session. …`
  ——每次開機第一次介入時印一行（多人在 `server-console.txt`，單人在 `console.txt`）。
- `[MinidoracatFixes] MDFX_SledgehammerGuard refused a sledgehammer hit (<規則>) on <圖塊> at <x>,<y>,<z> by player="<名稱>" onlineID=<n> steamid~<SteamID> (#n). …`
  ——原函式之前的檢查拒絕時每次一行，每個連線每次開機最多 20 行，之後印一行 `reached LOG_LIMIT for player=… onlineID=… steamid~…; further refused sledgehammer hits from this connection are not logged this session.`。
  規則是 `no usable sledgehammer within reach` 或 `SledgehammerOnlyInSafehouse outside an allowed safehouse`。名稱由客戶端提供，認人看 SteamID。
  SteamID 是近似值（伺服器的 Lua 讀不到完整數字，捨入到 16 的倍數）；精確值看伺服器 `Logs/*_user.txt` 裡這位玩家 `fully connected` 那一行（開頭是 SteamID）。
- `[MinidoracatFixes] MDFX_SledgehammerGuard could not log a refused sledgehammer hit. …`——記拒絕行時出錯，一次；那一下照樣拒絕。
- `[MinidoracatFixes] MDFX_SledgehammerGuard could not check the server rules for a sledgehammer hit; NOT masking it (re-throwing): …`——檢查本身出錯，一次；原錯誤照樣拋出（原版在同一處也會出錯），這一下不拆。
- `[MinidoracatFixes] MDFX_SledgehammerGuard could not check for or remove a leftover piece; vanilla result kept: …`——自己那段出錯、或單片移除之後物件還在（`… is still on its square after the single-piece removal`），照原版結果，一次。
  沒有敲殘缺物件卻看到這一行＝檢查用到的引擎方法變了，本補丁已經不運作，回頭對版（`check_vanilla_alignment.py` 的依賴符號會先轉紅）。
- `[MinidoracatFixes] MDFX_SledgehammerGuard NOT installed: vanilla ISDestroyStuffAction shape changed; …`——包裝目標不在，回頭對版。

### 驗證

離線：`lua scripts/test_sledgehammer_guard.lua`（照載原版 `ISDestroyStuffAction.lua`，Java 端的格子、圖塊組與兩種移除用 Lua 模擬，101 項）；`--mutants` 42 個突變都要被抓到。

實機（42.22.2，9950X3D，`fixes-e2e` 的 `broken-multitile` 情境；伺服器在 Muldraugh 主街旁的空地照圖塊自己的 SpriteGrid 擺一顆完整的 2×2 巨石、
一顆只剩 `boulders_19`＋`boulders_16` 的巨石、一張只剩一片的雙格長椅，客戶端用原版大錘游標敲）：

- 原版對照（`6b1d79b`，沒有本檔）多人 `fxbm-ctl-mp-1111a`、單人 `fxbm-ctl-sp-1111a`：`RESULT PASS steps=9 checks=8`。完整巨石敲一下四片都消失；
  殘缺巨石的兩片與殘缺長椅，游標綠色、完成端 `complete` 回 true，伺服器與客戶端都還在。
- 修正組（收錄版本的守衛，暫時 commit `41e4f5b3`，和收錄版只差一行註解）多人 `fxbm-fix-mp-1111i`、單人 `fxbm-fix-sp-1111i`（都同時載 NicksSledgehammerFix）：`RESULT PASS steps=9 checks=10`。
  完整巨石照樣整組消失；殘缺巨石敲第一片後只剩另一片、再敲就沒了；殘缺長椅敲掉；兩端一致。診斷行恰一行，沒有 `NOT installed` 與失敗行，伺服器開服後沒有例外。
  只修殘片的 `e838cec` 版（`-1111f` 三輪）與更早的 review 版本（`-1111b`～`-1111e`）結果相同。
- 安全屋拒絕（`fxbm-fix-sh-mp-1111i`，同一個暫時 commit，另載 MinidoracatSafehouseFor42，把它的權限判斷換成對大錘一律拒絕）：`RESULT PASS steps=12 checks=12`。
  `complete` 回 false、殘缺巨石還在、本補丁沒印診斷行；還原後照常敲得掉。
- 伺服器規則（`fxbm-fix-srv-mp-1111i`，同一個暫時 commit；伺服器在大錘動作完成前把角色的大錘拿走，再敲完整巨石）：`RESULT PASS steps=11 checks=12`。
  `complete` 回 false、巨石兩端都還在、拒絕行恰一行（`no usable sledgehammer within reach`）；之後殘片與長椅照常敲掉。
- 沒有實機驗的：`SledgehammerOnlyInSafehouse`、規則檢查本身出錯、沒載入的格子、圖塊組的空位置、單片移除失敗，只有離線測試。

### 可退場條件

缺片的多格物件：官方讓缺片的多格物件拆得掉：`transmitRemoveItemFromSquare` 對找不齊的整組不再回 -1，或大錘改用別的移除方式。到時原版在第 2 步就移掉了，本補丁自動不介入。
`check_vanilla_alignment.py` 的爆點轉 CHANGED 時，重跑 E2E `broken-multitile` 的對照組：`hit-broken-*` 的殘片被原版敲掉了，就移出這一段。
伺服器規則：常見的整支取代 `complete` 的 MOD 都帶上原版 42.22 的那兩道規則時可以拿掉；原函式是原版時這一段和原版同結果，留著無害。
原版改了那兩道規則（指紋的依賴符號轉紅）時，照新的寫法改，或拿掉。

---

## MDFX_BasementVoidGuard — 樓梯旁的牆被敲掉後，從旁邊走進樓梯口時掉到地下室的牆外（走不回來、重登也一樣）

| 項目 | 內容 |
|------|------|
| 檔案 | `client/Fixes/MDFX_BasementVoidGuard.lua` |
| 影響版本 | Build 42.22.2 實測（反編譯快照 `42.22.2-20261109`） |
| 端 | 玩家的遊戲（多人客戶端與單人；專用伺服器不執行 `client/`） |
| 類型 | 原版**讓角色掉到地下室牆外**（所在格與實際位置不同步）；事後放回，不改地圖、不擋大錘 |
| 狀態 | **現役**（`42.22.2-0.19.0` 起） |

### 症狀

- 有些房子通往地下室的樓梯頂，正好在上樓樓梯頂格的正下方。樓梯旁邊的牆被大錘敲掉之後，從隔壁房間直接走進樓梯頂格：角色往下掉到地下一層、摔傷（實測每次 3–9 點），
  站在地下室的牆外。那裡的格子存在、沒有地板，牆從外面進不去，周圍沒有格子的地方走不過去；伺服器照存這個位置，重新登入還在原地。
- 單人與多人都會發生。每幀位移超過 0.01 格才會：30 FPS 走路就會，60 FPS 偶爾，244 FPS 走路不會、衝刺會。
- 玩家回報與現場分析在 `MinidoracatServerAnalyze` 的事件報告（2026-11-11）。

### 根因（行號為 42.22.2 反編譯快照）

- **地圖**：原版地圖在這類房子畫的地下室區指定了樓梯位置（例：羅斯伍德 8175,11673 那棟 `StairDirection=S, StairX=1, StairY=3`，`media/maps/Muldraugh, KY/objects.lua`），
  不管世界種子選到哪個地下室，地下室樓梯頂都對到同一格（`Basements.java:154-229`、`:314-413`），正好在上樓樓梯頂格的正下方。原版靠樓梯兩側的牆擋住側面。
- **引擎**（`IsoMovingObject.postupdate`）：牆不在時，從旁邊的房間走進樓梯頂格的那一幀：
  1. `DoCollide()` 一開頭就把「所在格」換成下一步位置那一格（`IsoMovingObject.java:1504`），也就是樓梯頂格；沒有牆，不算碰撞，所在格就留在那一格。
  2. 所在格有樓梯時 `getGlobalMovementMod()` 回 0.75（`:801`），每幀位移超過 0.01 格就乘上它（`:998-1002`）。原本剛好跨過格線的一步變短，人實際還留在原來那一格。
  3. `doStairs()`（`:1006`）照「所在格」算高度：所在格是樓梯頂、高度小數不到 0.1、正下方也是樓梯頂時，改用下面那道樓梯（`:277-291`），高度變成略低於 0。
  4. `findCurrentGridSquare()`（`:1008`）用實際位置與新高度重找所在格：原來那一格的正下方、地下一層，也就是地下室牆外的空格（`IsoChunk.java:2386-2415` 只在有物件的格子周圍補空格）。
- 實測每幀軌跡（`fxbv-sp30-1111f` 的 `O-gap-north`，30 FPS）：`y=11675.936 z=0`（廚房）→ 下一幀 `y=11675.986 z=-0.053`、所在格 `8176,11675,-1`（沒有地板）。
  一步 0.0667 格 × 0.75 ＝ 0.050，和第 2 步相符；之後 `PlayerFallingState`，約 0.6 秒後落到 `z=-1`。
- 牆還在時不會發生（`DoCollide` 判成碰撞、所在格換回原來那一格）；從樓梯原本的入口上下樓也不會（實機 `I-storage`／`O-storage`）。

### 修法

- **掛點**：`OnPlayerUpdate`（`IsoPlayer.java:2291`），只看 `isLocalPlayer()` 的角色；坐在車上、開著穿牆（`isNoClip()`）、所在格沒載入時不動。
- **判定**：所在格 `TreatAsSolidFloor()`（地板、樓梯、斜面）就記下位置（每位玩家一筆）。所在格在地面以下（`z < 0`），而且從正下方一路到這個 chunk 的最低層都沒有 `TreatAsSolidFloor()` 的格子，就是牆外。
  地面以上的半空中、地下樓梯井上方（正下方有樓梯或地板）照原版，也不記位置。
- **放回**：記下的位置和現在水平相差 `NEAR`（2）格以內，放回那個位置；否則（一進遊戲就在牆外、被傳送進來）放到正上方最近的可站格的正中央，再不行找地面層 `RADIUS`（2）格內、由近到遠。
  可站＝`TreatAsSolidFloor()` 而且不是實心物件或家具（`isSolid()`／`isSolidTrans()`）。都找不到就不動，印一次。
- **放回的做法**：設位置與上一幀位置（座標保留小數；原版 `teleportTo` 會截成整數）、清掉落（`setFallTime(0)`、`setLastFallSpeed(0)`、`setbFalling(false)`）、
  `setCurrentSquareFromPosition()` 把所在格換成新位置那一格。最後一步不能省：`OnPlayerUpdate` 之後同一幀才跑掉落計算（`IsoGameCharacter.updateFalling`，`:9573-9616`），
  它照所在格算離地高度，所在格還是牆外那一格就繼續往下掉（第一版沒有這一步，實機 `fxbv-fix-sp30-1111k` 一條路線放回 241 次、角色動彈不得）。
- **自保**：整段 `pcall`；出錯就停用本補丁並印一次。缺 `OnPlayerUpdate`／`getCell`／`getTimestampMs` 印 `NOT installed`、不登記。
- **診斷**：每次介入印一行 `MDFX_BasementVoidGuard player <編號> was below ground at <x>,<y>,<z> (square <格>) with no floor here or below; put back to …, the last position on a floor (#n)`
  （已經在牆外的寫 `moved to …, the nearest floor above`）。連續 `EVENT_GAP_MS`（5 秒）內的放回算同一次；每次啟動最多 20 行（之後照樣放回、不再記）。

### 與原版的差異

- 掉到地下室牆外的角色被放回（原版留在牆外）；一進遊戲就已經在牆外的角色被送到正上方最近的地板。
- 一直朝那個缺口走時，角色可能停在缺口邊緣進不去：同一個位置、同一步每次都被縮短，所以每次都被放回（實機 `O-gap-north` 按住 2 秒放回 25 次；原版是掉下去）。
  放回前那一幀角色低約 0.05 格。從樓梯原本的入口上下樓不受影響。
- 使用者 2026-11-11 同意（設計稿三個決定：放回上一個站得住的位置、已困住的也送上來、診斷每次一行上限 20）。

### 已知限制

- 不補牆、不擋大錘、不改地圖、不動伺服器；只在掉到牆外之後放回。沒裝本 MOD 的客戶端照原版。
- 坐在車上、開著穿牆的玩家不處理；所在格還沒載入時不處理。
- 正上方與地面層 2 格內都沒有可站的格子時不動（印一次）。

### 驗證

`lua scripts/test_basement_void_guard.lua` — 63 項，全綠。假 Java 端照快照形狀模擬格子（地板／實心／家具／chunk 最低層）、角色的位置、上一幀位置、所在格與掉落欄位。
涵蓋：重現量到的那一幀放回上一幀位置、掉落取消、所在格換回；從地下室樓梯走到牆外放回樓梯上（含高度）；按住不放 300 幀只算一次；5 秒的界線；
一進遊戲就在牆外送到正上方、地下二層先到上一層；正上方沒有地板／實心／家具／沒載入時找鄰格、取近的、3 格外不動並只印一次；記下的位置太遠（x、y 各自的界線）；
不該動的（地面以上的半空中且不記位置、樓梯井上方、隔兩層才有地板、下面沒有格子、讀不到 chunk、所在格沒載入、車上、穿牆、別人的角色）；分割畫面各記各的；
log 上限與上限提示；每幀成本（站在地板上每幀只問一次 `TreatAsSolidFloor`）；出錯後停用並只印一次；缺 API 印 `NOT installed`；重複載入不疊。

**mutation 驗證**（`--mutants`，60 個全部抓到）：每個判定條件與界線、每個常數、放回的每一個 setter、換所在格與它的先後、落點的每個條件、事件合併、log 上限、`pcall` 與停用各一個以上。

`python scripts/check_vanilla_alignment.py` 登記 30 條（Java 指紋）：成因三條（`DoCollide` 先換所在格；`postupdate` 的「乘 `getGlobalMovementMod`→`doStairs`→`findCurrentGridSquare`」順序；
`doStairs` 改用正下方樓梯頂的分支）、係數一條（所在格有樓梯回 0.75）、前提（`updateFalling` 照所在格算；`OnPlayerUpdate` 在上層 `update` 之前；`setX`／`setY` 同時設下一步位置）與依賴的方法。

實機（`fixes-e2e` skill 的 `basement-void`，2026-11-11，42.22.2，9950X3D；羅斯伍德 8176,11676 那棟，牆用原版大錘敲掉，走路用引擎的自動行走；修正組的 MOD 是未提交的工作樹、暫時 commit `8db0bbf5`）：

- 原版重現（MOD 只有探針與空殼）：30 FPS 走路 23 條路線，單人四輪各 8 條停在牆外（`fxbv-sp30-1111f`、`-sp30run-1111f`、`-sp30both-1111g`、`-sp30shot-1111h`），多人 5 條（`fxbv-mp30-1111g`）；
  牆還在 23 條 0 次；60 FPS 1 次（`fxbv-sp60-1111j`）；244 FPS 走路 104 條 0 次、衝刺 23 條 1 次（`fxbv-spsprint-1111f`）。
- 對照組 `fxbv-ctl-sp30-1111m`（單人 30 FPS，加了判定的情境）：`RESULT PASS steps=56 checks=3`。牆還在 23 條 0 次、牆拆掉 23 條 8 次，生命 100 → 70.5；直接放進牆外空格的那一步停在 `z=-1`。
- 修正組單人 `fxbv-fix-sp30-1111l`（30 FPS）：`RESULT PASS steps=56 checks=6`。47 條路線沒有一條停在牆外、生命 100 → 100；牆還在的 23 條（含儲藏室下樓到地下室再走回來）守衛 0 次介入；
  牆拆掉後放回 178 次、算 8 次事件；直接放進牆外空格 (8180,11675,-1) 的角色被送到 (8180.5,11675.5,0)，恰好介入一次。
- 修正組多人 `fxbv-fix-mp30-1111m`（管理員帳號，30 FPS）：`RESULT PASS steps=33 checks=5`，24 條路線 0 次停在牆外、放回 130 次、生命不變。
- 修正組多人、一般帳號 `fxbv-fix-mpuser-1111n`（伺服器 `SpawnPoint` 設在屋旁、`AntiCheatSpeed=2` 照範本，30 FPS）：`RESULT PASS steps=33 checks=5`，放回 130 次，沒有被踢，`server-console.txt` 沒有 anticheat 訊息。
  讀碼：AntiCheatSpeed 每 1 秒取樣一次水平位移、上限 20 格／秒（`NetworkCharacterAI.java:367-405`），本補丁一次最多移 2 格多。
- 已經困在牆外才裝上本補丁 `fxbv-stuck-mp-1111p`（多人、一般帳號，兩個場次）：場次 1 的 MOD 樹拿掉本檔，角色放進牆外空格後停在 (8180.5,11675.5,-1)，關掉客戶端與伺服器；
  把本檔放回、重開，場次 2 `RESULT PASS steps=1 checks=2`：伺服器記的登入位置是 (8180,11675,-1)，進遊戲第 1 幀就印 `moved to 8180.50,11675.50,0.00, the nearest floor above (#1)`，角色在正上方的客廳地板上，恰好介入一次。
- 牆拆掉之後連上樓樓梯也敲掉（大錘一下拆掉整道三格；單人 30 FPS）：對照組 `fxbv-ctl-stairs-1111q` 23 條路線 0 次停在牆外、生命不變（樓梯頂格沒有樓梯，上面第 2、3 步不成立，人直接落到地下室樓梯上）；
  修正組 `fxbv-fix-stairs-1111q` `RESULT PASS steps=36 checks=4`，23 條路線守衛 0 次介入。
- 第一版（暫時 commit `1a0e933d`，放回時沒有換所在格）`fxbv-fix-sp30-1111k`：`O-gap-north` 一條路線放回 241 次、角色停在 `z=-0.003` 動彈不得、結束時仍算在牆外；加上 `setCurrentSquareFromPosition()` 後才是上面的結果。
- 前後對照圖（同一條路線 `O-gap-north` 結束時；左原版在牆外、右修正後在地下室樓梯上）：`temp/fixes-basement-void-1111/bv-fix-pair.jpg`（本機，不進 git）。

### 可退場條件

官方讓這種位置進不去（例如 `doStairs` 不在位移被縮短的那一幀照下一步那一格算高度），或自己把掉到牆外的角色放回。
`check_vanilla_alignment.py` 的三條成因或係數任一轉 CHANGED 時，重跑 E2E `basement-void` 的對照組（`--define mode=control`、30 FPS、`--src` 指向沒有本檔的 MOD 樹）：
牆拆掉的 23 條路線 `BV SUMMARY … open=0`，就移出本檔。

---

## MDFX_ConsumedContainerGuard — 配方把裝著東西的袋子當材料用掉時，袋裡的東西一起消失

| 項目 | 內容 |
|------|------|
| 檔案 | `server/Fixes/MDFX_ConsumedContainerGuard.lua` |
| 影響版本 | Build 42.22.2 實測（原版腳本、原版 Lua 與反編譯快照 `42.22.2-20261109`）；官方論壇 2024-12-28 有 42.0.2 單人、不載 MOD 的回報（集雨桶吃掉垃圾袋裡的東西） |
| 端 | 多人伺服器與單人（放 `server/`，沒有 `isServer()` 閘門；多人客戶端不安裝：兩個完成端的消耗都在伺服器跑） |
| 類型 | 原版**靜默弄丟物品**：只在原版完成之後，把被用掉的容器物品裡剩下的東西放回它原本所在的地方 |
| 狀態 | **現役**（`42.22.2-0.20.0` 起） |

### 症狀

- 有些配方會把還裝著東西的袋子當材料用掉，袋裡的東西跟著消失，沒有任何訊息。單人與多人都一樣。
- 蓋集雨桶（垃圾袋 4）：裝著東西的垃圾袋被選成材料，袋裡不是材料的東西、多帶的木板與釘子都消失。拆解麻袋：麻袋裡的東西、放在麻袋裡的剪刀（配方的工具）都消失。
- 多人伺服器的副作用：袋子在角色身上、袋裡的東西也是這次配方的材料或工具時，`server-console.txt` 印 `Unable to resolve container location`
  （`Packet "ItemStats" send failed`），每個連線一份。伺服器 2026-11-12 一次建造印了 180 份；2026-09 到 2026-10 另有 6 輪是手工製作印的。
  這串訊息不是每次都有：同一種擺法兩輪是 1 份與 3 份，袋子在地上或材料另外帶的擺法是 0 份，東西照樣消失。

### 根因（行號為 42.22.2 原版腳本、原版 Lua 與反編譯快照）

- 配方的輸入行要有 `IsEmpty` 旗標，引擎才擋掉裝著東西的容器物品（`InputScript.doesItemPassIsOrNotEmptyAndFullTests`，`InputScript.java:1040` 一帶）。
- 原版腳本裡會用掉容器物品、又沒有 `IsEmpty` 的輸入行共 8 行：`RainCollector` 與 `RainCollectorRound` 的 `item 4 tags[base:garbagebag]`
  （`generated/entities/outdoors/entity_raincollector.txt:43`、`:98`；別的垃圾袋配方 11 行都有 `IsEmpty`）、`ScrapSack`（`recipes_tailoring.txt:815`）、`ScrapSackLarge`、
  `CutHeadSack`、`MakeHollowBook`、`Scrap_Smaller_Gold_Object`、`Scrap_Smaller_Silver_Object`（鑰匙圈）。
- 完成端用掉材料時（`CraftRecipeData.processDestroyAndUsedItems`，`CraftRecipeData.java:517-573`）對容器物品呼叫 `ItemUser.RemoveItem`（`ItemUser.java:123-180`）：
  只把那件容器物品從它所在的容器或地上移除，它裡面的東西沒有處理，留在已經不在任何地方的袋子裡。
- 例外是同一個函式稍後的 `GameServer.sendItemStats`：對每件用掉或留著的物品送同步，物品所在的袋子已被移除時 `ContainerID.set` 解析不到位置；
  `INetworkPacket.sendToAll` 對每個連線各接一次、各印一份。印幾份跟物品的處理順序有關。

### 修法

包裝兩個完成端：建造的 `ISBuildIsoEntity.create`（`server/BuildingObjects/ISBuildIsoEntity.lua:510-602`，`:554` 選定材料、`:580` 用掉）
與手工製作的 `ISHandcraftAction.performRecipe`（`shared/Entity/TimedActions/ISHandcraftAction.lua:225-254`，`:227`、`:238`）。

1. 原函式之前：記下每一件裝著東西的容器物品，以及它在哪個容器、或在地上的哪一格哪個位置（「在不在地上」的判準同 `ItemUser.RemoveItem`：世界物件還在格子上才算）。
   看兩個地方：這次配方的容器清單（`logic:getContainers()`；配方只會用到這些容器的直接物品，`CraftRecipeManager.java:274-282`），
   與角色所在格加周圍一圈的地上物品。後者是因為原版在完成時會重新收集這個範圍的地上物品當材料（`BaseCraftingLogic.updateFloorContainer`，`:792-816`，
   由 `HandcraftLogic.performCurrentRecipe` `:139-146` 與 `BuildLogic.performCurrentRecipe` `:238-245` 呼叫），動作開始後才放到地上的袋子不在原本的清單裡。
   清單裡已經不在任何地方的過期項目（動作開始後被別的途徑移除）不記：原版重建清單時不會用到它，不是這次用掉的。
2. 原函式照原樣呼叫，回傳值照原樣回傳。原函式的錯原樣外洩，那時不做第 3 步。
3. 原函式之後：記下的容器物品現在既不在任何容器、也不在地上（＝被用掉了），就把它裡面剩下的東西放回它原本所在的地方。
   原本在地上：先從袋子拿掉，再用 `AddWorldInventoryItem` 放回同一格同一個位置（伺服器會送給客戶端）；放不成（Java 端出錯、Lua 拿到 nil）而且物品還沒落地就塞回袋裡，算沒搬走；已經落地的留在地上。
   原本在容器裡：`AddItem` 放回那個容器（它會先把物品從舊容器拿掉，不會多出一份），再 `sendAddItemToContainer`；放回的地方在車上（車的容器，或車上背包的內部：看最外層容器 `getOutermostContainer`）就照原版 `ItemUser.java:116-118` 的做法重算那個車容器的內容量與車重
   （原版移除車上背包裡的物品時不重算；這裡要算，因為客戶端收到重送的封包時會重算，伺服器不算兩端就不一樣）。
   原本所在的容器自己也被這次配方用掉（袋中袋）時，改放角色的主背包。
   原本所在的容器送不到客戶端時（車上或箱子裡的背包的內部：`GameServer.sendAddItemToContainer` 與 `sendRemoveItemFromContainer` 都只送玩家身上的容器、
   有世界物件的容器、地上袋子的內部，`GameServer.java:2427-2443`、`:2487-2503`；這種位置連原版移除袋子的封包也沒送到，客戶端還看得到已經用掉的袋子）：
   照樣放回原處，再往外找到第一件「所在容器送得到」的容器物品（例：後車廂裡的那個背包），對它所在的容器先送移除、再送加入。
   客戶端收到加入封包時是照伺服器現在的內容建一件新的（`AddInventoryItemToContainerPacket.java:77-112`；容器裡還有同編號的就不加，所以要先移除），兩端就一致了。
4. 放完讀回袋子裡還剩幾件（Java 端拋例外時 Lua 收不到錯誤）；還有剩就印一次，診斷行的件數只算搬走的。

不改配方腳本、不替輸入行補 `IsEmpty`：`InputScript` 的旗標是 private、沒有可從 Lua 呼叫的寫入方法；覆寫配方腳本要整份複製，會蓋掉官方之後對那些配方的修改，也管不到 MOD 的配方。
袋子照樣被用掉、配方照樣完成；被配方用掉的材料不會回來（它們已經被原版從袋子移除，不在袋裡）。
自己的部分各自 `pcall`（記錄一段、每個袋子的放回各一段）：出錯印一次，原版的結果照舊，其他袋子照樣處理。

安裝：放 `server/`，載入時包一次；`OnInitGlobalModData` 再檢查一次，之後被別的檔整支替換時重新包上（單人進場時才載 `server/`，`OnGameBoot` 早就觸發過）。
兩個完成端各自檢查形狀，一個變了不影響另一個。

### 和原版的差異（使用者 2026-11-12 同意）

- 配方用掉裝著東西的容器物品時，裡面剩下的東西留下來，放在那件容器物品原本所在的地方（原版：全部消失）。
- 和配方是哪一個無關，MOD 加的配方也一樣。配方若是故意連內容一起銷毀，內容也會被留下來（沒看過這種原版配方）。
- 放回主背包不檢查負重，背包可能因此超重。原版把製作產物交給角色時會檢查，放不下就丟在腳邊（`Actions.addOrDropItem`，`shared/ActionManager.lua:4-23`）；這裡照裁定放回原處、不檢查。
- 袋中袋（袋子裝在另一個也被這次配方用掉的袋子裡）時，內層的東西進角色主背包；外層原本在地上的話，外層自己的東西留在那一格。
- 車上背包裡的袋子被用掉時，多人遊戲的客戶端會看到那個背包被移除又放回（內容照伺服器的現況）。原版在這個位置不送任何封包，客戶端會一直看到已經用掉的袋子，直到重新載入那一區。
- 原版右鍵選單的製作（`OnNewCraft`）對不能在地上做的配方會先把材料搬進主背包（`ISInventoryPaneContextMenu.lua:3424-3430`），那條路徑上袋子一定在主背包被用掉、東西留在主背包。
  袋子在原位（手上、背包、地上、車上）被用掉的是建造與製作視窗。
- 沒有改的：多人伺服器那串 `Unable to resolve container location` 照樣會印（使用者 2026-11-12 裁定先留著；它不影響結果）。
  機台自動製作（`CraftLogic`）由 Java 直接完成，不在範圍。空的容器物品、沒被用掉的容器物品完全照原版。

### 已知限制

- **車上背包裡的袋子：整件重送會換掉客戶端的那個背包物件**。實機（`fxbag-probe-vehicle-1112r`，探針版情境）：做動作的玩家事先選著書包那一頁，完成後不動，
  拾取頁自己重建了分頁：書包那一頁指到新的背包、看得到放回去的東西，選中的頁跳回後車廂。
  沒有實機驗的（讀程式推測）：旁邊另一位玩家正開著那個背包時，他的那一頁要等他走一步、轉身或點任一個容器鈕才更新（更新後選中的頁同樣跳回第一個容器；
  在那之前他看到的和沒有本檔時一樣，客戶端收到這兩種封包不會觸發拾取頁重建）；排了隊還沒開始、對象是那個背包裡物品的動作
  （製作視窗一次排好幾個、搬移）拿的是舊背包，可能送不出去、要重排。伺服器上的資料不受影響。驗法：兩個客戶端的 E2E。
  原版在這個位置對其他玩家本來就不同步（增減的封包都不送）。
- **袋中袋的外層在送不到客戶端的位置、而且外層自己沒有剩東西**：內層的東西進主背包，外層不重送，客戶端還看得到已經用掉的外層（和原版一樣）。
  原版拾取頁只把車上部件裡第一層的袋子列成容器（`ISInventoryPage.lua:1764-1777`），這個擺法只有會列巢狀容器的 MOD 介面碰得到。
- 機台自動製作不在範圍；已經消失的東西補不回來。

### Log

- `[MinidoracatFixes] MDFX_ConsumedContainerGuard recipe="<配方>" used up <容器物品類型> that still held <n> item(s); put them back in the container it was in. Logged once per recipe. …`
  ——每種配方第一次介入印一行（原本在地上的寫 `on its square`，袋中袋改放主背包的寫 `in the player's main inventory`），每次開機最多 20 種配方，之後印一行
  `kept the contents for more than 20 recipes; not logging further recipes this session.`。多人在 `server-console.txt`，單人在 `console.txt`。
- `[MinidoracatFixes] MDFX_ConsumedContainerGuard could not keep what a used-up container held; vanilla result kept: …`——自己那段出錯，
  或放回之後袋子裡還有剩（`<n> item(s) are still inside a used-up <類型>`），一次。沒有人用掉袋子卻看到這一行＝用到的引擎方法變了，回頭對版。
- `[MinidoracatFixes] MDFX_ConsumedContainerGuard NOT installed: vanilla ISBuildIsoEntity shape changed; …`（或 `ISHandcraftAction`、`engine API shape changed`）——包裝目標或引擎函式不在，回頭對版。

### 驗證

離線：`lua scripts/test_consumed_container_guard.lua`（容器、容器物品、地上的世界物件、格子、車的部件與 `ItemUser.RemoveItem` 用 Lua 模擬，74 項）；`--mutants` 74 個突變都要被抓到。

實機（42.22.2，9950X3D，`fixes-e2e` 的 `bag-material` 情境；伺服器發材料並照擺法放好，客戶端走原版建造游標或原版手工製作動作；
袋裡另放一把不是材料的螺絲起子）。修正組是定版前的暫時 commit `e5e85dd3`（守衛檔與定版相同），`mode=fix`：

| 擺法 | 原版對照（沒有本檔，多人） | 修正組（多人） |
|------|------|------|
| 圓形集雨桶，袋子是空的 | `fxbag-control-1112a`：螺絲起子還在，例外 0 | `fxbag-fix-control-1112s`：同原版，沒有診斷行 |
| 圓形集雨桶，袋子拿在副手、材料在袋裡 | `fxbag-hand-1112a`、`-1112b`：螺絲起子消失，例外 1 與 3 | `fxbag-fix-hand-1112s`：螺絲起子在主背包（例外 15，原版副作用） |
| 圓形集雨桶，袋子在腳邊地上、材料在袋裡 | `fxbag-floor-1112a`：螺絲起子消失，例外 0 | `fxbag-fix-floor-1112s`：螺絲起子在同一格地上，恰一把 |
| 圓形集雨桶，袋子在背包、材料另外帶 | `fxbag-inv-1112a`：螺絲起子與袋裡的木板 6、釘子 5 消失，例外 0 | `fxbag-fix-inv-1112s`：12 件都在主背包 |
| 拆解麻袋，麻袋拿在副手、剪刀也在袋裡 | `fxbag-craft-1112c`：螺絲起子與剪刀消失，例外 0 | `fxbag-fix-craft-1112s`：兩件都在主背包（例外 3，原版副作用） |
| 拆解麻袋，麻袋在背包、剪刀另外帶 | `fxbag-craftinv-1112c`：螺絲起子消失，例外 0 | `fxbag-fix-craftinv-1112s`：螺絲起子在主背包 |
| 拆解麻袋，麻袋在車子後車廂的書包裡 | `fxbag-ctl-vehicle-1112j`：伺服器上螺絲起子消失；客戶端的書包裡還看得到已經用掉的麻袋 | `fxbag-fix-vehicle-1112s`：螺絲起子回到那個書包，客戶端也看得到；麻袋兩端都不見；主背包沒有多一把；客戶端沒有 `Dupe item ID` |

修正組七輪都是 `RESULT PASS`（建造案各 6 個 CHECK、手工案 7 個、車子案 5 個）：袋子本身兩端都用掉、留下的東西伺服器與客戶端位置和數量一致、
用掉的材料沒有多出來、站位周圍地上沒有多出或少掉東西；每輪診斷行恰一行（空袋那輪沒有），沒有 `NOT installed` 與失敗行。對照組的堆疊只有原版的 Lua 幀。
例外的堆疊都在原函式裡的 `CraftRecipeData.processDestroyAndUsedItems`（守衛的放回在它回來之後才跑）；份數每輪不同，見下面「例外份數」。

單人（`--sp`，同一個暫時 commit）：`fxbag-spfix-hand-1112s`、`-floor-`、`-craft-` 三輪 `RESULT PASS`（6、6、7 個 CHECK），診斷行印在玩家的 `console.txt`。

例外份數（袋子拿在副手、材料在袋裡那個擺法，每輪 `server-console.txt` 的 `Unable to resolve container location` 行數）：沒有本檔 8 輪是 1、3、2、0、5、7、15、7
（`fxbag-hand-1112a`、`-1112b`、`fxbag-ctl-hand-1112m1`–`m3`、`-1112q1`–`q3`）；有本檔 7 輪是 14、9、7、5、0、14、15（`fxbag-fix-hand-1112d`、`-1112g`、`-1112k`、`-1112m1`–`m3`、`-1112s`）；
本檔只留包裝層、不記錄也不放回的變體 3 輪是 6、6、9（`fxbag-pass-hand-1112n1`–`n3`）；本檔照樣載入但什麼都不包的變體 3 輪是 14、6、9（`fxbag-load-hand-1112q1`–`q3`）。
四組範圍重疊，沒有本檔也跑出 15 份：份數隨輪次變，和守衛做的事無關，不能拿來估受害次數。

沒有實機驗的：方形集雨桶與其餘 5 個配方、袋子在箱子裡或車子座位上、袋中袋、動作途中才放到地上的袋子、放回失敗、建造用掉車上背包裡的袋子，只有離線測試或讀腳本。

### 可退場條件

官方讓配方用掉容器物品時處理它的內容（清空、掉出來，或漏掉的輸入行都補上 `IsEmpty`、引擎一律擋）。到時第 3 步看到的都是空袋，本補丁自動不介入（診斷行不再出現）。
`check_vanilla_alignment.py` 的兩條成因（集雨桶、拆解麻袋的輸入行）轉 CHANGED 或 `ItemUser.RemoveItem` 的退場提示出現時，
用沒有本檔的 MOD 樹重跑 E2E `bag-material` 的六案（`--define mode=control`）：袋裡的螺絲起子都還在，就移出本檔。只補了部分配方時留著：MOD 的配方仍可能漏。

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
