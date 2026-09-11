# Client addons

Two implementations of the same idea live here. **Only one can be installed
at a time** — they both declare `/qr`, the `QuestRadarDB` saved variable and
the same frames, so installing both would have them fight each other.

## `QuestRadar/` — shipped

The addon to install. It reads the quest POI data the 3.3.5a client already
has (`QuestMapUpdateAllQuests` / `QuestPOIUpdateIcons` /
`QuestPOIGetIconInfo`) and projects it onto the minimap with
[!Astrolabe](https://github.com/Trimitor/WDM-addons).

- **Needs no server module.** Works on any AzerothCore whose world database
  has `quest_poi` populated (stock does).
- One icon **per quest**, numbered exactly like the world map.
- Verified in-game on a real 3.3.5a server.

## `server-module-variant/` — reference, not shipped

The original addon, which gets its positions from the `mod-quest-radar` C++
module over the `CHAT_MSG_ADDON` bridge instead of from the client.

It is kept here because it does something the shipped addon cannot: the
3.3.5a Lua API only exposes **one POI per quest**
(`QuestPOIGetIconInfo(questID)` returns a single position), whereas the
server module can hand over **one group per objective** plus the area
circles. That granularity is the reason to finish wiring the two together.

Its known 3.3.5a defects have been fixed in place (three Cataclysm-only
events it used to register), but it has not been re-tested since the
restructure. To use it, it has to be renamed to `QuestRadar/` and its `.toc`
matched to the folder name.

## Where this is heading

The intended end state is a single addon that works standalone and upgrades
itself to per-objective icons when it detects the server module on the realm
— `Core.lua` already performs that handshake. That merge is not done yet.
