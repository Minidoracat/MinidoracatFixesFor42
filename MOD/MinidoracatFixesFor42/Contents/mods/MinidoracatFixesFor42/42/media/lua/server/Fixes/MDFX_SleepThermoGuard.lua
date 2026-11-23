--[[
MDFX_SleepThermoGuard — 一天很長的多人伺服器，全員睡著快轉時體溫模擬失控，舒適溫度下也被 3 級失溫叫醒

【缺陷】（行號為 42.22.2 反編譯快照）
全員睡著時伺服器快轉（GameServer.java:1067-1087），GameTime.getMultiplier()（GameTime.java:963-981）變成
平常的倍率 × FastForwardMultiplier ÷ (30 ÷ 一天的分鐘數)：一天越長倍率越大（伺服器 10 tps、FastForwardMultiplier 40：
預設日長約 583、6 小時約 2316、12 小時約 4644、即時制約 9290）。
體溫模擬每個 tick 拿這個倍率當步長（Thermoregulator.getSimulationMultiplier，Thermoregulator.java:606-620），
核心體溫一步的變化量沒有上限（updateHeatDeltas，:844-881）。42.22 的體溫模擬只在伺服器跑
（BodyDamage.Update，BodyDamage.java:2097-2136）。

【後果】
倍率約 4600 以上時核心體溫每個 tick 上下跳 8～9°C，失溫或中暑到 3 級就被叫醒
（IsoPlayer.updateTemperatureCheck，IsoPlayer.java:7630-7648）：22°C 的室內預定睡 8 小時，
12 小時日長睡 0.91 小時、即時制睡 0.27 小時就醒，醒來體溫 27～28°C。

【本補丁】
伺服器掛 OnTick（IngameState.java:1562）：在這一 tick 原版體溫更新之後、GameServer 決定下一 tick 要不要快轉之前。
1. 全員睡著（同 GameServer.java:1067-1087 的條件，下一 tick 伺服器會快轉）時估下一 tick 的倍率：已經在快轉就是這一 tick 的
   getMultiplier()，剛睡著就再乘上快轉倍率。超過 TRIGGER 就把體溫模擬倍率（Thermoregulator.setSimulationMultiplier，:85，
   全域）設成原值的 1/N（N＝倍率 ÷ STEP_MAX 無條件進位），下一 tick 原版那一步只走 1/N。有人醒著就還原。
   STEP_MAX 取原版預設日長的一步：介入後每一小步約等於絕大多數伺服器平常跑的那一步。N 用上一 tick 的倍率估，
   倍率會浮動（實機：小步 463～587，原版預設日長 570～582）。
2. 上一 tick 設過 1/N：對每位原版會跑體溫模擬的玩家（活著、不是無敵、所在格已載入）再呼叫 N−1 次
   Thermoregulator:update()（:661-674）。每個 tick 模擬的總時間和原版相同，只是切成 N 步；估錯也成立
   （補的步數跟著實際寫進去的 1/N 走）。
補步時把 GameTime 的倍率暫時縮成 EPS 倍、模擬倍率放大 1/EPS 倍（步長是兩者的乘積，不變）：update() 裡另外兩個
只看 GameTime 倍率的計時（體溫變化箭頭 updateCoreRateOfChange :535-544、凍傷與燒傷 updateThermalDamage :626-659）
在補步時幾乎不前進，每個 tick 仍只照原版算一次。原版自己也這樣暫換再還原（AnimatedModel.java:721-742）。

【零行為差異】
有人醒著、或快轉倍率不超過 TRIGGER（伺服器 10 tps、FastForwardMultiplier 用預設的 40 時：一天不到 6 小時）時不寫任何東西。單人與多人客戶端不安裝。
模擬倍率原本不是 1（別的 MOD 或除錯設的）就以它為準、離開時還原；切步期間被別人改掉就停用、不還原。

【已知限制】
- 連線那一 tick 伺服器正好在快轉：新玩家可能多算不到一個 tick 的體溫。
- TRIGGER 落在 6 小時日長的倍率上（名目 2304、實測 2305～2341）：這種伺服器有的 tick 切 5 步、有的不切。
  不切的那些 tick 是原版的一整步：22°C 穩定，35°C 室外體溫會上下擺動約 0.35°C（原版行為，實機 hot35-v9）。
- 凍傷與燒傷的條件（核心體溫這一步沒有回升，:629）看的是原版那一小步，不是整個 tick；體溫單調變化時兩者同號。
- update() 本體丟的 Java 例外不會讓本檔停用（引擎接住後回 nil）；倍率照樣還原。

【診斷】
第一次切步記一行；停用時記一行。

【退場條件】
官方替體溫模擬的步長加上限或自己切步，或快轉倍率不再隨一天的長度放大。
遊戲更新後跑 `python scripts/check_vanilla_alignment.py`。
]]

if MDFX_SleepThermoGuard then return end
if type(isServer) ~= "function" or not isServer() then return end

local function say(message)
    print("[MinidoracatFixes] MDFX_SleepThermoGuard " .. message .. " See docs/fixes.md MDFX_SleepThermoGuard")
end

local event = Events and Events.OnTick
if not (event and event.Add and getOnlinePlayers and getGameTime and getServerOptions
        and Thermoregulator and Thermoregulator.setSimulationMultiplier) then
    say("NOT installed: engine API shape changed; re-check docs/fixes.md.")
    return
end

local TRIGGER = 2304    -- 快轉倍率超過才介入（22°C 實機：原版 3096 以下穩定、4631 以上失控）；使用者同意的範圍
local STEP_MAX = 576    -- 介入後一小步的倍率：約等於原版預設日長的一步（約 583）。35°C 室外實機：一步 1159 平穩、2340 會擺動
local N_MAX = 64        -- 一個 tick 最多切幾步：伺服器卡住時倍率沒有上限，不讓補步的迴圈跟著放大
local EPS = 1 / 1048576 -- 2 的次方：float 乘除不產生誤差

local G = { ticks = 0 } -- ticks＝補過步的 tick 數
MDFX_SleepThermoGuard = G

-- stepN、stepSim＝上一 tick 寫進去、這一 tick 原版用的步數與模擬倍率（寫入後讀回的值）；base＝切步前的模擬倍率
local stepN, stepSim, base = nil, nil, nil
local wasAll = false -- 上一 tick 全員睡著＝這一 tick 伺服器在快轉
local disabled, logged = false, false

local function thermoOf(player)
    local body = player:getBodyDamage()
    return body and body:getThermoregulator()
end

-- 模擬倍率是全域的，讀它要透過任何一位玩家的 Thermoregulator
local function firstThermo(players)
    for i = 0, players:size() - 1 do
        local player = players:get(i)
        local th = player and thermoOf(player)
        if th then return th end
    end
end

-- GameServer 主迴圈在 OnTick 之後用同一組條件決定下一 tick 快不快轉
local function allAsleep(players)
    if getServerOptions():getBoolean("SleepAllowed") ~= true then return false end
    local alive = 0
    for i = 0, players:size() - 1 do
        local player = players:get(i)
        if player and not player:isDead() then
            if not player:isAsleep() then return false end
            alive = alive + 1
        end
    end
    return alive > 0
end

-- 模擬倍率不在這裡還原：tick() 接下來一定重寫（base/N 或 base），出錯時由 fail() 還原
local function substeps(gt, players, keep)
    gt:setMultiplier(keep * EPS)
    Thermoregulator.setSimulationMultiplier(stepSim / EPS)
    for i = 0, players:size() - 1 do
        local player = players:get(i)
        if player and not player:isDead() and not player:isGodMod() and player:getCurrentSquare() then
            local th = thermoOf(player)
            if th then
                for _ = 2, stepN do th:update() end
            end
        end
    end
end

local function fail(err)
    disabled = true
    if stepN then pcall(function() Thermoregulator.setSimulationMultiplier(base) end) end
    stepN = nil
    say("disabled after an internal error (vanilla behaviour from here on): " .. tostring(err) .. ".")
end

local function tick()
    local gt, players = getGameTime(), getOnlinePlayers()
    local m = gt:getMultiplier() -- 這一 tick 原版用的倍率：快轉旗標與 fpsMultiplier 都在 OnTick 之後才更新
    local probe = firstThermo(players)

    if stepN and probe then
        local found = probe:getSimulationMultiplier()
        if found ~= stepSim then
            disabled, stepN = true, nil
            say(string.format("disabled: something else changed the body-temperature simulation multiplier while this guard was sub-stepping (set %s, found %s); left as found.",
                tostring(stepSim), tostring(found)))
            return
        end
        local keep = gt:getTrueMultiplier()
        local ok, err = pcall(substeps, gt, players, keep)
        gt:setMultiplier(keep)
        if not ok then return fail(err) end
        G.ticks = G.ticks + 1
    end

    local all = allAsleep(players)
    local n, nextM = 1, nil
    if all and probe then
        -- 上一 tick 就全員睡著：這一 tick 已在快轉，倍率照用；剛睡著：下一 tick 才開始快轉（GameTime.java:963-981）
        nextM = wasAll and m or m * getServerOptions():getDouble("FastForwardMultiplier") / gt:getDeltaMinutesPerDay()
        n = nextM > TRIGGER and math.min(math.ceil(nextM / STEP_MAX), N_MAX) or 1
    end
    wasAll = all

    if n > 1 then
        if not stepN then base = probe:getSimulationMultiplier() end
        Thermoregulator.setSimulationMultiplier(base / n)
        stepN, stepSim = n, probe:getSimulationMultiplier()
        if not logged then
            logged = true
            say(string.format("is sub-stepping body temperature while everyone sleeps (time multiplier %.0f, %d steps per tick; logged once per session).", nextM, n))
        end
    elseif stepN then
        Thermoregulator.setSimulationMultiplier(base)
        stepN, stepSim, base = nil, nil, nil
    end
end

local function onTick()
    if disabled then return end
    local ok, err = pcall(tick)
    if not ok then fail(err) end
end

event.Add(onTick)
