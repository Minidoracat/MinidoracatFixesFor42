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
        "name": "MDFX_WorldObjectCheckWeapon（vanilla 本體）",
        "file": "media/lua/client/ISUI/ISWorldObjectContextMenu.lua",
        "crash": [
            # 本補丁複製的就是這個函式本體；它還在 client/ 就代表 server 上仍然缺席
            r"ISWorldObjectContextMenu\.checkWeapon = function\(chr\)",
        ],
        "depends": [
            # 逐行等價的實作面：這些行變了就要同步改寫補丁裡的副本
            r"if not weapon or weapon:getCondition\(\) <= 0 then",
            r"weapon = chr:getInventory\(\):getBestWeapon\(chr:getDescriptor\(\)\)",
            r"if weapon:isTwoHandWeapon\(\) and not chr:getSecondaryHandItem\(\) then",
            # 官方自己就預期它會在 server 端執行（本補丁的立論依據）
            r"sendServerCommand\(chr, 'ui', 'dirtyUI', \{ \}\);",
        ],
    },
    {
        "name": "MDFX_WorldObjectCheckWeapon（呼叫點 ISDestroyStuffAction）",
        "file": "media/lua/shared/TimedActions/ISDestroyStuffAction.lua",
        "crash": [
            # :311-312 complete 尾段，damageCheck 為真時無條件呼叫 client-only 全域
            r"if sledge and sledge:damageCheck\(0,2,false\) then\s*\n\s*ISWorldObjectContextMenu\.checkWeapon\(self\.character\)",
        ],
        "exithint": [
            # 官方若自己加了存在檢查
            r"if ISWorldObjectContextMenu",
        ],
    },
    {
        "name": "MDFX_WorldObjectCheckWeapon（呼叫點 ISPickUpGroundCoverItem）",
        "file": "media/lua/shared/TimedActions/ISPickUpGroundCoverItem.lua",
        "crash": [
            r"if self\.weapon and self\.weapon:damageCheck\(0,4,false\) then\s*\n\s*ISWorldObjectContextMenu\.checkWeapon\(self\.character\)",
        ],
        "exithint": [
            r"if ISWorldObjectContextMenu",
        ],
    },
    {
        "name": "MDFX_WorldObjectCheckWeapon（呼叫點 ISRemoveBush）",
        "file": "media/lua/shared/TimedActions/ISRemoveBush.lua",
        "crash": [
            r"if self\.weapon and self\.weapon:damageCheck\(0,4,false\) then\s*\n\s*ISWorldObjectContextMenu\.checkWeapon\(self\.character\)",
        ],
        "exithint": [
            r"if ISWorldObjectContextMenu",
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
        "name": "MDFX_StaleRoomGuard（成因：WorldRegionToMetaGrid）",
        "class": "zombie.iso.areas.isoregion.metagrid.WorldRegionToMetaGrid",
        "crash": [
            # removeIsoRoom（:432-434）把被移除房間的 def 設成 null
            r"private void removeIsoRoom\(zombie\.iso\.areas\.IsoRoom, boolean\);(?:(?!\n  \S)[\s\S])*?"
            r"aconst_null\s+\d+: putfield\s+#\d+\s+// Field zombie/iso/areas/IsoRoom\.def:Lzombie/iso/RoomDef;",
            # updateSquares（:601-610）只重設 chunkIsDirty 的區塊
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

    print()
    if problems:
        print(f"共 {problems} 處需要人工處理。")
        return 1
    print(f"全部對齊：{len(FIXES)} 條指紋登記的 vanilla 前提都未變。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
