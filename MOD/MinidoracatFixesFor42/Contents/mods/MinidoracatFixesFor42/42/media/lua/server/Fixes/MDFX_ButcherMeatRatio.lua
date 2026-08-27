--[[
MDFX_ButcherMeatRatio — 屠宰壞屍體（modData 缺 meatRatio）的 server 端防護

【背景】
vanilla `setAnimalBodyData`（shared/Definitions/animal/ButcheringUtil.lua:12-57）在
:18 查 `AnimalPartsDefinitions.animals[fullName]`，模組動物查不到時 def 為 nil，
:19 還誠實寫下 `modData["parts"] = def ~= nil`，:27 卻無條件解參考 `def.feather`
——當場拋錯，而 meatRatio 要到 :40 才寫入。Java 端 IsoDeadBody.setAnimalData 是
protectedCallVoid，錯誤被吞掉後屍體照樣生成，於是成為「isAnimal() 為 true、
modData 永久缺 meatRatio」的壞資料。這與已退場的 MDFX_AnimalTrailerSize
（docs/fixes.md）是同一個根因、不同下游爆點。

【缺陷】
`ButcheringUtil.butcherAnimalFromGround`（ButcheringUtil.lua:70）在給任何產出之前
先組除錯字串：

    text = text .. "Meat ratio: " .. carcass:getModData()["meatRatio"] .. "\r\n";

缺欄位時 Kahlua 對 nil 串接直接拋
`__concat not defined for operands: null`（正式服 log 實據，0–20 次/天）。
就算值存在但不是數字，:279 的 `meatRatio <= 0` 比較與 :287-288 的乘法一樣會炸，
所以判準是「非 number 即不可用」（與已退場的 MDFX_AnimalTrailerSize 同判準）。

【後果】
ISButcherAnimal:complete()（:55）呼叫本函式時拋出 → NetTimedAction.perform 連鎖
NPE（NetTimedAction.java:140）。玩家花完整段屠宰動作（900 − 技能×20 ticks）、
動畫演完、一塊肉都拿不到、屍體留在原地；缺欄位是屍體 modData 的永久狀態，
那隻動物永遠屠宰不了，玩家會反覆嘗試、反覆炸。
註：ISButcherAnimal:isValid() 要求 `modData["parts"] ~= nil`，壞屍體的 parts 是
false（非 nil）所以動作發起得了；更舊的「欄位時代之前」屍體 parts 為 nil，
根本進不到這條路。

【本補丁】
包裝 `ButcheringUtil.butcherAnimalFromGround`：

- 屍體為 nil（ISGetAnimalBones:complete 沒有 ISButcherAnimal:51 那道 body guard，
  MP 物件解析競態下 body 可能為 nil）或 modData 的 meatRatio 不是 number
  → 印一次診斷後直接 return，不呼叫原函式（fail-closed：屍體留著，不炸）。
- 檢查本身拋錯（畸形 carcass）→ 交還 vanilla，讓堆疊指向原始行號，不掩蓋。
- 其餘一律原樣透傳（零行為差異）。

為什麼是「早退」而不是「補預設值」或「複製函式體跳過除錯字串」：
1. 不補值——meatRatio 會進 addAnimalPart 的產出量乘法（ButcheringUtil.lua:287-288），
   任何預設值都是在改產出平衡。
2. 不複製函式體——實戰可達的壞屍體形狀只有「parts=false 的模組動物」，
   官方就算修好 :70，同一屍體也會在 :74 的 partDef 檢查早退（getAnimalDef 查的
   是當初就查不到的同一個 key）。早退與「修好後的 vanilla」行為等價，
   而繼續往下跑反而會踩 :279（nil 比較）、:134（AddItems 的 nil 數量）、
   :156（`2 - nil`）等更多缺欄位地雷；骨架路徑（:92 getAnimalBones →
   :470 addAnimalPart）同樣繞不開 :279。
3. 本函式開頭有 `if isClient() then return end`，本補丁只在 server／單人生效，
   與爆點同端；放 server/ 目錄讓 MP 純客戶端連載入都不載。

【安裝機制】
sentinel 存 wrapper 自身引用（不是 boolean）：Core.ResetLua 重載時 vanilla 重建
整張表、sentinel 隨之消失、本檔重跑重新包裝；後載 MOD 若整支替換了目標函式，
OnGameBoot 復查會發現 sentinel 與現任不符，把「他的版本」當新的 original
再包一層（chain，兩邊都保留）。比本補丁更晚的替換不在保證範圍。

【退場條件】
官方修好 setAnimalBodyData 的 nil 解參考（讓壞屍體不再產生）**且**對 :70 的
除錯字串加防護（讓既有壞屍體不再炸）。只修前者救不了世界上已存在的壞屍體。
遊戲更新後跑 `python scripts/check_vanilla_alignment.py` 確認 vanilla 形狀是否已變。
]]

local warnedBadCorpse = false
local warnedNotInstalled = false

-- 「不可用」= 屍體不存在，或 meatRatio 不是 number（nil／string／boolean 都算，
-- vanilla 的串接、比較、乘法對非 number 一律拋錯）
local function corpseUnusable(carcass)
    if carcass == nil then return true end
    return type(carcass:getModData()["meatRatio"]) ~= "number"
end

local function install()
    if type(ButcheringUtil) ~= "table"
        or type(ButcheringUtil.butcherAnimalFromGround) ~= "function" then
        if not warnedNotInstalled then
            warnedNotInstalled = true
            print("[MinidoracatFixes] MDFX_ButcherMeatRatio NOT installed: vanilla ButcheringUtil shape changed; re-check docs/fixes.md")
        end
        return
    end
    -- 我們的 wrapper 仍在位 → 不重複包裝
    if ButcheringUtil.MDFX_meatRatioGuard == ButcheringUtil.butcherAnimalFromGround then
        return
    end

    local original = ButcheringUtil.butcherAnimalFromGround

    local function wrapper(carcass, player, keepCorpse)
        local ok, unusable = pcall(corpseUnusable, carcass)
        if ok and unusable then
            if not warnedBadCorpse then
                warnedBadCorpse = true
                local animalType = "carcass=nil"
                pcall(function()
                    animalType = tostring(carcass:getModData()["AnimalType"])
                end)
                print("[MinidoracatFixes] butcher aborted: corpse modData lacks usable meatRatio (animal="
                    .. animalType
                    .. "); vanilla ButcheringUtil.lua:70 would throw. Further occurrences suppressed this session. See docs/fixes.md MDFX_ButcherMeatRatio")
            end
            return
        end
        return original(carcass, player, keepCorpse)
    end

    ButcheringUtil.butcherAnimalFromGround = wrapper
    ButcheringUtil.MDFX_meatRatioGuard = wrapper
end

install()
if Events and Events.OnGameBoot then
    Events.OnGameBoot.Add(install)
end
