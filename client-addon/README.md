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

## Settled: the search areas cannot be drawn client-side

The translucent area the world map shows for an imprecise objective **cannot be
put on the minimap without the module**. This was prototyped and tested in-game,
not assumed — branch `proto/minimap-quest-blobs`.

The client holds the point lists and `DrawQuestBlob` paints them, but no Lua
function returns their geometry: the entire `QuestPOIFrame` surface on 3.3.5a is
`DrawQuestBlob`, `GetNumTooltips`, `GetTooltipIndex` and the
`Set*Texture`/`Set*Alpha` calls, none of which hands back a coordinate. The
prototype therefore never asked where an area was — it sized a `QuestPOIFrame`
like Blizzard's `WorldMapBlobFrame`, scaled it to the minimap's yards-per-pixel
and anchored the player's position to the minimap centre.

It renders in the right place at the right size. It also **bleeds well outside
the minimap**: `DrawQuestBlob` does not confine itself to its frame's rectangle,
and 3.3.5a has no `SetClipsChildren`. `SetMaskTexture` only masks the minimap's
own terrain, not frames drawn over it, so reshaping the minimap does not help
either.

That leaves the approach the bridge-based variant already uses: a pre-rounded
texture (`Icons/glow.blp`) drawn at the area's centre, sized to its radius —
which needs that centre and radius **as numbers**. Only the server module
provides them (`areaX`/`areaY`). This is now the module's strongest
justification.

## The hybrid

`QuestRadar/` now does both. `Sync.lua` asks the module for a sync; if an answer
comes back it draws **one icon per objective group**, and if none ever does it
stays on the client's own POI data with no message and no penalty. `/qr module`
turns the upgrade off, and `/qr status` says which source is live.

Both sources feed a single renderer. The module speaks world yards and the rest
of the addon speaks normalised map coordinates, but absolute positions are never
needed: the player exists in both frames, so a delta converts between them, with
the zone's size in yards coming from Astrolabe's public `ComputeDistance`. Every
icon therefore goes through the same `PlaceIconOnMinimap` call, and zoom,
rotation, minimap shape, edge clamping and the Blizzard artwork are written once.

Two behaviours inherited from the bridge-based variant, both of which it learned
the hard way in-game: icons point at a group's **stable centre** (`areaX`/`areaY`)
rather than its nearest point, which otherwise makes them jump between points as
the player moves; and a group with a negative `objectiveIndex` — the `quest_poi`
convention for "not a numbered objective" — is only drawn once the quest is
complete, as the turn-in icon, because a numberless badge reads as a native NPC
blip.

Icon *numbers* stay sequential rather than following `objectiveIndex`:
`QuestPOI_DisplayButton` caches its buttons by index, so two objectives sharing a
number would share a button. The module's gain is the number of icons, not what
is written in them.
