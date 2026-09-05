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

用法（repo 根目錄）：
    python scripts/check_vanilla_alignment.py [PZ安裝目錄]
預設安裝目錄 D:/SteamLibrary/steamapps/common/ProjectZomboid，
也可用環境變數 PZ_HOME 覆蓋。

exit code：0 = 全部對齊；1 = 有 CHANGED / MISSING（需要人工處理）。
exithint 只提示不影響 exit code。
"""

import os
import re
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
]


def line_of(content, match):
    return content.count("\n", 0, match.start()) + 1


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
