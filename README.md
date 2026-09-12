# mod-quest-radar

*[Lire en français](README.fr.md)*

C++ module for **AzerothCore 3.3.5a** that shows where your current quest
objectives are, in the spirit of QuestHelper / Questie — plus a client addon
([`client-addon/QuestRadar/`](client-addon/QuestRadar)) that draws them as
icons on the **minimap**, which WotLK never did natively.

## Screenshots

| One icon per objective, labelled by quest | In-game view |
|---|---|
| ![Minimap closeup](scrn/minimap-icon-closeup.jpg) | ![In-game view](scrn/ingame-view.jpg) |

Quest 4 in the tracker, *Solanian's Belongings*, has three objectives in three
different places — so the minimap carries three icons all marked `4`.

![World map next to the minimap](scrn/worldmap-vs-minimap.jpg)

Same moment, same quests: the world map (left) places **one** circle for quest
4, the minimap (right) shows its three objectives separately. The client API
the world map uses (`QuestPOIGetIconInfo`) only returns one position per
quest; the module reads the same `quest_poi` tables without that limit.

## The two parts

1. **The server module** (`src/`) reads the `quest_poi` / `quest_poi_points`
   tables and reports the objectives known on the player's map, in chat
   (`.questradar`) or over an addon bridge (`CHAT_MSG_ADDON`).
2. **The client addon** (`client-addon/QuestRadar/`) draws them on the
   minimap. A server module can't touch the client UI, so the rendering has
   to live in an addon.

The shipped addon **works without the module**: it reads the quest POI data
the client already has. When the module is present it detects it and upgrades
to one icon per *objective* instead of one per quest. See
[`client-addon/README.md`](client-addon/README.md).

## Features

- Announces the nearest known objectives in chat when a quest is accepted
  (`QuestRadar.AnnounceOnAccept`).
- `.questradar` command (alias `.qr`): lists the nearest objectives of every
  quest in progress on the current map.
- Addon bridge (`QuestRadar.AddonSyncEnabled`): sends the player's position
  and the full list of objectives on the map, for minimap display.
- Uses only data the core already loads (`ObjectMgr::GetQuestPOIVector`): no
  new table, no SQL import.
- No dependency on Eluna or any other module.

## Installation

### 1. Copy the module

```bash
cp -r mod-quest-radar/ <azerothcore>/modules/
```

Keep the folder named **`mod-quest-radar`** — AzerothCore derives the
`Addmod_quest_radarScripts()` entry-point name from it (see
`src/QuestRadarLoader.cpp`).

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

The module loads automatically:
```
mod-questradar: Loaded - Enabled=1 AnnounceOnAccept=1 MaxObjectivesShown=3 AddonSyncEnabled=1
```

### 5. Install the client addon (optional, for minimap icons)

```bash
cp -r mod-quest-radar/client-addon/QuestRadar/ <client_wow>/Interface/AddOns/
```

Everything it needs, Astrolabe included, ships with it. See the
[addon's README](client-addon/QuestRadar/README.md) for its settings and
`/qr` commands.

## Configuration

| Option | Default | Effect |
|---|---|---|
| `QuestRadar.Enable` | `1` | Master on/off switch |
| `QuestRadar.AnnounceOnAccept` | `1` | Announce objectives when a quest is accepted |
| `QuestRadar.MaxObjectivesShown` | `3` | Max objectives listed per chat announce |
| `QuestRadar.AddonSyncEnabled` | `1` | Server↔addon bridge used for minimap icons |

## File structure

```
mod-quest-radar/
├── conf/
│   └── mod-questradar.conf.dist
├── src/
│   ├── QuestRadar.h           # config + structures + prototypes
│   ├── QuestRadar.cpp         # objective lookup + addon protocol formatting
│   └── QuestRadarLoader.cpp   # hooks, .questradar command, addon bridge
└── client-addon/              # see client-addon/README.md
    ├── QuestRadar/            # shipped addon (standalone, uses the module when present)
    └── server-module-variant/ # reference: the original bridge-only addon
```

## Hooks used

| Hook | When | Action |
|---|---|---|
| `OnBeforeConfigLoad` | Startup / `.reload config` | Loads the `.conf` config |
| `OnPlayerQuestAccept` | The player accepts a quest | Announces the nearest objectives |
| `OnPlayerBeforeSendChatMessage` | The addon sends a `REQ` request | Replies with the known objectives |
| `.questradar` / `.qr` | On the player's request | Announces the nearest objectives |
