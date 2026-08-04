# Changelog

## [42.20.0-0.3.0] - 2026-08-04

依第四輪 codex 獨立 review（60/100，九個歷史 blocker 8 關 1 半開）的架構性結論，
**移除自動斷根，只保留右鍵手動清除**。

### 移除

- **`MDFX_MultiTileFurniture` 的自動斷根**（`OnObjectAboutToBeRemoved` ＋ `OnTick`
  延後確認掃描）。它分不出「永久殘骸」與「合法但延遲完成的 remove-and-replace」——
  PZ 從未承諾 replacement 會在固定時間內完成（`MOFeedingTrough.lua:15` 目前恰好
  同幀完成，但那不是 API 契約）。獨立審查用延遲替換 probe 重現了不可逆刪掉三個
  仍有效成員（`delayed_replacement_removed=3`），而當時 27 項測試全綠。

  沒有行為人、拿不到操作意圖，只靠事後掃描無法證明零資料損失；加長 timeout、
  identity snapshot、`OnObjectAdded` 取消機制都只能縮小視窗。

  影響：新的缺角仍會產生，但玩家隨時能用右鍵清掉。要真正斷根該走 Java patch，
  在 `removeItemFromMap` 比照車庫門展開——那裡才拿得到明確的操作意圖。

### 保留與強化

右鍵手動清除有明確行為人與完整的 server gate，全部保留：距離、安全屋（逐成員）、
內容物（容器／component／流體）、未載入格子、錨點模糊、TOCTOU 重驗、畸形封包。

### 測試

- 27 → 25 項（移除斷根相關情境，新增「選單本身也擋安全屋」與 event 白名單防迴歸）。
- **event 白名單防迴歸**：所有待測檔載入完後，斷言註冊的 event 只有
  `OnClientCommand` 與 `OnFillWorldObjectContextMenu`。第五輪 review 實測，
  原本只黑名單 `OnTick` / `OnObjectAboutToBeRemoved` 的版本擋不住
  「改用 `EveryOneMinute`」與「改在 client 端註冊」兩種變體；白名單版本四種全擋。
- 十一道防線 mutation test 全數通過。

### 文件

- 修正三處註解語意殘留：client 檔頭仍稱斷根會防止新殘骸、shared 仍用「自動清掃」、
  server 的「吃不掉玩家儲物」比實際 component 保證更絕對。
  公開 README／docs 原本就正確，這三處是程式碼內註解。

## [42.20.0-0.2.3] - 2026-08-04

第三輪 codex 獨立 review（verdict：REQUEST CHANGES／BLOCK；六個舊 blocker 4 關 2 半開）的修正。
兩條新的可重現不可逆刪除路徑，加上一條 Important。

### 修正

- **只查 `ItemContainer`，component 與流體內容仍會被刪掉**。改為直接用原版自己的
  `isObjectNoContainerOrEmpty()`（`IsoObject.java:6692`）——它已涵蓋所有容器（含未探索）
  與所有 component 狀態（`Resources`、進行中的 `CraftLogic`，例如乾燥架）。
  但它**漏掉流體**：`FluidContainer` 是 component 卻沒 override
  `isNoContainerOrEmpty()`，而餵食槽有水時 primary `ItemContainer` 甚至是 nil
  （`IsoFeedingTrough.java:59`），因此另外查 `getFluidContainer()`。
  codex probe：`component_removed=3`、`fluid_removed=3`。

- **安全屋授權只覆蓋指令那一格，自動清掃完全沒有 gate**。安全屋是矩形範圍，
  實際被刪的是整組成員——只驗一格就能「站在屋外對屋內 sibling 下手」。
  改為逐一檢查每個待刪成員當下的 square，並改用與原版 UI 同一套 policy 的
  `SafeHouse.isSafehouseAllowInteract`（`SafeHouse.java:245`，含交戰中對手，
  解掉先前 `playerAllowed` 造成的 UI／伺服器不一致）。自動清掃沒有行為人，
  任一成員在安全屋內就整組 fail closed。
  codex probe：`safehouse_command_removed=3`、`safehouse_auto_removed=3`。

- **重複 sprite 的 grid 會算出錯誤錨點，刪到隔壁完好群組**。
  `getSpriteGridPosX` 走 `getSpriteIndex`，只回第一個相符位置
  （`IsoSpriteGrid.java:52`），`validate()` 也不檢查唯一性。改為掃描前先數
  該 sprite 在 grid 內的出現次數，不等於 1 一律視為無法判定。
  codex probe：`duplicate_removed=1,intactB=false`。

### 測試

- 21 → 27 項。新增 component 狀態、流體、安全屋跨界繞道、自動清掃安全屋 gate、
  重複 sprite grid、MP 分支 payload。
- 修掉三個 codex 指出的假綠來源：stub 補上 component／fluid 狀態、
  `SafeHouse` mock 改成逐格判定、`isClient()` 改為可切換讓 MP 分支真的跑到。
- stub 保留舊 `getContainer()` API，讓「精確退回舊版程式碼」的 mutation 不會死在缺方法。
- 八道防線全部 mutation test 通過。

### 文件

- 修正 `docs/fixes.md` 殘留的事實錯誤：`rawgetFloat` 缺鍵回 `-1.0` 而非 `0.0`。

## [42.20.0-0.2.2] - 2026-08-04

第二輪 codex 獨立 review（verdict：REQUEST CHANGES，20/100，三個不可逆刪除 blocker）的修正。
上一輪三個 blocker 的修法本身還留著三個新缺口。

### 修正

- **容器保護不完整，仍會毀掉玩家的東西**。`hasStoredItems` 只查 primary
  `getContainer()`，漏掉兩種情況：
  - 物件可能有**多個**容器（`IsoObject.getContainerCount()` = primary ＋
    `secondaryContainers`，`IsoObject.java:5132`）
  - **未探索**的容器戰利品還沒生成，`getItems():size()` 是 0 但「將會」有東西
    （`ItemContainer.isExplored()`，`ItemContainer.java:334`）

    兩者都改成 fail-closed：一律當成有內容，寧可留著殘骸也不毀東西。

- **伺服器端沒做安全屋授權**。原版右鍵選單被 `safehouseAllowInteract` 擋著
  （`ISWorldObjectContextMenu.lua:211`），但那是客戶端 gate；惡意客戶端可直接送
  `OnClientCommand` 繞過去，跑進別人的安全屋清家具。伺服器端補上
  `SafeHouse.getSafeHouse(sq)` ＋ `playerAllowed(player)`（原版拆除先例：
  `ISDestroyCursor.lua:148`）。

- **右鍵選項有 TOCTOU**。選項沿用建立選單當下抓到的成員清單，但選單建好到點擊之間
  世界可能已變（別人補好了、chunk 卸載、有人往容器塞東西）。MP 有伺服器重驗擋著，
  **單人沒有**，會直接刪錯東西。改成點擊時重跑 `inspect`。

### 測試

- 14 → 21 項。新增 secondary／未探索容器、安全屋授權（擋下＋放行）、
  以及三項客戶端 TOCTOU（補回完整不刪、容器被塞不刪、情況未變正常清）。
- 四道會造成不可逆刪除的防線全部做過 mutation test，逐一確認拿掉後對應檢查立即失敗。

## [42.20.0-0.2.1] - 2026-08-04

依 codex 獨立 review 修正 `MDFX_MultiTileFurniture` 的三個問題，其中第一項會造成不可逆的存檔損壞。

### 修正

- **⚠ 未載入的格子被當成缺角，會誤刪完好家具**（嚴重）。
  `MDFX_SpriteGrid.scan` 照抄了 Java `getSpriteGridMultiTileObjects` 的 boolean，
  但原版拿它當**許可 gate**（無法確認 → 不准移除，fail-closed），本 MOD 卻拿來當
  **刪除依據**——語意剛好相反。結果：跨 chunk 邊界、或相鄰 chunk 尚未載入的多格家具
  會被判定成殘骸直接清掉。

  改為把「缺成員」與「無法判定」分開回報：格子未載入或稀疏 grid 一律 `unknown`，
  絕不刪除，改為稍後重試（最多 5 輪）；等不到就放棄，殘骸留著由玩家手動清。

- **容器內容物會被自動清掃靜默毀掉**。原版 `RemoveTileObject` 完全不管容器。
  玩家自己動手拆是他的決定，自動清掃不能替他決定——群組內只要還有非空容器，
  自動清掃與手動清除指令都放過。

- **`OnClientCommand` 授權不足**。補上座標型別驗證、玩家存在且未死亡檢查，
  整段 `pcall` 包住避免畸形封包在 event 迴圈裡拋例外。

### 測試

- 11 → 14 項。新增未載入格子不誤刪＋載回後重試、非空容器放過、畸形封包與死亡玩家被擋。
- 第 13 項做過 mutation test（改回舊行為即失敗），確認是真的迴歸測試。

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
