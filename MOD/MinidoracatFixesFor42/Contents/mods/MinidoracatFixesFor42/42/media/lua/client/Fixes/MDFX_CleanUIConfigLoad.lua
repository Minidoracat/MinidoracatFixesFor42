--[[
MDFX_CleanUIConfigLoad — CleanUI 缺失的 CleanUIConfig.loadConfig 臨時補丁

【背景】
PZ B42.20.4 的安全變更移除了 Lua 的 loadstring / loadstream：vanilla
se.krka.kahlua.j2se.J2SEPlatform.setupEnvironment 不再呼叫 LuaCompiler.register(env)
（42.20.3 該呼叫位於 J2SEPlatform.java:59，42.20.4 整段刪除）。CleanUI 原本用
loadstring 讀 CleanUIConfig 檔案，因此作者在 v2.7.8（2026-08-26）改寫成自帶的
restricted parser。

【缺陷】
v2.7.8 的發佈包裡少了外層函式 CleanUIConfig.loadConfig，但
  CleanUIConfig.getConfig()    (CleanUIConfig.lua:410)
  CleanUIConfig.updateConfig() (CleanUIConfig.lua:446)
兩處都還在呼叫它，於是每次都是「Object tried to call nil in getConfig」。
同一份檔案裡只留下 loadConfigFile(fileName)（:375，零 caller），以及沒有任何
讀取者的 configCache（:2/:360）與 legacyConfigFileName（:353）——正是被漏掉的
那層 wrapper 該用的材料。

【後果】
ISInventoryPane:new()（ISInventoryPane.lua:344）在 return o 之前就拋出，
ISInventoryPage:createChildren（:359）中斷；vanilla ISUIElement:instantiate() 的
createChildren() 呼叫沒有 pcall 保護（ISUIElement.lua:1007），例外一路外逃，
ISPlayerDataObject:createInventoryInterface 在 :30（setUIName）之後全數不執行——
addToUIManager()、戰利品面板 panel3、UIManager.setPlayerInventory() 都沒跑，
玩家的背包與戰利品視窗完全不存在。

【本補丁】
只補回那一個缺失的函式，形狀沿用同作者 CleanHotBar 的正解
（chbconfig.lua:287-311：cache → 新的 .txt → legacy .lua），用的全部是 CleanUI
自己已經存在的成員，不改動 CleanUI 任何既有行為，也不新增任何設定或介面。

【臨時性】
CleanUI 官方修好（自己定義 loadConfig）之後，下面的 type 檢查就不會成立，
本補丁自動退場；屆時本檔可直接從 MOD 移除。

【兩個刻意的取捨】
1. 不依賴 mod 載入順序。若本檔早於 CleanUI 載入，改在 OnGameBoot 補裝
   （vanilla Core.ResetLua 先跑完 LuaManager.LoadDirBase() 才觸發 OnGameBoot，
   Core.java:3948 / :3962，所以那時 CleanUI 一定已載入）。也不會為了搶順序去
   建立一張假的 CleanUIConfig 空表——有其他 mod 以全域表存在與否偵測 CleanUI。
2. 讀到 legacy 檔時不主動寫檔遷移。CleanUI 自己的 getConfig/updateConfig 會在
   真的需要時呼叫 saveConfig，本補丁保持零檔案副作用。
   但 configCache 一定要填：getConfig 會被 ISInventoryPage:isPagelocked()
   （ISInventoryPage.lua:811）這類每幀路徑呼叫，不填 cache 等於每幀讀檔。
]]

local function installLoadConfigShim()
    -- CleanUI 尚未載入，或玩家根本沒裝 → 回報「還無法判斷」，交給 OnGameBoot 再試
    if type(CleanUIConfig) ~= "table" then
        return false
    end

    -- 官方已補上自己的版本 → 絕不覆寫
    if type(CleanUIConfig.loadConfig) == "function" then
        return true
    end

    -- 內部結構與預期不符（CleanUI 又改版了）→ 不亂補，讓原本的錯誤照常暴露
    if type(CleanUIConfig.loadConfigFile) ~= "function" then
        return true
    end

    local function readConfigFile(fileName)
        if type(fileName) ~= "string" then
            return nil
        end
        local ok, config = pcall(CleanUIConfig.loadConfigFile, fileName)
        if ok and type(config) == "table" then
            return config
        end
        return nil
    end

    function CleanUIConfig.loadConfig()
        local cached = CleanUIConfig.configCache
        if type(cached) == "table" then
            return cached
        end

        local config = readConfigFile(CleanUIConfig.configFileName)
        if not config then
            config = readConfigFile(CleanUIConfig.legacyConfigFileName)
        end

        if config then
            CleanUIConfig.configCache = config
        end

        return config
    end

    print("[MinidoracatFixes] CleanUIConfig.loadConfig shim installed")
    return true
end

-- 本檔晚於 CleanUI 載入 → 立即生效；早於 CleanUI → 等所有 mod Lua 載入完再補
if not installLoadConfigShim() then
    Events.OnGameBoot.Add(installLoadConfigShim)
end
