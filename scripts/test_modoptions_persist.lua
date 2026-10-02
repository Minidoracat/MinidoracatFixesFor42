-- MDFX_ModOptionsPersist 離線自我檢查
-- 用法（repo 根目錄）： lua scripts/test_modoptions_persist.lua [--mutants]
--
-- 照載本機遊戲的原版 client/PZAPI/ModOptions.lua 與 shared/luautils.lua（PZ_HOME 可改安裝目錄），
-- 檔案系統用記憶體 stub：getFileWriter 只收 ini 等副檔名（LuaManager.java:6728）、寫入在 close 時落盤；
-- getFileReader 照 BufferedReader.readLine（\r\n、\n、\r 都算行尾，回傳不含行尾），createIfNull 建空檔。
-- 驗證：
--   * 黏行第一筆屬已註冊／未註冊兩種：值套上、檔案改成一筆一行、下次 save 一筆一行（對照組：原版丟值）
--   * save 先於 load：主選單沒有 MOD 選項時不清空；有選項時不改已註冊選項在記憶體裡的值、不重複、可重入
--   * 無黏行：load 不寫檔；只有已註冊行時 load＋save 與原版位元組相同；有未註冊行時只差每行補上 \r\n
--   * EquipmentUI 式 load 包裝（在本補丁內層／外層）照樣用 string.find 找到並移除自己的舊行
--   * 舊 combobox 行 → 同 id 新 slider 的 .selected 遷移訊號照舊（獨立行與黏行）
--   * 切不出合法筆數不改檔；寫入讀回不符時寫回原內容、不再 load
--   * 任何一步出錯退回原版；原 save 拋錯照樣外洩且 OtherOptions 還原；形狀不符印 NOT installed；重複載入不疊
--   * 官方先補上 :287 換行（模擬）時，未註冊行之後只多一個空行、不會越存越多
-- --mutants：逐一抽掉每道防線，確認至少一項檢查轉紅。

local PZ_HOME = os.getenv("PZ_HOME") or "D:/SteamLibrary/steamapps/common/ProjectZomboid"
local VANILLA = PZ_HOME .. "/media/lua/"
local FIX = "MOD/MinidoracatFixesFor42/Contents/mods/MinidoracatFixesFor42/42/media/lua/client/Fixes/MDFX_ModOptionsPersist.lua"

local realPrint = print

local function readFile(path)
    local f = assert(io.open(path, "rb"))
    local s = f:read("*a")
    f:close()
    return s
end

local SOURCES = { fix = readFile(FIX) }
local VANILLA_MODOPTIONS = readFile(VANILLA .. "client/PZAPI/ModOptions.lua")
local VANILLA_LUAUTILS = readFile(VANILLA .. "shared/luautils.lua")
-- 官方若在 :287 補上換行（可退場條件之一）的模擬版
local VANILLA_FIXED, nFixed = VANILLA_MODOPTIONS:gsub("fileOutput:write%(line%)", 'fileOutput:write(line .. "\\r\\n")')
assert(nFixed == 1, "vanilla :287 write(line) not found exactly once")

-- ── 假環境 ────────────────────────────────────────────────────────
local disk, io_stats, prints
local dropNextWrite = false
local ALLOWED = { ini = true, cfg = true, txt = true, log = true, json = true }

local function resetEnv()
    disk, prints = {}, {}
    io_stats = { reads = 0, writes = 0 }
    dropNextWrite = false
    getText = function(s) return s end
    print = function(...)
        local parts = {}
        for i = 1, select("#", ...) do parts[i] = tostring(select(i, ...)) end
        prints[#prints + 1] = table.concat(parts, " ")
    end
    getFileWriter = function(name, create, append)
        if not ALLOWED[name:match("%.(%w+)$") or ""] then return nil end
        io_stats.writes = io_stats.writes + 1
        local drop = dropNextWrite
        dropNextWrite = false
        local buf = append and (disk[name] or "") or ""
        disk[name] = buf -- FileOutputStream(append=false) 一開就截斷
        return {
            write = function(_, s) if not drop then buf = buf .. s end end,
            close = function() disk[name] = buf end,
        }
    end
    getFileReader = function(name, create)
        io_stats.reads = io_stats.reads + 1
        local data = disk[name]
        if data == nil then
            if not create then return nil end
            data = ""
            disk[name] = data
        end
        local pos = 1
        return {
            readLine = function()
                if pos > #data then return nil end
                local s = data:find("[\r\n]", pos)
                local line
                if not s then
                    line = data:sub(pos); pos = #data + 1
                else
                    line = data:sub(pos, s - 1)
                    pos = (data:sub(s, s + 1) == "\r\n") and s + 2 or s + 1
                end
                return line
            end,
            close = function() end,
        }
    end
    luautils = {}
    assert(load(VANILLA_LUAUTILS, "=luautils.lua"))()
end

local function freshVanilla(src)
    PZAPI = nil
    assert(load(src or VANILLA_MODOPTIONS, "=ModOptions.lua"))()
end

local function printCount(needle)
    local n = 0
    for i = 1, #prints do
        if prints[i]:find(needle, 1, true) then n = n + 1 end
    end
    return n
end

local function lines(s)
    local out = {}
    for l in (s or ""):gmatch("([^\r\n]*)\r\n") do out[#out + 1] = l end
    return out
end

local function hasLine(s, line)
    return (s or ""):find("\r\n" .. line .. "\r\n", 1, true) ~= nil or (s or ""):sub(1, #line + 2) == line .. "\r\n"
end

-- ── 註冊用的 MOD 選項 ──────────────────────────────────────────────
local function regAD()
    local o = PZAPI.ModOptions:create("MinidoracatAutoDrive", "AD")
    o:addTickBox("VoiceEnabled", "x", true)
    local c = o:addComboBox("VoiceLanguage", "x")
    c:addItem("a", true); c:addItem("b"); c:addItem("c")
    o:addSlider("VoiceVolume", "x", 0, 100, 1, 70)
    return o
end

local function regOther()
    local o = PZAPI.ModOptions:create("OtherMod", "Other")
    o:addTickBox("o1", "x", false)
    local m = o:addMultipleTickBox("m", "x")
    m:addTickBox("a", false); m:addTickBox("b", false)
    o:addColorPicker("col", "x", 1, 1, 1, 1)
    o:addTextEntry("t", "x", "default")
    o:addKeyBind("k", "x", 10)
    o:addSlider("s", "x", 0, 1, 0.0001, 0.5)
    return o
end

local function regMiniMap()
    local o = PZAPI.ModOptions:create("MinidoracatMiniMap", "MM")
    o:addSlider("ZombieDotSize", "x", 1, 8, 1, 3)
    return o
end

-- EquipmentUI 3780682550 的 load 包裝與 migrateLegacyScale（EquipmentUI/ModOptions.lua:125-173）照抄
local function installEquipmentUI()
    local MOD_ID, SCALE_KEY, LEGACY = "EquipmentUI_B42", "EQUIPMENT_UI_SCALE", "EQUIPMENT_UI_SCALE_INDEX"
    local o = PZAPI.ModOptions:create(MOD_ID, "EUI")
    local dd = o:addComboBox(SCALE_KEY, "x")
    for i = 1, 15 do dd:addItem(tostring(i), i == 3) end
    local function readSavedValue(optionId)
        local reader = getFileReader("ModOptions.ini", true)
        if not reader then return nil end
        local value = nil
        while true do
            local line = reader:readLine()
            if line == nil then break end
            local parts = luautils.split(line, "|")
            if parts[2] == MOD_ID and parts[3] == optionId then value = tonumber(parts[4]) end
        end
        reader:close()
        return value
    end
    local state = { migrated = 0 }
    local function migrateLegacyScale()
        if readSavedValue(SCALE_KEY) then return end
        local legacyIndex = readSavedValue(LEGACY)
        if not legacyIndex then return end
        dd:setValue(math.floor((legacyIndex * 0.5 - 0.5) / 0.25 + 0.5) + 1)
        state.migrated = state.migrated + 1
        for i = #PZAPI.ModOptions.OtherOptions, 1, -1 do
            if string.find(PZAPI.ModOptions.OtherOptions[i], "|" .. MOD_ID .. "|" .. LEGACY .. "|", 1, true) then
                table.remove(PZAPI.ModOptions.OtherOptions, i)
            end
        end
    end
    local og_load = PZAPI.ModOptions.load
    function PZAPI.ModOptions:load()
        og_load(self)
        pcall(migrateLegacyScale)
    end
    state.dd = dd
    return state
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
    local function loadFix()
        assert(load(srcs.fix, "=MDFX_ModOptionsPersist.lua"))()
    end
    -- 新 Lua 環境（ResetLua）：原版檔重建 PZAPI，before 在本補丁之前載入，after 在之後
    local function session(withFix, before, after, vanillaSrc)
        freshVanilla(vanillaSrc)
        local r = {}
        if before then r.before = before() end
        if withFix then loadFix() end
        if after then r.after = after() end
        return r
    end

    local GLUED_REG_FIRST = "tickbox|MinidoracatAutoDrive|VoiceEnabled|false"
        .. "multipletickbox|OtherMod|m|true false "
        .. "combobox|MinidoracatAutoDrive|VoiceLanguage|3"
        .. "colorpicker|OtherMod|col|0.8 0.7 0.3 1"
        .. "slider|OtherMod|s|1.0E-4"
        .. "textentry|OtherMod|t|hello world"
        .. "keybind|OtherMod|k|57"
        .. "slider|MinidoracatAutoDrive|VoiceVolume|30"
        .. "tickbox|GoneMod|g|true"
    local GLUED_OTHER_FIRST = "tickbox|GoneMod|g|true"
        .. "tickbox|MinidoracatAutoDrive|VoiceEnabled|false"
        .. "combobox|MinidoracatAutoDrive|VoiceLanguage|3"
        .. "slider|MinidoracatAutoDrive|VoiceVolume|30"
    local AD_LINES = { "tickbox|MinidoracatAutoDrive|VoiceEnabled|false",
        "combobox|MinidoracatAutoDrive|VoiceLanguage|3", "slider|MinidoracatAutoDrive|VoiceVolume|30" }

    local function adValues(o)
        return o:getOption("VoiceEnabled"):getValue(), o:getOption("VoiceLanguage"):getValue(),
            o:getOption("VoiceVolume"):getValue()
    end

    -- 1 黏行，第一筆屬已註冊選項
    section("[1] 黏行第一筆屬已註冊選項（AutoDrive 註冊、OtherMod 沒註冊）")
    resetEnv()
    disk["ModOptions.ini"] = "tickbox|Keep|k|true\r\n" .. GLUED_REG_FIRST
    session(false)
    local ctl = regAD()
    PZAPI.ModOptions:load()
    local e0, l0 = adValues(ctl)
    check("1 對照組：原版整行丟掉，AutoDrive 值留在預設", e0 == true and l0 == 1)
    PZAPI.ModOptions:save()
    check("1 對照組：原版 save 後 GoneMod 那筆永久消失", not disk["ModOptions.ini"]:find("GoneMod", 1, true))

    resetEnv()
    disk["ModOptions.ini"] = "tickbox|Keep|k|true\r\n" .. GLUED_REG_FIRST
    session(true)
    local ad = regAD()
    PZAPI.ModOptions:load()
    local e1, l1, v1 = adValues(ad)
    check("1 修正：AutoDrive 三個值都套上", e1 == false and l1 == 3 and v1 == 30, tostring(e1) .. "/" .. tostring(l1) .. "/" .. tostring(v1))
    local f1 = disk["ModOptions.ini"]
    check("1 修正：檔案改成一筆一行（10 行、每行一筆）", #lines(f1) == 10 and lines(f1)[2] == AD_LINES[1]
        and lines(f1)[3] == "multipletickbox|OtherMod|m|true false " and lines(f1)[5] == "colorpicker|OtherMod|col|0.8 0.7 0.3 1"
        and lines(f1)[6] == "slider|OtherMod|s|1.0E-4" and lines(f1)[10] == "tickbox|GoneMod|g|true", f1)
    check("1 修正：OtherOptions 是逐筆原文（不帶行尾）", #PZAPI.ModOptions.OtherOptions == 7
        and PZAPI.ModOptions.OtherOptions[1] == "tickbox|Keep|k|true"
        and PZAPI.ModOptions.OtherOptions[2] == "multipletickbox|OtherMod|m|true false ")
    check("1 修正：印一行 split 診斷", printCount("MDFX_ModOptionsPersist split 9 glued records") == 1, prints[1])
    PZAPI.ModOptions:save()
    local s1 = disk["ModOptions.ini"]
    check("1 修正：save 後每筆一行、GoneMod 還在", #lines(s1) == 10 and s1:sub(-2) == "\r\n" and hasLine(s1, "tickbox|GoneMod|g|true")
        and hasLine(s1, "keybind|OtherMod|k|57"), s1)
    check("1 修正：save 後 OtherOptions 還是同一張表、內容沒帶行尾", PZAPI.ModOptions.OtherOptions[1] == "tickbox|Keep|k|true")
    session(true)
    local other = regOther()
    PZAPI.ModOptions:load()
    check("1 修正：之後只有 OtherMod 的場次，五種型別的值都套上",
        other:getOption("m").values[1].value == true and other:getOption("m").values[2].value == false
        and other:getOption("col").color.g == 0.7 and other:getOption("s").value == 0.0001
        and other:getOption("t").value == "hello world" and other:getOption("k").key == 57)
    PZAPI.ModOptions:save()
    session(true)
    local ad1b = regAD()
    PZAPI.ModOptions:load()
    local e1b, l1b = adValues(ad1b)
    check("1 修正：再回到 AutoDrive 場次值仍在", e1b == false and l1b == 3)

    -- 2 黏行，第一筆屬未註冊選項
    section("[2] 黏行第一筆屬未註冊選項")
    resetEnv()
    disk["ModOptions.ini"] = GLUED_OTHER_FIRST
    session(false)
    local ctl2 = regAD()
    PZAPI.ModOptions:load()
    local e2c = adValues(ctl2)
    check("2 對照組：原版整行進 OtherOptions，值套不到", e2c == true and #PZAPI.ModOptions.OtherOptions == 1)

    resetEnv()
    disk["ModOptions.ini"] = GLUED_OTHER_FIRST
    session(true)
    local ad2 = regAD()
    PZAPI.ModOptions:load()
    local e2, l2, v2 = adValues(ad2)
    check("2 修正：值套上", e2 == false and l2 == 3 and v2 == 30)
    check("2 修正：OtherOptions 只剩 GoneMod 一筆", #PZAPI.ModOptions.OtherOptions == 1 and PZAPI.ModOptions.OtherOptions[1] == "tickbox|GoneMod|g|true")
    ad2:getOption("VoiceVolume"):setValue(55)
    PZAPI.ModOptions:save()
    check("2 修正：save 一筆一行", disk["ModOptions.ini"] == "tickbox|MinidoracatAutoDrive|VoiceEnabled|false\r\n"
        .. "combobox|MinidoracatAutoDrive|VoiceLanguage|3\r\nslider|MinidoracatAutoDrive|VoiceVolume|55\r\n"
        .. "tickbox|GoneMod|g|true\r\n", disk["ModOptions.ini"])

    -- 3 save 先於 load
    section("[3] save 先於 load")
    local BASE = AD_LINES[1] .. "\r\n" .. AD_LINES[2] .. "\r\n" .. AD_LINES[3] .. "\r\ntickbox|Keep|k|true\r\n"
        .. "tickbox|GoneMod|g|truetickbox|Gone2|h|false"
    resetEnv()
    disk["ModOptions.ini"] = BASE
    session(false)
    PZAPI.ModOptions:save()
    check("3 對照組：主選單沒有 MOD 選項時按套用，原版清空檔案", disk["ModOptions.ini"] == "")

    resetEnv()
    disk["ModOptions.ini"] = BASE
    session(true)
    PZAPI.ModOptions:save()
    local s3 = disk["ModOptions.ini"]
    check("3 修正：沒有 MOD 選項時按套用，每一筆都留下且一筆一行",
        s3 == table.concat(AD_LINES, "\r\n") .. "\r\ntickbox|Keep|k|true\r\ntickbox|GoneMod|g|true\r\ntickbox|Gone2|h|false\r\n", s3)
    PZAPI.ModOptions:save()
    check("3 修正：再按一次套用位元組不變（不重複）", disk["ModOptions.ini"] == s3)
    check("3 修正：OtherOptions 仍是原表、仍是空的", #PZAPI.ModOptions.OtherOptions == 0)

    resetEnv()
    disk["ModOptions.ini"] = BASE .. "\r\ntickbox|Keep|k|true\r\n"
    session(true)
    local ad3 = regAD()
    ad3:getOption("VoiceEnabled"):setValue(true) -- 主 MOD 遷移式：程式設值後直接 save，沒有 load
    PZAPI.ModOptions:save()
    local s3b = disk["ModOptions.ini"]
    check("3 修正：已註冊選項寫記憶體裡的值、檔案舊值不重複寫回",
        s3b == "tickbox|MinidoracatAutoDrive|VoiceEnabled|true\r\ncombobox|MinidoracatAutoDrive|VoiceLanguage|1\r\n"
        .. "slider|MinidoracatAutoDrive|VoiceVolume|70\r\ntickbox|Keep|k|true\r\ntickbox|GoneMod|g|true\r\ntickbox|Gone2|h|false\r\n", s3b)
    check("3 修正：記憶體裡的值沒被改", ad3:getOption("VoiceEnabled"):getValue() == true and ad3:getOption("VoiceLanguage"):getValue() == 1)
    session(true)
    local ad3c = regAD()
    PZAPI.ModOptions:load()
    check("3 修正：下一場 load 讀到程式設的值", ad3c:getOption("VoiceEnabled"):getValue() == true)

    -- 4 無黏行
    section("[4] 無黏行：與原版位元組相同")
    local CLEAN = table.concat(AD_LINES, "\r\n") .. "\r\n"
    resetEnv()
    disk["ModOptions.ini"] = CLEAN
    session(false); regAD(); PZAPI.ModOptions:load(); PZAPI.ModOptions:save()
    local vanillaOut = disk["ModOptions.ini"]
    resetEnv()
    disk["ModOptions.ini"] = CLEAN
    session(true); regAD()
    PZAPI.ModOptions:load()
    check("4 load 不寫檔、只多讀一次", io_stats.writes == 0 and io_stats.reads == 2, io_stats.writes .. "/" .. io_stats.reads)
    PZAPI.ModOptions:save()
    check("4 只有已註冊行：load＋save 與原版位元組相同", disk["ModOptions.ini"] == vanillaOut)
    check("4 沒有診斷", #prints == 0, prints[1])

    local MIXED = CLEAN .. "tickbox|GoneMod|g|true\r\ntickbox|Gone2|h|false"
    resetEnv()
    disk["ModOptions.ini"] = MIXED
    session(false); regAD(); PZAPI.ModOptions:load(); PZAPI.ModOptions:save()
    local vanillaMixed = disk["ModOptions.ini"]
    resetEnv()
    disk["ModOptions.ini"] = MIXED
    session(true); regAD(); PZAPI.ModOptions:load()
    check("4 單筆行（含結尾沒換行）不算黏行，load 不寫檔", io_stats.writes == 0 and disk["ModOptions.ini"] == MIXED)
    PZAPI.ModOptions:save()
    check("4 有未註冊行：只差每行補上 \\r\\n", vanillaMixed == CLEAN .. "tickbox|GoneMod|g|truetickbox|Gone2|h|false"
        and disk["ModOptions.ini"] == CLEAN .. "tickbox|GoneMod|g|true\r\ntickbox|Gone2|h|false\r\n", disk["ModOptions.ini"])

    -- 5 EquipmentUI 式包裝
    local LEGACY_LINE = "combobox|EquipmentUI_B42|EQUIPMENT_UI_SCALE_INDEX|4"
    for _, order in ipairs({ "inner", "outer" }) do
        section("[5] EquipmentUI 的 load 包裝在本補丁" .. (order == "inner" and "內層（先載入）" or "外層（後載入）"))
        for _, glued in ipairs({ false, true }) do
            local tag = "5 " .. order .. (glued and " 黏行" or " 獨立行")
            resetEnv()
            disk["ModOptions.ini"] = glued
                and (AD_LINES[1] .. LEGACY_LINE .. "tickbox|GoneMod|g|true")
                or (LEGACY_LINE .. "\r\ntickbox|GoneMod|g|true\r\n")
            local r = session(true, order == "inner" and installEquipmentUI or nil, order == "outer" and installEquipmentUI or nil)
            local eui = r.before or r.after
            regAD()
            PZAPI.ModOptions:load()
            local found = false
            for _, l in ipairs(PZAPI.ModOptions.OtherOptions) do
                if l:find("EQUIPMENT_UI_SCALE_INDEX", 1, true) then found = true end
            end
            check(tag .. "：舊行轉換並從 OtherOptions 移除", eui.migrated >= 1 and eui.dd:getValue() == 7 and not found,
                eui.migrated .. "/" .. tostring(eui.dd:getValue()))
            PZAPI.ModOptions:save()
            local s5 = disk["ModOptions.ini"]
            check(tag .. "：save 後舊行消失、新值寫入、其他行一筆一行",
                not s5:find("EQUIPMENT_UI_SCALE_INDEX", 1, true) and hasLine(s5, "combobox|EquipmentUI_B42|EQUIPMENT_UI_SCALE|7")
                and hasLine(s5, "tickbox|GoneMod|g|true"), s5)
        end
    end

    -- 6 combobox → slider 的 .selected 訊號
    section("[6] 舊 combobox 行 → 新 slider 的 .selected 遷移訊號")
    for _, glued in ipairs({ false, true }) do
        resetEnv()
        disk["ModOptions.ini"] = glued and ("tickbox|GoneMod|g|truecombobox|MinidoracatMiniMap|ZombieDotSize|3")
            or "combobox|MinidoracatMiniMap|ZombieDotSize|3\r\n"
        session(true)
        local mm = regMiniMap()
        PZAPI.ModOptions:load()
        check("6 " .. (glued and "黏行" or "獨立行") .. "：.selected == 3、slider 值不動",
            mm:getOption("ZombieDotSize").selected == 3 and mm:getOption("ZombieDotSize").value == 3)
    end

    -- 7 切不出合法筆數
    section("[7] 切不出合法筆數就不改檔")
    local BAD = "tickbox|GoneMod|g|truetickbox|MinidoracatAutoDrive|VoiceEnabled|maybe"
    resetEnv()
    disk["ModOptions.ini"] = BAD
    session(true); local ad7 = regAD()
    PZAPI.ModOptions:load()
    check("7 檔案不動、值照原版", io_stats.writes == 0 and disk["ModOptions.ini"] == BAD and ad7:getOption("VoiceEnabled"):getValue() == true)
    check("7 印一行診斷", printCount("glued line 1 has an unrecognised record; file left unchanged") == 1, prints[1])
    PZAPI.ModOptions:load()
    check("7 診斷一 session 一次", printCount("unrecognised record") == 1)
    local MULTI_BAD = "multipletickbox|GoneMod|m|true falsetickbox|Gone2|h|true"
    resetEnv()
    disk["ModOptions.ini"] = MULTI_BAD
    session(true); regAD(); PZAPI.ModOptions:load()
    check("7 multipletickbox 值少了結尾空格也算不合法", io_stats.writes == 0 and disk["ModOptions.ini"] == MULTI_BAD)

    -- 8 寫入讀回不符
    section("[8] 寫入讀回不符（getFileWriter 靜默丟寫）")
    resetEnv()
    disk["ModOptions.ini"] = GLUED_OTHER_FIRST
    session(true); local ad8 = regAD()
    dropNextWrite = true
    PZAPI.ModOptions:load()
    check("8 寫回原內容（逐行相同）", #lines(disk["ModOptions.ini"]) == 1 and lines(disk["ModOptions.ini"])[1] == GLUED_OTHER_FIRST, disk["ModOptions.ini"])
    check("8 沒有第二次 load：值照原版", ad8:getOption("VoiceEnabled"):getValue() == true)
    check("8 印 not verified 診斷", printCount("rewrite not verified; original lines written back") == 1, prints[1])

    -- 9 例外與退回
    section("[9] 出錯退回原版、不吞原 save 的錯誤")
    resetEnv()
    disk["ModOptions.ini"] = GLUED_OTHER_FIRST
    session(true); local ad9 = regAD()
    local realReader = getFileReader
    local n = 0
    getFileReader = function(name, create)
        n = n + 1
        if n == 2 then error("disk gone") end
        return realReader(name, create)
    end
    local ok9 = pcall(PZAPI.ModOptions.load, PZAPI.ModOptions)
    getFileReader = realReader
    check("9 修補讀檔拋錯：load 不外洩、值照原版", ok9 and ad9:getOption("VoiceEnabled"):getValue() == true)
    check("9 修補讀檔拋錯：印 repair failed", printCount("repair failed") == 1, prints[1])

    resetEnv()
    disk["ModOptions.ini"] = "tickbox|Broken|x|true\r\n" .. BASE
    session(true)
    PZAPI.ModOptions.Dict.Broken = {} -- 沒有 .dict：準備 OtherOptions 時拋錯
    PZAPI.ModOptions:save()
    check("9 準備 OtherOptions 拋錯：退回原版 save（清空）並印診斷", disk["ModOptions.ini"] == "" and printCount("vanilla save used") == 1)

    resetEnv()
    disk["ModOptions.ini"] = CLEAN
    session(true); regAD(); PZAPI.ModOptions:load()
    table.insert(PZAPI.ModOptions.OtherOptions, "tickbox|GoneMod|g|true")
    local before = PZAPI.ModOptions.OtherOptions
    PZAPI.ModOptions.Data[1].data[1].type = "textentry"
    PZAPI.ModOptions.Data[1].data[1].value = setmetatable({}, { __tostring = function() error("boom") end })
    local ok9b, err9b = pcall(PZAPI.ModOptions.save, PZAPI.ModOptions)
    check("9 原 save 拋錯照樣外洩", not ok9b and tostring(err9b):find("boom", 1, true) ~= nil, tostring(err9b))
    check("9 原 save 拋錯後 OtherOptions 換回原表", PZAPI.ModOptions.OtherOptions == before and before[1] == "tickbox|GoneMod|g|true")

    -- 10 安裝
    section("[10] 安裝：形狀檢查、冪等")
    resetEnv()
    freshVanilla()
    PZAPI.ModOptions.save = nil
    local okShape = pcall(loadFix)
    check("10 save 不見：不安裝、印一次 NOT installed", okShape and PZAPI.ModOptions.MDFX_ModOptionsPersist == nil
        and printCount("MDFX_ModOptionsPersist NOT installed: vanilla PZAPI.ModOptions shape changed") == 1, prints[1])
    resetEnv()
    disk["ModOptions.ini"] = CLEAN
    freshVanilla()
    loadFix()
    local wrapped = PZAPI.ModOptions.load
    loadFix()
    regAD()
    PZAPI.ModOptions:load()
    check("10 重複載入不疊包裝", PZAPI.ModOptions.load == wrapped and io_stats.reads == 2, io_stats.reads)

    -- 11 官方先補上換行
    section("[11] 官方先補上 :287 的換行、本補丁還沒退場")
    resetEnv()
    disk["ModOptions.ini"] = CLEAN .. "tickbox|GoneMod|g|true"
    local snapshots = {}
    for cycle = 1, 3 do
        session(true, nil, nil, VANILLA_FIXED); regAD()
        PZAPI.ModOptions:load(); PZAPI.ModOptions:save()
        snapshots[cycle] = disk["ModOptions.ini"]
    end
    check("11 未註冊行之後只多一個空行", snapshots[1] == CLEAN .. "tickbox|GoneMod|g|true\r\n\r\n", snapshots[1])
    check("11 再存兩次不會越存越多", snapshots[3] == snapshots[1], snapshots[3])

    return checks, failures
end

-- ── 主程式 ───────────────────────────────────────────────────────
local MUTANTS = {
    { name = "不載入修正", whole = "fix" },
    { name = "修好檔案後不再 load", from = "    elseif repaired then\n        originalLoad(self, ...)\n", to = "" },
    { name = "load 修補不包 pcall", from = "local ok, repaired = pcall(repairFile)", to = "local ok, repaired = true, repairFile()" },
    { name = "沒有黏行也改寫", from = "    if glued == 0 then return false end\n", to = "" },
    { name = "起頭不取最左（照型別順序先找到先贏）", from = "if s and (bs == nil or s < bs) then", to = "if s and bs == nil then" },
    { name = "多筆不驗值", from = "if not VALID[records[i].kind](records[i].value) then return false end", to = "" },
    { name = "寫完不讀回比對", from = "    local back = readLines(false)\n", to = "    do return true end\n    local back = readLines(false)\n" },
    { name = "讀回不符不寫回原內容", from = "    writeVerified(lines)\n", to = "" },
    { name = "save 不補行尾", from = "            line = line .. \"\\r\\n\"\n", to = "" },
    { name = "save 不換回原表", from = "    target.OtherOptions = other\n", to = "" },
    { name = "原 save 的錯誤不重拋", from = "    if not saved then error(err) end\n", to = "" },
    { name = "準備 OtherOptions 不包 pcall", from = "local ok, lines = pcall(linesToWrite, other, pristine)",
        to = "local ok, lines = true, linesToWrite(other, pristine)" },
    { name = "load 過也補檔案裡的行", from = "    if other ~= pristine then return out end\n", to = "" },
    { name = "save 先於 load 不保留檔案內容", from = "    if other ~= pristine then return out end\n", to = "    do return out end\n" },
    { name = "save 先於 load 不拆黏行", from = "if not records then records = { { text = lines[i] } } end", to = "records = { { text = lines[i] } }" },
    { name = "已註冊的行也寫回", from = "and not registered and", to = "and" },
    { name = "不去重", from = "and not seen[text] then", to = "then" },
    { name = "空行也傳給 save", from = "        if line ~= \"\" then\n", to = "        if true then\n" },
    { name = "拆掉形狀檢查", from = "type(api.save) ~= \"function\"", to = "false" },
    { name = "拆掉冪等 marker", from = "if api[MARKER] then", to = "if false then" },
    { name = "診斷不節流", from = "    if warned[key] then return end\n", to = "" },
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
    if m.extra then
        src, why = replaceOnce(src, m.extra.from, m.extra.to)
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
