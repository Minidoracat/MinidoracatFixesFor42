--[[
MDFX_DeathSync — 多人遊戲只有客戶端判定死亡、伺服器沒處理：沒有屍體，按重生後畫面全黑（42.21）

【缺陷】（行號為 42.21.0 反編譯快照）
被殭屍圍住拖倒（沙盒 ZombiesDragDown）的死亡由受害者的客戶端判定：客戶端自己 Kill（PlayerHitReactionState.java:83、
IsoPlayer.java:3439）。伺服器要收到客戶端送來的殭屍命中（只替本機擁有的殭屍送，GameClient.java:1191-1194），再用
自己看到的攻擊殭屍數重算一次拖倒（命中封包沒有拖倒旗標，Bite.java:18-28；重算在 BodyDamage.java:1286-1296），
算出拖倒才跟著 Kill（Bite.java:89-94）。命中整段沒送到，或伺服器算出的攻擊殭屍數不到門檻，伺服器上的角色就一直活著；
客戶端自己 Kill 的其他路徑也一樣不通知伺服器。

【後果】
- 伺服器不寫 `user … died`、不建屍體，也不送 PlayerDeath 回客戶端。
- 玩家按重生、建好新角色後，伺服器看到舊角色還活著就拒絕（ConnectCoopPacket.java:69-70），客戶端的 players[0]
  一直是 null：畫面全黑、只剩介面。
- 重新連線後，伺服器那份還活著就回到原角色；那份之後被別的路徑弄成死亡時沒有屍體，裝備全沒。
正式服 2026-10-14～10-29 有 10 次（PerkLog 有 [Died]、user.txt 沒有 died），其中 4 次在屍潮中。

【本補丁】
客戶端在 OnPlayerDeath（只對本地玩家觸發，IsoPlayer.java:6568-6570）送一個指令給伺服器。伺服器只處理寄件者自己的
角色（指令的 player 由連線解析，GameServer.java:2280）：還活著、沒開無敵，就走原版伺服器的死亡路徑——
Kill(nil)（DoDeath 寫 `user … died`、觸發 OnCharacterDeath，IsoPlayer.java:8349-8370、IsoGameCharacter.java:2024-2036）
再 die()（建屍體、把 PlayerDeath 送給附近客戶端，IsoGameCharacter.java:14623-14646、IsoPlayer.java:8372-8381；
伺服器在 hitConsequences 也是直接 die()，IsoGameCharacter.java:6222-6223）。
伺服器自己處理過的死亡（正常路徑）到這裡時 isDead() 已經是真，什麼都不做。
伺服器上的角色出生不到 MIN_SECONDS 秒也不處理：ClientCommand 與 ConnectCoop 都是 RELIABLE、不保證順序
（PacketTypes.java:510、ConnectCoopPacket.java:22-28），正常死亡送出的指令可能在玩家重生之後才到，連線上那時已是
剛建的新角色。伺服器每幀替每位玩家累加存活時數（GameTime.java:539-545）；新角色由伺服器建立、不帶時數，從 0 開始
（CreatePlayerPacket.java:288-302）。換算成遊戲小時時，一遊戲天是沙盒 DayLength 的實際分鐘數（GameTime.getMinutesPerDay，
SandboxOptions.java:410-419、452）。
補處理與擋下各記一行，各自每 session 最多 LOG_LIMIT 行。

【已知限制】
- 只能讓寄件者自己的角色死亡；改過的客戶端可以拿它自殺，結果和被殭屍咬死相同。
- 指令要在玩家建好新角色、送出重生之前送到；網路慢到比這還久時，第一次重生仍會被拒。
- 角色出生不到 MIN_SECONDS 秒就這樣死亡時不補處理，照原版黑畫面（記一行 ignored）。

【退場條件】
官方讓伺服器處理客戶端判定的死亡（拖倒致死不再只靠受害者送命中），或 ConnectCoop 遇到舊角色還活著時改成替它處理死亡。
遊戲更新後跑 `python scripts/check_vanilla_alignment.py`（本修復登記的是 Java 指紋）。
]]

if MDFX_DeathSync then return end

local MODULE, COMMAND = "MinidoracatFixes", "clientDied"
local LOG_LIMIT = 20
local MIN_SECONDS = 30 -- 實際秒數：伺服器上的角色活不到這麼久，就當成重生後才到的舊回報

local function say(message)
    print("[MinidoracatFixes] MDFX_DeathSync " .. message .. " See docs/fixes.md MDFX_DeathSync")
end

if not (Events and Events.OnPlayerDeath and Events.OnPlayerDeath.Add and Events.OnClientCommand
        and Events.OnClientCommand.Add and sendClientCommand and isClient and isServer and getGameTime) then
    say("NOT installed: engine API shape changed; re-check docs/fixes.md.")
    return
end

local G = { handled = 0, ignored = 0 }
MDFX_DeathSync = G

local function note(n, what, message)
    if n <= LOG_LIMIT then
        say(message)
    elseif n == LOG_LIMIT + 1 then
        say("reached LOG_LIMIT for " .. what .. "; they are still handled, not logged this session.")
    end
end

-- 客戶端：本地玩家死了就通知伺服器。伺服器已處理的死亡也會送，由伺服器端判斷。
local function onPlayerDeath(player)
    if isClient() then
        sendClientCommand(player, MODULE, COMMAND, {})
    end
end

-- 伺服器：寄件者的角色還活著、不是剛建的＝伺服器沒處理到這次死亡，照原版伺服器路徑補上。
local function onClientCommand(module, command, player)
    if module ~= MODULE or command ~= COMMAND or not isServer() then return end
    if not player or player:isDead() or player:isGodMod() then return end
    local hours = player:getHoursSurvived()
    local minHours = MIN_SECONDS * 24 / (60 * getGameTime():getMinutesPerDay()) -- 一遊戲天＝getMinutesPerDay() 實際分鐘
    local where = string.format('player="%s" x=%d y=%d z=%d', tostring(player:getUsername()),
        math.floor(player:getX()), math.floor(player:getY()), math.floor(player:getZ()))
    if hours < minHours then
        G.ignored = G.ignored + 1
        note(G.ignored, "ignored reports", string.format(
            "ignored a death report for a character alive %.3f game hours (< %.3f): %s n=%d.", hours, minHours, where, G.ignored))
        return
    end
    player:Kill(nil)
    player:die()
    G.handled = G.handled + 1
    note(G.handled, "processed deaths", string.format("processed a death the server missed: %s n=%d.", where, G.handled))
end

Events.OnPlayerDeath.Add(onPlayerDeath)
Events.OnClientCommand.Add(onClientCommand)
