# mod-quest-radar

*[Lire en français](README.fr.md)*

Native C++ module for **AzerothCore 3.3.5a** that helps a player locate the
objectives of their current quests (area/coordinates), in the spirit of
QuestHelper / Questie — with, in addition to the server module, a
companion **client addon** that shows these objectives as icons on the
**minimap** (see [`client-addon/QuestRadar/`](client-addon/QuestRadar)).

## Screenshots

| Minimap icon (numbered objective + area) | In-game view |
|---|---|
| ![Minimap icon closeup](scrn/minimap-icon-closeup.jpg) | ![In-game view](scrn/ingame-view.jpg) |

## Why two parts (server module + client addon)

An AzerothCore C++ module runs **server-side**, inside `worldserver`. It
can't draw an icon on the 3.3.5a client's minimap: that's Blizzard UI/Lua
territory, which only a **client addon** can modify. QuestHelper and
Questie are themselves 100% client addons — and WotLK 3.3.5 has no native
equivalent at all (this feature came later, with Questie in particular).

This module therefore provides:

1. **The server module** (`src/`): computes, from data already present in
   the database (`quest_poi` / `quest_poi_points`), which quest objectives
   are known on the player's current map, and shows them in chat
   (`.questradar`) or via an **addon communication bridge**
   (`CHAT_MSG_ADDON` / `LANG_ADDON`) toward a client addon.
2. **The client addon** (`client-addon/QuestRadar/`): queries this bridge on
   every zone/quest change (and periodically) and draws, on the minimap, an
   icon per **tracked** objective (the default — configurable) (plus a
   circular area when the objective isn't a precise spot), from a
   player/objective delta computed server-side — without depending on any
   third-party Lua library (see the addon's README for why). Configurable
   via `/qr` or a native options panel (Esc > Interface > AddOns). The world
   map doesn't need to be handled: WotLK already draws quest POIs on it
   natively. **Tested under real conditions** on an AzerothCore 3.3.5a
   server — see the [dedicated README](client-addon/QuestRadar/README.md)
   for installation and the history of attempts (a third-party library,
   HereBeDragons, was first tried then dropped after several
   incompatibilities observed in-game with a genuine 3.3.5a client).

## Features

- Automatically announces in chat, when a quest is accepted, the nearest
  known objectives (`QuestRadar.AnnounceOnAccept`).
- Manual `.questradar` command (alias `.qr`): lists the nearest objectives
  for every quest currently in progress on the current map.
- Relies only on data the core already loads
  (`ObjectMgr::GetQuestPOIVector`, `quest_poi` / `quest_poi_points` tables):
  no new table, no SQL import needed.
- A quest with no `quest_poi` data (common for lesser-documented classic
  quests) is silently skipped rather than showing a wrong position.
- Addon communication bridge (`QuestRadar.AddonSyncEnabled`): replies to
  the client addon's requests with the player's position and the full list
  (not just the top 3) of objectives known on the current map, for minimap
  display.

## Compatibility

- ✅ AzerothCore 3.3.5a (`master` branch, "modern" core API:
  `PlayerScript`/`WorldScript` hooks, `Acore::ChatCommands`)
- No dependency on Eluna or any other module.

## Installation

### 1. Copy the module

```bash
cp -r mod-quest-radar/ <azerothcore>/modules/
```

Keep the folder named **`mod-quest-radar`** (or, if you rename it, update
the `Addmod_quest_radarScripts()` function name in
`src/QuestRadarLoader.cpp` accordingly — see the comment in that file,
AzerothCore's build system derives this name from the folder's name).

### 2. Build

```bash
cd <azerothcore>/build
cmake .. -DMODULES_FOLDER=../modules
make -j$(nproc)
```

### 3. Configure

```bash
cp conf/mod-questradar.conf.dist <worldserver_dir>/mod-questradar.conf
```

### 4. Start worldserver

The module loads automatically. Check the logs:
```
mod-questradar: Loaded - Enabled=1 AnnounceOnAccept=1 MaxObjectivesShown=3 AddonSyncEnabled=1
```

### 5. Install the client addon (optional, for minimap icons)

Copy `client-addon/QuestRadar/` into `Interface/AddOns/` of the 3.3.5a WoW
client of every player who wants the icons (the server module alone keeps
working without it, via `.questradar`):

```bash
cp -r mod-quest-radar/client-addon/QuestRadar/ <client_wow>/Interface/AddOns/
```

See the [addon's README](client-addon/QuestRadar/README.md) for
installation details and its status.

## File structure

```
mod-quest-radar/
├── conf/
│   └── mod-questradar.conf.dist
├── README.md
├── data/
│   └── sql/
│       └── db-world/          # reserved for a future evolution (empty for now)
├── src/
│   ├── QuestRadar.h           # config + structures + prototypes
│   ├── QuestRadar.cpp         # logic: finding objectives + formatting the addon protocol
│   └── QuestRadarLoader.cpp   # PlayerScript/WorldScript hooks, .questradar command, addon bridge
└── client-addon/
    └── QuestRadar/             # client Lua addon (see its own README)
        ├── QuestRadar.toc
        ├── Core.lua             # addon protocol (sending REQ, receiving ME/OBJ/END), settings
        ├── Minimap.lua          # minimap icons + areas (player/objective delta, no third-party Lua lib)
        ├── Options.lua          # native options panel (Esc > Interface > AddOns)
        └── Icons/               # glow.blp (vendored image, see Icons/README.md)
```

## Hooks used

| Hook | When | Action |
|---|---|---|
| `OnBeforeConfigLoad` | Startup / `.reload config` | Loads the `.conf` config |
| `OnPlayerQuestAccept` | The player accepts a quest | Announces the nearest objectives (if enabled) |
| `OnPlayerBeforeSendChatMessage` | The client addon self-whispers a `REQ` request | Replies with the known objectives (addon bridge) |
| `.questradar` / `.qr` command | On the player's request | Announces the nearest objectives |

## Roadmap

Minimap display (addon + communication bridge), filtering by tracked
quests, and an options panel are now implemented — see
[`client-addon/QuestRadar/`](client-addon/QuestRadar). Remaining, not yet
implemented, improvement ideas:

- Configurable icon size/color (currently hardcoded in `Minimap.lua`).
