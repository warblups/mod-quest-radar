/*
 * mod-quest-radar - C++ module for AzerothCore 3.3.5a
 */

#include "QuestRadar.h"
#include "Chat.h"
#include "ObjectMgr.h"
#include "QuestDef.h"
#include <algorithm>
#include <cmath>
#include <iomanip>
#include <sstream>

QuestRadarConfig sQuestRadarConfig;

std::vector<QuestRadarObjective> QuestRadar_GetNearbyObjectives(Player* player)
{
    std::vector<QuestRadarObjective> result;
    if (!player)
        return result;

    uint32 mapId = player->GetMapId();

    for (uint16 slot = 0; slot < MAX_QUEST_LOG_SIZE; ++slot)
    {
        uint32 questId = player->GetQuestSlotQuestId(slot);
        if (!questId)
            continue;

        if (player->GetQuestStatus(questId) != QUEST_STATUS_INCOMPLETE)
            continue;

        Quest const* quest = sObjectMgr->GetQuestTemplate(questId);
        if (!quest)
            continue;

        // `quest_poi` / `quest_poi_points` data: the same data sent to the
        // client for the quest log's "Objectives" tab.
        QuestPOIVector const* poiVector = sObjectMgr->GetQuestPOIVector(questId);
        if (!poiVector)
            continue; // no known location data for this quest

        // One group (= one objective) per QuestPOI entry on this map - not
        // the single "best" group across all quests/objectives. See the
        // QuestRadarObjective comment (QuestRadar.h): keeping only one
        // "nearest" point per quest made the icon jump between distant
        // groups from one sync to the next.
        for (QuestPOI const& poi : *poiVector)
        {
            if (poi.MapId != mapId || poi.points.empty())
                continue;

            float bestDist = -1.0f;
            float bestX = 0.0f;
            float bestY = 0.0f;
            float sumX = 0.0f;
            float sumY = 0.0f;

            for (QuestPOIPoint const& point : poi.points)
            {
                float dist = player->GetDistance2d(float(point.x), float(point.y));
                if (bestDist < 0.0f || dist < bestDist)
                {
                    bestDist = dist;
                    bestX = float(point.x);
                    bestY = float(point.y);
                }
                sumX += float(point.x);
                sumY += float(point.y);
            }

            // Approximate area: centroid + radius enclosing all points of
            // this group. A single point (the common case) gives a radius
            // of 0 - nothing more to draw than the precise point.
            float areaX = sumX / poi.points.size();
            float areaY = sumY / poi.points.size();
            float areaRadius = 0.0f;
            for (QuestPOIPoint const& point : poi.points)
            {
                float dx = float(point.x) - areaX;
                float dy = float(point.y) - areaY;
                float r = std::sqrt(dx * dx + dy * dy);
                if (r > areaRadius)
                    areaRadius = r;
            }

            result.push_back({ questId, quest->GetTitle(), poi.Id, bestX, bestY, bestDist, areaX, areaY, areaRadius, poi.ObjectiveIndex });
        }
    }

    std::sort(result.begin(), result.end(),
        [](QuestRadarObjective const& a, QuestRadarObjective const& b)
        {
            return a.distance < b.distance;
        });

    return result;
}

void QuestRadar_AnnounceNearbyObjectives(Player* player, uint32 maxCount)
{
    if (!player || !player->GetSession())
        return;

    ChatHandler handler(player->GetSession());
    std::vector<QuestRadarObjective> objectives = QuestRadar_GetNearbyObjectives(player);

    if (objectives.empty())
    {
        handler.PSendSysMessage("|cffffcc00[QuestRadar]|r No locatable quest objective on this map.");
        return;
    }

    // QuestRadar_GetNearbyObjectives now returns one group per objective,
    // not one per quest (see QuestRadarObjective): a quest with several
    // distinct objectives could therefore appear here more than once. For
    // the chat announce, only keep its nearest group (the first one
    // encountered - the list is already sorted by distance).
    std::vector<uint32> announcedQuestIds;
    uint32 shown = 0;
    for (QuestRadarObjective const& obj : objectives)
    {
        if (shown >= maxCount)
            break;

        if (std::find(announcedQuestIds.begin(), announcedQuestIds.end(), obj.questId) != announcedQuestIds.end())
            continue;
        announcedQuestIds.push_back(obj.questId);

        handler.PSendSysMessage("|cffffcc00[QuestRadar]|r {} - {} yd (X: {:.1f}, Y: {:.1f})",
            obj.questTitle, uint32(obj.distance), obj.x, obj.y);
        ++shown;
    }
}

std::vector<std::string> QuestRadar_BuildAddonSyncMessages(Player* player)
{
    std::vector<std::string> messages;
    if (!player)
        return messages;

    uint32 mapId = player->GetMapId();
    std::vector<QuestRadarObjective> objectives = QuestRadar_GetNearbyObjectives(player);

    // The player's own position: the client has no reliable way to know it
    // in yards (the modern "Classic" client's "UnitPosition" API doesn't
    // exist on a genuine 3.3.5.12340 client - verified in-game). By sending
    // it here, in the same frame of reference as the objectives, the addon
    // just computes a plain delta (objective - player) without needing to
    // know any map/continent coordinate system client-side.
    {
        std::ostringstream me;
        me << "ME\t" << mapId << '\t'
            << std::fixed << std::setprecision(1) << player->GetPositionX() << '\t' << player->GetPositionY();
        messages.push_back(me.str());
    }

    for (QuestRadarObjective const& obj : objectives)
    {
        // The title goes in the payload's last field ("\t"-separated): it
        // is truncated and any tab neutralized so it doesn't break the
        // parsing on the addon side (client-addon/QuestRadar/Core.lua).
        std::string title = obj.questTitle;
        if (title.size() > 60)
            title.resize(60);
        std::replace(title.begin(), title.end(), '\t', ' ');

        std::ostringstream oss;
        oss << "OBJ\t" << mapId << '\t' << obj.questId << '\t' << obj.poiId << '\t'
            << std::fixed << std::setprecision(1) << obj.x << '\t' << obj.y << '\t' << obj.distance << '\t'
            << obj.areaX << '\t' << obj.areaY << '\t' << obj.areaRadius << '\t' << obj.objectiveIndex
            << '\t' << title;
        messages.push_back(oss.str());
    }

    std::ostringstream end;
    end << "END\t" << mapId << '\t' << objectives.size();
    messages.push_back(end.str());

    return messages;
}
