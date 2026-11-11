<!-- 指南網址：https://steamcommunity.com/sharedfiles/filedetails/?id=3817840467 -->
<!-- Steam guide source (English): the full reference for this mod; the Workshop description only summarizes. Format and sync: pz-family-docs/release.md「完整說明：Steam 指南」 -->
<!-- 標題：📖 Fixes Mod Guide: Fix List & Details -->
<!-- 摘要：Guide to the Minidoracat Fixes mod: every vanilla bug fix it includes (symptom, cause, fix, scope and when it retires), known limitations, what to know before removing it, and FAQ. -->
=== 🚀 Quick start
[b]繁體中文版：[/b][url=https://steamcommunity.com/sharedfiles/filedetails/?id=3817840419]修正合集 MOD 完整說明[/url]

The mod on Steam Workshop:
https://steamcommunity.com/sharedfiles/filedetails/?id=3790443858
[list]
[*] [b]Requires[/b]: Build 42.20.4+.
[*] [b]Install[/b]: subscribe and enable; no settings, sandbox options or keys. In MP the server enables it.
[*] [b]Vanilla bugs only[/b]: no balance changes, items or UI.
[*] [b]Acts only where vanilla would error[/b]: plus two farming fixes against duplicate traffic and save overflow, one that stops vanilla from losing mod settings, one that skips vanilla's needless per-frame recalculation for battery chargers, one that has the server handle multiplayer deaths it missed, one that puts a vehicle back above the ground after it dropped below it, one that puts a character back where it stood after it dropped outside the basement walls, one that lets a window vanilla misjudged go back on its wall, one that has the server clear a worn item it left behind after you placed it on the ground, and one that strengthens the server's validation of the health cheat.
[*] [b]Rechecked after game updates[/b]: fixes are removed once officially fixed.
[/list]
=== 🧰 Animals: butchering, petting, milking, watering, leashing
[h3]Some animal corpses can never be butchered[/h3]
[list]
[*] [b]Symptom[/b]: the full butchering action plays, no meat, the corpse stays; retries always fail.
[*] [b]Cause[/b]: corpses of animals vanilla has no definition for (mostly from animal mods) are created without a meat-ratio field; butchering errors on it before giving meat.
[*] [b]Fix[/b]: such corpses are rejected cleanly, logging the animal type to trace the source mod. No default is filled in (it would change yield); normal butchering is untouched.
[*] [b]Scope[/b]: server, also SP.
[*] [b]Retired[/b]: only when vanilla stops making broken corpses [i]and[/i] handles existing ones.
[/list]
[h3]Server error when a petted animal just died or despawned[/h3]
[list]
[*] [b]Symptom[/b]: in MP, if the animal dies, despawns or leaves sync range during the ~3 s of petting, the server logs an error.
[*] [b]Cause[/b]: the server can't find the animal; petting lacks a check the magazine-loading action has.
[*] [b]Fix[/b]: like vanilla's own code, the action ends cleanly and the client cancels it.
[*] [b]Scope[/b]: MP server only.
[*] [b]Retired[/b]: when vanilla adds the check.
[/list]
[h3]Milking produces nothing[/h3]
[list]
[*] [b]Symptom[/b]: the animation plays, the bucket stays empty, the action hangs. Rare, but in bursts.
[*] [b]Cause[/b]: vanilla checks the bucket exists, not that it still holds liquid.
[*] [b]Fix[/b]: treated as "no usable container", ending the vanilla way; use another bucket. The animal isn't spooked by it (vanilla never got that far).
[*] [b]Scope[/b]: MP server.
[*] [b]Retired[/b]: when vanilla checks the bucket holds liquid.
[/list]
[h3]Watering an animal the server no longer knows makes the server error nonstop[/h3]
[list]
[*] [b]Symptom[/b]: in MP the watering action hangs at the end of its bar; meanwhile the server logs an error every 0.4 s until the player cancels, does something else, leaves, or the server restarts (up to 30 minutes).
[*] [b]Cause[/b]: the server can't find the animal being watered, or the player's water container (the two sides briefly disagree; the root cause is still being traced). Vanilla starts anyway and errors on every sip, so its "stop when full or out of water" check is never reached. With a missing container it's worse: each sip takes thirst off the animal before erroring, quenching it without using any water.
[*] [b]Fix[/b]: on the first sip the server ends the action cleanly and the client cancels it; the animal, water and XP are untouched. One server log line per action records the player and position to help trace the cause (up to 20 per start). Normal watering is unchanged.
[*] [b]Scope[/b]: MP server only.
[*] [b]Retired[/b]: when vanilla checks for a missing animal or container.
[/list]
[h3]Leashing, tying, loading into a trailer or hand-feeding an animal the server no longer knows makes the server error[/h3]
[list]
[*] [b]Symptom[/b]: in MP the action finishes without effect and the server logs an error.
[*] [b]Cause[/b]: as with watering, the server can't find the animal. These four don't hang, but each errors once at the end; the action never happened anyway.
[*] [b]Fix[/b]: the server rejects the action outright without the error, logging the player and position the same way (one line per action, up to 20 per start). Normal use is unchanged.
[*] [b]Scope[/b]: MP server only.
[*] [b]Retired[/b]: each one separately, once vanilla adds its check.
[/list]
=== 🧰 Items & actions: reloading, tools, pouring, clothing, doors
[h3]Reload does nothing: non-firearm in hand with an ammo strap, or revolvers and shotguns with a shoulder holster or chest rig[/h3]
[list]
[*] [b]Symptom[/b]: holding e.g. a flashlight with an ammo strap (or fast-reload gear) worn, loading a magazine does nothing. Since Build 42.22, wearing a shoulder holster, chest rig or ALICE belt without an ammo strap, reloading a revolver, shotgun or other gun without a magazine errors at once and loads nothing.
[*] [b]Cause[/b]: vanilla's reload-speed math treats the held item as a gun and errors asking a non-firearm for its magazine type. Since 42.22 it also checks worn fast-reload gear, then reads the ammo strap even when none is worn.
[*] [b]Fix[/b]: only when vanilla errors in one of these two ways, speed uses vanilla's no-strap formula (vanilla gives no strap bonus in either case). Other errors still surface; other reloads are unchanged.
[*] [b]Scope[/b]: server, client and SP.
[*] [b]Retired[/b]: once vanilla checks for a firearm and for a worn ammo strap; each case is removed on its own.
[/list]
[h3]Actions get stuck when a tool breaks on its last swing (fixed officially in Build 42.21, retired)[/h3]
[list]
[*] [b]Symptom[/b]: demolishing walls, clearing clutter or cutting bushes, if the tool breaks on that swing the action doesn't finish and the broken tool stays in hand.
[*] [b]Cause[/b]: vanilla's broken-tool swap is client-only, so dedicated servers lack it, yet all three actions call it there.
[*] [b]Fix[/b]: an equivalent server copy unequips the broken tool and draws the best usable weapon.
[*] [b]Scope[/b]: dedicated server (SP and clients have it).
[*] [b]Retired[/b]: Build 42.21 moved the code to a shared file servers also load; this fix detects it and no longer adds its copy.
[/list]
[h3]Liquid vanishes when pouring into another container[/h3]
[list]
[*] [b]Symptom[/b]: the source loses liquid, the target gains none. The only fix here preventing real loss.
[*] [b]Cause[/b]: vanilla drains the source, then fills the target, never checking the target.
[*] [b]Fix[/b]: both must be liquid containers before either is touched, else nothing happens. Vanilla already requires this in SP, so nothing that works today is blocked.
[*] [b]Scope[/b]: MP server.
[*] [b]Retired[/b]: when vanilla checks both sides first.
[/list]
[h3]Server error when the clothing or furniture item is already gone[/h3]
[list]
[*] [b]Symptom[/b]: in MP the item was already dropped, used or out of range; the server logs an error. The action failed anyway.
[*] [b]Cause[/b]: vanilla lacks a missing-item check.
[*] [b]Fix[/b]: the action ends cleanly; same result, no log spam.
[*] [b]Scope[/b]: MP server only.
[*] [b]Retired[/b]: when vanilla adds the check.
[/list]
[h3]Vehicle doors only lock halfway[/h3]
[list]
[*] [b]Symptom[/b]: on some vehicles (incl. modded linked doors) locking or unlocking only affects the first few doors.
[*] [b]Cause[/b]: at a seat part with no door vanilla means to print a note and stop, but the note itself errors; doors lock one by one, so it stops halfway.
[*] [b]Fix[/b]: the vehicle is checked first; with such a part it stops as vanilla intended, touching no door rather than inventing new behavior.
[*] [b]Scope[/b]: MP server.
[*] [b]Retired[/b]: when vanilla fixes that note.
[/list]
[h3]New Build 42 windows can't be put back on a north wall[/h3]
[list]
[*] [b]Symptom[/b]: windows from the four window sets added in Build 42, taken off a north wall with a crowbar, always show red when you point them back at their own frame. The frame is still there and you have the skill and a hammer. Older windows are fine.
[*] [b]Cause[/b]: to pick the wall, vanilla also wants the tile to have "other face" data. Each new set shares one name across about a hundred tiles, and the game only builds that data for groups of four or fewer, so these have none; a north window is treated as a west one and vanilla looks for a west-wall frame.
[*] [b]Fix[/b]: when vanilla refuses a north window, it is asked again as a north-wall window and allowed if that passes. The frame, existing-window, skill and tool checks are still vanilla's; anything vanilla already allowed is unchanged.
[*] [b]Log[/b]: the first time per start, one line [MinidoracatFixes] MDFX_WindowFaceGuard: vanilla refused north-facing window … (in MP, one in the server's server-console.txt and one in the player's console.txt).
[*] [b]Scope[/b]: SP, MP server and each player's game (in MP the server checks placement again, so both sides need it).
[*] [b]Retired[/b]: once vanilla gives these sets their face data or changes that check; vanilla then allows it itself and this fix stops acting.
[/list]
=== 🧰 Crops: sync traffic, the farming save, join errors
[h3]The server keeps re-sending unchanged crop data near farmland[/h3]
[list]
[*] [b]Symptom[/b]: server upload rises when players cross big farmland (about 3.4% in a one-minute sample).
[*] [b]Cause[/b]: loading a map area sends every crop's data before players have the area, so it's discarded; every 10 in-game minutes unchanging plowed, dead and rotten crops are re-sent.
[*] [b]Fix[/b]: sent only on change; watering, growth, trampling etc. still show at once, and fields other mods add sync too.
[*] [b]Scope[/b]: MP server (SP never sends).
[*] [b]Retired[/b]: when vanilla compares before sending.
[/list]
[h3]The farming save grows too large, gets wiped, and crops stop growing[/h3]
[list]
[*] [b]Symptom[/b]: after a restart all farm data is gone; reappearing crops may not grow for years; trampled or harvested plots can't be cleared or plowed.
[*] [b]Cause[/b]: vanilla keeps every crop ever loaded in the save, even dead and trampled ones. Past the engine's 10 MB limit the file comes out empty and the farming clock resets. Crops re-register with old-clock growth times (vanilla's recovery breaks after rain or watering); trampled/harvested ones are never recognized again.
[*] [b]Fix[/b], three parts:
[list]
[*] [b]Move out[/b]: in empty areas, dead, rotten, trampled and harvested crops that the map can rebuild exactly and were unchanged over two checks leave the save (100 at a time), restored when someone returns; ones vanilla lost are re-registered too. Companion crops (onion, garlic etc.) stay.
[*] [b]Clock backup[/b]: saved every 10 in-game minutes, restored if the save can't be read.
[*] [b]Unstick[/b]: stuck crops resume at the next 10-minute check; growth is only moved earlier.
[/list]
[*] [b]Scope[/b]: server and SP.
[*] [b]Retired[/b]: per part, once vanilla lifts the size limit, recognizes these crops on load, or stops resetting the clock.
[/list]
[h3]Multiplayer: a burst of crop-related errors right after joining a server[/h3]
[list]
[*] [b]Symptom[/b]: right as you enter a server, an error window (e.g. Error Magnifier) pops up dozens of errors at once; play is normal afterwards and crops look fine. console.txt shows pairs of "already an object at" and "getModData of non-table" (CGlobalObject.lua, CPlantGlobalObject.lua) right after "Processing delayed packets".
[*] [b]Cause[/b]: the server syncs crops, campfires, rain barrels, traps and feeding troughs two ways: a full list when your login is accepted, then one notice per addition or removal. But the server starts sending notices a second or two before the list, during login verification, so anything added in that gap is in both. Your game stores the notices while loading and handles them on entering; vanilla doesn't check whether the square already has the object before adding, so the duplicate errors.
[*] [b]Why it's common[/b]: in vanilla this only happens if someone plants or builds a campfire in that second; this mod's farming-save fix (above) re-registers dead and trampled crops in bulk when an area loads, so someone driving past such a field while you log in means dozens at once.
[*] [b]Fix[/b]: when your game gets an "add" for a square that already has that object, it keeps the existing one instead of erroring; the data the server sent is applied as in vanilla, so the result is identical to vanilla after its error, minus the error.
[*] [b]Log[/b]: when it acts, console.txt shows [MinidoracatFixes] MDFX_GosDuplicateNewGuard the server announced a new … object at … (once per session).
[*] [b]Scope[/b]: each player's game (also loaded in SP, same behavior). Players get it when the server updates the mod.
[*] [b]Retired[/b]: once vanilla stops erroring on an "add" for an existing object, or the server stops sending notices before the player has the list.
[/list]
=== 🧰 Kicked to the main menu: player-built houses & hen houses
[h3]Players near a player-built house get kicked back to the main menu after walls are removed or rebuilt (fixed officially in Build 42.21, retired)[/h3]
[list]
[*] [b]Symptom[/b]: after someone removes or rebuilds a wall of a player-built house, nearby players (often several at once) are dropped to the main menu; it works again after reconnecting until someone builds nearby again. The player's console.txt shows an error about ParameterFirearmRoomSize / RoomDef.getArea(). ItemStats errors seen at the same time are unrelated noise.
[*] [b]Cause[/b]: after walls or floors change, vanilla removes and rebuilds nearby player-built buildings but leaves some squares pointing at the room that no longer exists. Every frame each player's game asks how big the room under every visible player is (for gunshot sound); such a square throws, and vanilla then disconnects.
[*] [b]Fix[/b]: right after a rebuild, or when a player steps onto a new square, the squares around each player are checked; any still pointing at a removed room is reset before the next frame to what vanilla should have given it (not in a room). Squares the map still marks as a room are never touched. Normally it costs one cheap comparison per player per frame.
[*] [b]Log[/b]: when it acts, console.txt shows [MinidoracatFixes] MDFX_StaleRoomGuard repaired square.
[*] [b]Scope[/b]: runs in each player's game (and SP); the dedicated server doesn't run it.
[*] [b]Retired[/b]: Build 42.21 now updates those squares when rebuilding, so this fix finds nothing to repair there; it stays in the mod in case a later update breaks it again.
[/list]
[h3]Multiplayer: kicked back to the main menu when leaving a hen house[/h3]
[list]
[*] [b]Symptom[/b]: in MP, walking, driving or teleporting away from a hen house with chickens drops you to the main menu without a message; reconnecting works, but it can happen again when you leave a hen house (seconds after joining or hours into a session). console.txt shows an error about IsoHutch.removeFromWorld / removeFromUpdateLists.
[*] [b]Cause[/b]: since Build 42.21, when your game unloads a hen house it processes every slot's chicken without checking for empty slots, while vanilla's MP sync leaves empty slot records in your game whenever a chicken changes place (e.g. a hen going to a nest box to lay). Unloading hits an empty slot, errors, and vanilla disconnects.
[*] [b]Fix[/b]: your game remembers nearby hen houses and clears empty slot records once per frame; chickens, nest boxes, eggs and slots holding a dead chicken are left alone. With no hen house nearby it does nothing; otherwise one cheap check per hen house per frame.
[*] [b]Side effect[/b]: the "hutch full" check and the animal-zone count no longer count empty slots (vanilla counted them).
[*] [b]Log[/b]: when it acts, console.txt shows [MinidoracatFixes] MDFX_HutchNullSlotGuard removed null slot(s).
[*] [b]Scope[/b]: each player's game in MP only; servers and SP aren't affected. Players get it when the server updates the mod.
[*] [b]Build 42.22[/b]: vanilla fixed the disconnect on unload; the empty slot records are still left behind. This fix stays and keeps clearing them, so the "hutch full" check and the animal count stay correct.
[*] [b]Retired[/b]: once vanilla's MP sync stops leaving empty slot records.
[/list]
=== 🧰 Mod settings & battery charger performance
[h3]Mod settings reset to defaults after a restart, or all vanish at once[/h3]
[list]
[*] [b]Symptom[/b]: some mods' settings (ESC → Options → Mods) are back to defaults after a restart, or every mod's settings vanish at once. No error is shown.
[*] [b]Cause[/b]: all mod settings share one file, one per line. When saving, vanilla writes back the settings of mods that aren't loaded right now without line breaks, gluing them into one line; the next read only sees the first entry, and the next save drops the rest for good.
[*] [b]When it happens[/b]: the main menu and a save enable different mods and you press Apply/Accept in the main menu. If no mod has settings in the main menu, Apply saves without reading the file first and empties it.
[*] [b]Fix[/b]: each setting is saved on its own line; glued lines are split, checked and applied on load (left untouched if they can't be split cleanly); saving before anything was read keeps the settings already in the file. A copy of the file is also kept (Zomboid/Lua/ModOptions_MDFX_backup.ini): if a mod has no settings left in the file on load but the copy has them, they're put back. No setting value is changed, and mods that read/write settings themselves keep working.
[*] [b]Scope[/b]: runs in each player's game (and SP); the dedicated server doesn't run it. Without this mod in the main menu, Apply there still empties the file, and the settings come back from the copy the next time you load into a game with this mod; in MP the server must enable it. Settings are still one set shared by every save and server.
[*] [b]Retired[/b]: once vanilla saves line breaks and stops overwriting from an empty main menu.
[/list]
[h3]Idle car battery chargers near a generator slow down the server and players[/h3]
[list]
[*] [b]Symptom[/b]: when a car battery charger near a generator has no battery, or has one but is switched off, the server and every nearby player's game recompute that generator's power list every frame; the more chargers, generators and appliances, the worse. No error, just stutter around that base and higher server load. On a live server, a base with 10 chargers and 10 generators made up about 70% of a player's game memory allocation.
[*] [b]Cause[/b]: vanilla switches an idle charger "off" again every frame (no battery, or no power), and every switch-off tells nearby generators to recompute, without checking that it was already off. Washers and dryers do check.
[*] [b]Fix[/b]: switched-off chargers sit out the per-frame update (for them it does nothing but notify generators) and go back the moment they're switched on: right away when you switch one on, on the next frame after your game hears someone else did; taken or unloaded chargers are forgotten. Charging, its sound and the battery level behave exactly as in vanilla.
[*] [b]Log[/b]: when it acts, the log shows [MinidoracatFixes] MDFX_ChargerIdleGuard took an idle car battery charger … (once per session).
[*] [b]Scope[/b]: server, each player's game and SP. Players get it when the server updates the mod.
[*] [b]Retired[/b]: once vanilla checks the charger's state before notifying generators.
[/list]
=== 🧰 Multiplayer deaths: black screen, no body
[h3]Multiplayer: after being dragged down by zombies, the screen stays black, respawning doesn't work and the body is gone[/h3]
[list]
[*] [b]Symptom[/b]: after dying in MP (most often when dragged down by several zombies in a horde), the screen goes black with only the chat box and other UI left, and pressing Respawn just keeps it black. After reconnecting, sometimes the old character is still alive, sometimes you have to make a new one, and there is no body at the death spot, so all gear is lost.
[*] [b]Cause[/b]: in vanilla MP, a drag-down death is decided by your own game; the server only follows when it also receives that zombie's bite and works out the drag-down itself, which occasionally doesn't happen (e.g. when many players fight the same group of zombies). The server thinks the character is still alive and refuses the respawn, hence the black screen.
[*] [b]Fix[/b]: your game tells the server when it decides you died; if the character is still alive on the server, it's handled like a normal death: the death is recorded, the body stays at the death spot with your gear, and respawning works. Deaths the server already handled are untouched; it can only affect the player's own character. Characters younger than 30 seconds are skipped, so a late message from before a respawn can't hit the new character.
[*] [b]Difference from vanilla[/b]: vanilla sometimes brings the old character back after reconnecting; now it always counts as a death, matching what you saw on screen.
[*] [b]Log[/b]: each death it handles adds one line to the server's server-console.txt: [MinidoracatFixes] MDFX_DeathSync processed a death the server missed: player="<name>" …; each late message it skips adds … ignored a death report … (up to 20 each per start).
[*] [b]Scope[/b]: MP only; the server and every player's game need it (same file). Players get it when the server updates the mod. Does nothing in SP.
[*] [b]Retired[/b]: once the vanilla server handles these deaths itself.
[/list]
=== 🧰 Multiplayer driving: vehicle drops below the ground
[h3]Multiplayer: your vehicle drops below the ground while driving: black screen, the car stays stuck underground, even after relogging[/h3]
[list]
[*] [b]Symptom[/b]: while driving in MP (often at speed, after a crash, or right after the game snaps you back), the screen suddenly goes black with only the UI and minimap left; after getting out, the car sits below the ground and can't be reached, and relogging doesn't help.
[*] [b]Cause[/b]: in MP a vehicle's physics run in the driver's own game, and the server accepts whatever height it reports. When the car ends up below the floor, vanilla never puts it back; the camera follows the car, hence the black screen. The server saves that height too, so relogging gives you the same buried car.
[*] [b]Fix[/b]: every frame your game checks the vehicles it is simulating (the one you drive, or one you just hit while driving). If one is more than 25 cm below the floor of its level and that square has a floor, it is put back above the ground at once, same spot and heading, and the correct height goes to the server. A car that is upside down and more than one level down is set upright first; a flipped car still near the ground is left alone.
[*] [b]Log[/b]: each time, the player's console.txt gets one line: [MinidoracatFixes] MDFX_VehicleSinkGuard vehicle … lifted to … (up to 20 per start).
[*] [b]Scope[/b]: only in each player's own game in MP. Players get it when the server updates the mod. Does nothing in SP.
[*] [b]Retired[/b]: once vanilla puts sunken vehicles back itself, or the server stops accepting heights below the floor.
[/list]
=== 🧰 A bag placed on the ground is still worn
[h3]After you place a worn bag or clothing item on the ground, it still shows on your character until you relog[/h3]
[list]
[*] [b]Symptom[/b]: you right-click a bag (or clothing) you are wearing and choose Place Item: the bag is on the ground, but it is still drawn on your back and the hotbar slots it gave you stay, until you relog (in SP, until you reload your save). Most likely with a mod that swaps your character's appearance (transmog-style) turned on; in SP it only happens with such a mod. Drop and Unequip from the right-click menu are not affected.
[*] [b]Cause[/b]: when you place an item, your own game decides at that moment whether to take it off first; the placing step only puts the item on the ground and never clears it from what you wear. If your game decides wrong at that moment (for example an appearance mod has just swapped your worn items for display copies), the game (in MP, both the server and your game) keeps thinking you wear it.
[*] [b]Fix[/b]: once a second, what each player wears is checked (in MP the server checks every player; in SP your own game does). If a worn item is already on the ground or inside another container on two checks in a row, it is taken off, and in MP every player's game is told: within a second or two the bag on your back and its hotbar slots are gone. Normal wearing, taking off, swapping and dropping are unchanged.
[*] [b]Log[/b]: each time, the server's server-console.txt (console.txt in SP) gets one line: [MinidoracatFixes] MDFX_StaleWornGuard removed stale worn item … from player="<name>" … (up to 20 per start).
[*] [b]Scope[/b]: in MP it runs on the server and takes effect once the server updates the mod and restarts; in SP it takes effect once you update the mod.
[*] [b]Retired[/b]: once vanilla (in SP and on servers) clears worn items itself when they leave your inventory, and servers stop re-creating worn items from the list your game sends.
[/list]
=== 🧰 A boulder with missing pieces can't be destroyed
[h3]Large objects with missing pieces (for example a boulder that only half spawned) can't be destroyed with a sledgehammer[/h3]
[list]
[*] [b]Symptom[/b]: an object that covers several squares (a 2x2 boulder, a two-square bench and the like) is missing some of its pieces. You hit what is left with a sledgehammer: the cursor is green, the action finishes, the sledgehammer wears as usual, but the object stays and no message appears, however often you try. Happens in SP and MP; the usual case is a boulder that only half spawned when the map was generated.
[*] [b]Cause[/b]: when the game removes an object that covers several squares, it first looks for every piece of the set around it; if any piece is missing it removes nothing, yet the sledgehammer action still counts as done.
[*] [b]Fix[/b]: when the sledgehammer action finished and the game allowed it, but the object is still there, the game is asked once more the vanilla way; if the set still can't be found, only the piece you hit is removed. Hit the other pieces one by one. Complete large objects are still destroyed as a whole, as in vanilla; without a sledgehammer, on servers that only allow sledgehammers in safehouses, or when another mod doesn't let you destroy it, nothing changes.
[*] [b]Log[/b]: the first time per start, the server's server-console.txt (console.txt in SP) gets one line: [MinidoracatFixes] MDFX_SledgehammerGuard vanilla left <tile> at <x>,<y>,<z> standing after a sledgehammer hit ….
[*] [b]Scope[/b]: in MP it runs on the server and takes effect once the server updates the mod and restarts; in SP it takes effect once you update the mod.
[*] [b]Retired[/b]: once vanilla lets you destroy large objects with missing pieces with a sledgehammer.
[/list]
=== 🧰 Dropped outside the basement walls
[h3]With the wall beside a staircase knocked down, stepping onto the stairs from the side drops you outside the basement walls[/h3]
[list]
[*] [b]Symptom[/b]: in some houses the basement stairs sit right below the stairs going up. After the wall beside the staircase is knocked down with a sledgehammer, walking onto the top of the stairs from the next room makes the character drop, take a little fall damage, and end up outside the basement walls. There is no floor there, the walls can't be entered from outside, so there is no way back; relogging leaves you in the same spot. Happens in SP and MP, mostly at low frame rates (around 30 FPS) or when sprinting.
[*] [b]Cause[/b]: when a character steps onto a square with stairs, the game shortens that step a little. A step that would just cross onto the stairs is shortened so the character has not actually crossed yet, but the game already takes the height from the stairs. In these houses the square below the top of the stairs is the top of the basement stairs, so the height comes out below ground, and the character is treated as standing right below where it was: outside the basement walls.
[*] [b]Fix[/b]: every frame your game checks your character. If it is below ground with no floor or stairs under it or anywhere below, it is put back where it stood a moment ago and the fall is cancelled, with no damage. A character that is already outside the walls when you load in is moved to the nearest floor above.
[*] [b]Difference from vanilla[/b]: if you keep walking into that gap, the character may stop at its edge instead of getting in (vanilla drops you). Using the stairs from their normal entrance is unaffected.
[*] [b]Log[/b]: each time, the player's console.txt gets one line: [MinidoracatFixes] MDFX_BasementVoidGuard player … was below ground at … put back to … (put-backs within 5 seconds count as one; up to 20 lines per start).
[*] [b]Scope[/b]: runs in each player's own game, in SP and MP. In MP players get it when the server updates the mod. It doesn't rebuild walls or change the map.
[*] [b]Retired[/b]: once vanilla stops dropping characters outside the basement walls this way.
[/list]
=== 🧰 Multiplayer: only admins can use the health cheat
[h3]Stronger server-side validation: only admins can use the health cheat (an admin feature)[/h3]
[list]
[*] [b]Fix[/b]: MP servers accept the health cheat only from admins (accounts with the health-cheat permission). When an admin uses the health panel on someone else, that player's game sends one command back on their behalf; that one still goes through. Everything else is refused and changes nobody; malformed requests are refused without a server error.
[*] [b]Difference from vanilla[/b]: accounts without the permission can no longer use the health cheat, on themselves either, whatever their client settings; admins work as in vanilla, on themselves and on others.
[*] [b]Log[/b]: each refusal adds one line to the server's server-console.txt: [MinidoracatFixes] MDFX_HealthCheatPermission denied …, with the name, SteamID, target and action, so admins can find cheaters (up to 20 per connection per start). The name comes from the client, so identify players by SteamID; the SteamID there is approximate (the server's Lua can't read the full number); the exact one is on the *_cmd.txt line in the server's Logs folder from the same second.
[*] [b]Scope[/b]: MP servers only. Does nothing in SP.
[*] [b]Retired[/b]: once vanilla fully validates the health cheat on the server and admins can still use it on others.
[/list]
=== 🧰 Multiplayer: sledgehammer destruction follows the vanilla server rules
[h3]Stronger server-side validation: sledgehammer destruction is checked against the vanilla server rules[/h3]
[list]
[*] [b]Fix[/b]: before a sledgehammer destroys anything, MP servers check the vanilla rules once more: the character needs a usable sledgehammer within reach; on servers with "sledgehammer only in safehouses" on, the target must be in a safehouse the character may use (accounts with the build-cheat permission excepted). Otherwise the hit is refused and nothing is destroyed.
[*] [b]Difference from vanilla[/b]: with the vanilla sledgehammer code the result is the same as vanilla. Some mods replace the sledgehammer destruction code entirely; the vanilla rules are checked then too.
[*] [b]Log[/b]: each refusal adds one line to the server's server-console.txt: [MinidoracatFixes] MDFX_SledgehammerGuard refused a sledgehammer hit …, with the rule, target, position, name and SteamID (up to 20 per connection per start). The name comes from the client, so identify players by SteamID; the SteamID there is approximate (the server's Lua can't read the full number); the exact one is on the player's fully connected line in *_user.txt in the server's Logs folder.
[*] [b]Scope[/b]: in MP it runs on the server and takes effect once the server updates the mod and restarts; in SP the result is the same as vanilla.
[*] [b]Retired[/b]: once the common mods that replace sledgehammer destruction carry the vanilla rules.
[/list]
=== ⚠️ Known limitations
[list]
[*] [b]Moved-out crops[/b]: while moved out, dead/rotten crops pause their slow change to the trampled look until someone returns.
[*] [b]Trimming scope[/b]: covers only areas loaded and unloaded since this start; plots trampled before sowing never move out.
[*] [b]Crop sync[/b]: steps aside if another mod rewrote it (one log line); traps and campfires aren't covered.
[*] [b]Milking and doors[/b]: can error in SP too, but only MP cases are on record, so only MP is handled.
[*] [b]Player-built house disconnect[/b]: a player who jumps more than one square in a single frame (teleport, lag correction, a very fast vehicle) onto such a square can still be disconnected.
[*] [b]Broken corpses[/b]: have other client-side error spots (e.g. trailer menu), not covered.
[*] [b]Watering and the other animal actions[/b]: the log line has no ID of the requested animal (lost when the server parses it).
[*] [b]Loading an animal into a trailer from your hands[/b]: while the server thinks you hold an animal, it errors when the action is created; not covered.
[*] [b]Mod settings[/b]: the copy is made the first time you load in after updating this mod; settings wiped before that can't be recovered. Only mods with no settings left in the file are put back; if a mod still has any line there, the file wins. To reset every mod's settings, delete ModOptions.ini together with ModOptions_MDFX_backup.ini, or they come back.
[*] [b]Hen house disconnect[/b]: an empty slot created in the very frame its hen house unloads (rare) still disconnects; slots that also hold a dead chicken aren't cleared, so the corpse isn't removed with them.
[*] [b]Battery chargers[/b]: idle chargers no longer refresh nearby generators' power lists every frame; appliance switches, added/removed objects and area loads still do, same as a vanilla base without chargers.
[*] [b]Multiplayer deaths[/b]: the message has to reach the server before you finish the new character and press Play; if the connection is slower than that, the first respawn may still be refused (black screen). Reconnect and make a new character; the body stays where you died. A character that dies this way within 30 seconds of spawning isn't handled and gets the vanilla black screen.
[*] [b]Health cheat[/b]: for 30 seconds after an admin uses it on someone, the one command that player's game sends back (same body part, same action) still goes through. If an admin uses it on split-screen player 2-4, or the player's game sends it back after 30 seconds, it is logged as denied; if an admin used the health cheat shortly before a denied line (about the same second for split-screen, 30+ seconds before for a late reply; the server's Logs *_cmd.txt shows the admin's player.onHealthCheat), don't treat it as a cheater straight away. The log-line limit is per player, so each split-screen player has their own; reconnecting or respawning under a new name may restart it.
[*] [b]Vehicle below the ground[/b]: it only puts the car back after it dropped; it doesn't stop the drop itself, and the car lands from slightly above the ground. A car already buried with nobody driving it isn't handled (vanilla pulls its height back to the floor when the server reloads that vehicle). Squares without a floor (e.g. the map edge) aren't handled.
[*] [b]New windows[/b]: these four sets still can't switch between north and west like older windows: a north window only goes back on a north-wall frame, a west one on a west-wall frame. Pointing a north window at a west-wall frame isn't red, but clicking does nothing (vanilla behavior).
[*] [b]Placed bag still worn[/b]: it takes a second or two after placing. If you place an item less than a second after putting it on, in rare cases it still stays until you relog. It doesn't fix why your game decided wrong; appearance mods and vanilla's placing flow are untouched.
[*] [b]Objects with missing pieces[/b]: only the sledgehammer is fixed. Furniture with missing pieces still can't be picked up or disassembled, and it still doesn't disappear when zombies or players break it. Only the piece you hit is removed each time. Large stations that hold crafting equipment or fluids (the kind built from the build menu) aren't handled when pieces are missing and still can't be destroyed.
[/list]
=== ⚠️ Before removing this mod
[list]
[*] [b]Other fixes[/b]: they only act on errors; removing brings back vanilla bugs.
[*] [b]Moved-out crops[/b]: trampled/harvested crops in areas nobody has returned to become vanilla orphans that can't be cleared or plowed. Revisited areas are already restored; vanilla re-registers dead/rotten ones.
[*] [b]Clock parts[/b]: a wiped farming save resets the clock again.
[/list]
=== ❓ FAQ
[h3]Items on corpses (e.g. a red digital watch) can't be picked up?[/h3]
[list]
[*] Not covered or investigated yet.
[*] Report on GitHub Issues with the item, a screenshot and log, noting if pure vanilla does it too.
[/list]
[h3]Is a fix working?[/h3]
[list]
[*] [b]Check the log[/b]: server-console.txt on servers, console.txt in SP shows [MinidoracatFixes] lines.
[*] [b]When a problem is caught[/b]: one line per fix per start. The watering and animal-action fixes log one per action and the death-sync fix one per death it handles or late message it skips, the health-cheat fix one per refusal, the placed-bag fix one per item it takes off (in the server's server-console.txt), up to 20 each (per connection for the health cheat); the mod-settings, hen-house and join-errors fixes log in the player's own console.txt, the vehicle-below-ground and outside-the-basement fixes one line per put-back there too (up to 20 each), the battery-charger fix in both the server's and the player's.
[*] [b]Report these two[/b]: "NOT installed" = a game update changed vanilla, fix paused; "NOT masking it" = unknown error.
[/list]
[h3]Does load order matter?[/h3]
[list]
[*] Usually not: if a later mod replaces the same vanilla code, most fixes re-attach at startup and keep its changes.
[*] Crop sync steps aside instead.
[/list]
[h3]What about the CleanUI inventory fix?[/h3]
[list]
[*] Retired: CleanUI v2.7.9 fixed it; the patch stays dormant.
[/list]
[h3]What about the trailer / multi-tile furniture debris fixes?[/h3]
[list]
[*] Removed in 0.4.0, unmaintained.
[/list]
=== 💬 Reporting
[list]
[*] [b][url=https://github.com/Minidoracat/MinidoracatFixesFor42/blob/main/docs/fixes.md]docs/fixes.md on GitHub[/url][/b]: every fix's cause, verification and retirement condition are public.
[*] [b][url=https://github.com/Minidoracat/MinidoracatFixesFor42/issues]GitHub Issues[/url][/b]: report new bugs with
[list]
[*] the steps
[*] the log error
[/list]
[*] [b][url=https://discord.gg/Gur2V67]Discord community[/url][/b]: or discuss there.
[/list]
