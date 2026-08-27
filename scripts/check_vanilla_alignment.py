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
        "formula": [],
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
        "formula": [],
        "exithint": [
            # 官方若比照 ISLoadBulletsInMagazine:70-73 補上 guard
            r"if\s+not\s+self\.animal\s+then",
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

        for pat in fix["crash"]:
            m = re.search(pat, content)
            if m:
                print(f"  OK       爆點仍在（:{line_of(content, m)}）— 修復仍有必要")
            else:
                print(f"  CHANGED  爆點形狀已變：/{pat}/")
                print("           官方可能已修或已重構——人工核對後決定退場或改寫")
                problems += 1

        for pat in fix["depends"]:
            m = re.search(pat, content)
            if m:
                print(f"  OK       依賴符號仍在（:{line_of(content, m)}）")
            else:
                print(f"  CHANGED  依賴符號消失：/{pat}/")
                print("           修復不會安裝（線上印 NOT installed），需要改寫")
                problems += 1

        for pat in fix["formula"]:
            m = re.search(pat, content)
            if m:
                print(f"  OK       公式係數未變（:{line_of(content, m)}）")
            else:
                print(f"  CHANGED  公式係數已變：/{pat}/ — fallback 公式要跟著更新")
                problems += 1

        for pat in fix["exithint"]:
            m = re.search(pat, content)
            if m:
                print(f"  NOTICE   vanilla 出現自帶防護跡象（:{line_of(content, m)}）：/{pat}/")
                print("           人工核對是否可讓本修復退場（見 docs/fixes.md 該節退場條件）")

    print()
    if problems:
        print(f"共 {problems} 處需要人工處理。")
        return 1
    print("全部對齊：三條修復的 vanilla 前提都未變。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
