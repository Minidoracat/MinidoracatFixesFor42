<!-- Steam 討論區貼文稿源（英文）；簡介只放摘要，詳細內容以本串為準 -->
<!-- 討論串網址：https://steamcommunity.com/workshop/filedetails/discussion/3790443858/586187095760095607/ -->
<!-- 標題：📖 Fixes Guide: Fix List & Details -->

[b]繁體中文版：[/b][url=https://steamcommunity.com/workshop/filedetails/discussion/3790443858/586187095760095585/]Fixes 完整說明：修正清單與原因[/url]

[h2]🚀 Quick start[/h2]
[list]
[*] Build 42.20.4+. Subscribe and enable; no settings, sandbox options or keys. In MP the server enables it.
[*] Vanilla bugs only; no balance changes, items or UI. Fixes act only where vanilla would error (plus two farming fixes against duplicate traffic and save overflow, one that stops vanilla from losing mod settings, and one that skips vanilla's needless per-frame recalculation for battery chargers), are rechecked after game updates and removed once officially fixed.
[/list]

[h2]🐛 Fix details[/h2]

[h3]1. Some animal corpses can never be butchered[/h3]
[b]Symptom[/b]: the full butchering action plays, no meat, the corpse stays; retries always fail.
[b]Cause[/b]: corpses of animals vanilla has no definition for (mostly from animal mods) are created without a meat-ratio field; butchering errors on it before giving meat.
[b]Fix[/b]: such corpses are rejected cleanly, logging the animal type to trace the source mod. No default is filled in (it would change yield); normal butchering is untouched.
[b]Scope[/b]: server, also SP. [b]Retired[/b]: only when vanilla stops making broken corpses [i]and[/i] handles existing ones.

[h3]2. Reload does nothing with a non-firearm in hand and an ammo strap[/h3]
[b]Symptom[/b]: holding e.g. a flashlight with an ammo strap (or fast-reload gear) worn, loading a magazine does nothing.
[b]Cause[/b]: vanilla's reload-speed math treats the held item as a gun and errors asking a non-firearm for its magazine type.
[b]Fix[/b]: only when vanilla errors and the item isn't a firearm, speed uses vanilla's no-strap formula (the strap bonus is for firearms). Other errors still surface; firearm reloads are unchanged.
[b]Scope[/b]: server, client and SP. [b]Retired[/b]: once vanilla checks for a firearm.

[h3]3. Server error when a petted animal just died or despawned[/h3]
[b]Symptom[/b]: in MP, if the animal dies, despawns or leaves sync range during the ~3 s of petting, the server logs an error.
[b]Cause[/b]: the server can't find the animal; petting lacks a check the magazine-loading action has.
[b]Fix[/b]: like vanilla's own code, the action ends cleanly and the client cancels it.
[b]Scope[/b]: MP server only. [b]Retired[/b]: when vanilla adds the check.

[h3]4. Actions get stuck when a tool breaks on its last swing (fixed officially in Build 42.21, retired)[/h3]
[b]Symptom[/b]: demolishing walls, clearing clutter or cutting bushes, if the tool breaks on that swing the action doesn't finish and the broken tool stays in hand.
[b]Cause[/b]: vanilla's broken-tool swap is client-only, so dedicated servers lack it, yet all three actions call it there.
[b]Fix[/b]: an equivalent server copy unequips the broken tool and draws the best usable weapon.
[b]Scope[/b]: dedicated server (SP and clients have it). [b]Retired[/b]: Build 42.21 moved the code to a shared file servers also load; this fix detects it and no longer adds its copy.

[h3]5. Milking produces nothing[/h3]
[b]Symptom[/b]: the animation plays, the bucket stays empty, the action hangs. Rare, but in bursts.
[b]Cause[/b]: vanilla checks the bucket exists, not that it still holds liquid.
[b]Fix[/b]: treated as "no usable container", ending the vanilla way; use another bucket. The animal isn't spooked by it (vanilla never got that far).
[b]Scope[/b]: MP server. [b]Retired[/b]: when vanilla checks the bucket holds liquid.

[h3]6. Liquid vanishes when pouring into another container[/h3]
[b]Symptom[/b]: the source loses liquid, the target gains none. The only fix here preventing real loss.
[b]Cause[/b]: vanilla drains the source, then fills the target, never checking the target.
[b]Fix[/b]: both must be liquid containers before either is touched, else nothing happens. Vanilla already requires this in SP, so nothing that works today is blocked.
[b]Scope[/b]: MP server. [b]Retired[/b]: when vanilla checks both sides first.

[h3]7. Server error when the clothing or furniture item is already gone[/h3]
[b]Symptom[/b]: in MP the item was already dropped, used or out of range; the server logs an error. The action failed anyway.
[b]Cause[/b]: vanilla lacks a missing-item check.
[b]Fix[/b]: the action ends cleanly; same result, no log spam.
[b]Scope[/b]: MP server only. [b]Retired[/b]: when vanilla adds the check.

[h3]8. Vehicle doors only lock halfway[/h3]
[b]Symptom[/b]: on some vehicles (incl. modded linked doors) locking or unlocking only affects the first few doors.
[b]Cause[/b]: at a seat part with no door vanilla means to print a note and stop, but the note itself errors; doors lock one by one, so it stops halfway.
[b]Fix[/b]: the vehicle is checked first; with such a part it stops as vanilla intended, touching no door rather than inventing new behavior.
[b]Scope[/b]: MP server. [b]Retired[/b]: when vanilla fixes that note.

[h3]9. The server keeps re-sending unchanged crop data near farmland[/h3]
[b]Symptom[/b]: server upload rises when players cross big farmland (about 3.4% in a one-minute sample).
[b]Cause[/b]: loading a map area sends every crop's data before players have the area, so it's discarded; every 10 in-game minutes unchanging plowed, dead and rotten crops are re-sent.
[b]Fix[/b]: sent only on change; watering, growth, trampling etc. still show at once, and fields other mods add sync too.
[b]Scope[/b]: MP server (SP never sends). [b]Retired[/b]: when vanilla compares before sending.

[h3]10. The farming save grows too large, gets wiped, and crops stop growing[/h3]
[b]Symptom[/b]: after a restart all farm data is gone; reappearing crops may not grow for years; trampled or harvested plots can't be cleared or plowed.
[b]Cause[/b]: vanilla keeps every crop ever loaded in the save, even dead and trampled ones. Past the engine's 10 MB limit the file comes out empty and the farming clock resets. Crops re-register with old-clock growth times (vanilla's recovery breaks after rain or watering); trampled/harvested ones are never recognized again.
[b]Fix[/b], three parts:
[list]
[*] [b]Move out[/b]: in empty areas, dead, rotten, trampled and harvested crops that the map can rebuild exactly and were unchanged over two checks leave the save (100 at a time), restored when someone returns; ones vanilla lost are re-registered too. Companion crops (onion, garlic etc.) stay.
[*] [b]Clock backup[/b]: saved every 10 in-game minutes, restored if the save can't be read.
[*] [b]Unstick[/b]: stuck crops resume at the next 10-minute check; growth is only moved earlier.
[/list]
[b]Scope[/b]: server and SP. [b]Retired[/b]: per part, once vanilla lifts the size limit, recognizes these crops on load, or stops resetting the clock.

[h3]11. Players near a player-built house get kicked back to the main menu after walls are removed or rebuilt (fixed officially in Build 42.21, retired)[/h3]
[b]Symptom[/b]: after someone removes or rebuilds a wall of a player-built house, nearby players (often several at once) are dropped to the main menu; it works again after reconnecting until someone builds nearby again. The player's console.txt shows an error about ParameterFirearmRoomSize / RoomDef.getArea(). ItemStats errors seen at the same time are unrelated noise.
[b]Cause[/b]: after walls or floors change, vanilla removes and rebuilds nearby player-built buildings but leaves some squares pointing at the room that no longer exists. Every frame each player's game asks how big the room under every visible player is (for gunshot sound); such a square throws, and vanilla then disconnects.
[b]Fix[/b]: right after a rebuild, or when a player steps onto a new square, the squares around each player are checked; any still pointing at a removed room is reset before the next frame to what vanilla should have given it (not in a room). Squares the map still marks as a room are never touched. Normally it costs one cheap comparison per player per frame. When it acts, console.txt shows [MinidoracatFixes] MDFX_StaleRoomGuard repaired square.
[b]Scope[/b]: runs in each player's game (and SP); the dedicated server doesn't run it. [b]Retired[/b]: Build 42.21 now updates those squares when rebuilding, so this fix finds nothing to repair there; it stays in the mod in case a later update breaks it again.

[h3]12. Watering an animal the server no longer knows makes the server error nonstop[/h3]
[b]Symptom[/b]: in MP the watering action hangs at the end of its bar; meanwhile the server logs an error every 0.4 s until the player cancels, does something else, leaves, or the server restarts (up to 30 minutes).
[b]Cause[/b]: the server can't find the animal being watered, or the player's water container (the two sides briefly disagree; the root cause is still being traced). Vanilla starts anyway and errors on every sip, so its "stop when full or out of water" check is never reached. With a missing container it's worse: each sip takes thirst off the animal before erroring, quenching it without using any water.
[b]Fix[/b]: on the first sip the server ends the action cleanly and the client cancels it; the animal, water and XP are untouched. One server log line per action records the player and position to help trace the cause (up to 20 per start). Normal watering is unchanged.
[b]Scope[/b]: MP server only. [b]Retired[/b]: when vanilla checks for a missing animal or container.

[h3]13. Leashing, tying, loading into a trailer or hand-feeding an animal the server no longer knows makes the server error[/h3]
[b]Symptom[/b]: in MP the action finishes without effect and the server logs an error.
[b]Cause[/b]: as above, the server can't find the animal. These four don't hang, but each errors once at the end; the action never happened anyway.
[b]Fix[/b]: the server rejects the action outright without the error, logging the player and position the same way (one line per action, up to 20 per start). Normal use is unchanged.
[b]Scope[/b]: MP server only. [b]Retired[/b]: each one separately, once vanilla adds its check.

[h3]14. Mod settings reset to defaults after a restart, or all vanish at once[/h3]
[b]Symptom[/b]: some mods' settings (ESC → Options → Mods) are back to defaults after a restart, or every mod's settings vanish at once. No error is shown.
[b]Cause[/b]: all mod settings share one file, one per line. When saving, vanilla writes back the settings of mods that aren't loaded right now without line breaks, gluing them into one line; the next read only sees the first entry, and the next save drops the rest for good. It happens when the main menu and a save enable different mods and you press Apply/Accept in the main menu. If no mod has settings in the main menu, Apply saves without reading the file first and empties it.
[b]Fix[/b]: each setting is saved on its own line; glued lines are split, checked and applied on load (left untouched if they can't be split cleanly); saving before anything was read keeps the settings already in the file. No setting value is changed, and mods that read/write settings themselves keep working.
[b]Scope[/b]: runs in each player's game (and SP); the dedicated server doesn't run it. To protect the main menu, enable this mod in the main-menu mod list too; in MP it works in-game only if the server enables it. [b]Retired[/b]: once vanilla saves line breaks and stops overwriting from an empty main menu.

[h3]15. Multiplayer: kicked back to the main menu when leaving a hen house[/h3]
[b]Symptom[/b]: in MP, walking, driving or teleporting away from a hen house with chickens drops you to the main menu without a message; reconnecting works, but it can happen again when you leave a hen house (seconds after joining or hours into a session). console.txt shows an error about IsoHutch.removeFromWorld / removeFromUpdateLists.
[b]Cause[/b]: since Build 42.21, when your game unloads a hen house it processes every slot's chicken without checking for empty slots, while vanilla's MP sync leaves empty slot records in your game whenever a chicken changes place (e.g. a hen going to a nest box to lay). Unloading hits an empty slot, errors, and vanilla disconnects.
[b]Fix[/b]: your game remembers nearby hen houses and clears empty slot records once per frame; chickens, nest boxes, eggs and slots holding a dead chicken are left alone. With no hen house nearby it does nothing; otherwise one cheap check per hen house per frame. Side effect: the "hutch full" check and the animal-zone count no longer count empty slots (vanilla counted them). When it acts, console.txt shows [MinidoracatFixes] MDFX_HutchNullSlotGuard removed null slot(s).
[b]Scope[/b]: each player's game in MP only; servers and SP aren't affected. Players get it when the server updates the mod. [b]Retired[/b]: once vanilla skips empty slots on unload, or its sync stops leaving them.

[h3]16. Multiplayer: a burst of crop-related errors right after joining a server[/h3]
[b]Symptom[/b]: right as you enter a server, an error window (e.g. Error Magnifier) pops up dozens of errors at once; play is normal afterwards and crops look fine. console.txt shows pairs of "already an object at" and "getModData of non-table" (CGlobalObject.lua, CPlantGlobalObject.lua) right after "Processing delayed packets".
[b]Cause[/b]: the server syncs crops, campfires, rain barrels, traps and feeding troughs two ways: a full list when your login is accepted, then one notice per addition or removal. But the server starts sending notices a second or two before the list, during login verification, so anything added in that gap is in both. Your game stores the notices while loading and handles them on entering; vanilla doesn't check whether the square already has the object before adding, so the duplicate errors. In vanilla this only happens if someone plants or builds a campfire in that second; this mod's farming-save fix (item 10) re-registers dead and trampled crops in bulk when an area loads, so someone driving past such a field while you log in means dozens at once.
[b]Fix[/b]: when your game gets an "add" for a square that already has that object, it keeps the existing one instead of erroring; the data the server sent is applied as in vanilla, so the result is identical to vanilla after its error, minus the error. When it acts, console.txt shows [MinidoracatFixes] MDFX_GosDuplicateNewGuard the server announced a new … object at … (once per session).
[b]Scope[/b]: each player's game (also loaded in SP, same behavior). Players get it when the server updates the mod. [b]Retired[/b]: once vanilla stops erroring on an "add" for an existing object, or the server stops sending notices before the player has the list.

[h3]17. Idle car battery chargers near a generator slow down the server and players[/h3]
[b]Symptom[/b]: when a car battery charger near a generator has no battery, or has one but is switched off, the server and every nearby player's game recompute that generator's power list every frame; the more chargers, generators and appliances, the worse. No error, just stutter around that base and higher server load. On a live server, a base with 10 chargers and 10 generators made up about 70% of a player's game memory allocation.
[b]Cause[/b]: vanilla switches an idle charger "off" again every frame (no battery, or no power), and every switch-off tells nearby generators to recompute, without checking that it was already off. Washers and dryers do check.
[b]Fix[/b]: switched-off chargers sit out the per-frame update (for them it does nothing but notify generators) and go back the moment they're switched on: right away when you switch one on, on the next frame after your game hears someone else did; taken or unloaded chargers are forgotten. Charging, its sound and the battery level behave exactly as in vanilla. When it acts, the log shows [MinidoracatFixes] MDFX_ChargerIdleGuard took an idle car battery charger … (once per session).
[b]Scope[/b]: server, each player's game and SP. Players get it when the server updates the mod. [b]Retired[/b]: once vanilla checks the charger's state before notifying generators.

[h2]⚠️ Known limitations[/h2]
[list]
[*] While moved out, dead/rotten crops pause their slow change to the trampled look until someone returns. Apart from the hen-house fix also correcting the "full" check, the only visible difference.
[*] Trimming covers only areas loaded and unloaded since this start; plots trampled before sowing never move out.
[*] Crop sync steps aside if another mod rewrote it (one log line); traps and campfires aren't covered.
[*] Milking and doors can error in SP too, but only MP cases are on record, so only MP is handled.
[*] Player-built house disconnect: a player who jumps more than one square in a single frame (teleport, lag correction, a very fast vehicle) onto such a square can still be disconnected.
[*] Broken corpses have other client-side error spots (e.g. trailer menu), not covered.
[*] Watering and the other animal actions: the log line has no ID of the requested animal (lost when the server parses it). Loading an animal into a trailer from your hands while the server thinks you hold an animal errors when the action is created; not covered.
[*] Mod settings already wiped or dropped by vanilla can't be recovered; set them again once.
[*] Hen house disconnect: an empty slot created in the very frame its hen house unloads (rare) still disconnects; slots that also hold a dead chicken aren't cleared, so the corpse isn't removed with them.
[*] Battery chargers: idle chargers no longer refresh nearby generators' power lists every frame; appliance switches, added/removed objects and area loads still do, same as a vanilla base without chargers.
[/list]

[h2]🧹 Before removing this mod[/h2]
[list]
[*] Other fixes only act on errors; removing brings back vanilla bugs.
[*] [b]Moved-out crops[/b]: trampled/harvested crops in areas nobody has returned to become vanilla orphans that can't be cleared or plowed. Revisited areas are already restored; vanilla re-registers dead/rotten ones.
[*] [b]Clock parts[/b]: a wiped farming save resets the clock again.
[/list]

[h2]❓ FAQ[/h2]
[list]
[*] [b]Items on corpses (e.g. a red digital watch) can't be picked up?[/b] Not covered or investigated yet; report on GitHub Issues with the item, a screenshot and log, noting if pure vanilla does it too.
[*] [b]Is a fix working?[/b] The log (server-console.txt on servers, console.txt in SP) shows [MinidoracatFixes] lines: one per fix per start when a problem is caught (the watering and animal-action fixes log one per action, up to 20 each, to help trace the cause; the mod-settings, hen-house and join-errors fixes log in the player's own console.txt, the battery-charger fix in both the server's and the player's); "NOT installed" = a game update changed vanilla, fix paused; "NOT masking it" = unknown error. Report the last two.
[*] [b]Load order?[/b] Usually irrelevant: if a later mod replaces the same vanilla code, most fixes re-attach at startup and keep its changes; crop sync steps aside.
[*] [b]CleanUI inventory fix?[/b] Retired: CleanUI v2.7.9 fixed it; the patch stays dormant.
[*] [b]Trailer / multi-tile furniture debris fixes?[/b] Removed in 0.4.0, unmaintained.
[/list]

[h2]💬 Reporting[/h2]
[list]
[*] Every fix's cause, verification and retirement condition are public: [url=https://github.com/Minidoracat/MinidoracatFixesFor42/blob/main/docs/fixes.md]docs/fixes.md on GitHub[/url]
[*] New bug? [url=https://github.com/Minidoracat/MinidoracatFixesFor42/issues]GitHub Issues[/url] with steps and the log error, or [url=https://discord.gg/Gur2V67]Discord[/url].
[/list]
