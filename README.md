# Minidoracat Fixes for B42

**By Minidoracat**

Project Zomboid Build 42 的常設修復合輯（client + server）。

只收「原版或熱門 MOD 壞掉、官方修好就退場」的防護。純修復——不改平衡、
不加物品、不加介面、不加設定選項；正常遊玩的行為完全不變，只在原本會炸掉的
地方乾淨接住。每一項修復都在 [docs/fixes.md](docs/fixes.md) 登記症狀、根因、
修法、驗證方式與可退場條件；遊戲更新後跑
`python scripts/check_vanilla_alignment.py` 一鍵確認各修復的 vanilla 前提是否仍成立。

與 `MinidoracatFixPrivate`（`MinidoracatFixMultipleFor42` repo，client + server 兩端的
TimedAction／多人同步修復）的分工是**發佈管道**，不是端別：那支是私有、非 workshop，
只能裝在自己的伺服器上，玩家客戶端吃不到；本 MOD 是 **workshop 公開**，
玩家會實際載入的那一半。

## 目前收錄

| 修復 | 端 | 症狀 |
|------|----|------|
| `MDFX_ButcherMeatRatio` | server | 屠宰某些動物屍體（modData 缺 `meatRatio`，多為動物 MOD 產物）時 `ButcheringUtil.lua:70` 串接 nil 拋錯，連鎖 NetTimedAction NPE；玩家花完整段動作一塊肉都拿不到，該動物永遠屠宰不了 |
| `MDFX_ReloadSpeedGuard` | shared | 手持非槍械物品＋穿彈藥背帶（或 RELOAD_FAST 裝備）對彈匣裝彈，`ISReloadWeaponAction.lua:95` 對非武器呼叫 `getMagazineType` 拋錯；裝彈流程沒開始就中斷，「按了沒反應」 |
| `MDFX_PetAnimalGuard` | server | 撫摸動作送到伺服器時動物已死亡／卸載，3 秒後 `ISPetAnimal.lua:88` 對 nil 拋錯；比照 vanilla 自家寫法乾淨結束動作 |
| `MDFX_WorldObjectCheckWeapon` | server | 工具在最後一擊剛好用壞時，`ISWorldObjectContextMenu.checkWeapon` 在 dedicated server 上不存在（vanilla 只放在 `client/`），`ISDestroyStuffAction.lua:312`／`ISPickUpGroundCoverItem.lua:35`／`ISRemoveBush.lua:79` 拋錯；動作沒收尾、壞工具不卸裝 |
| `MDFX_MilkAnimalGuard` | server | 桶子已不是流體容器時 `ISMilkAnimal.lua:70` 對 nil 解參考；擠奶動畫演完、桶子沒有奶 |
| `MDFX_ConsolidateDrainableGuard` | server | `ISConsolidateDrainable.lua:33/35` 先扣來源再填目的物、中間不驗型別；目的物缺 `setUsedDelta` 時形成部分更新（液體憑空消失） |
| `MDFX_ClothingExtraGuard` | server | `ISClothingExtraAction:complete` 缺 `isValid:6` 那道 nil guard，`:67` 對 nil 衣物解參考 |
| `MDFX_MoveablesActionGuard` | server | `ISMoveablesAction.lua:308` 在 `place` 模式對 nil 物品解參考；只有 log 噪音（引擎本來就當動作被拒） |
| `MDFX_LockDoorsGuard` | server | `ISLockDoors.lua:46` 對 `VehiclePart` 做 `..` 拋錯，且上鎖迴圈邊走邊寫；車門只鎖到一半 |
| `MDFX_Guard`（骨架，非修復） | shared | 六條 server 端守衛的共用骨架：`isServer()` 閘門、vanilla 形狀檢查、marker 冪等、`OnGameBoot` 復查、診斷節流 |
| `MDFX_CleanUIConfigLoad` | client | **已退場**（CleanUI v2.7.9 官方修復；補丁自動不介入，保留為 regression 保險）。CleanUI v2.7.8 缺 `CleanUIConfig.loadConfig` 讓背包與戰利品視窗完全不建立 |

### 已移出

| 修復 | 移出版本 | 說明 |
|------|---------|------|
| `MDFX_AnimalTrailerSize` | 0.4.0 | 拖車動物門開著時右鍵載具，整段車輛選單消失 |
| `MDFX_MultiTileFurniture` | 0.4.0 | 多格家具殘骸右鍵清除 |

兩項都不再隨遊戲版本維護。原理與當時的判斷記錄仍留在 `docs/fixes.md`。

## 結構

```
MOD/MinidoracatFixesFor42/Contents/mods/MinidoracatFixesFor42/42/
├─ mod.info
└─ media/lua/
   ├─ client/Fixes/*.lua             客戶端修復（檔頭寫清楚根因）
   ├─ server/Fixes/*.lua             伺服器端修復（MP 由伺服器啟用；單人也載入）
   ├─ shared/Fixes/*.lua             兩端都要保護時放這裡
   └─ shared/Translate/*/            介面字串（目前無，修復不含任何字串）
docs/fixes.md                        修復清單（症狀／根因／修法／驗證／退場）
scripts/test_*.lua                   離線自我檢查，lua 直接跑
scripts/check_vanilla_alignment.py   遊戲更新後確認各修復仍對齊 vanilla
scripts/link_workshop.ps1            開發實體副本同步／歸檔管理
scripts/PZ_Test.ps1                  啟動前自動同步的本機測試啟動器
scripts/poster/finish_poster.py      封面合成（主視覺 → preview.png ＋ poster.png）
```

## 開發

```powershell
.\link_workshop.bat     # 手動同步到兩處實體副本；日常不必每次執行
.\PZ_Test.bat           # 自動同步後啟動本機測試；規則見 ../pz-family-docs/tools.md
lua scripts\test_butcher_meatratio.lua
lua scripts\test_reload_speed_guard.lua
lua scripts\test_pet_animal_guard.lua
lua scripts\test_cleanui_config_load.lua
python scripts\check_vanilla_alignment.py
```

## 加一項新修復

1. 依生效端在 `media/lua/{client,server,shared}/Fixes/` 開一個 `MDFX_<名稱>.lua`，
   檔頭註解寫明症狀、根因（含原版檔名行號）、修法、為什麼修在這一端。
2. 包裝原版函式時一律 `pcall` 保護自己的部分——修復本身不能變成新的當機來源；
   正常路徑必須原樣透傳（零行為差異），並防重複包裝。
3. 寫一支 `scripts/test_<名稱>.lua` 離線檢查，`lua` 跑得起來；對每道防線做
   mutation 驗證（抽掉防線對應檢查要轉紅）。
4. 在 `docs/fixes.md` 登記，含可退場條件；在
   `scripts/check_vanilla_alignment.py` 登記 vanilla 指紋（爆點行＋依賴符號）。
5. 更新 `CHANGELOG.md` 與 `mod.info` 的 `modversion`。

## MOD 資訊

- **Mod ID:** `MinidoracatFixesFor42`
- **支援版本:** Build 42.20.4+
- 單人／多人皆可用（多人由伺服器啟用）

### 發布到 Workshop

雙擊 `Publish_Workshop.bat`：先確認 Steam 用戶端已以作者帳號登入（未登入會喚起 Steam 並等你登入後重試），
再選擇更新 MOD 內容（含 `STEAM_CHANGELOG.md` 更新說明）／GIF 封面／簡介／全部；提交後回查 Steam，
任一不符即以非零碼結束。設定在 `scripts/workshop_publish.json`（Workshop ID、簡介語言槽來源、GIF 路徑）。

```
uv run --no-project python -B scripts/publish_workshop.py --mode all --yes       # 自動化／AI；或 content / preview / description
uv run --no-project python -B scripts/publish_workshop.py --mode all --dry-run   # 只檢查、顯示計畫
```

退出碼：`0` 成功／`2` 參數或取消／`3` 未登入、帳號不是擁有者／`4` 前置檢查失敗／`5` 提交失敗／`6` 已提交但回查不符。
網頁動態封面放 `MOD/<資料夾>/workshop/preview.gif`（不在 `Contents/`，不會下載給玩家）；遊戲內上傳器仍用 `preview.png`，
且每次會把網頁封面覆回靜態，需要動態封面時一律改用本工具發布。
