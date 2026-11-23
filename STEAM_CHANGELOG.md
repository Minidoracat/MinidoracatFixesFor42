[h1]Minidoracat Fixes for B42 42.22.2-0.21.0[/h1]
[i]2026-11-23[/i]

[b]English summary[/b]
[list]
[*] Multiplayer servers with very long days (12 hours or longer, real-time days included): when everyone slept at once, players were woken by "hypothermia" within minutes, even indoors at a normal temperature. They now sleep until the planned wake-up time.
[*] Cause: the server fast-forwards time while everyone is asleep, and the longer the day is set, the faster it goes. Vanilla's body temperature calculation advances by a step that grows with it, so the calculated temperature jumped by several degrees. The fix splits the calculation into smaller steps during fast-forward, each about the size of vanilla's step with the default day length.
[*] Everything else follows vanilla: it stays out of the way while anyone is awake and on servers with days shorter than 6 hours (with the default fast-forward multiplier). When it really is cold you still get hypothermia, and you are still woken by it.
[*] Runs only on multiplayer servers. Players don't need to do anything; single player is not affected.
[/list]

[h3]🔧 修正[/h3]
[list]
[*] [b]一天設得很長的多人伺服器，所有人一起睡覺時沒多久就被冷醒[/b]：一天設成 12 小時以上（包含即時制）的多人伺服器，所有人都睡著之後，沒多久就被「失溫」叫醒，待在室內、氣溫正常也一樣。預定睡 8 小時，一天 12 小時的伺服器睡不到 1 小時、即時制的伺服器十幾分鐘就醒。現在可以睡到預定的時間。
[*] 原因：所有人都睡著時伺服器會快轉時間，一天設得越長快轉得越快；原版的體溫計算每次前進的幅度跟著放大，算出來的體溫上下跳好幾度。本修正在快轉期間把體溫計算切成小步來算，每一小步的幅度約等於原版在預設一天長度下的幅度。
[*] 其他都照原版：有人醒著的時候、一天不到 6 小時的伺服器（快轉倍率用預設值時）都不介入；真的冷的時候照樣會失溫，也照樣會被冷醒。
[*] 只在多人伺服器執行，玩家不用另外做什麼；單人遊戲不介入。
[*] 2026-11-23 在 42.22.2 多人伺服器實機驗過：一天 8 小時、12 小時與即時制都睡滿 8 小時，體溫維持在 36.9～37.1°C；寒冷、炎熱、凍傷與兩位玩家一起睡也驗過。
[/list]
