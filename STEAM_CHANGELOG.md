[h1]Minidoracat Fixes for B42 42.22.2-0.20.0[/h1]
[i]2026-11-12[/i]

[b]English summary[/b]
[list]
[*] When a recipe uses up a bag that still has items inside, those items are no longer lost: they are put back where the bag was (the same container, or the same spot on the ground).
[*] Seen in vanilla when building a Rain Collector Barrel with a filled Garbage Bag, and with Rip Sack on a filled Sack. It works for any build-menu or crafting recipe, including ones added by mods.
[*] The bag is still used up and the recipe still completes. Empty bags and bags that are not used up are untouched.
[*] Items are put back without a weight check, so your inventory can end up over its limit. Items that were already lost are not restored.
[*] Runs on the server in multiplayer (players do not need to do anything) and in your own game in single player.
[/list]

[h3]🔧 修正[/h3]
[list]
[*] [b]配方把還裝著東西的袋子當材料用掉時，袋裡的東西跟著消失[/b]：有些配方會把還裝著東西的袋子當成材料用掉，袋裡的東西也一起不見，沒有任何提示。例如蓋集雨桶（要 4 個垃圾袋）時用掉了裝著東西的垃圾袋，袋裡的其他東西、多帶的木板與釘子都不見；拆解麻袋時，麻袋裡的東西、連放在裡面的剪刀都不見。現在袋裡還有的東西會留下來。
[*] 東西放回袋子原本所在的地方：袋子在背包、箱子、車廂等容器裡，就回到那個容器；袋子在地上，就留在同一格地上。用右鍵選單製作時，原版會先把材料拿到身上再做，東西就留在主背包。
[*] 袋子本身照樣被用掉，配方照樣完成。建造選單與手工製作的所有配方都適用，MOD 加的配方也一樣；空袋與沒被用掉的袋子不受影響。
[*] 這是原版的問題，單人與多人都會發生。
[*] 東西放回去時不檢查負重，背包可能因此超重。機台自動製作不在範圍；已經消失的東西補不回來。
[*] 多人遊戲在伺服器執行，玩家不用另外做什麼；單人更新 MOD 後就生效。
[/list]
