# mod-quest-radar

*[Read this in English](README.md)*

Module C++ natif pour **AzerothCore 3.3.5a** qui aide un joueur à localiser
les objectifs de ses quêtes en cours (zone/coordonnées), dans l'esprit de
QuestHelper / Questie — avec, en plus du module serveur, un
**addon client** compagnon qui affiche ces objectifs sous forme d'icônes sur
la **minimap** (voir [`client-addon/QuestRadar/`](client-addon/QuestRadar)).

## Captures d'écran

| Icône minimap (objectif numéroté + zone) | Vue en jeu |
|---|---|
| ![Icône minimap](scrn/minimap-icon-closeup.jpg) | ![Vue en jeu](scrn/ingame-view.jpg) |

## Pourquoi deux parties (module serveur + addon client)

Un module C++ AzerothCore tourne **côté serveur**, dans `worldserver`. Il ne
peut pas dessiner une icône sur la minimap du client 3.3.5a : c'est le
territoire de l'UI/Lua Blizzard, que seul un **addon client** peut modifier.
QuestHelper et Questie sont eux-mêmes 100% des addons client — et WotLK 3.3.5
n'a aucun équivalent natif (cette fonctionnalité est arrivée plus tard,
notamment avec Questie).

Ce module fournit donc :

1. **Le module serveur** (`src/`) : calcule, à partir des données déjà
   présentes en base (`quest_poi` / `quest_poi_points`), quels objectifs de
   quête sont connus sur la carte actuelle du joueur, et les affiche dans le
   chat (`.questradar`) ou via un **pont de communication addon**
   (`CHAT_MSG_ADDON` / `LANG_ADDON`) vers un addon client.
2. **L'addon client** (`client-addon/QuestRadar/`) : interroge ce pont à
   chaque changement de zone/quête (et périodiquement) et dessine, sur la
   minimap, une icône par objectif **suivi** (comportement par défaut —
   configurable) (plus une zone circulaire quand l'objectif n'est pas un
   point précis), à partir d'un delta joueur/objectif calculé côté serveur —
   sans dépendre d'aucune bibliothèque Lua tierce (voir le README de l'addon
   pour savoir pourquoi). Configurable via `/qr` ou un panneau d'options
   natif (Échap > Interface > Addons). La carte du monde n'a pas besoin
   d'être gérée : WotLK y dessine déjà nativement les POI de quête.
   **Testé en conditions réelles** sur un serveur AzerothCore 3.3.5a — voir
   le [README dédié](client-addon/QuestRadar/README.md) pour l'installation
   et l'historique des tentatives (une bibliothèque tierce, HereBeDragons, a
   d'abord été essayée puis abandonnée après plusieurs incompatibilités
   observées en jeu avec un client 3.3.5a authentique).

## Fonctionnalités

- Annonce automatiquement dans le chat, à l'acceptation d'une quête, les
  objectifs connus les plus proches (`QuestRadar.AnnounceOnAccept`).
- Commande manuelle `.questradar` (alias `.qr`) : liste les objectifs les
  plus proches pour chaque quête en cours sur la carte actuelle.
- Ne s'appuie que sur des données déjà chargées par le core
  (`ObjectMgr::GetQuestPOIVector`, tables `quest_poi` / `quest_poi_points`) :
  aucune nouvelle table, aucun import SQL nécessaire.
- Une quête sans donnée `quest_poi` (fréquent pour des quêtes classiques peu
  documentées) est silencieusement ignorée plutôt que d'afficher une
  position erronée.
- Pont de communication addon (`QuestRadar.AddonSyncEnabled`) : répond aux
  requêtes de l'addon client avec la position du joueur et la liste
  complète (pas seulement le top 3) des objectifs connus sur la carte
  actuelle, pour l'affichage minimap.

## Compatibilité

- ✅ AzerothCore 3.3.5a (branche `master`, API core "moderne" :
  hooks `PlayerScript`/`WorldScript`, `Acore::ChatCommands`)
- Aucune dépendance à Eluna ni à un autre module.

## Installation

### 1. Copier le module

```bash
cp -r mod-quest-radar/ <azerothcore>/modules/
```

Garder le dossier nommé **`mod-quest-radar`** (ou, si vous le renommez,
mettre à jour en conséquence le nom de la fonction
`Addmod_quest_radarScripts()` dans `src/QuestRadarLoader.cpp` — voir le
commentaire dans ce fichier, le système de build d'AzerothCore dérive ce nom
à partir du nom du dossier).

### 2. Compiler

```bash
cd <azerothcore>/build
cmake .. -DMODULES_FOLDER=../modules
make -j$(nproc)
```

### 3. Configurer

```bash
cp conf/mod-questradar.conf.dist <worldserver_dir>/mod-questradar.conf
```

### 4. Démarrer worldserver

Le module se charge automatiquement. Vérifier les logs :
```
mod-questradar: Loaded - Enabled=1 AnnounceOnAccept=1 MaxObjectivesShown=3 AddonSyncEnabled=1
```

### 5. Installer l'addon client (optionnel, pour les icônes minimap)

Copier `client-addon/QuestRadar/` dans `Interface/AddOns/` du client WoW
3.3.5a de chaque joueur qui veut les icônes (le module serveur continue de
fonctionner seul, sans lui, via `.questradar`) :

```bash
cp -r mod-quest-radar/client-addon/QuestRadar/ <client_wow>/Interface/AddOns/
```

Voir le [README de l'addon](client-addon/QuestRadar/README.md) pour le
détail de l'installation et son statut.

## Structure des fichiers

```
mod-quest-radar/
├── conf/
│   └── mod-questradar.conf.dist
├── README.md
├── data/
│   └── sql/
│       └── db-world/          # réservé pour une évolution future (vide pour l'instant)
├── src/
│   ├── QuestRadar.h           # config + structures + prototypes
│   ├── QuestRadar.cpp         # logique : recherche des objectifs + formatage du protocole addon
│   └── QuestRadarLoader.cpp   # hooks PlayerScript/WorldScript, commande .questradar, pont addon
└── client-addon/
    └── QuestRadar/             # addon Lua client (voir son propre README)
        ├── QuestRadar.toc
        ├── Core.lua             # protocole addon (envoi de REQ, réception de ME/OBJ/END), réglages
        ├── Minimap.lua          # icônes + zones minimap (delta joueur/objectif, sans lib Lua tierce)
        ├── Options.lua          # panneau d'options natif (Échap > Interface > Addons)
        └── Icons/               # glow.blp (image importée, voir Icons/README.md)
```

## Hooks utilisés

| Hook | Quand | Action |
|---|---|---|
| `OnBeforeConfigLoad` | Démarrage / `.reload config` | Charge la config `.conf` |
| `OnPlayerQuestAccept` | Le joueur accepte une quête | Annonce les objectifs les plus proches (si activé) |
| `OnPlayerBeforeSendChatMessage` | L'addon client s'auto-chuchote une requête `REQ` | Répond avec les objectifs connus (pont addon) |
| Commande `.questradar` / `.qr` | À la demande du joueur | Annonce les objectifs les plus proches |

## Feuille de route

L'affichage minimap (addon + pont de communication), le filtrage par
quêtes suivies, et un panneau d'options sont désormais implémentés — voir
[`client-addon/QuestRadar/`](client-addon/QuestRadar). Idées d'amélioration
restantes, non encore implémentées :

- Taille/couleur d'icône configurable (actuellement en dur dans
  `Minimap.lua`).
