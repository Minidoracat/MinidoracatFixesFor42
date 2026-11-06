--[[
MDFX_HealthCheatPermission — 強化多人伺服器對健康作弊（管理員功能）的驗證（42.21）

【缺陷】原版 media/lua/server/ClientCommands.lua（42.21.0，:474-627）處理健康作弊的伺服器端驗證不完整，參數不對時也會丟錯。
細節屬攻擊面分析，依家族保密規則只寫在本機知識庫（fixes-dev 的 references/server-commands.md）。
合法流程：管理員對自己作弊時送 onHealthCheatCurrentPlayer；對別人作弊時送 onHealthCheat，伺服器檢查管理員權限後轉給目標的客戶端
（:477），目標的客戶端再替自己送 onHealthCheatCurrentPlayer（ISHealthPanel.lua:191-195、329-332、1964-1969）。

【本補丁】只在伺服器生效。
- 掛點：原版的 Commands 是檔內 local，拿不到單一指令，改包整支 OnClientCommand 分派器（:1296-1307）。本檔放 shared/，
  專用伺服器先載入全部 shared/ 再載入 server/（GameServer.java:1469-1471），所以早於原版檔：載入時暫換
  Events.OnClientCommand.Add（Events.X 是一般 Lua 表，Event.java:78-83），以 getFilenameOfClosure（LuaManager.java:7345-7347）
  認出原版 server/ClientCommands.lua 傳進來的函式（路徑不含 /mods/），換成包裝再交給引擎；其他函式原樣轉交。
  OnGameBoot 換回 Add；原版檔恰好註冊一支才啟用，否則印 NOT installed，包裝原樣轉交。
- 包裝只看 player 模組的兩個指令，其餘原樣交給原版：
  - onHealthCheat：原版會轉送時（目標在線、寄件者有 UseHealthCheat）先給目標記一張轉送票，再照原版處理。
  - onHealthCheatCurrentPlayer：寄件者有 UseHealthCheat（與 onHealthCheat 同一個 checkPermissions）照原版；沒有時，只放行
    「管理員轉給他的那一筆」：args.id 是自己、部位與 action 和票上的相同、TICKET_MS 內。票只用一次，寄件者有權限時也照樣用掉。
    其餘拒絕，不改任何人。參數不合法（args 不是表、args.id 不是在線玩家的 onlineID、bodyPartIndex 不是 0～部位數-1 的整數）
    一律拒絕，不丟錯，有權限也一樣。
- 自己的檢查包在 pcall 裡：檢查本身出錯時，onHealthCheatCurrentPlayer 拒絕、onHealthCheat 照原版（各印一次）；原版的錯誤原樣外洩。
- 每次拒絕記一行（名稱、onlineID、SteamID、目標 args.id、action、部位）。額度以連線計：Steam 伺服器用 SteamID 加 onlineID
  （SteamID 是捨入值，相鄰的帳號會相同），否則用 onlineID 加名稱（onlineID 斷線後會給下一個人）；每個連線每 session 最多 LOG_LIMIT 行，
  超過印一次提示。名稱由客戶端提供，不能當身分（認人看 SteamID）；名稱與參數輸出前都去掉控制字元與引號、截長。
  SteamID 是 getSteamID() 的 long 轉成 Lua double 後的值（KahluaNumberConverter.java:106、113），SteamID64 會被捨入到 16 的倍數，
  所以寫成 steamid~；精確值看同一秒 Logs/*_cmd.txt 的那一行（GameServer.java:2290-2305，開頭是連線的 SteamID）。

【已知限制】
- 攔不到原版的登記（印 NOT installed、照原版）：別的 MOD 整份蓋掉原版 ClientCommands.lua；別的 MOD 在本檔載入前就 require 原版檔；
  晚於本檔的 shared/ 檔換掉 Events.OnClientCommand.Add 又不轉交給換掉前的函式。伺服器中途重載 Lua 後沒有再觸發 OnGameBoot 時不啟用。
- 原版轉送路徑仍信任目標客戶端回送的那一筆；票只放行管理員剛轉送的同一部位、同一 action。
- 管理員對分割畫面的第 2～4 位玩家作弊時，原版客戶端用第 1 位玩家回送（ISHealthPanel.lua:1967），本補丁拒絕並記成那位玩家的 denied；
  回送晚於 TICKET_MS 時也記成 denied。

【退場條件】
官方讓 onHealthCheatCurrentPlayer 自己驗證權限與參數（而且管理員對別人作弊的轉送路徑仍可用）。
遊戲更新後跑 `python scripts/check_vanilla_alignment.py`。
]]

if MDFX_HealthCheatPermission then return end
if not (type(isServer) == "function" and isServer()) then return end

local MODULE, CHEAT, RELAY = "player", "onHealthCheatCurrentPlayer", "onHealthCheat"
local VANILLA_FILE = "/media/lua/server/clientcommands.lua"
local LOG_LIMIT = 20     -- 每個連線身分每 session 的拒絕 log 行數
local TICKET_MS = 30000  -- 管理員轉送後，目標客戶端回送的期限（真實時間）

local function say(message)
    print("[MinidoracatFixes] MDFX_HealthCheatPermission " .. message .. " See docs/fixes.md MDFX_HealthCheatPermission")
end

local event = Events and Events.OnClientCommand
if not (event and event.Add and Events.OnGameBoot and Events.OnGameBoot.Add and getFilenameOfClosure and checkPermissions
        and getPlayerByOnlineID and getTimestampMs and Capability and Capability.UseHealthCheat) then
    say("NOT installed: engine API shape changed; re-check docs/fixes.md.")
    return
end

local G = { denied = 0, bad = 0, relayed = 0 }
MDFX_HealthCheatPermission = G

local active = false
local tickets = {} -- 目標 IsoPlayer → { { part, action, at }, ... }
local logged = {}  -- 連線（SteamID|onlineID，非 Steam 伺服器 onlineID|名稱）→ 已印的拒絕行數
local warned = {}

local function permitted(player)
    return checkPermissions(player, Capability.UseHealthCheat) == true
end

local function prune(now)
    local empty = {}
    for target, list in pairs(tickets) do
        for i = #list, 1, -1 do
            local age = now - list[i].at
            if age < 0 or age > TICKET_MS then table.remove(list, i) end
        end
        if #list == 0 then empty[#empty + 1] = target end
    end
    for i = 1, #empty do tickets[empty[i]] = nil end
end

local function takeTicket(player, args)
    prune(getTimestampMs())
    local list = tickets[player]
    if not list then return false end
    for i = 1, #list do
        if list[i].part == args.bodyPartIndex and list[i].action == args.action then
            table.remove(list, i)
            return true
        end
    end
    return false
end

local function isIndex(v, size)
    return type(v) == "number" and v == math.floor(v) and v >= 0 and v < size
end

-- nil＝交給原版；否則回 "denied"／"bad" 與原因
local function screenCheat(player, args)
    if type(args) ~= "table" then return "bad", "args is not a table" end
    -- 管理員轉來的那一筆：寄件者有沒有權限都把票用掉，票不能留到之後（例如被撤權後）再用
    local relayed = args.id == player:getOnlineID() and takeTicket(player, args)
    local allowed = permitted(player)
    if not allowed and not relayed then return "denied", "no UseHealthCheat" end
    local target = type(args.id) == "number" and getPlayerByOnlineID(args.id) or nil
    if not target or target:getOnlineID() ~= args.id then return "bad", "no online player with this onlineID" end
    if not isIndex(args.bodyPartIndex, target:getBodyDamage():getBodyParts():size()) then
        return "bad", "body part index out of range"
    end
    if relayed and not allowed then G.relayed = G.relayed + 1 end
    return nil
end

local function steamText(player)
    local v = player:getSteamID()
    if type(v) ~= "number" or v <= 0 then return "none" end
    local hi = math.floor(v / 1e9)
    local lo = tostring(math.floor(v - hi * 1e9))
    return (hi > 0 and tostring(hi) .. string.rep("0", 9 - #lo) or "") .. lo
end

local function clip(v)
    return (string.sub((string.gsub(tostring(v), "[%c\"]", "?")), 1, 32))
end

local function note(kind, why, player, args)
    local sid = steamText(player)
    local id = tostring(player:getOnlineID())
    local key = sid ~= "none" and (sid .. "|" .. id) or (id .. "|" .. tostring(player:getUsername()))
    local n = (logged[key] or 0) + 1
    logged[key] = n
    if n > LOG_LIMIT + 1 then return end
    local who = clip(player:getUsername())
    if n == LOG_LIMIT + 1 then
        say(string.format('reached LOG_LIMIT for player="%s" onlineID=%s steamid~%s; further rejections are not logged this session.',
            who, id, sid))
        return
    end
    local t = type(args) == "table" and args or {}
    say(string.format('%s %s (%s): player="%s" onlineID=%s steamid~%s target=%s action=%s part=%s.', kind, CHEAT, why, who,
        id, sid, clip(t.id), clip(t.action), clip(t.bodyPartIndex)))
end

-- 回 true＝交給原版
local function screen(command, player, args)
    if command == RELAY then
        if type(args) == "table" and type(args.id) == "number" then
            local target = getPlayerByOnlineID(args.id)
            if target and permitted(player) then
                prune(getTimestampMs())
                local list = tickets[target] or {}
                tickets[target] = list
                list[#list + 1] = { part = args.bodyPartIndex, action = args.action, at = getTimestampMs() }
            end
        end
        return true
    end
    local kind, why = screenCheat(player, args)
    if not kind then return true end
    G[kind] = G[kind] + 1
    note(kind, why, player, args)
    return false
end

local function wrap(vanilla)
    return function(module, command, player, args)
        if active and module == MODULE and (command == CHEAT or command == RELAY) then
            local ok, pass = pcall(screen, command, player, args)
            if not ok then
                if not warned[command] then
                    warned[command] = true
                    say(string.format("check for %s failed (%s); %s.", command, tostring(pass),
                        command == CHEAT and "rejecting it" or "passing it to vanilla"))
                end
                pass = command ~= CHEAT
            end
            if not pass then return end
        end
        return vanilla(module, command, player, args)
    end
end

local engineAdd = event.Add
local seen = 0 -- 原版檔註冊的 OnClientCommand 數

local function fromVanilla(fn)
    local ok, file = pcall(getFilenameOfClosure, fn)
    if not ok or type(file) ~= "string" then return false end
    local path = string.lower((string.gsub(file, "\\", "/")))
    return string.sub(path, -#VANILLA_FILE) == VANILLA_FILE and not string.find(path, "/mods/", 1, true)
end

local function add(fn)
    if type(fn) == "function" and fromVanilla(fn) then
        seen = seen + 1
        fn = wrap(fn)
    end
    return engineAdd(fn)
end
event.Add = add

Events.OnGameBoot.Add(function()
    if event.Add == add then event.Add = engineAdd end
    if seen ~= 1 then
        say("NOT installed: expected 1 OnClientCommand registration from vanilla server/ClientCommands.lua, saw "
            .. seen .. "; re-check docs/fixes.md.")
        return
    end
    active = true
    say("installed (vanilla OnClientCommand dispatcher wrapped).")
end)
