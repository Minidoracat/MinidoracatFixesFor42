-- MDFX_HutchNullSlotGuard 離線自我檢查
-- 用法（repo 根目錄）： lua scripts/test_hutch_null_slot_guard.lua [--mutants]
--
-- 假引擎照客戶端每一幀的順序跑（GameClient.update 處理動物封包＝寫入 null → IngameState 的
-- ProcessChunkPos 卸載雞舍＝IsoHutch.removeFromWorld 走過 values() → Lua OnTick），驗證：
--   * 母雞進巢箱、換格留下的 null 在下一次卸載前清掉，卸載不崩潰；活的母雞、巢箱、屍體都不動
--   * Integer key 經過 Lua 變成 double：HashMap.remove(double) 對不到，必須走 IsoHutch.removeAnimal
--   * 雞舍登記只靠 MapObjects 圖塊分派與 OnObjectAdded；只登記封包會解析到的那一座
--   * 沒事時每幀每座雞舍一次 containsValue；單人與沒有雞舍時零成本；卸載的雞舍會放掉
--   * 自己出錯時不外洩、只印一次並停用；引擎形狀不符時不安裝
-- --mutants：逐一抽掉每道防線，確認至少一項檢查轉紅。

local SRC_PATH = "MOD/MinidoracatFixesFor42/Contents/mods/MinidoracatFixesFor42/"
    .. "42/media/lua/client/Fixes/MDFX_HutchNullSlotGuard.lua"

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
local NULL = setmetatable({}, { __tostring = function() return "null" end })

-- java.util.HashMap<Integer, IsoAnimal>：key 是 Integer。Lua 傳進來的數字一律是 double
-- （KahluaNumberConverter），對 Object 參數不轉型，所以 get／remove(double) 對不到任何 key。
local JMap = {}
JMap.__index = JMap
local function newMap() return setmetatable({ e = {} }, JMap) end
function JMap:jput(k, v) self.e[k] = (v == nil) and NULL or v end
-- sticky：模擬不是 Integer 的 key（例如別的 MOD 從 Lua 以數字 put 進來的 Double key），IsoHutch.removeAnimal 刪不到
function JMap:jremove(k) if not (self.sticky and self.sticky[k]) then self.e[k] = nil end end
function JMap:jget(k) local v = self.e[k]; if v == NULL then return nil end return v end
function JMap:get(_) W.calls.mapGet = W.calls.mapGet + 1 return nil end
function JMap:remove(_) W.calls.mapRemove = W.calls.mapRemove + 1 return nil end
function JMap:size()
    local n = 0
    for _ in pairs(self.e) do n = n + 1 end
    return n
end
function JMap:containsValue(v)
    W.calls.containsValue = W.calls.containsValue + 1
    if W.throwOnContains then error("boom from containsValue") end
    for _, x in pairs(self.e) do
        if (v == nil and x == NULL) or x == v then return true end
    end
    return false
end
function JMap:keySet()
    W.calls.keySet = W.calls.keySet + 1
    local ks = {}
    for k in pairs(self.e) do ks[#ks + 1] = k end
    table.sort(ks)
    return { _items = ks }
end
function JMap:values()
    local vs = {}
    for _, x in pairs(self.e) do vs[#vs + 1] = x end
    return { _items = vs }
end

local AList = {}
AList.__index = AList
local function newList() return setmetatable({ items = {}, n = 0 }, AList) end
function AList:clear() self.items, self.n = {}, 0 end
function AList:addAll(coll)
    for _, v in ipairs(coll._items) do
        self.n = self.n + 1
        self.items[self.n] = v
    end
end
function AList:size() return self.n end
function AList:get(i)
    local v = self.items[i + 1]
    if v == NULL then return nil end
    return v
end

local Animal = {}
Animal.__index = Animal
local function newAnimal(name)
    local a = setmetatable({ name = name, hutch = nil, nestBox = -1, _class = "IsoAnimal" }, Animal)
    a.data = { pos = -1, pref = -1,
        getHutchPosition = function(d) return d.pos end,
        setHutchPosition = function(d, k)
            assert(type(k) == "number" and k == math.floor(k), "setHutchPosition(int) got " .. tostring(k))
            d.pos = k
        end }
    return a
end
function Animal:getData() return self.data end
function Animal:getHutch() return self.hutch end

local Hutch = {}
Hutch.__index = Hutch
function Hutch:getAnimalInside() return self.map end
function Hutch:isSlave() return self.slave end
function Hutch:getSquare() return self.sq end
function Hutch:getX() return self.x end
function Hutch:getY() return self.y end
function Hutch:getZ() return 0 end
function Hutch:getAnimal(k) W.calls.getAnimal = W.calls.getAnimal + 1 return self.map:jget(k) end -- Integer 參數：Kahlua 轉型
function Hutch:getDeadBody(k) return self.bodies[k] end
function Hutch:getObjectIndex()
    if not self.sq then return -1 end
    for i, o in ipairs(self.sq.objects) do
        if o == self then return i - 1 end
    end
    return -1
end
-- 原版 IsoHutch.removeAnimal（IsoHutch.java:538-544）：以動物的 hutchPosition（int 自動裝箱）remove；客戶端不送封包
function Hutch:removeAnimal(a)
    W.calls.removeAnimal = W.calls.removeAnimal + 1
    a.hutch = nil
    self.map:jremove(a.data.pos)
    self.bodies[a.data.pos] = nil
    a.data.pos = -1
end
-- 原版 42.21 IsoHutch.removeFromWorld（IsoHutch.java:983-990）：values() 有 null 就 NPE
function Hutch:engineRemoveFromWorld()
    for _, v in pairs(self.map.e) do
        if v == NULL then W.crashes = W.crashes + 1 return end
    end
end

local Square = {}
Square.__index = Square
function Square:getHutch()
    for _, o in ipairs(self.objects) do
        if getmetatable(o) == Hutch then return o end
    end
    return nil
end
function Square:getChunk() return self.chunk end

local function square(x, y)
    local k = x .. "," .. y
    local sq = W.squares[k]
    if not sq then
        sq = setmetatable({ x = x, y = y, objects = {}, chunk = { id = k } }, Square)
        W.squares[k] = sq
    end
    return sq
end

local function newHutch(x, y, sprite, slave, sq)
    return setmetatable({ x = x, y = y, sprite = sprite, slave = slave, sq = sq, map = newMap(), bodies = {},
        _class = "IsoHutch" }, Hutch)
end

-- 一座 hutchhen：主雞舍＋四個附屬格（HutchDefinitions.lua:12-22），objects 照原版建構順序（主雞舍先加）
local function placeHutch(x, y, opts)
    opts = opts or {}
    local base = square(x, y)
    local master = newHutch(x, y, opts.masterSprite or "location_farm_accesories_01_50", false, base)
    local parts = {
        { 1, 0, "location_farm_accesories_01_42" }, { 1, -1, "location_farm_accesories_01_43" },
        { 0, -1, "location_farm_accesories_01_41" }, { 0, 0, "location_farm_accesories_01_44" },
    }
    local all = {}
    if opts.slaveFirst then
        local s0 = newHutch(x, y, "location_farm_accesories_01_44", true, base)
        base.objects[#base.objects + 1] = s0
        all[#all + 1] = s0
    end
    base.objects[#base.objects + 1] = master
    all[#all + 1] = master
    for _, p in ipairs(parts) do
        if not (opts.slaveFirst and p[1] == 0 and p[2] == 0) then
            local sq = square(x + p[1], y + p[2])
            local s = newHutch(x + p[1], y + p[2], p[3], true, sq)
            sq.objects[#sq.objects + 1] = s
            all[#all + 1] = s
        end
    end
    return master, all
end

local function fillHens(h, n)
    local hens = {}
    for i = 0, n - 1 do
        local a = newAnimal("hen" .. i)
        a.hutch, a.data.pos, a.data.pref = h, i, i
        h.map:jput(i, a)
        hens[#hens + 1] = a
    end
    return hens
end

-- chunk 載入：MapObjects.loadGridSquare 依圖塊名分派（MapObjects.java:184-218）
local function loadHutch(x, y, opts)
    local master, all = placeHutch(x, y, opts)
    local hens = fillHens(master, opts and opts.hens or 4)
    for _, obj in ipairs(all) do
        local fns = W.onLoad[obj.sprite]
        if fns then
            for _, fn in ipairs(fns) do fn(obj) end
        end
    end
    W.loaded[#W.loaded + 1] = master
    return master, hens, all
end

-- 建造中新增：AddItemToMapPacket.processClient → OnObjectAdded（AddItemToMapPacket.java:94）
local function buildViaPacket(x, y)
    local master, all = placeHutch(x, y)
    local hens = fillHens(master, 4)
    for _, obj in ipairs(all) do
        for _, fn in ipairs(W.onAdded) do fn(obj) end
    end
    W.loaded[#W.loaded + 1] = master
    return master, hens
end

-- 原版客戶端同步（NetworkPlayerAI.parse(AnimalPacket)，NetworkPlayerAI.java:361-396）
local function netNest(h, hen, nest)
    if hen.data.pos ~= -1 then h.map:jput(hen.data.pos, nil) end -- put(舊格, null)，巢箱分支不重設 hutchPosition
    h.nest = h.nest or {}
    h.nest[nest] = hen
    hen.nestBox = nest
end
local function netSlot(h, hen, slot)
    if hen.nestBox ~= -1 then h.nest[hen.nestBox] = nil end
    if hen.data.pos ~= -1 then h.map:jput(hen.data.pos, nil) end
    if h.map:jget(slot) ~= hen then
        hen.data.pref, hen.data.pos = slot, slot
        h.map:jput(slot, hen)
    end
end

local function unload(h)
    for _, o in ipairs(h.sq.objects) do
        if getmetatable(o) == Hutch then o:engineRemoveFromWorld() end
    end
    h.sq.chunk = nil -- IsoChunk.removeFromWorld 把格子的 chunk 設 null（IsoChunk.java:3260）
end

-- 一幀：封包（寫入 null）→ ProcessChunkPos（卸載）→ OnTick
local function frame(packets, unloads)
    if packets then packets() end
    if unloads then unloads() end
    for _, fn in ipairs(W.ticks) do fn() end
end

local HUTCH_DEFS = {
    hutchhen = {
        baseSprite = "location_farm_accesories_01_50",
        extraSprites = {
            { xoffset = 1, yoffset = 0, sprite = "location_farm_accesories_01_42" },
            { xoffset = 1, yoffset = -1, sprite = "location_farm_accesories_01_43" },
            { xoffset = 0, yoffset = -1, sprite = "location_farm_accesories_01_41" },
            { xoffset = 0, yoffset = 0, sprite = "location_farm_accesories_01_44", spriteOpen = "location_farm_accesories_01_46" },
        },
    },
    -- 有蛋門的定義：主雞舍格的圖塊會被換成門的圖塊（IsoHutch.toggleEggHatchDoor），存檔後以該圖塊載入
    modhutch = {
        baseSprite = "mod_hutch_01_0",
        extraSprites = {},
        eggHatchDoors = { { sprite = "mod_hutch_01_0", closedSprite = "mod_hutch_01_8" } },
    },
}

local function newWorld(opts)
    opts = opts or {}
    W = {
        squares = {}, loaded = {}, ticks = {}, onAdded = {}, onLoad = {}, prints = {}, crashes = 0,
        mp = opts.mp ~= false, priorities = {},
        calls = { containsValue = 0, keySet = 0, getAnimal = 0, removeAnimal = 0, addAnimal = 0, mapGet = 0, mapRemove = 0 },
    }
    Events = {
        OnTick = { Add = function(fn) W.ticks[#W.ticks + 1] = fn end },
        OnObjectAdded = { Add = function(fn) W.onAdded[#W.onAdded + 1] = fn end },
    }
    MapObjects = {
        OnLoadWithSprite = function(names, fn, priority)
            assert(type(names) == "table", "expected sprite-name table")
            for _, n in ipairs(names) do
                W.onLoad[n] = W.onLoad[n] or {}
                table.insert(W.onLoad[n], fn)
                W.priorities[n] = priority
            end
        end,
    }
    HutchDefinitions = { hutchs = HUTCH_DEFS }
    ArrayList = { new = function() return newList() end }
    getCell = function() return W end
    isClient = function() return W.mp end
    instanceof = function(o, cls) return type(o) == "table" and o._class == cls end
    AnimalDefinitions = { getDef = function() return { getBreedByName = function() return { name = "rhodeisland" } end } end }
    addAnimal = function(_, x, y, z)
        W.calls.addAnimal = W.calls.addAnimal + 1
        assert(x == 0 and y == 0 and z == 0, "scratch hen must not enter the world")
        local a = newAnimal("scratch")
        W.scratch = a
        return a
    end
    print = function(...)
        local parts = {}
        for i = 1, select("#", ...) do parts[i] = tostring(select(i, ...)) end
        W.prints[#W.prints + 1] = table.concat(parts, " ")
    end
    MDFX_HutchNullSlotGuard = nil
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

local function liveCount(h)
    local n = 0
    for _, v in pairs(h.map.e) do
        if v ~= NULL then n = n + 1 end
    end
    return n
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
    local function load()
        local chunk, err = _G.load(src, "=MDFX_HutchNullSlotGuard.lua")
        if not chunk then error(err) end
        chunk()
    end
    local function G() return MDFX_HutchNullSlotGuard end

    -- 1 安裝
    section("1 安裝")
    newWorld()
    load()
    local want = { "location_farm_accesories_01_50", "location_farm_accesories_01_42", "location_farm_accesories_01_43",
        "location_farm_accesories_01_41", "location_farm_accesories_01_44", "location_farm_accesories_01_46",
        "mod_hutch_01_0", "mod_hutch_01_8" }
    local missing = {}
    for _, n in ipairs(want) do
        if not W.onLoad[n] or #W.onLoad[n] ~= 1 then missing[#missing + 1] = n end
    end
    check("1 每個雞舍圖塊（主格、附屬格、開門、蛋門）都登記一次 MapObjects", #missing == 0, table.concat(missing, ","))
    check("1 MapObjects priority 不是原版常用的小數字", W.priorities["location_farm_accesories_01_50"] ~= nil
        and W.priorities["location_farm_accesories_01_50"] > 100)
    check("1 登記一個 OnObjectAdded", #W.onAdded == 1, #W.onAdded .. " handlers")
    check("1 還沒有雞舍時不掛 OnTick", #W.ticks == 0, #W.ticks .. " handlers")
    check("1 安裝時不印訊息", #W.prints == 0, table.concat(W.prints, " | "))
    check("1 有全域統計表", type(G()) == "table" and G().removed == 0 and G().tracked() == 0)
    load()
    check("1 同一個 Lua 狀態重複載入不重複登記", #W.onAdded == 1 and #W.onLoad["location_farm_accesories_01_50"] == 1)

    -- 2 引擎形狀不符
    section("2 形狀不符不安裝")
    newWorld()
    MapObjects = nil
    load()
    check("2 不登記任何事件", #W.onAdded == 0 and #W.ticks == 0)
    check("2 印一行 NOT installed", printed("NOT installed") == 1, table.concat(W.prints, " | "))

    -- 3 母雞進巢箱（原版下蛋流程）→ 下一次卸載前清掉
    section("3 母雞進巢箱")
    newWorld()
    load()
    local h3, hens3 = loadHutch(20, 20)
    check("3 載入雞舍後掛上 OnTick", #W.ticks == 1, #W.ticks .. " handlers")
    check("3 只登記主雞舍", G().tracked() == 1, "tracked=" .. G().tracked())
    frame()
    frame(function() netNest(h3, hens3[1], 0) end)
    check("3 null 在下一幀之前拿掉", not h3.map:containsValue(nil) and G().removed == 1, "removed=" .. G().removed)
    check("3 拿掉的是那一格 key，活的三隻不動", h3.map:size() == 3 and liveCount(h3) == 3 and h3.map:jget(1) == hens3[2])
    check("3 巢箱裡的母雞不動", h3.nest[0] == hens3[1] and hens3[1].hutch == h3)
    check("3 暫用母雞回到 -1／沒有雞舍", W.scratch ~= nil and W.scratch.data.pos == -1 and W.scratch.hutch == nil)
    frame(nil, function() unload(h3) end)
    check("3 卸載不崩潰", W.crashes == 0, "crashes=" .. W.crashes)
    check("3 診斷只印一次", printed("removed null slot") == 1, table.concat(W.prints, " | "))
    check("3 不用 HashMap.remove(double)", W.calls.mapRemove == 0)

    -- 3b 對照：同樣的流程沒有補丁＝原版崩潰（確認假引擎重現得出來）
    newWorld()
    local h3b, hens3b = loadHutch(20, 20)
    frame(function() netNest(h3b, hens3b[1], 0) end, function() unload(h3b) end)
    check("3b 對照組（不載補丁）原版崩潰", W.crashes == 1, "crashes=" .. W.crashes)

    -- 4 換格的 null 會一直留著；同一 session 第二次不再印
    section("4 換格")
    newWorld()
    load()
    local h4, hens4 = loadHutch(30, 30)
    frame()
    frame(function() netSlot(h4, hens4[1], 10) end)
    check("4 舊格的 null 拿掉、新格的母雞在", not h4.map:containsValue(nil) and h4.map:jget(10) == hens4[1]
        and h4.map:size() == 4)
    frame(function() netNest(h4, hens4[2], 1) end)
    check("4 第二個 null 也拿掉", not h4.map:containsValue(nil) and G().removed == 2, "removed=" .. G().removed)
    check("4 第二次不再印診斷", printed("removed null slot") == 1)
    check("4 暫用母雞只建一次", W.calls.addAnimal == 1, "addAnimal=" .. W.calls.addAnimal)
    frame(nil, function() unload(h4) end)
    check("4 卸載不崩潰", W.crashes == 0)

    -- 5 null 格裡有屍體：不動、印一次、冷卻期間不重查
    section("5 屍體")
    newWorld()
    load()
    local h5, hens5 = loadHutch(40, 40)
    local body = { name = "body" }
    h5.bodies[3] = body
    frame(function() h5.map:jput(3, nil) end)
    check("5 有屍體的 null 格不動", h5.map.e[3] == NULL and h5.bodies[3] == body)
    check("5 記到 skipped、印一次", G().skipped == 1 and printed("dead body") == 1, table.concat(W.prints, " | "))
    resetCalls()
    for _ = 1, 299 do frame() end
    check("5 冷卻期間不再取 key", W.calls.keySet == 0 and W.calls.containsValue == 0,
        "keySet=" .. W.calls.keySet .. " containsValue=" .. W.calls.containsValue)
    frame()
    frame()
    check("5 冷卻結束後重查", W.calls.containsValue >= 1)
    check("5 其他格的母雞不動", liveCount(h5) == 3 and h5.map:jget(0) == hens5[1])

    -- 5b 刪不掉的 null：只冷卻、不每幀重跑、不算成移除
    newWorld()
    load()
    local h5b = loadHutch(44, 40)
    h5b.map.sticky = { [7] = true }
    frame(function() h5b.map:jput(7, nil) end)
    check("5b 刪不掉的 null 不算成移除、不印移除訊息", G().removed == 0 and printed("removed null slot") == 0,
        "removed=" .. G().removed)
    resetCalls()
    for _ = 1, 299 do frame() end
    check("5b 刪不掉時冷卻，不每幀取 key", W.calls.keySet == 0, "keySet=" .. W.calls.keySet)

    -- 6 沒事時的成本（效能不變式）
    section("6 每幀固定成本")
    newWorld()
    load()
    for i = 1, 10 do loadHutch(100 + i * 10, 100) end
    frame()
    resetCalls()
    for _ = 1, 100 do frame() end
    check("6 10 座雞舍、100 幀：每座每幀一次 containsValue", W.calls.containsValue == 1000,
        "containsValue=" .. W.calls.containsValue)
    check("6 沒有 null 時不取 key、不查格", W.calls.keySet == 0 and W.calls.getAnimal == 0 and W.calls.addAnimal == 0)

    -- 7 單人：不登記、不掛 OnTick
    section("7 單人")
    newWorld({ mp = false })
    load()
    local h7, hens7 = loadHutch(20, 20)
    check("7 單人不登記雞舍", G().tracked() == 0)
    check("7 單人不掛 OnTick", #W.ticks == 0)
    resetCalls()
    frame(function() netNest(h7, hens7[1], 0) end)
    check("7 單人零呼叫", W.calls.containsValue == 0 and W.calls.addAnimal == 0)

    -- 8 建造中新增的雞舍（AddItemToMap → OnObjectAdded）
    section("8 新蓋的雞舍")
    newWorld()
    load()
    local h8, hens8 = buildViaPacket(50, 50)
    check("8 新蓋的雞舍有登記", G().tracked() == 1 and #W.ticks == 1)
    frame(function() netNest(h8, hens8[1], 0) end)
    frame(nil, function() unload(h8) end)
    check("8 新蓋的雞舍卸載不崩潰", W.crashes == 0 and G().removed == 1)

    -- 9 卸載的雞舍會放掉
    section("9 放掉卸載的雞舍")
    newWorld()
    load()
    local h9 = loadHutch(60, 60)
    loadHutch(70, 60)
    frame(nil, function() unload(h9) end)
    for _ = 1, 300 do frame() end
    check("9 卸載後放掉，另一座還在", G().tracked() == 1, "tracked=" .. G().tracked())
    local weak = setmetatable({ h9 }, { __mode = "v" })
    h9 = nil
    W.loaded = {}
    W.squares = {}
    collectgarbage("collect")
    collectgarbage("collect")
    check("9 放掉的雞舍可被回收（沒有殘留參照）", weak[1] == nil)

    -- 10 只登記封包會解析到的那一座
    section("10 登記對象")
    newWorld()
    load()
    local h10 = loadHutch(80, 80, { slaveFirst = true })
    local firstOnBase = h10.sq:getHutch()
    check("10 主雞舍格上第一個是附屬格時，兩個都登記", G().tracked() == 2 and firstOnBase ~= h10,
        "tracked=" .. G().tracked())
    -- 原版 IsoHutch.getHutch(x,y,z) 會解析到格上第一個 IsoHutch（IsoGridSquare.java:11235-11240）
    frame(function() firstOnBase.map:jput(5, nil) end)
    frame(nil, function() unload(h10) end)
    check("10 寫進第一個的 null 也清掉", W.crashes == 0 and not firstOnBase.map:containsValue(nil))
    newWorld()
    load()
    loadHutch(90, 90)
    check("10 一般順序只登記主雞舍（附屬格不登記）", G().tracked() == 1)

    -- 11 有蛋門的定義：主雞舍以門的圖塊載入
    section("11 主雞舍換過圖塊")
    newWorld()
    load()
    local h11, hens11 = loadHutch(110, 110, { masterSprite = "mod_hutch_01_8" })
    check("11 以門的圖塊載入也有登記", G().tracked() == 1)
    frame(function() netNest(h11, hens11[1], 0) end)
    frame(nil, function() unload(h11) end)
    check("11 清掉 null、卸載不崩潰", W.crashes == 0 and not h11.map:containsValue(nil), "crashes=" .. W.crashes)

    -- 12 多座雞舍、同一座多個 null
    section("12 多個 null")
    newWorld()
    load()
    local a12, ha = loadHutch(120, 120)
    local b12, hb = loadHutch(130, 120)
    frame(function()
        netNest(a12, ha[1], 0); netNest(a12, ha[2], 1); netSlot(b12, hb[3], 12)
    end)
    check("12 兩座雞舍、三個 null 全部拿掉", not a12.map:containsValue(nil) and not b12.map:containsValue(nil)
        and G().removed == 3, "removed=" .. G().removed)
    frame(nil, function() unload(a12); unload(b12) end)
    check("12 卸載不崩潰", W.crashes == 0)

    -- 13 自己出錯：不外洩、只印一次、之後停用
    section("13 自身錯誤")
    newWorld()
    load()
    loadHutch(140, 140)
    W.throwOnContains = true
    local ok13 = pcall(frame)
    check("13 例外不外洩到 OnTick", ok13 == true)
    frame()
    check("13 只印一次 disabled", printed("disabled for this session") == 1, table.concat(W.prints, " | "))
    W.throwOnContains = false
    resetCalls()
    frame()
    check("13 停用後零呼叫", W.calls.containsValue == 0)

    return checks, failures
end

-- ── 主程式 ───────────────────────────────────────────────────────
local MUTANTS = {
    { name = "直接 HashMap.remove(key)", subs = {
        { "local s = scratchHen()\n                s:getData():setHutchPosition(k)\n                h:removeAnimal(s)",
          "map:remove(k)" } } },
    { name = "不檢查屍體", subs = { { "if h:getDeadBody(k) ~= nil then", "if false then" } } },
    { name = "每幀都取 key（拿掉 containsValue 快速路徑）", subs = {
        { "elseif maps[i]:containsValue(nil) then", "else" } } },
    { name = "沒有冷卻", subs = { { "quiet[i] = QUIET", "quiet[i] = 0" } } },
    { name = "不登記 OnObjectAdded", subs = { { "Events.OnObjectAdded.Add(onHutch)", "local _ = onHutch" } } },
    { name = "只登記 baseSprite", subs = {
        { "            sprite(part.sprite)\n            sprite(part.spriteOpen)\n", "" },
        { "            sprite(door.sprite)\n            sprite(door.closedSprite)\n", "" } } },
    { name = "不放掉卸載的雞舍", subs = {
        { "if sq == nil or sq:getChunk() == nil or h:getObjectIndex() < 0 then untrack(i) end", "local _ = sq" } } },
    { name = "拿掉 pcall", subs = { { "local ok, err = pcall(tick)", "local ok, err = true, tick()" } } },
    { name = "單人也登記", subs = {
        { "if not mp or not instanceof(obj, \"IsoHutch\") then return end",
          "if not instanceof(obj, \"IsoHutch\") then return end" } } },
    { name = "不追主雞舍格上的第一個", subs = { { "if first and first ~= obj then add(first) end", "local _ = first" } } },
    { name = "附屬格也登記", subs = { { "    if obj:isSlave() then return end\n", "" } } },
    { name = "暫用母雞每次重建", subs = { { "if scratch == nil then", "if true then" } } },
    { name = "載入時就掛 OnTick", subs = {
        { "Events.OnObjectAdded.Add(onHutch)", "Events.OnObjectAdded.Add(onHutch)\nticking = true\nEvents.OnTick.Add(onTick)" } } },
    { name = "不看 size() 差就當成移除", subs = { { "local removed = before - map:size()", "local removed = 1" } } },
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
