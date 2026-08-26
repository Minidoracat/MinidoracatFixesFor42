[h1]🔧 Minidoracat Fixes for B42[/h1]
[h3]By Minidoracat[/h3]

[hr][/hr]

[h2]⏳ 這是臨時修復[/h2]
本 MOD 目前只做一件事：把 [b]CleanUI[/b] 在 Build 42.20.4 上壞掉的背包與戰利品視窗救回來。

[b]這是替原作者頂著的臨時措施。[/b]CleanUI 原作者釋出修好的版本之後，本修復會自動失效——它偵測到官方版本就不再介入，玩家不需要做任何事。屆時本 MOD 就會下架，或改收其他項目。

[h2]🐛 修的是什麼[/h2]
[list]
[*] [b]症狀[/b]：背包與戰利品視窗完全打不開。角色能走、能聊天，但整個物品欄介面不存在。
[*] console.txt 會出現 [b]Object tried to call nil in getConfig[/b]。
[*] [b]成因在 CleanUI 那一側[/b]：Build 42.20.4 的安全性變更移除了 Lua 的 loadstring，CleanUI 作者當天緊急改寫了設定讀取方式，但釋出的檔案裡少了其中一個函式，而呼叫它的地方沒有跟著改。
[*] 物品欄面板在建立途中就中斷，連帶讓戰利品視窗、以及掛在同一段初始化流程上的其他介面全都沒建起來。這就是為什麼「只是一個設定讀不到」會讓整個物品欄消失。
[*] [b]本修復[/b]：只把那個缺失的函式補回去，用的全是 CleanUI 自己已經有的東西。不改它任何既有行為，不新增設定或介面。
[/list]

[h2]📋 MOD 資訊[/h2]
[list]
[*] [b]Mod ID:[/b] MinidoracatFixesFor42
[*] [b]支援版本:[/b] Build 42.20.4+
[*] 沒裝 CleanUI 的玩家裝了完全不會有作用，也不會有副作用
[*] 客戶端修復，伺服器不需要額外設定
[*] 載入順序不影響效果（排在 CleanUI 前面或後面都可以）
[*] 不改遊戲平衡、不新增物品、不新增介面、不新增設定選項
[*] 不會寫入或修改你的 CleanUI 設定檔
[/list]

[h2]💬 回報與社群[/h2]
[url=https://discord.gg/Gur2V67]👉 加入 Discord 伺服器[/url]

[h2]📺 追蹤作者[/h2]
[url=https://www.twitch.tv/minidoracat]🎬 Twitch 頻道[/url]

[b]#fix #bugfix #CleanUI #inventory #Minidoracat[/b]

Workshop ID: 3790443858
Mod ID: MinidoracatFixesFor42
