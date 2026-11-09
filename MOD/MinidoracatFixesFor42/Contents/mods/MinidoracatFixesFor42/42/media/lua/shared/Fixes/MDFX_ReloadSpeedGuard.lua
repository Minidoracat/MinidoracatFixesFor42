--[[
MDFX_ReloadSpeedGuard — setReloadSpeed 兩種已知壞形狀的三端保護

【缺陷】
vanilla `ISReloadWeaponAction.setReloadSpeed`（shared/TimedActions/
ISReloadWeaponAction.lua:75-114）在 :86 取 `character:getPrimaryHandItem()` 當
「槍」，:90 的 gate 只檢查「手上有東西＋穿彈藥背帶（AMMO_STRAP）或帶 RELOAD_FAST
標籤裝備」，之後兩處會拋錯：

一、手持非槍械（42.20 起）：
    :93  if gun:getAmmoType() == AmmoType.SHOTGUN_SHELLS then   -- 基類方法，安全
    :95  elseif gun:getMagazineType() then                      -- 只有 HandWeapon 有！
`getAmmoType` 定義在 InventoryItem 基類（InventoryItem.java:3901，回 null 安全），
`getMagazineType` 只在 HandWeapon（HandWeapon.java:2020）。手持手電筒／撬棍等
非武器物品時 :95 對 Java 物件呼叫不存在的方法，Kahlua 拋
`Object tried to call nil in setReloadSpeed`（正式服 log 實據，7 次/輪）。

二、穿 RELOAD_FAST_MAGAZINES 裝備、沒穿彈藥背帶（42.22 起）：
42.22 的 :90 gate 多了 `character:hasWornTag(ItemTag.RELOAD_FAST_MAGAZINES)`。原版肩掛槍套、
胸掛、ALICE 腰帶吊帶都帶這個標籤（穿在 shoulderholster／webbing，不是 AMMO_STRAP）。
槍不吃彈匣時（散彈槍走 :100、左輪與其他走 :102；手持近戰武器對彈匣裝子彈也走 :102），
前面的標籤都不符就對 nil 的 strap 呼叫 `strap:getClothingItemName()`，拋
`attempted index: getClothingItemName of non-table: null`。官方論壇 42.22.0 已有回報
（topic 102797：穿 ALICE 腰帶吊帶裝填左輪就出錯）。

【後果】
觸發一不需要手持槍：對彈匣裝子彈（ISLoadBulletsInMagazine）手上拿什麼都行。
兩種都在 initVars() 裡拋出：server 端 serverStart() 在三個 emulateAnimEvent 註冊之前
中斷，裝彈流程沒開始：子彈不消耗、彈匣或槍不填充，玩家看到「按了裝彈沒動作」。
單人與 MP 客戶端走 start() → initVars() 同一條路，start() 後半沒跑完，update() 每幀
對 nil 的 ammoCount 做運算再拋錯。所以本補丁放 shared/ 讓三端都被保護。
7 個 caller（Reload／Eject／Insert／LoadBullets／Rack／UnloadFirearm／
UnloadMagazine 的 initVars）全部以表查用法呼叫，包裝後全數受益。

【本補丁】
包裝 `ISReloadWeaponAction.setReloadSpeed`：

1. 先原樣呼叫原函式，成功就結束——正常玩家的裝彈速度公式一個位元都沒動，
   vanilla 更新公式時正常路徑自動跟進。
2. 原函式拋出時**正面辨識已知壞形狀**：
   - 一：手持物存在且不是 HandWeapon；
   - 二：沒穿彈藥背帶，而且錯誤訊息是對 nil 取 getClothingItemName（Kahlua 全文
     `attempted index: getClothingItemName of non-table: null`，KahluaThread.java:1134-1137）。
   吻合才以 vanilla :76-83／:109-112 的「無背帶加成」語意重算並寫入：

       0.8 ＋ 裝填技能×0.10 － 恐慌×0.05（rack 時改＋技能×0.04、不扣恐慌）
       駕駛中再 ×0.8

   一：背帶那段（:85-108）本來就只對「手持槍械」有意義，跳過它不是少算。
   二：走到 strap 取值＝前面的標籤都不符，沒穿背帶時原版本來就是無加成。
   重算再失敗整體退 1.0（下游 getReloadTime 的 getVariableFloat 預設值，
   ISReloadWeaponAction.lua:70），不用算到一半的值。
3. 原函式因**其他原因**拋出（未來版本的新問題）→ 印一次警告後把原始錯誤
   原樣重拋——本補丁只承接它能辨識的形狀，不冒充、不掩蓋新的 regression。

【取捨】
不整函式複製替換——40 行的複製面在遊戲更新時就是 40 行的漂移風險；
pcall 包原函式讓正常路徑永遠跟著 vanilla 走，fallback 公式只在
「vanilla 自己已經炸掉、且確認是已知形狀」時才承重。fallback 過期的最壞後果
是壞形狀下裝彈速度略偏，而不是任何正常玩家受影響。

【安裝機制】
sentinel 存 wrapper 自身引用：Core.ResetLua 重載時 vanilla 重建表、本檔重跑
重新包裝；後載 MOD 整支替換時 OnGameBoot 復查把「他的版本」當新 original
再包一層。比本補丁更晚的替換不在保證範圍。

【退場條件】
一：官方在 :95 前檢查手持物是否槍械（或改用基類安全的查法）。
二：官方在 :100／:102 對 strap 判 nil。兩者都修好才整支退場。
遊戲更新後跑 `python scripts/check_vanilla_alignment.py` 確認 vanilla 形狀是否已變。
]]

local warnedFallback = false
local warnedNoStrap = false
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

    -- 已知壞形狀：回 "nonFirearm"（手持物不是 HandWeapon，vanilla :95 對它呼叫 getMagazineType）、
    -- "noStrap"（沒穿彈藥背帶，vanilla :100／:102 對 nil 的 strap 取 getClothingItemName）；其餘回 nil。
    -- noStrap 比對 Kahlua 對 nil 取值的完整訊息：只比方法名稱會連別的 getClothingItemName 錯誤一起吞掉
    local function knownBadShape(character, err)
        local gun = character:getPrimaryHandItem()
        if gun == nil then return nil end
        if not instanceof(gun, "HandWeapon") then return "nonFirearm" end
        if character:getWornItem(ItemBodyLocation.AMMO_STRAP) == nil
            and string.find(tostring(err), "attempted index: getClothingItemName of non-table: null", 1, true) then
            return "noStrap"
        end
        return nil
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

        local shape = nil
        pcall(function() shape = knownBadShape(character, err) end)

        if not shape then
            -- 不是我們認識的形狀：不冒充，原樣重拋讓 regression 可見。
            -- 注意 Kahlua 的 error() 會動 coroutine.stackTrace（BaseLib.java:248-259，
            -- 第二參數是 stacktrace 字串不是 Lua level），原始 Lua 堆疊救不回來，
            -- 所以先把完整錯誤全文印進 log 保真，再以單參 error 重拋。
            if not warnedUnknown then
                warnedUnknown = true
                print("[MinidoracatFixes] setReloadSpeed threw for an unrecognized reason; NOT masking it (re-throwing): "
                    .. tostring(err)
                    .. " - see docs/fixes.md MDFX_ReloadSpeedGuard")
            end
            error(err)
        end

        local okCalc, speed = pcall(fallbackSpeed, character, rack)
        if not okCalc or type(speed) ~= "number" then
            speed = 1.0
        end
        pcall(function() character:setVariable("ReloadSpeed", speed) end)
        if shape == "nonFirearm" then
            if not warnedFallback then
                warnedFallback = true
                print("[MinidoracatFixes] setReloadSpeed crashed on a non-firearm in primary hand (vanilla ISReloadWeaponAction.lua:95); fallback ReloadSpeed="
                    .. tostring(speed)
                    .. ". Further occurrences suppressed this session. See docs/fixes.md MDFX_ReloadSpeedGuard")
            end
        elseif not warnedNoStrap then
            warnedNoStrap = true
            print("[MinidoracatFixes] setReloadSpeed crashed on a missing ammo strap (reload-fast gear worn, nothing on AMMO_STRAP); fallback ReloadSpeed="
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
