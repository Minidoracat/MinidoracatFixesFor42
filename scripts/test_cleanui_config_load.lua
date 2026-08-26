-- MDFX_CleanUIConfigLoad 離線自我檢查
-- 用法（repo 根目錄）： lua scripts/test_cleanui_config_load.lua
--
-- 以最小 stub 模擬 CleanUI 的 CleanUIConfig 表與 PZ 的 Events，驗證：
--   * 四種載入順序 × CleanUI 狀態的組合都得到正確結果（含官方修好後自動退場）
--   * 不依賴 mod 載入順序，也不會為了搶順序建立假的 CleanUIConfig 全域表
--   * configCache 有填（getConfig 是每幀路徑，不填等於每幀讀檔）
--   * legacy 檔 fallback
--   * loadConfigFile 拋出時不外洩例外
--   * 零檔案副作用（不呼叫 saveConfig）

local MOD_LUA = "MOD/MinidoracatFixesFor42/Contents/mods/MinidoracatFixesFor42/"
    .. "42/media/lua/client/Fixes/MDFX_CleanUIConfigLoad.lua"

local realPrint = print
local failures = 0
local checks = 0

local function check(label, cond, detail)
    checks = checks + 1
    if cond then
        realPrint(string.format("  PASS  %s", label))
    else
        failures = failures + 1
        realPrint(string.format("  FAIL  %s%s", label, detail and ("  — " .. detail) or ""))
    end
end

-- ── stub 環境 ──────────────────────────────────────────────────
local bootHandlers, prints = {}, {}

local function resetEnv()
    bootHandlers, prints = {}, {}
    CleanUIConfig = nil
    Events = { OnGameBoot = { Add = function(fn) bootHandlers[#bootHandlers + 1] = fn end } }
    print = function(...)
        local parts = {}
        for i = 1, select("#", ...) do parts[i] = tostring(select(i, ...)) end
        prints[#prints + 1] = table.concat(parts, " ")
    end
end

local function fireBoot()
    for i = 1, #bootHandlers do bootHandlers[i]() end
end

-- 模擬 CleanUI v2.7.8 的 CleanUIConfig：有 restricted parser 的 loadConfigFile，
-- 但沒有外層 loadConfig。files 是「磁碟」內容，reads 記錄每次讀檔。
local function newCleanUI(files, opts)
    opts = opts or {}
    local t = {
        configFileName = opts.configFileName ~= false and "CleanUIConfig.txt" or nil,
        legacyConfigFileName = opts.legacyConfigFileName ~= false and "CleanUIConfig.lua" or nil,
        configCache = nil,
        reads = {},
        saveCalls = 0,
    }
    t.saveConfig = function(config)
        t.saveCalls = t.saveCalls + 1
        t.configCache = config
        return true
    end
    if not opts.noLoadConfigFile then
        t.loadConfigFile = function(fileName)
            t.reads[#t.reads + 1] = tostring(fileName)
            if opts.throwOn == fileName then
                error("simulated getFileReader failure: " .. tostring(fileName))
            end
            return files[fileName]
        end
    end
    return t
end

local function loadShim()
    local chunk = assert(loadfile(MOD_LUA))
    chunk()
end

-- ── 情境 1：本檔晚於 CleanUI 載入，CleanUI 尚未修好 ─────────────
resetEnv()
CleanUIConfig = newCleanUI({ ["CleanUIConfig.txt"] = { hideEquipped = true } })
loadShim()
check("1 立即安裝（不需等 OnGameBoot）", type(CleanUIConfig.loadConfig) == "function")
check("1 不註冊 OnGameBoot", #bootHandlers == 0, #bootHandlers .. " handlers")
check("1 印出安裝訊息", #prints == 1 and prints[1]:find("shim installed", 1, true) ~= nil,
    table.concat(prints, " | "))
local cfg = CleanUIConfig.loadConfig()
check("1 讀到 .txt 的內容", type(cfg) == "table" and cfg.hideEquipped == true)
check("1 只讀 .txt、不碰 legacy", #CleanUIConfig.reads == 1
    and CleanUIConfig.reads[1] == "CleanUIConfig.txt", table.concat(CleanUIConfig.reads, ","))
check("1 有填 configCache", CleanUIConfig.configCache == cfg)
CleanUIConfig.loadConfig()
check("1 第二次走 cache、不重複讀檔", #CleanUIConfig.reads == 1,
    #CleanUIConfig.reads .. " reads")
check("1 零檔案副作用（未呼叫 saveConfig）", CleanUIConfig.saveCalls == 0)

-- ── 情境 2：CleanUI 官方已補上自己的 loadConfig → 不得覆寫 ──────
resetEnv()
CleanUIConfig = newCleanUI({})
local official = function() return { fromOfficial = true } end
CleanUIConfig.loadConfig = official
loadShim()
check("2 官方版本存活（補丁自動退場）", CleanUIConfig.loadConfig == official)
check("2 退場時不印安裝訊息", #prints == 0, table.concat(prints, " | "))
check("2 退場時不註冊 OnGameBoot", #bootHandlers == 0)

-- ── 情境 3：CleanUI 內部結構不符（沒有 loadConfigFile）─────────
resetEnv()
CleanUIConfig = newCleanUI({}, { noLoadConfigFile = true })
loadShim()
check("3 結構不符時不亂補", CleanUIConfig.loadConfig == nil)
check("3 結構不符時不註冊 OnGameBoot（已判定完成）", #bootHandlers == 0)

-- ── 情境 4：本檔早於 CleanUI 載入 → OnGameBoot 補裝 ────────────
resetEnv()
loadShim()
check("4 CleanUI 未載入時延後處理", #bootHandlers == 1, #bootHandlers .. " handlers")
check("4 延後期間不建立假的 CleanUIConfig 全域表", CleanUIConfig == nil)
CleanUIConfig = newCleanUI({ ["CleanUIConfig.txt"] = { lockLootWindow = true } })
fireBoot()
check("4 OnGameBoot 補裝成功", type(CleanUIConfig.loadConfig) == "function")
local cfg4 = CleanUIConfig.loadConfig()
check("4 補裝後讀得到設定", type(cfg4) == "table" and cfg4.lockLootWindow == true)

-- ── 情境 5：玩家沒裝 CleanUI ──────────────────────────────────
resetEnv()
loadShim()
fireBoot()
check("5 沒裝 CleanUI 時完全無作用", CleanUIConfig == nil)
check("5 沒裝 CleanUI 時不印訊息", #prints == 0, table.concat(prints, " | "))

-- ── 情境 6：.txt 不存在 → 退回 legacy .lua ────────────────────
resetEnv()
CleanUIConfig = newCleanUI({ ["CleanUIConfig.lua"] = { hideEquipped = false } })
loadShim()
local cfg6 = CleanUIConfig.loadConfig()
check("6 legacy fallback 讀得到", type(cfg6) == "table" and cfg6.hideEquipped == false)
check("6 順序是先 .txt 再 legacy", #CleanUIConfig.reads == 2
    and CleanUIConfig.reads[1] == "CleanUIConfig.txt"
    and CleanUIConfig.reads[2] == "CleanUIConfig.lua", table.concat(CleanUIConfig.reads, ","))
check("6 legacy 讀成功後仍不主動寫檔", CleanUIConfig.saveCalls == 0)

-- ── 情境 7：兩個檔都沒有 → 回 nil，交給 getConfig 走預設值 ─────
resetEnv()
CleanUIConfig = newCleanUI({})
loadShim()
check("7 兩檔皆無時回 nil", CleanUIConfig.loadConfig() == nil)
check("7 回 nil 時不寫 cache（保留 getConfig 的預設值路徑）",
    CleanUIConfig.configCache == nil)

-- ── 情境 8：loadConfigFile 拋出 → 不得外洩例外 ────────────────
resetEnv()
CleanUIConfig = newCleanUI({ ["CleanUIConfig.lua"] = { hideEquipped = true } },
    { throwOn = "CleanUIConfig.txt" })
loadShim()
local ok8, res8 = pcall(CleanUIConfig.loadConfig)
check("8 .txt 讀取拋出時不外洩例外", ok8 == true, tostring(res8))
check("8 拋出後仍退回 legacy", type(res8) == "table" and res8.hideEquipped == true)

-- ── 情境 9：檔名欄位是 nil（CleanUI 改版）→ 安全回 nil ─────────
resetEnv()
CleanUIConfig = newCleanUI({}, { configFileName = false, legacyConfigFileName = false })
loadShim()
local ok9, res9 = pcall(CleanUIConfig.loadConfig)
check("9 檔名為 nil 時不拋出", ok9 == true, tostring(res9))
check("9 檔名為 nil 時回 nil 且不讀檔", res9 == nil and #CleanUIConfig.reads == 0)

-- ── 情境 10：與真實 CleanUI v2.7.8 檔案整合（找不到檔案就跳過）─
-- 前面九個情境用 stub 驗邏輯；這一個把真的 CleanUIConfig.lua 載進來，
-- 先重現「未安裝補丁時 getConfig 拋出」，再證明安裝後能讀出玩家設定。
local REAL_CLEANUI = "D:/SteamLibrary/steamapps/workshop/content/108600/3437629766/"
    .. "mods/CleanUI/42.19/media/lua/client/ISUI/CleanUIConfig.lua"

local probe = io.open(REAL_CLEANUI, "r")
if not probe then
    realPrint("  SKIP  10 真實 CleanUI 整合 — 本機找不到 workshop 檔案")
else
    probe:close()

    -- PZ 端檔案 API 的最小 stub：reader 只需要 readLine()/close()
    local disk = {
        ["CleanUIConfig.txt"] = 'return {\n'
            .. '    lockInventoryWindow = false,\n'
            .. '    hideEquipped = true,\n'
            .. '    pane_0_inventory_sortBy = "nameInc",\n'
            .. '}\n',
    }

    local function installFileStubs()
        getFileReader = function(fileName)
            local content = disk[fileName]
            if not content then return nil end
            local lines, idx = {}, 0
            for line in string.gmatch(content, "[^\n]+") do lines[#lines + 1] = line end
            return {
                readLine = function() idx = idx + 1; return lines[idx] end,
                close = function() end,
            }
        end
        getFileWriter = function() return nil end
    end

    -- 對照組：只載真實 CleanUI，不裝補丁 → 必須重現線上的錯誤
    resetEnv()
    installFileStubs()
    dofile(REAL_CLEANUI)
    check("10 真實檔案確實缺 loadConfig", CleanUIConfig.loadConfig == nil)
    local okBare, errBare = pcall(CleanUIConfig.getConfig)
    check("10 對照組：未裝補丁時 getConfig 拋出", okBare == false, tostring(errBare))

    -- 實驗組：載真實 CleanUI ＋ 本補丁
    resetEnv()
    installFileStubs()
    dofile(REAL_CLEANUI)
    loadShim()
    local okFixed, cfg10 = pcall(CleanUIConfig.getConfig)
    check("10 裝上補丁後 getConfig 不再拋出", okFixed == true, tostring(cfg10))
    check("10 讀出玩家自己的設定（hideEquipped）",
        type(cfg10) == "table" and cfg10.hideEquipped == true)
    check("10 讀出欄位設定（pane_0_inventory_sortBy）",
        type(cfg10) == "table" and cfg10.pane_0_inventory_sortBy == "nameInc")
    check("10 缺少的 default key 由 CleanUI 自己補齊（lockLootWindow）",
        type(cfg10) == "table" and cfg10.lockLootWindow == false)

    -- CleanUI 在檔案層把 getConfig 掛上 OnGameBoot（CleanUIConfig.lua:456）：
    -- 補丁裝上後這一輪必須安靜跑完，這就是線上第一個錯誤的發生點。
    local okBoot, errBoot = pcall(fireBoot)
    check("10 OnGameBoot 一輪不拋出（線上第一個錯誤的發生點）",
        okBoot == true, tostring(errBoot))
end

-- ── 總結 ─────────────────────────────────────────────────────
print = realPrint
print()
print(string.format("%d checks, %d failed", checks, failures))
os.exit(failures == 0 and 0 or 1)
