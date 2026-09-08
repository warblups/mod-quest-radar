# QuestRadar (client addon)

Lua addon for the **World of Warcraft 3.3.5a client** (build 12340, the one
used by AzerothCore — not the modern "WotLK Classic" client, which doesn't
use the same API). Companion to the [`mod-quest-radar`](../../README.md)
server module: shows on the **minimap** a numbered icon per known quest
objective — the same number natively shown in the yellow circle on the
*world map* for that same objective.

The world map doesn't need to be handled by this addon: WotLK already draws
quest POIs on it natively (unlike the minimap, which never did before
Cataclysm — that's the whole gap this addon fills).

## Installation

```bash
cp -r client-addon/QuestRadar/ <client_wow>/Interface/AddOns/
```

Then, on the in-game AddOns selection screen, make sure "QuestRadar" is
checked.

⚠️ **After a first install (or after adding a new file to the `.toc`
— image or `.lua`), fully restart the WoW client** (close it and relaunch
it), not just `/reload` — observed in-game twice: once for `Icons/glow.blp`
(area invisible), once for adding `Options.lua` to the `.toc` (options
panel missing until the client was restarted). **Modifying a file already
loaded**, on the other hand, reloads fine with `/reload` — the limitation
seems to be specifically about detecting *new* files.

**Server requirement**: the `mod-quest-radar` module must be built into
`worldserver` with `QuestRadar.AddonSyncEnabled = 1` (the default, see
`conf/mod-questradar.conf.dist`).

## How it works

This addon knows **nothing** by itself about quest positions, not even its
own position: everything comes from the server via the `CHAT_MSG_ADDON`
bridge (see `Core.lua`, and server-side
`QuestRadar_BuildAddonSyncMessages` / `QuestRadar_AddonCommsScript` in
`src/QuestRadar.cpp` / `src/QuestRadarLoader.cpp`).

**Why the server also sends the player's position**: a genuine WotLK
3.3.5.12340 client has no reliable function to know its own position in
yards (`UnitPosition` doesn't exist on this client — see the attempt
history below). The server already knows this position
(`Player::GetPositionX/Y`), so it sends it in the same frame of reference
as the objectives: the addon just has to compute a plain delta
(objective − player) in yards, without needing to know any map/continent/
zone coordinate system client-side.

`Minimap.lua` then converts this delta into an on-screen position using the
minimap's current zoom (`Minimap:GetZoom()`) and handles rotation if
`rotateMinimap` is enabled — the same method used by classic minimap
libraries (HereBeDragons-Pins, Astrolabe...), without depending on one:
**no third-party Lua library is used**, everything fits in the two files
`Core.lua` and `Minimap.lua` (only `Icons/glow.blp`, an image, is vendored —
see `Icons/README.md`).

**One icon per objective group (`quest_poi`), not per quest**: a quest with
several distinct objectives on the same map (e.g. "kill boars" AND "bring
this back to an NPC elsewhere") shows several independent icons, each with
its own number (`objectiveIndex + 1`) — not a single icon that jumps between
them. This is a real bug that was fixed in-game: keeping only one "nearest"
point per quest made the icon jump from one group to another, sometimes far
away, as soon as the player moved, making it seem to "flee" or "orbit"
erratically.

A group with a negative `objectiveIndex` (`quest_poi` convention for "not a
precise numbered objective", often a generic quest turn-in spot) **shows
nothing at all** — observed in-game: a numberless badge still showing up
was mistaken for the minimap's native NPC blips, and added nothing useful.

When a group isn't a precise spot (several points, e.g. "kill boars
somewhere in this area"), a translucent circular area shows up in addition
to the icon, centered on those points — like the blob Blizzard natively
shows on the *world map* for this kind of objective, but which never
existed on the minimap. **The icon points to this stable center
(`areaX`/`areaY`), not to the precise nearest point**: within the same
scattered group (e.g. several mobs), the nearest point can also jump from
one point to another as the player moves — same stability logic.

On every zone/quest change the addon requests a full sync; it also
requests one every ~3 seconds so the player's position (and thus the
icons) stays reasonably up to date while they move around.

## Settings

Persisted across sessions (`QuestRadarDB`, `SavedVariables`), via a native
options panel (Esc > Interface > AddOns > QuestRadar, `Options.lua`) **or**
commands — both read/write the same settings, no need to pick one:

| Command | Effect |
|---|---|
| `/qr` or `/questradar` | Manual sync + diagnostic (legacy behavior) |
| `/qr on` / `/qr off` | Enables/disables the whole module (icon, area, and stops querying the server) |
| `/qr zone on` / `/qr zone off` | Shows/hides just the circular area (keeps the icon) |
| `/qr tracked on` / `/qr tracked off` | `on` (default): only shows tracked quests (Objectives tracker); `off`: shows every quest accepted on the map |
| `/qr scan` | Diagnostic: dump of the quest log (index, header or not, id, tracked) |
| `/qr help` | Recalls these commands |

Whether a quest is tracked (checked in the Objectives tracker) is a
**100% client-side** state: the server doesn't know it and always sends
every quest accepted on the current map. With `onlyTracked` (the default),
filtering happens entirely in `Minimap.lua` by querying the local quest log
(`IsQuestWatched`); it updates immediately when you check/uncheck a quest
(`QUEST_WATCH_LIST_CHANGED` event), without waiting for the next server
sync.

No graphical options panel dependency needed for this (to stay free of
Ace3/AceConfig) — just commands, deliberately kept simple.

## History: why no external library

Earlier versions of this addon relied on **HereBeDragons-1.0**
(+ `-Pins-1.0`), a third-party library widely used across the WoW addon
ecosystem. Tested in-game on a real AzerothCore server, it turned out to
depend on several functions absent from a genuine 3.3.5.12340 client
(`GetWorldMapTransforms`, `GetAreaMaps`, the return order of
`GetMapContinents`, and likely `UnitPosition` further into its code): it
actually targets Blizzard's modern "Classic" client (which runs on the
current client engine with compatibility layers), not the original.
`!Astrolabe` (older, genuinely designed for this client) was also
considered, but its per-zone dimension table is private (not exposed to
other addons) and indexed by old-style continent/zone, not by the `mapId`
the server knows — which would have required the same fragile
correspondence layer. Hence the current approach: the server directly
provides a delta already in the right frame of reference, needing no zone
data client-side.

For the circular area, an earlier version drew it with a solid color
(`Texture:SetTexture(r,g,b,a)`, no image file). Problem observed in-game:
WoW 3.3.5 has no native circular clip for addon textures — a square large
enough always pokes out of the minimap's circle, whatever its size (a
matter of geometry, not a setting). The fix: a real round image with a soft
edge, `Icons/glow.blp`, pulled from
[Questie-335](https://github.com/divial28/Questie-335) (a Questie fork
explicitly targeting this same 3.3.5.12340 client) rather than trying to
fake a blur with stacked shapes.

## ✅ Status

Tested under real conditions on an AzerothCore 3.3.5a server (built, played
live, several rounds of fixes): the server↔addon bridge, the icon (stable,
no longer "fleeing" the player, in the right direction) and the circular
area all three work. Points worth keeping in mind:

- **WoW's axis convention**: +X world = north, +Y world = west (not the
  usual screen frame of X=horizontal/Y=vertical). A bug observed in-game
  (an objective northwest of the player on the world map, shown southwest
  on the minimap) came from reusing a library's (HereBeDragons-Pins)
  display formula without reusing its internal axis conversion. See the
  `ComputeMinimapDelta` comment in `Minimap.lua` before touching this
  calculation again.
- **`GetQuestLogTitle(index)`** returns `title, level, questTag,
  suggestedGroup, isHeader, isCollapsed, isComplete, isDaily, questID,
  displayQuestID` (verified against the real 3.3.5 client's FrameXML
  sources,
  [wowgaming/3.3.5-interface-files](https://github.com/wowgaming/3.3.5-interface-files)) —
  `isHeader` is the **5th** return value, not the 4th. An earlier version
  read it at the 4th position (so actually `suggestedGroup`, a number
  that's almost never `nil`/`false`, hence always "true" in Lua): every
  quest was mistaken for a header, and the "tracked quests" filter never
  detected anything. And **`GetQuestID()`** (used in an intermediate
  version to find a quest's id via `SelectQuestLogEntry`+`GetQuestID()`)
  **doesn't exist** on this client — not needed anyway, `GetQuestLogTitle`
  already returns the id directly at the 9th position (`qid` in
  `IsQuestTracked`, `Minimap.lua`).

- After installing or updating `Icons/glow.blp`, a full client restart is
  required (see "Installation" above).
- If `/qr` doesn't respond at all, check `QuestRadar.AddonSyncEnabled`
  server-side and the `worldserver` logs.
- If an icon/area stays invisible even though `/qr` lists it as "created",
  suspect an insufficient display level (`SetFrameLevel`) against internal
  minimap elements — that happened twice during development (see the
  `SetFrameLevel` comments in `Minimap.lua`).

## Files

- `QuestRadar.toc` — the addon's manifest (loads `Core.lua`, `Minimap.lua`
  then `Options.lua`, no third-party Lua library).
- `Core.lua` — addon network protocol: sending `REQ`, receiving
  `ME`/`OBJ`/`END`, throttling and periodic resync, settings
  (`QuestRadar.db`/`QuestRadarDB`), `/qr` commands.
- `Minimap.lua` — draws minimap icons and areas (one per `poiId`, not per
  quest) from the player/objective delta exposed by `Core.lua`
  (`QuestRadar.objectives`, `QuestRadar.playerX/Y`, `QuestRadar.currentMapId`),
  and filters by quest tracking (`IsQuestTracked`) and by `objectiveIndex`.
- `Options.lua` — native options panel (Esc > Interface > AddOns), no
  Ace3: just `InterfaceOptionsCheckButtonTemplate` +
  `InterfaceOptions_AddCategory`.
- `Icons/` — `glow.blp`, the only vendored asset (an image, no code); see
  `Icons/README.md`.
