# Minidoracat Fixes for B42

**By Minidoracat**

Project Zomboid Build 42 原版錯誤修復合輯（客戶端）。

專收「原版 Lua 沒做防護、在多人伺服器上會實際炸掉」的地方。純修復——
不改平衡、不加物品、不加介面、不加設定選項。每一項修復都在
[docs/fixes.md](docs/fixes.md) 登記症狀、根因、修法、驗證方式與可退場條件。

與 `MinidoracatFixPrivate`（`MinidoracatFixMultipleFor42` repo，client + server 兩端的
TimedAction／多人同步修復）的分工是**發佈管道**，不是端別：那支是私有、非 workshop，
只能裝在自己的伺服器上，玩家客戶端吃不到；本 MOD 是 **workshop 公開**，
玩家會實際載入的那一半。

## 目前收錄

| 修復 | 端 | 症狀 |
|------|----|------|
| `MDFX_AnimalTrailerSize` | client | 拖車動物門開著時右鍵載具，整段車輛選單消失、死掉的動物裝不上拖車 |
| `MDFX_MultiTileFurniture` | server + client | 多格家具（野餐桌／鋼琴／鍛造爐）被砸壞或搬走後留下缺角殘骸，此後打不掉、拆不了、搬不走。右鍵可清除（只清殘骸，不做斷根——理由見 docs） |

## 結構

```
MOD/MinidoracatFixesFor42/Contents/mods/MinidoracatFixesFor42/42/
├─ mod.info
└─ media/lua/
   ├─ client/Fixes/*.lua             客戶端修復（檔頭寫清楚根因）
   ├─ server/Fixes/*.lua             伺服器端修復（MP 由伺服器啟用時生效）
   ├─ shared/Fixes/*.lua             兩端共用的判準／工具
   └─ shared/Translate/*/            介面字串（EN / CH / CN / JP）
docs/fixes.md                        修復清單（症狀／根因／修法／驗證／退場）
scripts/test_*.lua                   離線自我檢查，lua 直接跑
scripts/link_workshop.ps1            開發／上傳用符號連結管理
scripts/PZ_Test.ps1                  本機測試啟動器
scripts/poster/finish_poster.py      封面合成（主視覺 → preview.png ＋ poster.png）
```

## 開發

```powershell
.\link_workshop.bat     # 連結到 Zomboid\Workshop 與 Zomboid\mods
.\PZ_Test.bat           # 啟動本機測試
lua scripts\test_animal_trailer_size.lua
```

## 加一項新修復

1. 在 `media/lua/client/Fixes/` 開一個 `MDFX_<名稱>.lua`，檔頭註解寫明症狀、
   根因（含原版檔名行號）、修法、為什麼修在這一端。
2. 包裝原版函式時一律 `pcall` 保護自己的部分——修復本身不能變成新的當機來源。
3. 寫一支 `scripts/test_<名稱>.lua` 離線檢查，`lua` 跑得起來。
4. 在 `docs/fixes.md` 登記，含可退場條件。
5. 更新 `CHANGELOG.md` 與 `mod.info` 的 `modversion`。

## MOD 資訊

- **Mod ID:** `MinidoracatFixesFor42`
- **支援版本:** Build 42.20.0+
- 單人／多人皆可用（多人由伺服器啟用）
