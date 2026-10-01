<!-- Steam 討論區貼文稿源（英文）；簡介只放摘要，詳細內容以本串為準 -->
<!-- 討論串網址：https://steamcommunity.com/workshop/filedetails/discussion/3790443858/586187095760095607/ -->
<!-- 標題：📖 Fixes Guide: Fix List & Details -->

[b]繁體中文版：[/b][url=https://steamcommunity.com/workshop/filedetails/discussion/3790443858/586187095760095585/]Fixes 完整說明：修正清單與原因[/url]

[h2]🚀 Quick start[/h2]
[list]
[*] Build 42.20.4+. Subscribe and enable; no settings, sandbox options or keys. In MP the server enables it.
[*] Vanilla bugs only; no balance changes, items or UI. Fixes act only where vanilla would error (plus two farming fixes against duplicate traffic and save overflow), are rechecked after game updates and removed once officially fixed.
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
[b]Scope[/b]: server, client and SP; the only fix needed on both sides. [b]Retired[/b]: once vanilla checks for a firearm.

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
[b]Symptom[/b]: in MP the watering action hangs at the end of its bar, the animal gets no water and none is used; meanwhile the server logs an error every 0.4 s until the player cancels, does something else, leaves, or the server restarts (up to 30 minutes).
[b]Cause[/b]: the server can't find the animal being watered (the two sides briefly disagree; the root cause is still being traced). Vanilla starts anyway and errors on every sip, so its "stop when full or out of water" check is never reached.
[b]Fix[/b]: on the first sip the server ends the action cleanly and the client cancels it; water and XP are untouched. One server log line per action records the player and position to help trace the cause (up to 20 per start). Normal watering is unchanged.
[b]Scope[/b]: MP server only. [b]Retired[/b]: when vanilla checks for a missing animal.

[h2]⚠️ Known limitations[/h2]
[list]
[*] While moved out, dead/rotten crops pause their slow change to the trampled look until someone returns. The only visible difference.
[*] Trimming covers only areas loaded and unloaded since this start; plots trampled before sowing never move out.
[*] Crop sync steps aside if another mod rewrote it (one log line); traps and campfires aren't covered.
[*] Milking and doors can error in SP too, but only MP cases are on record, so only MP is handled.
[*] Player-built house disconnect: a player who jumps more than one square in a single frame (teleport, lag correction, a very fast vehicle) onto such a square can still be disconnected.
[*] Broken corpses have other client-side error spots (e.g. trailer menu), not covered.
[*] Watering: leashing, tying to a tree, hand-feeding and loading into a trailer error only once in the same situation and aren't covered; the log line has no ID of the requested animal (lost when the server parses it).
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
[*] [b]Is a fix working?[/b] The log (server-console.txt on servers, console.txt in SP) shows [MinidoracatFixes] lines: one per fix per start when a problem is caught (the watering fix logs one per action, up to 20, to help trace the cause); "NOT installed" = a game update changed vanilla, fix paused; "NOT masking it" = unknown error. Report the last two.
[*] [b]Load order?[/b] Usually irrelevant: if a later mod replaces the same vanilla code, most fixes re-attach at startup and keep its changes; crop sync steps aside.
[*] [b]CleanUI inventory fix?[/b] Retired: CleanUI v2.7.9 fixed it; the patch stays dormant.
[*] [b]Trailer / multi-tile furniture debris fixes?[/b] Removed in 0.4.0, unmaintained.
[/list]

[h2]💬 Reporting[/h2]
[list]
[*] Every fix's cause, verification and retirement condition are public: [url=https://github.com/Minidoracat/MinidoracatFixesFor42/blob/main/docs/fixes.md]docs/fixes.md on GitHub[/url]
[*] New bug? [url=https://github.com/Minidoracat/MinidoracatFixesFor42/issues]GitHub Issues[/url] with steps and the log error, or [url=https://discord.gg/Gur2V67]Discord[/url].
[/list]
