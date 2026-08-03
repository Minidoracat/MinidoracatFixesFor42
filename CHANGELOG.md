# Changelog

## [42.20.0-0.2.0] - 2026-08-04

### 新增

- **MDFX_MultiTileFurniture**：修復多格家具（野餐桌／鋼琴／鍛造爐等）被砸壞或搬走後
  留下缺角殘骸、此後大槌打不掉／拆解不了／搬不走且完全無提示的問題。

  缺角來自 MP 封包不對稱：客戶端本地整組移除但只送單格封包，而伺服器端
  `removeItemFromMap` 只對 `GARAGE_DOOR` / `DOUBLE_DOOR` 整組展開；鎖死則來自
  `getSpriteGridMultiTileObjects` 的 all-or-nothing 檢查缺格即靜默放棄。

  **斷根**：伺服器端 `OnObjectAboutToBeRemoved` 記下群組錨點，延後約一秒再確認，
  仍殘缺才清掉剩餘成員。刻意不當場展開——原版 `MOFeedingTrough.lua:21` 在地圖載入時
  會蓄意單格移除再替換，而餵食槽本身就用 sprite grid，當場展開會弄壞餵食槽與兔籠。

  **清舊殘骸**：右鍵「清除卡住的家具殘骸」，只在確實殘缺時出現；MP 下由伺服器
  權威執行並重驗距離與殘缺狀態（客戶端座標不可信，也不能拿來拆完好家具）。

  殘缺判準是 `getSpriteGridMultiTileObjects` 的忠實 Lua 移植，與原版鎖死用的
  gate 完全一致。詳見 [docs/fixes.md](docs/fixes.md)。

  > 離線測試：`scripts/test_multitile_furniture.lua`（11 項檢查）。
  > 已知殘留：出手者自己畫面在少數情況有可自癒的暫態，不影響伺服器存檔。

- 介面字串翻譯：EN / CH / CN / JP。

## [42.20.0-0.1.0] - 2026-08-04

首版。

### 新增

- **MDFX_AnimalTrailerSize**：修復動物屍體缺 `animalTrailerSize` modData 欄位時，
  拖車動物門開著右鍵載具會讓**整段車輛右鍵選單消失**、死掉的動物裝不上拖車。

  原版 `ISVehicleMenu.doAnimalSubMenu`（42.20 第 755 / 806 行）把該欄位直接餵給
  `round()`，缺欄位時 `nil * mult` 拋 `__mul not defined for operands`，
  炸掉的是 `OnFillWorldObjectContextMenu` 上的 `ISVehicleMenu.FillMenuOutsideVehicle`
  整條鏈。欄位缺失的源頭是 `ButcheringUtil.setAnimalBodyData()` 第 27 行對
  `AnimalPartsDefinitions` 的 def 無條件解參考（第 19 行才剛判斷過它可能是 nil），
  在寫入 `animalTrailerSize` 之前就拋錯，而 Java 端是 protectedCall 吞掉錯誤後
  照樣寫 `animalType`——屍體於是成為「是動物、但缺欄位」的永久壞資料。

  修法為呼叫原版函式前補回 `trailerBaseSize × animalSize`（與 Java
  `IsoAnimal.getAnimalTrailerSize()` 同式），已有正確數值不覆蓋，每具屍體各自 `pcall`
  隔離，失敗時印一次 `[MinidoracatFixes]` 診斷行（避免本修復自己靜默失效）。
  詳見 [docs/fixes.md](docs/fixes.md)。

  > 玩家回報 + `console (14).txt` 33 次同一堆疊佐證。
  > 離線測試：`scripts/test_animal_trailer_size.lua`（9 項檢查）。

### 開發腳本

- `link_workshop.ps1`：UAC 提權建立符號連結時，路徑改走 `-EncodedCommand` ＋
  單引號加倍轉義。原本直接字串內插，Windows 路徑允許單引號（例如使用者名稱
  `O'Brien`），內插後會成為**以系統管理員身分執行的命令注入**。
- `link_workshop.ps1`：掛載時遇到既有 `.bak` 不再遞迴刪除，改用帶時間戳的備份名，
  避免第二次衝突把第一份備份不可復原地毀掉。
- `PZ_Test.ps1`：「停止」只殺路徑位於 PZ 目錄下的 `java.exe`。原本對所有 `java`
  執行 `Stop-Process -Force`，會連 IDE 與其他 Java 服務一起殺掉。

  > 這三項是從 `MinidoracatMiniMapFor42/scripts/` 原樣移植時帶進來的，
  > **該 repo 的同名腳本仍有相同問題**。
