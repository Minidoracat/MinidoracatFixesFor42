[h1]🔧 Minidoracat Fixes for B42[/h1]
[h3]By Minidoracat[/h3]

[hr][/hr]

[h2]🧰 這是什麼[/h2]
Project Zomboid Build 42 的常設修復合輯，只收原版的錯誤，官方修好就退場。不改平衡、不加物品、介面或設定；正常遊玩不變。

[h2]🐛 目前收錄[/h2]
[list]
[*] [b]有些動物屍體永遠屠宰不了[/b]：缺資料的屍體（多來自動物 MOD）會讓屠宰白做一場。現在乾淨擋下，正常屠宰不受影響。
[*] [b]手拿非槍械＋穿彈藥背帶時裝彈沒反應[/b]：現在照原版公式正常裝彈。
[*] [b]撫摸的動物剛好死亡或消失時伺服器出錯[/b]：現在乾淨結束動作。
[*] [b]工具最後一擊用壞時動作卡住[/b]（拆牆、清雜物、砍矮樹）：現在正常收尾，壞工具會卸下並換上最好的武器。
[*] [b]擠奶擠不出東西[/b]：桶子已不能裝液體時，現在直接結束，換個桶子即可。
[*] [b]倒液體到另一個容器時液體憑空消失[/b]：現在先確認兩邊都能裝，不行就整個不做。
[*] [b]換裝或擺家具時物品已不在，伺服器出錯[/b]：現在乾淨結束動作。
[*] [b]車門只鎖到一半[/b]：現在先檢查整台車，有問題就一扇都不動。
[*] [b]走過農田時伺服器一直重送沒變的作物資料[/b]：現在只在作物有變化時才送，澆水、生長、被踩爛等照樣即時看到，省下伺服器上傳流量。
[*] [b]農作物存檔長太大後整份被清空、作物停止生長[/b]：原版把枯死、被踩爛的作物也永久記在存檔裡，超過引擎上限時整份變空、農作時鐘歸零。現在沒人的區域裡這類作物會暫時移出存檔，有人回去時原樣還原（移出期間枯作物不會慢慢變成踩爛的樣子）；另外備份農作時鐘，已經卡住的作物也會恢復生長。
[/list]

[h2]📋 MOD 資訊[/h2]
[list]
[*] [b]Mod ID:[/b] MinidoracatFixesFor42
[*] [b]支援版本:[/b] Build 42.20.4+
[*] 單人／多人皆可用；多人由伺服器啟用，除裝彈那條外都只在伺服器端生效
[*] 每項修復的原因與驗證都公開在 GitHub
[*] 移除本 MOD 前請留意：還沒有人回去過的區域裡，被暫時移出存檔的踩爛／已收成作物將無法再用農作選單處理
[/list]

[h2]💬 回報與社群[/h2]
[url=https://discord.gg/Gur2V67]👉 加入 Discord 伺服器[/url]

[h2]☕ 支持作者[/h2]
覺得有幫助的話，請在這頁按個 👍 讚、到 GitHub 給個 ⭐ 星星，讓更多玩家找得到它。
MOD 永遠免費，原始碼公開在 GitHub。喜歡的話可以請我喝杯咖啡，贊助會用在伺服器與 MOD 開發上。
[url=https://ko-fi.com/minidoracat][img]https://raw.githubusercontent.com/Minidoracat/workshop-resources/refs/heads/main/badges/badge_kofi.png[/img][/url] [url=https://github.com/Minidoracat/MinidoracatFixesFor42][img]https://raw.githubusercontent.com/Minidoracat/workshop-resources/refs/heads/main/badges/badge_github.png[/img][/url]

[b]#fix #bugfix #vanilla #butchering #reload #farming #Minidoracat[/b]

Workshop ID: 3790443858
Mod ID: MinidoracatFixesFor42
