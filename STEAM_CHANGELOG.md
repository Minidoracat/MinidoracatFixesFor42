[h1]Minidoracat Fixes for B42 42.20.0-0.3.0[/h1]
[i]2026-08-04[/i]
依第四輪 codex 獨立 review（60/100，九個歷史 blocker 8 關 1 半開）的架構性結論，
[b]移除自動斷根，只保留右鍵手動清除[/b]。

[h3]🗑️ 移除[/h3]
[list]
[*] [b]MDFX_MultiTileFurniture 的自動斷根[/b]（OnObjectAboutToBeRemoved ＋ OnTick
[/list]
延後確認掃描）。它分不出「永久殘骸」與「合法但延遲完成的 remove-and-replace」——
PZ 從未承諾 replacement 會在固定時間內完成（MOFeedingTrough.lua:15 目前恰好
同幀完成，但那不是 API 契約）。獨立審查用延遲替換 probe 重現了不可逆刪掉三個
仍有效成員（delayed_replacement_removed=3），而當時 27 項測試全綠。
沒有行為人、拿不到操作意圖，只靠事後掃描無法證明零資料損失；加長 timeout、
identity snapshot、OnObjectAdded 取消機制都只能縮小視窗。
影響：新的缺角仍會產生，但玩家隨時能用右鍵清掉。要真正斷根該走 Java patch，
在 removeItemFromMap 比照車庫門展開——那裡才拿得到明確的操作意圖。

[h3]• 保留與強化[/h3]
右鍵手動清除有明確行為人與完整的 server gate，全部保留：距離、安全屋（逐成員）、
內容物（容器／component／流體）、未載入格子、錨點模糊、TOCTOU 重驗、畸形封包。

[h3]• 測試[/h3]
[list]
[*] 27 → 25 項（移除斷根相關情境，新增「選單本身也擋安全屋」與 event 白名單防迴歸）。
[*] [b]event 白名單防迴歸[/b]：所有待測檔載入完後，斷言註冊的 event 只有
[/list]
OnClientCommand 與 OnFillWorldObjectContextMenu。第五輪 review 實測，
原本只黑名單 OnTick / OnObjectAboutToBeRemoved 的版本擋不住
「改用 EveryOneMinute」與「改在 client 端註冊」兩種變體；白名單版本四種全擋。
[list]
[*] 十一道防線 mutation test 全數通過。
[/list]

[h3]• 文件[/h3]
[list]
[*] 修正三處註解語意殘留：client 檔頭仍稱斷根會防止新殘骸、shared 仍用「自動清掃」、
[/list]
server 的「吃不掉玩家儲物」比實際 component 保證更絕對。
公開 README／docs 原本就正確，這三處是程式碼內註解。
