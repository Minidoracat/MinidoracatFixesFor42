# 修復清單

本 MOD 每加一項修復，就在這裡登記一筆：症狀、根因、修法、驗證方式、可退場條件。
「可退場」= 官方哪天修好了，就從 MOD 移除該檔並在此標記為已退場。

---

## MDFX_MultiTileFurniture — 多格家具缺角殘骸鎖死

| 項目 | 內容 |
|------|------|
| 檔案 | `shared/Fixes/MDFX_SpriteGrid.lua`、`server/Fixes/MDFX_MultiTileFurniture.lua`、`client/Fixes/MDFX_MultiTileFurnitureMenu.lua` |
| 影響版本 | 42.20.0（殘骸鎖死自 42.10 引入） |
| 端 | server（斷根＋執行）＋ client（右鍵選項） |
| 狀態 | 生效中 |

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

### 修法：延後確認，不當場展開

`OnObjectAboutToBeRemoved` 對**所有**移除都會觸發，包含原版蓄意的單格手術——
`MOFeedingTrough.lua:21` 在地圖載入時單格移除再替換成 `IsoFeedingTrough`，而
**餵食槽本身就用 sprite grid**（`IsoFeedingTrough.java:79-87`）。當場展開刪 sibling
會在 chunk 載入時把餵食槽的另一半刪掉，直接弄壞餵食槽與兔籠。

所以 event 只記下群組錨點，延後 60 tick（約一秒）再回頭掃一次，**仍然殘缺才清**：

| 情境 | 延後掃描時 | 結果 |
|------|-----------|------|
| 原版移除→立刻替換（餵食槽／兔籠） | 同 sprite 已補回，群組完整 | 不動 |
| 大槌／搬運撿取／殭屍打壞 | 缺角補不回來 | 清掉剩餘成員 |

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
| 格子沒載入 | `unknown = true` | **絕不清**，稍後重試（最多 5 輪） |
| 稀疏 grid（該格無預期 sprite） | `unknown = true` | **絕不清**（原版是讓它永遠撿不起來） |

等不到就放棄——殘骸留著沒關係，玩家還能右鍵手動清；誤刪完好家具才是不可逆的。

### 容器內容物

原版 `RemoveTileObject` 完全不管容器，移除就等於把裡面的東西一起毀掉。玩家自己動手拆
是他的決定，但本 MOD 的**自動**清掃不能替玩家做這個決定。因此群組內只要還有內容，
自動清掃與手動清除指令都會放過它。玩家把東西拿出來後就能清——殘骸擋的是「移除」，
不擋「開箱拿東西」。

判定**直接用原版自己的 `isObjectNoContainerOrEmpty()`**（`IsoObject.java:6692`），
不要自己重寫——它已經涵蓋：

- 所有 `ItemContainer`（`getContainerCount()` ＝ primary ＋ `secondaryContainers`）
- **未探索**的容器（戰利品還沒生成，`size()` 是 0 但「將會」有東西）
- 所有 component 狀態（`Resources`、進行中的 `CraftLogic`…，例如乾燥架）

但它**漏掉流體**，必須另外查：`FluidContainer` 雖然是 component（`ComponentType:62`），
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

  **自動清掃沒有行為人**，無從判斷誰有權限：任一成員位在安全屋內就整組放過，
  留給有權限的玩家用右鍵手動處理。
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

27 項離線檢查：錨點回推、完整群組不誤判、缺一格判殘缺、同格無關物件不算成員、
移除必須走非 safe 版、**斷根在確認期滿後生效**、**原版替換流程不被誤傷**、
重入 guard、清除指令的距離驗證、近距離放行、完好家具不得被指令拆掉、
畸形封包與死亡玩家被擋、**未載入格子絕不誤刪且載回後重試能補上**、
**primary／secondary／未探索三種容器一律放過**、**安全屋授權**（未授權擋下、授權放行）、
**點擊時重新判定**（群組被補回完整、容器被塞東西 → 不刪；情況未變 → 正常清）、
**component 狀態與流體非空一律放過**、**安全屋跨界繞道被擋**、
**自動清掃碰安全屋 fail closed**、**重複 sprite 的 grid 判為無法判定**、
**MP 分支不本地刪除且 payload 正確**。

每一道會造成不可逆刪除的防線都做過 mutation test——把該防線改回錯誤行為後，
對應檢查立即失敗：

| 突變 | 失敗的檢查 |
|------|-----------|
| 未載入格子當成缺角 | 未載入的格子必須回報 unknown |
| 只查 primary 容器 | secondary 容器有東西 |
| 拿掉未探索容器保護 | 未探索容器（戰利品還沒生成） |
| 拿掉 component 狀態檢查 | primary 容器有東西 |
| 拿掉流體檢查 | 流體非空時自動清掃必須放過 |
| 安全屋改成永不阻擋 | 非授權玩家不得清安全屋內的殘骸 |
| 自動清掃拿掉安全屋 gate | 自動清掃碰到安全屋必須 fail closed |
| 拿掉重複 sprite 檢查 | 重複 sprite 的 grid 必須回報無法判定 |

### 可退場條件

官方在 `removeItemFromMap` 比照 `GARAGE_DOOR` 對 sprite grid 做整組展開，
或讓 `safelyRemoveTileObjectFromSquare` 對殘缺群組不再靜默失敗。

---

## MDFX_AnimalTrailerSize — 動物屍體 `animalTrailerSize` 欄位缺失

| 項目 | 內容 |
|------|------|
| 檔案 | `42/media/lua/client/Fixes/MDFX_AnimalTrailerSize.lua` |
| 影響版本 | 42.20.0（更早版本同樣有此寫法） |
| 端 | 純客戶端 |
| 狀態 | 生效中 |

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
