-- MDFX_BasementVoidGuard 離線自我檢查
-- 用法（repo 根目錄）： lua scripts/test_basement_void_guard.lua [--mutants]
--
-- 假引擎照 42.22.2 反編譯快照的形狀模擬（IsoGridSquare 的 TreatAsSolidFloor／isSolid／isSolidTrans／getChunk，
-- IsoChunk.getMinLevel，IsoMovingObject 的位置、上一幀位置、所在格，IsoGameCharacter 的掉落欄位），驗證：
--   * 本機玩家踏進地面以下、這一格與正下方各層都沒有地板的空格時，放回上一個腳下有地板的位置，掉落取消、所在格換回去
--   * 記下的位置離得太遠（剛登入就在牆外、被傳送進來）時，改放到正上方最近的地板，再不行找地面層 2 格內
--   * 地面以上的半空中、地下樓梯井上方（下方有樓梯或地板）、車上、穿牆、別人的角色、格子沒載入都不動
--   * 按住方向鍵連續被放回只算一次、記一行；每次啟動最多 20 行
--   * 自己出錯時不外洩、只印一次並停用；引擎形狀不符時不安裝
-- --mutants：逐一抽掉每道防線，確認至少一項檢查轉紅。

local SRC_PATH = "MOD/MinidoracatFixesFor42/Contents/mods/MinidoracatFixesFor42/"
    .. "42/media/lua/client/Fixes/MDFX_BasementVoidGuard.lua"

local function readFile(path)
    local f = assert(io.open(path, "rb"))
    local s = f:read("*a")
    f:close()
    return s
end
local SOURCE = readFile(SRC_PATH)
local realPrint = print
local floor = math.floor

-- ── 假引擎 ─────────────────────────────────────────────────────
local W

local Sq = {}
Sq.__index = Sq
function Sq:getX() return self.x end
function Sq:getY() return self.y end
function Sq:getZ() return self.z end
function Sq:TreatAsSolidFloor()    -- IsoGridSquare.java:7704：solidfloor 旗標、樓梯、斜面
    W.calls.floor = W.calls.floor + 1
    return self.floor
end
function Sq:isSolid() return self.solid end
function Sq:isSolidTrans() return self.trans end
function Sq:getChunk()
    if self.nochunk then return nil end
    return { getMinLevel = function() return W.minLevel end }
end

-- opts：floor（預設 true）、solid、trans、nochunk
local function square(x, y, z, opts)
    opts = opts or {}
    local s = setmetatable({ x = x, y = y, z = z, floor = opts.floor ~= false, solid = opts.solid or false,
        trans = opts.trans or false, nochunk = opts.nochunk }, Sq)
    W.squares[x .. "," .. y .. "," .. z] = s
    return s
end
local function at(x, y, z) return W.squares[floor(x) .. "," .. floor(y) .. "," .. floor(z)] end

local Pl = {}
Pl.__index = Pl
function Pl:isLocalPlayer() return self.isLocal end
function Pl:getPlayerNum() return self.num end
function Pl:getVehicle() return self.vehicle end
function Pl:isNoClip() return self.noclip end
function Pl:getCurrentSquare()
    if W.failSquare then error("boom") end
    return self.cur
end
function Pl:getX() return self.x end
function Pl:getY() return self.y end
function Pl:getZ() return self.z end
function Pl:setX(v) self.x = v self.log[#self.log + 1] = "setX" end
function Pl:setY(v) self.y = v self.log[#self.log + 1] = "setY" end
function Pl:setZ(v) self.z = v self.log[#self.log + 1] = "setZ" end
function Pl:setLastX(v) self.lx = v end
function Pl:setLastY(v) self.ly = v end
function Pl:setLastZ(v) self.lz = v end
function Pl:setFallTime(v) self.fallTime = v end
function Pl:setLastFallSpeed(v) self.lastFallSpeed = v end
function Pl:setbFalling(v) self.falling = v end
function Pl:setCurrentSquareFromPosition()   -- IsoMovingObject.java:2040：照目前位置重找所在格
    self.cur = at(self.x, self.y, self.z)
    self.log[#self.log + 1] = "setCurrentSquareFromPosition"
end

local function player(opts)
    opts = opts or {}
    return setmetatable({ num = opts.num or 0, isLocal = opts.isLocal ~= false, vehicle = opts.vehicle, noclip = opts.noclip or false,
        x = 0, y = 0, z = 0, lx = 0, ly = 0, lz = 0, fallTime = 0, lastFallSpeed = 0, falling = false, log = {} }, Pl)
end

-- 引擎那一幀把人移到 (x,y,z)（所在格照位置找），再觸發 OnPlayerUpdate
local function step(p, x, y, z, fall)
    p.x, p.y, p.z = x, y, z
    p.lx, p.ly, p.lz = x, y, z
    p.cur = at(x, y, z)
    if fall then p.fallTime, p.lastFallSpeed, p.falling = 0.1, 0.5, true end
    for _, fn in ipairs(W.handlers) do fn(p) end
end
local function moved(p) return #p.log > 0 end
local function isAt(p, x, y, z)
    return math.abs(p.x - x) < 1e-6 and math.abs(p.y - y) < 1e-6 and math.abs(p.z - z) < 1e-6
end

local function printed(needle)
    local n = 0
    for _, line in ipairs(W.prints) do
        if line:find(needle, 1, true) then n = n + 1 end
    end
    return n
end

-- 回報那棟房子的樣子：廚房（y 11674–11675）在樓梯頂格 (8176,11676) 北邊；地下一層的樓梯頂在它正下方，
-- 房間在東南，牆外是一圈沒有地板的空格
local function newWorld()
    W = { handlers = {}, prints = {}, squares = {}, minLevel = -1, now = 1000000,
        calls = { floor = 0, grid = 0, cell = 0 } }
    MDFX_BasementVoidGuard = nil
    print = function(...)
        local parts = {}
        for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
        W.prints[#W.prints + 1] = table.concat(parts, "\t")
    end
    Events = { OnPlayerUpdate = { Add = function(fn) W.handlers[#W.handlers + 1] = fn end } }
    local cell = { getGridSquare = function(_, x, y, z)
        W.calls.grid = W.calls.grid + 1
        return W.squares[x .. "," .. y .. "," .. z]
    end }
    getCell = function()
        W.calls.cell = W.calls.cell + 1
        return cell
    end
    getTimestampMs = function() return W.now end
    for x = 8170, 8184 do
        for y = 11670, 11675 do square(x, y, 0) end
        square(x, 11675, -1, { floor = false })
    end
    square(8176, 11676, 0)        -- 上樓樓梯頂（樓梯算地板）
    square(8176, 11676, -1)       -- 地下室樓梯頂
    square(8177, 11676, -1)
    square(8175, 11676, -1, { floor = false })
    for x = 8179, 8182 do
        for y = 11676, 11677 do square(x, y, -1) end
    end
end

local KX, KY = 8176.5, 11675.936      -- 廚房南緣，掉下去前一幀的位置
local VX, VY, VZ = 8176.5, 11675.986, -0.053   -- 重現量到的那一幀：高度已是地下，x、y 還在廚房那格

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
        local chunk, err = _G.load(src, "=MDFX_BasementVoidGuard.lua")
        if not chunk then error(err) end
        chunk()
    end
    local function fresh()
        newWorld()
        load()
        return player()
    end
    local G = function() return MDFX_BasementVoidGuard end
    local function where(p) return string.format("%.3f,%.3f,%.3f", p.x, p.y, p.z) end

    section("1 安裝")
    newWorld()
    load()
    check("1 註冊一個 OnPlayerUpdate", #W.handlers == 1, #W.handlers .. " handlers")
    check("1 安裝時不印訊息", #W.prints == 0, table.concat(W.prints, " | "))
    check("1 有全域統計表", type(G()) == "table" and G().putBack == 0 and G().events == 0)
    load()
    check("1 同一個 Lua 狀態重複載入不重複註冊", #W.handlers == 1, #W.handlers .. " handlers")

    section("2 形狀不符不安裝")
    newWorld()
    Events.OnPlayerUpdate = nil
    load()
    check("2 沒有 OnPlayerUpdate：印一行 NOT installed", printed("NOT installed") == 1, table.concat(W.prints, " | "))
    newWorld()
    getTimestampMs = nil
    load()
    check("2 沒有 getTimestampMs：不註冊、印一行 NOT installed", #W.handlers == 0 and printed("NOT installed") == 1)

    section("3 從廚房踏進牆外的那一幀")
    local p = fresh()
    step(p, KX, KY, 0)
    check("3 站在廚房不動", not moved(p))
    step(p, VX, VY, VZ, true)
    check("3 放回上一幀在廚房的位置", isAt(p, KX, KY, 0), where(p))
    check("3 上一幀位置也設成同一點", p.lx == KX and p.ly == KY and p.lz == 0, p.lx .. "," .. p.ly .. "," .. p.lz)
    check("3 掉落取消", p.fallTime == 0 and p.lastFallSpeed == 0 and p.falling == false)
    check("3 所在格換回廚房那一格", p.cur == at(KX, KY, 0) and p.log[#p.log] == "setCurrentSquareFromPosition")
    check("3 計數 putBack 1、events 1", G().putBack == 1 and G().events == 1)
    check("3 記一行：玩家、位置、格子、放回哪裡", printed("[MinidoracatFixes] MDFX_BasementVoidGuard player 0 was below ground at "
        .. "8176.50,11675.99,-0.05 (square 8176,11675,-1) with no floor here or below; put back to 8176.50,11675.94,0.00, "
        .. "the last position on a floor (#1). See docs/fixes.md MDFX_BasementVoidGuard") == 1, table.concat(W.prints, " | "))
    step(p, KX, KY, 0)
    check("3 放回後站在地板上，不再介入", G().putBack == 1 and #W.prints == 1)
    p = fresh()
    step(p, 8176.4, 11676.3, -0.4)     -- 地下室樓梯上
    step(p, 8175.9, 11676.3, -0.45)    -- 往西走出樓梯，到牆外
    check("3 從地下室樓梯走到牆外：放回樓梯上的位置（含高度）", isAt(p, 8176.4, 11676.3, -0.4), where(p))
    check("3 上一幀位置跟著回到樓梯上", p.lx == 8176.4 and p.ly == 11676.3 and p.lz == -0.4, p.lx .. "," .. p.ly .. "," .. p.lz)

    section("4 按住方向鍵：每幀又踏進去")
    p = fresh()
    step(p, KX, KY, 0)
    for _ = 1, 300 do              -- 30 FPS 按住 10 秒
        W.now = W.now + 33
        step(p, VX, VY, VZ)
    end
    check("4 300 次都放回", G().putBack == 300 and isAt(p, KX, KY, 0), G().putBack)
    check("4 算同一次、只記一行", G().events == 1 and printed("was below ground") == 1, G().events)
    W.now = W.now + 4999
    step(p, VX, VY, VZ)
    check("4 隔 4999 ms 再踏進去仍算同一次", G().events == 1)
    W.now = W.now + 5000
    step(p, VX, VY, VZ)
    check("4 隔 5000 ms 算新的一次、記第二行", G().events == 2 and printed("(#2).") == 1, G().events)

    section("5 一進遊戲就在牆外（沒有記下的位置）")
    p = fresh()
    step(p, 8180.3, 11675.7, -1)
    check("5 送到正上方那格的正中央", isAt(p, 8180.5, 11675.5, 0), where(p))
    check("5 所在格是上面那一格、掉落取消", p.cur == at(8180, 11675, 0) and p.lastFallSpeed == 0)
    check("5 訊息寫明是正上方的地板", printed("player 0 was below ground at 8180.30,11675.70,-1.00 (square 8180,11675,-1) with no floor "
        .. "here or below; moved to 8180.50,11675.50,0.00, the nearest floor above (#1).") == 1, table.concat(W.prints, " | "))
    p = fresh()
    W.minLevel = -2
    square(8180, 11675, -2, { floor = false })
    step(p, 8180.5, 11675.5, -2)
    check("5 在地下二層的空格：送到最近的上一層（這裡是地面）", isAt(p, 8180.5, 11675.5, 0), where(p))
    p = fresh()
    W.minLevel = -2
    square(8180, 11675, -2, { floor = false })
    at(8180, 11675, -1).floor = true
    step(p, 8180.5, 11675.5, -2)
    check("5 上一層就有地板時停在上一層，不直接到地面", isAt(p, 8180.5, 11675.5, -1), where(p))

    section("6 正上方站不了：找地面層 2 格內")
    local function blockedAbove(how)
        local q = fresh()
        for x = 8178, 8182 do
            for y = 11673, 11677 do
                local s = at(x, y, 0) or square(x, y, 0)
                s.floor = false
            end
        end
        if how then how() end
        step(q, 8180.5, 11675.5, -1)
        return q
    end
    p = blockedAbove(function() at(8181, 11675, 0).floor = true end)
    check("6 正上方沒有地板：放到隔壁有地板那格的正中央", isAt(p, 8181.5, 11675.5, 0), where(p))
    p = blockedAbove(function()
        at(8180, 11675, 0).floor, at(8180, 11675, 0).solid = true, true
        at(8179, 11674, 0).floor = true
    end)
    check("6 正上方是實心物件：不放那格", isAt(p, 8179.5, 11674.5, 0), where(p))
    p = blockedAbove(function()
        at(8180, 11675, 0).floor, at(8180, 11675, 0).trans = true, true
        at(8179, 11674, 0).floor = true
    end)
    check("6 正上方是家具（solidtrans）：不放那格", isAt(p, 8179.5, 11674.5, 0), where(p))
    p = blockedAbove(function()
        W.squares["8180,11675,0"] = nil
        at(8180, 11676, 0).floor = true
    end)
    check("6 正上方那格沒載入：照樣找鄰格、不出錯", isAt(p, 8180.5, 11676.5, 0) and printed("disabled") == 0, where(p))
    p = blockedAbove(function() at(8182, 11675, 0).floor = true end)
    check("6 只有 2 格外有地板：放到那裡", isAt(p, 8182.5, 11675.5, 0), where(p))
    p = blockedAbove(function()
        at(8182, 11677, 0).floor = true
        at(8181, 11676, 0).floor = true
    end)
    check("6 1 格與 2 格外都有：取近的", isAt(p, 8181.5, 11676.5, 0), where(p))
    p = blockedAbove(function() square(8183, 11675, 0) end)
    check("6 3 格外才有：不動", not moved(p) and G().putBack == 0, where(p))
    check("6 印一行 left alone", printed("with no floor here or below, and no floor was found above or within 2 squares at ground level; left alone.") == 1,
        table.concat(W.prints, " | "))
    step(p, 8180.5, 11675.5, -1)
    step(p, 8180.5, 11675.5, -1)
    check("6 之後每幀照樣不動、不再印", not moved(p) and #W.prints == 1 and printed("disabled") == 0, #W.prints)

    section("7 記下的位置離得太遠")
    local function teleportedIn(gx, gy, vx, vy)
        local q = fresh()
        step(q, gx, gy, 0)
        step(q, vx, vy, -1)
        return q
    end
    p = teleportedIn(8172.5, 11672.5, 8180.5, 11675.5)
    check("7 8 格外：不放回那裡，改送到正上方", isAt(p, 8180.5, 11675.5, 0), where(p))
    check("7 訊息寫 nearest floor above", printed("the nearest floor above") == 1 and printed("the last position") == 0)
    p = teleportedIn(8178.0, 11675.5, 8180.5, 11675.5)
    check("7 只有 x 差 2.5 格：送到正上方", isAt(p, 8180.5, 11675.5, 0), where(p))
    p = teleportedIn(8180.5, 11673.0, 8180.5, 11675.5)
    check("7 只有 y 差 2.5 格：送到正上方", isAt(p, 8180.5, 11675.5, 0), where(p))
    p = teleportedIn(8178.25, 11675.5, 8180.25, 11675.5)
    check("7 x 剛好差 2 格：放回記下的位置", isAt(p, 8178.25, 11675.5, 0), where(p))
    p = teleportedIn(8180.25, 11673.75, 8180.25, 11675.75)
    check("7 y 剛好差 2 格：放回記下的位置", isAt(p, 8180.25, 11673.75, 0), where(p))

    section("8 不該動的情況")
    p = fresh()
    square(8177, 11676, 0, { floor = false })       -- 地面層的洞，正下方是地下室樓梯
    step(p, KX, KY, 0)
    step(p, 8177.5, 11676.1, 0.4)
    check("8 地面以上的半空中不動", not moved(p))
    step(p, VX, VY, VZ)
    check("8 半空中的位置不記：之後踏進牆外放回的是廚房", isAt(p, KX, KY, 0), where(p))
    p = fresh()
    square(8174, 11676, 0, { floor = false })       -- 地面層的洞，正下方什麼都沒有
    step(p, 8174.5, 11676.5, 0)
    check("8 地面層沒地板、下面也沒有：仍不算牆外", not moved(p) and G().putBack == 0)
    p = fresh()
    W.minLevel = -2
    square(8177, 11677, -1, { floor = false })      -- 地下一層的樓梯井
    square(8177, 11677, -2)                         -- 正下方是樓梯
    step(p, 8177.5, 11677.5, -1)
    check("8 地下樓梯井上方（正下方有樓梯）不動", not moved(p))
    p = fresh()
    W.minLevel = -3
    square(8177, 11677, -1, { floor = false })
    square(8177, 11677, -2, { floor = false })
    square(8177, 11677, -3)
    step(p, 8177.5, 11677.5, -1)
    check("8 隔兩層才有地板也不動（一路看到 chunk 最低層）", not moved(p))
    p = fresh()
    W.minLevel = -2                                 -- 同一個 chunk 別處有地下二層，這裡下面沒有格子
    step(p, KX, KY, 0)
    step(p, VX, VY, VZ)
    check("8 下面那層沒有格子：照樣算牆外、不出錯", isAt(p, KX, KY, 0) and printed("disabled") == 0, where(p))
    p = fresh()
    at(8180, 11675, -1).nochunk = true
    step(p, 8180.5, 11675.5, -1)
    check("8 讀不到 chunk 不動、不出錯", not moved(p) and #W.prints == 0, table.concat(W.prints, " | "))
    p = fresh()
    step(p, 8190.5, 11690.5, -1)
    check("8 所在格沒載入不動、不出錯", p.cur == nil and not moved(p) and #W.prints == 0, table.concat(W.prints, " | "))
    p = fresh()
    p.vehicle = {}
    step(p, 8180.5, 11675.5, -1)
    check("8 坐在車上不動", not moved(p))
    p = fresh()
    p.noclip = true
    step(p, 8180.5, 11675.5, -1)
    check("8 開著穿牆不動", not moved(p))
    p = fresh()
    local other = player({ isLocal = false })
    step(other, 8180.5, 11675.5, -1)
    check("8 別人的角色不動", not moved(other) and G().putBack == 0)
    step(p, KX, KY, 0)
    step(other, 8172.5, 11672.5, 0)
    step(p, VX, VY, VZ)
    check("8 別人的角色不改寫本機玩家記下的位置", isAt(p, KX, KY, 0), where(p))

    section("9 分割畫面：每位玩家各記各的")
    newWorld()
    load()
    local a, b = player({ num = 0 }), player({ num = 1 })
    step(a, KX, KY, 0)
    step(b, 8177.25, 11675.5, 0)
    step(a, VX, VY, VZ)
    check("9 玩家 0 回到自己的位置", isAt(a, KX, KY, 0), where(a))
    step(b, 8177.25, 11675.99, -0.05)
    check("9 玩家 1 回到自己的位置", isAt(b, 8177.25, 11675.5, 0), where(b))
    check("9 兩位各算一次、各記一行", G().events == 2 and printed("player 0 was") == 1 and printed("player 1 was") == 1,
        table.concat(W.prints, " | "))

    section("10 診斷行上限")
    p = fresh()
    step(p, KX, KY, 0)
    for _ = 1, 25 do
        W.now = W.now + 6000
        step(p, VX, VY, VZ)
    end
    check("10 25 次都照樣放回", G().putBack == 25 and G().events == 25)
    check("10 只記 20 行", printed("was below ground") == 20, printed("was below ground"))
    check("10 第 20 行註明之後不再記", printed("(#20, further events are not logged).") == 1
        and printed("further events are not logged") == 1)

    section("11 每幀成本")
    p = fresh()
    for _ = 1, 100 do step(p, KX, KY, 0) end
    check("11 站在地板上：每幀只問一次 TreatAsSolidFloor", W.calls.floor == 100, W.calls.floor)
    check("11 不取 cell、不查別的格子", W.calls.cell == 0 and W.calls.grid == 0, W.calls.cell .. "/" .. W.calls.grid)

    section("12 自己出錯")
    p = fresh()
    step(p, KX, KY, 0)
    W.failSquare = true
    local ok = pcall(step, p, VX, VY, VZ)
    check("12 錯誤不外洩", ok)
    check("12 印一行 disabled", printed("disabled after an internal error") == 1, table.concat(W.prints, " | "))
    W.failSquare = false
    step(p, VX, VY, VZ)
    step(p, VX, VY, VZ)
    check("12 之後不再執行（照原版）", not moved(p) and G().putBack == 0 and printed("disabled") == 1)

    return checks, failures
end

-- ── 主程式 ───────────────────────────────────────────────────────
local MUTANTS = {
    { name = "拿掉防重複載入", subs = { { "if MDFX_BasementVoidGuard then return end", "" } } },
    { name = "形狀檢查不看 OnPlayerUpdate", subs = { { "Events.OnPlayerUpdate and Events.OnPlayerUpdate.Add and ", "" } } },
    { name = "形狀檢查不看 getTimestampMs", subs = { { " and getTimestampMs)", ")" } } },
    { name = "不看是不是本機玩家", subs = { { "not p:isLocalPlayer() or ", "" } } },
    { name = "車上也處理", subs = { { "p:getVehicle() or ", "" } } },
    { name = "穿牆也處理", subs = { { " or p:isNoClip()", "" } } },
    { name = "所在格沒載入就出錯", subs = { { "    if not sq then return end\n", "" } } },
    { name = "地面以上沒地板也當牆外", subs = { { "    if z >= 0 then return false end\n", "" } } },
    { name = "地面層（z=0）也算地下", subs = { { "if z >= 0 then return false end", "if z > 0 then return false end" } } },
    { name = "不看正下方有沒有地板", subs = { { "        if below and below:TreatAsSolidFloor() then return false end\n", "" } } },
    { name = "只看正下方一層", subs = { { "for level = z - 1, chunk:getMinLevel(), -1 do", "for level = z - 1, z - 1, -1 do" } } },
    { name = "少看最低那一層", subs = { { "chunk:getMinLevel(), -1 do", "chunk:getMinLevel() + 1, -1 do" } } },
    { name = "讀不到 chunk 就出錯", subs = { { "    if not chunk then return false end\n", "" } } },
    { name = "下方格子沒載入就出錯", subs = { { "if below and below:TreatAsSolidFloor()", "if below:TreatAsSolidFloor()" } } },
    { name = "半空中也記位置", subs = { { "    if sq:TreatAsSolidFloor() then\n        local g = good[n]", "    if sq:getZ() >= 0 then\n        local g = good[n]" } } },
    { name = "記位置不記高度", subs = { { "g[1], g[2], g[3] = p:getX(), p:getY(), p:getZ()", "g[1], g[2], g[3] = p:getX(), p:getY(), 0" } } },
    { name = "每位玩家共用一筆", subs = { { "local n = p:getPlayerNum()", "local n = 0" } } },
    { name = "記下的位置不設距離", subs = { { "if g and abs(g[1] - x) <= NEAR and abs(g[2] - y) <= NEAR then", "if g then" } } },
    { name = "距離不看 x", subs = { { "abs(g[1] - x) <= NEAR and ", "" } } },
    { name = "距離不看 y", subs = { { " and abs(g[2] - y) <= NEAR then", " then" } } },
    { name = "NEAR 改 1", subs = { { "local NEAR = 2 ", "local NEAR = 1 " } } },
    { name = "NEAR 改 3", subs = { { "local NEAR = 2 ", "local NEAR = 3 " } } },
    { name = "x 剛好在界線上不算", subs = { { "abs(g[1] - x) <= NEAR", "abs(g[1] - x) < NEAR" } } },
    { name = "y 剛好在界線上不算", subs = { { "abs(g[2] - y) <= NEAR", "abs(g[2] - y) < NEAR" } } },
    { name = "不找正上方", subs = { { "for z = sq:getZ() + 1, 0 do", "for z = 1, 0 do" } } },
    { name = "正上方只看地面層", subs = { { "for z = sq:getZ() + 1, 0 do", "for z = 0, 0 do" } } },
    { name = "正上方不放正中央", subs = { { "return x + 0.5, y + 0.5, z", "return x, y, z" } } },
    { name = "鄰格不放正中央", subs = { { "return x + dx + 0.5, y + dy + 0.5, 0", "return x + dx, y + dy, 0" } } },
    { name = "不找鄰格", subs = { { "for r = 1, RADIUS do", "for r = 1, 0 do" } } },
    { name = "RADIUS 改 1", subs = { { "local RADIUS = 2 ", "local RADIUS = 1 " } } },
    { name = "RADIUS 改 3", subs = { { "local RADIUS = 2 ", "local RADIUS = 3 " } } },
    { name = "鄰格由遠到近", subs = { { "for r = 1, RADIUS do", "for r = RADIUS, 1, -1 do" } } },
    { name = "落點不看有沒有地板", subs = { { "sq ~= nil and sq:TreatAsSolidFloor() and not sq:isSolid()", "sq ~= nil and not sq:isSolid()" } } },
    { name = "落點不看實心物件", subs = { { " and not sq:isSolid()", "" } } },
    { name = "落點不看家具", subs = { { " and not sq:isSolidTrans()", "" } } },
    { name = "落點沒載入就出錯", subs = { { "return sq ~= nil and sq:TreatAsSolidFloor()", "return sq:TreatAsSolidFloor()" } } },
    { name = "找不到地板不只印一次", subs = { { "if not warnedNowhere then", "if true then" } } },
    { name = "找不到地板照樣放", subs = { { "            warnedNowhere = true\n", "            warnedNowhere = true\n            tx, ty, tz = x, y, 0\n" },
        { "                n, sq:getX(), sq:getY(), sq:getZ(), RADIUS))\n        end\n        return\n",
          "                n, sq:getX(), sq:getY(), sq:getZ(), RADIUS))\n        end\n" } } },
    { name = "不設 x", subs = { { "    p:setX(x)\n", "" } } },
    { name = "不設 y", subs = { { "    p:setY(y)\n", "" } } },
    { name = "不設 z", subs = { { "    p:setZ(z)\n", "" } } },
    { name = "不設上一幀 x", subs = { { "    p:setLastX(x)\n", "" } } },
    { name = "不設上一幀 y", subs = { { "    p:setLastY(y)\n", "" } } },
    { name = "不設上一幀 z", subs = { { "    p:setLastZ(z)\n", "" } } },
    { name = "不清掉落時間", subs = { { "    p:setFallTime(0)\n", "" } } },
    { name = "不清掉落速度", subs = { { "    p:setLastFallSpeed(0)\n", "" } } },
    { name = "不清掉落旗標", subs = { { "    p:setbFalling(false)\n", "" } } },
    { name = "不換所在格", subs = { { "    p:setCurrentSquareFromPosition()\n", "" } } },
    { name = "先換所在格才設位置", subs = { { "    p:setCurrentSquareFromPosition()\n", "" },
        { "    p:setX(x)\n", "    p:setCurrentSquareFromPosition()\n    p:setX(x)\n" } } },
    { name = "放回不計數", subs = { { "    G.putBack = G.putBack + 1\n", "" } } },
    { name = "不記上一次放回的時間", subs = { { "    lastAt[n] = now\n", "" } } },
    { name = "只在記行時更新時間", subs = { { "    lastAt[n] = now\n", "" },
        { "    G.events = G.events + 1\n", "    G.events = G.events + 1\n    lastAt[n] = now\n" } } },
    { name = "間隔改 500 ms", subs = { { "local EVENT_GAP_MS = 5000 ", "local EVENT_GAP_MS = 500 " } } },
    { name = "間隔改 50 秒", subs = { { "local EVENT_GAP_MS = 5000 ", "local EVENT_GAP_MS = 50000 " } } },
    { name = "剛好 5000 ms 仍算同一次", subs = { { "now - last < EVENT_GAP_MS", "now - last <= EVENT_GAP_MS" } } },
    { name = "診斷行沒有上限", subs = { { "if G.events <= LOG_LIMIT then", "if true then" } } },
    { name = "上限改 5", subs = { { "local LOG_LIMIT = 20", "local LOG_LIMIT = 5" } } },
    { name = "不註明之後不再記", subs = { { "G.events == LOG_LIMIT and", "false and" } } },
    { name = "拿掉 pcall", subs = { { "local ok, err = pcall(check, p)", "local ok, err = true, check(p)" } } },
    { name = "出錯後不停用", subs = { { "        disabled = true\n", "" } } },
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
