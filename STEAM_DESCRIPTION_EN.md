[h1]🔧 Minidoracat Fixes for B42[/h1]
[h3]By Minidoracat[/h3]

[hr][/hr]

[h2]🧰 What is this[/h2]
A standing collection of fixes for vanilla bugs in Project Zomboid Build 42; each fix is retired once the game fixes it officially. No balance changes, items, UI or settings — normal gameplay is unchanged.

[h2]🐛 Currently included[/h2]
[list]
[*] [b]Some animal corpses can never be butchered[/b]: corpses missing data (mostly from animal mods) waste the whole action. Now cleanly rejected; normal butchering is untouched.
[*] [b]Reloading does nothing with a non-firearm in hand and an ammo strap worn[/b]: now reloads normally using the vanilla formula.
[*] [b]Server error when a petted animal just died or despawned[/b]: the action now ends cleanly.
[*] [b]Actions get stuck when a tool breaks on its last swing[/b] (walls, clutter, bushes): now finish properly, unequip the broken tool and draw your best weapon.
[*] [b]Milking produces nothing[/b]: if the bucket can no longer hold liquid, the action now just ends — use another bucket.
[*] [b]Liquid vanishes when pouring into another container[/b]: both containers are now checked first; if either is invalid, nothing happens.
[*] [b]Server error when changing clothes or placing furniture and the item is already gone[/b]: the action now ends cleanly.
[*] [b]Vehicle doors only lock halfway[/b]: the whole vehicle is now checked first; if something is wrong, no door is touched.
[*] [b]The server keeps re-sending unchanged crop data as players walk past farmland[/b]: it now only sends when a crop changes — watering, growth, trampling still show up instantly — saving server upload bandwidth.
[/list]

[h2]📋 Mod info[/h2]
[list]
[*] [b]Mod ID:[/b] MinidoracatFixesFor42
[*] [b]Supported version:[/b] Build 42.20.4+
[*] Singleplayer and multiplayer; in MP it is enabled by the server, and all fixes except the reload one run server-side only
[*] The cause and verification of every fix are public on GitHub
[/list]

[h2]💬 Feedback & community[/h2]
[url=https://discord.gg/Gur2V67]👉 Join the Discord server[/url]

[h2]☕ Support the author[/h2]
If this helped, a 👍 on this page and a ⭐ on GitHub help other players find it.
The mod is free and always will be, with the source public on GitHub. If you enjoy it, consider buying me a coffee - tips go straight into servers and mod development.
[url=https://ko-fi.com/minidoracat][img]https://raw.githubusercontent.com/Minidoracat/workshop-resources/refs/heads/main/badges/badge_kofi.png[/img][/url] [url=https://github.com/Minidoracat/MinidoracatFixesFor42][img]https://raw.githubusercontent.com/Minidoracat/workshop-resources/refs/heads/main/badges/badge_github.png[/img][/url]

[b]#fix #bugfix #vanilla #butchering #reload #farming #Minidoracat[/b]

Workshop ID: 3790443858
Mod ID: MinidoracatFixesFor42
