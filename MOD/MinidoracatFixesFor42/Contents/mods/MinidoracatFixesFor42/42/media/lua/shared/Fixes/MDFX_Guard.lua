--[[
MDFX_Guard — server 端 vanilla 守衛的共用骨架

本檔不修任何東西，只把六支 server 端守衛重複的四件事收成一處：

1. **`isServer()` 閘門**——這些爆點只存在於 dedicated server 的封包重建路徑，
   client／單人不安裝（`server/` 目錄在單人也會載入，所以閘門要自己判）。
   `isServer` 在檔案載入時可能還沒註冊，所以先驗型別再呼叫。
2. **形狀檢查**——class 表存在、每個要包的 method 都還是 function；不符就印
   一次 `NOT installed: … shape changed` 並放棄安裝（不猜、不硬包）。
3. **冪等 marker**——marker 存第一個 wrapper 的引用：`Core.ResetLua` 重載時
   vanilla 重建整張表、marker 隨之消失、重跑重新包裝；後載 MOD 整支替換目標
   函式時，`OnGameBoot` 復查發現 marker 與現任不符，把「他的版本」當新
   original 再包一層（chain，兩邊行為都保留）。比本補丁更晚的替換不在保證範圍。
4. **一 session 一次的診斷**——正式服的爆點頻率是每天數十次量級，逐次寫 log
   等於自製日誌洪水（家族 Log 坑見 pitfalls.md）。

放 `shared/` 是因為 PZ 的載入順序是 shared → client → server，server 端的
守衛檔一定拿得到它。本檔在 client／單人也會載入，但只是定義函式、不做事。

刻意保持在「三個函式」的規模，不做成框架：需要的守衛自己寫 wrapper 本體，
骨架只負責安裝時機與形狀把關。`MDFX_ReloadSpeedGuard`（shared 三端、沒有
`isServer()` 閘門）與 `MDFX_ButcherMeatRatio`（vanilla 函式本身在單人也會跑，
加閘門等於在單人關掉修復）形狀不同，刻意不改走本骨架。
]]

MDFX_Guard = MDFX_Guard or {}

local warned = {}

-- 一 session 一次的診斷。回傳是否真的印了（測試用得到）。
function MDFX_Guard.warnOnce(key, message)
    if warned[key] then
        return false
    end
    warned[key] = true
    print("[MinidoracatFixes] " .. message)
    return true
end

-- 只在 dedicated server 執行 install：立即跑一次，並在 OnGameBoot 復查一次。
function MDFX_Guard.onServer(install)
    local function run()
        if type(isServer) == "function" and isServer() then
            install()
        end
    end
    run()
    if Events and Events.OnGameBoot then
        Events.OnGameBoot.Add(run)
    end
end

-- 包裝 vanilla class 的 method。
-- spec = {
--   name    = "fooGuard",              -- marker 與診斷 key 用
--   class   = "ISFoo",                 -- 全域名字（每輪重新查，才吃得到 ResetLua 後的新表）
--   methods = { "complete", "update" },-- 全部都要存在才安裝；methods[1] 是 marker 的錨
--   build   = function(originals) return { complete = fn, update = fn } end,
-- }
function MDFX_Guard.wrap(spec)
    local marker = "MDFX_" .. spec.name
    local anchor = spec.methods[1]

    MDFX_Guard.onServer(function()
        local cls = _G[spec.class]
        if type(cls) ~= "table" then
            cls = nil
        end
        local originals = {}
        for i = 1, #spec.methods do
            local fn = cls and cls[spec.methods[i]]
            if type(fn) ~= "function" then
                cls = nil
                break
            end
            originals[spec.methods[i]] = fn
        end
        if not cls then
            MDFX_Guard.warnOnce(marker .. ":shape", spec.name
                .. " NOT installed: vanilla " .. spec.class
                .. " shape changed; re-check docs/fixes.md")
            return
        end
        if cls[marker] == cls[anchor] then
            return
        end
        local wrappers = spec.build(originals)
        for name, fn in pairs(wrappers) do
            cls[name] = fn
        end
        cls[marker] = cls[anchor]
    end)
end
