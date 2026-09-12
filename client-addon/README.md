# Client addons

Two implementations of the same idea live here. **Only one can be installed
at a time** — they both declare `/qr`, the `QuestRadarDB` saved variable and
the same frames.

## `QuestRadar/` — the one to install

Reads the quest POI data the 3.3.5a client already has and projects it onto
the minimap with the bundled [!Astrolabe](https://github.com/Trimitor/WDM-addons).

- **Needs no server module.** Works on any AzerothCore whose world database
  has `quest_poi` populated (stock does).
- One icon per quest, numbered exactly like the world map.
- When the `mod-quest-radar` module is on the realm, it switches to one icon
  per *objective group* — the client API only ever exposes one POI per quest,
  the module has no such limit. `/qr module` turns the upgrade off, `/qr
  status` says which source is live.

See its [README](QuestRadar/README.md).

## `server-module-variant/` — reference, not shipped

The original addon, which gets all its positions from the module over the
`CHAT_MSG_ADDON` bridge instead of from the client. Kept for reference; its
per-objective behaviour now lives in the shipped addon. To use it, rename the
folder to `QuestRadar/` and match its `.toc` to the folder name.

## Why the search areas aren't drawn

The translucent area the world map shows for an imprecise objective can't be
put on the minimap from the client alone: no Lua function on 3.3.5a returns
an area's geometry, `DrawQuestBlob` paints outside its own frame, and the
client has no `SetClipsChildren` to crop it. Drawing one needs its centre and
radius as numbers — which only the server module provides (`areaX`/`areaY`).
