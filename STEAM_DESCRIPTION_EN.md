[h1]🔧 Minidoracat Fixes for B42[/h1]
[h3]By Minidoracat[/h3]

[hr][/hr]

[h2]⏳ This is a temporary fix[/h2]
Right now this mod does exactly one thing: it brings back the inventory and loot windows that [b]CleanUI[/b] breaks on Build 42.20.4.

[b]This is a stopgap on the original author's behalf.[/b] Once CleanUI ships a fixed version, this fix retires itself automatically — it detects the official version and stops interfering. Players do not have to do anything. At that point this mod will be delisted, or repurposed for something else.

[h2]🐛 What it fixes[/h2]
[list]
[*] [b]Symptom[/b]: the inventory and loot windows never open at all. Your character can walk and chat, but the entire inventory interface simply does not exist.
[*] console.txt shows [b]Object tried to call nil in getConfig[/b].
[*] [b]The cause is on CleanUI's side[/b]: the Build 42.20.4 security change removed Lua's loadstring, CleanUI rewrote its config loading path the same day, but the released files are missing one of the functions while the code calling it was left unchanged.
[*] The inventory panel aborts halfway through construction, which also takes down the loot window and every other interface hanging off the same initialization sequence. That is why "one setting could not be read" removes your whole inventory UI.
[*] [b]This fix[/b]: it only restores that one missing function, using nothing but what CleanUI already ships. No changes to any of CleanUI's existing behavior, no new settings, no new UI.
[/list]

[h2]📋 Mod info[/h2]
[list]
[*] [b]Mod ID:[/b] MinidoracatFixesFor42
[*] [b]Supported version:[/b] Build 42.20.4+
[*] Does nothing at all — and causes no side effects — if you do not have CleanUI installed
[*] Client-side fix; no extra server configuration needed
[*] Load order does not matter (before or after CleanUI both work)
[*] No balance changes, no new items, no new UI, no new options
[*] Never writes to or modifies your CleanUI config file
[/list]

[h2]💬 Feedback & community[/h2]
[url=https://discord.gg/Gur2V67]👉 Join the Discord server[/url]

[h2]📺 Follow the author[/h2]
[url=https://www.twitch.tv/minidoracat]🎬 Twitch channel[/url]

[b]#fix #bugfix #CleanUI #inventory #Minidoracat[/b]

Workshop ID: 3790443858
Mod ID: MinidoracatFixesFor42
