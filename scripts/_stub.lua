-- server 端守衛測試的共用假環境（不是測試，沒有 main）
-- 用法：local S = dofile("scripts/_stub.lua")
--       S.reset()                      -- dedicated server（預設）
--       S.reset({ server = false })     -- client／單人
--       S.load(S.SERVER_FIXES .. "MDFX_FooGuard.lua")
--       S.fireBoot()  S.printed(x)  S.printCount(x)  S.finish(checks, failures)
--
-- reset() 每次都重新 dofile MDFX_Guard.lua：它的 warnOnce 旗標是 file-local
-- closure，重新載入才能讓每個測試段落從乾淨的節流狀態開始。

local S = {}

local MOD_LUA = "MOD/MinidoracatFixesFor42/Contents/mods/MinidoracatFixesFor42/42/media/lua/"
S.SERVER_FIXES = MOD_LUA .. "server/Fixes/"
S.GUARD = MOD_LUA .. "shared/Fixes/MDFX_Guard.lua"

S.realPrint = print
S.prints = {}
S.bootHandlers = {}
S.onServer = true

-- 假 instanceof：物件用 _class 欄位標型別；nil 一律 false（比照
-- LuaManager.instof，LuaManager.java:2948-2951 的 `if (obj == null) return false`）
local function stubInstanceof(obj, className)
    return type(obj) == "table" and obj._class == className
end

function S.reset(opts)
    opts = opts or {}
    S.prints = {}
    S.bootHandlers = {}
    S.onServer = opts.server ~= false

    isServer = function() return S.onServer end
    instanceof = opts.instanceof or stubInstanceof
    Events = { OnGameBoot = { Add = function(fn) S.bootHandlers[#S.bootHandlers + 1] = fn end } }
    print = function(...)
        local parts = {}
        for i = 1, select("#", ...) do parts[i] = tostring(select(i, ...)) end
        S.prints[#S.prints + 1] = table.concat(parts, " ")
    end

    MDFX_Guard = nil
    dofile(S.GUARD)
end

function S.load(path)
    dofile(path)
end

function S.fireBoot()
    for i = 1, #S.bootHandlers do S.bootHandlers[i]() end
end

function S.printCount(needle)
    local n = 0
    for i = 1, #S.prints do
        if S.prints[i]:find(needle, 1, true) then n = n + 1 end
    end
    return n
end

function S.printed(needle)
    return S.printCount(needle) > 0
end

-- 只新增了哪些成員（用來斷言「除了 marker 什麼都沒動」）
function S.extraKeys(tbl, before, allowed)
    local extra = {}
    for k in pairs(tbl) do
        if not before[k] and k ~= allowed then extra[#extra + 1] = tostring(k) end
    end
    return extra
end

function S.snapshotKeys(tbl)
    local before = {}
    for k in pairs(tbl) do before[k] = true end
    return before
end

-- 每支測試共用的計分器
function S.checker()
    local state = { checks = 0, failures = 0 }
    function state.check(label, cond, detail)
        state.checks = state.checks + 1
        if cond then
            S.realPrint(string.format("  PASS  %s", label))
        else
            state.failures = state.failures + 1
            S.realPrint(string.format("  FAIL  %s%s", label, detail and ("  — " .. detail) or ""))
        end
    end
    function state.section(title)
        S.realPrint(title)
    end
    function state.finish()
        print = S.realPrint
        S.realPrint("")
        S.realPrint(string.format("%d checks, %d failed", state.checks, state.failures))
        os.exit(state.failures == 0 and 0 or 1)
    end
    return state
end

return S
