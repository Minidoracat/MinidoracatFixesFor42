# 修復清單

本 MOD 每加一項修復，就在這裡登記一筆：症狀、根因、修法、驗證方式、可退場條件。
「可退場」= 官方哪天修好了，就從 MOD 移除該檔並在此標記為已退場。

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

- `BaseVehicle.canAddAnimalInTrailer(IsoDeadBody)` 用 `rawgetFloat`，缺鍵回 `0.0`，不會炸
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
`trailerBaseSize`）。未知（模組）動物補 0，與 Java 端 `rawgetFloat` 缺鍵行為一致。
已有數值一律不覆蓋。手上拿著的屍體（原版第 755 行同樣沒防護）一併補。

補資料整段包在 `pcall` 裡 —— 修復本身絕不能變成新的選單殺手。

### 驗證

```
lua scripts/test_animal_trailer_size.lua
```

7 項離線檢查：正常補值、不覆蓋既有值、非動物屍體不碰、未知動物補 0、
包裝後原版函式照常回傳、補資料拋錯時選單仍完整、手上屍體也補到。

遊戲內：把有問題的動物屍體丟在開著動物門的拖車旁，右鍵載具 —— 修復前整段
車輛選單消失，修復後選單完整且「加入動物」可點。

### 可退場條件

官方在 `ISVehicleMenu.doAnimalSubMenu` 對 `animalTrailerSize` 加上 nil 防護，
或修掉 `ButcheringUtil.setAnimalBodyData` 第 27 行的無條件解參考。

### 待查

無法從客戶端 log 判定該伺服器上的壞屍體是「模組動物」還是「舊存檔屍體」——
要看伺服器端 log 有沒有 `setAnimalBodyData` 的 Lua 錯誤。不影響本修復是否正確，
但若是模組動物，代表壞屍體會持續產生。
