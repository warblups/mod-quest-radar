# Quest Radar

Cataclysm-style quest objective icons on the **WotLK 3.3.5a** minimap, for a
genuine 3.3.5.12340 client (the one AzerothCore serves — not Blizzard's modern
"WotLK Classic" client, which has a different API).

WotLK already draws numbered quest POIs on the *world map* natively. It never
drew them on the minimap — that is the gap this addon fills, reusing the very
same data and the very same artwork.

## Requirements

- `Interface\AddOns\!Astrolabe` — installed **and enabled**. Quest POIs come
  back as coordinates normalised to the zone map, and turning that into minimap
  pixels needs the zone's size in yards, which this client exposes nowhere.
  !Astrolabe carries that table and also handles minimap zoom, rotation, shape
  and edge clamping. Available from
  [Trimitor/WDM-addons](https://github.com/Trimitor/WDM-addons).
- A server whose world database has the `quest_poi` table populated (stock
  AzerothCore does). If the world map shows no numbered circles either, the
  data is missing server-side — no client addon can invent it.

No server module is required. Everything comes from the client's own quest POI
data.

## Installation

Copy the folder containing `QuestRadar.toc` and `QuestRadar.lua` into
`World of Warcraft\Interface\AddOns\`, then make sure both **QuestRadar** and
**!Astrolabe** are checked on the AddOns selection screen.

After a *first* install, restart the client fully rather than `/reload` — this
client only picks up new files at startup.

## Settings

Two equivalent ways in, both writing the same `QuestRadarDB`:

- **Esc > Interface > AddOns > QuestRadar** — a native panel built from stock
  Blizzard widgets (`InterfaceOptionsCheckButtonTemplate`,
  `OptionsSliderTemplate`), no Ace3 and no third-party dependency. There is no
  Okay/Cancel: every control applies immediately.
- The `/qr` commands below.

## Commands

| Command | Effect |
|---|---|
| `/qr` | Toggle the radar |
| `/qr on` / `/qr off` | Enable / disable explicitly |
| `/qr status` | Diagnostic: Astrolabe found, current map, quests, POIs reported, icons placed |
| `/qr tracked` | `on` (default): only quests checked in the objectives tracker. `off`: every quest on the map |
| `/qr completed` | Show or hide turn-in (`?`) icons for completed quests |
| `/qr edge` | Show or hide objectives that are out of range (clamped to the minimap rim) |
| `/qr scale <0.5-3>` | Icon size |

`/qr arrows` is kept as an alias of `/qr edge`.

## Notes on 3.3.5a

Three things are easy to get wrong on this client, and each one silently
produces an empty or nonsensical radar. All were checked against the client's
own FrameXML ([wowgaming/3.3.5-interface-files](https://github.com/wowgaming/3.3.5-interface-files)):

- **POI coordinates are not live.** `QuestPOIGetIconInfo()` only answers once
  `QuestMapUpdateAllQuests()` has rebuilt the POI list for the *current world
  map* — exactly what `WorldMapFrame_UpdateQuests()` and
  `WatchFrame_GetCurrentMapQuests()` do before reading it. Without that call
  the radar stays empty forever, with no error.
- **Quest ids come from `QuestPOIGetQuestIDByVisibleIndex(i)`**, which also
  returns the quest log index. Completed quests occupy the first visible
  indexes, which is how the world map numbers the remaining ones 1..n — this
  addon reproduces that numbering so both views agree.
  (`GetQuestLogTitle` does return a `questID` 9th, but it is not the POI
  enumeration order.)
- **A normalised map delta cannot be scaled to pixels by a constant.** Earlier
  versions multiplied by `RADAR_SIZE * (1 + zoom * 0.22)`, which is off by the
  ratio between zone sizes — icons bunched in the middle of the minimap in
  Northrend and pinned to the rim in Elwynn. The projection is delegated to
  !Astrolabe instead.
- **`QUEST_WATCH_LIST_CHANGED` does not exist on this client** (it arrived with
  Cataclysm); registering it raises a Lua error. `QUEST_WATCH_UPDATE` is the
  3.3.5 equivalent — but it fires on objective *progress*, not on a quest being
  checked or unchecked. Nothing on this client signals that: Blizzard's own UI
  calls `AddQuestWatch` / `RemoveQuestWatch` directly, so those two are hooked
  with `hooksecurefunc` to refresh the radar immediately.

Whether a quest is tracked is purely client-side state. With `/qr tracked` on
(the default), the numbers follow the objectives tracker rather than the world
map, exactly like Blizzard's own `WatchFrame` does — the two can disagree when
something is untracked. Turn it off to get the world map numbering back.

The quest search *blobs* (`QuestPOIFrame:DrawQuestBlob`) are deliberately not
rendered: 3.3.5 has no circular clipping for addon frames on the minimap, so a
blob large enough to be meaningful always spills out of the minimap as a
square.
