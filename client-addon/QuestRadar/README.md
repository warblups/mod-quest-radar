# Quest Radar

Cataclysm-style quest objective icons on the **WotLK 3.3.5a** minimap, for a
genuine 3.3.5.12340 client (the one AzerothCore serves — not Blizzard's modern
"WotLK Classic" client, which has a different API).

WotLK already draws numbered quest POIs on the *world map* natively. It never
drew them on the minimap — that is the gap this addon fills, reusing the same
data and the same artwork.

## Requirements

Only one: a server whose world database has the `quest_poi` table populated
(stock AzerothCore does). If the world map shows no numbered circles either,
the data is missing server-side.

**No server module needed, and nothing else to install.** If the realm runs
[`mod-quest-radar`](../../README.md), the addon detects it and upgrades to one
icon per *objective* instead of one per quest — see [`../README.md`](../README.md).

Astrolabe ships inside the addon under `Libs/Astrolabe/`; it converts a map
coordinate into a minimap offset, handling zoom, rotation, minimap shape and
edge clamping. If you also run the standalone `!Astrolabe` addon, DongleStub
keeps whichever copy is newer — there is no conflict. See
[`Libs/Astrolabe/README.md`](Libs/Astrolabe/README.md) for its origin and
licence.

## Installation

Copy the folder containing `QuestRadar.toc` into
`World of Warcraft\Interface\AddOns\`, then check **QuestRadar** on the AddOns
selection screen. Keep `Libs/` with it.

After a first install, restart the client fully rather than `/reload` — this
client only picks up new files at startup.

## Settings

Two equivalent ways in, both writing the same `QuestRadarDB`:

- **Esc > Interface > AddOns > QuestRadar** — a native panel, no Ace3 and no
  third-party dependency. Every control applies immediately.
- The `/qr` commands below.

## Commands

| Command | Effect |
|---|---|
| `/qr` | Toggle the radar |
| `/qr on` / `/qr off` | Enable / disable explicitly |
| `/qr status` | Diagnostic: Astrolabe found, current map, quests, POIs reported, icons placed |
| `/qr module` | Use the `mod-quest-radar` server module when the realm has it (default on) |
| `/qr tracked` | `on` (default): only quests checked in the objectives tracker. `off`: every quest on the map |
| `/qr completed` | Show or hide turn-in (`?`) icons for completed quests |
| `/qr edge` | Show or hide objectives that are out of range (clamped to the minimap rim) |
| `/qr scale <0.5-3>` | Icon size |

`/qr arrows` is kept as an alias of `/qr edge`.

Selecting a quest — in the quest log, or on the world map — lights up its icons
with Blizzard's own selection glow. A quest split across several objectives
lights all of them at once.

## Good to know

- Whether a quest is tracked is purely client-side state. With `/qr tracked` on
  (the default), the numbers follow the objectives tracker rather than the
  world map, exactly like Blizzard's own `WatchFrame` — the two can disagree
  when something is untracked. Turn it off to get the world map numbering back.
- The quest search *blobs* — the translucent area the world map shows for an
  imprecise objective — are not drawn on the minimap. Their centre and radius
  are numbers no Lua function on this client returns; see
  [`../README.md`](../README.md).

## Files

- `QuestRadar.toc` — manifest.
- `QuestRadar.lua` — POI enumeration and minimap rendering.
- `Sync.lua` — optional server-module sync (`CHAT_MSG_ADDON` bridge).
- `Options.lua` — native options panel.
- `Libs/Astrolabe/` — bundled library; see its own README.
