/*
 * mod-quest-radar - C++ module for AzerothCore 3.3.5a
 */

#include "QuestRadar.h"
#include "Chat.h"
#include "CommandScript.h"
#include "Config.h"
#include "Log.h"
#include "Opcodes.h"
#include "Player.h"
#include "ScriptMgr.h"
#include "SharedDefines.h"
#include "WorldPacket.h"

using namespace Acore::ChatCommands;

// ---------------------------------------------------------------------------
// Config
// ---------------------------------------------------------------------------
static void LoadQuestRadarConfig()
{
    sQuestRadarConfig.Enabled            = sConfigMgr->GetOption<bool>  ("QuestRadar.Enable",             true);
    sQuestRadarConfig.AnnounceOnAccept   = sConfigMgr->GetOption<bool>  ("QuestRadar.AnnounceOnAccept",   true);
    sQuestRadarConfig.MaxObjectivesShown = sConfigMgr->GetOption<uint32>("QuestRadar.MaxObjectivesShown", 3);
    sQuestRadarConfig.AddonSyncEnabled   = sConfigMgr->GetOption<bool>  ("QuestRadar.AddonSyncEnabled",   true);

    LOG_INFO("module", "mod-questradar: Loaded - Enabled={} AnnounceOnAccept={} MaxObjectivesShown={} AddonSyncEnabled={}",
        sQuestRadarConfig.Enabled, sQuestRadarConfig.AnnounceOnAccept, sQuestRadarConfig.MaxObjectivesShown,
        sQuestRadarConfig.AddonSyncEnabled);
}

// ===========================================================================
// WorldScript - (re)loads the config on startup and on .reload config
// ===========================================================================
class QuestRadar_WorldScript : public WorldScript
{
public:
    QuestRadar_WorldScript() : WorldScript("QuestRadar_WorldScript") {}

    void OnBeforeConfigLoad(bool /*reload*/) override
    {
        LoadQuestRadarConfig();
    }
};

// ===========================================================================
// PlayerScript
// ===========================================================================
class QuestRadar_PlayerScript : public PlayerScript
{
public:
    QuestRadar_PlayerScript() : PlayerScript("QuestRadar_PlayerScript") {}

    void OnPlayerQuestAccept(Player* player, Quest const* /*quest*/) override
    {
        if (!sQuestRadarConfig.Enabled || !sQuestRadarConfig.AnnounceOnAccept)
            return;

        QuestRadar_AnnounceNearbyObjectives(player, sQuestRadarConfig.MaxObjectivesShown);
    }
};

// ===========================================================================
// Server <-> client addon communication bridge
// (CHAT_MSG_ADDON / LANG_ADDON, cf. SharedDefines.h)
// ===========================================================================
// Protocol (prefix QUESTRADAR_ADDON_PREFIX = "QuestRadar", see
// QuestRadar.h):
//   Client -> Server: the addon self-whispers "QuestRadar\tREQ" (via
//     SendAddonMessage) every time it wants to refresh its icons (zone
//     change, quest accepted/turned in, login...).
//   Server -> Client: this module replies with a series of messages, one
//     per objective known on the player's current map (cf.
//     QuestRadar_BuildAddonSyncMessages), followed by an end marker.
// Both ends (this file and client-addon/QuestRadar/Core.lua) must stay in
// sync on the prefix and the REQ/OBJ/END keywords.
//
// Packet construction: see the AzerothCore "How to use the Warden Payload
// Manager" doc (www.azerothcore.org/wiki/how-to-use-warden-payload-mgr),
// which documents this same SMSG_MESSAGECHAT/LANG_ADDON mechanism for
// sending an addon message from server to client.
static void SendQuestRadarAddonMessage(Player* player, std::string const& payload)
{
    if (!player || !player->GetSession())
        return;

    std::string fullMsg = std::string(QUESTRADAR_ADDON_PREFIX) + "\t" + payload;
    size_t len = fullMsg.length();

    WorldPacket data;
    data.Initialize(SMSG_MESSAGECHAT, 1 + 4 + 8 + 4 + 8 + 4 + 1 + len + 1);
    data << uint8(CHAT_MSG_WHISPER);
    data << uint32(LANG_ADDON);
    data << uint64(player->GetGUID().GetRawValue());
    data << uint32(0);
    data << uint64(player->GetGUID().GetRawValue());
    data << uint32(len + 1);
    data << fullMsg;
    data << uint8(0);

    player->SendDirectMessage(&data);
}

class QuestRadar_AddonCommsScript : public PlayerScript
{
public:
    QuestRadar_AddonCommsScript() : PlayerScript("QuestRadar_AddonCommsScript") {}

    // Intercepts the whisper the client addon sends itself to carry its
    // addon messages (standard technique: there is no dedicated addon
    // channel for the client -> server direction, only whisper/party/
    // guild/channel tagged LANG_ADDON). type/lang/msg are never modified
    // here: the content is only read to build a reply.
    void OnPlayerBeforeSendChatMessage(Player* player, uint32& type, uint32& lang, std::string& msg) override
    {
        if (!sQuestRadarConfig.Enabled || !sQuestRadarConfig.AddonSyncEnabled)
            return;

        if (type != CHAT_MSG_WHISPER || lang != LANG_ADDON)
            return;

        size_t sep = msg.find('\t');
        if (sep == std::string::npos)
            return;

        if (msg.compare(0, sep, QUESTRADAR_ADDON_PREFIX) != 0)
            return; // addon message from a different addon than ours

        std::string command = msg.substr(sep + 1);
        if (command != "REQ")
            return;

        for (std::string const& payload : QuestRadar_BuildAddonSyncMessages(player))
            SendQuestRadarAddonMessage(player, payload);
    }
};

// ===========================================================================
// CommandScript - manual ".questradar" / ".qr" command
// ===========================================================================
class questradar_commandscript : public CommandScript
{
public:
    questradar_commandscript() : CommandScript("questradar_commandscript") { }

    ChatCommandTable GetCommands() const override
    {
        static ChatCommandTable commandTable =
        {
            { "questradar", HandleQuestRadarCommand, SEC_PLAYER, Console::No },
            { "qr",         HandleQuestRadarCommand, SEC_PLAYER, Console::No },
        };
        return commandTable;
    }

    static bool HandleQuestRadarCommand(ChatHandler* handler)
    {
        if (!sQuestRadarConfig.Enabled)
        {
            handler->PSendSysMessage("|cffffcc00[QuestRadar]|r The module is disabled (QuestRadar.Enable = 0).");
            return true;
        }

        Player* player = handler->GetSession() ? handler->GetSession()->GetPlayer() : nullptr;
        if (!player)
            return false;

        QuestRadar_AnnounceNearbyObjectives(player, sQuestRadarConfig.MaxObjectivesShown);
        return true;
    }
};

// ===========================================================================
// Module entry point.
// NOTE: the name of this function is dictated by AzerothCore's module build
// system: "Add" + <module folder name, any '-' replaced with '_', case
// preserved> + "Scripts" (see modules/CMakeLists.txt::ConfigureScriptLoader
// in azerothcore-wotlk). If this folder is copied/renamed differently under
// <azerothcore>/modules/, rename this function to match.
// ===========================================================================
void Addmod_quest_radarScripts()
{
    new QuestRadar_WorldScript();
    new QuestRadar_PlayerScript();
    new QuestRadar_AddonCommsScript();
    new questradar_commandscript();
}
