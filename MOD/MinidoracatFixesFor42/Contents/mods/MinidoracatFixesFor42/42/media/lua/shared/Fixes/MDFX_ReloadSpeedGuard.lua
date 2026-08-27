--[[
MDFX_ReloadSpeedGuard — setReloadSpeed 對「手持非槍械」缺防護的三端保護

【缺陷】
vanilla `ISReloadWeaponAction.setReloadSpeed`（shared/TimedActions/
ISReloadWeaponAction.lua:75-114）在 :86 取 `character:getPrimaryHandItem()` 當
「槍」，:90 的 gate 只檢查了「手上有東西＋穿彈藥背帶（AMMO_STRAP）或帶
RELOAD_FAST 標籤裝備」，沒檢查那東西是不是槍械：

    :93  if gun:getAmmoType() == AmmoType.SHOTGUN_SHELLS then   -- 基類方法，安全
    :95  elseif gun:getMagazineType() then                      -- 只有 HandWeapon 有！

`getAmmoType` 定義在 InventoryItem 基類（InventoryItem.java:3901，回 null 安全），
`getMagazineType` 只在 HandWeapon（HandWeapon.java:2020）。手持手電筒／撬棍等
非武器物品時 :95 對 Java 物件呼叫不存在的方法，Kahlua 拋
`Object tried to call nil in setReloadSpeed`（正式服 log 實據，7 次/輪）。

【後果】
觸發不需要手持槍：對彈匣裝子彈（ISLoadBulletsInMagazine）手上拿什麼都行。
server 端 serverStart() → initVars() → setReloadSpeed 在三個 emulateAnimEvent
註冊之前拋出 → 裝彈流程沒開始就中斷：子彈不消耗、彈匣不填充，
玩家看到「按了裝彈沒動作」。同一段程式碼在單人與 MP 客戶端一樣會炸
（start() → initVars() 同路徑），所以本補丁放 shared/ 讓三端都被保護。
7 個 caller（Reload／Eject／Insert／LoadBullets／Rack／UnloadFirearm／
UnloadMagazine 的 initVars）全部以表查用法呼叫，包裝後全數受益。

【本補丁】
包裝 `ISReloadWeaponAction.setReloadSpeed`：

1. 先原樣呼叫原函式，成功就結束——正常玩家的裝彈速度公式一個位元都沒動，
   vanilla 更新公式時正常路徑自動跟進。
2. 原函式拋出時**正面辨識已知壞形狀**：手持物存在且不是 HandWeapon。
   吻合才以 vanilla :76-83／:109-112 的「無背帶加成」語意重算並寫入：

       0.8 ＋ 裝填技能×0.10 － 恐慌×0.05（rack 時改＋技能×0.04、不扣恐慌）
       駕駛中再 ×0.8

   背帶那段（:85-108）本來就只對「手持槍械」有意義，跳過它不是少算，
   而是這個形狀下的正確語意。重算再失敗整體退 1.0（下游 getReloadTime 的
   getVariableFloat 預設值，ISReloadWeaponAction.lua:70），不用算到一半的值。
3. 原函式因**其他原因**拋出（未來版本的新問題）→ 印一次警告後把原始錯誤
   原樣重拋——本補丁只承接它能辨識的形狀，不冒充、不掩蓋新的 regression。

【取捨】
不整函式複製替換——40 行的複製面在遊戲更新時就是 40 行的漂移風險；
pcall 包原函式讓正常路徑永遠跟著 vanilla 走，fallback 公式只在
「vanilla 自己已經炸掉、且確認是已知形狀」時才承重。fallback 過期的最壞後果
是壞形狀下裝彈速度略偏，而不是任何正常玩家受影響。
順帶記錄 vanilla 同函式的另一顆未爆彈：:100/:102 在 reloadFast 為 true、
沒穿背帶時 `strap:getClothingItemName()` 對 nil 解參考。該形狀需要「手持
shell/bullets 槍械＋帶 RELOAD_FAST tag＋沒穿背帶＋tag 細項全不匹配」，
實戰 log 零實據；真的發生時它手持的是槍械、不吻合本補丁的辨識條件，
會走「重拋」路徑原樣暴露——刻意不擴大承接範圍。

【安裝機制】
sentinel 存 wrapper 自身引用：Core.ResetLua 重載時 vanilla 重建表、本檔重跑
重新包裝；後載 MOD 整支替換時 OnGameBoot 復查把「他的版本」當新 original
再包一層。比本補丁更晚的替換不在保證範圍。

【退場條件】
官方在 :95 前檢查手持物是否槍械（或改用基類安全的查法）。
遊戲更新後跑 `python scripts/check_vanilla_alignment.py` 確認 vanilla 形狀是否已變。
]]

local warnedFallback = false
local warnedUnknown = false
local warnedNotInstalled = false

local function install()
    if type(ISReloadWeaponAction) ~= "table"
        or type(ISReloadWeaponAction.setReloadSpeed) ~= "function" then
        if not warnedNotInstalled then
            warnedNotInstalled = true
            print("[MinidoracatFixes] MDFX_ReloadSpeedGuard NOT installed: vanilla ISReloadWeaponAction shape changed; re-check docs/fixes.md")
        end
        return
    end
    if ISReloadWeaponAction.MDFX_reloadSpeedGuard == ISReloadWeaponAction.setReloadSpeed then
        return
    end

    local original = ISReloadWeaponAction.setReloadSpeed

    -- 已知壞形狀：手持物存在且不是 HandWeapon（vanilla :95 對它 call nil）
    local function isKnownBadShape(character)
        local gun = character:getPrimaryHandItem()
        return gun ~= nil and not instanceof(gun, "HandWeapon")
    end

    -- vanilla :76-83 ＋ :109-112 的無背帶語意（背帶加成只對手持槍械有意義）
    local function fallbackSpeed(character, rack)
        local speed = 0.8
        if rack then
            speed = speed + character:getPerkLevel(Perks.Reloading) * 0.04
        else
            speed = speed + character:getPerkLevel(Perks.Reloading) * 0.10
            speed = speed - character:getMoodles():getMoodleLevel(MoodleType.PANIC) * 0.05
        end
        if character:getVehicle() and character:getVehicle():getDriver() == character then
            speed = speed * 0.8
        end
        return speed
    end

    local function wrapper(character, rack)
        local ok, err = pcall(original, character, rack)
        if ok then return end

        local recognized = false
        pcall(function() recognized = isKnownBadShape(character) end)

        if not recognized then
            -- 不是我們認識的形狀：不冒充，原樣重拋讓 regression 可見。
            -- 注意 Kahlua 的 error() 會動 coroutine.stackTrace（BaseLib.java:248-259，
            -- 第二參數是 stacktrace 字串不是 Lua level），原始 Lua 堆疊救不回來，
            -- 所以先把完整錯誤全文印進 log 保真，再以單參 error 重拋。
            if not warnedUnknown then
                warnedUnknown = true
                print("[MinidoracatFixes] setReloadSpeed threw for an unrecognized reason; NOT masking it (re-throwing): "
                    .. tostring(err)
                    .. " — see docs/fixes.md MDFX_ReloadSpeedGuard")
            end
            error(err)
        end

        local okCalc, speed = pcall(fallbackSpeed, character, rack)
        if not okCalc or type(speed) ~= "number" then
            speed = 1.0
        end
        pcall(function() character:setVariable("ReloadSpeed", speed) end)
        if not warnedFallback then
            warnedFallback = true
            print("[MinidoracatFixes] setReloadSpeed crashed on a non-firearm in primary hand (vanilla ISReloadWeaponAction.lua:95); fallback ReloadSpeed="
                .. tostring(speed)
                .. ". Further occurrences suppressed this session. See docs/fixes.md MDFX_ReloadSpeedGuard")
        end
    end

    ISReloadWeaponAction.setReloadSpeed = wrapper
    ISReloadWeaponAction.MDFX_reloadSpeedGuard = wrapper
end

install()
if Events and Events.OnGameBoot then
    Events.OnGameBoot.Add(install)
end
