-- MDFX_DeathSync 離線自我檢查
-- 用法（repo 根目錄）： lua scripts/test_death_sync.lua [--mutants]
--
-- Java 端用 Lua 照 42.21.0 反編譯快照的形狀模擬：
--   * Kill(killer)：setAttackedBy(killer)、血量歸 0；第一次才走 onKilled → DoDeath（寫 user died、觸發 OnCharacterDeath）
--     （IsoGameCharacter.java:14605-14618、IsoPlayer.java:8349-8370）
--   * die()：還沒 Kill 過就先 Kill(getAttackedBy())；伺服器建屍體並送 PlayerDeath，只做一次（IsoGameCharacter.java:14623-14646）
--   * isDead()：血量 <= 0（IsoGameCharacter.java:4913-4915）；getHoursSurvived()：伺服器自己累加的存活遊戲小時（GameTime.java:539-545）
--   * getGameTime():getMinutesPerDay()：一遊戲天的實際分鐘數（沙盒 DayLength，SandboxOptions.java:410-419、452）
--   * sendClientCommand 只送本地玩家（LuaManager.java:8936-8950）；伺服器把指令交給「寄件者連線上的角色」（GameServer.java:2280）
-- 驗證：
--   * 多人客戶端死亡送出指令；單人不送
--   * 伺服器只處理自己的指令、只在寄件者還活著、沒開無敵、出生滿 MIN_SECONDS 秒（依一天長度換成遊戲小時）時補處理：
--     先 Kill(nil) 再 die()，恰一次 DoDeath、一具屍體
--   * 伺服器已處理過的死亡（正常路徑）、重複送達都不做事；重生後才到的舊回報落在新角色身上時擋下並記一行
--   * 補處理與擋下的診斷各自每 session 上限 LOG_LIMIT，超過各印一次提示、照樣處理
--   * 形狀不符印 NOT installed、什麼都不登記；重複載入不疊
-- --mutants：逐一抽掉每道防線，確認至少一項檢查轉紅。

local FIX = "MOD/MinidoracatFixesFor42/Contents/mods/MinidoracatFixesFor42/42/media/lua/shared/Fixes/MDFX_DeathSync.lua"

local realPrint = print

local function readFile(path)
    local f = assert(io.open(path, "rb"))
    local s = f:read("a")
    f:close()
    return s
end

local SOURCE = readFile(FIX)

-- ── 假 Java 端 ─────────────────────────────────────────────────────
local env -- 每個案例重建

local function newEvent()
    local ev = { fns = {} }
    function ev.Add(fn) ev.fns[#ev.fns + 1] = fn end
    return ev
end

local function fire(ev, ...)
    for _, fn in ipairs(ev.fns) do fn(...) end
end

local function newPlayer(name, opts)
    opts = opts or {}
    local p = {
        name = name, health = opts.dead and 0 or 1, god = opts.god or false, attackedBy = opts.attackedBy,
        hours = opts.hours or 100, x = 10722.6, y = 9727.4, z = 0,
        kills = {}, deaths = 0, corpses = 0, killDone = opts.dead or false, deathDone = false, order = {},
    }
    function p:isDead() return self.health <= 0 end
    function p:isGodMod() return self.god end
    function p:getHoursSurvived() return self.hours end
    function p:getX() return self.x end
    function p:getY() return self.y end
    function p:getZ() return self.z end
    function p:getUsername() return self.name end
    function p:getAttackedBy() return self.attackedBy end
    function p:Kill(killer)
        self.kills[#self.kills + 1] = killer == nil and "nil" or killer
        self.order[#self.order + 1] = "Kill"
        self.attackedBy = killer
        self.health = 0
        if not self.killDone then
            self.killDone = true
            self.deaths = self.deaths + 1 -- onKilled → DoDeath
        end
    end
    function p:die()
        self.order[#self.order + 1] = "die"
        if self.deathDone then return end
        if not self.killDone then self:Kill(self.attackedBy) end
        self.deathDone = true
        self.corpses = self.corpses + 1
    end
    return p
end

local function resetEnv(opts)
    opts = opts or {}
    env = { prints = {}, sent = {}, client = opts.client or false, server = opts.server or false }
    Events = {
        OnPlayerDeath = newEvent(),
        OnClientCommand = newEvent(),
    }
    if opts.noClientCommandEvent then Events.OnClientCommand = nil end
    isClient = function() return env.client end
    isServer = function() return env.server end
    env.minutesPerDay = opts.minutesPerDay or 60
    getGameTime = function()
        return { getMinutesPerDay = function() return env.minutesPerDay end }
    end
    if opts.noGameTime then getGameTime = nil end
    sendClientCommand = function(player, module, command, args)
        env.sent[#env.sent + 1] = { player = player, module = module, command = command, args = args }
    end
    if opts.noSend then sendClientCommand = nil end
    print = function(...)
        local parts = {}
        for i = 1, select("#", ...) do parts[i] = tostring(select(i, ...)) end
        env.prints[#env.prints + 1] = table.concat(parts, " ")
    end
    MDFX_DeathSync = nil
end

local function load(src)
    assert(_G.load(src, "=MDFX_DeathSync.lua"))()
end

local function printCount(needle)
    local n = 0
    for _, line in ipairs(env.prints) do
        if line:find(needle, 1, true) then n = n + 1 end
    end
    return n
end

-- 伺服器收到客戶端指令：交給寄件者連線上的角色（GameServer.java:2280-2313）
local function deliver(cmd, serverPlayer)
    fire(Events.OnClientCommand, cmd.module, cmd.command, serverPlayer, cmd.args)
end

local REPORT = { module = "MinidoracatFixes", command = "clientDied", args = {} }

-- ── 測試套件（--mutants 以突變後的原始碼重跑同一套）──────────────────
local function runSuite(src, quiet)
    local checks, failures = 0, 0
    local function check(label, cond, detail)
        checks = checks + 1
        if cond then
            if not quiet then realPrint("  PASS  " .. label) end
        else
            failures = failures + 1
            if not quiet then realPrint("  FAIL  " .. label .. (detail and ("  — " .. detail) or "")) end
        end
    end
    local function section(title)
        if not quiet then realPrint(title) end
    end

    section("多人客戶端：本地玩家死亡送出指令")
    resetEnv({ client = true })
    load(src)
    local me = newPlayer("test")
    fire(Events.OnPlayerDeath, me)
    check("送出一個指令", #env.sent == 1, "sent=" .. #env.sent)
    local cmd = env.sent[1] or {}
    check("寄件者是死亡的本地玩家", cmd.player == me)
    check("指令帶參數表", type(cmd.args) == "table")
    check("客戶端不碰自己的角色", #me.kills == 0 and me.corpses == 0)

    section("單人：不送指令")
    resetEnv({ client = false, server = false })
    load(src)
    fire(Events.OnPlayerDeath, newPlayer("solo"))
    check("單人死亡不送指令", #env.sent == 0, "sent=" .. #env.sent)

    section("往返：客戶端單方面死亡 → 伺服器補處理")
    resetEnv({ client = true })
    load(src)
    fire(Events.OnPlayerDeath, newPlayer("test"))
    local sent = env.sent[1]
    resetEnv({ server = true })
    load(src)
    local zombie = { zombie = true }
    local srv = newPlayer("test", { attackedBy = zombie })
    deliver(sent, srv)
    check("伺服器角色死亡", srv:isDead())
    check("Kill 恰一次、不帶攻擊者（不歸給上一個攻擊者）", #srv.kills == 1 and srv.kills[1] == "nil",
        "kills=" .. #srv.kills .. " first=" .. tostring(srv.kills[1]))
    check("先 Kill 再 die", srv.order[1] == "Kill" and srv.order[2] == "die", table.concat(srv.order, ","))
    check("DoDeath 恰一次（user died、OnCharacterDeath）", srv.deaths == 1, "deaths=" .. srv.deaths)
    check("建一具屍體", srv.corpses == 1, "corpses=" .. srv.corpses)
    check("診斷一行，帶玩家與座標", printCount('processed a death the server missed: player="test" x=10722 y=9727 z=0 n=1.') == 1,
        table.concat(env.prints, " | "))
    check("計數", MDFX_DeathSync and MDFX_DeathSync.handled == 1)
    deliver(sent, srv)
    check("重複送達不再處理", #srv.kills == 1 and srv.corpses == 1 and srv.deaths == 1)
    check("重複送達不再記錄", printCount("processed a death") == 1)

    section("伺服器：正常路徑（伺服器已處理死亡）不做事")
    resetEnv({ server = true })
    load(src)
    local done = newPlayer("test2", { dead = true })
    deliver(REPORT, done)
    check("已死亡的角色不再 Kill／die", #done.kills == 0 and #done.order == 0, table.concat(done.order, ","))
    check("不記錄", #env.prints == 0, table.concat(env.prints, " | "))

    section("伺服器：開無敵的角色不處理")
    local god = newPlayer("admin", { god = true })
    deliver(REPORT, god)
    check("無敵角色不 Kill／die", #god.order == 0 and not god:isDead())

    section("伺服器：只處理自己的指令")
    local other = newPlayer("other")
    deliver({ module = "MinidoracatFixes", command = "somethingElse", args = {} }, other)
    deliver({ module = "OtherMod", command = "clientDied", args = {} }, other)
    check("別的指令不碰角色", #other.order == 0 and not other:isDead())
    local ok = pcall(deliver, REPORT, nil)
    check("寄件者是 nil 時不拋錯", ok)

    section("伺服器：重生後才到的舊回報落在新角色身上")
    resetEnv({ server = true })
    load(src)
    -- 舊角色由原版正常處理死亡；玩家重生，同一個連線座位換成新角色；舊回報這時才送到
    local old = newPlayer("respawner", { dead = true, hours = 500 })
    local fresh = newPlayer("respawner", { hours = 0.02 })
    deliver(REPORT, fresh)
    check("新角色不 Kill／die、仍活著", #fresh.order == 0 and not fresh:isDead(), table.concat(fresh.order, ","))
    check("舊角色不受影響", #old.order == 0)
    -- 一天 60 分鐘：30 秒＝0.2 遊戲小時
    check("擋下記一行，帶存活時數、門檻與玩家",
        printCount('ignored a death report for a character alive 0.020 game hours (< 0.200): player="respawner"') == 1,
        table.concat(env.prints, " | "))
    check("擋下計數", MDFX_DeathSync and MDFX_DeathSync.ignored == 1 and MDFX_DeathSync.handled == 0)
    local edge = newPlayer("edge", { hours = 0.1999 })
    deliver(REPORT, edge)
    check("差一點滿 30 秒也擋下", #edge.order == 0 and not edge:isDead())
    local exact = newPlayer("exact", { hours = 0.2 })
    deliver(REPORT, exact)
    check("剛好滿 30 秒就補處理", exact.corpses == 1)

    section("伺服器：門檻依一天長度換算，固定是實際 30 秒")
    resetEnv({ server = true, minutesPerDay = 15 })
    load(src)
    -- 一天 15 分鐘：30 秒＝0.8 遊戲小時
    local fast = newPlayer("fast", { hours = 0.5 })
    deliver(REPORT, fast)
    check("一天 15 分鐘：0.5 遊戲小時（約 19 秒）擋下", #fast.order == 0 and not fast:isDead())
    resetEnv({ server = true, minutesPerDay = 1440 })
    load(src)
    -- 一天 24 小時：30 秒＝0.0083 遊戲小時
    local slow = newPlayer("slow", { hours = 0.02 })
    deliver(REPORT, slow)
    check("一天 24 小時：0.02 遊戲小時（72 秒）補處理", slow.corpses == 1)

    section("不是伺服器時收到指令不做事（單人的 SinglePlayerServer 也會觸發 OnClientCommand）")
    resetEnv({ client = false, server = false })
    load(src)
    local spPlayer = newPlayer("solo")
    deliver(REPORT, spPlayer)
    check("單人不 Kill／die", #spPlayer.order == 0)

    section("診斷上限：補處理與擋下各自 LOG_LIMIT 行，超過各印一次提示、照樣處理")
    resetEnv({ server = true })
    load(src)
    for i = 1, 25 do deliver(REPORT, newPlayer("new" .. i, { hours = 0 })) end
    check("擋下 20 行", printCount("ignored a death report") == 20, "lines=" .. printCount("ignored a death report"))
    check("擋下的上限提示一次", printCount("reached LOG_LIMIT for ignored reports") == 1)
    local after = newPlayer("after")
    deliver(REPORT, after)
    check("擋下滿了，補處理照樣記", after.corpses == 1 and printCount("processed a death") == 1)
    local all = 1
    for i = 1, 24 do
        local p = newPlayer("p" .. i)
        deliver(REPORT, p)
        if p.corpses == 1 then all = all + 1 end
    end
    check("25 次都補處理", all == 25, "handled=" .. all)
    check("補處理 20 行", printCount("processed a death") == 20, "lines=" .. printCount("processed a death"))
    check("補處理的上限提示一次", printCount("reached LOG_LIMIT for processed deaths") == 1)

    section("形狀不符：印 NOT installed、什麼都不登記")
    resetEnv({ server = true, noClientCommandEvent = true })
    load(src)
    check("缺 OnClientCommand：印 NOT installed", printCount("NOT installed") == 1)
    check("缺 OnClientCommand：不登記死亡事件", #Events.OnPlayerDeath.fns == 0)
    check("缺 OnClientCommand：沒有全域表", MDFX_DeathSync == nil)
    resetEnv({ client = true, noSend = true })
    load(src)
    check("缺 sendClientCommand：印 NOT installed", printCount("NOT installed") == 1)
    check("缺 sendClientCommand：不登記", #Events.OnPlayerDeath.fns == 0 and #Events.OnClientCommand.fns == 0)
    resetEnv({ server = true, noGameTime = true })
    load(src)
    check("缺 getGameTime：印 NOT installed", printCount("NOT installed") == 1)
    check("缺 getGameTime：不登記", #Events.OnPlayerDeath.fns == 0 and #Events.OnClientCommand.fns == 0)

    section("重複載入不疊")
    resetEnv({ server = true })
    load(src)
    load(src)
    check("兩個事件各只登記一次", #Events.OnPlayerDeath.fns == 1 and #Events.OnClientCommand.fns == 1,
        #Events.OnPlayerDeath.fns .. "/" .. #Events.OnClientCommand.fns)

    print = realPrint
    return checks, failures
end

-- ── 主程式 ───────────────────────────────────────────────────────
local MUTANTS = {
    { name = "不載入修正", whole = true },
    { name = "客戶端不看 isClient（單人也送）", from = "    if isClient() then", to = "    if true then" },
    { name = "客戶端不帶參數表", from = "sendClientCommand(player, MODULE, COMMAND, {})", to = "sendClientCommand(player, MODULE, COMMAND, nil)" },
    { name = "伺服器不看 isServer", from = " or not isServer() then return end", to = " then return end" },
    { name = "不比對 module", from = "if module ~= MODULE or ", to = "if " },
    { name = "不比對 command", from = " or command ~= COMMAND or ", to = " or " },
    { name = "不檢查寄件者 nil", from = "if not player or player:isDead()", to = "if player:isDead()" },
    { name = "已死亡也處理", from = " or player:isDead() or ", to = " or " },
    { name = "無敵也處理", from = " or player:isGodMod() then return end", to = " then return end" },
    { name = "不檢查角色存活時數（重生後的舊回報會殺掉新角色）", from = "    if hours < minHours then", to = "    if false then" },
    { name = "存活時數邊界改成 <=", from = "    if hours < minHours then", to = "    if hours <= minHours then" },
    { name = "不依一天長度換算", from = "(60 * getGameTime():getMinutesPerDay())", to = "(60 * 60)" },
    { name = "換算方向寫反", from = "MIN_SECONDS * 24 / (60 * getGameTime():getMinutesPerDay())",
        to = "MIN_SECONDS * (60 * getGameTime():getMinutesPerDay()) / 24 / 3600" },
    { name = "形狀檢查不看 getGameTime", from = " and isServer and getGameTime) then", to = " and isServer) then" },
    { name = "只 die 不先 Kill(nil)", from = "    player:Kill(nil)\n", to = "" },
    { name = "Kill 帶上一個攻擊者", from = "player:Kill(nil)", to = "player:Kill(player:getAttackedBy())" },
    { name = "只 Kill 不 die（沒有屍體）", from = "    player:die()\n", to = "" },
    { name = "診斷不設上限", from = "    if n <= LOG_LIMIT then", to = "    if true then" },
    { name = "不印上限提示", from = "    elseif n == LOG_LIMIT + 1 then", to = "    elseif false then" },
    { name = "補處理與擋下共用上限", from = "note(G.handled, ", to = "note(G.handled + G.ignored, " },
    { name = "補處理不計數", from = "    G.handled = G.handled + 1\n", to = "" },
    { name = "擋下不計數", from = "        G.ignored = G.ignored + 1\n", to = "" },
    { name = "擋下不記錄", from = "        note(G.ignored, ", to = "        (function() end)(G.ignored, " },
    { name = "拆掉形狀檢查", from = "if not (Events and Events.OnPlayerDeath", to = "if false and (Events and Events.OnPlayerDeath" },
    { name = "拆掉重複載入防護", from = "if MDFX_DeathSync then return end", to = "" },
}

local function replaceOnce(src, from, to)
    local s, e = src:find(from, 1, true)
    if not s then return nil, "pattern not found: " .. from end
    if src:find(from, e + 1, true) then return nil, "pattern not unique: " .. from end
    return src:sub(1, s - 1) .. to .. src:sub(e + 1)
end

if arg and arg[1] == "--mutants" then
    local survived, broken = 0, 0
    for _, m in ipairs(MUTANTS) do
        local src, why
        if m.whole then src = "" else src, why = replaceOnce(SOURCE, m.from, m.to) end
        if not src then
            broken = broken + 1
            realPrint("  BROKEN    " .. m.name .. " — " .. why)
        else
            local ok, checks, failures = pcall(runSuite, src, true)
            print = realPrint
            if ok and failures == 0 then
                survived = survived + 1
                realPrint(string.format("  SURVIVED  %s（%d 項全綠）", m.name, checks))
            else
                realPrint(string.format("  KILLED    %s（%s）", m.name,
                    ok and (failures .. "/" .. checks .. " 項轉紅") or ("拋錯 " .. tostring(checks))))
            end
        end
    end
    realPrint("")
    realPrint(string.format("%d mutants, %d survived, %d broken", #MUTANTS, survived, broken))
    os.exit((survived == 0 and broken == 0) and 0 or 1)
end

local checks, failures = runSuite(SOURCE, false)
print = realPrint
realPrint("")
realPrint(string.format("%d checks, %d failed", checks, failures))
os.exit(failures == 0 and 0 or 1)
