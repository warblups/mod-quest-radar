/*
 * mod-quest-radar - C++ module for AzerothCore 3.3.5a
 */

#ifndef MOD_QUESTRADAR_H
#define MOD_QUESTRADAR_H

#include "Player.h"
#include <string>
#include <vector>

struct QuestRadarConfig
{
    bool   Enabled            = true;
    bool   AnnounceOnAccept   = true;
    uint32 MaxObjectivesShown = 3;
    bool   AddonSyncEnabled   = true;
};

extern QuestRadarConfig sQuestRadarConfig;

// Addon message prefix (CHAT_MSG_ADDON / LANG_ADDON, the player self-
// whispering on the client side) used by the server<->addon bridge. Must
// stay in sync with ADDON_PREFIX in client-addon/QuestRadar/Core.lua - see
// the protocol doc above QuestRadar_BuildAddonSyncMessages.
constexpr char const* QUESTRADAR_ADDON_PREFIX = "QuestRadar";

// One group of `quest_poi` points (= one precise objective of a quest, in
// the sense the world map shows it: one numbered yellow circle per group,
// not one per quest). A quest with several distinct objectives (e.g. "kill
// the boars" AND "bring this back to NPC X, elsewhere on the map") therefore
// has SEVERAL entries here, each with its own `poiId`/`objectiveIndex` -
// this module does not collapse them into a single "nearest" one per quest.
// That was tried (one icon per quest, the nearest among all its groups) and
// observed in-game to make the "winning" group change from one sync to the
// next as soon as the player moved, making the icon jump to a far-away spot
// - one stable icon per group avoids that problem.
struct QuestRadarObjective
{
    uint32      questId;
    std::string questTitle;
    // Id of the `quest_poi` group (`QuestPOI::Id`): the stable key used
    // client-side to associate an icon/area with THIS specific group (not
    // just the quest), so that the same questId with several groups shows
    // several independent icons instead of one that jumps between them.
    uint32      poiId;
    float       x;        // precise point nearest to the player, within this group (for display/tooltip)
    float       y;
    float       distance;
    // Approximate area of the objective (centroid + radius enclosing all
    // points of THIS group): a group can have several points when the
    // objective isn't a precise spot (e.g. "kill boars somewhere in this
    // area") - this is what the world map already shows as a blob rather
    // than a single point. areaRadius is 0 when the group only has one
    // point (nothing more to draw than the precise point).
    float       areaX;
    float       areaY;
    float       areaRadius;
    // Index (as stored in `quest_poi.ObjectiveIndex`) of the objective
    // within this quest - the same number shown natively in the yellow
    // circle on the world map (displayed +1, client side). Can be -1
    // (`quest_poi` convention for "not a specific numbered objective", e.g.
    // a generic quest turn-in spot) - the addon then shows no number.
    int32       objectiveIndex;
};

// Returns, sorted by increasing distance, the positions of every objective
// group (`quest_poi`) known for `player`'s current quests on the map they
// are on - one per group, not one per quest (see the QuestRadarObjective
// comment). Returns an empty vector if no `quest_poi` data is available for
// any of their quests (many classic quests don't have any).
std::vector<QuestRadarObjective> QuestRadar_GetNearbyObjectives(Player* player);

// Shows `player`, via their own chat, the `maxCount` nearest objectives
// returned by QuestRadar_GetNearbyObjectives().
void QuestRadar_AnnounceNearbyObjectives(Player* player, uint32 maxCount);

// Builds the response (as payloads, without the "QuestRadar\t" prefix nor
// the WorldPacket) to a "REQ" sync request sent by the client addon:
//   - a "ME\t<mapId>\t<x>\t<y>" payload with the player's own position
//     (same frame of reference as the objectives - the client has no
//     reliable way to know its own position in yards on a genuine 3.3.5a
//     client, cf. Minimap.lua on the addon side);
//   - one "OBJ\t<mapId>\t<questId>\t<poiId>\t<x>\t<y>\t<dist>\t<areaX>\t<areaY>\t<areaRadius>\t<objectiveIndex>\t<title>"
//     payload per objective group known on `player`'s current map (same
//     data as QuestRadar_GetNearbyObjectives, not limited by
//     MaxObjectivesShown - that only applies to the chat display);
//   - a final "END\t<mapId>\t<count>" payload signalling to the addon that
//     the sync is complete (letting it purge icons that are no longer
//     current).
// The actual network send (building the SMSG_MESSAGECHAT WorldPacket) is
// done by the caller, in QuestRadarLoader.cpp - this function only formats
// data.
std::vector<std::string> QuestRadar_BuildAddonSyncMessages(Player* player);

#endif // MOD_QUESTRADAR_H
