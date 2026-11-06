-- MDFX_HealthCheatPermission 離線自我檢查
-- 用法（repo 根目錄）： lua scripts/test_health_cheat_permission.lua [--mutants]
--
-- Java 端用 Lua 照 42.21.0 的形狀模擬：
--   * Events.X.Add 是一般表上的函式（Event.java:78-83），引擎依序呼叫登記的函式
--   * getFilenameOfClosure 回函式來源檔（LuaManager.java:7345-7347）；checkPermissions 看寄件者角色（:3054-3063）
--   * getPlayerByOnlineID 的數字轉換（LuaManager.java:3940-3946）
--   * ArrayList.get：非數字丟錯、先轉 int、超出範圍丟 IndexOutOfBounds
--   * 原版分派器（ClientCommands.lua:1296-1305）的形狀：兩個健康作弊指令依 args 處理（:474-627，這裡只模擬 bite 的切換）
-- 驗證：
--   * 只在伺服器安裝；只包原版檔（不含 /mods/）的那一支，其他 MOD 的登記原樣轉交；OnGameBoot 換回 Add，恰好一支才啟用
--   * 沒有 UseHealthCheat：不能改別人也不能改自己，每次記一行（名稱、onlineID、SteamID、目標、action、部位），額度以連線計（SteamID|onlineID，非 Steam 用 onlineID|名稱）
--   * 有權限照原版；壞參數（不是表、找不到玩家、onlineID 不精確、部位不是範圍內整數）一律拒絕、不丟錯
--   * 管理員對別人作弊的轉送：目標客戶端回送的那一筆放行一次，部位、action、自己的 id 都要相符，TICKET_MS 內
--   * 其他指令原樣交給原版；原版的錯誤原樣外洩；自己的檢查出錯時作弊指令拒絕、轉送照原版
--   * log 每個連線上限 LOG_LIMIT，內容去掉控制字元與引號、截長
-- --mutants：逐一抽掉每道防線，確認至少一項檢查轉紅。

local FIX = "MOD/MinidoracatFixesFor42/Contents/mods/MinidoracatFixesFor42/42/media/lua/shared/Fixes/MDFX_HealthCheatPermission.lua"
local VANILLA_PATH = "C:/Zomboid_e2e_pz/ProjectZomboid/media/lua/server/ClientCommands.lua"
local MOD_OVERRIDE = "C:/Zomboid/mods/SomeMod/42/media/lua/server/ClientCommands.lua"
local OTHER_PATH = "C:/Zomboid/mods/Other/42/media/lua/server/OtherCommands.lua"
local VANILLA_OTHER = "C:/Zomboid_e2e_pz/ProjectZomboid/media/lua/server/Vehicles/VehicleCommands.lua"

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

local function intValue(d)
    if d ~= d then return 0 end
    if d >= 2147483647 then return 2147483647 end
    if d <= -2147483648 then return -2147483648 end
    return d >= 0 and math.floor(d) or math.ceil(d)
end

local function toShort(i)
    i = i % 65536
    return i >= 32768 and i - 65536 or i
end

local function newPlayer(name, id, cap, steam)
    local parts = {}
    for i = 0, 16 do parts[i] = { index = i, bitten = false } end
    local list = {}
    function list:size() return 17 end
    function list:get(i)
        if type(i) ~= "number" then error("No implementation found for get(" .. type(i) .. ")") end
        local n = intValue(i)
        if n < 0 or n >= 17 then error("IndexOutOfBoundsException: Index " .. n .. " out of bounds for length 17") end
        return parts[n]
    end
    local body = { getBodyParts = function() return list end }
    local p = { name = name, id = id, cap = cap, steam = steam or 0, parts = parts }
    function p:getUsername() return self.name end
    function p:getOnlineID() return self.id end
    function p:getSteamID() return self.steam end
    function p:getBodyDamage() return body end
    return p
end

local function resetEnv(opts)
    opts = opts or {}
    env = { prints = {}, engine = {}, boot = {}, files = {}, applied = {}, relays = {}, passed = {}, players = {},
        now = 1000000, server = opts.server ~= false }
    local function engineAdd(fn)
        assert(type(fn) == "function", "engine Add takes a closure")
        env.engine[#env.engine + 1] = fn
    end
    env.engineAdd = engineAdd
    Events = {
        OnClientCommand = { Add = engineAdd, Remove = function() end },
        OnGameBoot = { Add = function(fn) env.boot[#env.boot + 1] = fn end },
    }
    isServer = function() return env.server end
    getFilenameOfClosure = function(fn)
        if type(fn) ~= "function" then error("not a closure") end
        return env.files[fn] or "C:/Zomboid/mods/Unknown/42/media/lua/shared/x.lua"
    end
    Capability = { UseHealthCheat = "UseHealthCheat" }
    checkPermissions = function(player, capability)
        assert(capability == "UseHealthCheat")
        return player.cap == true
    end
    getPlayerByOnlineID = function(id)
        return env.players[toShort(intValue(id))]
    end
    getTimestampMs = function() return env.now end
    print = function(...)
        local parts = {}
        for i = 1, select("#", ...) do parts[i] = tostring(select(i, ...)) end
        env.prints[#env.prints + 1] = table.concat(parts, " ")
    end
    MDFX_HealthCheatPermission = nil
end

local function addPlayer(p)
    env.players[p.id] = p
    return p
end

-- 原版 server/ClientCommands.lua 分派器的形狀（只模擬 player 模組的兩個指令；其他指令記下 args 原樣到達）
local function vanillaDispatch(module, command, player, args)
    if module == "boom" then error("vanilla boom") end
    if module ~= "player" or (command ~= "onHealthCheat" and command ~= "onHealthCheatCurrentPlayer") then
        env.passed[#env.passed + 1] = { module = module, command = command, args = args }
        return
    end
    if command == "onHealthCheat" then
        local other = getPlayerByOnlineID(args.id)
        if other and checkPermissions(player, Capability.UseHealthCheat) then
            env.relays[#env.relays + 1] = { to = other, args = args }
        end
        return
    end
    local other = getPlayerByOnlineID(args.id)
    local action = args.action
    local bodyPart = other:getBodyDamage():getBodyParts():get(args.bodyPartIndex)
    if action == "bite" then bodyPart.bitten = not bodyPart.bitten end
    env.applied[#env.applied + 1] = { target = other, part = bodyPart.index, action = action, by = player }
end

local function registerFrom(path, fn)
    env.files[fn] = path
    Events.OnClientCommand.Add(fn)
end

local function boot()
    for _, fn in ipairs(env.boot) do fn() end
end

local function load(src)
    assert(_G.load(src, "=MDFX_HealthCheatPermission.lua"))()
end

-- 標準安裝：伺服器載入本檔 → 原版檔登記分派器 → 另一個 MOD 登記自己的 → OnGameBoot
local function install(src, opts)
    opts = opts or {}
    resetEnv(opts)
    load(src)
    env.other = function() env.otherCalled = (env.otherCalled or 0) + 1 end
    for _ = 1, (opts.vanillaCount or 1) do registerFrom(opts.vanillaPath or VANILLA_PATH, vanillaDispatch) end
    registerFrom(OTHER_PATH, env.other)
    env.vanillaOther = function() end
    registerFrom(VANILLA_OTHER, env.vanillaOther)
    if not opts.noBoot then boot() end
end

-- 伺服器收到客戶端指令：依序交給引擎登記的每個函式，各自 protectedCall（Event.java:24-58）
local function deliver(module, command, player, args)
    local errs = {}
    for _, fn in ipairs(env.engine) do
        local ok, err = pcall(fn, module, command, player, args)
        if not ok then errs[#errs + 1] = tostring(err) end
    end
    return errs
end

local function cheat(player, args) return deliver("player", "onHealthCheatCurrentPlayer", player, args) end

local function printCount(needle)
    local n = 0
    for _, line in ipairs(env.prints) do
        if line:find(needle, 1, true) then n = n + 1 end
    end
    return n
end

local function lastPrint()
    return env.prints[#env.prints] or ""
end

local G = function() return MDFX_HealthCheatPermission or {} end

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
    local A, B, C

    local function players()
        -- SteamID 用浮點數字面值：伺服器 Lua 拿到的是 double（KahluaNumberConverter.java:106、113），tostring 會變科學記號
        A = addPlayer(newPlayer("admin1", 3, true, 76561198033176896.0))
        B = addPlayer(newPlayer("user1", 7, false, 76561198000000016.0))
        C = addPlayer(newPlayer("user2", 9, false, 0))
    end

    section("安裝：只包原版檔那一支，其他 MOD 原樣轉交，OnGameBoot 換回引擎的 Add")
    install(src)
    check("引擎收到三支", #env.engine == 3, "n=" .. #env.engine)
    check("原版那支換成包裝", env.engine[1] ~= vanillaDispatch and type(env.engine[1]) == "function")
    check("其他 MOD 的函式原樣登記", env.engine[2] == env.other)
    check("原版別的檔（VehicleCommands）原樣登記", env.engine[3] == env.vanillaOther)
    check("OnGameBoot 換回引擎的 Add", Events.OnClientCommand.Add == env.engineAdd)
    check("印一行 installed", printCount("MDFX_HealthCheatPermission installed") == 1, table.concat(env.prints, " | "))
    check("沒有 NOT installed", printCount("NOT installed") == 0)

    section("一般帳號：不能改別人，也不能改自己")
    players()
    local errs = cheat(B, { id = A.id, action = "bite", bodyPartIndex = 0 })
    check("A 沒被咬", A.parts[0].bitten == false)
    check("原版沒被呼叫", #env.applied == 0)
    check("不丟錯", #errs == 0, table.concat(errs, " | "))
    check("記一次拒絕", G().denied == 1, tostring(G().denied))
    local line = lastPrint()
    check("log 帶名稱、onlineID、SteamID、目標、action、部位",
        line:find('denied onHealthCheatCurrentPlayer', 1, true) and line:find('player="user1"', 1, true)
        and line:find("onlineID=7", 1, true) and line:find("steamid~76561198000000016", 1, true)
        and line:find("target=3", 1, true) and line:find("action=bite", 1, true) and line:find("part=0", 1, true), line)
    check("log 不寫原版檔名行號", not line:find("ClientCommands.lua:", 1, true))
    check("SteamID 寫完整十進位（不是科學記號）", not line:find("steamid~[%d.]*[eE]"), line)
    cheat(B, { id = B.id, action = "bite", bodyPartIndex = 0 })
    check("B 自己沒被改", B.parts[0].bitten == false and #env.applied == 0)
    check("第二次拒絕", G().denied == 2)
    cheat(C, { id = C.id, action = "bite", bodyPartIndex = 1 })
    check("非 Steam 帳號的 SteamID 寫 none", lastPrint():find("steamid~none", 1, true) ~= nil, lastPrint())
    errs = cheat(B, nil)
    check("一般帳號送沒有參數表：拒絕、不丟錯", #errs == 0 and #env.applied == 0 and G().bad == 1, "bad=" .. tostring(G().bad))

    section("管理員：照原版")
    cheat(A, { id = A.id, action = "bite", bodyPartIndex = 2 })
    check("對自己生效", A.parts[2].bitten == true and #env.applied == 1)
    cheat(A, { id = A.id, action = "bite", bodyPartIndex = 2 })
    check("再送一次切回", A.parts[2].bitten == false and #env.applied == 2)
    cheat(A, { id = B.id, action = "bite", bodyPartIndex = 16 })
    check("對別人生效（最後一個部位）", B.parts[16].bitten == true and #env.applied == 3)
    cheat(A, { id = B.id, action = "bite", bodyPartIndex = 0 })
    check("部位 0 生效", B.parts[0].bitten == true and #env.applied == 4)
    check("管理員不算拒絕", G().denied == 3 and G().bad == 1, "denied=" .. tostring(G().denied) .. " bad=" .. tostring(G().bad))

    section("管理員送壞參數：一律拒絕、不丟錯、原版不被呼叫")
    local BAD = {
        { "沒有參數表", nil },
        { "參數不是表", "x" },
        { "找不到玩家", { id = 30000, action = "bite", bodyPartIndex = 0 } },
        { "id 是字串", { id = "3", action = "bite", bodyPartIndex = 0 } },
        { "id 不是精確的在線 onlineID（小數）", { id = 3.5, action = "bite", bodyPartIndex = 0 } },
        { "id 不是精確的在線 onlineID（超出範圍）", { id = 3 + 65536, action = "bite", bodyPartIndex = 0 } },
        { "id 是 NaN", { id = 0 / 0, action = "bite", bodyPartIndex = 0 } },
        { "部位 = 部位數", { id = A.id, action = "bite", bodyPartIndex = 17 } },
        { "部位 -1", { id = A.id, action = "bite", bodyPartIndex = -1 } },
        { "部位是小數", { id = A.id, action = "bite", bodyPartIndex = 1.5 } },
        { "部位是字串", { id = A.id, action = "bite", bodyPartIndex = "x" } },
        { "沒有部位", { id = A.id, action = "bite" } },
        { "部位是無限大", { id = A.id, action = "bite", bodyPartIndex = 1 / 0 } },
    }
    local applied0, bad0 = #env.applied, G().bad
    for i, case in ipairs(BAD) do
        errs = cheat(A, case[2])
        check("壞參數：" .. case[1], #errs == 0 and #env.applied == applied0 and G().bad == bad0 + i,
            table.concat(errs, " | ") .. " bad=" .. tostring(G().bad))
    end
    check("A 的部位都沒動", A.parts[0].bitten == false and A.parts[1].bitten == false)
    check("壞參數記 bad，log 帶原因", lastPrint():find("bad onHealthCheatCurrentPlayer", 1, true) ~= nil
        and lastPrint():find("body part index out of range", 1, true) ~= nil, lastPrint())

    section("管理員對別人作弊：目標客戶端回送的那一筆放行一次")
    resetEnv()
    install(src)
    players()
    deliver("player", "onHealthCheat", A, { id = B.id, action = "bite", bodyPartIndex = 3 })
    check("原版照常轉送", #env.relays == 1 and env.relays[1].to == B)
    cheat(B, { id = B.id, action = "bite", bodyPartIndex = 3 })
    check("目標回送的那一筆生效", B.parts[3].bitten == true and #env.applied == 1)
    check("記一次轉送放行", G().relayed == 1 and G().denied == 0)
    cheat(B, { id = B.id, action = "bite", bodyPartIndex = 3 })
    check("再送一次（重放）拒絕", B.parts[3].bitten == true and G().denied == 1)

    deliver("player", "onHealthCheat", A, { id = B.id, action = "bite", bodyPartIndex = 4 })
    cheat(B, { id = B.id, action = "bite", bodyPartIndex = 5 })
    check("部位不同：拒絕", B.parts[5].bitten == false and G().denied == 2)
    cheat(B, { id = B.id, action = "bleeding", bodyPartIndex = 4 })
    check("action 不同：拒絕", G().denied == 3 and #env.applied == 1)
    cheat(B, { id = A.id, action = "bite", bodyPartIndex = 4 })
    check("拿票改別人：拒絕", A.parts[4].bitten == false and G().denied == 4)
    cheat(C, { id = C.id, action = "bite", bodyPartIndex = 4 })
    check("別人的票不能用", C.parts[4].bitten == false and G().denied == 5)
    cheat(B, { id = B.id, action = "bite", bodyPartIndex = 4 })
    check("票沒被上面那些用掉：正確的那筆照樣生效", B.parts[4].bitten == true and G().relayed == 2)

    deliver("player", "onHealthCheat", A, { id = B.id, action = "bite", bodyPartIndex = 6 })
    deliver("player", "onHealthCheat", A, { id = B.id, action = "bite", bodyPartIndex = 6 })
    cheat(B, { id = B.id, action = "bite", bodyPartIndex = 6 })
    cheat(B, { id = B.id, action = "bite", bodyPartIndex = 6 })
    check("兩次轉送：兩筆都生效", G().relayed == 4 and B.parts[6].bitten == false and #env.applied == 4)
    cheat(B, { id = B.id, action = "bite", bodyPartIndex = 6 })
    check("第三筆拒絕", G().denied == 6)

    deliver("player", "onHealthCheat", B, { id = C.id, action = "bite", bodyPartIndex = 7 })
    check("一般帳號送 onHealthCheat：原版不轉送", #env.relays == 4)
    cheat(C, { id = C.id, action = "bite", bodyPartIndex = 7 })
    check("沒有票：拒絕", C.parts[7].bitten == false and G().denied == 7)
    deliver("player", "onHealthCheat", A, { id = 30000, action = "bite", bodyPartIndex = 7 })
    errs = deliver("player", "onHealthCheat", A, nil)
    check("onHealthCheat 壞參數照原版（原版的錯原樣外洩）", #errs == 1 and #env.relays == 4, table.concat(errs, " | "))

    section("票的期限：TICKET_MS 內可用，超過拒絕")
    deliver("player", "onHealthCheat", A, { id = B.id, action = "bite", bodyPartIndex = 8 })
    env.now = env.now + 30000
    cheat(B, { id = B.id, action = "bite", bodyPartIndex = 8 })
    check("剛好 TICKET_MS：放行", B.parts[8].bitten == true and G().relayed == 5)
    deliver("player", "onHealthCheat", A, { id = B.id, action = "bite", bodyPartIndex = 9 })
    env.now = env.now + 30001
    cheat(B, { id = B.id, action = "bite", bodyPartIndex = 9 })
    check("超過 TICKET_MS：拒絕", B.parts[9].bitten == false and G().denied == 8)
    deliver("player", "onHealthCheat", A, { id = B.id, action = "bite", bodyPartIndex = 10 })
    env.now = env.now - 1
    cheat(B, { id = B.id, action = "bite", bodyPartIndex = 10 })
    check("時鐘倒退：拒絕", B.parts[10].bitten == false and G().denied == 9)

    section("目標有權限時也用掉票：撤權後不能拿殘留的票重放")
    local D = addPlayer(newPlayer("admin2", 11, true, 0))
    deliver("player", "onHealthCheat", A, { id = D.id, action = "bite", bodyPartIndex = 11 })
    cheat(D, { id = D.id, action = "bite", bodyPartIndex = 11 })
    check("有權限的目標回送照原版", D.parts[11].bitten == true)
    check("有權限的目標不算轉送放行", G().relayed == 5)
    D.cap = false
    cheat(D, { id = D.id, action = "bite", bodyPartIndex = 11 })
    check("撤權後重放同一筆：拒絕", D.parts[11].bitten == true and G().denied == 10, "denied=" .. tostring(G().denied))

    section("其他指令與原版的錯誤")
    resetEnv()
    install(src)
    players()
    local args = { id = A.id, weight = 1 }
    deliver("player", "setWeight", B, args)
    check("其他指令原樣交給原版（同一張參數表）", #env.passed == 1 and env.passed[1].args == args)
    deliver("object", "onHealthCheatCurrentPlayer", B, { id = A.id, action = "bite", bodyPartIndex = 0 })
    check("別的模組同名指令不攔", #env.passed == 2)
    check("其他 MOD 的處理器照樣收到", env.otherCalled == 2)
    errs = deliver("boom", "x", A, {})
    check("原版自己的錯原樣外洩", #errs == 1 and errs[1]:find("vanilla boom", 1, true) ~= nil, table.concat(errs, " | "))

    section("自己的檢查出錯：作弊指令拒絕、轉送照原版，各印一次")
    checkPermissions = function() error("perm boom") end
    errs = cheat(A, { id = A.id, action = "bite", bodyPartIndex = 0 })
    check("作弊指令拒絕、不丟錯", #errs == 0 and #env.applied == 0, table.concat(errs, " | "))
    cheat(A, { id = A.id, action = "bite", bodyPartIndex = 0 })
    check("只印一次", printCount("check for onHealthCheatCurrentPlayer failed") == 1)
    errs = deliver("player", "onHealthCheat", A, { id = B.id, action = "bite", bodyPartIndex = 0 })
    check("轉送照原版（原版的錯原樣外洩）", #errs == 1 and printCount("check for onHealthCheat failed") == 1,
        table.concat(errs, " | "))

    section("log：每個連線上限 LOG_LIMIT，去掉控制字元")
    resetEnv()
    install(src)
    players()
    for _ = 1, 25 do cheat(B, { id = A.id, action = "bite", bodyPartIndex = 0 }) end
    check("B 印 20 行拒絕", printCount('denied onHealthCheatCurrentPlayer (no UseHealthCheat): player="user1"') == 20)
    check("上限提示印一次", printCount('reached LOG_LIMIT for player="user1"') == 1)
    check("超過上限照樣拒絕", G().denied == 25 and #env.applied == 0)
    local B2 = addPlayer(newPlayer("user1-renamed", 7, false, 76561198000000016.0))
    cheat(B2, { id = A.id, action = "bite", bodyPartIndex = 0 })
    check("重生換名（同一個 SteamID）不換額度：照樣拒絕、不再印", G().denied == 26
        and printCount('player="user1-renamed"') == 0, "denied=" .. tostring(G().denied))
    -- ...017 進 double 後和 B 的 ...016 相同（捨入到 16 的倍數）：不同帳號、不同連線
    local F = addPlayer(newPlayer("user9", 11, false, 76561198000000017.0))
    cheat(F, { id = A.id, action = "bite", bodyPartIndex = 0 })
    check("捨入後 SteamID 相同的另一個連線照樣記", printCount('player="user9"') == 1)
    cheat(C, { id = A.id, action = 'bite\n[MinidoracatFixes] fake "x"' .. string.rep("y", 50), bodyPartIndex = 0 })
    line = lastPrint()
    check("別的帳號照樣記", line:find('player="user2"', 1, true) ~= nil, line)
    check("action 去掉換行與引號、截到 32 字", not line:find("\n", 1, true) and not line:find('fake "x"', 1, true)
        and line:find("action=bite?[MinidoracatFixes] fake ?x? part=0", 1, true) ~= nil, line)
    local E = addPlayer(newPlayer('evil\n[MinidoracatFixes] fake "' .. string.rep("z", 40), 13, false, 0))
    for _ = 1, 21 do cheat(E, { id = A.id, action = "bite", bodyPartIndex = 0 }) end
    local evil, reached = 0, 0
    for _, l in ipairs(env.prints) do
        if l:find("evil?[MinidoracatFixes] fake ?", 1, true) then
            evil = evil + 1
            if l:find("reached LOG_LIMIT", 1, true) then reached = reached + 1 end
            if l:find("\n", 1, true) or l:find("zzzzzzzzzzzzzzzzzzzz", 1, true) then evil = -100 end
        end
    end
    check("角色名去掉換行與引號、截長（拒絕行與上限提示都是）", evil == 21 and reached == 1, "evil=" .. evil .. " reached=" .. reached)
    local R = addPlayer(newPlayer("user3", 13, false, 0))
    cheat(R, { id = A.id, action = "bite", bodyPartIndex = 0 })
    check("非 Steam：別人接手同一個 onlineID 照樣記", printCount('player="user3"') == 1)

    section("啟用前（OnGameBoot 之前）照原版")
    install(src, { noBoot = true })
    players()
    cheat(B, { id = A.id, action = "bite", bodyPartIndex = 0 })
    check("還沒啟用：照原版", A.parts[0].bitten == true)

    section("原版檔沒登記、登記兩支、被 MOD 蓋掉：NOT installed，照原版")
    install(src, { vanillaCount = 0 })
    check("沒登記：NOT installed", printCount("saw 0") == 1 and printCount("installed (vanilla") == 0)
    install(src, { vanillaCount = 2 })
    players()
    check("兩支：NOT installed", printCount("saw 2") == 1)
    cheat(B, { id = A.id, action = "bite", bodyPartIndex = 0 })
    check("兩支：不啟用（照原版）", A.parts[0].bitten == false and #env.applied == 2)
    install(src, { vanillaPath = MOD_OVERRIDE })
    check("MOD 蓋掉的 ClientCommands.lua 不包", env.engine[1] == vanillaDispatch and printCount("saw 0") == 1)

    section("只在伺服器；形狀不符不裝；重複載入不疊")
    install(src, { server = false })
    check("客戶端／單人：什麼都不動", env.engine[1] == vanillaDispatch and MDFX_HealthCheatPermission == nil
        and #env.boot == 0 and #env.prints == 0)
    resetEnv()
    getFilenameOfClosure = nil
    load(src)
    check("缺 getFilenameOfClosure：NOT installed、不換 Add", printCount("NOT installed: engine API shape changed") == 1
        and Events.OnClientCommand.Add == env.engineAdd)
    resetEnv()
    load(src)
    load(src)
    registerFrom(VANILLA_PATH, vanillaDispatch)
    boot()
    check("載入兩次：只包一層、只啟用一次", #env.engine == 1 and printCount("installed (vanilla") == 1 and #env.boot == 1)

    print = realPrint
    return checks, failures
end

-- ── 主程式 ───────────────────────────────────────────────────────
local MUTANTS = {
    { name = "不載入修正", whole = true },
    { name = "不看 isServer", from = "if not (type(isServer) == \"function\" and isServer()) then return end", to = "" },
    { name = "不檢查權限", from = "local allowed = permitted(player)", to = "local allowed = true" },
    { name = "票不檢查 args.id 是自己", from = "local relayed = args.id == player:getOnlineID() and takeTicket", to = "local relayed = takeTicket" },
    { name = "有權限時不用掉票", from = "local relayed = args.id == player:getOnlineID() and takeTicket(player, args)\n    local allowed = permitted(player)",
        to = "local allowed = permitted(player)\n    local relayed = not allowed and args.id == player:getOnlineID() and takeTicket(player, args)" },
    { name = "票用了不消耗", from = "            table.remove(list, i)\n            return true", to = "            return true" },
    { name = "票不比部位", from = "list[i].part == args.bodyPartIndex and ", to = "" },
    { name = "票不比 action", from = " and list[i].action == args.action then", to = " then" },
    { name = "票不過期", from = "if age < 0 or age > TICKET_MS then", to = "if false then" },
    { name = "票的期限邊界改成 >=", from = "age > TICKET_MS", to = "age >= TICKET_MS" },
    { name = "時鐘倒退不作廢", from = "if age < 0 or age > TICKET_MS", to = "if age > TICKET_MS" },
    { name = "轉送不看寄件者權限", from = "if target and permitted(player) then", to = "if target then" },
    { name = "不檢查 args 是表", from = "if type(args) ~= \"table\" then return \"bad\", \"args is not a table\" end", to = "" },
    { name = "不檢查 id 是數字", from = "type(args.id) == \"number\" and getPlayerByOnlineID(args.id)", to = "getPlayerByOnlineID(args.id)" },
    { name = "不比對 onlineID 精確相符", from = " or target:getOnlineID() ~= args.id then", to = " then" },
    { name = "部位不檢查整數", from = " and v == math.floor(v)", to = "" },
    { name = "部位不檢查下限", from = " and v >= 0", to = "" },
    { name = "部位上限改成 <=", from = "v < size", to = "v <= size" },
    { name = "轉送放行不計數", from = "if relayed and not allowed then G.relayed = G.relayed + 1 end", to = "" },
    { name = "有權限的回送也算轉送放行", from = "if relayed and not allowed then", to = "if relayed then" },
    { name = "名稱不清理", from = "local who = clip(player:getUsername())", to = "local who = tostring(player:getUsername())" },
    { name = "log 不設上限", from = "if n > LOG_LIMIT + 1 then return end", to = "" },
    { name = "log 上限全服共用", from = "local key = sid ~= \"none\" and (sid .. \"|\" .. id) or (id .. \"|\" .. tostring(player:getUsername()))", to = "local key = \"*\"" },
    { name = "log 額度以名稱計", from = "local key = sid ~= \"none\" and (sid .. \"|\" .. id) or (id .. \"|\" .. tostring(player:getUsername()))", to = "local key = tostring(player:getUsername())" },
    { name = "Steam 額度不看 onlineID", from = "local key = sid ~= \"none\" and (sid .. \"|\" .. id)", to = "local key = sid ~= \"none\" and sid" },
    { name = "非 Steam 額度不看名稱", from = "or (id .. \"|\" .. tostring(player:getUsername()))", to = "or id" },
    { name = "log 不去控制字元", from = "\"[%c\\\"]\"", to = "\"[%z]\"" },
    { name = "log 不截長", from = ", 1, 32))", to = ", 1, 9999))" },
    { name = "SteamID 用 tostring（保留 none）", from = "    local hi = math.floor(v / 1e9)\n", to = "    do return tostring(v) end\n    local hi = math.floor(v / 1e9)\n" },
    { name = "檢查不包 pcall", from = "local ok, pass = pcall(screen, command, player, args)", to = "local ok, pass = true, screen(command, player, args)" },
    { name = "檢查出錯時作弊指令也放行", from = "pass = command ~= CHEAT", to = "pass = true" },
    { name = "啟用前就攔", from = "if active and module == MODULE", to = "if module == MODULE" },
    { name = "不看原版登記幾支", from = "if seen ~= 1 then", to = "if seen == 0 then" },
    { name = "不排除 /mods/", from = " and not string.find(path, \"/mods/\", 1, true)", to = "" },
    { name = "不比對原版檔名", from = "string.sub(path, -#VANILLA_FILE) == VANILLA_FILE and ", to = "" },
    { name = "OnGameBoot 不換回 Add", from = "if event.Add == add then event.Add = engineAdd end", to = "" },
    { name = "拆掉形狀檢查", from = "if not (event and event.Add and", to = "if false and (event and event.Add and" },
    { name = "拆掉重複載入防護", from = "if MDFX_HealthCheatPermission then return end", to = "" },
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
