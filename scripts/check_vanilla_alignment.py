#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""check_vanilla_alignment.py — 遊戲更新後確認各修復仍對齊 vanilla。

每條修復登記三類指紋，逐一比對本機遊戲安裝的 vanilla Lua：

  crash    爆點行還在且形狀未變 → 修復仍有必要；行變了 → 人工重新核對
  depends  wrapper 依賴的 vanilla 符號還在 → 修復仍會安裝；缺了 → 線上會印
           "NOT installed"，需要改寫修復
  formula  fallback 複製的公式係數行（只有 MDFX_ReloadSpeedGuard 有）；
           變了 → fallback 公式要跟著更新
  exithint vanilla 出現自帶防護的跡象 → 提示評估退場（人工確認，不自動判定）
  retired  已退場修復所依據的官方修正還在 → 補丁不介入；消失 → 人工核對
           官方是否撤回修正、補丁要不要復役

爆點在 Java 的修復（MDFX_StaleRoomGuard）用 `class` 條目：以 `javap -c -p`
反組譯本機 projectzomboid.jar 裡的該類別，再對反組譯文字比對同樣四類指紋。
需要 PATH 上有 JDK 25 以上的 javap（PZ 自帶的 jre64 沒有 javap）；找不到算 MISSING。

用法（repo 根目錄）：
    python scripts/check_vanilla_alignment.py [PZ安裝目錄]
預設安裝目錄 D:/SteamLibrary/steamapps/common/ProjectZomboid，
也可用環境變數 PZ_HOME 覆蓋。

exit code：0 = 全部對齊；1 = 有 CHANGED / MISSING（需要人工處理）。
exithint 只提示不影響 exit code。
"""

import os
import re
import shutil
import subprocess
import sys

DEFAULT_PZ_HOME = r"D:/SteamLibrary/steamapps/common/ProjectZomboid"

# 每條修復的指紋。pattern 都是對「整檔內容」的 regex search。
FIXES = [
    {
        "name": "MDFX_ButcherMeatRatio",
        "file": "media/lua/shared/Definitions/animal/ButcheringUtil.lua",
        "crash": [
            # :70 的除錯字串串接，缺欄位時 concat nil
            r'"Meat ratio: "\s*\.\.\s*carcass:getModData\(\)\["meatRatio"\]',
        ],
        "depends": [
            # wrapper 的包裝目標
            r"function\s+ButcheringUtil\.butcherAnimalFromGround\s*\(",
            # 「server／單人才會執行」的前提（本修復放 server/ 的理由）
            r"if\s+isClient\(\)\s+then\s+return;?\s+end",
        ],
        "exithint": [
            # 官方若對 meatRatio 加了 nil 處理，多半會在同一行附近出現這些形狀
            r'getModData\(\)\["meatRatio"\]\s*or\s',
            r'tostring\(carcass:getModData\(\)\["meatRatio"\]\)',
        ],
    },
    {
        "name": "MDFX_ReloadSpeedGuard",
        "file": "media/lua/shared/TimedActions/ISReloadWeaponAction.lua",
        "crash": [
            # :95 對非 HandWeapon 手持物 call nil
            r"elseif\s+gun:getMagazineType\(\)\s+then",
            # 42.22 :90 gate 看穿戴的 RELOAD_FAST_MAGAZINES（肩掛槍套、胸掛、ALICE 腰帶吊帶）：沒穿背帶也會進來
            r"if\s+gun\s+and\s+\(reloadFast\s+or\s+character:hasWornTag\(ItemTag\.RELOAD_FAST_MAGAZINES\)\s+or\s+\(strap\s+and\s+strap:getClothingItem\(\)\)\)\s+then",
            # :100／:102 前面的標籤都不符就對 strap 取值，strap 可能是 nil
            r'or\s+strap:getClothingItemName\(\)\s*==\s*"AmmoStrap_Shells"\)\s+then',
            r'or\s+strap:getClothingItemName\(\)\s*==\s*"AmmoStrap_Bullets"\)\s+then',
        ],
        "depends": [
            r"function\s+ISReloadWeaponAction\.setReloadSpeed\s*\(\s*character\s*,\s*rack\s*\)",
        ],
        "formula": [
            # fallback 複製的係數（:76-83 / :109-112）；變了要同步 fallback。
            # (?!\d) 錨定精確值：0.10 改成 0.12/0.15 之類也必須被抓到
            r"local\s+baseReloadSpeed\s*=\s*0\.8(?!\d)",
            r"Perks\.Reloading\)\s*\*\s*0\.04(?!\d)",
            r"Perks\.Reloading\)\s*\*\s*0\.10(?!\d)",
            r"MoodleType\.PANIC\)\s*\*\s*0\.05(?!\d)",
            r"baseReloadSpeed\s*\*\s*0\.8(?!\d)",
        ],
        "exithint": [
            # 官方若加了「手持物是否槍械」的檢查
            r'instanceof\(gun,\s*"HandWeapon"\)',
            # 官方若在 strap 取值前判 nil
            r"strap\s+and\s+strap:getClothingItemName\(\)",
        ],
    },
    {
        "name": "MDFX_PetAnimalGuard",
        "file": "media/lua/shared/TimedActions/Animals/ISPetAnimal.lua",
        "crash": [
            # animEvent :88（complete :70 同一行形狀）
            r"self\.animal:petAnimal\(self\.character\);",
        ],
        "depends": [
            r"function\s+ISPetAnimal:serverStart\s*\(",
            r"function\s+ISPetAnimal:animEvent\s*\(\s*event\s*,\s*parameter\s*\)",
            r"function\s+ISPetAnimal:complete\s*\(",
        ],
        "exithint": [
            # 官方若比照 ISLoadBulletsInMagazine:70-73 補上 guard
            r"if\s+not\s+self\.animal\s+then",
        ],
    },
    # ── 0.6.0 的六條 server 端 vanilla 守衛 ──────────────────────────────
    {
        # 42.21 已退場：官方把 checkWeapon 搬到 shared 的 ItemUtils，補丁偵測到就不安裝
        "name": "MDFX_WorldObjectCheckWeapon（已退場：ItemUtils）",
        "file": "media/lua/shared/Items/ItemUtils.lua",
        "retired": [
            r"ItemUtils\.checkWeapon = function\(chr\)",
        ],
    },
    {
        "name": "MDFX_WorldObjectCheckWeapon（已退場：呼叫點 ISDestroyStuffAction）",
        "file": "media/lua/shared/TimedActions/ISDestroyStuffAction.lua",
        "retired": [
            r"if sledge and sledge:damageCheck\(0,2,false\) then\s*\n\s*ItemUtils\.checkWeapon\(self\.character\)",
        ],
    },
    {
        "name": "MDFX_WorldObjectCheckWeapon（已退場：呼叫點 ISPickUpGroundCoverItem）",
        "file": "media/lua/shared/TimedActions/ISPickUpGroundCoverItem.lua",
        "retired": [
            r"if self\.weapon and self\.weapon:damageCheck\(0,4,false\) then\s*\n\s*ItemUtils\.checkWeapon\(self\.character\)",
        ],
    },
    {
        "name": "MDFX_WorldObjectCheckWeapon（已退場：呼叫點 ISRemoveBush）",
        "file": "media/lua/shared/TimedActions/ISRemoveBush.lua",
        "retired": [
            r"if self\.weapon and self\.weapon:damageCheck\(0,4,false\) then\s*\n\s*ItemUtils\.checkWeapon\(self\.character\)",
        ],
    },
    {
        "name": "MDFX_MilkAnimalGuard",
        "file": "media/lua/shared/TimedActions/Animals/ISMilkAnimal.lua",
        "crash": [
            # :70 可用容器判準只檢查桶子存不存在，沒檢查還是不是流體容器
            r"if not self\.bucket or self\.bucket:getFluidContainer\(\):isFull\(\)",
            # :41 stress 倒奶，同形狀的第二個爆點（本補丁攔在原函式之前一併蓋掉）
            r"self\.bucket:getFluidContainer\(\):removeFluid\(\);",
        ],
        "depends": [
            r"function\s+ISMilkAnimal:milk\s*\(",
            r"function\s+ISMilkAnimal:stress\s*\(",
            # 補丁走的 vanilla 結束路徑
            r"self\.netAction:forceComplete\(\)",
        ],
        "exithint": [
            # 官方若把判準改成「桶子存在且有流體容器」
            r"if not self\.bucket or not self\.bucket:getFluidContainer\(\)",
        ],
    },
    {
        "name": "MDFX_ConsolidateDrainableGuard",
        "file": "media/lua/shared/TimedActions/ISConsolidateDrainable.lua",
        "crash": [
            # :33 先扣來源、:35 才填目的物 → 目的物缺 setUsedDelta 時形成部分更新
            r"self\.drainable:setUsedDelta\(fromDelta\);",
            r"self\.intoItem:setUsedDelta\(intoDelta\);",
        ],
        "depends": [
            r"function\s+ISConsolidateDrainable:update\s*\(",
            r"function\s+ISConsolidateDrainable:complete\s*\(",
            # :61 是「vanilla 自己就要求 intoItem 是 DrainableComboItem」的依據
            # （canConsolidate 只在 DrainableComboItem.java:516），也是本補丁判準的立論
            r"self\.intoItem:canConsolidate\(\)",
        ],
        "exithint": [
            # 官方若在寫入前自己驗型別
            r'instanceof\(self\.intoItem,\s*"DrainableComboItem"\)',
        ],
    },
    {
        "name": "MDFX_ClothingExtraGuard",
        "file": "media/lua/shared/TimedActions/ISClothingExtraAction.lua",
        "crash": [
            # complete(:125) → createItemNew(:67) 對 nil 衣物解參考
            r"local visual = item:getVisual\(\)",
        ],
        "depends": [
            r"function\s+ISClothingExtraAction:complete\s*\(",
            # isValid 的同款判準，是本補丁抄的 vanilla 先例
            r"if not self\.item or self\.item:isBroken\(\) then return false end",
        ],
        "exithint": [
            # 官方若把 isValid 的 nil guard 也補進 complete 入口
            r"function ISClothingExtraAction:complete\(\)\s*\n\s*if not self\.item",
        ],
    },
    {
        "name": "MDFX_MoveablesActionGuard",
        "file": "media/lua/shared/Moveables/ISMoveablesAction.lua",
        "crash": [
            # :308 place 模式對 item 無條件解參考
            r"local worldSpriteName = item:getWorldSprite\(\);",
        ],
        "depends": [
            # 簽名要一致：wrapper 是按位置逐一轉交八個參數的
            r"function ISMoveablesAction:new\(character, square, mode, origSpriteName, object, direction, item, moveCursor \)",
        ],
        "exithint": [
            # 官方若在 place 分支的 gate 併入 item 檢查
            r'if o\.mode == "place" and item',
        ],
    },
    {
        "name": "MDFX_LockDoorsGuard",
        "file": "media/lua/shared/Vehicles/TimedActions/ISLockDoors.lua",
        "crash": [
            # :46 對 VehiclePart 做 ..（隔壁 :42 有 tostring，這行漏了）
            r"print\('part ' \.\. part \.\. ' has no door'\)",
        ],
        "depends": [
            r"function\s+ISLockDoors:complete\s*\(",
            # 預掃複製的就是這道判準（complete 迴圈裡唯一一處）
            r"if not part:getDoor\(\) then",
        ],
        "exithint": [
            # 官方若照 :42 的寫法補上 tostring
            r"'part ' \.\. tostring\(part\)",
        ],
    },
    {
        "name": "MDFX_GiveWaterAnimalGuard",
        "file": "media/lua/shared/TimedActions/Animals/ISGiveWaterToAnimal.lua",
        "crash": [
            # :102-105 server 時長 -1：new() 不碰動物與水容器，nil 也建得起動作，只剩 30 分鐘上限
            r"function ISGiveWaterToAnimal:getDuration\(\)\s*if isServer\(\) then\s*return -1",
            # :97-100 每 400 ms 模擬一次 update 事件
            r'emulateAnimEvent\(self\.netAction, period, "update", nil\)',
            # :82-85 update 分支第一行就對動物取值（update() :33 有同一行，所以連函式頭一起比）
            r'function ISGiveWaterToAnimal:animEvent\(event, parameter\)\s*if isServer\(\) then\s*'
            r'if event == "update" then\s*self\.animal:getStats\(\):remove\(CharacterStat\.THIRST',
            # :85-87 先扣口渴、再對水容器取值（:87 sendSyncEntity 只在 animEvent，update() :33-34 不會誤中）
            r"self\.animal:getStats\(\):remove\(CharacterStat\.THIRST, 0\.05 \* self\.animal:getThirstBoost\(\)\);\s*"
            r"self\.item:getFluidContainer\(\):removeFluid\(0\.05, false\);\s*self\.item:sendSyncEntity\(nil\)",
            # :76-78 complete 同樣無條件取值
            r'"id", self\.animal:getOnlineID\(\),',
        ],
        "depends": [
            r"function\s+ISGiveWaterToAnimal:animEvent\s*\(",
            r"function\s+ISGiveWaterToAnimal:complete\s*\(",
            # 補丁走的 vanilla 結束路徑（:91）
            r"self\.netAction:forceComplete\(\);",
        ],
        "exithint": [
            # 官方若補上動物或水容器的 nil 檢查
            r"if\s+not\s+self\.animal\s+then",
            r"if\s+not\s+self\.item\s+then",
        ],
    },
    # ── MDFX_AnimalCompleteGuard：四個動作在 server 只有 complete 碰動物 ──────────────
    {
        "name": "MDFX_AnimalCompleteGuard（牽繩）",
        "file": "media/lua/shared/TimedActions/Animals/ISAttachAnimalToPlayer.lua",
        "crash": [
            # complete :42（牽上）／:50（解開）對動物取值
            r"function ISAttachAnimalToPlayer:complete\(\)\s*if not self\.remove then\s*if self\.animal:getData\(\):getAttachedTree\(\) then",
            r"self\.character:getAttachedAnimals\(\):remove\(self\.animal\);\s*self\.animal:getData\(\):setAttachedPlayer\(nil\);",
            # 前提：server 端沒有 serverStart／animEvent 先碰動物
            r"\A(?![\s\S]*function ISAttachAnimalToPlayer:(?:serverStart|animEvent)\b)",
        ],
        "depends": [r"function\s+ISAttachAnimalToPlayer:complete\s*\("],
        "exithint": [r"if\s+not\s+self\.animal\s+then"],
    },
    {
        "name": "MDFX_AnimalCompleteGuard（拴樹）",
        "file": "media/lua/shared/TimedActions/Animals/ISAttachAnimalToTree.lua",
        "crash": [
            # complete :42（解開）／:47（拴上）對動物取值
            r"function ISAttachAnimalToTree:complete\(\)\s*if self\.remove then\s*self\.animal:getData\(\):setAttachedTree\(nil\);",
            r"self\.animal:getData\(\):setAttachedTree\(self\.tree\);",
            r"\A(?![\s\S]*function ISAttachAnimalToTree:(?:serverStart|animEvent)\b)",
        ],
        "depends": [r"function\s+ISAttachAnimalToTree:complete\s*\("],
        "exithint": [r"if\s+not\s+self\.animal\s+then"],
    },
    {
        "name": "MDFX_AnimalCompleteGuard（裝拖車）",
        "file": "media/lua/shared/TimedActions/Animals/ISAddAnimalInTrailer.lua",
        "crash": [
            # complete :76（從地上）對動物取值；:66（從手上）把動物交給 Java 的 addAnimalFromHandsInTrailer
            r'self\.vehicle:getAreaDist\("AnimalEntry", self\.animal:getSquare\(\):getX\(\)',
            r"self\.vehicle:addAnimalFromHandsInTrailer\(self\.animal, self\.character\)",
            r"\A(?![\s\S]*function ISAddAnimalInTrailer:(?:serverStart|animEvent)\b)",
        ],
        "depends": [r"function\s+ISAddAnimalInTrailer:complete\s*\("],
        "exithint": [r"function ISAddAnimalInTrailer:complete\(\)\s*if\s+not\s+self\.animal"],
    },
    {
        "name": "MDFX_AnimalCompleteGuard（手餵）",
        "file": "media/lua/shared/TimedActions/Animals/ISFeedAnimalFromHand.lua",
        "crash": [
            # complete :46 第一行就對動物取值
            r"function ISFeedAnimalFromHand:complete\(\)\s*self\.animal:getBehavior\(\):setBlockMovement\(false\);",
            r"\A(?![\s\S]*function ISFeedAnimalFromHand:(?:serverStart|animEvent)\b)",
        ],
        "depends": [r"function\s+ISFeedAnimalFromHand:complete\s*\("],
        "exithint": [r"if\s+not\s+self\.animal\s+then"],
    },
    # ── 農作物同步「有變才送」：crash 在這裡指「原版無條件重送的形狀」──────────
    {
        "name": "MDFX_FarmingSyncDedupe",
        "file": "media/lua/server/Farming/SPlantGlobalObject.lua",
        "crash": [
            # :43-56 / :58-87：本體裡 isServer() 只出現在結尾那三包、之後直接結束。
            # 補丁用 setfenv 讓本體的 isServer() 回 false 來擋三包——本體若多了別的
            # isServer() 用途或在三包之後加了程式，就會被一起擋掉／漏補，必須人工重核。
            r"(?s)function SPlantGlobalObject:stateFromIsoObject\(isoObject\)(?:(?!isServer\(|\nfunction ).)*?"
            r"if isServer\(\) then\s*isoObject:sendObjectChange\(IsoObjectChange\.NAME\)\s*"
            r"isoObject:sendObjectChange\(IsoObjectChange\.SPRITE\)\s*isoObject:transmitModData\(\)\s*end\s*end",
            r"(?s)function SPlantGlobalObject:stateToIsoObject\(isoObject\)(?:(?!isServer\(|\nfunction ).)*?"
            r"if isServer\(\) then\s*isoObject:sendObjectChange\(IsoObjectChange\.NAME\)\s*"
            r"isoObject:sendObjectChange\(IsoObjectChange\.SPRITE\)\s*isoObject:transmitModData\(\)\s*end\s*end",
            # :771-777 整個本體：補丁「不送」那條路只做 getIsoObject＋toModData，
            # 本體多了別的事就要跟著改
            r"function SPlantGlobalObject:saveData\(\)\s*local isoObject = self:getIsoObject\(\)\s*"
            r"if isoObject then\s*self:toModData\(isoObject:getModData\(\)\)\s*isoObject:transmitModData\(\)\s*end\s*end",
        ],
    },
    {
        "name": "MDFX_FarmingSyncDedupe（載入觸發 MOFarming）",
        "file": "media/lua/server/Map/MapObjects/MOFarming.lua",
        "crash": [
            # :126-137：枯作物與各作物 sprite 在每次 cell 載入時走 loadIsoObject
            r'MapObjects\.OnLoadWithSprite\("vegetation_farming_01_13", LoadDestroyed, PRIORITY\)',
            r"MapObjects\.OnLoadWithSprite\(farming_vegetableconf\.sprite\[typeOfSeed\], LoadPlant, PRIORITY\)",
        ],
    },
    {
        "name": "MDFX_FarmingSyncDedupe（定期觸發 SFarmingSystem）",
        "file": "media/lua/server/Farming/SFarmingSystem.lua",
        "crash": [
            # :127 EveryTenMinutes 每次都 checkPlant；:288-289 checkPlant2 最後無條件 saveData
            r"self:checkPlant\(\)\s*end",
            r"if sprite then luaObject:setSpriteName\(sprite\) end\s*luaObject:saveData\(\)",
        ],
    },
    # ── 農作物存檔三件：時鐘備份（C）、時鐘錯位自癒（A）、GOS 瘦身（B）──────────
    {
        "name": "MDFX_FarmingClockBackup",
        "file": "media/lua/server/Farming/SFarmingSystem.lua",
        "crash": [
            # :11 讀不到 gos_farming.bin 時時鐘歸零
            r"o\.hoursElapsed = o\.hoursElapsed or 0",
        ],
        "depends": [
            # :27 時鐘只存在 GOS；:93 每遊戲小時 +1（備份排在這之後）；:586 原版 handler 在檔案載入時註冊
            r"self\.system:setModDataKeys\(\{'hoursElapsed'\}\)",
            r"self\.hoursElapsed = self\.hoursElapsed \+ 1",
            r"Events\.EveryTenMinutes\.Add\(EveryTenMinutes\)",
            r"self\.system:loadedWorldVersion\(\)",
        ],
    },
    {
        "name": "MDFX_FarmingClockBackup（系統建立時機）",
        "file": "media/lua/server/Map/SGlobalObjectSystem.lua",
        "depends": [
            # instance 在 OnSGlobalObjectSystemInit 建立；本補丁的 handler 註冊在它之後
            r"local function OnSGlobalObjectSystemInit\(luaClass\)\s*luaClass\.instance = luaClass:new\(\)",
            r"Events\.OnSGlobalObjectSystemInit\.Add\(function\(\) OnSGlobalObjectSystemInit\(luaClass\) end\)",
        ],
    },
    {
        "name": "MDFX_FarmingStallHeal",
        "file": "media/lua/server/Farming/SPlantGlobalObject.lua",
        "crash": [
            # :43-56 stateFromIsoObject 沒有時鐘補救（本體不出現 lastWaterHour）
            r"(?s)function SPlantGlobalObject:stateFromIsoObject\(isoObject\)(?:(?!lastWaterHour|\nfunction ).)*?\nend",
        ],
        "formula": [
            # :66-74 補救的觸發與重設方式，本補丁照抄
            r"if self\.lastWaterHour and self\.lastWaterHour > SFarmingSystem\.instance\.hoursElapsed then",
            r'getCore\(\):getDebug\(\) and getDebugOptions\(\):getBoolean\("Cheat\.Farming\.FastGrow"\) then\s*'
            r"self\.nextGrowing = SFarmingSystem\.instance\.hoursElapsed \+ 1\s*else\s*"
            r"self\.nextGrowing = SFarmingSystem\.instance\.hoursElapsed \+ farming_vegetableconf\.props\[self\.typeOfSeed\]\.timeToGrow",
            r"self\.lastWaterHour = SFarmingSystem\.instance\.hoursElapsed\s*self:noise\('reset lastWaterHour/nextGrowing",
        ],
    },
    {
        "name": "MDFX_FarmingStallHeal（生長判斷與下雨）",
        "file": "media/lua/server/Farming/SFarmingSystem.lua",
        "crash": [
            # :278 時鐘錯位的作物永遠過不了這行；:309 下雨把 lastWaterHour 改成新時鐘、讓原版補救失效
            r"if luaObject\.nextGrowing and self\.hoursElapsed >= luaObject\.nextGrowing then",
            r"luaObject\.lastWaterHour = self\.hoursElapsed",
        ],
        "depends": [
            r"function SFarmingSystem:checkPlant2\(luaObject\)",
        ],
    },
    {
        "name": "MDFX_FarmingStallHeal（LIMIT 的公式來源）",
        "file": "media/lua/server/Farming/farming_vegetableconf.lua",
        "formula": [
            # :79 offset ±12；:86、:108 倍率 1/FarmingSpeedNew（最小 0.1 在 SandboxOptions.java:232，本腳本查不到 Java）
            r"return ZombRand\(25\)-12",
            r"nextTime = nextTime \* calcNextTimeFactor\(\)",
            r"nextTime = nextTime / sandboxTime",
            # :284-285 rotTime；:297 timeToGrow + 三個修正項；:356、:360 badPlant
            r"local rotTime = prop\.rotTime or math\.floor\(prop\.timeToGrow/2\)",
            r"calcNextGrowing\(nextGrowing, prop\.timeToGrow \+ water \+ waterMax \+ diseaseLvl\)",
            r"calcNextGrowing\(nextGrowing, 30\)",
            r"calcNextGrowing\(nextGrowing, 50\)",
            # 三個修正項合計 < 50：calcWater 的「差 10% 以內」分支、calcDisease 的 < 30 分支
            r"elseif waterLvl >= math\.floor\(waterMin /  1\.10\) then\s*return waterMin - waterLvl;",
            r"elseif diseaseLvl < 30 then\s*return diseaseLvl;",
        ],
        "depends": [
            # 遠期判斷只在這五個排程函式都出自本檔時啟用（getFilenameOfClosure 比對來源）
            r"function calcNextGrowing\(nextGrowing, nextTime\)",
            r"function calcNextTimeFactor\(\)",
            r"function randomGrowthOffset\(\)",
            r"function badPlant\(water, waterMax, diseaseLvl, plant, nextGrowing, updateNbOfGrow\)",
            r"farming_vegetableconf\.grow = function\(planting, nextGrowing, updateNbOfGrow\)",
        ],
    },
    {
        "name": "MDFX_FarmingGosPrune（重新登記缺口）",
        "file": "media/lua/server/Map/MapObjects/MOFarming.lua",
        "crash": [
            # 原版沒替 trampledSprite 註冊 OnLoad → 失去登記的踩爛／已收成作物回不來
            r"\A(?![\s\S]*trampledSprite)",
        ],
        "depends": [
            # 本補丁 priority 6 要高於原版的 5，dead／rotten 才會先重建、再由原版 LoadPlant 同步
            r"local PRIORITY = 5",
            r"MapObjects\.OnLoadWithSprite\(farming_vegetableconf\.deadSprite\[typeOfSeed\], LoadPlant, PRIORITY\)",
        ],
    },
    {
        "name": "MDFX_FarmingGosPrune（移出期間原版不做的事）",
        "file": "media/lua/server/Farming/SFarmingSystem.lua",
        "crash": [
            # :265 destroyed／harvested 直接 return；:267-270 dead／rotten 只有 1/5000 變 destroyed；
            # :256 plowFadeCheck 沒載入就 return；:133、:147 水量／健康只處理活的
            r'if \(not luaObject\) or \(luaObject\.state == "destroyed"\) or \(luaObject\.state == "harvested"\) then return end',
            r"if \(not\s+luaObject:isAlive\(\)\) and ZombRand\(5000\) == 0 then\s*luaObject:destroyThis\(\)\s*return\s*end",
            r"(?s)function SFarmingSystem:plowFadeCheck\(luaObject\)(?:(?!\nfunction ).)*?local square = luaObject:getSquare\(\)\s*if not square then return end",
            r"function SFarmingSystem:lowerWaterLvlAndUpDisease\(\)\s*for i=1,self:getLuaObjectCount\(\) do\s*local luaObject = self:getLuaObjectByIndex\(i\)\s*if luaObject:isAlive\(\) then",
            r'if luaObject:isAlive\(\) and luaObject\.state ~= "plow" then',
            # :400-404 伴生作物擋病蟲害只看鄰格 nbOfGrow >= 3 與 *Bane、不看 state → 這類不移出
            r"if luaObject2\.nbOfGrow >= 3 then\s*local prop2 = farming_vegetableconf\.props\[luaObject2\.typeOfSeed\]\s*"
            r"if prop2\.aphidsBane then aphidsBane = true end\s*if prop2\.fliesBane then fliesBane = true end\s*"
            r"if prop2\.slugsBane then slugsBane = true end",
        ],
        "formula": [
            # 比對用的 26 個鍵（SFarmingSystem.lua:30-34），本補丁的 KEYS 照抄
            r"self\.system:setObjectModDataKeys\(\{\s*'state', 'nbOfGrow', 'typeOfSeed', 'fertilizer', 'mildewLvl',\s*"
            r"'aphidLvl', 'fliesLvl', 'slugsLvl', 'hasWeeds',  'waterLvl', 'waterNeeded', 'waterNeededMax',\s*"
            r"'lastWaterHour', 'nextGrowing', 'hasSeed', 'hasVegetable',\s*"
            r"'health', 'badCare', 'exterior', 'spriteName', 'objectName', 'cursed', 'compost', 'bonusYield', 'naturalLight',\s*"
            r"'owner'\}\)",
        ],
    },
    {
        "name": "MDFX_FarmingGosPrune（作物物件）",
        "file": "media/lua/server/Farming/SPlantGlobalObject.lua",
        "crash": [
            # :47 stateFromIsoObject 用 IsoObject 的 spriteName 欄位（setSpriteFromName 不更新它）→ 本補丁不走它
            r"self\.spriteName = isoObject:getSpriteName\(\)",
        ],
        "depends": [
            r'return self\.state ~= "destroyed" and self\.state ~= "dead" and self\.state ~= "rotten" and self\.state ~= "harvested"',
            r"function SPlantGlobalObject:initNew\(\)",
            r"function SPlantGlobalObject:fromModData\(modData\)",
        ],
    },
    {
        "name": "MDFX_FarmingGosPrune（sprite 分組）",
        "file": "media/lua/server/Farming/farming_vegetableconf.lua",
        "depends": [
            r'if plant\.state == "destroyed" or plant\.state == "harvested" then\s*spriteType = "trampledSprite"',
            r'elseif plant\.state == "dead" or plant\.state == "rotten" then\s*spriteType = "deadSprite"',
        ],
    },
    {
        "name": "MDFX_FarmingGosPrune（GOS 基底）",
        "file": "media/lua/server/Map/SGlobalObjectSystem.lua",
        "depends": [
            # :95-102 移除會通知客戶端；:143-147 重新登記的建立順序，本補丁照抄
            r"self:removeLuaObjectOnClient\(luaObject\)\s*self\.system:removeObject\(luaObject\.globalObject\)",
            r"local globalObject = self\.system:newObject\(square:getX\(\), square:getY\(\), square:getZ\(\)\)\s*"
            r"local luaObject = self:newLuaObject\(globalObject\)\s*luaObject:stateFromIsoObject\(isoObject\)",
            r"function SGlobalObjectSystem:getIsoObjectOnSquare\(square\)",
        ],
    },
    {
        "name": "農作物存檔三件（Java：GOS 存檔緩衝區只有 10 MiB）",
        "class": "zombie.iso.SliceY",
        "crash": [
            # SliceY.java:10：所有 GOS 系統共用的存檔緩衝區固定 10,485,760 byte，農作物系統寫超過就丟 BufferOverflowException。
            # 轉紅＝官方加大或改寫緩衝區，回頭評估 GosPrune／ClockBackup／StallHeal 退場
            r"static \{\};\s+Code:\s+\d+: ldc\s+#\d+\s+// int 10485760\s+\d+: invokestatic\s+#\d+\s+"
            r"// Method java/nio/ByteBuffer\.allocate:\(I\)Ljava/nio/ByteBuffer;\s+\d+: putstatic\s+#\d+\s+// Field SliceBuffer:Ljava/nio/ByteBuffer;",
        ],
    },
    {
        "name": "農作物存檔三件（Java：先截斷檔案才寫緩衝區）",
        "class": "zombie.globalObjects.SGlobalObjectSystem",
        "crash": [
            # save()（42.22.2 SGlobalObjectSystem.java:273-298）：先 new FileOutputStream（gos_*.bin 截成 0 byte）才 save(ByteBuffer)，
            # 溢出的例外被吞，檔案留在 0 byte。轉紅＝官方改成先寫暫存檔或先寫緩衝區，回頭評估退場
            r"public void save\(\);(?:(?!\n  \S)[\s\S])*?// Method java/io/FileOutputStream\.\"<init>\":\(Ljava/io/File;\)V"
            r"(?:(?!\n  \S)[\s\S])*?// Method save:\(Ljava/nio/ByteBuffer;\)V",
        ],
    },
    {
        "name": "MDFX_ModOptionsPersist（存讀）",
        "file": "media/lua/client/PZAPI/ModOptions.lua",
        "crash": [
            # :286-288 OtherOptions 寫回不加換行 → 黏成一行
            r"for i, line in ipairs\(PZAPI\.ModOptions\.OtherOptions\) do\s*fileOutput:write\(line\)\s*end",
            # :304-305 黏行只看第一筆的 modid／optid；:330 對不上的行原樣收進 OtherOptions
            r'local t = luautils\.split\(line, "\|"\)\s*'
            r"if PZAPI\.ModOptions\.Dict\[t\[2\]\] ~= nil and PZAPI\.ModOptions\.Dict\[t\[2\]\]\.dict\[t\[3\]\] ~= nil then",
            r"table\.insert\(PZAPI\.ModOptions\.OtherOptions, line\)",
        ],
        "depends": [
            r"function PZAPI\.ModOptions:save\(\)",
            r"function PZAPI\.ModOptions:load\(\)",
            # load 第一行換新表＝本補丁判斷「還沒 load 過」的依據；檔名與開檔方式
            r"function PZAPI\.ModOptions:load\(\)\s*local stringtoboolean = \{[^}]*\}\s*PZAPI\.ModOptions\.OtherOptions = \{\}",
            r'getFileReader\("ModOptions\.ini", true\)',
            r'getFileWriter\("ModOptions\.ini", true, false\)',
            # :320 舊 combobox 行寫進同 id 選項的 .selected（MiniMap 遷移訊號，兩次 load 都要照舊）
            r"PZAPI\.ModOptions\.Dict\[t\[2\]\]\.dict\[t\[3\]\]\.selected = tonumber\(t\[4\]\)",
        ],
        "formula": [
            # 黏行切分用的七種型別與值的寫法（:264-281）；多了型別或改了格式，切分規則要跟著改
            r'local data = option\.type \.\. "\|" \.\. options\.modOptionsID \.\. "\|" \.\. option\.id \.\. "\|"',
            r'if option\.type == "textentry" or option\.type == "tickbox" or option\.type == "slider" then',
            r'elseif option\.type == "multipletickbox" then\s*for _, v in ipairs\(option\.values\) do\s*'
            r'data = data \.\. tostring\(v\.value\) \.\. " "',
            r'elseif option\.type == "combobox" then',
            r'elseif option\.type == "colorpicker" then\s*data = data \.\. tostring\(option\.color\.r\) \.\. " " \.\. '
            r'tostring\(option\.color\.g\) \.\. " " \.\. tostring\(option\.color\.b\) \.\. " " \.\. tostring\(option\.color\.a\)',
            r'elseif option\.type == "keybind" then',
        ],
        "exithint": [
            # 官方若在寫回 OtherOptions 時補換行
            r'fileOutput:write\(line \.\. "\\r\\n"\)',
        ],
    },
    {
        "name": "MDFX_ModOptionsPersist（主選單清空）",
        "file": "media/lua/client/OptionScreens/MainOptions.lua",
        "crash": [
            # :409-411 沒有 MOD 選項就不 load；:3766 apply 無條件 save
            r"if #PZAPI\.ModOptions\.Data ~= 0 then\s*self:addModOptionsPanel\(\)\s*end",
            r"getCore\(\):saveOptions\(\)\s*PZAPI\.ModOptions:save\(\)",
        ],
        "depends": [
            # load 只在 MOD 頁建立時呼叫（:2796）
            r"function MainOptions:addModOptionsPanel\(\)\s*PZAPI\.ModOptions:load\(\)",
        ],
    },
    {
        "name": "MDFX_ModOptionsPersist（安裝時機：MainOptions 只在事件裡建立）",
        "file": "media/lua/client/OptionScreens/MainScreen.lua",
        "depends": [
            r"self\.mainOptions:create\(\);",
            r"Events\.OnMainMenuEnter\.Add\(LoadMainScreenPanel\);",
            r"Events\.OnGameStart\.Add\(LoadMainScreenPanelIngame\);",
        ],
    },
    {
        "name": "MDFX_StaleRoomGuard（爆點：ParameterFirearmRoomSize）",
        "class": "zombie.audio.parameters.ParameterFirearmRoomSize",
        "crash": [
            # getRoomSize（ParameterFirearmRoomSize.java:38-39）：getRoomDef() 的回傳值直接 getArea()，中間沒有 null 檢查
            r"// Method zombie/iso/areas/IsoRoom\.getRoomDef:\(\)Lzombie/iso/RoomDef;\s+\d+: invokevirtual #\d+\s+"
            r"// Method zombie/iso/RoomDef\.getArea:\(\)I",
        ],
        "exithint": [
            # 官方若先檢查 getRoomDef() 的回傳值，兩個呼叫之間會多出 dup／astore／ifnull 之類的指令
            r"// Method zombie/iso/areas/IsoRoom\.getRoomDef:\(\)Lzombie/iso/RoomDef;\s+\d+: (?:dup|astore|ifnull|ifnonnull)",
        ],
    },
    {
        # 42.21 官方已修成因；補丁（沒有失效格子時不做事）留著當 regression 保險
        "name": "MDFX_StaleRoomGuard（成因已由官方修正：WorldRegionToMetaGrid）",
        "class": "zombie.iso.areas.isoregion.metagrid.WorldRegionToMetaGrid",
        "retired": [
            # removeUserDefinedBuildingsFromCell：移除自建建築前先把它覆蓋的所有 chunk 標成 dirty
            r"private int removeUserDefinedBuildingsFromCell\(int, int\);(?:(?!\n  \S)[\s\S])*?"
            r"// Method markBuildingChunksDirty:\(Lzombie/iso/BuildingDef;\)V",
            # updateSquares 重設 dirty chunk 的每一格（官方修正靠它生效）
            r"private void updateSquares\(\);(?:(?!\n  \S)[\s\S])*?// Method chunkIsDirty:\(Lzombie/iso/IsoChunk;\)Z",
        ],
    },
    {
        "name": "MDFX_StaleRoomGuard（前提：房間只在區域資料交換後重建）",
        "class": "zombie.iso.areas.isoregion.IsoRegions",
        "depends": [
            # update（IsoRegions.java:206-214）：先交換 DataRoot，再 clientProcessBuildings——本補丁靠交換偵測重建
            r"public static void update\(\);(?:(?!\n  \S)[\s\S])*?IsoRegionWorker\.getRootBuffer:(?:(?!\n  \S)[\s\S])*?"
            r"IsoRegionWorker\.setRootBuffer:(?:(?!\n  \S)[\s\S])*?DataRoot\.clientProcessBuildings:\(\)V",
            r"public static zombie\.iso\.areas\.isoregion\.data\.DataChunk getDataChunk\(int, int\);",
        ],
    },
    {
        "name": "MDFX_StaleRoomGuard（前提：玩家更新在房間重建之前）",
        "class": "zombie.iso.IsoWorld",
        "depends": [
            # updateWorld（IsoWorld.java:2935-2937）：IsoCell.update（爆點）→ IsoRegions.update（重建），OnTick 在這之後
            r"private void updateWorld\(\);\s+Code:\s+\d+: aload_0\s+\d+: getfield\s+#\d+\s+// Field currentCell:Lzombie/iso/IsoCell;\s+"
            r"\d+: invokevirtual #\d+\s+// Method zombie/iso/IsoCell\.update:\(\)V\s+"
            r"\d+: invokestatic\s+#\d+\s+// Method zombie/iso/areas/isoregion/IsoRegions\.update:\(\)V",
        ],
    },
    {
        "name": "MDFX_StaleRoomGuard（依賴：IsoGridSquare）",
        "class": "zombie.iso.IsoGridSquare",
        "depends": [
            r"public zombie\.iso\.areas\.IsoRoom getRoom\(\);",
            r"public void setRoomID\(long\);",
            r"public void RecalcProperties\(\);",
        ],
    },
    {
        "name": "MDFX_StaleRoomGuard（依賴：IsoRoom）",
        "class": "zombie.iso.areas.IsoRoom",
        "depends": [
            r"public zombie\.iso\.RoomDef getRoomDef\(\);",
        ],
    },
    {
        "name": "MDFX_StaleRoomGuard（依賴：IsoMetaGrid）",
        "class": "zombie.iso.IsoMetaGrid",
        "depends": [
            r"public zombie\.iso\.RoomDef getRoomAt\(int, int, int\);",
        ],
    },
    {
        "name": "MDFX_HutchNullSlotGuard（爆點：IsoHutch.removeFromWorld；42.22 官方已判 null）",
        "class": "zombie.iso.objects.IsoHutch",
        "retired": [
            # 42.22.2 removeFromWorld（IsoHutch.java:1016-1025）：values() 的每個值先判 null 才 removeFromUpdateLists。
            # 42.21.0（:983-990）沒有這個判斷，客戶端卸載雞舍時 NPE 斷線。轉紅＝官方撤回，崩潰保護又要靠補丁
            r"public void removeFromWorld\(\);(?:(?!\n  \S)[\s\S])*?// class zombie/characters/animals/IsoAnimal\s+"
            r"\d+: astore_2\s+\d+: aload_2\s+\d+: (?:ifnull|ifnonnull)",
        ],
        "depends": [
            # 清 null 的唯一路徑：removeAnimal 以動物的 hutchPosition（int）自動裝箱 remove（IsoHutch.java:538-544）
            r"public void removeAnimal\(zombie\.characters\.animals\.IsoAnimal\);(?:(?!\n  \S)[\s\S])*?"
            r"AnimalData\.getHutchPosition:\(\)I\s+\d+: invokestatic\s+#\d+\s+// Method java/lang/Integer\.valueOf:\(I\)Ljava/lang/Integer;\s+"
            r"\d+: invokevirtual #\d+\s+// Method java/util/HashMap\.remove:",
            # removeAnimal 尾端的 sendAnimalUpdate 只在伺服器送封包（:685-686），客戶端呼叫不會送出任何東西
            r"private void sendAnimalUpdate\(zombie\.characters\.animals\.IsoAnimal\);\s+Code:\s+\d+: getstatic\s+#\d+\s+"
            r"// Field zombie/network/GameServer\.server:Z\s+\d+: ifeq",
            r"public java\.util\.HashMap<java\.lang\.Integer, zombie\.characters\.animals\.IsoAnimal> getAnimalInside\(\);",
            r"public zombie\.characters\.animals\.IsoAnimal getAnimal\(java\.lang\.Integer\);",
            r"public zombie\.iso\.objects\.IsoDeadBody getDeadBody\(java\.lang\.Integer\);",
            r"public boolean isSlave\(\);",
        ],
    },
    {
        "name": "MDFX_HutchNullSlotGuard（成因：客戶端同步寫入 null）",
        "class": "zombie.characters.NetworkPlayerAI",
        "crash": [
            # parse(AnimalPacket)（NetworkPlayerAI.java:370-372）：對動物目前的格 put(格, null)
            r"public void parse\(zombie\.network\.packets\.character\.AnimalPacket\);(?:(?!\n  \S)[\s\S])*?"
            r"aconst_null\s+\d+: invokevirtual #\d+\s+// Method java/util/HashMap\.put:",
        ],
    },
    {
        "name": "MDFX_HutchNullSlotGuard（成因：requested 回應先放 null）",
        "class": "zombie.network.packets.character.AnimalUpdatePacket",
        "crash": [
            # parse（AnimalUpdatePacket.java:192-195）：put(格, null) 後 addAnimalInside(animal, false) 的回傳被丟掉
            r"public void parse\(zombie\.core\.network\.ByteBufferReader, zombie\.network\.IConnection\);(?:(?!\n  \S)[\s\S])*?"
            r"aconst_null\s+\d+: invokevirtual #\d+\s+// Method java/util/HashMap\.put:[^\n]*\n\s+\d+: pop\s+"
            r"\d+: aload\s+\d+\s+\d+: aload\s+\d+\s+\d+: iconst_0\s+\d+: invokevirtual #\d+\s+"
            r"// Method zombie/iso/objects/IsoHutch\.addAnimalInside:\(Lzombie/characters/animals/IsoAnimal;Z\)Z\s+\d+: pop",
        ],
    },
    {
        "name": "MDFX_HutchNullSlotGuard（依賴：雞舍登記）",
        "class": "zombie.Lua.MapObjects",
        "depends": [
            # 依圖塊名分派的載入回呼（MapObjects.java:163-182）
            r"public static void OnLoadWithSprite\(se\.krka\.kahlua\.vm\.KahluaTable, se\.krka\.kahlua\.vm\.LuaClosure, int\);",
        ],
    },
    {
        "name": "MDFX_HutchNullSlotGuard（依賴：客戶端載入 chunk 時分派 MapObjects）",
        "class": "zombie.iso.IsoChunk",
        "depends": [
            r"// Method zombie/Lua/MapObjects\.loadGridSquare:\(Lzombie/iso/IsoGridSquare;\)V",
        ],
    },
    {
        "name": "MDFX_HutchNullSlotGuard（依賴：建造中新增的雞舍觸發 OnObjectAdded）",
        "class": "zombie.network.packets.AddItemToMapPacket",
        "depends": [
            r"public void processClient\(zombie\.core\.raknet\.UdpConnection\);(?:(?!\n  \S)[\s\S])*?// String OnObjectAdded",
        ],
    },
    {
        "name": "MDFX_HutchNullSlotGuard（依賴：封包解析到的雞舍＝格上第一個 IsoHutch）",
        "class": "zombie.iso.IsoGridSquare",
        "depends": [
            r"public zombie\.iso\.objects\.IsoHutch getHutch\(\);",
        ],
    },
    {
        "name": "MDFX_HutchNullSlotGuard（依賴：雞舍圖塊定義）",
        "file": "media/lua/shared/Definitions/animal/HutchDefinitions.lua",
        "depends": [
            r'HutchDefinitions\.hutchs\["hutchhen"\]\.baseSprite\s*=\s*"[^"]+"',
            r'table\.insert\(HutchDefinitions\.hutchs\["hutchhen"\]\.extraSprites,\s*\{[^}]*sprite\s*=',
        ],
    },
    {
        "name": "MDFX_GosDuplicateNewGuard（爆點：CGlobalObjectSystem:newLuaObjectAt）",
        "file": "media/lua/client/Map/CGlobalObjectSystem.lua",
        "crash": [
            # :69-72 不看同座標是否已有物件就 newObject（Java 拋 already an object at，Kahlua 回 nil 繼續跑）
            r"function CGlobalObjectSystem:newLuaObjectAt\(x, y, z\)\s*local globalObject = self\.system:newObject\(x, y, z\)"
            r"\s*return self:newLuaObject\(globalObject\)\s*end",
        ],
        "depends": [
            r'CGlobalObjectSystem = ISBaseObject:derive\("CGlobalObjectSystem"\)',
            # wrapper 以 self.system:getObjectAt 查既有物件、診斷帶 self.systemName（CGlobalObjectSystem:new 設定）
            r"o\.system = system",
            r"o\.systemName = name",
        ],
        "exithint": [
            # 官方若讓 newLuaObjectAt 先查同座標，函式本體會出現 getObjectAt
            r"function CGlobalObjectSystem:newLuaObjectAt\(x, y, z\)(?:(?!\nend)[\s\S])*?getObjectAt",
        ],
    },
    {
        "name": "MDFX_GosDuplicateNewGuard（第二條錯誤：CGlobalObject.new 對 nil 取 getModData）",
        "file": "media/lua/client/Map/CGlobalObject.lua",
        "crash": [
            r"function CGlobalObject:new\(luaSystem, globalObject\)(?:(?!\nend)[\s\S])*?local o = globalObject:getModData\(\)",
        ],
    },
    {
        "name": "MDFX_GosDuplicateNewGuard（依賴：農作物系統走基底的 newLuaObjectAt）",
        "file": "media/lua/client/Farming/CFarmingSystem.lua",
        "depends": [
            # 整檔沒有 newLuaObjectAt＝走 CGlobalObjectSystem 的版本，本修復包得到（正式服的重複新增都是農作物）
            r"\A(?![\s\S]*newLuaObjectAt)",
            r'CFarmingSystem = CGlobalObjectSystem:derive\("CFarmingSystem"\)',
        ],
    },
    {
        "name": "MDFX_GosDuplicateNewGuard（Java：newObject 同座標已有物件就拋錯）",
        "class": "zombie.globalObjects.GlobalObjectSystem",
        "crash": [
            # GlobalObjectSystem.java:36-45
            r"public final zombie\.globalObjects\.GlobalObject newObject\(int, int, int\);(?:(?!\n  \S)[\s\S])*?"
            r"// Method getObjectAt:\(III\)Lzombie/globalObjects/GlobalObject;\s+\d+: ifnull\s+\d+\s+"
            r"\d+: new\s+#\d+\s+// class java/lang/IllegalStateException",
        ],
        "depends": [
            r"public final zombie\.globalObjects\.GlobalObject getObjectAt\(int, int, int\);",
        ],
    },
    {
        "name": "MDFX_GosDuplicateNewGuard（Java：Lua 失敗後照樣把封包內容寫進既有物件＝零行為差異的前提）",
        "class": "zombie.globalObjects.CGlobalObjectSystem",
        "depends": [
            # CGlobalObjectSystem.java:34-50：pcall newLuaObjectAt 的結果不看，接著 getObjectAt＋逐鍵 rawset
            r"public void receiveNewLuaObjectAt\(int, int, int, se\.krka\.kahlua\.vm\.KahluaTable\);"
            r"(?:(?!\n  \S)[\s\S])*?// String newLuaObjectAt(?:(?!\n  \S)[\s\S])*?LuaCaller\.pcall:[^\n]*\n\s+\d+: pop"
            r"(?:(?!\n  \S)[\s\S])*?// Method getObjectAt:\(III\)Lzombie/globalObjects/GlobalObject;"
            r"(?:(?!\n  \S)[\s\S])*?KahluaTable\.rawset:",
        ],
    },
    {
        "name": "MDFX_GosDuplicateNewGuard（Java：依賴 GlobalObject.getModData）",
        "class": "zombie.globalObjects.GlobalObject",
        "depends": [
            r"public se\.krka\.kahlua\.vm\.KahluaTable getModData\(\);",
        ],
    },
    {
        "name": "MDFX_GosDuplicateNewGuard（成因：新增封包廣播給每條連線，不看連線狀態）",
        "class": "zombie.globalObjects.SGlobalObjectNetwork",
        "crash": [
            # SGlobalObjectNetwork.java:39-61：取出連線後直接 startPacket，沒有任何狀態判斷
            r"private static void sendPacket\(java\.nio\.ByteBuffer\);(?:(?!\n  \S)[\s\S])*?"
            r"// class zombie/core/raknet/UdpConnection\s+\d+: astore_2\s+\d+: aload_2\s+"
            r"\d+: invokevirtual #\d+\s+// Method zombie/core/raknet/UdpConnection\.startPacket:",
        ],
        "exithint": [
            # 官方若只廣播給已拿到清單／已完整連線的連線，sendPacket 裡會出現 UdpConnection.is* 判斷
            r"private static void sendPacket\(java\.nio\.ByteBuffer\);(?:(?!\n  \S)[\s\S])*?"
            r"// Method zombie/core/raknet/UdpConnection\.is\w+",
        ],
    },
    {
        "name": "MDFX_GosDuplicateNewGuard（成因：連線一接上就加進廣播表）",
        "class": "zombie.network.GameServer$DelayedConnection",
        "crash": [
            # GameServer.java:4427-4436（user log 的 Connection add），早於登入驗證與清單
            r"public void connect\(\);(?:(?!\n  \S)[\s\S])*?// String Connection add(?:(?!\n  \S)[\s\S])*?"
            r"// Field zombie/core/raknet/UdpEngine\.connections:Ljava/util/List;(?:(?!\n  \S)[\s\S])*?"
            r"// InterfaceMethod java/util/List\.add:",
        ],
    },
    {
        "name": "MDFX_GosDuplicateNewGuard（成因：清單在登入被接受時才打包）",
        "class": "zombie.network.ConnectionDetails",
        "crash": [
            # ConnectionDetails.java:38、:149-151
            r"public static void write\((?:(?!\n  \S)[\s\S])*?// Method writeGlobalObjects:",
            r"private static void writeGlobalObjects\(zombie\.core\.network\.ByteBufferWriter\)(?:(?!\n  \S)[\s\S])*?"
            r"// Method zombie/globalObjects/SGlobalObjects\.saveInitialStateForClient:",
        ],
    },
    # ── MDFX_ChargerIdleGuard：沒在充電的充電器每幀 updateGenerator ─────────────
    {
        "name": "MDFX_ChargerIdleGuard（成因：setActivated 不比對狀態）",
        "class": "zombie.iso.objects.IsoCarBatteryCharger",
        "crash": [
            # setActivated（IsoCarBatteryCharger.java:433-436）：寫入後直接 updateGenerator，中間沒有任何分支。
            # 這條轉紅＝官方改成比對狀態，本修復可以退場
            r"public void setActivated\(boolean\);\s+Code:\s+\d+: aload_0\s+\d+: iload_1\s+\d+: putfield\s+#\d+\s+// Field activated:Z\s+"
            r"\d+: aload_0\s+\d+: getfield\s+#\d+\s+// Field square:Lzombie/iso/IsoGridSquare;\s+"
            r"\d+: invokestatic\s+#\d+\s+// Method zombie/iso/objects/IsoGenerator\.updateGenerator:\(Lzombie/iso/IsoGridSquare;\)V\s+\d+: return",
            # update（:122-156）每次都可能呼叫 setActivated(false)（沒電池、沒電兩處）
            r"public void update\(\);(?:(?!\n  \S)[\s\S])*?// Method setActivated:\(Z\)V(?:(?!\n  \S)[\s\S])*?// Method setActivated:\(Z\)V",
        ],
        "depends": [
            # addToWorld（:111-114）登記進每幀更新清單：移出／放回的對象
            r"public void addToWorld\(\);(?:(?!\n  \S)[\s\S])*?// Method zombie/iso/IsoCell\.addToProcessIsoObject:\(Lzombie/iso/IsoObject;\)V",
            r"public boolean isActivated\(\);",
        ],
    },
    {
        "name": "MDFX_ChargerIdleGuard（成因：updateGenerator 標記重算）",
        "class": "zombie.iso.objects.IsoGenerator",
        "crash": [
            # updateGenerator（IsoGenerator.java:693-705）把半徑內的發電機標成 updateSurrounding
            r"public static void updateGenerator\(zombie\.iso\.IsoGridSquare\);(?:(?!\n  \S)[\s\S])*?// Field updateSurrounding:Z",
        ],
    },
    {
        "name": "MDFX_ChargerIdleGuard（依賴：每幀更新清單）",
        "class": "zombie.iso.IsoCell",
        "depends": [
            r"public java\.util\.ArrayList<zombie\.iso\.IsoObject> getProcessIsoObjects\(\);",
            # addToProcessIsoObject（IsoCell.java:2261-2268）只在尾端 add：只讀新增尾段的前提
            r"public void addToProcessIsoObject\(zombie\.iso\.IsoObject\);(?:(?!\n  \S)[\s\S])*?// Method java/util/ArrayList\.add:\(Ljava/lang/Object;\)Z",
            # 移除延到 ProcessIsoObject 開頭以 removeAll 處理（:2194-2199），其餘元素相對順序不變
            r"public void addToProcessIsoObjectRemove\(zombie\.iso\.IsoObject\);",
            r"private void ProcessIsoObject\(\);(?:(?!\n  \S)[\s\S])*?// Method java/util/ArrayList\.removeAll:",
        ],
    },
    {
        "name": "MDFX_ChargerIdleGuard（依賴：LoadChunk 在物件 addToWorld 之後）",
        "class": "zombie.iso.IsoChunk",
        "depends": [
            # doLoadGridsquare（IsoChunk.java:3807、:3969）
            r"public void doLoadGridsquare\(\);(?:(?!\n  \S)[\s\S])*?// Method zombie/iso/IsoObject\.addToWorld:\(\)V"
            r"(?:(?!\n  \S)[\s\S])*?// String LoadChunk",
        ],
    },
    {
        "name": "MDFX_ChargerIdleGuard（依賴：客戶端收到新物件觸發 OnObjectAdded）",
        "class": "zombie.network.packets.AddItemToMapPacket",
        "depends": [
            r"public void processClient\(zombie\.core\.raknet\.UdpConnection\);(?:(?!\n  \S)[\s\S])*?// String OnObjectAdded",
        ],
    },
    {
        "name": "MDFX_ChargerIdleGuard（包裝：啟動動作）",
        "file": "media/lua/shared/TimedActions/ISActivateCarBatteryChargerAction.lua",
        "depends": [
            r"function\s+ISActivateCarBatteryChargerAction:complete\s*\(\)",
            r"self\.charger:setActivated\(self\.activate\)",
        ],
    },
    {
        "name": "MDFX_ChargerIdleGuard（包裝：放置動作）",
        "file": "media/lua/shared/TimedActions/ISPlaceCarBatteryChargerAction.lua",
        "depends": [
            r"function\s+ISPlaceCarBatteryChargerAction:complete\s*\(\)",
            r"square:AddSpecialObject\(charger\)",
        ],
    },
    # ── MDFX_DeathSync：客戶端判定的死亡伺服器沒處理，按重生被拒 ─────────────
    {
        "name": "MDFX_DeathSync（成因：拖倒致死只在客戶端 Kill）",
        "class": "zombie.ai.states.PlayerHitReactionState",
        "crash": [
            # animEvent 的 Death 事件（PlayerHitReactionState.java:83）：!GameServer.server 才 Kill
            r"public void animEvent\([^)]*\);(?:(?!\n  \S)[\s\S])*?// String Death\s+\d+: invokevirtual #\d+\s+"
            r"// Method java/lang/String\.equalsIgnoreCase:\(Ljava/lang/String;\)Z(?:(?!\n  \S)[\s\S])*?"
            r"// Field zombie/network/GameServer\.server:Z\s+\d+: ifne\s+\d+\s+\d+: aload_1\s+\d+: aload_1\s+\d+: invokevirtual #\d+\s+"
            r"// Method zombie/characters/IsoGameCharacter\.getAttackedBy:\(\)Lzombie/characters/IsoGameCharacter;\s+\d+: invokevirtual #\d+\s+"
            r"// Method zombie/characters/IsoGameCharacter\.Kill:\(Lzombie/characters/IsoGameCharacter;\)V",
        ],
    },
    {
        "name": "MDFX_DeathSync（成因：伺服器只在收到命中、自己算出拖倒時 Kill）",
        "class": "zombie.network.fields.hit.Bite",
        "crash": [
            # process（Bite.java:89-94）：GameServer.server 時 isDeathDragDown 才 Kill(wielder)
            r"public void process\(zombie\.characters\.IsoZombie, zombie\.characters\.IsoGameCharacter\);(?:(?!\n  \S)[\s\S])*?"
            r"// Field zombie/network/GameServer\.server:Z(?:(?!\n  \S)[\s\S])*?"
            r"// Method zombie/characters/IsoGameCharacter\.isDeathDragDown:\(\)Z\s+\d+: ifeq\s+\d+\s+\d+: aload_2\s+\d+: aload_1\s+"
            r"\d+: invokevirtual #\d+\s+// Method zombie/characters/IsoGameCharacter\.Kill:\(Lzombie/characters/IsoGameCharacter;\)V",
        ],
    },
    {
        "name": "MDFX_DeathSync（後果：舊角色還活著時拒絕重生）",
        "class": "zombie.network.packets.connection.ConnectCoopPacket",
        "crash": [
            # ConnectCoopPacket.java:69-70：getPlayerAt(index) 還活著就 sendCoopAccessDenied
            r"// InterfaceMethod zombie/network/IConnection\.getPlayerAt:\(I\)Lzombie/characters/IsoPlayer;\s+\d+: invokevirtual #\d+\s+"
            r"// Method zombie/characters/IsoPlayer\.isDead:\(\)Z\s+\d+: ifne\s+\d+(?:(?!\n  \S)[\s\S])*?// Method sendCoopAccessDenied:",
        ],
    },
    {
        "name": "MDFX_DeathSync（依賴：OnPlayerDeath 只對本地玩家觸發、伺服器的死亡路徑、存活時數）",
        "class": "zombie.characters.IsoPlayer",
        "depends": [
            # OnDeath（IsoPlayer.java:6568-6570）
            r"public void OnDeath\(\);(?:(?!\n  \S)[\s\S])*?// Method isLocalPlayer:\(\)Z\s+\d+: ifeq\s+\d+\s+\d+: ldc(?:_w)?\s+#\d+\s+// String OnPlayerDeath",
            # Kill → onKilled → DoDeath（寫 user died、OnCharacterDeath，IsoPlayer.java:8349-8370）
            r"public void onKilled\(zombie\.characters\.IsoGameCharacter, zombie\.inventory\.types\.HandWeapon, boolean\);(?:(?!\n  \S)[\s\S])*?// Method DoDeath:",
            # 屍體建好後把 PlayerDeath 送給附近客戶端（IsoPlayer.java:8372-8381）
            r"private void onDied\(zombie\.characters\.IsoGameCharacter, zombie\.iso\.objects\.IsoDeadBody\);(?:(?!\n  \S)[\s\S])*?"
            r"// Method zombie/network/GameServer\.sendCharacterDeath:",
            # 擋重生後才到的舊回報靠伺服器端存活時數
            r"public double getHoursSurvived\(\);",
        ],
    },
    {
        "name": "MDFX_DeathSync（依賴：伺服器替每位玩家累加存活時數；一遊戲天的實際分鐘數）",
        "class": "zombie.GameTime",
        "depends": [
            # GameTime.java:539-545：GameServer.server 時對 GameServer.getPlayers() 每一位 setHoursSurvived(get + time)
            r"// Method zombie/network/GameServer\.getPlayers:\(\)Ljava/util/ArrayList;(?:(?!\n  \S)[\s\S])*?"
            r"// Method zombie/characters/IsoPlayer\.setHoursSurvived:\(D\)V",
            # 把 MIN_SECONDS 換成遊戲小時（GameTime.java:946-948；值由沙盒 DayLength 設定，SandboxOptions.java:410-419、452）
            r"public float getMinutesPerDay\(\);",
        ],
    },
    {
        "name": "MDFX_DeathSync（依賴：伺服器建的新角色存活時數從 0 開始）",
        "class": "zombie.network.packets.character.CreatePlayerPacket",
        "depends": [
            # processServer（CreatePlayerPacket.java:288-302）：new IsoPlayer（欄位預設 0，IsoPlayer.java:410）到存進 ServerPlayerDB
            # 之間不設存活時數；之後 PlayerConnect 由 DB 讀回（GameServer.java:2812-2814 → IsoPlayer.load :1230）。
            # 這條轉紅＝新角色可能帶著時數出生，重生後才到的舊回報會越過 MIN_SECONDS，要重新設計門檻
            r"public void processServer\(zombie\.network\.PacketTypes\$PacketType, zombie\.core\.raknet\.UdpConnection\);(?:(?!\n  \S)[\s\S])*?"
            r"\d+: new\s+#\d+\s+// class zombie/characters/IsoPlayer\n"
            r"(?:(?!setHoursSurvived)(?!\n  \S)[\s\S])*?// Method zombie/savefile/ServerPlayerDB\.serverUpdateNetworkCharacter:",
        ],
    },
    {
        "name": "MDFX_DeathSync（依賴：Kill／die／isDead／isGodMod）",
        "class": "zombie.characters.IsoGameCharacter",
        "depends": [
            r"public final void Kill\(zombie\.characters\.IsoGameCharacter\);",
            # die（IsoGameCharacter.java:14623-14646）：伺服器端 becomeCorpse
            r"public final void die\(\);(?:(?!\n  \S)[\s\S])*?// Field zombie/network/GameServer\.server:Z(?:(?!\n  \S)[\s\S])*?"
            r"// Method becomeCorpse:\(\)Lzombie/iso/objects/IsoDeadBody;",
            r"public boolean isDead\(\);",
            r"public boolean isGodMod\(\);",
        ],
    },
    {
        "name": "MDFX_DeathSync（依賴：指令的 player 由寄件者連線解析）",
        "class": "zombie.network.GameServer",
        "depends": [
            # receiveClientCommand（GameServer.java:2280-2313）
            r"static void receiveClientCommand\([^)]*\);(?:(?!\n  \S)[\s\S])*?// Method getPlayerFromConnection:(?:(?!\n  \S)[\s\S])*?// String OnClientCommand",
        ],
    },
    # ── MDFX_HealthCheatPermission：強化健康作弊的伺服器端驗證（細節見本機知識庫 server-commands.md）──
    {
        "name": "MDFX_HealthCheatPermission（原版指令與分派器；42.22 官方已補權限檢查）",
        "file": "media/lua/server/ClientCommands.lua",
        "retired": [
            # 42.22.2 :645-649：onHealthCheatCurrentPlayer 只改寄件者自己，而且要 UseHealthCheat（42.21.0 :481-627 兩樣都不查）
            r"Commands\.player\.onHealthCheatCurrentPlayer\s*=\s*function\s*\(\s*player\s*,\s*args\s*\)\s*"
            r"if\s+getPlayerByOnlineID\(args\.id\)\s*==\s*player\s+and\s+checkPermissions\(player,\s*Capability\.UseHealthCheat\)\s+then",
            # 42.22.2 :638-643：onHealthCheat 有權限就由伺服器直接套用，不再轉給目標的客戶端（補丁的轉送票在 42.22 用不到）
            r"Commands\.player\.onHealthCheat\s*=\s*function\s*\(\s*player\s*,\s*args\s*\)\s*"
            r"local\s+otherPlayer\s*=\s*getPlayerByOnlineID\(args\.id\)\s*"
            r"if\s+otherPlayer\s+and\s+checkPermissions\(player,\s*Capability\.UseHealthCheat\)\s+then\s*applyHealthCheat\(otherPlayer,\s*args\)",
        ],
        "depends": [
            # 分派器依 module／command 呼叫，參數原樣傳下去（42.22.2 :1342-1352）
            r"ClientCommands\.OnClientCommand\s*=\s*function\s*\(\s*module\s*,\s*command\s*,\s*player\s*,\s*args\s*\)"
            r"(?:(?!\nend)[\s\S])*?Commands\[module\]\[command\]\(player,\s*args\)",
            # 全檔恰好一次 Events.OnClientCommand.Add，而且登記的是分派器（補丁要求恰好一支）
            r"\A(?:(?!Events\.OnClientCommand\.Add)[\s\S])*Events\.OnClientCommand\.Add\(ClientCommands\.OnClientCommand\)"
            r"(?:(?!Events\.OnClientCommand\.Add)[\s\S])*\Z",
        ],
    },
    {
        "name": "MDFX_HealthCheatPermission（依賴：伺服器先載入 shared/ 再載入 server/）",
        "class": "zombie.network.GameServer",
        "depends": [
            # GameServer.java:1469-1471：補丁放 shared/，載入時暫換 Add，一定早於原版 server/ClientCommands.lua
            r"// String shared\s+\d+: invokestatic\s+#\d+\s+// Method zombie/Lua/LuaManager\.LoadDirBase:\(Ljava/lang/String;\)V\s+"
            r"\d+: ldc(?:_w)?\s+#\d+\s+// String client\s+\d+: iconst_1\s+\d+: invokestatic\s+#\d+\s+"
            r"// Method zombie/Lua/LuaManager\.LoadDirBase:\(Ljava/lang/String;Z\)V\s+"
            r"\d+: ldc(?:_w)?\s+#\d+\s+// String server\s+\d+: invokestatic\s+#\d+\s+// Method zombie/Lua/LuaManager\.LoadDirBase:",
        ],
    },
    {
        "name": "MDFX_HealthCheatPermission（依賴：Events.X.Add 是一般表上的欄位，可以暫換）",
        "class": "zombie.Lua.Event",
        "depends": [
            # Event.java:78-83
            r"public void register\(se\.krka\.kahlua\.vm\.Platform, se\.krka\.kahlua\.vm\.KahluaTable\);(?:(?!\n  \S)[\s\S])*?"
            r"// String Add\s+\d+: aload_0\s+\d+: getfield\s+#\d+\s+// Field add:Lzombie/Lua/Event\$Add;\s+"
            r"\d+: invokeinterface\s+#\d+,\s+3\s+// InterfaceMethod se/krka/kahlua/vm/KahluaTable\.rawset:",
        ],
    },
    {
        "name": "MDFX_VehicleSinkGuard（成因：update 不把掉到地板下的車放回）",
        "class": "zombie.vehicles.BaseVehicle",
        "crash": [
            # update()（42.22.2 BaseVehicle.java:3402-3451）只用物理高度推算樓層：整個方法恰一個 setWorldTransform
            # （格子沒載入時把車夾回 chunk 的那一個），沒有 PZMath.clamp。轉紅＝官方在 update 補了放回地面，本修復可以退場
            r"public void update\(\);(?:(?!\n  \S)(?!// Method setWorldTransform:)(?!PZMath\.clamp)[\s\S])*"
            r"// Method setWorldTransform:\(Lzombie/core/physics/Transform;\)V"
            r"(?:(?!\n  \S)(?!// Method setWorldTransform:)(?!PZMath\.clamp)[\s\S])*(?=\n  \S)",
        ],
        "formula": [
            # 樓層＝floor(物理高度 ÷ 2.44949 + 0.05)：守衛的 LEVEL_HEIGHT 與「車所在樓層」（getZ）都依這一段
            r"public void update\(\);(?:(?!\n  \S)[\s\S])*?// float 2\.44949f\s+\d+: fdiv\s+\d+: ldc(?:_w)?\s+#\d+\s+// float 0\.05f\s+"
            r"\d+: fadd\s+\d+: invokestatic\s+#\d+\s+// Method zombie/core/math/PZMath\.fastfloor:\(F\)I",
            # 翻覆門檻 MIN_UPRIGHT 抄自這個常數（javap -c 不印值，值在 BaseVehicle.java:238）
            r"public static final float MINIMUM_DOT_UPRIGHT;",
        ],
        "depends": [
            r"public boolean isLocalPhysicSim\(\);",
            r"public zombie\.core\.physics\.Transform getWorldTransform\(zombie\.core\.physics\.Transform\);",
            # setWorldTransform（:4083-4101）在客戶端呼叫原生 teleportVehicle（原生端會清掉線速度與角速度）
            r"public void setWorldTransform\(zombie\.core\.physics\.Transform\);(?:(?!\n  \S)[\s\S])*?"
            r"// Method zombie/core/physics/Bullet\.teleportVehicle:",
            # setAngles（:4114-4129）：rotationXYZ 後整個 transform 經 setWorldTransform 放回，原點不變
            r"public void setAngles\(float, float, float\);(?:(?!\n  \S)[\s\S])*?rotationXYZ(?:(?!\n  \S)[\s\S])*?"
            r"// Method setWorldTransform:",
            r"public float getUpVectorDot\(\);",
            r"public org\.joml\.Vector3f getForwardVector\(org\.joml\.Vector3f\);",
            r"public short getId\(\);",
            r"public java\.lang\.String getAuthorizationDescription\(\);",
        ],
    },
    {
        "name": "MDFX_VehicleSinkGuard（成因：伺服器照收客戶端回報的高度）",
        "class": "zombie.network.packets.vehicle.VehiclePhysicsPacket",
        "crash": [
            # processServer：setZ 與 jniTransform 原點直接寫入，整個方法沒有 clamp。轉紅＝官方在伺服器夾樓層，回頭評估退場
            r"public void processServer\(zombie\.network\.PacketTypes\$PacketType, zombie\.core\.raknet\.UdpConnection\);"
            r"(?:(?!\n  \S)(?!clamp)[\s\S])*// Method zombie/vehicles/BaseVehicle\.setZ:\(F\)F"
            r"(?:(?!\n  \S)(?!clamp)[\s\S])*(?=\n  \S|\n\})",
        ],
    },
    {
        "name": "MDFX_VehicleSinkGuard（放回高度的公式來源：CarController 生成車輛）",
        "class": "zombie.core.physics.CarController",
        "formula": [
            # 建構子（CarController.java:70-80）：−min(模型偏移＋輪子偏移－輪半徑, 重心偏移－車身高÷2)。守衛照抄，輪半徑改用上限
            r"public zombie\.core\.physics\.CarController\(zombie\.vehicles\.BaseVehicle\);(?:(?!\n  \S)[\s\S])*?"
            r"VehicleScript\.getModelOffset:(?:(?!\n  \S)[\s\S])*?VehicleScript\$Wheel\.getOffset:(?:(?!\n  \S)[\s\S])*?"
            r"// Field zombie/scripting/objects/VehicleScript\$Wheel\.radius:F(?:(?!\n  \S)[\s\S])*?"
            r"VehicleScript\.getCenterOfMassOffset:(?:(?!\n  \S)[\s\S])*?VehicleScript\.getExtents:",
        ],
    },
    {
        "name": "MDFX_VehicleSinkGuard（依賴：VehicleScript）",
        "class": "zombie.scripting.objects.VehicleScript",
        "depends": [
            r"public org\.joml\.Vector3f getModelOffset\(\);",
            r"public org\.joml\.Vector3f getExtents\(\);",
            r"public org\.joml\.Vector3f getCenterOfMassOffset\(\);",
            r"public int getWheelCount\(\);",
            r"public zombie\.scripting\.objects\.VehicleScript\$Wheel getWheel\(int\);",
        ],
    },
    {
        "name": "MDFX_VehicleSinkGuard（依賴：輪子；輪半徑只有欄位、Lua 讀不到）",
        "class": "zombie.scripting.objects.VehicleScript$Wheel",
        "depends": [
            r"public org\.joml\.Vector3f getOffset\(\);",
        ],
        "formula": [
            # WHEEL_RADIUS 抄這個欄位的預設值（VehicleScript.java:2697，0.5）
            r"public float radius;",
        ],
        "exithint": [
            # 官方加了 getter：守衛可以改讀實際輪半徑，放回高度就和原版生成車輛完全相同
            r"public float getRadius\(\);",
        ],
    },
    {
        "name": "MDFX_VehicleSinkGuard（依賴：Transform.getOrigin）",
        "class": "zombie.core.physics.Transform",
        "depends": [
            r"public org\.joml\.Vector3f getOrigin\(\);",
        ],
    },
    {
        "name": "MDFX_VehicleSinkGuard（依賴：IsoGridSquare.hasFloor）",
        "class": "zombie.iso.IsoGridSquare",
        "depends": [
            r"public boolean hasFloor\(\);",
        ],
    },
    {
        "name": "MDFX_VehicleSinkGuard（依賴：IsoCell.getVehicles 回 Set，守衛以 ArrayList.addAll 取出）",
        "class": "zombie.iso.IsoCell",
        "depends": [
            r"public java\.util\.Set<zombie\.vehicles\.BaseVehicle> getVehicles\(\);",
        ],
    },
    {
        "name": "MDFX_VehicleSinkGuard（依賴：Transform／Vector3f／輪子曝露給 Lua）",
        "class": "zombie.Lua.LuaManager$Exposer",
        "depends": [
            r"// class zombie/core/physics/Transform\s+\d+: invokevirtual #\d+\s+// Method setExposed:",
            r"// class org/joml/Vector3f\s+\d+: invokevirtual #\d+\s+// Method setExposed:",
            r"// class zombie/scripting/objects/VehicleScript\$Wheel\s+\d+: invokevirtual #\d+\s+// Method setExposed:",
        ],
    },
    {
        "name": "MDFX_VehicleSinkGuard（前提：OnTick 在所有車的 update 之後）",
        "class": "zombie.gameStates.IngameState",
        "depends": [
            # updateInternal：IsoWorld.update（車的 update 在裡面）之後才 onTick
            r"updateInternal\(\);(?:(?!\n  \S)[\s\S])*?// Method zombie/iso/IsoWorld\.update:\(\)V(?:(?!\n  \S)[\s\S])*?"
            r"// Method onTick:\(\)V",
        ],
    },
    {
        "name": "MDFX_WindowFaceGuard",
        "file": "media/lua/shared/Moveables/ISMoveableSpriteProps.lua",
        "crash": [
            # :1941 北向與否多看了 hasFaces()：沒有換面資料的北向窗被當成西向。行變了＝官方動了這個判斷，重跑 E2E window-faces 對照組
            r'local\s+isNorth\s*=\s*\(self:hasFaces\(\)\s+and\s+self\.facing\s*==\s*"N"\s+or\s+self\.facing\s*==\s*"S"\)\s+or\s+false',
        ],
        "depends": [
            # wrapper 的包裝目標與參數順序
            r"function\s+ISMoveableSpriteProps:canPlaceMoveableInternal\s*\(\s*_character\s*,\s*_square\s*,\s*_item\s*,\s*_forceTypeObject\s*\)",
            # 「把 facing 暫時改成 S 就會找北牆窗框」的前提：:1941 把 "S" 當北向、:1942／:1944 照 isNorth 找窗框與已有的窗
            r'self:getWallForFacing\(_square,\s*isNorth\s+and\s+"S"\s+or\s+"E",\s*"WindowFrame"\)',
            r"_square:getWindow\(isNorth\s+and\s+GridSquareEdgeFacingDirection\.NORTH_SOUTH\s+or\s+GridSquareEdgeFacingDirection\.EAST_WEST\)",
            # 放下去那一段（placeMoveableInternal :2077）直接照 Facing 判北向：判斷放行後窗會放在北牆
            r'local\s+north\s*=\s*self\.facing\s+and\s+\(self\.facing\s*==\s*"N"\s+or\s+self\.facing\s*==\s*"S"\)',
            # 完成端（多人是伺服器）會再判一次（placeMoveable :2050）：本補丁放 shared/ 的理由
            r"if\s+item\s+and\s+\(self:canPlaceMoveableInternal\(_character,\s*_square,\s*item\)\s+or\s+_forceAllow\)\s+then",
        ],
    },
    # ── MDFX_StaleWornGuard：放到地上（或別的容器）的物品還留在穿戴清單，伺服器定期拿掉 ─────────────
    {
        "name": "MDFX_StaleWornGuard（成因：伺服器放下物品時不碰穿戴）",
        "file": "media/lua/shared/TimedActions/ISDropWorldItemAction.lua",
        "crash": [
            # complete :81-91：放到地上再移出物品欄，中間沒有脫下。行變了＝官方動了這段，重跑 E2E stale-worn 對照組
            r"local worldItem = self\.sq:AddWorldInventoryItem\(self\.item,[^\n]*\n(?:(?!removeWornItem)[\s\S])*?"
            r"self\.character:getInventory\(\):Remove\(self\.item\);\s*"
            r"sendRemoveItemFromContainer\(self\.character:getInventory\(\),\s*self\.item\);\s*if instanceof\(worldItem",
        ],
        "exithint": [
            # 官方若讓放下的動作自己脫下
            r"removeWornItem|setWornItem|getWornItems\(\):remove",
        ],
    },
    {
        "name": "MDFX_StaleWornGuard（成因：要不要先脫下，由客戶端排動作時判斷）",
        "file": "media/lua/server/BuildingObjects/ISPlace3DItemCursor.lua",
        "crash": [
            # create :38-40（:27-29 是「全部放置」的同一段）
            r'if self\.chr:isEquipped\(item\) then\s*ISTimedActionQueue\.add\(ISUnequipAction:new\(self\.chr, item, 1, "place"\)\);',
        ],
    },
    {
        "name": "MDFX_StaleWornGuard（成因：伺服器照客戶端的清單穿回；物品欄沒有就另建一件）",
        "class": "zombie.network.packets.SyncClothingPacket",
        "crash": [
            # process（SyncClothingPacket.java:192-204）：getItemWithID 找不到 → CreateItem → setID（沿用清單上的編號）→ WornItems.setItem。
            # 守衛把「另建的物件、同編號的真物品這位玩家穿過」當殘留；轉紅＝官方改了伺服器收清單的方式，重看守衛的判定
            # 開頭那段鎖 :193 的 Clothing 轉型：背包轉不過去，所以每收到一次清單都重穿（另建）一次
            # setID 那段：另建的物件不沿用編號的話，守衛照編號比先例就永遠對不上
            r"private void process\(\);(?:(?!\n  \S)[\s\S])*?// Method zombie/characters/WornItems/WornItems\.getItemById:\(I\)Lzombie/inventory/InventoryItem;"
            r"\s+\d+: ldc(?:_w)?\s+#\d+\s+// class zombie/inventory/types/Clothing"
            r"(?:(?!\n  \S)[\s\S])*?// Method zombie/inventory/ItemContainer\.getItemWithID:\(I\)Lzombie/inventory/InventoryItem;"
            r"(?:(?!\n  \S)[\s\S])*?// Method zombie/inventory/InventoryItemFactory\.CreateItem:\(Ljava/lang/String;\)Lzombie/inventory/InventoryItem;"
            r"(?:(?!\n  \S)[\s\S])*?// Method zombie/inventory/InventoryItem\.setID:\(I\)V"
            r"(?:(?!\n  \S)[\s\S])*?// Method zombie/characters/WornItems/WornItems\.setItem:",
        ],
    },
    {
        "name": "MDFX_StaleWornGuard（依賴：removeWornItem 走 setWornItem、結尾 syncClothing；isDead）",
        "class": "zombie.characters.IsoGameCharacter",
        "depends": [
            # removeWornItem(item, forceDropTooHeavy)（IsoGameCharacter.java:3516-3518）
            r"public void removeWornItem\(zombie\.inventory\.InventoryItem, boolean\);(?:(?!\n  \S)[\s\S])*?"
            r"// Method setWornItem:\(Lzombie/scripting/objects/ItemBodyLocation;Lzombie/inventory/InventoryItem;Z\)V",
            # setWornItem（:3460-3505）
            r"public void setWornItem\(zombie\.scripting\.objects\.ItemBodyLocation, zombie\.inventory\.InventoryItem, boolean\);"
            r"(?:(?!\n  \S)[\s\S])*?// Method syncClothing:\(\)V",
            # setWornItem 把舊的那件移出每幀更新清單（:3464-3466）：守衛拿掉真物品後要登記回去
            r"public void setWornItem\(zombie\.scripting\.objects\.ItemBodyLocation, zombie\.inventory\.InventoryItem, boolean\);"
            r"(?:(?!\n  \S)[\s\S])*?// Method zombie/iso/IsoCell\.addToProcessItemsRemove:\(Lzombie/inventory/InventoryItem;\)V",
            r"public boolean isDead\(\);",
        ],
    },
    {
        "name": "MDFX_StaleWornGuard（依賴：伺服器的 syncClothing 把穿戴清單送給所有客戶端）",
        "class": "zombie.characters.IsoPlayer",
        "depends": [
            # IsoPlayer.java:8956-8959
            r"public void syncClothing\(\);(?:(?!\n  \S)[\s\S])*?// Field zombie/network/GameServer\.server:Z(?:(?!\n  \S)[\s\S])*?"
            r"// Field zombie/network/PacketTypes\$PacketType\.SyncClothing:(?:(?!\n  \S)[\s\S])*?"
            r"// InterfaceMethod zombie/network/packets/INetworkPacket\.sendToAll:",
        ],
    },
    {
        "name": "MDFX_StaleWornGuard（依賴：WornItems）",
        "class": "zombie.characters.WornItems.WornItems",
        "depends": [
            r"public zombie\.inventory\.InventoryItem getItemByIndex\(int\);",
            r"public int size\(\);",
            r"public boolean contains\(zombie\.inventory\.InventoryItem\);",
            r"public zombie\.scripting\.objects\.ItemBodyLocation getLocation\(zombie\.inventory\.InventoryItem\);",
            r"public zombie\.characters\.WornItems\.BodyLocationGroup getBodyLocationGroup\(\);",
            # setItem（WornItems.java:53-59）：可同時穿多件的部位不移除舊的。這行沒了＝多件部位也拿得掉，守衛可以不再跳過
            r"(?s)public void setItem\(zombie\.scripting\.objects\.ItemBodyLocation, zombie\.inventory\.InventoryItem\);"
            r"(?:(?!\n  [a-z]).)*?BodyLocationGroup\.isMultiItem:",
        ],
    },
    {
        "name": "MDFX_StaleWornGuard（依賴：部位能不能同時穿多件）",
        "class": "zombie.characters.WornItems.BodyLocationGroup",
        "depends": [
            r"public boolean isMultiItem\(zombie\.scripting\.objects\.ItemBodyLocation\);",
        ],
    },
    {
        "name": "MDFX_StaleWornGuard（依賴：物品所在的容器與地上物件）",
        "class": "zombie.inventory.InventoryItem",
        "depends": [
            r"public zombie\.inventory\.ItemContainer getContainer\(\);",
            r"public zombie\.iso\.objects\.IsoWorldInventoryObject getWorldItem\(\);",
            r"public int getID\(\);",
        ],
    },
    {
        "name": "MDFX_StaleWornGuard（前提：移出物品欄後 getContainer() 是 null）",
        "class": "zombie.inventory.ItemContainer",
        "depends": [
            # Remove(InventoryItem)（ItemContainer.java:2084-2094）
            r"public void Remove\(zombie\.inventory\.InventoryItem\);(?:(?!\n  \S)[\s\S])*?aconst_null\s+\d+: putfield\s+#\d+\s+"
            r"// Field zombie/inventory/InventoryItem\.container:",
        ],
        "exithint": [
            # 官方若在物品離開容器時順手脫下（Remove 已經呼叫 removeFromHands，最自然的修法位置）
            r"public void Remove\(zombie\.inventory\.InventoryItem\);(?:(?!\n  \S)[\s\S])*?// Method zombie/characters/IsoGameCharacter\.removeWornItem:",
        ],
    },
    {
        "name": "MDFX_StaleWornGuard（前提：放到地上的物品有 getWorldItem()）",
        "class": "zombie.iso.IsoGridSquare",
        "depends": [
            # AddWorldInventoryItem(item, x, y, height, transmit, synchSpawn)（IsoGridSquare.java:6066-6126）
            r"public zombie\.inventory\.InventoryItem AddWorldInventoryItem\(zombie\.inventory\.InventoryItem, float, float, float, boolean, boolean\);"
            r"(?:(?!\n  \S)[\s\S])*?// Method zombie/inventory/InventoryItem\.setWorldItem:",
        ],
    },
    {
        "name": "MDFX_StaleWornGuard（依賴：IsoCell.addToProcessItems）",
        "class": "zombie.iso.IsoCell",
        "depends": [
            # IsoCell.java:2294-2301：取消待移除、沒有才加入
            r"public void addToProcessItems\(zombie\.inventory\.InventoryItem\);",
        ],
    },
    {
        "name": "MDFX_StaleWornGuard（依賴：getOnlinePlayers 在伺服器回 GameServer.getPlayers）",
        "class": "zombie.Lua.LuaManager$GlobalObject",
        "depends": [
            # LuaManager.java:4474-4480
            r"getOnlinePlayers\(\);(?:(?!\n  \S)[\s\S])*?// Field zombie/network/GameServer\.server:Z(?:(?!\n  \S)[\s\S])*?"
            r"// Method zombie/network/GameServer\.getPlayers:",
        ],
    },
    {
        "name": "MDFX_StaleWornGuard（單人：OnTickEvenPaused 在 IsoWorld.update 與 OnTick 之前）",
        "class": "zombie.gameStates.IngameState",
        "depends": [
            # IngameState.java:1346、:1535、:1653。單人掛 OnTickEvenPaused 是因為外觀 MOD 在 OnTick 才把穿戴清單換成複製品；
            # 順序變了＝單人讀到的可能不是真清單，重跑 E2E stale-worn 的單人修正組
            r"// String OnTickEvenPaused(?:(?!\n  \S)[\s\S])*?// Method zombie/iso/IsoWorld\.update:\(\)V"
            r"(?:(?!\n  \S)[\s\S])*?// Method onTick:\(\)V",
        ],
    },
    {
        "name": "MDFX_StaleWornGuard（單人：本機玩家）",
        "class": "zombie.Lua.LuaManager$GlobalObject",
        "depends": [
            # LuaManager.java:3901-3903、:4184-4186
            r"public static int getNumActivePlayers\(\);",
            r"public static zombie\.characters\.IsoPlayer getSpecificPlayer\(int\);",
        ],
    },
    # ── MDFX_SledgehammerGuard：缺片的多格物件大錘拆不掉（原版完成後只補移除被敲的那一片）＋照原版伺服器規則先檢查 ─────────────
    {
        "name": "MDFX_SledgehammerGuard",
        "file": "media/lua/shared/TimedActions/ISDestroyStuffAction.lua",
        "crash": [
            # :329-330 一般物件用一個參數的移除（安全移除）。行變了＝官方動了大錘的移除方式，重跑 E2E broken-multitile 對照組
            r"else --not a corner wall, just remove it\s*self\.item:getSquare\(\):transmitRemoveItemFromSquare\(self\.item\)",
        ],
        "depends": [
            # wrapper 的包裝目標
            r"function\s+ISDestroyStuffAction:complete\s*\(\s*\)",
            # 「回 true＝原版判定可拆、也試著移除了」的前提：complete 結尾回 true（:349）
            r"return true;\s*end\s*function\s+ISDestroyStuffAction:getDuration",
            # 被敲那一片自己的容器原版先倒了（:132）；守衛只多擋有 component 的物件
            r"self\.item:dumpContentsInSquare\(\)",
            # 原版伺服器端的兩道規則（:116-130）：守衛的 refusal 照這兩段寫。轉紅＝原版改了規則，refusal 要跟著改
            r"function\s+ISDestroyStuffAction:hasSledgehammerInRange\s*\(\s*character\s*,\s*item\s*\)",
            r"if not self\.character:isBuildCheat\(\) and not self:hasSledgehammerInRange\(self\.character, self\.item\) then\s*return false",
            r'if getServerOptions\(\):getBoolean\("SledgehammerOnlyInSafehouse"\) then\s*local role = self\.character:getRole\(\)\s*'
            r"local isPrivileged = role and role:hasCapability\(Capability\.UseBuildCheat\)\s*if not isPrivileged then\s*"
            r"local safe = SafeHouse\.isSafeHouse\(self\.item:getSquare\(\), nil, false\)\s*"
            r"if not \(safe and safe:playerAllowed\(self\.character\)\) then\s*return false",
        ],
    },
    {
        "name": "MDFX_SledgehammerGuard（成因：伺服器的安全移除，多格物件找不齊整組就回 -1）",
        "class": "zombie.iso.IsoGridSquare",
        "crash": [
            # transmitRemoveItemFromSquare(obj, safelyRemove)（IsoGridSquare.java:5933-5960）：isObjectMultiSquare → getAllMultiTileObjects 回 false → 回 -1
            r"public int transmitRemoveItemFromSquare\(zombie\.iso\.IsoObject, boolean\);(?:(?!\n  \S)[\s\S])*?"
            r"// Method zombie/iso/IsoObjectUtils\.isObjectMultiSquare:\(Lzombie/iso/IsoObject;\)Z(?:(?!\n  \S)[\s\S])*?"
            r"// Method zombie/iso/IsoObjectUtils\.getAllMultiTileObjects:\(Lzombie/iso/IsoObject;Ljava/util/ArrayList;\)Z\s+\d+: ifeq"
            r"(?:(?!\n  \S)[\s\S])*?\d+: iconst_m1\s+\d+: ireturn",
        ],
        "depends": [
            # 一個參數的版本固定傳 true（:5929-5931）：守衛「再問一次」用的就是它
            r"public int transmitRemoveItemFromSquare\(zombie\.iso\.IsoObject\);\s+Code:\s+0: aload_0\s+1: aload_1\s+2: iconst_1\s+"
            r"3: invokevirtual #\d+\s+// Method transmitRemoveItemFromSquare:\(Lzombie/iso/IsoObject;Z\)I",
            # safelyRemove 是 false 時直接 GameServer.RemoveItemFromMap（只移除那一片、送客戶端）
            r"public int transmitRemoveItemFromSquare\(zombie\.iso\.IsoObject, boolean\);(?:(?!\n  \S)[\s\S])*?"
            r"// Method zombie/iso/IsoObjectUtils\.getAllMultiTileObjects:(?:(?!\n  \S)[\s\S])*?"
            r"// Method zombie/network/GameServer\.RemoveItemFromMap:\(Lzombie/iso/IsoObject;\)I\s+\d+: ireturn\s*\n",
            # 單人：RemoveTileObject(obj, true) 走 IsoObjectUtils.safelyRemoveTileObjectFromSquare（:5705-5708）
            r"public int RemoveTileObject\(zombie\.iso\.IsoObject, boolean\);\s+Code:\s+0: iload_2\s+1: ifeq\s+\d+\s+4: aload_1\s+"
            r"5: invokestatic\s+#\d+\s+// Method zombie/iso/IsoObjectUtils\.safelyRemoveTileObjectFromSquare:\(Lzombie/iso/IsoObject;\)I",
            # 守衛看每一格有哪些物件
            r"public java\.util\.List<zombie\.iso\.IsoObject> getObjects\(\);",
        ],
    },
    {
        "name": "MDFX_SledgehammerGuard（成因：單人的安全移除；多格的判斷看圖塊的 SpriteGrid）",
        "class": "zombie.iso.IsoObjectUtils",
        "crash": [
            # safelyRemoveTileObjectFromSquare（IsoObjectUtils.java:32-62）：getAllMultiTileObjects 回 false → 回 -1
            r"public static int safelyRemoveTileObjectFromSquare\(zombie\.iso\.IsoObject\);(?:(?!\n  \S)[\s\S])*?"
            r"// Method getAllMultiTileObjects:\(Lzombie/iso/IsoObject;Ljava/util/ArrayList;\)Z\s+\d+: ifne"
            r"(?:(?!\n  \S)[\s\S])*?\d+: iconst_m1\s+\d+: ireturn",
        ],
        "depends": [
            # isObjectMultiSquare（:20-30）看圖塊的 SpriteGrid：守衛用 getSpriteGrid() 認多格圖塊
            r"public static boolean isObjectMultiSquare\(zombie\.iso\.IsoObject\);(?:(?!\n  \S)[\s\S])*?"
            r"// Method zombie/iso/sprite/IsoSprite\.getSpriteGrid:\(\)Lzombie/iso/sprite/IsoSpriteGrid;",
            # dumpContentsInSquare（:161-205）：整組找不齊就在倒 component 之前返回。守衛因此不管有 component 的物件；
            # 轉紅＝官方改了倒內容的順序，重看那個條件
            r"public static void dumpContentsInSquare\(zombie\.iso\.IsoObject\);(?:(?!\n  \S)[\s\S])*?"
            r"// Method getAllMultiTileObjects:\(Lzombie/iso/IsoObject;Ljava/util/ArrayList;\)Z(?:(?!\n  \S)[\s\S])*?"
            r"// Method zombie/entity/Component\.dumpContentsInSquare:\(\)V",
            # getSpriteGridMultiTileObjects（:115-155）找整組的走法：守衛的缺片判斷照這個順序看每一格。
            # 轉紅＝引擎改了找整組的方式，重看 hasMissingPiece 還對不對得上
            r"private static boolean getSpriteGridMultiTileObjects\(zombie\.iso\.IsoObject, java\.util\.ArrayList<zombie\.iso\.IsoObject>\);"
            r"(?:(?!\n  \S)[\s\S])*?IsoSpriteGrid\.getSpriteGridPosX:(?:(?!\n  \S)[\s\S])*?IsoSpriteGrid\.getSpriteGridPosY:"
            r"(?:(?!\n  \S)[\s\S])*?IsoSpriteGrid\.getSpriteGridPosZ:(?:(?!\n  \S)[\s\S])*?IsoSpriteGrid\.getLevels:"
            r"(?:(?!\n  \S)[\s\S])*?IsoCell\.getGridSquare:\(III\)Lzombie/iso/IsoGridSquare;"
            r"(?:(?!\n  \S)[\s\S])*?IsoSpriteGrid\.getSprite:\(III\)Lzombie/iso/sprite/IsoSprite;"
            r"(?:(?!\n  \S)[\s\S])*?// Method verifyObject:",
            # verifyObject（:157-159）比的是同一個圖塊物件
            r"private static boolean verifyObject\(zombie\.iso\.IsoObject, zombie\.iso\.sprite\.IsoSprite\);(?:(?!\n  \S)[\s\S])*?\d+: if_acmpne",
        ],
    },
    {
        "name": "MDFX_SledgehammerGuard（依賴：物件還在不在格子上、圖塊的 SpriteGrid）",
        "class": "zombie.iso.IsoObject",
        "depends": [
            r"public int getObjectIndex\(\);",
            r"public zombie\.iso\.sprite\.IsoSpriteGrid getSpriteGrid\(\);",
        ],
    },
    {
        "name": "MDFX_SledgehammerGuard（依賴：多格圖塊組的大小與每一格的圖塊）",
        "class": "zombie.iso.sprite.IsoSpriteGrid",
        "depends": [
            r"public zombie\.iso\.sprite\.IsoSprite getSprite\(int, int, int\);",
            r"public int getSpriteGridPosX\(zombie\.iso\.sprite\.IsoSprite\);",
            r"public int getSpriteGridPosY\(zombie\.iso\.sprite\.IsoSprite\);",
            r"public int getSpriteGridPosZ\(zombie\.iso\.sprite\.IsoSprite\);",
            r"public int getWidth\(\);",
            r"public int getHeight\(\);",
            r"public int getLevels\(\);",
        ],
    },
    {
        "name": "MDFX_SledgehammerGuard（依賴：照座標取格子，沒載入回 null）",
        "class": "zombie.iso.IsoCell",
        "depends": [
            r"public zombie\.iso\.IsoGridSquare getGridSquare\(int, int, int\);",
        ],
    },
    {
        "name": "MDFX_SledgehammerGuard（依賴：getCell）",
        "class": "zombie.Lua.LuaManager$GlobalObject",
        "depends": [
            r"public static zombie\.iso\.IsoCell getCell\(\);",
        ],
    },
    {
        "name": "MDFX_SledgehammerGuard（安裝：復查用的 OnInitGlobalModData）",
        "class": "zombie.world.moddata.GlobalModData",
        "depends": [
            # GlobalModData.java:54，由 IsoWorld.init 呼叫（單人與伺服器都在所有 Lua 載完之後）
            r"public void init\(\)(?:(?!\n  \S)[\s\S])*?// String OnInitGlobalModData",
        ],
    },
    {
        "name": "MDFX_SledgehammerGuard（安裝：單人進場時才載 server/）",
        "class": "zombie.gameStates.GameLoadingState",
        "depends": [
            # GameLoadingState.java:149。OnGameBoot 在主選單就觸發過，所以復查不能掛它
            r"public void enter\(\);(?:(?!\n  \S)[\s\S])*?// String server\s+\d+: invokestatic\s+#\d+\s+"
            r"// Method zombie/Lua/LuaManager\.LoadDirBase:\(Ljava/lang/String;\)V",
        ],
    },
    {
        "name": "MDFX_SledgehammerGuard（依賴：物件的 component 數）",
        "class": "zombie.entity.GameEntity",
        "depends": [
            r"public final int componentSize\(\);",
        ],
    },
    {
        "name": "MDFX_SledgehammerGuard（前提：客戶端收到移除封包只移除那一個物件）",
        "class": "zombie.network.packets.RemoveItemFromSquarePacket",
        "depends": [
            # processClient（RemoveItemFromSquarePacket.java:75-97）：RemoveTileObject(o, 車庫門或雙扇門才整組)
            r"public void processClient\(zombie\.core\.raknet\.UdpConnection\);(?:(?!\n  \S)[\s\S])*?"
            r"// Method zombie/iso/IsoGridSquare\.RemoveTileObject:\(Lzombie/iso/IsoObject;Z\)I",
        ],
    },
    {
        "name": "MDFX_SledgehammerGuard（依賴：拒絕行的名稱）",
        "class": "zombie.characters.IsoPlayer",
        "depends": [
            r"public java\.lang\.String getUsername\(\);",
        ],
    },
]


def line_of(content, match):
    return content.count("\n", 0, match.start()) + 1


def javap_text(pz_home, cls):
    """反組譯 projectzomboid.jar 裡的類別；失敗時回 (None, 原因)。"""
    javap = shutil.which("javap")
    if not javap:
        return None, "PATH 上找不到 javap（需要 JDK 25 以上）"
    jar = os.path.join(pz_home, "projectzomboid.jar")
    proc = subprocess.run([javap, "-c", "-p", "-cp", jar, cls],
                          capture_output=True, text=True, encoding="utf-8", errors="replace")
    if proc.returncode != 0:
        lines = (proc.stderr or proc.stdout).strip().splitlines()
        return None, lines[0] if lines else f"javap exit {proc.returncode}"
    return proc.stdout, None


def main():
    pz_home = None
    if len(sys.argv) > 1:
        pz_home = sys.argv[1]
    pz_home = pz_home or os.environ.get("PZ_HOME") or DEFAULT_PZ_HOME
    pz_home = pz_home.rstrip("/\\")

    if not os.path.isdir(pz_home):
        print(f"FAIL  找不到 PZ 安裝目錄：{pz_home}")
        print("      用法：python scripts/check_vanilla_alignment.py <PZ安裝目錄>")
        return 1

    print(f"PZ 安裝目錄：{pz_home}")
    problems = 0

    for fix in FIXES:
        print(f"\n== {fix['name']} ==")
        if "class" in fix:
            content, why = javap_text(pz_home, fix["class"])
            if content is None:
                print(f"  MISSING  無法反組譯 {fix['class']}：{why}")
                print("           類別消失或 javap 不可用，需人工重新核對")
                problems += 1
                continue
        else:
            path = os.path.join(pz_home, fix["file"])
            if not os.path.isfile(path):
                print(f"  MISSING  vanilla 檔不存在：{fix['file']}")
                print("           修復目標整檔消失，需人工重新核對（線上會印 NOT installed）")
                problems += 1
                continue
            with open(path, "r", encoding="utf-8", errors="replace") as f:
                content = f.read()

        for pat in fix.get("crash", []):
            m = re.search(pat, content)
            if m:
                print(f"  OK       爆點仍在（:{line_of(content, m)}）— 修復仍有必要")
            else:
                print(f"  CHANGED  爆點形狀已變：/{pat}/")
                print("           官方可能已修或已重構——人工核對後決定退場或改寫")
                problems += 1

        for pat in fix.get("depends", []):
            m = re.search(pat, content)
            if m:
                print(f"  OK       依賴符號仍在（:{line_of(content, m)}）")
            else:
                print(f"  CHANGED  依賴符號消失：/{pat}/")
                print("           修復不會安裝（線上印 NOT installed），需要改寫")
                problems += 1

        for pat in fix.get("formula", []):
            m = re.search(pat, content)
            if m:
                print(f"  OK       公式係數未變（:{line_of(content, m)}）")
            else:
                print(f"  CHANGED  公式係數已變：/{pat}/ — fallback 公式要跟著更新")
                problems += 1

        for pat in fix.get("exithint", []):
            m = re.search(pat, content)
            if m:
                print(f"  NOTICE   vanilla 出現自帶防護跡象（:{line_of(content, m)}）：/{pat}/")
                print("           人工核對是否可讓本修復退場（見 docs/fixes.md 該節退場條件）")

        for pat in fix.get("retired", []):
            m = re.search(pat, content)
            if m:
                print(f"  OK       官方修正仍在（:{line_of(content, m)}）— 這條原版問題不必再由補丁承接")
            else:
                print(f"  CHANGED  官方修正形狀已變：/{pat}/")
                print("           人工核對官方是否撤回修正、補丁要不要復役")
                problems += 1

    print()
    if problems:
        print(f"共 {problems} 處需要人工處理。")
        return 1
    print(f"全部對齊：{len(FIXES)} 條指紋登記的 vanilla 前提都未變。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
