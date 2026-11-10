-- MDFX_StaleWornGuard 離線自我檢查
-- 用法（repo 根目錄）： lua scripts/test_stale_worn_guard.lua [--mutants]
--
-- 假引擎照 42.22.2 反編譯快照的形狀模擬（WornItems 的 size／getItemByIndex／contains／getLocation／getBodyLocationGroup、
-- InventoryItem 的 getContainer／getWorldItem／getID、removeWornItem(item, forceDropTooHeavy)、IsoCell 的每幀更新清單、
-- getOnlinePlayers 的清單、伺服器照客戶端清單另建同編號物件），驗證：
--   * 穿著而且在自己物品欄裡的物品永遠不動
--   * 穿著卻在地上、或在別的容器裡的物品，同一個編號連兩次檢查都成立才拿掉；參數是 false；拿掉後登記回每幀更新清單
--   * 只成立一次（瞬間狀態）不動；不連續的兩次也不動
--   * 照客戶端清單另建的物件（不在容器、不在地上）：這位玩家先前穿過同編號的真物品才拿掉，
--     物件每次檢查都換新也一樣；沒有先例的（繃帶模型）不動；別的玩家的先例不算
--   * 死亡的角色不看；拿不到物品欄或穿戴清單的角色跳過；離線後不留紀錄
--   * 可同時穿多件的部位不呼叫 removeWornItem；呼叫後還在的記一次、不再重試；兩次檢查至少隔 CHECK_MS；多件、多位玩家各自處理
--   * 每次介入記一行、有上限；自己出錯時不外洩、只印一次並停用；多人客戶端不安裝；引擎形狀不符不安裝
--   * 單人：掛 OnTickEvenPaused（不掛 OnTick）、看本機玩家（空位跳過）、同一套判定
-- --mutants：逐一抽掉每道防線，確認至少一項檢查轉紅。

local SRC_PATH = "MOD/MinidoracatFixesFor42/Contents/mods/MinidoracatFixesFor42/"
    .. "42/media/lua/server/Fixes/MDFX_StaleWornGuard.lua"

local function readFile(path)
    local f = assert(io.open(path, "rb"))
    local s = f:read("*a")
    f:close()
    return s
end
local SOURCE = readFile(SRC_PATH)
local realPrint = print
local loadSource = loadstring or load

-- ── 假引擎 ─────────────────────────────────────────────────────
local W

local Item = {}
Item.__index = Item
function Item:getContainer() return self.container end
function Item:getWorldItem() return self.worldItem end
function Item:getFullType() return self.type end
function Item:getID() return self.id end

local nextId = 100
local function item(type, id)
    if not id then
        nextId = nextId + 1
        id = nextId
    end
    return setmetatable({ id = id, type = type or "Base.Bag_ALICEpack" }, Item)
end

local Worn = {}
Worn.__index = Worn
function Worn:size() return #self.items end
function Worn:getItemByIndex(i) return self.items[i + 1] end -- WornItems.java:95-97：超出範圍回 null
function Worn:contains(it)                                    -- :115-117
    for _, w in ipairs(self.items) do if w == it then return true end end
    return false
end
-- 部位：沒指定就一件一個；名稱以 "multi:" 開頭的可以同時穿多件（BodyLocationGroup.java:116-119）
local Group = { isMultiItem = function(_, loc) return loc:sub(1, 6) == "multi:" end }
function Worn:getLocation(it) return it.loc or ("loc:" .. tostring(it.id)) end
function Worn:getBodyLocationGroup() return Group end

local Player = {}
Player.__index = Player
function Player:getInventory() return self.inv end
function Player:getWornItems() return self.worn end
function Player:isDead() return self.dead end
function Player:getUsername() return self.name end
function Player:getX() return 10758.6 end
function Player:getY() return 9772.4 end
function Player:getZ() return 0 end
-- IsoGameCharacter.java:3460-3518：先把「該部位的第一件」移出每幀更新清單，再改穿戴清單；可同時穿多件的部位不移除（WornItems.java:54-59）。
-- it.failRemove 模擬 Java 端出錯：清單沒改，Lua 這邊也收不到錯誤。
function Player:removeWornItem(it, forceDropTooHeavy)
    self.calls[#self.calls + 1] = { item = it, flag = forceDropTooHeavy }
    local worn = self.worn
    local loc = worn:getLocation(it)
    for i, w in ipairs(worn.items) do
        if worn:getLocation(w) == loc then
            W.process[w] = nil
            if not it.failRemove and not Group:isMultiItem(loc) then table.remove(worn.items, i) end
            return
        end
    end
end

local function player(name)
    local p = setmetatable({ name = name or "test", inv = { name = "inv:" .. tostring(name) }, calls = {}, dead = false }, Player)
    p.worn = setmetatable({ items = {} }, Worn)
    W.players[#W.players + 1] = p
    return p
end

-- 穿上一件；where：nil＝在自己物品欄、"ground"、"other"（別的容器）、"phantom"（哪裡都不在）
local function wear(p, where, type, id)
    local it = item(type, id)
    if where == nil then
        it.container = p.inv
    elseif where == "ground" then
        it.worldItem = {}
    elseif where == "other" then
        it.container = { name = "elsewhere" }
    end
    p.worn.items[#p.worn.items + 1] = it
    W.process[it] = true -- 物品進容器或放到地上時登記（ItemContainer.java:540-542）
    return it
end
local function drop(p, it) it.container, it.worldItem = nil, {} end
local function pickUp(p, it) it.container, it.worldItem = p.inv, nil end
-- 伺服器收到客戶端清單：物品欄找不到這個編號，另建一件同編號的物件換上（SyncClothingPacket.java:192-204）
local function recreate(p, old)
    local it = item(old.type, old.id)
    for i, w in ipairs(p.worn.items) do
        if w == old then p.worn.items[i] = it return it end
    end
    p.worn.items[#p.worn.items + 1] = it
    return it
end

local function printed(needle)
    local n = 0
    for _, line in ipairs(W.prints) do
        if line:find(needle, 1, true) then n = n + 1 end
    end
    return n
end

-- 過 ms 毫秒後跑一幀：先 OnTickEvenPaused 再 OnTick（IngameState.java:1346、:1653）
local function frame(ms)
    W.now = W.now + (ms or 1000)
    for _, fn in ipairs(W.paused) do fn() end
    for _, fn in ipairs(W.ticks) do fn() end
end

-- opts.mode："server"（預設）、"sp"（單人）、"client"（多人客戶端）
local function newWorld(opts)
    opts = opts or {}
    local mode = opts.mode or "server"
    W = { ticks = {}, paused = {}, prints = {}, players = {}, process = {}, events = {}, now = 50000, scans = 0, added = 0 }
    MDFX_StaleWornGuard = nil
    print = function(...)
        local parts = {}
        for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
        W.prints[#W.prints + 1] = table.concat(parts, "\t")
    end
    Events = {
        OnTick = { Add = function(fn) W.ticks[#W.ticks + 1] = fn end },
        OnTickEvenPaused = { Add = function(fn) W.paused[#W.paused + 1] = fn end },
    }
    isServer = function() return mode == "server" end
    isClient = function() return mode == "client" end
    getTimestampMs = function() return W.now end
    -- 伺服器回線上玩家；單人回空清單（LuaManager.java:4474-4480）
    getOnlinePlayers = function()
        W.scans = W.scans + 1
        if W.failPlayers then error("boom") end
        local list = mode == "server" and W.players or {}
        return { size = function() return #list end, get = function(_, i) return list[i + 1] end }
    end
    -- 本機玩家：W.slots 個位置，沒人的位置是 nil（LuaManager.java:3901-3903、:4184-4186）
    getNumActivePlayers = function() return W.slots or #W.players end
    getSpecificPlayer = function(i) return W.players[i + 1] end
    triggerEvent = function(name, who) W.events[#W.events + 1] = { name = name, who = who } end
    local cell = { addToProcessItems = function(_, it) -- IsoCell.java:2294-2301
        W.added = W.added + 1
        W.process[it] = true
    end }
    getCell = function() return cell end
    if opts.noPlayersApi then getOnlinePlayers = nil end
    if opts.noLocalApi then getSpecificPlayer = nil end
    if opts.noPausedEvent then Events.OnTickEvenPaused = nil end
    if opts.noCell then getCell = nil end
end

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
    local function load(opts)
        newWorld(opts)
        assert(loadSource(src, "MDFX_StaleWornGuard"))()
    end

    -- 1 多人客戶端：不安裝（由伺服器處理）
    load({ mode = "client" })
    check("1 多人客戶端不掛任何事件", #W.ticks == 0 and #W.paused == 0)
    check("1 多人客戶端不印任何東西", #W.prints == 0)

    -- 2 引擎形狀不符：不安裝、印一行
    load({ noPlayersApi = true })
    check("2 缺 getOnlinePlayers 不掛 OnTick", #W.ticks == 0)
    check("2 缺 getOnlinePlayers 印 NOT installed", printed("NOT installed") == 1)
    load({ noCell = true })
    check("2 缺 getCell 不掛 OnTick", #W.ticks == 0 and printed("NOT installed") == 1)

    -- 3 伺服器：掛一個 OnTick（不掛 OnTickEvenPaused）；重複載入不再掛
    load()
    check("3 掛一個 OnTick", #W.ticks == 1 and #W.paused == 0)
    assert(loadSource(src, "MDFX_StaleWornGuard"))()
    check("3 重複載入不再掛", #W.ticks == 1)

    -- 4 正常穿著（在自己物品欄）：永遠不動
    load()
    local p = player("test")
    wear(p) wear(p, nil, "Base.Hat_Beret")
    for _ = 1, 5 do frame() end
    check("4 正常穿著不動", #p.calls == 0 and #p.worn.items == 2 and #W.prints == 0)

    -- 5 放到地上還穿著：第二次檢查才拿掉，參數 false，記一行，登記回每幀更新清單
    load()
    p = player("test")
    local keep = wear(p, nil, "Base.Hat_Beret")
    local bag = wear(p)
    frame()
    drop(p, bag)
    frame()
    check("5 第一次看到不動", #p.calls == 0)
    frame()
    check("5 第二次拿掉", #p.calls == 1 and p.calls[1].item == bag, #p.calls)
    check("5 forceDropTooHeavy 是 false", p.calls[1] and p.calls[1].flag == false)
    check("5 其他穿著不動", #p.worn.items == 1 and p.worn.items[1] == keep)
    check("5 記一行（物品、位置、玩家、座標）", printed('removed stale worn item Base.Bag_ALICEpack#' .. bag.id
        .. ' (on the ground) from player="test" at 10758,9772,0 (#1)') == 1, table.concat(W.prints, " | "))
    check("5 計數", MDFX_StaleWornGuard.removed == 1 and MDFX_StaleWornGuard.stuck == 0)
    check("5 地上那件仍在每幀更新清單", W.process[bag] == true and W.added == 1)
    frame() frame()
    check("5 之後不再動", #p.calls == 1 and #W.prints == 1)
    check("5 伺服器不發 OnClothingUpdated（客戶端收到清單時自己發）", #W.events == 0)

    -- 6 在別的容器裡還穿著：同樣處理
    load()
    p = player("test")
    bag = wear(p, "other")
    frame() frame()
    check("6 別的容器裡的拿掉", #p.calls == 1 and p.calls[1].item == bag)
    check("6 記成 in another container", printed("(in another container)") == 1)
    check("6 被撿走的那件仍在每幀更新清單", W.process[bag] == true)

    -- 7 瞬間狀態：只成立一次不動；中間恢復過的兩次不算連續
    load()
    p = player("test")
    bag = wear(p)
    drop(p, bag)
    frame()
    pickUp(p, bag)
    frame()
    check("7 只成立一次不動", #p.calls == 0)
    drop(p, bag)
    frame()
    check("7 恢復後再成立，重新算第一次", #p.calls == 0)
    frame()
    check("7 連續第二次才拿掉", #p.calls == 1)

    -- 8 沒有先例的另建物件（繃帶模型：伺服器上從來不在物品欄）：不動
    load()
    p = player("test")
    wear(p, "phantom", "Base.Bandage_LeftHand")
    for _ = 1, 4 do frame() end
    check("8 沒有先例的另建物件不動", #p.calls == 0 and #p.worn.items == 1 and #W.prints == 0)

    -- 9 放下後被客戶端清單換成另建的物件，而且每次檢查都是新物件：照編號連兩次成立，拿掉
    load()
    p = player("test")
    bag = wear(p)
    frame()                      -- 看過它穿著、在主物品欄
    drop(p, bag)
    local ph = recreate(p, bag)  -- 伺服器照清單另建
    frame()
    check("9 第一次看到另建的物件不動", #p.calls == 0)
    ph = recreate(p, ph)         -- 又收到一次清單，物件換新
    frame()
    check("9 物件換新仍照編號拿掉", #p.calls == 1 and p.calls[1].item == ph and #p.worn.items == 0, #p.calls)
    check("9 記成 re-created from a client list", printed("#" .. bag.id .. " (re-created from a client list)") == 1,
        table.concat(W.prints, " | "))
    check("9 另建的物件不登記每幀更新", W.added == 0 and W.process[ph] == nil)
    ph = recreate(p, ph)         -- 客戶端還沒收到新清單、又送一次：再拿一次
    frame() frame()
    check("9 之後又被穿回，再拿掉", #p.calls == 2 and #p.worn.items == 0)

    -- 10 先例只算自己的：別的玩家穿過同編號，不算
    load()
    p = player("test")
    local q = player("test2")
    bag = wear(p)
    frame()
    wear(q, "phantom", bag.type, bag.id)
    frame() frame() frame()
    check("10 別的玩家的先例不算", #q.calls == 0 and #p.calls == 0)

    -- 11 死亡的角色不看
    load()
    p = player("test")
    wear(p, "ground")
    p.dead = true
    for _ = 1, 4 do frame() end
    check("11 死亡的角色不動", #p.calls == 0)

    -- 12 兩次檢查至少隔 CHECK_MS（1000）
    load()
    p = player("test")
    wear(p, "ground")
    frame(1000)
    local scans = W.scans
    frame(400) frame(400)
    check("12 不到 1000 ms 不檢查", W.scans == scans and #p.calls == 0, W.scans - scans)
    frame(200)
    check("12 滿 1000 ms 才做第二次", W.scans == scans + 1 and #p.calls == 1)
    -- 系統時鐘被往回調：差距在一個間隔內照等；超過一個間隔就不等它追上
    frame(600)
    scans = W.scans
    frame(-300)
    check("12 時鐘小幅往回（離下一次不到一個間隔），照等", W.scans == scans)
    frame(-3600000)
    check("12 時鐘往回一小時，照常檢查", W.scans == scans + 1)
    frame(1000)
    check("12 之後照新的時鐘算間隔", W.scans == scans + 2)

    -- 13 同一位玩家相鄰的兩件、另一位玩家的一件：各自處理
    load()
    p = player("test")
    q = player("test2")
    keep = wear(p)
    local a, b = wear(p, "ground"), wear(p, "other", "Base.Bag_FannyPackFront")
    local c = wear(q, "ground")
    wear(q)
    frame() frame()
    check("13 同一位玩家兩件都拿掉", #p.calls == 2 and #p.worn.items == 1 and p.worn.items[1] == keep, #p.calls)
    check("13 另一位玩家的也拿掉", #q.calls == 1 and q.calls[1].item == c and #q.worn.items == 1)
    check("13 記三行", printed("removed stale worn item") == 3 and printed('player="test2"') == 1)
    check("13 拿的是那兩件", (p.calls[1].item == a or p.calls[1].item == b) and (p.calls[2].item == a or p.calls[2].item == b)
        and p.calls[1].item ~= p.calls[2].item)

    -- 14 拿不到穿戴清單、或拿不到物品欄的角色：跳過、不出錯，其他人照常
    load()
    p = player("test")
    p.worn = nil
    local r = player("test3")
    local own = wear(r)          -- 在自己物品欄
    local realInv = r.inv
    r.inv = nil                  -- getInventory() 暫時回 nil
    q = player("test2")
    bag = wear(q, "ground")
    frame() frame() frame()
    check("14 拿不到穿戴清單的跳過，其他人照常", #q.calls == 1 and printed("disabled") == 0)
    check("14 拿不到物品欄的不動", #r.calls == 0 and r.worn.items[1] == own)
    r.inv = realInv

    -- 15 可同時穿多件的部位：不呼叫 removeWornItem（它不會移除，還會把該部位第一件移出每幀更新清單）；記一次、不算 removed
    load()
    p = player("test")
    local head = wear(p, nil, "Base.Hat_Beret")
    head.loc = "multi:a"
    bag = wear(p, "ground")
    bag.loc = "multi:a"
    local other = wear(p, "ground", "Base.Hat_Beret")
    other.loc = "multi:a"
    for _ = 1, 6 do frame() end
    check("15 多件部位不呼叫 removeWornItem", #p.calls == 0 and #p.worn.items == 3, #p.calls)
    check("15 同部位的物品都還在每幀更新清單", W.process[head] == true and W.process[bag] == true and W.process[other] == true)
    check("15 不算 removed、stuck 計兩件", MDFX_StaleWornGuard.removed == 0 and MDFX_StaleWornGuard.stuck == 2)
    check("15 只記一行 could not remove", printed("could not remove stale worn item") == 1 and printed("removed stale worn item") == 0)

    -- 15b 呼叫後還在穿戴清單（Java 端出錯）：只試一次、真物品登記回每幀更新清單、不算 removed
    load()
    p = player("test")
    bag = wear(p, "ground")
    bag.failRemove = true
    for _ = 1, 6 do frame() end
    check("15b 只試一次", #p.calls == 1 and #p.worn.items == 1, #p.calls)
    check("15b 真物品還在每幀更新清單", W.process[bag] == true)
    check("15b 不算 removed、stuck 計一件", MDFX_StaleWornGuard.removed == 0 and MDFX_StaleWornGuard.stuck == 1)

    -- 15c 拿不掉的另建物件每次檢查都換新：stuck 照編號記，仍只試一次
    load()
    p = player("test")
    bag = wear(p)
    frame()
    drop(p, bag)
    local phantom = recreate(p, bag)
    for _ = 1, 6 do
        phantom.failRemove = true
        frame()
        phantom = recreate(p, phantom)
    end
    check("15c 物件每次換新也只試一次", #p.calls == 1, #p.calls)
    check("15c stuck 只計一次", MDFX_StaleWornGuard.stuck == 1 and MDFX_StaleWornGuard.removed == 0)

    -- 16 離線後不留紀錄：先例跟著消失
    load()
    p = player("test")
    bag = wear(p)
    frame()
    W.players = {}
    frame()
    W.players = { p }
    drop(p, bag)
    recreate(p, bag)
    frame() frame() frame()
    check("16 離線過的玩家先例不保留", #p.calls == 0)

    -- 17 診斷行上限 20，超過照樣處理
    load()
    p = player("test")
    for _ = 1, 25 do wear(p, "ground") end
    frame() frame()
    check("17 25 件都拿掉", #p.calls == 25 and MDFX_StaleWornGuard.removed == 25)
    check("17 只記 20 行", printed("removed stale worn item") == 20)
    check("17 第 20 行註明之後不再記", printed("(#20, further events are not logged)") == 1 and printed("further events") == 1)

    -- 18 自己出錯：不外洩、印一次、停用
    load()
    p = player("test")
    wear(p, "ground")
    W.failPlayers = true
    local ok = pcall(frame)
    check("18 錯誤不外洩", ok)
    check("18 印一行 disabled", printed("disabled after an internal error") == 1, table.concat(W.prints, " | "))
    W.failPlayers = false
    scans = W.scans
    frame() frame() frame()
    check("18 之後不再執行（照原版）", W.scans == scans and #p.calls == 0 and printed("disabled") == 1)

    -- 19 單人：掛 OnTickEvenPaused、不掛 OnTick；缺事件或本機玩家 API 不安裝
    load({ mode = "sp" })
    check("19 單人掛一個 OnTickEvenPaused、不掛 OnTick", #W.paused == 1 and #W.ticks == 0 and #W.prints == 0)
    load({ mode = "sp", noPausedEvent = true })
    check("19 單人缺 OnTickEvenPaused 不安裝", #W.paused == 0 and #W.ticks == 0 and printed("NOT installed") == 1)
    load({ mode = "sp", noLocalApi = true })
    check("19 單人缺 getSpecificPlayer 不安裝", #W.paused == 0 and #W.ticks == 0 and printed("NOT installed") == 1)

    -- 20 單人：看本機玩家（空位跳過），同一套判定
    load({ mode = "sp" })
    p = player("solo")
    local second = player("couch")
    W.players = { p, nil, second }
    W.slots = 4
    keep = wear(p, nil, "Base.Hat_Beret")
    bag = wear(p)
    local bandage = wear(p, "phantom", "Base.Bandage_LeftHand")
    local bag2 = wear(second, "other")
    frame()
    drop(p, bag)
    bag.container = { name = "floor" } -- 單人：地上的物品在地面的容器裡（E2E swe2e-sp-mir-1110a 實測）
    frame()
    check("20 第一次看到不動", #p.calls == 0 and #second.calls == 1)
    frame()
    check("20 第二次拿掉地上那件、參數 false", #p.calls == 1 and p.calls[1].item == bag and p.calls[1].flag == false, #p.calls)
    check("20 在物品欄的與沒有先例的另建物件不動", #p.worn.items == 2 and p.worn.items[1] == keep and p.worn.items[2] == bandage)
    check("20 另一位本機玩家各自處理", #second.calls == 1 and second.calls[1].item == bag2)
    check("20 拿掉的真物品仍在每幀更新清單", W.process[bag] == true and W.process[bag2] == true)
    check("20 空位不讓守衛停用、不讀線上玩家清單", printed("disabled") == 0 and W.scans == 0)
    check("20 計數與診斷行（地面容器裡的記成 on the ground）", MDFX_StaleWornGuard.removed == 2
        and printed('(on the ground) from player="solo"') == 1 and printed('(in another container) from player="couch"') == 1,
        table.concat(W.prints, " | "))
    check("20 每次拿掉都對那位玩家發 OnClothingUpdated（快捷列靠它重算）", #W.events == 2
        and W.events[1].name == "OnClothingUpdated" and W.events[1].who == second
        and W.events[2].name == "OnClothingUpdated" and W.events[2].who == p)

    -- 21 單人：沒拿掉的不發事件
    load({ mode = "sp" })
    p = player("solo")
    bag = wear(p, "ground")
    bag.failRemove = true
    for _ = 1, 4 do frame() end
    check("21 沒拿掉的不發 OnClothingUpdated", #p.calls == 1 and #W.events == 0 and MDFX_StaleWornGuard.stuck == 1)

    return checks, failures
end

-- ── 主程式 ───────────────────────────────────────────────────────
local MUTANTS = {
    { name = "拿掉防重複載入", subs = { { "if MDFX_StaleWornGuard then return end", "" } } },
    { name = "多人客戶端也安裝", subs = { { " or isClient() then return end", " then return end" } } },
    { name = "單人拿掉後不通知", subs = { { '    if not server then triggerEvent("OnClothingUpdated", player) end\n', "" } } },
    { name = "伺服器也發事件", subs = { { 'if not server then triggerEvent("OnClothingUpdated", player) end', 'triggerEvent("OnClothingUpdated", player)' } } },
    { name = "沒拿掉也通知", subs = { {
        '    if worn:contains(item) then return giveUp(st, id, what) end\n    -- 單人',
        '    if not server then triggerEvent("OnClothingUpdated", player) end\n    if worn:contains(item) then return giveUp(st, id, what) end\n    -- 單人' } } },
    { name = "地上的物品先看容器（單人記成在別的容器）", subs = { {
        '    if item:getWorldItem() then return "on the ground" end\n    if container then return "in another container" end\n',
        '    if container then return "in another container" end\n    if item:getWorldItem() then return "on the ground" end\n' } } },
    { name = "單人也掛 OnTick", subs = { { "    event = Events and Events.OnTickEvenPaused\n", "" } } },
    { name = "單人用線上玩家清單", subs = { { "    listPlayers = localPlayers and function() return localPlayers end\n", "" } } },
    { name = "單人缺本機玩家 API 照樣安裝", subs = { { "local localPlayers = triggerEvent and getNumActivePlayers and getSpecificPlayer and {", "local localPlayers = {" } } },
    { name = "空位不跳過", subs = { { "        if player then\n", "        if true then\n" } } },
    { name = "形狀檢查不看事件", subs = { { "if not (event and event.Add and listPlayers", "if not (listPlayers" } } },
    { name = "形狀檢查不看玩家清單", subs = { { " and listPlayers and getTimestampMs", " and getTimestampMs" } } },
    { name = "形狀檢查不看 getCell", subs = { { " and getTimestampMs and getCell)", " and getTimestampMs)" } } },
    { name = "檢查間隔縮到 100 ms", subs = { { "local CHECK_MS = 1000", "local CHECK_MS = 100" } } },
    { name = "不排下一次檢查的時間", subs = { { "    nextAt = now + CHECK_MS\n", "" } } },
    { name = "時鐘往回時一直等", subs = { { "if now < nextAt and nextAt - now <= CHECK_MS then return end", "if now < nextAt then return end" } } },
    { name = "在自己物品欄的也算", subs = { { "    if container == inv then return nil end\n", "" } } },
    { name = "別的容器裡的不算", subs = { { '    if container then return "in another container" end\n', "" } } },
    { name = "地上的不算", subs = { { '    if item:getWorldItem() then return "on the ground" end\n', "" } } },
    { name = "另建的物件不算", subs = { { "    if known[item:getID()] then return RECREATED end\n", "" } } },
    { name = "另建的物件不看先例", subs = { { "if known[item:getID()] then return RECREATED end", "do return RECREATED end" } } },
    { name = "不記先例", subs = { { "if item:getContainer() == inv then st.known[id] = true end", "" } } },
    { name = "不在物品欄的也記成先例", subs = { { "if item:getContainer() == inv then st.known[id] = true end", "st.known[id] = true" } } },
    { name = "拿不掉的照物件記", subs = {
        { "local id = item:getID()\n    local what", "local id = item\n    local what" },
        { "elseif not st.stuck[id] then", "elseif not st.stuck[item] then" } } },
    { name = "先例不分玩家", subs = {
        { "local why = stale(inv, item, st.known)", "ALLKNOWN = ALLKNOWN or {} local why = stale(inv, item, ALLKNOWN)" },
        { "if item:getContainer() == inv then st.known[id] = true end", "if item:getContainer() == inv then ALLKNOWN[id] = true end" } } },
    { name = "離線後紀錄不清", subs = { { "    state = online\nend", "    for k, v in pairs(online) do state[k] = v end\nend" } } },
    { name = "第一次看到就拿掉", subs = { { "if st.suspect[id] then remove(", "if true then remove(" } } },
    { name = "可疑清單只增不換", subs = { { "    st.suspect = suspect\n", "    for k in pairs(suspect) do st.suspect[k] = true end\n" } } },
    { name = "死亡的角色也看", subs = { { " and not player:isDead() then", " then" } } },
    { name = "不檢查穿戴清單拿不拿得到", subs = { { "if inv and worn and not", "if inv and not" } } },
    { name = "不檢查物品欄拿不拿得到", subs = { { "if inv and worn and not", "if worn and not" } } },
    { name = "由前往後掃", subs = { { "for j = worn:size() - 1, 0, -1 do", "for j = 0, worn:size() - 1 do" } } },
    { name = "不拿掉", subs = { { "    player:removeWornItem(item, false)\n", "" } } },
    { name = "物品欄放不下就再丟一次", subs = { { "player:removeWornItem(item, false)", "player:removeWornItem(item, true)" } } },
    { name = "不帶第二個參數", subs = { { "player:removeWornItem(item, false)", "player:removeWornItem(item)" } } },
    { name = "不確認有沒有拿掉", subs = { { "if worn:contains(item) then", "if false then" } } },
    { name = "多件部位照樣呼叫", subs = { { "    if worn:getBodyLocationGroup():isMultiItem(worn:getLocation(item)) then return giveUp(st, id, what) end\n", "" } } },
    { name = "拿不掉的還是重試", subs = { { "    st.stuck[id] = true\n", "" } } },
    { name = "拿不掉的不計數", subs = { { "    G.stuck = G.stuck + 1\n", "" } } },
    { name = "拿不掉的每次都記", subs = { { "if G.stuck == 1 then", "if true then" } } },
    { name = "拿不掉的也算 removed", subs = { { "if worn:contains(item) then return giveUp(st, id, what) end", "if worn:contains(item) then giveUp(st, id, what) end" } } },
    { name = "確認沒拿掉之後才登記回每幀更新", subs = { {
        "    if why ~= RECREATED then\n        local cell = getCell()\n        if cell then cell:addToProcessItems(item) end\n    end\n    if worn:contains(item) then return giveUp(st, id, what) end\n",
        "    if worn:contains(item) then return giveUp(st, id, what) end\n    if why ~= RECREATED then\n        local cell = getCell()\n        if cell then cell:addToProcessItems(item) end\n    end\n" } } },
    { name = "真物品不登記回每幀更新", subs = { { "        if cell then cell:addToProcessItems(item) end\n", "" } } },
    { name = "另建的物件也登記每幀更新", subs = { { "if why ~= RECREATED then", "if true then" } } },
    { name = "不計數", subs = { { "    G.removed = G.removed + 1\n", "" } } },
    { name = "診斷行沒有上限", subs = { { "if G.removed <= LOG_LIMIT then", "if true then" } } },
    { name = "不註明之後不再記", subs = { { "G.removed == LOG_LIMIT and", "false and" } } },
    { name = "拿掉 pcall", subs = { { "local ok, err = pcall(tick)", "local ok, err = true, tick()" } } },
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
            ALLKNOWN = nil
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
