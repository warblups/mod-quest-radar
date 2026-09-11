# mod-quest-radar

*[Read this in English](README.md)*

Module C++ natif pour **AzerothCore 3.3.5a** qui aide un joueur à localiser
les objectifs de ses quêtes en cours (zone/coordonnées), dans l'esprit de
QuestHelper / Questie — avec, en plus du module serveur, un
**addon client** compagnon qui affiche ces objectifs sous forme d'icônes sur
la **minimap** (voir [`client-addon/QuestRadar/`](client-addon/QuestRadar)).

## Captures d'écran

| Une icône par objectif, numérotée par quête | Vue en jeu |
|---|---|
| ![Gros plan minimap](scrn/minimap-icon-closeup.jpg) | ![Vue en jeu](scrn/ingame-view.jpg) |

La quête 4 du suivi, *Les possessions de Solanian*, a trois objectifs à trois
endroits différents — le minimap porte donc **trois icônes marquées `4`**.

![Carte du monde et minimap côte à côte](scrn/worldmap-vs-minimap.jpg)

Même instant, mêmes quêtes. La carte du monde (à gauche) place **une** pastille
pour la quête 4 ; le minimap (à droite) en sépare les trois objectifs. Ce n'est
pas une faiblesse de la carte mais de l'API client qu'elle utilise :
`QuestPOIGetIconInfo(questId)` ne rend qu'une position par quête, donc une
pastille est tout ce que Blizzard peut dessiner. Les séparer demande le module
serveur, qui lit les mêmes tables `quest_poi` sans cette contrainte.

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
2. **L'addon client** (`client-addon/QuestRadar/`) : dessine les objectifs
   sous forme d'icônes sur la minimap. La carte du monde n'a pas besoin
   d'être gérée : WotLK y dessine déjà nativement les POI de quête.

### L'addon client ne dépend plus du module

L'addon livré dans [`client-addon/QuestRadar/`](client-addon/QuestRadar) lit
désormais les données POI **que le client 3.3.5a possède déjà**
(`QuestMapUpdateAllQuests` / `QuestPOIUpdateIcons` / `QuestPOIGetIconInfo`)
et les projette sur la minimap avec
[!Astrolabe](https://github.com/Trimitor/WDM-addons). Il fonctionne sur
n'importe quel AzerothCore dont la table `quest_poi` est remplie — **aucun
module serveur, aucune recompilation**. Vérifié en jeu.

L'addon d'origine, basé sur le pont, est conservé dans
[`client-addon/server-module-variant/`](client-addon/server-module-variant).
Il est gardé parce qu'il sait encore faire une chose hors de portée de l'API
client : le Lua 3.3.5a n'expose qu'**un POI par quête**, là où le module peut
fournir **un groupe par objectif** plus les zones circulaires. Réunir les
deux — autonome par défaut, par objectif quand le module est détecté — est
l'état visé, et ce n'est pas encore fait. Voir
[`client-addon/README.md`](client-addon/README.md).

À noter : le module et le client lisent la **même** source, les tables
`quest_poi` / `quest_poi_points`. La justification d'origine du module — le
client ne peut pas connaître sa position en yards, `UnitPosition` n'existant
pas en 3.3.5a — ne tient plus : !Astrolabe s'en charge.

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

Il lui faut également **`!Astrolabe`** dans le même `Interface/AddOns/`,
activé sur l'écran de sélection des addons — c'est lui qui convertit une
coordonnée de POI en position sur la minimap. Disponible dans
[Trimitor/WDM-addons](https://github.com/Trimitor/WDM-addons).

Cet addon n'a **pas** besoin du module serveur : il lit les données POI du
client lui-même. Voir le [README de l'addon](client-addon/QuestRadar/README.md),
et [`client-addon/README.md`](client-addon/README.md) pour la différence avec
la variante par pont, conservée.

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
└── client-addon/              # voir client-addon/README.md - un SEUL des deux peut être installé
    ├── QuestRadar/            # LIVRÉ : autonome, lit les données POI du client lui-même
    │   ├── QuestRadar.toc
    │   ├── QuestRadar.lua     # énumération des POI + projection minimap via !Astrolabe
    │   └── README.md
    └── server-module-variant/ # RÉFÉRENCE : récupère ses positions via ce module
        ├── QuestRadar.toc
        ├── Core.lua           # protocole addon (envoi de REQ, réception de ME/OBJ/END), réglages
        ├── Minimap.lua        # icônes + zones minimap (delta joueur/objectif)
        ├── Options.lua        # panneau d'options natif (Échap > Interface > Addons)
        └── Icons/             # glow.blp (image importée, voir Icons/README.md)
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
