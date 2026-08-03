[h1]🔧 Minidoracat Fixes for B42[/h1]
[h3]By Minidoracat[/h3]

[hr][/hr]

[h2]✨ 這是什麼[/h2]
Build 42 原版錯誤修復合輯（客戶端）。專收「原版 Lua 沒做防護、在多人伺服器上會實際炸掉」的地方。

[b]純修復[/b]——不改遊戲平衡、不新增物品、不新增介面、不新增設定選項。裝上去唯一的差別是本來會壞的地方不壞了。

[h2]🧰 目前收錄[/h2]
[list]
[*] [b]動物屍體上不了拖車 / 車輛右鍵選單消失[/b]
拖車的動物門開著時右鍵載具、或按拖車動物 UI 的「加入動物」鈕，整段車輛右鍵選單消失，死掉的動物也裝不上拖車。
console.txt 會出現 [b]__mul not defined for operands in round[/b]（ISVehicleMenu.lua:806）。
成因是動物屍體缺了一個記錄「佔拖車多少空間」的欄位，而原版那行沒做防護，一碰就讓整段選單建構中止。
本修復在原版讀取前把該欄位依照遊戲自己的公式補回去，值與引擎算出來的完全一致。
[/list]

[h2]📋 MOD 資訊[/h2]
[list]
[*] [b]Mod ID:[/b] MinidoracatFixesFor42
[*] [b]支援版本:[/b] Build 42.20.0+
[*] 單人／多人皆可用（多人由伺服器啟用）
[*] 客戶端修復，伺服器不需要額外設定
[*] 官方哪天修好了，對應項目就會從本 MOD 移除
[/list]

[h2]💬 回報與社群[/h2]
[url=https://discord.gg/Gur2V67]👉 加入 Discord 伺服器[/url]

[h2]📺 追蹤作者[/h2]
[url=https://www.twitch.tv/minidoracat]🎬 Twitch 頻道[/url]

[b]#fix #bugfix #vehicle #animal #Minidoracat[/b]
