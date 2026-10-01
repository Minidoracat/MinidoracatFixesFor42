-- MDFX_AnimalCompleteGuard 離線自我檢查
-- 用法（repo 根目錄）： lua scripts/test_animal_complete_guard.lua [--mutants]
--
-- 四個原版動物動作（牽繩、拴樹、裝拖車、手餵）的 complete 照原版行號抄成 stub；server 端
-- NetTimedAction.perform 以 pcallBoolean 呼叫 complete，出錯或不是 true 都走 Reject
-- （NetTimedAction.java:132-139、ActionManager.java:64-97）。驗證：
--   * isServer() 為假時完全不安裝
--   * 動物存在時四個 complete 原樣透傳（回傳值、副作用、原函式恰一次），不印診斷
--   * 動物為 nil：不呼叫原函式、回 false、不拋錯（perform 走 Reject 但不失敗），每個動作恰一行診斷且欄位齊全
--   * 對照組：原版四個 complete 對 nil 動物都拋錯（perform 失敗走 Reject）；裝拖車從手上放入時，
--     IsoAnimal 多載先把 nil 加進拖車清單（BaseVehicle.java:10615）
--   * 每 session 上限 20 行（四個動作共用）＋一次上限提示
--   * 不吞不認識的錯誤：動物存在時原函式自己拋的錯原樣外洩
--   * 重複載入不疊 wrapper；後載 MOD 整支替換後 OnGameBoot 復查重新包裝
--   * 四個 class 各自安裝：缺一個只影響它自己；除 marker 外不動 class 既有成員
-- --mutants：逐一抽掉每道防線（含整支修正與 MDFX_Guard 骨架），確認至少一項檢查轉紅。

local S = dofile("scripts/_stub.lua")
local realPrint = S.realPrint

local function readFile(path)
    local f = assert(io.open(path, "rb"))
    local s = f:read("*a")
    f:close()
    return s
end

local SOURCES = {
    fix = readFile(S.SERVER_FIXES .. "MDFX_AnimalCompleteGuard.lua"),
    guard = readFile(S.GUARD),
}

local CLASSES = { "ISAttachAnimalToPlayer", "ISAttachAnimalToTree", "ISAddAnimalInTrailer", "ISFeedAnimalFromHand" }
local MARKERS = {
    ISAttachAnimalToPlayer = "MDFX_attachAnimalToPlayerGuard",
    ISAttachAnimalToTree = "MDFX_attachAnimalToTreeGuard",
    ISAddAnimalInTrailer = "MDFX_addAnimalInTrailerGuard",
    ISFeedAnimalFromHand = "MDFX_feedAnimalFromHandGuard",
}

-- ── 假物件 ───────────────────────────────────────────────────────
local CALLS -- 原函式呼叫次數與原版全域送出的封包

local function newList()
    local l = { n = 0, items = {} }
    function l:add(x) self.n = self.n + 1; self.items[self.n] = x end -- Java ArrayList 也收 null
    function l:remove(x)
        for i = 1, self.n do
            if self.items[i] == x then
                table.remove(self.items, i)
                self.n = self.n - 1
                return true
            end
        end
        return false
    end
    return l
end

local function newPlayer(name, x, y, z)
    local p = { attached = newList() }
    function p:getUsername() return name end
    function p:getX() return x end
    function p:getY() return y end
    function p:getZ() return z end
    function p:getAttachedAnimals() return self.attached end
    function p:removeAttachedAnimal(a) self.attached:remove(a) end
    return p
end

local function newAnimal()
    local data = {}
    function data:getAttachedTree() return self.tree end
    function data:setAttachedTree(t) self.tree = t end
    function data:getAttachedPlayer() return self.player end
    function data:setAttachedPlayer(p) self.player = p end
    local sq = {}
    function sq:getX() return 10 end
    function sq:getY() return 20 end
    function sq:getZ() return 0 end
    local behavior = {}
    function behavior:setBlockMovement(v) self.blocked = v end
    local a = { _class = "IsoAnimal", data = data, behavior = behavior, fed = 0 }
    function a:getData() return data end
    function a:getSquare() return sq end
    function a:getBehavior() return behavior end
    function a:feedFromHand(chr, food) self.fed = self.fed + 1 end
    function a:setVehicle(v) self.vehicle = v end
    return a
end

local function newVehicle()
    local v = { animals = newList(), updates = 0 }
    function v:updateParts() self.updates = self.updates + 1 end
    function v:getAreaDist(area, x, y, z) return 1 end
    -- BaseVehicle.java:10614-10616（IsoAnimal 多載）：先加進清單，下一行才對動物取值
    function v:addAnimalFromHandsInTrailer(animal, player)
        self.animals:add(animal)
        animal:setVehicle(self)
    end
    function v:addAnimalInTrailer(animal) self.animals:add(animal) end -- :10647-10648
    return v
end

-- ── vanilla stub（shared/TimedActions/Animals/）──────────────────
local vanilla = {}

vanilla.ISAttachAnimalToPlayer = function(self) -- ISAttachAnimalToPlayer.lua:40-53
    CALLS.ISAttachAnimalToPlayer = CALLS.ISAttachAnimalToPlayer + 1
    if not self.remove then
        if self.animal:getData():getAttachedTree() then -- :42
            self.animal:getData():setAttachedTree(nil)
        end
        self.character:getAttachedAnimals():add(self.animal)
        self.animal:getData():setAttachedPlayer(self.character)
    else
        self.character:getAttachedAnimals():remove(self.animal)
        self.animal:getData():setAttachedPlayer(nil) -- :50
    end
    return true
end

vanilla.ISAttachAnimalToTree = function(self) -- ISAttachAnimalToTree.lua:40-53
    CALLS.ISAttachAnimalToTree = CALLS.ISAttachAnimalToTree + 1
    if self.remove then
        self.animal:getData():setAttachedTree(nil) -- :42
        self.character:getAttachedAnimals():add(self.animal)
        self.animal:getData():setAttachedPlayer(self.character)
    else
        self.animal:getData():setAttachedTree(self.tree) -- :47
        self.character:removeAttachedAnimal(self.animal)
        self.animal:getData():setAttachedPlayer(nil)
    end
    return true
end

vanilla.ISAddAnimalInTrailer = function(self) -- ISAddAnimalInTrailer.lua:60-82
    CALLS.ISAddAnimalInTrailer = CALLS.ISAddAnimalInTrailer + 1
    self.vehicle:updateParts() -- :63
    if self.fromHand then
        self.vehicle:addAnimalFromHandsInTrailer(self.animal, self.character) -- :66
        sendAddAnimalFromHandsInTrailer(self.animal, self.character, self.vehicle)
    else
        local distCheck = 3
        if instanceof(self.animal, "IsoAnimal") then
            if self.animal:getData():getAttachedPlayer() == self.character then distCheck = 5 end
        end
        if self.vehicle:getAreaDist("AnimalEntry", self.animal:getSquare():getX(), self.animal:getSquare():getY(), self.animal:getSquare():getZ()) <= distCheck then -- :76
            self.vehicle:addAnimalInTrailer(self.animal)
        end
    end
    return true
end

vanilla.ISFeedAnimalFromHand = function(self) -- ISFeedAnimalFromHand.lua:45-51
    CALLS.ISFeedAnimalFromHand = CALLS.ISFeedAnimalFromHand + 1
    self.animal:getBehavior():setBlockMovement(false) -- :46
    self.animal:feedFromHand(self.character, self.food)
    sendFeedAnimalFromHand(self.animal, self.character, self.food)
    return true
end

function sendAddAnimalFromHandsInTrailer() CALLS.sent = CALLS.sent + 1 end
function sendFeedAnimalFromHand() CALLS.sent = CALLS.sent + 1 end

-- new() 的欄位（各檔的 :new）；server 解析不到動物時 animal 是 nil
local function newAction(class, animal, opts)
    opts = opts or {}
    local a = setmetatable({ character = opts.character, animal = animal }, { __index = _G[class] })
    if a.character == nil and not opts.noCharacter then a.character = newPlayer("tester", 10.7, 20.2, 0) end
    a.remove = opts.remove
    a.fromHand = opts.fromHand
    a.tree = opts.tree
    a.food = opts.food
    if class == "ISAddAnimalInTrailer" and not opts.noVehicle then a.vehicle = opts.vehicle or newVehicle() end
    return a
end

-- NetTimedAction.perform（:132-139）：pcallBoolean 出錯或不是 boolean 都是 null，拆箱 NPE 被 catch 成 false
local function perform(action)
    local ok, r = pcall(action.complete, action)
    return (ok and r == true) and "Done" or "Reject", ok, r
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
    local function section(title)
        if not quiet then realPrint(title) end
    end

    local function resetEnv(asServer)
        S.reset({ server = asServer })
        MDFX_Guard = nil
        assert(load(srcs.guard, "=MDFX_Guard.lua"))()
        CALLS = { sent = 0 }
        for _, class in ipairs(CLASSES) do
            CALLS[class] = 0
            _G[class] = { complete = vanilla[class], someOtherMember = "keep" }
        end
    end
    local function loadFix()
        assert(load(srcs.fix, "=MDFX_AnimalCompleteGuard.lua"))()
    end
    local function diagCount()
        return S.printCount("MDFX_AnimalCompleteGuard nilAnimal n=")
    end

    -- 1 ───────────────────────────────────────────────────────────
    section("[1] isServer() 為假時零介入")
    resetEnv(false)
    loadFix()
    S.fireBoot()
    local untouched = true
    for _, class in ipairs(CLASSES) do
        if _G[class].complete ~= vanilla[class] or _G[class][MARKERS[class]] ~= nil then untouched = false end
    end
    check("1 四個 complete 都不包裝、不留 marker", untouched)
    check("1 不印任何訊息", #S.prints == 0, table.concat(S.prints, " | "))

    -- 2 ───────────────────────────────────────────────────────────
    section("[2] 動物存在時原樣透傳")
    resetEnv(true)
    loadFix()
    local chr = newPlayer("tester", 10.7, 20.2, 0)
    local animal = newAnimal()
    local act = newAction("ISAttachAnimalToPlayer", animal, { character = chr })
    local verdict = perform(act)
    check("2 牽繩：Done、原函式一次、動物牽到玩家身上",
        verdict == "Done" and CALLS.ISAttachAnimalToPlayer == 1 and chr.attached.n == 1 and animal.data.player == chr)
    act = newAction("ISAttachAnimalToPlayer", animal, { character = chr, remove = true })
    verdict = perform(act)
    check("2 解開牽繩：Done、動物離開玩家", verdict == "Done" and chr.attached.n == 0 and animal.data.player == nil)
    act = newAction("ISAttachAnimalToTree", animal, { character = chr, tree = "tree" })
    verdict = perform(act)
    check("2 拴樹：Done、原函式一次、動物拴上", verdict == "Done" and CALLS.ISAttachAnimalToTree == 1 and animal.data.tree == "tree")
    local vehicle = newVehicle()
    act = newAction("ISAddAnimalInTrailer", animal, { character = chr, vehicle = vehicle })
    verdict = perform(act)
    check("2 裝拖車：Done、原函式一次、動物進了拖車",
        verdict == "Done" and CALLS.ISAddAnimalInTrailer == 1 and vehicle.animals.n == 1 and vehicle.animals.items[1] == animal)
    act = newAction("ISFeedAnimalFromHand", animal, { character = chr, food = "Base.Carrots" })
    verdict = perform(act)
    check("2 手餵：Done、原函式一次、動物吃到", verdict == "Done" and CALLS.ISFeedAnimalFromHand == 1 and animal.fed == 1)
    check("2 不印診斷", #S.prints == 0, table.concat(S.prints, " | "))

    -- 3 ───────────────────────────────────────────────────────────
    section("[3] 動物為 nil：拒絕、不拋錯、每個動作一行")
    resetEnv(true)
    loadFix()
    local results = {}
    vehicle = newVehicle()
    local cases = {
        { class = "ISAttachAnimalToPlayer", opts = {}, flag = " remove=false;" },
        { class = "ISAttachAnimalToTree", opts = { remove = true, tree = "tree" }, flag = " remove=true;" },
        { class = "ISAddAnimalInTrailer", opts = { fromHand = true, vehicle = vehicle }, flag = " fromHand=true;" },
        { class = "ISFeedAnimalFromHand", opts = { food = "Base.Carrots" }, flag = ";" },
    }
    for i, c in ipairs(cases) do
        local v, ok, r = perform(newAction(c.class, nil, c.opts))
        results[i] = { verdict = v, ok = ok, ret = r }
        check("3 " .. c.class .. "：回 false、不拋錯、Reject", ok and r == false and v == "Reject", tostring(r))
        check("3 " .. c.class .. "：原函式沒被呼叫", CALLS[c.class] == 0)
        check("3 " .. c.class .. "：診斷欄位齊全",
            S.printed("MDFX_AnimalCompleteGuard nilAnimal n=" .. i .. " action=" .. c.class
                .. ' player="tester" x=10 y=20 z=0' .. c.flag), S.prints[i])
    end
    check("3 四個動作各一行", diagCount() == 4, diagCount())
    check("3 拖車清單沒被動到、沒有 updateParts、沒送封包",
        vehicle.animals.n == 0 and vehicle.updates == 0 and CALLS.sent == 0)

    -- 4 ───────────────────────────────────────────────────────────
    section("[4] 對照組：原版（不載入修正）")
    resetEnv(true)
    local allThrow = true
    for _, c in ipairs(cases) do
        local opts = {}
        for k, v in pairs(c.opts) do opts[k] = v end
        if c.class == "ISAddAnimalInTrailer" then opts.fromHand = false; opts.vehicle = newVehicle() end
        local v, ok = perform(newAction(c.class, nil, opts))
        if ok or v ~= "Reject" then allThrow = false end
    end
    check("4 原版四個 complete 對 nil 動物都拋錯、perform 失敗走 Reject", allThrow)
    vehicle = newVehicle()
    local v4, ok4 = perform(newAction("ISAddAnimalInTrailer", nil, { fromHand = true, vehicle = vehicle }))
    check("4 原版裝拖車從手上放入：先 updateParts，IsoAnimal 多載把 nil 加進拖車清單後才拋錯",
        not ok4 and v4 == "Reject" and vehicle.updates == 1 and vehicle.animals.n == 1 and vehicle.animals.items[1] == nil)
    check("4 原版不印本補丁的診斷", not S.printed("[MinidoracatFixes]"))

    -- 5 ───────────────────────────────────────────────────────────
    section("[5] 每 session 上限（四個動作共用）")
    resetEnv(true)
    loadFix()
    local allRejected = true
    for i = 1, 25 do
        local class = CLASSES[(i - 1) % #CLASSES + 1]
        local v, ok, r = perform(newAction(class, nil, {}))
        if not ok or r ~= false or v ~= "Reject" then allRejected = false end
    end
    check("5 25 個動作全部回 false、不拋錯", allRejected)
    check("5 只記前 20 行", diagCount() == 20, diagCount())
    check("5 第 20 行編號正確", S.printed("nilAnimal n=20 action="))
    check("5 上限提示恰一次", S.printCount("MDFX_AnimalCompleteGuard limit=20 reached") == 1)

    -- 6 ───────────────────────────────────────────────────────────
    section("[6] 不吞不認識的錯誤")
    resetEnv(true)
    loadFix()
    local okT, errT = pcall(ISAddAnimalInTrailer.complete, newAction("ISAddAnimalInTrailer", newAnimal(), { noVehicle = true }))
    check("6 動物存在、載具解析不到：原版的錯原樣外洩", not okT and tostring(errT):find("vehicle", 1, true) ~= nil, errT)
    resetEnv(true)
    ISFeedAnimalFromHand.complete = function() error("some future vanilla problem") end
    loadFix()
    local okF, errF = pcall(ISFeedAnimalFromHand.complete, newAction("ISFeedAnimalFromHand", newAnimal(), {}))
    check("6 動物存在時原函式自己拋的錯原樣外洩", not okF and tostring(errF):find("some future vanilla problem", 1, true) ~= nil)
    check("6 不印診斷", not S.printed("[MinidoracatFixes]"))

    -- 7 ───────────────────────────────────────────────────────────
    section("[7] 重複載入與後載替換")
    resetEnv(true)
    loadFix()
    local wrapped = {}
    for _, class in ipairs(CLASSES) do wrapped[class] = _G[class].complete end
    local allWrapped = true
    for _, class in ipairs(CLASSES) do
        if wrapped[class] == vanilla[class] then allWrapped = false end
    end
    check("7 四個 complete 都換成 wrapper", allWrapped)
    loadFix()
    S.fireBoot()
    local same = true
    for _, class in ipairs(CLASSES) do
        if _G[class].complete ~= wrapped[class] then same = false end
    end
    check("7 重複載入、OnGameBoot 復查都不再包裝", same)
    perform(newAction("ISFeedAnimalFromHand", newAnimal(), {}))
    check("7 原函式恰被呼叫一次", CALLS.ISFeedAnimalFromHand == 1)

    local otherCalls = 0
    ISAttachAnimalToPlayer.complete = function(self) otherCalls = otherCalls + 1; return true end
    S.fireBoot()
    local v7, ok7, r7 = perform(newAction("ISAttachAnimalToPlayer", nil, {}))
    check("7 後載 MOD 整支替換後，nil 動物仍被擋下", ok7 and r7 == false and otherCalls == 0)
    perform(newAction("ISAttachAnimalToPlayer", newAnimal(), {}))
    check("7 正常路徑透傳到後載 MOD 的版本", otherCalls == 1)

    -- 8 ───────────────────────────────────────────────────────────
    section("[8] vanilla 缺席：只影響那一個 class")
    resetEnv(true)
    ISAttachAnimalToTree = nil
    ISFeedAnimalFromHand.complete = nil
    local ok8 = pcall(loadFix)
    check("8 有 class 缺席時不炸", ok8)
    check("8 缺席的兩個各印一次 NOT installed",
        S.printCount("attachAnimalToTreeGuard NOT installed") == 1 and S.printCount("feedAnimalFromHandGuard NOT installed") == 1)
    check("8 不建立假表、不補 complete", ISAttachAnimalToTree == nil and ISFeedAnimalFromHand.complete == nil)
    check("8 其他兩個照常安裝",
        ISAttachAnimalToPlayer.complete ~= vanilla.ISAttachAnimalToPlayer
        and ISAddAnimalInTrailer.complete ~= vanilla.ISAddAnimalInTrailer)

    -- 9 ───────────────────────────────────────────────────────────
    section("[9] 成員快照")
    resetEnv(true)
    local before = {}
    for _, class in ipairs(CLASSES) do before[class] = S.snapshotKeys(_G[class]) end
    loadFix()
    local onlyMarkers, anchored = true, true
    for _, class in ipairs(CLASSES) do
        if #S.extraKeys(_G[class], before[class], MARKERS[class]) ~= 0 then onlyMarkers = false end
        if _G[class][MARKERS[class]] ~= _G[class].complete or _G[class].someOtherMember ~= "keep" then anchored = false end
    end
    check("9 每個 class 只新增自己的 marker", onlyMarkers)
    check("9 marker 錨在 complete、其他成員不動", anchored)

    -- 10 ──────────────────────────────────────────────────────────
    section("[10] 診斷自己不炸")
    resetEnv(true)
    loadFix()
    local v10, ok10, r10 = perform(newAction("ISFeedAnimalFromHand", nil, { noCharacter = true }))
    check("10 角色也是 nil：照樣回 false", ok10 and r10 == false)
    check("10 欄位以 ? 標示", S.printed("nilAnimal n=1 action=ISFeedAnimalFromHand player=? x=? y=? z=?;"), S.prints[1])

    return checks, failures
end

-- ── 主程式 ───────────────────────────────────────────────────────
local MUTANTS = {
    { name = "不載入修正", whole = "fix" },
    { name = "complete 不判 nil", file = "fix",
        from = "if self.animal then return originals.complete(self) end", to = "if true then return originals.complete(self) end" },
    { name = "complete 回 true", file = "fix", from = "                    return false\n", to = "                    return true\n" },
    { name = "不記診斷", file = "fix",
        from = 'print("[MinidoracatFixes] MDFX_AnimalCompleteGuard nilAnimal n="',
        to = 'local _ = ("[MinidoracatFixes] MDFX_AnimalCompleteGuard nilAnimal n="' },
    { name = "旗標欄位拿掉", file = "fix",
        from = '(flag and (" " .. flag .. "=" .. tostring(self[flag] == true)) or "")', to = '""' },
    { name = "沒有 session 上限", file = "fix", from = "if logged <= LOG_LIMIT then", to = "if true then" },
    { name = "漏包手餵", file = "fix", from = 'guard("feedAnimalFromHandGuard", "ISFeedAnimalFromHand")\n', to = "" },
    { name = "MDFX_Guard 拆掉 isServer() 閘門", file = "guard",
        from = 'if type(isServer) == "function" and isServer() then', to = "if true then" },
    { name = "MDFX_Guard 拆掉冪等 marker", file = "guard", from = "if cls[marker] == cls[anchor] then", to = "if false then" },
    { name = "MDFX_Guard 拆掉診斷節流", file = "guard", from = "if warned[key] then", to = "if false then" },
}

local function mutate(m)
    local srcs = { fix = SOURCES.fix, guard = SOURCES.guard }
    if m.whole then
        srcs[m.whole] = ""
        return srcs
    end
    local src = srcs[m.file]
    local s, e = src:find(m.from, 1, true)
    if not s then return nil, "pattern not found: " .. m.from end
    if src:find(m.from, e + 1, true) then return nil, "pattern not unique: " .. m.from end
    srcs[m.file] = src:sub(1, s - 1) .. m.to .. src:sub(e + 1)
    return srcs
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
