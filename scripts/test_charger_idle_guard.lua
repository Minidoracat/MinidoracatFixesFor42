-- MDFX_ChargerIdleGuard 離線自我檢查
-- 用法（repo 根目錄）： lua scripts/test_charger_idle_guard.lua [--mutants]
--
-- 照載本機遊戲的原版 shared/TimedActions/ISActivateCarBatteryChargerAction.lua、ISPlaceCarBatteryChargerAction.lua
-- （PZ_HOME 可改安裝目錄）；Java 端用 Lua 照形狀模擬：
--   * IsoCell 的每幀更新清單（IsoCell.java:2194-2213、:2261-2276）：尾端 add、Set 去重、移除延到下一次 ProcessIsoObject 開頭
--   * IsoCarBatteryCharger.update（IsoCarBatteryCharger.java:122-156）與不比對狀態的 setActivated（:433-436，每次算一次 updateGenerator）
--   * chunk 卸載：物件 removeFromWorld 但仍留在 square 上、square 的 chunk 設成 null（IsoChunk.java:3248-3260）
--   * LoadChunk 在該 chunk 的物件都 addToWorld 之後才觸發（IsoChunk.java:3807、:3969）
-- 驗證：對照組重現每幀 updateGenerator；修正組連兩次檢查才移出、啟動當下（complete）或下一 tick（同步）放回、
-- 充電照常；不在世界上就丟掉不放回；只讀新增尾段（數 get 次數）、錨點消失退回整份讀、漏抓照原版跑；
-- 形狀不符不裝、重複載入不疊、自己出錯不外拋且全部放回、原版的錯照樣外洩、診斷只印一次。
-- --mutants：逐一抽掉每道防線，確認至少一項檢查轉紅。

local PZ_HOME = os.getenv("PZ_HOME") or "D:/SteamLibrary/steamapps/common/ProjectZomboid"
local VANILLA = PZ_HOME .. "/media/lua/shared/TimedActions/"
local FIX = "MOD/MinidoracatFixesFor42/Contents/mods/MinidoracatFixesFor42/42/media/lua/shared/Fixes/MDFX_ChargerIdleGuard.lua"

local realPrint = print

local function readFile(path)
    local f = assert(io.open(path, "rb"))
    local s = f:read("*a")
    f:close()
    return s
end

local SOURCES = { fix = readFile(FIX) }
local VANILLA_FILES = {
    { "ISActivateCarBatteryChargerAction.lua", readFile(VANILLA .. "ISActivateCarBatteryChargerAction.lua") },
    { "ISPlaceCarBatteryChargerAction.lua", readFile(VANILLA .. "ISPlaceCarBatteryChargerAction.lua") },
}

-- ── 假 Java 端 ─────────────────────────────────────────────────────
local prints, handlers, cell, hours, genCalls, nextId

local function newList()
    local L = { items = {}, gets = 0 }
    function L:size() return #self.items end
    function L:get(i)
        self.gets = self.gets + 1
        return self.items[i + 1]
    end
    return L
end

local function newCell()
    local c = { list = newList(), set = {}, rem = {} }
    function c:getProcessIsoObjects() return self.list end
    function c:addToProcessIsoObject(o)
        if o == nil then return end
        self.rem[o] = nil
        if not self.set[o] then
            self.set[o] = true
            self.list.items[#self.list.items + 1] = o
        end
    end
    function c:addToProcessIsoObjectRemove(o)
        if o ~= nil and self.set[o] then self.rem[o] = true end
    end
    function c:process()
        local keep = {}
        for _, o in ipairs(self.list.items) do
            if self.rem[o] then self.set[o] = nil else keep[#keep + 1] = o end
        end
        self.list.items, self.rem = keep, {}
        for i = 1, #keep do keep[i]:update() end
    end
    function c:inList(o) return self.set[o] == true and not self.rem[o] end
    return c
end

local function newSquare(x)
    local sq = { x = x or 100, chunk = {}, objects = {} }
    function sq:getChunk() return self.chunk end
    function sq:AddSpecialObject(o)
        o.square = self
        self.objects[#self.objects + 1] = o
        o:addToWorld()
    end
    return sq
end

local function newObj(class, sq)
    nextId = nextId + 1
    local o = { _class = class, id = nextId, square = sq }
    function o:getSquare() return self.square end
    function o:getObjectIndex()
        if self.square == nil then return -1 end
        for i, v in ipairs(self.square.objects) do
            if v == self then return i - 1 end
        end
        return -1
    end
    function o:getX() return self.square and self.square.x or 0 end
    function o:getY() return 200 end
    function o:getZ() return 0 end
    function o:update() end
    function o:addToWorld() cell:addToProcessIsoObject(self) end
    function o:removeFromWorld() cell:addToProcessIsoObjectRemove(self) end
    return o
end

-- 放進世界（AddSpecialObject：進 square、addToWorld）
local function place(o)
    o.square:AddSpecialObject(o)
    return o
end

local function newCharger(sq, opts)
    opts = opts or {}
    local c = newObj("IsoCarBatteryCharger", sq)
    c.activated, c.battery, c.powered = opts.activated or false, opts.battery, opts.powered ~= false
    c.lastUpdate, c.sound, c.gen = -1, false, 0
    function c:isActivated() return self.activated end
    function c:setActivated(a)
        self.activated = a
        self.gen = self.gen + 1
        genCalls = genCalls + 1
    end
    function c:sync() end
    function c:transmitCompleteItemToClients() end
    function c:update()
        if self.battery == nil then
            self.lastUpdate = -1
            self:setActivated(false)
            self.sound = false
            return
        end
        if not self.powered then self:setActivated(false) end
        if not self.activated then
            self.lastUpdate = -1
            self.sound = false
            return
        end
        self.sound = true
        if self.battery < 1 then
            if self.lastUpdate < 0 then self.lastUpdate = hours end
            local el = hours - self.lastUpdate
            if el > 0 then
                self.battery = math.min(1, self.battery + 0.16666667 * el)
                self.lastUpdate = hours
            end
        end
    end
    return c
end

local function fire(name, a)
    for _, fn in ipairs(handlers[name] or {}) do fn(a) end
end

-- 一幀：IsoCell.update 的 ProcessIsoObject → 遊戲時間前進 → OnTick
local function frames(n)
    for _ = 1, n or 1 do
        cell:process()
        hours = hours + 0.01
        fire("OnTick")
    end
end

local function unloadChunk(sq)
    for _, o in ipairs(sq.objects) do o:removeFromWorld() end
    sq.chunk = nil
end

local function takeAway(o)
    o:removeFromWorld()
    for i, v in ipairs(o.square.objects) do
        if v == o then table.remove(o.square.objects, i) break end
    end
end

local function resetEnv(opts)
    opts = opts or {}
    prints, handlers, hours, genCalls, nextId = {}, {}, 0, 0, 0
    cell = newCell()
    print = function(...)
        local parts = {}
        for i = 1, select("#", ...) do parts[i] = tostring(select(i, ...)) end
        prints[#prints + 1] = table.concat(parts, " ")
    end
    require = function() end
    getCell = function() return cell end
    instanceof = function(o, name) return type(o) == "table" and o._class == name end
    sendRemoveItemFromContainer = function() end
    Events = setmetatable({}, { __index = function(t, name)
        local ev = { Add = function(fn)
            handlers[name] = handlers[name] or {}
            handlers[name][#handlers[name] + 1] = fn
        end }
        rawset(t, name, ev)
        return ev
    end })
    IsoCarBatteryCharger = { new = function(item, c, sq) return newCharger(sq) end }
    ISBaseTimedAction = { derive = function(self, typ) return setmetatable({ Type = typ }, { __index = self }) end }
    ISActivateCarBatteryChargerAction, ISPlaceCarBatteryChargerAction = nil, nil
    MDFX_ChargerIdleGuard = nil
    for _, f in ipairs(VANILLA_FILES) do assert(load(f[2], "=" .. f[1]))() end
end

local function activate(c, on)
    local a = setmetatable({ charger = c, activate = on }, { __index = ISActivateCarBatteryChargerAction })
    return a:complete()
end

local function placeByAction(sq)
    local inv = { Remove = function() end }
    local character = { getSquare = function() return sq end, getInventory = function() return inv end }
    local a = setmetatable({ character = character, charger = {} }, { __index = ISPlaceCarBatteryChargerAction })
    a:complete()
    return sq.objects[#sq.objects]
end

local function printCount(needle)
    local n = 0
    for i = 1, #prints do
        if prints[i]:find(needle, 1, true) then n = n + 1 end
    end
    return n
end

-- ── 測試套件（--mutants 以突變後的原始碼重跑同一套）──────────────────
local function runSuite(srcs, quiet)
    local checks, failures = 0, 0
    local function check(label, cond, detail)
        checks = checks + 1
        if cond then
            if not quiet then realPrint("  PASS  " .. label) end
        else
            failures = failures + 1
            if not quiet then realPrint("  FAIL  " .. label .. (detail and ("  — " .. tostring(detail)) or "")) end
        end
    end
    local function loadFix()
        assert(load(srcs.fix, "=MDFX_ChargerIdleGuard.lua"))()
    end
    local G = function() return MDFX_ChargerIdleGuard end
    -- 一個基地：沒電池 2 台、有電池沒電 1 台、正在充電 1 台，旁邊幾個其他每幀物件
    local function base(withFix)
        resetEnv()
        local sq = newSquare(100)
        local b = {
            empty1 = place(newCharger(sq)),
            empty2 = place(newCharger(sq)),
            unpowered = place(newCharger(sq, { battery = 0.2, powered = false })),
            charging = place(newCharger(sq, { battery = 0.1, activated = true })),
            sq = sq,
        }
        place(newObj("IsoThumpable", sq))
        if withFix then loadFix() end
        return b
    end

    -- 1. 對照組：沒在充電的 3 台每幀各一次 updateGenerator
    local b = base(false)
    frames(100)
    check("1 對照組：每幀 3 次 updateGenerator", genCalls == 300, genCalls)
    check("1 對照組：充電中的照常充電", b.charging.battery > 0.1)

    -- 2. 修正組：連兩次檢查才移出、之後零呼叫、充電照常
    b = base(true)
    frames(15)
    check("2 第一次檢查後還在清單上", cell:inList(b.empty1) and cell:inList(b.unpowered) and G().removed == 0)
    frames(6)
    check("2 第二次檢查後 3 台移出", not cell:inList(b.empty1) and not cell:inList(b.empty2) and not cell:inList(b.unpowered)
        and G().removed == 3 and G().out() == 3, G().removed)
    check("2 充電中的留在清單上", cell:inList(b.charging))
    check("2 移出前原版已停音效、lastUpdate 歸 -1", not b.empty1.sound and b.unpowered.lastUpdate == -1)
    local g0, bat0 = genCalls, b.charging.battery
    frames(100)
    check("2 移出後 updateGenerator 不再增加", genCalls == g0, genCalls - g0)
    check("2 充電中的照常充電", b.charging.battery > bat0)
    check("2 診斷只印一行", printCount("MDFX_ChargerIdleGuard took an idle car battery charger") == 1, table.concat(prints, " | "))
    check("2 診斷不含原版檔名行號", printCount(".lua:") == 0 and printCount(".java:") == 0)
    frames(200)
    check("2 啟動中的充電器從不移出", cell:inList(b.charging) and G().out() == 3)

    -- 3. 包 complete：原版跑完立即放回（同一個呼叫內），下一幀開始充電
    b.unpowered.powered = true
    local ret = activate(b.unpowered, true)
    check("3 complete 回傳值照原版", ret == true)
    check("3 complete 後立即回到清單", cell:inList(b.unpowered) and G().out() == 2 and G().restored == 1)
    frames(5)
    check("3 放回後照常充電", b.unpowered.battery > 0.2 and b.unpowered.sound)

    -- 4. 只經同步改 activated（MP 客戶端看到別人打開）：下一 tick 放回
    b.empty1.activated = true
    frames(1)
    check("4 同步改成啟動後一個 tick 內放回", cell:inList(b.empty1))
    -- 沒電池時原版下一幀自己關掉，之後照常再移出
    frames(25)
    check("4 被引擎關掉後再移出", not cell:inList(b.empty1) and b.empty1.activated == false)

    -- 5. 在清單上的啟動又關閉：檢查計數要重算
    b = base(true)
    frames(10) -- 第一次檢查：empty1 計 1
    activate(b.empty1, true)
    frames(1)
    b.empty1.activated = false -- 不經 complete（例：被引擎關掉）
    frames(10)
    check("5 complete 啟動過就重算：再一次沒啟動不移出", cell:inList(b.empty1))
    b = base(true)
    frames(10)
    b.empty1.activated = true -- 只經同步
    b.empty1.battery = 0.5
    frames(10)                -- 第二次檢查看到啟動
    b.empty1.activated = false
    frames(10)
    check("5 檢查看到啟動就重算：再一次沒啟動不移出", cell:inList(b.empty1))

    -- 6. 拿走、chunk 卸載：丟掉、即使啟動也不放回
    b = base(true)
    frames(21)
    takeAway(b.empty1)
    b.empty1.activated = true
    frames(2)
    check("6 拿走的充電器不放回", not cell:inList(b.empty1) and G().dropped == 1, G().dropped)
    unloadChunk(b.sq)
    b.empty2.activated = true
    frames(11)
    check("6 chunk 卸載後不放回、清單上的也丟掉", not cell:inList(b.empty2) and G().tracked() == 0, G().tracked())

    -- 7. 只讀新增的尾段（數 get 次數）
    b = base(true)
    frames(1)
    local fulls, gets0 = G().fullScans, cell.list.gets
    local sq2 = newSquare(300)
    for _ = 1, 5 do place(newObj("IsoThumpable", sq2)) end
    local fresh = place(newCharger(sq2))
    fire("LoadChunk", {})
    local used = cell.list.gets - gets0
    check("7 LoadChunk 只讀新增的 6 個（+錨點+新錨點）", used == 8 and G().fullScans == fulls, "gets=" .. used .. " fulls=" .. G().fullScans)
    check("7 尾段裡的充電器被找到", G().tracked() == 5)
    frames(21)
    check("7 新找到的照樣移出", not cell:inList(fresh))
    -- 沒有新東西：只讀錨點
    gets0 = cell.list.gets
    fire("LoadChunk", {})
    check("7 沒有新增：只讀 2 次", cell.list.gets - gets0 == 2, cell.list.gets - gets0)

    -- 8. 錨點被移除：退回整份讀
    b = base(true)
    frames(1)
    local last = cell.list.items[#cell.list.items]
    takeAway(last)
    frames(1) -- ProcessIsoObject 拿掉它
    local later = place(newCharger(newSquare(400)))
    fulls = G().fullScans
    fire("LoadChunk", {})
    check("8 錨點不在清單上：整份讀一次", G().fullScans == fulls + 1)
    check("8 整份讀仍找到新的", G().tracked() == 5)
    frames(21)
    check("8 新的照樣移出", not cell:inList(later))

    -- 9. 錨點離開世界：週期檢查時先讀尾段再換錨點
    b = base(true)
    frames(1)
    local oldAnchor = G().anchor()
    local sq3 = newSquare(500)
    local tail = place(newObj("IsoThumpable", sq3))
    unloadChunk(oldAnchor.square)
    frames(10)
    check("9 錨點不在世界上就換掉", G().anchor() ~= oldAnchor and G().anchor() == tail)

    -- 10. 漏抓（沒有事件就進清單的充電器）：照原版跑、不出錯
    b = base(true)
    frames(21)
    local stray = newCharger(newSquare(600))
    stray.square.objects[1] = stray
    cell:addToProcessIsoObject(stray)
    g0 = genCalls
    frames(50)
    check("10 漏抓的充電器照原版每幀 updateGenerator", genCalls - g0 == 50 and cell:inList(stray), genCalls - g0)
    check("10 漏抓不出錯、沒有停用", printCount("disabled") == 0 and G().tracked() == 4)

    -- 11. 客戶端 OnObjectAdded：直接看那個物件，不讀清單
    b = base(true)
    frames(1)
    gets0 = cell.list.gets
    local sent = newCharger(newSquare(700))
    sent.square.objects[1] = sent
    cell:addToProcessIsoObject(sent)
    fire("OnObjectAdded", sent)
    check("11 OnObjectAdded 的充電器被追蹤、沒讀清單", G().tracked() == 5 and cell.list.gets == gets0)
    fire("OnObjectAdded", newObj("IsoThumpable", sent.square))
    check("11 其他物件不追蹤", G().tracked() == 5)

    -- 12. 放置動作：complete 後讀尾段找到新充電器
    b = base(true)
    frames(1)
    local placed = placeByAction(newSquare(800))
    check("12 放置後立即被追蹤", G().tracked() == 5 and placed._class == "IsoCarBatteryCharger")
    frames(21)
    check("12 放置的空充電器照樣移出", not cell:inList(placed))

    -- 13. 自己出錯：不外拋、移出的全部放回、之後照原版
    b = base(true)
    frames(21)
    b.empty1.isActivated = function() error("boom") end
    local okTick = pcall(frames, 1)
    check("13 自己的錯不外拋", okTick)
    check("13 停用時移出的全部放回", cell:inList(b.empty2) and cell:inList(b.unpowered))
    check("13 印一行停用", printCount("disabled for this session") == 1)
    g0 = genCalls
    frames(30)
    check("13 停用後不再移出（照原版）", genCalls - g0 == 90, genCalls - g0)

    -- 14. 原版 complete 的錯原樣外洩
    b = base(true)
    local okC, errC = pcall(activate, { setActivated = function() error("vanilla-boom") end }, true)
    check("14 原版的錯照樣外洩", not okC and tostring(errC):find("vanilla-boom", 1, true) ~= nil, errC)

    -- 15. 重複載入不疊
    b = base(true)
    local wrapped = ISActivateCarBatteryChargerAction.complete
    loadFix()
    check("15 重複載入：包裝不變、事件只掛一次", ISActivateCarBatteryChargerAction.complete == wrapped
        and #handlers.OnTick == 1 and #handlers.LoadChunk == 1)

    -- 16. 形狀不符：不裝
    resetEnv()
    ISActivateCarBatteryChargerAction.complete = nil
    local okL = pcall(loadFix)
    check("16 沒有 complete：印 NOT installed、不掛事件", okL and printCount("NOT installed") == 1 and handlers.OnTick == nil)
    resetEnv()
    local sq = newSquare(100)
    local e = place(newCharger(sq))
    cell.addToProcessIsoObjectRemove = nil
    loadFix()
    local okT = pcall(frames, 25)
    check("16 IsoCell 少方法：印 NOT installed、不動清單", okT and printCount("NOT installed: vanilla IsoCell") == 1 and cell:inList(e),
        table.concat(prints, " | "))
    resetEnv()
    sq = newSquare(100)
    e = place(newCharger(sq))
    e.isActivated = nil
    loadFix()
    okT = pcall(frames, 25)
    check("16 充電器少方法：印 NOT installed、不動清單", okT and printCount("NOT installed: vanilla IsoCarBatteryCharger") == 1 and cell:inList(e),
        table.concat(prints, " | "))

    return checks, failures
end

-- ── 主程式 ───────────────────────────────────────────────────────
local MUTANTS = {
    { name = "不載入修正", whole = true },
    { name = "一次檢查就移出", from = "local IDLE_CHECKS = 2", to = "local IDLE_CHECKS = 1" },
    { name = "移出前不查 isActivated", from = "        elseif o:isActivated() then\n            idle[o] = 0", to = "        elseif false then" },
    { name = "已移出的不查 isActivated", from = "        elseif o:isActivated() then\n            restore(c, i)", to = "        elseif false then" },
    { name = "已移出的不查在不在世界", from = "        if not inWorld(o) then\n            drop(outs, i)", to = "        if false then" },
    { name = "清單上的不查在不在世界", from = "        if not inWorld(o) then\n            drop(ins, i)", to = "        if false then" },
    { name = "在世界不看 chunk", from = "sq:getChunk() ~= nil and ", to = "" },
    { name = "在世界不看 objectIndex", from = " and o:getObjectIndex() ~= -1", to = "" },
    { name = "complete 後不放回", from = "            restore(cell(), i)\n            return", to = "            return" },
    { name = "complete 後不重算檢查次數", from = "    idle[o] = 0\nend", to = "end" },
    { name = "包裝不呼叫後段", from = "        guarded(after, self)\n", to = "" },
    { name = "包裝吞掉原版的錯", from = "        local r = original(self, ...)", to = "        local _, r = pcall(original, self, ...)" },
    { name = "讀清單不在錨點停", from = "        if anchor ~= nil and o == anchor then break end\n", to = "" },
    { name = "不更新錨點", from = "    anchor = n > 0 and list:get(n - 1) or nil\n", to = "" },
    { name = "開局不讀清單", from = "        started = true\n        scan(c)", to = "        started = true" },
    { name = "錨點離開世界不換", from = "    if anchor ~= nil and not inWorld(anchor) then scan(c) end\n", to = "" },
    { name = "不掛 LoadChunk", from = "Events.LoadChunk.Add(function() guarded(G.scan) end)", to = "" },
    { name = "不掛 OnObjectAdded", from = "Events.OnObjectAdded.Add(function(o) guarded(consider, o) end)", to = "" },
    { name = "不包放置動作", from = "wrapAfter(Place, G.scan)", to = "" },
    { name = "拆掉重複載入判斷", from = "if MDFX_ChargerIdleGuard then return end", to = "" },
    { name = "拆掉載入時形狀檢查", from = "and type(Activate.complete) == \"function\"", to = "" },
    { name = "拆掉 IsoCell 形狀檢查", from = "            error(\"shape: IsoCell\")\n", to = "" },
    { name = "拆掉充電器形狀檢查", from = "            error(\"shape: IsoCarBatteryCharger\")\n", to = "" },
    { name = "已知的不去重", from = "    if known[o] then return end\n", to = "" },
    { name = "停用時不放回", from = "        pcall(function() if c ~= nil and inWorld(o) then c:addToProcessIsoObject(o) end end)\n", to = "" },
    { name = "自己的程式不包 pcall", from = "    local ok, err = pcall(fn, a)", to = "    local ok, err = true, fn(a)" },
    { name = "診斷不節流", from = "    if warned[key] then return end\n", to = "" },
    { name = "移出錨點時不換錨點", from = "            if o == anchor then unanchor(c, o) end\n", to = "" },
}

local function replaceOnce(src, from, to)
    local s, e = src:find(from, 1, true)
    if not s then return nil, "pattern not found: " .. from end
    if src:find(from, e + 1, true) then return nil, "pattern not unique: " .. from end
    return src:sub(1, s - 1) .. to .. src:sub(e + 1)
end

local function mutate(m)
    if m.whole then return { fix = "" } end
    local src, why = replaceOnce(SOURCES.fix, m.from, m.to)
    if not src then return nil, why end
    return { fix = src }
end

if arg and arg[1] == "--mutants" then
    local survived, broken = 0, 0
    for _, m in ipairs(MUTANTS) do
        local srcs, why = mutate(m)
        if not srcs then
            broken = broken + 1
            realPrint("  BROKEN    " .. m.name .. " — " .. why)
        else
            local ok, checks, failures = pcall(runSuite, srcs, true)
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

local checks, failures = runSuite(SOURCES, false)
print = realPrint
realPrint("")
realPrint(string.format("%d checks, %d failed", checks, failures))
os.exit(failures == 0 and 0 or 1)
