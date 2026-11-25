[h1]Minidoracat Fixes for B42 42.22.2-0.22.0[/h1]
[i]2026-11-26[/i]

[b]English summary[/b]
[list]
[*] Multiplayer: a vehicle parked on farmland or next to crops no longer makes the server lag ("Server is too busy"). Before, the lag lasted as long as the vehicle stayed on trampled crops with a player nearby.
[*] Cause: for each crop under the vehicle, the player's game told the server "this crop was trampled" again on every frame, although it was already trampled. This is a vanilla problem; it happens without any mods too.
[*] Vehicles still trample crops as in vanilla. Two differences you may notice: an already-trampled crop no longer replays the trample sound every frame, and water you were adding when it got trampled is no longer cleared.
[*] Takes effect once the server has updated; players don't need to do anything. Single player is not affected.
[*] Tested on a 42.22.2 multiplayer server: with a vehicle parked on trampled crops for 10 seconds, the repeated messages the server received dropped from about 2,500 to 0.
[/list]

[h3]🔧 修正[/h3]
[list]
[*] [b]多人遊戲：車停在農地或作物旁時伺服器變卡（Server is too busy）[/b]：現在車停在踩爛的作物上，伺服器不會再因此變卡。伺服器更新後就生效，玩家不用另外做什麼；單人遊戲不受影響。
[list]
[*] 以前只要附近有玩家，車在踩爛的作物上停多久就卡多久，把車開走才恢復。
[*] 一個正式伺服器實測，伺服器約五分之一的時間花在這件事上，其中大部分是另一個 MOD 對每次通知做的權限檢查。
[*] 作物照樣會被車踩爛，車也照樣可以停在田上。
[*] 玩家會注意到的差別：已經踩爛的作物不再每個畫面重播踩爛的音效；澆水澆到一半作物被車踩爛、車還壓在上面時，水量不再被清空。
[*] 2026-11-26 在 42.22.2 多人伺服器實機驗過：車停在踩爛的作物上 10 秒，伺服器收到的重複通知從約 2500 次變成 0 次。
[/list]
[/list]
