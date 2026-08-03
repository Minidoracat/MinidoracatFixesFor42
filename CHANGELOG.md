# Changelog

## [42.20.0-0.1.0] - 2026-08-04

首版。

### 新增

- **MDFX_AnimalTrailerSize**：修復動物屍體缺 `animalTrailerSize` modData 欄位時，
  拖車動物門開著右鍵載具會讓**整段車輛右鍵選單消失**、死掉的動物裝不上拖車。

  原版 `ISVehicleMenu.doAnimalSubMenu`（42.20 第 755 / 806 行）把該欄位直接餵給
  `round()`，缺欄位時 `nil * mult` 拋 `__mul not defined for operands`，
  炸掉的是 `OnFillWorldObjectContextMenu` 上的 `ISVehicleMenu.FillMenuOutsideVehicle`
  整條鏈。欄位缺失的源頭是 `ButcheringUtil.setAnimalBodyData()` 第 27 行對
  `AnimalPartsDefinitions` 的 def 無條件解參考（第 19 行才剛判斷過它可能是 nil），
  在寫入 `animalTrailerSize` 之前就拋錯，而 Java 端是 protectedCall 吞掉錯誤後
  照樣寫 `animalType`——屍體於是成為「是動物、但缺欄位」的永久壞資料。

  修法為呼叫原版函式前補回 `trailerBaseSize × animalSize`（與 Java
  `IsoAnimal.getAnimalTrailerSize()` 同式），已有數值不覆蓋，補資料全程 `pcall` 保護。
  詳見 [docs/fixes.md](docs/fixes.md)。

  > 玩家回報 + `console (14).txt` 33 次同一堆疊佐證。
  > 離線測試：`scripts/test_animal_trailer_size.lua`（7 項檢查）。
