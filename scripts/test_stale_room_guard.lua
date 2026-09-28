-- MDFX_StaleRoomGuard 離線自我檢查
-- 用法（repo 根目錄）： lua scripts/test_stale_room_guard.lua [--mutants]
--
-- 用假引擎模擬客戶端每一幀的順序（IsoCell.update 讀玩家腳下房間 → IsoRegions.update
-- 交換區域資料並重建房間 → Lua OnTick），驗證：
--   * 房間在靜止玩家腳下／身旁失效時，下一幀之前就修好（靠區域資料交換偵測）
--   * 玩家走進很早以前失效的格子、爬上樓梯時不會踩到沒檢查過的格子
--   * 修法與原版 updateSquares 一致（setRoomID(-1) 後 RecalcProperties），地圖上仍有房間時不動
--   * 探針晚到、移動中取得探針時都會補做一次全面檢查
--   * 沒事時每幀的呼叫量固定（沒有逐格掃描），不留住已離開玩家的參照
--   * 自己出錯時不外洩、只印一次並停用；引擎形狀不符時不安裝
-- --mutants：逐一抽掉每道防線，確認至少一項檢查轉紅。

local SRC_PATH = "MOD/MinidoracatFixesFor42/Contents/mods/MinidoracatFixesFor42/"
    .. "42/media/lua/client/Fixes/MDFX_StaleRoomGuard.lua"

local function readFile(path)
    local f = assert(io.open(path, "rb"))
    local s = f:read("a")
    f:close()
    return s
end
local SOURCE = readFile(SRC_PATH)
local realPrint = print

-- ── 假引擎 ─────────────────────────────────────────────────────
local W

local function key(x, y, z) return x .. "," .. y .. "," .. z end
local function ckey(cx, cy) return cx .. "," .. cy end

local Sq = {}
Sq.__index = Sq
function Sq:getX() return self.x end
function Sq:getY() return self.y end
function Sq:getZ() return self.z end
function Sq:getRoom()
    if self.roomId == -1 then return nil end   -- IsoGridSquare.java:9643-9645
    return self.room
end
function Sq:setRoomID(id)                      -- IsoGridSquare.java:9827-9833
    self.roomId = id
    self.setRoomCalls = self.setRoomCalls + 1
    if id ~= -1 then
        self.exterior = false
        self.room = nil
    end
end
function Sq:RecalcProperties()                 -- IsoGridSquare.java:7703：roomId == -1 且沒屋頂才是室外
    self.recalcCalls = self.recalcCalls + 1
    self.exterior = self.roomId == -1
end

local Room = {}
Room.__index = Room
function Room:getRoomDef() return self.def end

local Player = {}
Player.__index = Player
function Player:getCurrentSquare()
    W.calls.getCurrentSquare = W.calls.getCurrentSquare + 1
    return self.sq
end

local function newList()
    return {
        size = function() W.calls.size = W.calls.size + 1 return #W.players end,
        get = function(_, i) W.calls.get = W.calls.get + 1 return W.players[i + 1] end,
    }
end

local function square(x, y, z)
    local s = setmetatable({ x = x, y = y, z = z, roomId = -1, room = nil, exterior = true,
        setRoomCalls = 0, recalcCalls = 0 }, Sq)
    W.squares[key(x, y, z)] = s
    return s
end

-- 平地 z=0：x/y 0..59
local function ground()
    for x = 0, 59 do
        for y = 0, 59 do square(x, y, 0) end
    end
end

-- 房間（含 z 樓層），同時登記在地圖上
local nextRoomId = 1
local function addRoom(x0, y0, x1, y1, z)
    local room = setmetatable({ def = { id = nextRoomId } }, Room)
    for x = x0, x1 do
        for y = y0, y1 do
            local s = W.squares[key(x, y, z)] or square(x, y, z)
            s.roomId, s.room, s.exterior = nextRoomId, room, false
            W.map[key(x, y, z)] = room.def
        end
    end
    nextRoomId = nextRoomId + 1
    return { room = room, x0 = x0, y0 = y0, x1 = x1, y1 = y1, z = z }
end

-- 原版 removeIsoRoom（WorldRegionToMetaGrid.java:432-434）＋updateSquares 沒走到這些格子
local function removeRoomStale(r)
    r.room.def = nil
    for x = r.x0, r.x1 do
        for y = r.y0, r.y1 do W.map[key(x, y, r.z)] = nil end
    end
end

local function regionChunk(cx, cy)
    local k = ckey(cx, cy)
    W.roots[1][k] = { root = 1, k = k }
    W.roots[2][k] = { root = 2, k = k }
end

local function newPlayer(x, y, z)
    return setmetatable({ sq = W.squares[key(x, y, z)] }, Player)
end
local function moveTo(p, x, y, z) p.sq = W.squares[key(x, y, z)] end

local function allPlayers()
    if W.mp then return W.players end
    return W.locals
end

-- 一幀：玩家移動 → 讀腳下房間（爆點）→ 區域資料交換＋重建 → OnTick
local function frame(move, rebuild)
    if move then move() end
    for _, p in ipairs(allPlayers()) do
        local s = p.sq
        if s and s.roomId ~= -1 and s.room and s.room.def == nil then
            W.crashes = W.crashes + 1
        end
    end
    if rebuild then
        W.root = 3 - W.root
        rebuild()
    end
    for _, fn in ipairs(W.ticks) do fn() end
end

local function newWorld(opts)
    opts = opts or {}
    W = {
        squares = {}, map = {}, roots = { {}, {} }, root = 1,
        players = {}, locals = {}, mp = opts.mp ~= false,
        ticks = {}, prints = {}, crashes = 0,
        calls = { getSquare = 0, getDataChunk = 0, getCurrentSquare = 0, getOnlinePlayers = 0, size = 0, get = 0 },
    }
    W.list = newList()
    W.world = { getMetaGrid = function() return W.meta end }
    W.meta = { getRoomAt = function(_, x, y, z) return W.map[key(x, y, z)] end }

    Events = { OnTick = { Add = function(fn) W.ticks[#W.ticks + 1] = fn end } }
    getSquare = function(x, y, z)
        W.calls.getSquare = W.calls.getSquare + 1
        if W.throwOnGetSquare then error("boom from getSquare") end
        return W.squares[key(x, y, z)]
    end
    getWorld = function() return W.world end
    isClient = function() return W.mp end
    getOnlinePlayers = function() W.calls.getOnlinePlayers = W.calls.getOnlinePlayers + 1 return W.list end
    getNumActivePlayers = function() return #W.locals end
    getSpecificPlayer = function(i) return W.locals[i + 1] end
    IsoRegions = {
        getDataChunk = function(cx, cy)
            W.calls.getDataChunk = W.calls.getDataChunk + 1
            return W.roots[W.root][ckey(cx, cy)]
        end,
    }
    print = function(...)
        local parts = {}
        for i = 1, select("#", ...) do parts[i] = tostring(select(i, ...)) end
        W.prints[#W.prints + 1] = table.concat(parts, " ")
    end
    MDFX_StaleRoomGuard = nil
    ground()
end

local function printed(needle)
    local n = 0
    for _, line in ipairs(W.prints) do
        if line:find(needle, 1, true) then n = n + 1 end
    end
    return n
end

local function resetCalls()
    for k in pairs(W.calls) do W.calls[k] = 0 end
end

-- ── 測試套件（mutant 模式重跑同一套）────────────────────────────
local function runSuite(src, quiet)
    local checks, failures = 0, 0
    local function check(label, cond, detail)
        checks = checks + 1
        if not cond then failures = failures + 1 end
        if not quiet then
            realPrint(string.format("  %s  %s%s", cond and "PASS" or "FAIL", label,
                (not cond and detail) and ("  — " .. detail) or ""))
        end
    end
    local function section(title) if not quiet then realPrint(title) end end
    local function load(ok)
        local chunk, err = _G.load(src, "=MDFX_StaleRoomGuard.lua")
        if not chunk then error(err) end
        chunk()
    end

    -- 1 安裝
    section("1 安裝")
    newWorld()
    load()
    check("1 註冊一個 OnTick", #W.ticks == 1, #W.ticks .. " handlers")
    check("1 安裝時不印訊息", #W.prints == 0, table.concat(W.prints, " | "))
    check("1 有全域統計表", type(MDFX_StaleRoomGuard) == "table" and MDFX_StaleRoomGuard.repaired == 0)
    load()
    check("1 同一個 Lua 狀態重複載入不重複註冊", #W.ticks == 1, #W.ticks .. " handlers")

    -- 2 引擎形狀不符
    section("2 形狀不符不安裝")
    newWorld()
    IsoRegions = nil
    load()
    check("2 不註冊 OnTick", #W.ticks == 0)
    check("2 印一行 NOT installed", printed("NOT installed") == 1, table.concat(W.prints, " | "))

    -- 3 沒事時的成本（效能不變式）
    section("3 靜止時每幀固定成本")
    newWorld()
    load()
    regionChunk(1, 1)
    local ps = {}
    for i = 1, 10 do
        ps[i] = newPlayer(8 + i, 10, 0)
        W.players[i] = ps[i]
    end
    frame()
    local G = MDFX_StaleRoomGuard
    check("3 第一幀檢查全部 10 人", G.verified >= 10, "verified=" .. G.verified)
    frame()
    resetCalls()
    local verified0 = G.verified
    for _ = 1, 100 do frame() end
    check("3 靜止 100 幀零逐格查詢", W.calls.getSquare == 0, "getSquare=" .. W.calls.getSquare)
    check("3 靜止 100 幀不重新檢查", G.verified == verified0, "verified " .. verified0 .. "→" .. G.verified)
    check("3 每幀只問一次探針", W.calls.getDataChunk == 100, "getDataChunk=" .. W.calls.getDataChunk)
    check("3 每人每幀 2 次呼叫（get＋getCurrentSquare）",
        W.calls.get == 1000 and W.calls.getCurrentSquare == 1000,
        "get=" .. W.calls.get .. " getCurrentSquare=" .. W.calls.getCurrentSquare)
    check("3 每幀取一次玩家清單", W.calls.getOnlinePlayers == 100 and W.calls.size == 100)
    resetCalls()
    frame(function() moveTo(ps[1], 9, 11, 0) end)
    check("3 換一格只查 27 格", W.calls.getSquare == 27, "getSquare=" .. W.calls.getSquare)

    -- 4 靜止玩家腳下與身旁的房間失效（正式服實況：拆牆後房間不再封閉）
    section("4 腳下房間失效")
    newWorld()
    load()
    regionChunk(2, 2)
    local r4 = addRoom(20, 20, 22, 22, 0)
    local inside = newPlayer(21, 21, 0)
    local beside = newPlayer(23, 21, 0)
    W.players = { inside, beside }
    frame()
    frame()
    frame(nil, function() removeRoomStale(r4) end)
    frame()
    check("4 站在失效房間裡的玩家下一幀不崩潰", W.crashes == 0, "crashes=" .. W.crashes)
    local s4 = W.squares[key(21, 21, 0)]
    check("4 腳下格子 roomId 重設為 -1", s4.roomId == -1)
    check("4 室外旗標跟著更新（先 setRoomID 再 RecalcProperties）", s4.exterior == true and s4.recalcCalls == 1)
    frame(function() moveTo(beside, 22, 21, 0) end)
    check("4 身旁玩家下一步踏進去也不崩潰", W.crashes == 0, "crashes=" .. W.crashes)
    check("4 修復診斷只印一次", printed("repaired square") == 1, table.concat(W.prints, " | "))
    check("4 統計有記到修復數", MDFX_StaleRoomGuard.repaired >= 2, "repaired=" .. MDFX_StaleRoomGuard.repaired)

    -- 5 走進很早以前失效、當時沒人在旁邊的格子（沒有任何區域資料＝只靠移動檢查）
    section("5 走進舊的失效格子")
    newWorld()
    load()
    local r5a = addRoom(30, 30, 32, 32, 0) -- 東西向穿過
    local r5b = addRoom(40, 40, 42, 42, 0) -- 南北向穿過
    local eastbound = newPlayer(20, 31, 0)
    local northbound = newPlayer(41, 55, 0)
    W.players = { eastbound, northbound }
    frame()
    frame(nil, function() removeRoomStale(r5a); removeRoomStale(r5b) end)
    for step = 1, 16 do
        frame(function()
            moveTo(eastbound, 20 + step, 31, 0)
            moveTo(northbound, 41, 55 - step, 0)
        end)
    end
    check("5 一路走過失效房間不崩潰", W.crashes == 0, "crashes=" .. W.crashes)
    check("5 踩過的格子都修好", W.squares[key(31, 31, 0)].roomId == -1 and W.squares[key(41, 41, 0)].roomId == -1)

    -- 6 走到樓梯口再上樓，一幀內踏進上層的失效房間
    section("6 上下樓")
    newWorld()
    load()
    local r6 = addRoom(40, 40, 42, 42, 1)
    local climber = newPlayer(41, 46, 0)
    W.players = { climber }
    frame()
    frame(nil, function() removeRoomStale(r6) end)
    for y = 45, 41, -1 do frame(function() moveTo(climber, 41, y, 0) end) end
    frame(function() moveTo(climber, 41, 41, 1) end)
    check("6 一幀內換樓層踏進失效格子也不崩潰", W.crashes == 0, "crashes=" .. W.crashes)

    -- 7 區域資料晚到：靜止玩家身旁的格子在看得到探針之前就失效
    section("7 探針晚到")
    newWorld()
    load()
    local r7 = addRoom(10, 13, 12, 15, 0)
    local afk = newPlayer(11, 12, 0) -- 站在房間北邊一格
    W.players = { afk }
    frame()
    frame(nil, function() removeRoomStale(r7) end)
    regionChunk(1, 1)
    for _ = 1, 31 do frame() end
    frame(function() moveTo(afk, 11, 13, 0) end)
    check("7 探針到手後補做全面檢查，靜止玩家之後踏進去不崩潰", W.crashes == 0, "crashes=" .. W.crashes)

    -- 8 移動中取得探針：抵達後馬上就能偵測重建
    section("8 移動中取得探針")
    newWorld()
    load()
    regionChunk(3, 3) -- 只有 x/y 24..31 的區塊有區域資料
    local r8 = addRoom(26, 27, 28, 29, 0)
    local mover = newPlayer(15, 26, 0)
    W.players = { mover }
    frame()                                   -- 第一次找探針（找不到，下次在 30 幀後）
    for x = 16, 27 do frame(function() moveTo(mover, x, 26, 0) end) end
    frame(nil, function() removeRoomStale(r8) end)
    frame(function() moveTo(mover, 27, 27, 0) end)
    check("8 抵達時就取得探針，隨即偵測到重建", W.crashes == 0, "crashes=" .. W.crashes)

    -- 9 地圖上仍有房間：不動、只印一次診斷
    section("9 未登記的形狀")
    newWorld()
    load()
    regionChunk(5, 5)
    local r9 = addRoom(44, 44, 45, 45, 0)
    local watcher = newPlayer(44, 46, 0)
    W.players = { watcher }
    frame()
    frame(nil, function() r9.room.def = nil end) -- 房間失效但地圖還有房間
    local s9 = W.squares[key(44, 45, 0)]
    check("9 不猜 id、不動格子", s9.setRoomCalls == 0 and s9.recalcCalls == 0 and s9.roomId ~= -1)
    check("9 印一次 untouched 診斷", printed("untouched") == 1, table.concat(W.prints, " | "))
    check("9 統計記到 unexpected", MDFX_StaleRoomGuard.unexpected >= 1)

    -- 10 單人：走本地玩家、不取線上清單
    section("10 單人")
    newWorld({ mp = false })
    load()
    regionChunk(2, 2)
    local r10 = addRoom(20, 20, 22, 22, 0)
    local solo = newPlayer(21, 21, 0)
    W.locals = { solo }
    frame()
    frame(nil, function() removeRoomStale(r10) end)
    frame()
    check("10 單人一樣修好", W.crashes == 0 and W.squares[key(21, 21, 0)].roomId == -1)
    check("10 單人不取線上玩家清單", W.calls.getOnlinePlayers == 0)

    -- 11 探針區塊消失：照樣偵測、重新找
    section("11 探針消失")
    newWorld()
    load()
    regionChunk(2, 2)
    regionChunk(1, 2)
    local r11 = addRoom(20, 20, 22, 22, 0)
    local p11 = newPlayer(21, 21, 0)
    W.players = { p11 }
    frame()
    W.roots[1][ckey(2, 2)], W.roots[2][ckey(2, 2)] = nil, nil
    frame()
    for _ = 1, 31 do frame() end
    frame(nil, function() removeRoomStale(r11) end)
    frame()
    check("11 換新探針後仍偵測得到重建", W.crashes == 0, "crashes=" .. W.crashes)

    -- 12 不留住已離開的玩家
    section("12 玩家離開")
    newWorld()
    load()
    local gone = newPlayer(5, 5, 0)
    W.players = { newPlayer(6, 6, 0), gone }
    frame()
    local weak = setmetatable({ gone }, { __mode = "v" })
    W.players = { W.players[1] }
    gone = nil
    frame()
    collectgarbage("collect")
    collectgarbage("collect")
    check("12 離開的玩家可被回收（沒有殘留參照）", weak[1] == nil)

    -- 13 自己出錯：不外洩、只印一次、之後停用
    section("13 自身錯誤")
    newWorld()
    load()
    regionChunk(0, 0)
    local p13 = newPlayer(1, 1, 0)
    W.players = { p13 }
    W.throwOnGetSquare = true
    local ok13 = pcall(frame)
    check("13 例外不外洩到 OnTick", ok13 == true)
    frame()
    check("13 只印一次 disabled", printed("disabled for this session") == 1, table.concat(W.prints, " | "))
    resetCalls()
    frame()
    check("13 停用後零呼叫", W.calls.getDataChunk == 0 and W.calls.getCurrentSquare == 0)

    return checks, failures
end

-- ── 主程式 ───────────────────────────────────────────────────────
local MUTANTS = {
    { name = "拿掉區域資料交換偵測", subs = { { "if dc ~= probe then", "if false then" } } },
    { name = "只查腳下這一格（x）", subs = { { "for xx = x - 1, x + 1 do", "for xx = x, x do" } } },
    { name = "只查腳下這一格（y）", subs = { { "for yy = y - 1, y + 1 do", "for yy = y, y do" } } },
    { name = "只查同一層", subs = { { "for zz = z - 1, z + 1 do", "for zz = z, z do" } } },
    { name = "不看地圖就重設", subs = { { "if getWorld():getMetaGrid():getRoomAt(x, y, z) ~= nil then", "if false then" } } },
    { name = "不跑 RecalcProperties", subs = { { "    s:RecalcProperties()\n", "" } } },
    { name = "先 RecalcProperties 再 setRoomID", subs = {
        { "    s:setRoomID(-1)\n    s:RecalcProperties()\n", "    s:RecalcProperties()\n    s:setRoomID(-1)\n" } } },
    { name = "拿掉 pcall", subs = { { "local ok, err = pcall(tick)", "local ok, err = true, tick()" } } },
    { name = "不清掉離開玩家的格位", subs = {
        { "slotPlayer[i], slotSquare[i], slotCX[i], slotCY[i] = nil, nil, nil, nil", "local _ = i" } } },
    { name = "每幀都全部重查（效能退化）", subs = { { "local resync = false", "local resync = true" } } },
    { name = "探針到手不補查", subs = { { "if not hadProbe and probe ~= nil then", "if false then" } } },
    { name = "不定期找探針", subs = { { "            search()\n", "" } } },
    { name = "移動時不順手取探針", subs = { { "if probe == nil then tryProbe(cx, cy) end", "local _ = cx" } } },
}

local function applySubs(src, subs)
    for _, sub in ipairs(subs) do
        local from, to = sub[1], sub[2]
        local s, e = src:find(from, 1, true)
        if not s then return nil, "pattern not found: " .. from end
        if src:find(from, e + 1, true) then return nil, "pattern not unique: " .. from end
        src = src:sub(1, s - 1) .. to .. src:sub(e + 1)
    end
    return src
end

if arg and arg[1] == "--mutants" then
    local survived, broken = 0, 0
    for _, m in ipairs(MUTANTS) do
        local src, why = applySubs(SOURCE, m.subs)
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
