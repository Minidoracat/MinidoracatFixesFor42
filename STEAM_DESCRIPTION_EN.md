[h1]🔧 Minidoracat Fixes for B42[/h1]
[h3]By Minidoracat[/h3]

[hr][/hr]

[h2]✨ What is this[/h2]
A collection of client-side fixes for vanilla Build 42 bugs — specifically the spots where vanilla Lua skips a nil check and actually blows up on multiplayer servers.

[b]Fixes only[/b] — no balance changes, no new items, no new UI, no new options. The only difference after installing is that things that used to break no longer break.

[h2]🧰 Included so far[/h2]
[list]
[*] [b]Dead animals can't be loaded into a trailer / vehicle right-click menu disappears[/b]
With a trailer's animal door open, right-clicking the vehicle (or pressing "Add animal" in the trailer animal UI) wipes out the entire vehicle context menu, and dead animals can't be loaded.
console.txt shows [b]__mul not defined for operands in round[/b] (ISVehicleMenu.lua:806).
The cause is an animal corpse missing the mod-data field that records how much trailer space it takes; the vanilla line reads it unguarded, which aborts the whole menu build.
This fix backfills that field using the game's own formula before vanilla reads it, so the value matches exactly what the engine computes.
[/list]

[h2]📋 Mod info[/h2]
[list]
[*] [b]Mod ID:[/b] MinidoracatFixesFor42
[*] [b]Supported version:[/b] Build 42.20.0+
[*] Works in singleplayer / multiplayer (MP requires the server to enable the mod)
[*] Client-side fixes; no extra server configuration needed
[*] Once a fix lands officially, the corresponding entry is removed from this mod
[/list]

[h2]💬 Feedback & community[/h2]
[url=https://discord.gg/Gur2V67]👉 Join the Discord server[/url]

[h2]📺 Follow the author[/h2]
[url=https://www.twitch.tv/minidoracat]🎬 Twitch channel[/url]

[b]#fix #bugfix #vehicle #animal #Minidoracat[/b]
