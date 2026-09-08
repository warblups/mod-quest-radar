# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

`mod-quest-radar` is a native C++ **module for AzerothCore 3.3.5a** (the
WotLK-era open-source WoW server core). It is not a standalone application —
it is a `modules/<name>/` folder meant to be dropped into an AzerothCore
source checkout and compiled together with `worldserver`.

Read `README.md` first. This is a **two-part** project: a server-side C++
module (`src/`) and a companion **client Lua addon**
(`client-addon/QuestRadar/`, its own `CLAUDE.md`-equivalent is its
`README.md`) — a server module cannot draw anything on the client minimap by
itself, so the actual icon rendering lives entirely in the addon, talking to
the server over a `CHAT_MSG_ADDON` / `LANG_ADDON` bridge (self-whisper
technique: client sends `QuestRadar\tREQ`, server hook
`QuestRadar_AddonCommsScript::OnPlayerBeforeSendChatMessage` in
`QuestRadarLoader.cpp` replies with `QuestRadar\tME\t...` (the player's own
position) then `QuestRadar\tOBJ\t...` messages built by
`QuestRadar_BuildAddonSyncMessages` in `QuestRadar.cpp`, then a final
`QuestRadar\tEND\t...`). Keep both ends of this protocol in sync — the
prefix and REQ/ME/OBJ/END keywords are duplicated by hand in `QuestRadar.h`
and `client-addon/QuestRadar/Core.lua`.

**This has been tested live against a real AzerothCore 3.3.5a server** (built,
deployed, played against, iterated on through several bugs — not just
written blind), and is confirmed working: comms bridge, minimap icon, and
the area "blob" all render correctly in-game. That testing is exactly what
found the addon's first library-based approach didn't work (see the
client-addon section below) and led to the current design. Two non-obvious
things that testing surfaced, worth knowing before touching `Minimap.lua`:
- A frame parented to `Minimap` with the default child level (parent+1) can
  still render *behind* Minimap's own internal chrome (border, compass) —
  both the icon and the area frame needed an explicit `SetFrameLevel` well
  above `Minimap:GetFrameLevel()` (see the constants at the top of the file)
  to actually show up, despite `IsShown()` correctly returning true either way.
- A texture **file** added to the addon folder (`Icons/glow.blp`) is not
  picked up by a plain `/reload` — it needs a full client restart. Lua file
  changes reload fine with `/reload`; this was specific to the binary asset.

## Build / run — there is nothing to run standalone here

This repo has **no `CMakeLists.txt`, no compiler, no test runner, and no
lint script of its own** — that's correct for an AzerothCore module, not a
gap. AzerothCore's own `modules/CMakeLists.txt` auto-discovers every folder
under `<azerothcore>/modules/` and compiles its `src/` into `worldserver`;
per-module CMakeLists.txt files are only needed for unusual build steps.

To actually build/test this module, it must be developed against a real
AzerothCore checkout:

```bash
cp -r mod-quest-radar/ <azerothcore>/modules/
cd <azerothcore>/build
cmake .. -DMODULES_FOLDER=../modules
make -j$(nproc)          # or the Windows/VS equivalent
```

Then copy `conf/mod-questradar.conf.dist` to `<worldserver_dir>/mod-questradar.conf`
and start `worldserver`; success shows as a `mod-questradar: Loaded - ...`
line in the log. There is no unit-test harness — verification is done live,
in-game, via the `.questradar` / `.qr` command.

## Architecture

**Entry point naming is load-bearing.** AzerothCore's module loader derives
the registration function name directly from this folder's name: `Add` +
`<folder name, any '-' replaced with '_', case preserved>` + `Scripts()`
(see `modules/CMakeLists.txt::ConfigureScriptLoader` in azerothcore-wotlk).
For this folder that's `Addmod_quest_radarScripts()`, defined at the
bottom of `src/QuestRadarLoader.cpp`. **If you rename this folder, you must
rename that function to match**, or the module silently fails to link into
the generated loader.

Three files, one clear split:

- `src/QuestRadar.h` — the module's config struct (`QuestRadarConfig`,
  backed by the global `sQuestRadarConfig`) and the public data/behavior
  contract (`QuestRadarObjective`, `QuestRadar_GetNearbyObjectives`,
  `QuestRadar_AnnounceNearbyObjectives`).
- `src/QuestRadar.cpp` — the actual logic. It does **not** touch the
  database directly for quest locations; it reads `sObjectMgr->GetQuestPOIVector(questId)`,
  which is the same in-memory data (loaded at world start from the
  `quest_poi` / `quest_poi_points` tables) that the core already uses to
  answer the client's quest-log "Objectives" popup. This is why the module
  needs no SQL of its own: it's reusing data the core loads anyway. A quest
  with no POI data is skipped, not guessed at.
- `src/QuestRadarLoader.cpp` — wires the logic above into the engine: a
  `WorldScript` reloads `sQuestRadarConfig` from `mod-questradar.conf` on
  `OnBeforeConfigLoad`, a `PlayerScript` (`QuestRadar_PlayerScript`) calls
  the announce function on `OnPlayerQuestAccept`, a second `PlayerScript`
  (`QuestRadar_AddonCommsScript`) implements the addon comms bridge via
  `OnPlayerBeforeSendChatMessage`, and a `CommandScript` exposes
  `.questradar` / `.qr`. All are `new`'d in the entry-point function
  described above — this is the only place they're registered.

**Extending this module**: new sync'd data or new commands go through the
same file shape (declare in the header, implement in `QuestRadar.cpp`,
hook it up in `QuestRadarLoader.cpp`) — mirror the sibling module
`G:\Dev\mod-accountwide` if you want a second worked example of the same
pattern (config struct + `sConfigMgr->GetOption<T>`, `WorldScript` for
config reload, `PlayerScript` for gameplay hooks, French comments/README).

## The client addon (`client-addon/QuestRadar/`)

Separate Lua project, loaded by a WoW client not by AzerothCore — nothing
here compiles with the server module. **No third-party library** — an
earlier version vendored HereBeDragons-1.0/-Pins-1.0, but in-game testing
against a real AzerothCore 3.3.5a server found it depends on several
functions absent from a genuine 3.3.5.12340 client (`GetWorldMapTransforms`,
`GetAreaMaps`, the tuple order `GetMapContinents` returns, and likely
`UnitPosition`) — it actually targets Blizzard's modern "Classic" client, not
the original. See `README.md`'s "Historique" section before reaching for any
minimap/map library again (Astrolabe was also considered and rejected: its
zone-dimension table is private and keyed by an old-style continent/zone
index, not the server's `mapId`). The replacement has the **server** send its
own position (`ME` message) in the same world-yard frame as objectives, so
the addon only ever computes a plain delta — no client-side map/continent
data needed at all.

Icon math lives in `Minimap.lua`; the addon-side half of the wire protocol
lives in `Core.lua` — if you change the message format on one end
(`QUESTRADAR_ADDON_PREFIX` / `QuestRadar_BuildAddonSyncMessages` in
`src/QuestRadar.h`/`.cpp`), update the other (`ADDON_PREFIX` /
`OnAddonMessage` in `Core.lua`) in the same change. The world map needs no
handling here — WotLK already draws quest POIs on it natively; only the
minimap lacked that (added later, in Cataclysm).

The icon is placed at `obj.areaX/areaY` (the POI's centroid), not
`obj.x/obj.y` (the nearest single point) — a quest with several scattered POI
points (e.g. several mobs across a ~180-yard spread) makes the "nearest
point" jump between them as the player moves, which looked in-game like the
icon fleeing the player. The centroid doesn't jump, so it's the stable
target; `obj.distance` (nearest-point based) is still what the tooltip shows.
The one non-Lua asset, `Icons/glow.blp` (a soft round texture, tinted blue for
the area blob — a plain `SetTexture(r,g,b,a)` fill was tried first but always
left square corners poking out of the round minimap, since 3.3.5 has no
native circular clip), was pulled from
[Questie-335](https://github.com/divial28/Questie-335), a Questie fork
explicitly targeting this same client build — see
`client-addon/QuestRadar/Icons/README.md`.

Icons/zones are additionally filtered by `IsQuestTracked()` in `Minimap.lua`
(`QuestRadar.db.onlyTracked`, default on) — whether a quest is checked in
the Objectives tracker is purely client-side state the server has no concept
of. Two more real-client surprises this surfaced, both fixed by reading
`wowgaming/3.3.5-interface-files`' actual `QuestLogFrame.lua` instead of
guessing from memory (a pattern worth repeating before trusting any
"remembered" 3.3.5 API shape — this repo has now been wrong from memory
about client APIs several times over the course of building this feature):
`GetQuestLogTitle(index)` returns `title, level, questTag, suggestedGroup,
isHeader, isCollapsed, isComplete, isDaily, questID, displayQuestID` —
`isHeader` is the 5th value, not the 4th (a wrong guess there silently reads
`suggestedGroup`, an always-truthy number, so every entry misreads as a
header); and `GetQuestID()` doesn't exist on this client at all — the 9th
`GetQuestLogTitle` return already *is* the quest ID, no
`SelectQuestLogEntry`-then-query dance needed.

Settings (`enabled`, `showArea`, `onlyTracked`) live in `QuestRadar.db`
(`QuestRadarDB` SavedVariable, defaults + `ADDON_LOADED` merge in
`Core.lua`), readable/writable from both the `/qr` slash commands (`Core.lua`)
and the native Interface-Options panel (`Options.lua`, plain
`InterfaceOptionsCheckButtonTemplate` — no Ace3). Both write the same table
and call `QuestRadar.RefreshIcons()` immediately; there's no separate
Okay/Cancel state to keep in sync.
