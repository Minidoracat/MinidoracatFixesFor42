[h1]Minidoracat Fixes for B42 42.22.2-0.18.0[/h1]
[i]2026-11-11[/i]

[b]English summary[/b]
[list]
[*] Multiplayer: a vehicle that drops below the ground while you drive (black screen, car stuck underground even after relogging) is now put back on the ground right away.
[*] Windows from the four new Build 42 sets can be put back on a north wall after you pick them up.
[*] A worn bag or clothing item you place on the ground no longer keeps showing on your character; its hotbar slots go away within a second or two.
[*] Large objects with missing pieces (for example a boulder that only half spawned) can now be destroyed with a sledgehammer, one piece per hit.
[*] Stronger server-side validation: in multiplayer, sledgehammer destruction follows the vanilla server rules.
[*] Servers need to update the mod and restart; players get it on their next connect.
[/list]

[h3]🔧 修正[/h3]
[list]
[*] [b]多人遊戲開車時車掉到地面下[/b]：畫面突然全黑、只剩介面與小地圖，下車後車陷在地裡，重新登入也一樣。現在車一掉到地板下面就立刻放回地面，位置與車頭方向不變。
[*] 只處理你自己正在開、或開車撞到的車；已經陷在地下、沒有人開的車不處理。翻覆但還在地面附近的車不動。
[*] [b]北側牆上的新款窗拆下後裝不回去[/b]：Build 42 新增的四組窗（「白色窗框」等）用撬棍拆下來之後，指回原本的窗框一直是紅色。現在裝得回去；窗框、木工等級與鐵鎚的條件都照原版。
[*] 這是原版的問題，單人與多人都會發生。這些新款窗仍然不能像舊款那樣在北側與西側之間換面。
[*] [b]把穿著的背包或衣物放到地上後，身上還畫著它[/b]：背包已經在地上，背上卻還畫著，背包給的快捷列欄位也不消失，要重新登入（單人要重新讀檔）才恢復。現在一到兩秒內就會消失。
[*] 開著會更換角色外觀的 MOD（幻化類）時特別容易遇到。正常的穿、脫、換穿、扔掉完全不變。
[*] [b]缺了幾片的大石頭或大型家具用大錘敲不掉[/b]：佔好幾格的物件少了幾片時（常見的是只生成一半的大石頭），游標是綠的、動作跑完、大錘照常耗損，東西卻還在原地。現在敲得掉，每次敲掉被敲的那一片。
[*] 這是原版的問題，單人與多人都會發生。完整的大型物件照原版一次整組拆掉。只修大錘：缺片的家具仍然撿不起來、拆解不了。
[*] [b]強化伺服器端驗證：大錘拆除照原版的伺服器規則檢查[/b]：角色要帶著能用的大錘、離目標夠近；伺服器開了「大錘只能在安全屋用」時，要在允許自己用的安全屋裡。只用原版的大錘拆除時結果和原版相同。
[*] 伺服器更新本 MOD 並重啟後生效，玩家下次連線就會下載到；單人更新 MOD 後就生效。
[/list]
