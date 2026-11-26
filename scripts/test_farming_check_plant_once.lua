-- MDFX_FarmingCheckPlantOnce 離線自我檢查
-- 用法（repo 根目錄）： lua scripts/test_farming_check_plant_once.lua [--mutants]
--
-- 照載本機遊戲原版 server/Farming/SFarmingSystem.lua 的 checkPlant 本體與
-- server/Map/SGlobalObjectSystem.lua 的 getLuaObjectByIndex（PZ_HOME 可改安裝目錄），
-- 底下接假的 Java system（越界回 nil，同 GlobalObjectSystem.getObjectByIndex），和修正版跑同一份假作物表，比對：
--   * checkPlant2／plowFadeCheck 的呼叫順序、次數、拋錯，逐一與原版相同
--     （正常、中途空值、反向時移除、正向時增減物件、checkPlant2 拋錯、空表）
--   * 取物件的次數剛好是原版的一半
--   * 經 self: 呼叫，安裝後別的 MOD 包的 checkPlant2 照樣生效
--   * 安裝後 getLuaObjectByIndex 被換成兩次結果不同的版本 → 整輪照原版
--   * 只換原版檔案、試跑序列與原版相同的函式；別的 MOD 覆寫、別的檔案、同檔別支函式、官方改過的本體、
--     getter 不是原版、來源查不到、形狀不符都不裝；客戶端不裝
--   * 本檔重跑不疊、不印 NOT installed；ResetLua 後重新安裝；installed 只印一次
-- --mutants：逐一抽掉每道防線，確認至少一項檢查轉紅。

local S = dofile("scripts/_stub.lua")
local PZ_HOME = os.getenv("PZ_HOME") or "D:/SteamLibrary/steamapps/common/ProjectZomboid"
local VANILLA_PATH = PZ_HOME .. "/media/lua/server/Farming/SFarmingSystem.lua"
local GOS_PATH = PZ_HOME .. "/media/lua/server/Map/SGlobalObjectSystem.lua"
local FIX = S.SERVER_FIXES .. "MDFX_FarmingCheckPlantOnce.lua"

local function readFile(path)
    local f = assert(io.open(path, "rb"))
    local s = f:read("*a")
    f:close()
    return s
end

local VANILLA_SRC = readFile(VANILLA_PATH):match("\n(function SFarmingSystem:checkPlant%(%).-\nend)\r?\n")
assert(VANILLA_SRC, "vanilla SFarmingSystem:checkPlant not found in " .. VANILLA_PATH)
local GETTER_SRC = readFile(GOS_PATH):match("\n(function SGlobalObjectSystem:getLuaObjectByIndex%(index%).-\nend)\r?\n")
assert(GETTER_SRC, "vanilla SGlobalObjectSystem:getLuaObjectByIndex not found in " .. GOS_PATH)
local SOURCES = { fix = readFile(FIX) }

-- 原版 checkPlant 每次編一個新 closure，來源記成原版檔路徑（getFilenameOfClosure 看得到）；
-- src 可換成別的本體（同檔別支函式、官方改過的版本）
local function vanillaCheckPlant(chunkname, src)
    local saved = SFarmingSystem
    SFarmingSystem = {}
    assert(load(src or VANILLA_SRC, "@" .. (chunkname or VANILLA_PATH)))()
    local fn = SFarmingSystem.checkPlant
    SFarmingSystem = saved
    return fn
end

local function vanillaGetter(chunkname)
    local saved = SGlobalObjectSystem
    SGlobalObjectSystem = {}
    assert(load(GETTER_SRC, "@" .. (chunkname or GOS_PATH)))()
    local fn = SGlobalObjectSystem.getLuaObjectByIndex
    SGlobalObjectSystem = saved
    return fn
end

-- 同檔的別支函式（來源檔對、行為不同），與官方已改成每輪取一次的本體：試跑都對不上原版
local OTHER_SRC = "function SFarmingSystem:checkPlant()\n\tfor i=1,self:getLuaObjectCount() do\n"
    .. "\t\tlocal o = self:getLuaObjectByIndex(i)\n\t\tif o then self:checkPlant2(o) end\n\tend\nend"
local OFFICIAL_FIX_SRC = "function SFarmingSystem:checkPlant()\n\tfor i=1,self:getLuaObjectCount() do\n"
    .. "\t\tlocal luaObject = self:getLuaObjectByIndex(i)\n\t\tif not luaObject then break end\n"
    .. "\t\tself:checkPlant2(luaObject)\n\tend\n\tlocal i = self:getLuaObjectCount()\n\twhile i > 0 do\n"
    .. "\t\tlocal luaObject = self:getLuaObjectByIndex(i)\n\t\tif not luaObject then break end\n"
    .. "\t\tself:plowFadeCheck(luaObject)\n\t\ti = i - 1\n\tend\nend"
-- 改過的本體：迴圈裡多了別的呼叫與欄位讀取、多傳一個參數、停不下來（每輪都記在全域 PROBE_ITERS）
local UNKNOWN_SRC = VANILLA_SRC:gsub("self:checkPlant2%(luaObject%)",
    "if luaObject.state ~= nil then self:checkPlant2(luaObject) end self:noise()", 1)
local EXTRA_ARG_SRC = VANILLA_SRC:gsub("self:plowFadeCheck%(luaObject%)", "self:plowFadeCheck(luaObject, true)", 1)
local RUNAWAY_SRC = "function SFarmingSystem:checkPlant()\n\tfor k = 1, 1000 do\n\t\tPROBE_ITERS = k\n"
    .. "\t\tself:getLuaObjectCount()\n\tend\nend"
-- 改過的本體：寫作物欄位、寫 self 欄位（只讀不呼叫的話試跑看不出來）
local WRITE_CROP_SRC = VANILLA_SRC:gsub("self:checkPlant2%(luaObject%)", "luaObject.checked = true self:checkPlant2(luaObject)", 1)
local WRITE_SELF_SRC = VANILLA_SRC:gsub("self:plowFadeCheck%(luaObject%)", "self.lastFade = i self:plowFadeCheck(luaObject)", 1)

-- ── 假 SFarmingSystem：作物表是 objs[1..n]，可以有空格 ─────────────────
local function newClass()
    local cls = {}
    function cls:getLuaObjectCount() return self.n end
    cls.getLuaObjectByIndex = vanillaGetter()
    function cls:checkPlant2(o)
        self.trace[#self.trace + 1] = "c:" .. o.id
        if o.onCheck then o.onCheck(self, o) end
    end
    function cls:plowFadeCheck(o)
        self.trace[#self.trace + 1] = "f:" .. o.id
        if o.onFade then o.onFade(self, o) end
    end
    cls.checkPlant = vanillaCheckPlant()
    return cls
end

local function removeAt(sys, o)
    for i = 1, sys.n do
        if sys.objs[i] == o then
            for j = i, sys.n - 1 do sys.objs[j] = sys.objs[j + 1] end
            sys.objs[sys.n] = nil
            sys.n = sys.n - 1
            return
        end
    end
end

local function append(sys, id)
    sys.n = sys.n + 1
    sys.objs[sys.n] = { id = id }
end

-- spec(sys)：放作物與 hook；同一份 spec 給原版與修正版各建一份
local function newSystem(cls, n, spec)
    local sys = setmetatable({ n = n, objs = {}, trace = {}, gets = 0 }, { __index = cls })
    -- 假的 Java GlobalObjectSystem：越界回 nil（原版 getter 接著對 nil 取 modData 就拋錯）
    sys.system = { getObjectByIndex = function(_, idx)
        sys.gets = sys.gets + 1
        if idx < 0 or idx >= sys.n then return nil end
        return { getModData = function() return sys.objs[idx + 1] end }
    end }
    for i = 1, n do sys.objs[i] = { id = "p" .. i } end
    if spec then spec(sys) end
    return sys
end

local function run(sys)
    local ok, err = pcall(sys.checkPlant, sys)
    return { ok = ok, err = err and tostring(err), trace = table.concat(sys.trace, ","), gets = sys.gets }
end

local CASES = {
    { name = "正常 6 株", n = 6 },
    { name = "第 4 格是空值（兩個迴圈各自中止）", n = 6, spec = function(sys) sys.objs[4] = nil end },
    { name = "反向時移除正在檢查的那株", n = 6, spec = function(sys) sys.objs[3].onFade = removeAt end },
    { name = "正向時新增一株（次數照開頭）", n = 6, spec = function(sys)
        sys.objs[2].onCheck = function(s) append(s, "p7") end
    end },
    { name = "正向時少一株（越界拋錯）", n = 6, spec = function(sys)
        sys.objs[2].onCheck = function(s) removeAt(s, s.objs[6]) end
    end },
    { name = "checkPlant2 拋錯", n = 6, spec = function(sys)
        sys.objs[3].onCheck = function() error("vanilla checkPlant2 boom", 0) end
    end },
    { name = "空表", n = 0 },
}

-- ── 測試套件（--mutants 以突變後的原始碼重跑同一套）──────────────────
local function runSuite(srcs, quiet)
    local checks, failures = 0, 0
    local function check(label, cond, detail)
        checks = checks + 1
        if cond then
            if not quiet then S.realPrint("  PASS  " .. label) end
        else
            failures = failures + 1
            if not quiet then S.realPrint("  FAIL  " .. label .. (detail and ("  — " .. tostring(detail)) or "")) end
        end
    end
    local function section(title) if not quiet then S.realPrint(title) end end

    local client
    local function env(asClient)
        S.reset({ server = not asClient })
        client = asClient and true or false
        isClient = function() return client end
        require = function() end
        getFilenameOfClosure = function(fn)
            local src = debug.getinfo(fn, "S").source
            return src:sub(1, 1) == "@" and src:sub(2) or src
        end
        SFarmingSystem = newClass()
        return SFarmingSystem
    end
    local function loadFix()
        assert(load(srcs.fix, "@" .. FIX))()
    end

    -- 1. 安裝
    section("[1] 安裝")
    local cls = env(false)
    local vanilla = cls.checkPlant
    local okLoad, errLoad = pcall(loadFix)
    check("1 載入不拋錯", okLoad, errLoad)
    check("1 換掉原版 checkPlant", cls.checkPlant ~= vanilla)
    check("1 marker 指向現任", cls.MDFX_checkPlantOnce ~= nil and cls.MDFX_checkPlantOnce == cls.checkPlant)
    check("1 印 installed 一次", S.printCount("MDFX_FarmingCheckPlantOnce installed") == 1)
    local mine = cls.checkPlant
    pcall(loadFix)
    check("1 本檔重跑不疊", cls.checkPlant == mine)
    check("1 本檔重跑不把自己當成別人的", not S.printed("NOT installed"))

    -- 2. 與原版逐一相同、取物件少一半
    section("[2] 與原版相同")
    for _, case in ipairs(CASES) do
        local fixed = run(newSystem(cls, case.n, case.spec))
        local ref = run(newSystem(newClass(), case.n, case.spec))
        check("2 " .. case.name .. "：呼叫順序與次數同原版", fixed.trace == ref.trace, fixed.trace .. " vs " .. ref.trace)
        check("2 " .. case.name .. "：拋錯同原版", fixed.ok == ref.ok and fixed.err == ref.err,
            tostring(fixed.err) .. " vs " .. tostring(ref.err))
        if case.n == 6 and not case.spec then
            check("2 正常時取物件次數＝原版的一半", fixed.gets * 2 == ref.gets and fixed.gets == 12,
                fixed.gets .. " vs " .. ref.gets)
        else
            check("2 " .. case.name .. "：取物件不比原版多", fixed.gets <= ref.gets, fixed.gets .. " vs " .. ref.gets)
        end
    end
    local spot = run(newSystem(cls, 3))
    check("2 正向 checkPlant2、再反向 plowFadeCheck", spot.trace == "c:p1,c:p2,c:p3,f:p3,f:p2,f:p1", spot.trace)

    -- 3. 經 self: 呼叫：安裝後別的 MOD 包的 checkPlant2 照樣生效
    section("[3] 別的 MOD 包的 method")
    local inner = cls.checkPlant2
    cls.checkPlant2 = function(self, o)
        self.trace[#self.trace + 1] = "w:" .. o.id
        return inner(self, o)
    end
    local wrapped = run(newSystem(cls, 2))
    check("3 安裝後才包的 checkPlant2 也被呼叫", wrapped.trace == "w:p1,c:p1,w:p2,c:p2,f:p2,f:p1", wrapped.trace)
    local innerFade = cls.plowFadeCheck
    cls.plowFadeCheck = function(self, o)
        self.trace[#self.trace + 1] = "x:" .. o.id
        return innerFade(self, o)
    end
    wrapped = run(newSystem(cls, 2))
    check("3 安裝後才包的 plowFadeCheck 也被呼叫", wrapped.trace == "w:p1,c:p1,w:p2,c:p2,x:p2,f:p2,x:p1,f:p1", wrapped.trace)

    -- 4. ResetLua：新的類別表重新安裝
    section("[4] ResetLua")
    cls = env(false)
    vanilla = cls.checkPlant
    loadFix()
    check("4 新類別表重新安裝", cls.checkPlant ~= vanilla and cls.MDFX_checkPlantOnce == cls.checkPlant)

    -- 5. 只換原版檔案的函式
    section("[5] 來源判斷")
    cls = env(false)
    local modFn = vanillaCheckPlant("C:/Users/x/Zomboid/mods/FarmMod/42/media/lua/server/Farming/SFarmingSystem.lua")
    cls.checkPlant = modFn
    loadFix()
    check("5 別的 MOD 覆寫的（同檔名）不碰", cls.checkPlant == modFn)
    check("5 印 NOT installed 並指出來源", S.printed("MDFX_FarmingCheckPlantOnce NOT installed for SFarmingSystem.checkPlant")
        and S.printed("mods/FarmMod"))
    check("5 不印 installed", not S.printed("MDFX_FarmingCheckPlantOnce installed"))

    cls = env(false)
    local other = vanillaCheckPlant(PZ_HOME .. "/media/lua/server/Map/SGlobalObjectSystem.lua")
    cls.checkPlant = other
    loadFix()
    check("5 別的檔案定義的不碰", cls.checkPlant == other)

    cls = env(false)
    vanilla = vanillaCheckPlant((VANILLA_PATH:gsub("/", "\\")))
    cls.checkPlant = vanilla
    loadFix()
    check("5 Windows 反斜線路徑也認得是原版", cls.checkPlant ~= vanilla and S.printed("MDFX_FarmingCheckPlantOnce installed"))

    cls = env(false)
    vanilla = cls.checkPlant
    getFilenameOfClosure = nil
    okLoad = pcall(loadFix)
    check("5 缺 getFilenameOfClosure → 不炸、不裝", okLoad and cls.checkPlant == vanilla and S.printed("NOT installed"))

    cls = env(false)
    vanilla = cls.checkPlant
    getFilenameOfClosure = function() error("no source") end
    okLoad = pcall(loadFix)
    check("5 查來源拋錯 → 不炸、不裝", okLoad and cls.checkPlant == vanilla and S.printed("no known source"))

    -- 6. 形狀不符、客戶端
    section("[6] 形狀與端")
    env(false)
    SFarmingSystem = nil
    okLoad = pcall(loadFix)
    check("6 class 不存在 → 不炸、不建假表", okLoad and SFarmingSystem == nil
        and S.printed("MDFX_FarmingCheckPlantOnce NOT installed: vanilla SFarmingSystem.checkPlant shape changed"))

    cls = env(false)
    cls.checkPlant = nil
    okLoad = pcall(loadFix)
    check("6 checkPlant 不存在 → 不裝", okLoad and cls.checkPlant == nil and S.printed("shape changed"))

    cls = env(true)
    vanilla = cls.checkPlant
    loadFix()
    check("6 客戶端不裝、不印", cls.checkPlant == vanilla and cls.MDFX_checkPlantOnce == nil and not S.printed("[MinidoracatFixes]"))

    -- 7. getter 與試跑
    section("[7] getter 與試跑")
    cls = env(false)
    loadFix()
    local flips = 0
    local function flaky(self, i) -- 別的 MOD 換上的 getter：同一格第一次有、第二次空
        flips = flips + 1
        if flips % 2 == 0 then return nil end
        return self.objs[i]
    end
    cls.getLuaObjectByIndex = flaky
    local fixedFlaky = run(newSystem(cls, 4))
    local refCls = newClass()
    refCls.getLuaObjectByIndex = flaky
    flips = 0
    local refFlaky = run(newSystem(refCls, 4))
    check("7 安裝後 getter 被換掉 → 整輪照原版", fixedFlaky.trace == refFlaky.trace and fixedFlaky.ok == refFlaky.ok,
        fixedFlaky.trace .. " vs " .. refFlaky.trace)

    cls = env(false)
    loadFix()
    local instSys = newSystem(cls, 4)
    instSys.getLuaObjectByIndex = flaky -- 只換在 instance 上（self 分派到的那支），類別上的還是原版
    flips = 0
    local fixedInst = run(instSys)
    local refInstSys = newSystem(newClass(), 4)
    refInstSys.getLuaObjectByIndex = flaky
    flips = 0
    local refInst = run(refInstSys)
    check("7 getter 只換在 instance 上 → 整輪照原版", fixedInst.trace == refInst.trace and fixedInst.ok == refInst.ok,
        fixedInst.trace .. " vs " .. refInst.trace)

    cls = env(false)
    vanilla = cls.checkPlant
    cls.getLuaObjectByIndex = function(self, i) return self.objs[i] end -- 來源不是原版 SGlobalObjectSystem.lua
    loadFix()
    check("7 getter 不是原版 → 不裝", cls.checkPlant == vanilla
        and S.printed("NOT installed: SFarmingSystem.getLuaObjectByIndex"))

    cls = env(false)
    local sameFile = vanillaCheckPlant(VANILLA_PATH, OTHER_SRC)
    cls.checkPlant = sameFile
    loadFix()
    check("7 同檔別支函式（來源檔對、行為不同）→ 不裝", cls.checkPlant == sameFile and S.printed("no longer behaves"))

    cls = env(false)
    local officialFix = vanillaCheckPlant(VANILLA_PATH, OFFICIAL_FIX_SRC)
    cls.checkPlant = officialFix
    loadFix()
    check("7 官方改過的本體 → 不裝、不蓋掉", cls.checkPlant == officialFix and S.printed("no longer behaves")
        and not S.printed("MDFX_FarmingCheckPlantOnce installed"))

    cls = env(false)
    local odd = vanillaCheckPlant(VANILLA_PATH, UNKNOWN_SRC)
    cls.checkPlant = odd
    local realPcall, failedPcalls = pcall, 0
    pcall = function(f, ...) -- 數修正檔裡失敗的 pcall：遊戲裡被接住的錯照樣進錯誤清單
        local r = table.pack(realPcall(f, ...))
        if not r[1] then failedPcalls = failedPcalls + 1 end
        return table.unpack(r, 1, r.n)
    end
    okLoad = realPcall(loadFix)
    pcall = realPcall
    check("7 新本體呼叫未知 method、讀欄位 → 試跑不拋錯、不裝", okLoad and failedPcalls == 0 and cls.checkPlant == odd
        and S.printed("no longer behaves"), "failed pcalls: " .. failedPcalls)

    cls = env(false)
    local moreArgs = vanillaCheckPlant(VANILLA_PATH, EXTRA_ARG_SRC)
    cls.checkPlant = moreArgs
    loadFix()
    check("7 新本體多傳參數 → 不裝", cls.checkPlant == moreArgs and S.printed("no longer behaves"))

    cls = env(false)
    local runaway = vanillaCheckPlant(VANILLA_PATH, RUNAWAY_SRC)
    cls.checkPlant = runaway
    PROBE_ITERS = 0
    okLoad = pcall(loadFix)
    check("7 新本體停不下來 → 試跑在上限中止、不裝", okLoad and PROBE_ITERS <= 65 and cls.checkPlant == runaway,
        "iterations: " .. tostring(PROBE_ITERS))

    for _, case in ipairs({ { "作物", WRITE_CROP_SRC }, { "self", WRITE_SELF_SRC } }) do
        cls = env(false)
        local writer = vanillaCheckPlant(VANILLA_PATH, case[2])
        cls.checkPlant = writer
        loadFix()
        check("7 新本體寫" .. case[1] .. "欄位 → 不裝", cls.checkPlant == writer and S.printed("no longer behaves"))
    end

    print = S.realPrint
    return checks, failures
end

-- ── 主程式 ───────────────────────────────────────────────────────
local FORWARD = "        for i = 1, self:getLuaObjectCount() do\n            local luaObject = self:getLuaObjectByIndex(i)\n"
local MUTANTS = {
    { name = "不載入修正", whole = true },
    { name = "正向照原版取兩次", edits = { { "            if not luaObject then break end\n            self:checkPlant2(luaObject)",
        "            if not self:getLuaObjectByIndex(i) then break end\n            self:checkPlant2(luaObject)" } } },
    { name = "反向照原版取兩次", edits = { { "            if not luaObject then break end\n            self:plowFadeCheck(luaObject)",
        "            if not self:getLuaObjectByIndex(i) then break end\n            self:plowFadeCheck(luaObject)" } } },
    { name = "正向遇空值不中止", edits = { { "            if not luaObject then break end\n            self:checkPlant2(luaObject)",
        "            if luaObject then self:checkPlant2(luaObject) end" } } },
    { name = "反向遇空值不中止", edits = { { "            if not luaObject then break end\n            self:plowFadeCheck(luaObject)",
        "            if luaObject then self:plowFadeCheck(luaObject) end" } } },
    { name = "反向改成正向", edits = { { "        local i = self:getLuaObjectCount()\n        while i > 0 do",
        "        local i = 1\n        while i <= self:getLuaObjectCount() do" }, { "            i = i - 1", "            i = i + 1" } } },
    { name = "反向沿用正向開頭的次數", edits = { { FORWARD,
        "        local count = self:getLuaObjectCount()\n        for i = 1, count do\n            local luaObject = self:getLuaObjectByIndex(i)\n" },
        { "        local i = self:getLuaObjectCount()\n        while", "        local i = count\n        while" } } },
    { name = "正向每輪重算次數", edits = { { FORWARD,
        "        local i0 = 0\n        while i0 < self:getLuaObjectCount() do\n            i0 = i0 + 1\n            local i = i0\n            local luaObject = self:getLuaObjectByIndex(i)\n" } } },
    { name = "正向也做 plowFadeCheck（合併迴圈）", edits = { { "            self:checkPlant2(luaObject)\n",
        "            self:checkPlant2(luaObject)\n            self:plowFadeCheck(luaObject)\n" } } },
    { name = "執行時不查 getter", edits = { { "        if self.getLuaObjectByIndex ~= getter then return original(self) end\n", "" } } },
    { name = "不試跑", edits = { { "    if not probe(original) then", "    if false then" } } },
    { name = "試跑不比呼叫序列", edits = { { "return ok and table.concat(trace, \",\") == PROBE_TRACE", "return ok" } } },
    { name = "不查 getter 來源", edits = { { "    vanilla, why = sourceOf(getter, GETTER_FILE)", "    vanilla, why = true, nil" } } },
    { name = "來源判斷永真", edits = { {
        "if string.sub(path, -#vanillaFile) ~= vanillaFile or string.find(path, \"/mods/\", 1, true) then", "if false then" } } },
    { name = "不看 /mods/", edits = { { " or string.find(path, \"/mods/\", 1, true)", "" } } },
    { name = "不正規化反斜線", edits = { { "string.lower(string.gsub(file, \"\\\\\", \"/\"))", "string.lower(file)" } } },
    { name = "查來源不包 pcall", edits = { { "local ok, file = pcall(getFilenameOfClosure, fn)",
        "local ok, file = true, getFilenameOfClosure(fn)" } } },
    { name = "拆掉 marker 檢查", edits = { { "    if cls[MARKER] == cls.checkPlant then return end\n", "" } } },
    { name = "不寫 marker", edits = { { "    cls[MARKER] = checkPlant\n", "" } } },
    { name = "拆掉形狀檢查", edits = { { "if type(cls) ~= \"table\" or type(cls.checkPlant) ~= \"function\" then", "if false then" } } },
    { name = "拆掉 isClient 閘門", edits = { { "if isClient() then return end\n", "" } } },
    { name = "plowFadeCheck 不經 self:", edits = { { "    return function(self)\n",
        "    local plow = SFarmingSystem.plowFadeCheck\n    return function(self)\n" },
        { "            self:plowFadeCheck(luaObject)\n", "            plow(self, luaObject)\n" } } },
    { name = "試跑假表沒有代理", edits = { { "    local meta = { __index = unknown, ", "    local meta = { " } } },
    { name = "試跑不記寫入", edits = { { ", __newindex = function(_, k) log(\"!\" .. tostring(k)) end }", " }" } } },
    { name = "執行時看類別上的 getter", edits = { { "        if self.getLuaObjectByIndex ~= getter then",
        "        if SFarmingSystem.getLuaObjectByIndex ~= getter then" } } },
    { name = "試跑不記多出來的參數", edits = { { "return string.rep(\"+\", math.max(0, select(\"#\", ...) - n))", "return \"\"" } } },
    { name = "試跑沒有筆數上限", edits = { { "        if #trace > PROBE_LIMIT then error(\"probe runaway\", 0) end\n", "" } } },
}

local function replaceOnce(src, from, to)
    local s, e = src:find(from, 1, true)
    if not s then return nil, "pattern not found: " .. from end
    if src:find(from, e + 1, true) then return nil, "pattern not unique: " .. from end
    return src:sub(1, s - 1) .. to .. src:sub(e + 1)
end

local function mutate(m)
    if m.whole then return { fix = "" } end
    local src = SOURCES.fix
    for _, edit in ipairs(m.edits) do
        local why
        src, why = replaceOnce(src, edit[1], edit[2])
        if not src then return nil, why end
    end
    return { fix = src }
end

if arg and arg[1] == "--mutants" then
    local survived, broken = 0, 0
    for _, m in ipairs(MUTANTS) do
        local srcs, why = mutate(m)
        if not srcs then
            broken = broken + 1
            S.realPrint("  BROKEN    " .. m.name .. " — " .. why)
        else
            local ok, checks, failures = pcall(runSuite, srcs, true)
            print = S.realPrint
            if ok and failures == 0 then
                survived = survived + 1
                S.realPrint(string.format("  SURVIVED  %s（%d 項全綠）", m.name, checks))
            else
                S.realPrint(string.format("  KILLED    %s（%s）", m.name,
                    ok and (failures .. "/" .. checks .. " 項轉紅") or ("拋錯 " .. tostring(checks))))
            end
        end
    end
    S.realPrint("")
    S.realPrint(string.format("%d mutants, %d survived, %d broken", #MUTANTS, survived, broken))
    os.exit((survived == 0 and broken == 0) and 0 or 1)
end

local checks, failures = runSuite(SOURCES, false)
S.realPrint("")
S.realPrint(string.format("%d checks, %d failed", checks, failures))
os.exit(failures == 0 and 0 or 1)
