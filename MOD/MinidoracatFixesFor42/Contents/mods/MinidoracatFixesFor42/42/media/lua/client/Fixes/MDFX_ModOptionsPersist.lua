--[[
MDFX_ModOptionsPersist — 原版 PZAPI.ModOptions 把別的 MOD 的設定黏成一行、或整檔清空

【缺陷】（client/PZAPI/ModOptions.lua，42.21）
所有 MOD 的選項存在同一個 Zomboid/Lua/ModOptions.ini，一筆一行：
`<型別>|<modid>|<optid>|<值>`。
1. load（:292-333）用 readLine 逐行讀，對不上已註冊選項的行原樣存進
   PZAPI.ModOptions.OtherOptions（:330）；save（:259-290）寫回這些行時沒加換行
   （:286-288 `fileOutput:write(line)`），於是全部黏成一行。
2. 下次 load 對黏住的那行只看第一筆的 modid／optid（:304-305）：第一筆屬於已註冊的
   選項就整行在 if 分支裡被丟掉（不進 OtherOptions，下次 save 就永久消失）；否則整行
   留在 OtherOptions，裡面每一筆的值都套不到。
3. 主選單沒有任何 MOD 建選項時，MainOptions:create 不呼叫 load
   （client/OptionScreens/MainOptions.lua:409-411，load 在 addModOptionsPanel 的 :2796），
   這時按套用／Accept，apply 在 :3766 無條件 save，只寫出空的 Data 與空的 OtherOptions。

【後果】
主選單與存檔啟用的 MOD 不同時（每個存檔各自選 MOD），在主選單按一次套用，當下沒載入的
MOD 的設定就黏成一行；下次進遊戲那些 MOD 的設定回到預設，再存一次就永久消失。主選單
沒有任何 MOD 選項時按套用，整個檔案清空。

【本補丁】包裝 load 與 save，不取代原函式；任何一步失敗都退回原版行為。
1. load：先呼叫原 load（保留原版解析、舊 combobox 行寫進同 id 新選項 .selected 的遷移
   訊號 :320、其他 MOD 的包裝鏈）。再直接讀檔找黏行——不能只看 OtherOptions：第一筆屬
   已註冊選項的黏行根本不進 OtherOptions。有黏行就把檔案改寫成一筆一行，用
   getFileReader 讀回逐行比對（getFileWriter 失敗不報錯，家族 pitfalls.md），相同才
   再呼叫一次原 load 把值套上。原版 load 不寫檔，第一次 load 漏掉的值由第二次補回。
   切分：每筆以七種型別關鍵字加 `|modid|optid|` 起頭（save :264-281）；多筆時逐筆驗證
   值是原版 save 寫得出來的形狀，任何一筆不合就整檔不改。
2. save：暫時把 OtherOptions 換成「每行補上 \r\n」的複本、呼叫原 save、再換回原表
   （EquipmentUI 會用 string.find 在 OtherOptions 找自己的舊行，內容不能永久改）。
3. 本 session 還沒有 load 過就 save（OtherOptions 還是原版檔案建立時那張表）：先把檔案
   裡沒註冊的行（黏行先拆開）接在 OtherOptions 後面一起寫回，已註冊的跳過、完全相同的
   行去重。已註冊選項在記憶體裡的值不動——有 MOD 會程式設定值後直接 save。

【安裝時機】本檔在載入時就包好。原版 client 檔排在所有 MOD 之前執行
（LuaManager.java:1192-1193），所以 PZAPI.ModOptions 一定已經存在；
MainOptions:create 只從 MainScreen 的 OnMainMenuEnter／OnGameStart 處理器呼叫
（MainScreen.lua:2178、:2180 → instantiate → :694），這些事件都在 LuaManager.LoadDirBase
之後才觸發（Core.java:3949 → :3962-3963、IngameState.java:1070 → :1077）。

【臨時性】官方在 :287 補上換行、主選單沒有 MOD 選項時也先 load（或不 save）之後就可退場
（check_vanilla_alignment.py 有 exithint）。沒退場前官方先補換行，未註冊行之後各多一個空行，
空行不再傳給 save，所以不會越存越多。沒有黏行、OtherOptions 是空的時，檔案位元組與原版相同。
]]

local FILE = "ModOptions.ini"
local MARKER = "MDFX_ModOptionsPersist"

local warned = {}
local function warnOnce(key, message)
    if warned[key] then return end
    warned[key] = true
    print("[MinidoracatFixes] MDFX_ModOptionsPersist " .. message)
end

local api = type(PZAPI) == "table" and PZAPI.ModOptions
if type(api) ~= "table" or type(api.load) ~= "function" or type(api.save) ~= "function"
    or type(api.OtherOptions) ~= "table" or type(api.Dict) ~= "table"
    or type(getFileReader) ~= "function" or type(getFileWriter) ~= "function" then
    warnOnce("shape", "NOT installed: vanilla PZAPI.ModOptions shape changed; re-check docs/fixes.md")
    return
end
if api[MARKER] then
    return
end

-- save（ModOptions.lua:264-281）寫得出來的型別與值。原版對 nil 值寫 "nil"（tostring）。
local function isNumber(v)
    return v == "nil" or tonumber(v) ~= nil
end
local VALID = {
    textentry = function() return true end,
    tickbox = function(v) return v == "true" or v == "false" or v == "nil" end,
    slider = isNumber,
    combobox = isNumber,
    keybind = isNumber,
    multipletickbox = function(v)
        return (string.gsub(v, "%a+ ", function(w)
            if w == "true " or w == "false " or w == "nil " then return "" end
        end)) == ""
    end,
    colorpicker = function(v)
        local r, g, b, a = string.match(v, "^(%S+) (%S+) (%S+) (%S+)$")
        return r ~= nil and isNumber(r) and isNumber(g) and isNumber(b) and isNumber(a)
    end,
}
local TYPES = { "textentry", "tickbox", "multipletickbox", "slider", "combobox", "colorpicker", "keybind" }

-- 從 init 起最左邊的一筆起頭；multipletickbox 起頭比裡面的 tickbox 早，取最左就不會誤切
local function findHeader(line, init)
    local bs, be, bt, bm, bo
    for i = 1, #TYPES do
        local s, e, mod, opt = string.find(line, TYPES[i] .. "|([^|]+)|([^|]+)|", init)
        if s and (bs == nil or s < bs) then
            bs, be, bt, bm, bo = s, e, TYPES[i], mod, opt
        end
    end
    return bs, be, bt, bm, bo
end

-- 一行切成記錄 { text, mod, opt }：不是記錄行回 nil；多筆而有一筆不合法回 false
local function splitRecords(line)
    local s, e, kind, mod, opt = findHeader(line, 1)
    if s ~= 1 then return nil end
    local records = {}
    while s do
        local ns, ne, nkind, nmod, nopt = findHeader(line, e + 1)
        local stop = (ns or #line + 1) - 1
        records[#records + 1] = { text = string.sub(line, s, stop), kind = kind, value = string.sub(line, e + 1, stop), mod = mod, opt = opt }
        s, e, kind, mod, opt = ns, ne, nkind, nmod, nopt
    end
    if #records > 1 then
        for i = 1, #records do
            if not VALID[records[i].kind](records[i].value) then return false end
        end
    end
    return records
end

local function readLines(create)
    local reader = getFileReader(FILE, create)
    if not reader then return nil end
    local lines = {}
    while true do
        local line = reader:readLine()
        if line == nil then break end
        lines[#lines + 1] = line
    end
    reader:close()
    return lines
end

local function writeVerified(lines)
    local writer = getFileWriter(FILE, true, false)
    if not writer then return false end
    for i = 1, #lines do
        writer:write(lines[i] .. "\r\n")
    end
    writer:close()
    local back = readLines(false)
    if not back or #back ~= #lines then return false end
    for i = 1, #lines do
        if back[i] ~= lines[i] then return false end
    end
    return true
end

-- 有黏行且全部切得開 → 改寫成一筆一行並驗證，成功回 true
local function repairFile()
    local lines = readLines(true)
    if not lines then return false end
    local out, glued = {}, 0
    for i = 1, #lines do
        local records = splitRecords(lines[i])
        if records == false then
            warnOnce("unsplittable", "glued line " .. i .. " has an unrecognised record; file left unchanged")
            return false
        end
        if records and #records > 1 then
            glued = glued + #records
            for j = 1, #records do out[#out + 1] = records[j].text end
        else
            out[#out + 1] = lines[i]
        end
    end
    if glued == 0 then return false end
    if writeVerified(out) then
        warnOnce("repaired", "split " .. glued .. " glued records into one per line")
        return true
    end
    -- 讀回不符：盡量把原內容寫回（逐行相同，只差行尾），交還原版行為
    writeVerified(lines)
    warnOnce("verify", "rewrite not verified; original lines written back")
    return false
end

-- save 要寫的 OtherOptions 複本：每行補行尾、空行不寫（原版寫空字串本來就沒有輸出）；
-- 還沒 load 過就接上檔案裡沒註冊的行
local function linesToWrite(other, pristine)
    local out, seen = {}, {}
    for _, line in ipairs(other) do
        if line ~= "" then
            if type(line) == "string" and string.sub(line, -1) ~= "\n" then
                line = line .. "\r\n"
            end
            out[#out + 1] = line
            seen[line] = true
        end
    end
    if other ~= pristine then return out end
    local lines = readLines(false)
    if not lines then return out end
    local dict = PZAPI.ModOptions.Dict
    for i = 1, #lines do
        local records = splitRecords(lines[i])
        if not records then records = { { text = lines[i] } } end
        for j = 1, #records do
            local r = records[j]
            local registered = r.mod and dict[r.mod] ~= nil and dict[r.mod].dict[r.opt] ~= nil
            local text = r.text .. "\r\n"
            if r.text ~= "" and not registered and not seen[text] then
                out[#out + 1] = text
                seen[text] = true
            end
        end
    end
    return out
end

local originalLoad = api.load
local originalSave = api.save
local pristine = api.OtherOptions

api.load = function(self, ...)
    originalLoad(self, ...)
    local ok, repaired = pcall(repairFile)
    if not ok then
        warnOnce("loadError", "repair failed (" .. tostring(repaired) .. "); vanilla load kept")
    elseif repaired then
        originalLoad(self, ...)
    end
end

api.save = function(self, ...)
    local target = PZAPI.ModOptions
    local other = target.OtherOptions
    local ok, lines = pcall(linesToWrite, other, pristine)
    if not ok then
        warnOnce("saveError", "could not prepare other lines (" .. tostring(lines) .. "); vanilla save used")
        return originalSave(self, ...)
    end
    target.OtherOptions = lines
    local saved, err = pcall(originalSave, self, ...)
    target.OtherOptions = other
    if not saved then error(err) end
end

api[MARKER] = api.load
