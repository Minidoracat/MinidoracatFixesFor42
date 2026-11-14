-- MDFX_VehicleSinkGuard 離線自我檢查
-- 用法（repo 根目錄）： lua scripts/test_vehicle_sink_guard.lua [--mutants]
--
-- 假引擎照 42.22.2 反編譯快照的形狀模擬（BaseVehicle 的 jniTransform、授權、setAngles／setWorldTransform，
-- VehicleScript 的停放高度欄位，IsoCell 的車輛集合），驗證：
--   * 本機模擬（Local／LocalCollide）、原點比地板低 0.25 以上、那一格有地板的車放回停放高度，水平位置與方向不變
--   * 翻覆又低於地板一層以上的車先扶正（保留車頭方向）再放回；翻覆而低不到一層的不動
--   * 別人模擬的車、正常的車、只低一點的車、沒有地板的格子、單人遊戲都不動
--   * 停放高度照原版生成車輛的算法，至少 0.1
--   * 已經在地面上的車（例如客戶端修補包同一幀先處理過）不重複介入
--   * 每次介入記一行、有上限；自己出錯時不外洩、只印一次並停用；引擎形狀不符時不安裝
--   * 物理停掉的車（原生 teleportVehicle 不生效）先啟用物理再放回，診斷行記啟用前的狀態
-- --mutants：逐一抽掉每道防線，確認至少一項檢查轉紅。

local SRC_PATH = "MOD/MinidoracatFixesFor42/Contents/mods/MinidoracatFixesFor42/"
    .. "42/media/lua/client/Fixes/MDFX_VehicleSinkGuard.lua"

local function readFile(path)
    local f = assert(io.open(path, "rb"))
    local s = f:read("*a")
    f:close()
    return s
end
local SOURCE = readFile(SRC_PATH)
local realPrint = print
math.atan2 = math.atan2 or math.atan   -- Kahlua 有 atan2；Lua 5.4 併進 atan

local LEVEL = 2.44949
local REST = 0.6      -- 假 M911 的放回高度：輪心在原點下 0.1，輪半徑以守衛的上限 0.5 計

-- ── 假引擎 ─────────────────────────────────────────────────────
local W

local Vec = {}
Vec.__index = Vec
local function vec(x, y, z) return setmetatable({ _x = x or 0, _y = y or 0, _z = z or 0 }, Vec) end
function Vec:x() return self._x end
function Vec:y() return self._y end
function Vec:z() return self._z end
function Vec:set(x, y, z) self._x, self._y, self._z = x, y, z return self end

-- 旋轉只記前向量與朝上程度（守衛只讀這兩樣）
local Xf = {}
Xf.__index = Xf
local function xf() return setmetatable({ origin = vec(), fwd = vec(0, 0, 1), up = 1 }, Xf) end
function Xf:getOrigin() return self.origin end
local function copyXf(from, to)
    to.origin:set(from.origin._x, from.origin._y, from.origin._z)
    to.fwd:set(from.fwd._x, from.fwd._y, from.fwd._z)
    to.up = from.up
end

local Wheel = {}
Wheel.__index = Wheel
function Wheel:getOffset() return self.offset end   -- VehicleScript.Wheel 只有 getId／getOffset，radius 是讀不到的欄位

local Script = {}
Script.__index = Script
function Script:getWheelCount() return #self.wheels end
function Script:getWheel(i) return self.wheels[i + 1] end
function Script:getModelOffset() return self.modelOffset end
function Script:getCenterOfMassOffset() return self.com end
function Script:getExtents() return self.extents end

-- opts：wheels（數量）、wheelY、modelY（nil＝沒有模型）、comY、extY
local function script(opts)
    local s = setmetatable({ wheels = {}, com = vec(0, opts.comY, 0), extents = vec(2, opts.extY, 5) }, Script)
    if opts.modelY then s.modelOffset = vec(0, opts.modelY, 0) end
    for i = 1, opts.wheels do
        s.wheels[i] = setmetatable({ offset = vec(1, opts.wheelY, 1), radius = 0.27 }, Wheel)
    end
    return s
end
local function m911() return script({ wheels = 4, wheelY = -0.1, modelY = 0, comY = 0.2, extY = 1.0 }) end

local Veh = {}
Veh.__index = Veh
function Veh:getScript() return self.script end
function Veh:isLocalPhysicSim()       -- BaseVehicle.java:682-685（客戶端）
    W.calls.isLocalPhysicSim = W.calls.isLocalPhysicSim + 1
    return self.auth == "Local" or self.auth == "LocalCollide"
end
function Veh:getX() return self.x end
function Veh:getY() return self.y end
function Veh:getZ() return self.z end
function Veh:getId() return self.id end
function Veh:getScriptName() return self.name end
function Veh:getAuthorizationDescription() return "auth=" .. self.auth .. (self.idle and " static=true" or "") end
function Veh:setPhysicsActive(active) -- :4170
    self.log[#self.log + 1] = { "setPhysicsActive", active }
    self.idle = not active
end
function Veh:getUpVectorDot() return self.t.up end
function Veh:getWorldTransform(out)   -- :4078
    W.calls.getWorldTransform = W.calls.getWorldTransform + 1
    copyXf(self.t, out)
    return out
end
function Veh:getForwardVector(out) return out:set(self.t.fwd._x, self.t.fwd._y, self.t.fwd._z) end
function Veh:setAngles(ax, ay, az)    -- :4114：只改旋轉，原點不變；物理停掉時原生 teleportVehicle 不生效，下一幀姿勢被讀回
    self.log[#self.log + 1] = { "setAngles", ax, ay, az }
    if self.idle then return end
    if ax == 0 and az == 0 then
        local r = math.rad(ay)
        self.t.fwd:set(math.sin(r), 0, math.cos(r))
        self.t.up = 1
    end
end
function Veh:setWorldTransform(t)     -- :4083
    self.log[#self.log + 1] = { "setWorldTransform" }
    if self.idle then return end
    copyXf(t, self.t)
end

local nextId = 1
-- opts：auth、y（物理高度）、z（樓層，預設 0）、up、yaw（弧度）、fwd（{x,y,z}，蓋過 yaw）、script（false＝沒有）、idle（物理停掉）
local function vehicle(opts)
    local v = setmetatable({ id = nextId, name = opts.name or "Base.M911", auth = opts.auth or "Local",
        x = opts.x or 10.7, y = opts.wy or 20.9, z = opts.z or 0, t = xf(), log = {}, idle = opts.idle }, Veh)
    nextId = nextId + 1
    if opts.script ~= false then v.script = opts.script or m911() end
    local yaw = opts.yaw or 0
    v.t.origin:set(310.7, opts.y, 120.9)
    v.t.fwd:set(math.sin(yaw), 0, math.cos(yaw))
    if opts.fwd then v.t.fwd:set(opts.fwd[1], opts.fwd[2], opts.fwd[3]) end
    v.t.up = opts.up or 1
    W.vehicles[#W.vehicles + 1] = v
    return v
end

local function teleports(v)
    local n = 0
    for _, e in ipairs(v.log) do if e[1] == "setWorldTransform" then n = n + 1 end end
    return n
end
local function angleCalls(v)
    local n = 0
    for _, e in ipairs(v.log) do if e[1] == "setAngles" then n = n + 1 end end
    return n
end

local function floorAt(x, y, z, has) W.squares[x .. "," .. y .. "," .. z] = { has = has ~= false } end

local function printed(needle)
    local n = 0
    for _, line in ipairs(W.prints) do
        if line:find(needle, 1, true) then n = n + 1 end
    end
    return n
end

local function frame()
    for _, fn in ipairs(W.ticks) do fn() end
end

local function newWorld(opts)
    opts = opts or {}
    nextId = 7
    W = { ticks = {}, prints = {}, vehicles = {}, squares = {}, lists = {}, mp = opts.mp ~= false,
        calls = { isLocalPhysicSim = 0, getWorldTransform = 0, getCell = 0, getSquare = 0, xfNew = 0, vecNew = 0 } }
    MDFX_VehicleSinkGuard = nil
    print = function(...)
        local parts = {}
        for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
        W.prints[#W.prints + 1] = table.concat(parts, "\t")
    end
    Events = { OnTick = { Add = function(fn) W.ticks[#W.ticks + 1] = fn end } }
    isClient = function() return W.mp end
    local cell = { getVehicles = function()
        if W.failVehicles then error("boom") end
        return { set = W.vehicles }
    end }
    getCell = function()
        W.calls.getCell = W.calls.getCell + 1
        return cell
    end
    getSquare = function(x, y, z)
        W.calls.getSquare = W.calls.getSquare + 1
        W.lastSquare = x .. "," .. y .. "," .. z
        local s = W.squares[W.lastSquare]
        if not s then return nil end
        return { hasFloor = function() return s.has end }
    end
    ArrayList = { new = function()
        local l = { items = {} }
        function l:addAll(c) for _, v in ipairs(c.set) do self.items[#self.items + 1] = v end end
        function l:size() return #self.items end
        function l:get(i) return self.items[i + 1] end
        function l:clear() self.items = {} end
        W.lists[#W.lists + 1] = l
        return l
    end }
    Transform = { new = function() W.calls.xfNew = W.calls.xfNew + 1 return xf() end }
    Vector3f = { new = function() W.calls.vecNew = W.calls.vecNew + 1 return vec() end }
    floorAt(10, 20, 0)
end

local function near(a, b, eps) return math.abs(a - b) < (eps or 1e-4) end

-- ── 測試套件（mutant 模式重跑同一套）────────────────────────────
local function runSuite(src, quiet)
    local checks, failures = 0, 0
    local function check(label, cond, detail)
        checks = checks + 1
        if not cond then failures = failures + 1 end
        if not quiet then
            realPrint(string.format("  %s  %s%s", cond and "PASS" or "FAIL", label,
                (not cond and detail) and ("  — " .. tostring(detail)) or ""))
        end
    end
    local function section(title) if not quiet then realPrint(title) end end
    local function load()
        local chunk, err = _G.load(src, "=MDFX_VehicleSinkGuard.lua")
        if not chunk then error(err) end
        chunk()
    end
    -- 一台車、跑一幀，回傳車
    local function one(opts, world)
        newWorld(world)
        load()
        local v = vehicle(opts)
        frame()
        return v
    end

    section("1 安裝")
    newWorld()
    load()
    check("1 註冊一個 OnTick", #W.ticks == 1, #W.ticks .. " handlers")
    check("1 安裝時不印訊息", #W.prints == 0, table.concat(W.prints, " | "))
    check("1 有全域統計表", type(MDFX_VehicleSinkGuard) == "table" and MDFX_VehicleSinkGuard.lifted == 0
        and MDFX_VehicleSinkGuard.righted == 0)
    load()
    check("1 同一個 Lua 狀態重複載入不重複註冊", #W.ticks == 1, #W.ticks .. " handlers")

    section("2 形狀不符不安裝")
    newWorld()
    Transform = nil
    load()
    check("2 不註冊 OnTick", #W.ticks == 0)
    check("2 印一行 NOT installed", printed("NOT installed") == 1, table.concat(W.prints, " | "))

    section("3 單人遊戲不啟用")
    local v = one({ y = -0.599 }, { mp = false })
    check("3 地板下的車不動", teleports(v) == 0)
    check("3 不取車輛清單", W.calls.getCell == 0, "getCell=" .. W.calls.getCell)

    section("4 本機模擬、正的車掉到地板下 0.6")
    v = one({ y = -0.599, yaw = 0.7 })
    check("4 放回高度 0.6", near(v.t.origin._y, REST), v.t.origin._y)
    check("4 水平位置不變", v.t.origin._x == 310.7 and v.t.origin._z == 120.9)
    check("4 方向不變、不呼叫 setAngles", angleCalls(v) == 0 and near(v.t.fwd._x, math.sin(0.7)) and v.t.up == 1)
    check("4 只放一次車", teleports(v) == 1, teleports(v))
    check("4 計數 lifted 1、righted 0", MDFX_VehicleSinkGuard.lifted == 1 and MDFX_VehicleSinkGuard.righted == 0)
    check("4 記一行：車、位置、高度", printed("[MinidoracatFixes] MDFX_VehicleSinkGuard vehicle 7 Base.M911 at 10.70,20.90 (auth=Local): "
        .. "physics height -0.599 is below the floor of level 0; lifted to 0.600 (#1).") == 1, table.concat(W.prints, " | "))
    check("4 訊息不寫 flipped", printed("flipped") == 0)
    check("4 查的是車所在那一格", W.lastSquare == "10,20,0", W.lastSquare)
    frame()
    check("4 下一幀高度已正常，不再介入", teleports(v) == 1 and MDFX_VehicleSinkGuard.lifted == 1)
    v = one({ y = -0.599, auth = "LocalCollide" })
    check("4 LocalCollide 的車同樣放回", near(v.t.origin._y, REST) and teleports(v) == 1)
    v = one({ y = -80 })
    check("4 掉到 −80 也放回 0 樓", near(v.t.origin._y, REST))

    section("5 不該動的車")
    for _, auth in ipairs({ "Remote", "RemoteCollide", "Server" }) do
        v = one({ y = -0.599, auth = auth })
        check("5 " .. auth .. " 的車不動", teleports(v) == 0 and v.t.origin._y == -0.599)
    end
    v = one({ y = 0.506 })
    check("5 正常停放不動", teleports(v) == 0)
    v = one({ y = REST })
    check("5 同一幀已被放回地面的車不動（與客戶端修補包並存）", teleports(v) == 0 and #W.prints == 0)
    v = one({ y = -0.109 })
    check("5 地板下 0.109（車頭著地的拖車）不動", teleports(v) == 0)
    v = one({ y = -0.24 })
    check("5 地板下 0.24 不動", teleports(v) == 0)
    v = one({ y = -0.25 })
    check("5 剛好 0.25 不動", teleports(v) == 0)
    v = one({ y = -0.26 })
    check("5 地板下 0.26 放回", teleports(v) == 1)
    v = one({ y = -0.6, up = -1 })
    check("5 翻覆、地板下 0.6 不動", teleports(v) == 0 and angleCalls(v) == 0)
    v = one({ y = -2.4, up = -1 })
    check("5 翻覆、地板下 2.4（不到一層）不動", teleports(v) == 0 and angleCalls(v) == 0)
    v = one({ y = -0.6, up = 0.5 })
    check("5 側翻（up 0.5）、地板下 0.6 不動", teleports(v) == 0)
    v = one({ y = -0.6, up = 0.85 })
    check("5 略傾（up 0.85）不算翻覆，放回且不扶正", teleports(v) == 1 and angleCalls(v) == 0)
    v = one({ y = 0.3, up = -1 })
    check("5 車頂著地不動", teleports(v) == 0)
    newWorld()
    load()
    floorAt(10, 20, 0, false)
    v = vehicle({ y = -0.599 })
    local deep = vehicle({ y = -32, up = -1 })
    frame()
    check("5 那一格沒有地板不動（含翻覆深陷）", teleports(v) == 0 and teleports(deep) == 0 and angleCalls(deep) == 0)
    newWorld()
    load()
    W.squares = {}
    v = vehicle({ y = -0.599 })
    frame()
    check("5 那一格沒載入不動、也不出錯", teleports(v) == 0 and #W.prints == 0, table.concat(W.prints, " | "))
    v = one({ y = -0.599, script = false })
    check("5 沒有 script 的車不動、也不出錯", teleports(v) == 0 and #W.prints == 0, table.concat(W.prints, " | "))

    section("6 翻覆又掉到一層以下")
    v = one({ y = -32, up = -1, yaw = 1.1 })
    check("6 扶正", v.t.up == 1, v.t.up)
    check("6 車頭方向不變", near(v.t.fwd._x, math.sin(1.1)) and near(v.t.fwd._z, math.cos(1.1)),
        v.t.fwd._x .. "," .. v.t.fwd._z)
    check("6 放回停放高度、水平位置不變", near(v.t.origin._y, REST) and v.t.origin._x == 310.7 and v.t.origin._z == 120.9,
        v.t.origin._y)
    check("6 先啟用物理、setAngles(0, 車頭角度, 0)，再放車", #v.log == 3 and v.log[1][1] == "setPhysicsActive" and v.log[1][2] == true
        and v.log[2][1] == "setAngles" and v.log[2][2] == 0 and v.log[2][4] == 0
        and near(v.log[2][3], math.deg(1.1)) and v.log[3][1] == "setWorldTransform")
    check("6 計數 lifted 1、righted 1", MDFX_VehicleSinkGuard.lifted == 1 and MDFX_VehicleSinkGuard.righted == 1)
    check("6 訊息寫明扶正", printed("physics height -32.000 is below the floor of level 0; flipped (up -1.000), "
        .. "set upright keeping its heading, lifted to 0.600 (#1).") == 1, table.concat(W.prints, " | "))
    v = one({ y = -32, up = -1, yaw = -2.5 })
    check("6 車頭朝後方（−2.5 rad）也保留", near(v.t.fwd._x, math.sin(-2.5)) and near(v.t.fwd._z, math.cos(-2.5)))
    v = one({ y = -32, up = 0, fwd = { 0, 1, 0 } })
    check("6 前向量垂直時車頭取 0", v.t.up == 1 and near(v.t.fwd._x, 0) and near(v.t.fwd._z, 1) and near(v.t.origin._y, REST))
    v = one({ y = -LEVEL - 0.01, up = -1 })
    check("6 剛超過一層就處理", teleports(v) == 1 and v.t.up == 1)

    section("7 樓上的地板")
    newWorld()
    load()
    floorAt(10, 20, 1)
    v = vehicle({ y = LEVEL - 0.6, z = 1 })
    frame()
    check("7 一樓的車放回一樓地板以上", near(v.t.origin._y, LEVEL + REST), v.t.origin._y)
    check("7 查的是一樓那一格", W.lastSquare == "10,20,1", W.lastSquare)
    check("7 訊息寫樓層 1", printed("below the floor of level 1; lifted to 3.049") == 1, table.concat(W.prints, " | "))
    v = one({ y = LEVEL - 0.6, z = 0 })
    check("7 同一高度、車在 0 樓時不動", teleports(v) == 0)

    section("8 停放高度")
    v = one({ y = -1, script = script({ wheels = 4, wheelY = -0.1, modelY = -0.2, comY = 0.2, extY = 1.0 }) })
    check("8 模型偏移算進輪底", near(v.t.origin._y, 0.8), v.t.origin._y)
    v = one({ y = -1, script = script({ wheels = 4, wheelY = -0.1, comY = 0.2, extY = 1.0 }) })
    check("8 沒有模型時偏移當 0", near(v.t.origin._y, REST), v.t.origin._y)
    v = one({ y = -1, script = script({ wheels = 4, wheelY = 0, modelY = 0, comY = 0, extY = 1.4 }) })
    check("8 車身底比輪底低時用車身底", near(v.t.origin._y, 0.7), v.t.origin._y)
    v = one({ y = -1, script = script({ wheels = 0, comY = 0.5, extY = 0.6 }) })
    check("8 沒有輪子、算出來是負的拖車放到 0.1", near(v.t.origin._y, 0.1), v.t.origin._y)
    v = one({ y = -1, script = script({ wheels = 2, wheelY = 0.45, modelY = 0, comY = 0.5, extY = 0.9 }) })
    check("8 有輪子但不到 0.1 也放到 0.1", near(v.t.origin._y, 0.1), v.t.origin._y)

    section("9 多台車與每幀成本")
    newWorld()
    load()
    local far = vehicle({ y = -0.599, auth = "Remote" })
    local sunk = vehicle({ y = -0.599 })
    local fine = vehicle({ y = 0.5 })
    frame()
    check("9 只動本機模擬又掉下去的那台", teleports(far) == 0 and teleports(sunk) == 1 and teleports(fine) == 0)
    check("9 每台每幀問一次 isLocalPhysicSim", W.calls.isLocalPhysicSim == 3, W.calls.isLocalPhysicSim)
    check("9 幀末不留住車的參照", #W.lists == 1 and #W.lists[1].items == 0)
    newWorld()
    load()
    for _ = 1, 10 do vehicle({ y = 0.5, auth = "Remote" }) end
    for _ = 1, 100 do frame() end
    check("9 沒有本機模擬的車時每幀只有 10 次 isLocalPhysicSim", W.calls.isLocalPhysicSim == 1000, W.calls.isLocalPhysicSim)
    check("9 不讀任何車的 transform、不查格子", W.calls.getWorldTransform == 0 and W.calls.getSquare == 0)
    check("9 Transform／Vector3f／ArrayList 只在載入時各建一個", W.calls.xfNew == 1 and W.calls.vecNew == 1 and #W.lists == 1,
        W.calls.xfNew .. "/" .. W.calls.vecNew .. "/" .. #W.lists)

    section("10 診斷行上限")
    newWorld()
    load()
    v = vehicle({ y = -5 })
    for _ = 1, 25 do
        v.t.origin._y = -5      -- 模擬放車沒有生效、每幀又在地板下
        frame()
    end
    check("10 25 次都照樣放回", MDFX_VehicleSinkGuard.lifted == 25 and teleports(v) == 25)
    check("10 只記 20 行", printed("MDFX_VehicleSinkGuard vehicle") == 20, printed("MDFX_VehicleSinkGuard vehicle"))
    check("10 第 20 行註明之後不再記", printed("(#20, further events are not logged).") == 1
        and printed("further events are not logged") == 1)

    section("11 自己出錯")
    newWorld()
    load()
    v = vehicle({ y = -0.599 })
    W.failVehicles = true
    local ok = pcall(frame)
    check("11 錯誤不外洩", ok)
    check("11 印一行 disabled", printed("disabled after an internal error") == 1, table.concat(W.prints, " | "))
    W.failVehicles = false
    local calls = W.calls.getCell
    frame()
    frame()
    check("11 之後不再執行（照原版）", W.calls.getCell == calls and teleports(v) == 0 and printed("disabled") == 1)

    section("12 物理停掉的車")
    v = one({ y = -0.599, idle = true })
    check("12 放回高度 0.6、只放一次", near(v.t.origin._y, REST) and teleports(v) == 1, v.t.origin._y)
    check("12 診斷行記啟用物理之前的狀態", printed("(auth=Local static=true): physics height -0.599") == 1, table.concat(W.prints, " | "))
    frame()
    check("12 下一幀不再介入", MDFX_VehicleSinkGuard.lifted == 1)
    v = one({ y = -32, up = -1, yaw = 1.1, idle = true })
    check("12 翻覆的也扶正、放回", v.t.up == 1 and near(v.t.origin._y, REST), v.t.up .. "," .. v.t.origin._y)

    return checks, failures
end

-- ── 主程式 ───────────────────────────────────────────────────────
local MUTANTS = {
    { name = "拿掉防重複載入", subs = { { "if MDFX_VehicleSinkGuard then return end", "" } } },
    { name = "形狀檢查不看 Transform", subs = { { " and Transform and Transform.new", "" } } },
    { name = "單人也啟用", subs = { { "    if not isClient() then return end\n", "" } } },
    { name = "不看是不是本機模擬", subs = { { "if v:isLocalPhysicSim() then", "if true then" } } },
    { name = "門檻放寬到 0.05", subs = { { "local SINK_DEPTH = 0.25 ", "local SINK_DEPTH = 0.05 " } } },
    { name = "門檻收緊到 1.0", subs = { { "local SINK_DEPTH = 0.25 ", "local SINK_DEPTH = 1.0 " } } },
    { name = "剛好在門檻上也算", subs = { { "if not (y < floorY - SINK_DEPTH) then", "if not (y <= floorY - SINK_DEPTH) then" } } },
    { name = "翻覆的車不設一層的條件", subs = {
        { "    if up < MIN_UPRIGHT and not (y < floorY - LEVEL_HEIGHT) then return nil end\n", "" } } },
    { name = "翻覆的車一律不處理", subs = {
        { "if up < MIN_UPRIGHT and not (y < floorY - LEVEL_HEIGHT) then", "if up < MIN_UPRIGHT then" } } },
    { name = "翻覆門檻降到 0.4", subs = { { "local MIN_UPRIGHT = 0.8 ", "local MIN_UPRIGHT = 0.4 " } } },
    { name = "翻覆門檻升到 0.9", subs = { { "local MIN_UPRIGHT = 0.8 ", "local MIN_UPRIGHT = 0.9 " } } },
    { name = "一層的高度寫錯", subs = { { "local LEVEL_HEIGHT = 2.44949 ", "local LEVEL_HEIGHT = 2.3 " } } },
    { name = "不看有沒有地板", subs = { { "if not sq or not sq:hasFloor() then", "if not sq then" } } },
    { name = "格子沒載入就出錯", subs = { { "if not sq or not sq:hasFloor() then", "if not sq:hasFloor() then" } } },
    { name = "不檢查 script", subs = { { "    if not script then return nil end\n", "" } } },
    { name = "樓層一律當 0", subs = { { "local level = floor(v:getZ())", "local level = 0" } } },
    { name = "查格子不取整", subs = { { "getSquare(floor(v:getX()), floor(v:getY()), level)", "getSquare(v:getX(), v:getY(), level)" } } },
    { name = "不扶正", subs = { { "        v:setAngles(0, deg(atan2(f:x(), f:z())), 0)\n", "" } } },
    { name = "車頭角度的 x、z 顛倒", subs = { { "atan2(f:x(), f:z())", "atan2(f:z(), f:x())" } } },
    { name = "車頭角度不轉成度", subs = { { "deg(atan2(f:x(), f:z()))", "atan2(f:x(), f:z())" } } },
    { name = "正的車也扶正", subs = { { "local flipped = up < MIN_UPRIGHT", "local flipped = true" } } },
    { name = "扶正後用舊的 transform 放車", subs = {
        { "local o = v:getWorldTransform(xfrm):getOrigin()\n    o:set", "local o = xfrm:getOrigin()\n    o:set" } } },
    { name = "放車時改到水平位置", subs = { { "o:set(o:x(), to, o:z())", "o:set(0, to, 0)" } } },
    { name = "不放車", subs = { { "    v:setWorldTransform(xfrm)\n", "" } } },
    { name = "停放高度沒有下限", subs = { { "return max(rest, MIN_REST)", "return rest" } } },
    { name = "放回高度不算輪半徑", subs = { { " - WHEEL_RADIUS", "" } } },
    { name = "輪半徑上限改小", subs = { { "local WHEEL_RADIUS = 0.5", "local WHEEL_RADIUS = 0.2" } } },
    { name = "停放高度不算模型偏移", subs = { { "(offset and offset:y() or 0) + ", "" } } },
    { name = "停放高度取輪底與車身底較高的", subs = { { "local rest = -min(wheelBottom,", "local rest = -max(wheelBottom," } } },
    { name = "車身高不除以 2", subs = { { "script:getExtents():y() / 2)", "script:getExtents():y())" } } },
    { name = "診斷行沒有上限", subs = { { "if G.lifted <= LOG_LIMIT then", "if true then" } } },
    { name = "不註明之後不再記", subs = { { "G.lifted == LOG_LIMIT and", "false and" } } },
    { name = "幀末不清清單", subs = { { "    list:clear()\n", "" } } },
    { name = "拿掉 pcall", subs = { { "local ok, err = pcall(tick)", "local ok, err = true, tick()" } } },
    { name = "出錯後不停用", subs = { { "        disabled = true\n", "" } } },
    { name = "放車前不啟用物理", subs = { { "    v:setPhysicsActive(true) -- 物理停掉的車 teleportVehicle 不生效（見檔頭）\n", "" } } },
    { name = "診斷行記啟用物理之後的狀態", subs = { { "v:getX(), v:getY(), auth,", "v:getX(), v:getY(), tostring(v:getAuthorizationDescription())," } } },
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
