[h1]Minidoracat Fixes for B42 42.22.2-0.23.1[/h1]
[i]2026-11-27[/i]

[b]English summary[/b]
[list]
[*] Multiplayer: after digging up and replanting the same tile, players could keep seeing freshly plowed soil instead of the new crop. Replanted crops now always sync.
[*] Rare: only when the new crop matched the old one exactly (same in-game hour, same seed, same random values). Caused by this mod, not vanilla.
[*] Takes effect once the server has the update; players don't need to do anything. Single player is not affected.
[/list]

[h3]🔧 修正[/h3]
[list]
[*] [b]多人遊戲：同一格鏟掉重種後，玩家畫面上的新作物可能停在剛翻好的土[/b]：現在重種的作物一定會同步給玩家。伺服器更新 MOD 後就生效，玩家不用另外做什麼；單人遊戲不受影響。
[list]
[*] 只在少數情況發生：新作物剛好和舊作物同一個遊戲小時、同一種子播下，隨機數值也一樣。
[*] 這是本 MOD 從「走過農田時伺服器重送沒變的作物資料」那項修復起就有的問題，原版沒有。
[*] 2026-11-27 在 42.22.2 多人伺服器實機驗過：前一版重種後新作物沒有送出，這一版玩家約 0.5 秒後就看到新作物。
[/list]
[/list]
