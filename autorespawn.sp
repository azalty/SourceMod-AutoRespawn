/**
 * Auto Respawn V1.0
 * By David Y.
 * Modified from bobobagan's Player Respawn plugin V1.5 at
 * https://forums.alliedmods.net/showthread.php?t=108708
 * Repeat kill fix inspired by Repeat Kill Detector V1.02 by GoD-Tony at
 * https://forums.alliedmods.net/showthread.php?p=1504018
 *
 * Fixes auto-respawn infinite killing on maps with AFK or auto spawn killers.
 * Disables auto-respawn if the same player dies consecutively in too short a 
 * period of time. The plugin also takes into account the spawn delay when 
 * determining whether or not to disable the respawn for the current round.
 */

#pragma semicolon 1
#include <sourcemod>
#include <sdktools>

#undef REQUIRE_EXTENSIONS
#include <cstrike>
#include <tf2>
#define REQUIRE_EXTENSIONS

#undef REQUIRE_PLUGIN
#include <adminmenu>

new Handle:hAdminMenu = INVALID_HANDLE;
new Handle:g_hPlayerRespawn;
new Handle:g_hGameConfig;

// This will be used for checking which team the player is on before respawning them
#define SPECTATOR_TEAM 0
#define TEAM_SPEC      1
#define TEAM_1         2
#define TEAM_2         3

new Handle:sm_auto_respawn = INVALID_HANDLE;
new Handle:sm_auto_respawn_time = INVALID_HANDLE;
new Float:MapChecker[MAXPLAYERS+1];
new bool:g_bBlockRespawn = false;

public Plugin:myinfo =
{
	name = "Auto Respawn",
	author = "David",
	description = "Respawn dead players but disable if there is an auto-killer",
	version = "1.0",
	url = "http://forums.alliedmods.net/showthread.php?p=984087"
}

public OnPluginStart()
{
	CreateConVar("sm_respawn_version", "1.5", "Player Respawn Version", FCVAR_PLUGIN|FCVAR_SPONLY|FCVAR_REPLICATED|FCVAR_NOTIFY);
	sm_auto_respawn = CreateConVar("sm_auto_respawn", "0", "Automatically respawn players when they die; 0 - disabled, 1 - enabled");
	sm_auto_respawn_time = CreateConVar("sm_auto_respawn_time", "0.0", "How many seconds to delay the respawn");
	RegAdminCmd("sm_respawn", Command_Respawn, ADMFLAG_SLAY, "sm_respawn <#userid|name>");

	HookEvent("player_death", Event_PlayerDeath);
	HookEvent("round_start", Event_RoundStart, EventHookMode_PostNoCopy);

	new Handle:topmenu;
	if (LibraryExists("adminmenu") && ((topmenu = GetAdminTopMenu()) != INVALID_HANDLE))
	{
		OnAdminMenuReady(topmenu);
	}

	decl String:game[40];
	GetGameFolderName(game, sizeof(game));
	if (StrEqual(game, "dod"))
	{
		// Next 14 lines of text are taken from Andersso's DoDs respawn plugin. Thanks :)
		g_hGameConfig = LoadGameConfigFile("plugin.respawn");

		if (g_hGameConfig == INVALID_HANDLE)
		{
			SetFailState("Fatal Error: Missing File \"plugin.respawn\"!");
		}

		StartPrepSDKCall(SDKCall_Player);
		PrepSDKCall_SetFromConf(g_hGameConfig, SDKConf_Signature, "DODRespawn");
		g_hPlayerRespawn = EndPrepSDKCall();

		if (g_hPlayerRespawn == INVALID_HANDLE)
		{
			SetFailState("Fatal Error: Unable to find signature for \"CDODPlayer::DODRespawn(void)\"!");
		}
	}

	LoadTranslations("common.phrases");
	LoadTranslations("respawn.phrases");
	AutoExecConfig(true, "respawn");
}

public Action:Command_Respawn(client, args)
{
	if (args < 1)
	{
		ReplyToCommand(client, "[SM] Usage: sm_respawn <#userid|name>");
		return Plugin_Handled;
	}

	new String:arg[65];
	GetCmdArg(1, arg, sizeof(arg));

	new String:target_name[MAX_TARGET_LENGTH];
	new target_list[MaxClients], target_count, bool:tn_is_ml;

	target_count = ProcessTargetString(
					arg,
					client,
					target_list,
					MaxClients,
					COMMAND_FILTER_DEAD,
					target_name,
					sizeof(target_name),
					tn_is_ml);


	if(target_count <= COMMAND_TARGET_NONE) 	// If we don't have dead players
	{
		ReplyToTargetError(client, target_count);
		return Plugin_Handled;
	}

	// Team filter dead players, re-order target_list array with new_target_count
	new target, team, new_target_count;

	for (new i = 0; i < target_count; i++)
	{
		target = target_list[i];
		team = GetClientTeam(target);

		if(team >= 2)
		{
			target_list[new_target_count] = target; // re-order
			new_target_count++;
		}
	}

	if(new_target_count == COMMAND_TARGET_NONE) // No dead players from  team 2 and 3
	{
		ReplyToTargetError(client, new_target_count);
		return Plugin_Handled;
	}

	target_count = new_target_count; // re-set new value.

	if (tn_is_ml)
	{
		ShowActivity2(client, "[SM] ", "%t", "Toggled respawn on target", target_name);
	}
	else
	{
		ShowActivity2(client, "[SM] ", "%t", "Toggled respawn on target", "_s", target_name);
	}

	for (new i = 0; i < target_count; i++)
	{
		RespawnPlayer(client, target_list[i]);
	}

	return Plugin_Handled;
}

public OnClientDisconnect(client)
{
	MapChecker[client] = 0.0;
}

public Event_RoundStart(Handle:event, const String:name[], bool:dontBroadcast)
{
	g_bBlockRespawn = false;
}

public Event_PlayerDeath(Handle:event, const String:name[], bool:dontBroadcast)
{
	if(g_bBlockRespawn) return; // if disabled already, return nothing
	
	if (GetConVarInt(sm_auto_respawn) == 1)
	{
		// Get event info
		new client = GetClientOfUserId(GetEventInt(event, "userid"));
		new team = GetClientTeam(client);
		new attackerId = GetEventInt(event, "attacker");
		new attacker = GetClientOfUserId(attackerId);
		
		decl String:weapon[32];
		GetEventString(event, "weapon", weapon, sizeof(weapon));
	
		if (client && !attacker && StrEqual(weapon, "trigger_hurt"))
		{
			new Float:fGameTime = GetGameTime();
			new Float:respawnTime = GetConVarFloat(sm_auto_respawn_time);
			
			if ((fGameTime - MapChecker[client] - respawnTime) < respawnTime)
			{
				PrintToChatAll("\x04[Auto Respawner]\x01 Repeat killer detected. Disabling respawn for this round.");
				g_bBlockRespawn = true;
			}
			else {
				// create the respawn for CTs or Ts
				if(IsClientInGame(client) && (team == TEAM_1 || team == TEAM_2))
				{
					CreateTimer(GetConVarFloat(sm_auto_respawn_time), RespawnPlayer2, client, TIMER_FLAG_NO_MAPCHANGE);
				}
			}
			MapChecker[client] = fGameTime; // store the current time for the given player for next calculation
		}
	}
}

public RespawnPlayer(client, target)
{
	decl String:game[40];
	GetGameFolderName(game, sizeof(game));
	LogAction(client, target, "\"%L\" respawned \"%L\"", client, target);

	if(StrEqual(game, "cstrike") || StrEqual(game, "csgo"))
	{
		CS_RespawnPlayer(target);
	}
	else if (StrEqual(game, "tf"))
	{
		TF2_RespawnPlayer(target);
	}
	else if (StrEqual(game, "dod"))
	{
		SDKCall(g_hPlayerRespawn, target);
	}
}

public Action:RespawnPlayer2(Handle:Timer, any:client)
{
	decl String:game[40];
	GetGameFolderName(game, sizeof(game));

	if(StrEqual(game, "cstrike") || StrEqual(game, "csgo"))
	{
		CS_RespawnPlayer(client);
	}
	else if (StrEqual(game, "tf"))
	{
		TF2_RespawnPlayer(client);
	}
	else if (StrEqual(game, "dod"))
	{
		SDKCall(g_hPlayerRespawn, client);
	}
}

public OnLibraryRemoved(const String:name[])
{
	if (StrEqual(name, "adminmenu")) 
	{
		hAdminMenu = INVALID_HANDLE;
	}
}

public OnAdminMenuReady(Handle:topmenu)
{
	if (topmenu == hAdminMenu)
	{
		return;
	}
	
	hAdminMenu = topmenu;

	new TopMenuObject:player_commands = FindTopMenuCategory(hAdminMenu, ADMINMENU_PLAYERCOMMANDS);

	if (player_commands != INVALID_TOPMENUOBJECT)
	{
		AddToTopMenu(hAdminMenu,
		"sm_respawn",
		TopMenuObject_Item,
		AdminMenu_Respawn,
		player_commands,
		"sm_respawn",
		ADMFLAG_SLAY);
	}
}

public AdminMenu_Respawn( Handle:topmenu, TopMenuAction:action, TopMenuObject:object_id, param, String:buffer[], maxlength )
{
	if (action == TopMenuAction_DisplayOption)
	{
		Format(buffer, maxlength, "Respawn Player");
	}
	else if( action == TopMenuAction_SelectOption)
	{
		DisplayPlayerMenu(param);
	}
}

DisplayPlayerMenu(client)
{
	new Handle:menu = CreateMenu(MenuHandler_Players);

	decl String:title[100];
	Format(title, sizeof(title), "Choose Player to Respawn:");
	SetMenuTitle(menu, title);
	SetMenuExitBackButton(menu, true);

	// AddTargetsToMenu(menu, client, true, false);
	// Lets only add dead players to the menu... we don't want to respawn alive players do we?
	AddTargetsToMenu2(menu, client, COMMAND_FILTER_DEAD);

	DisplayMenu(menu, client, MENU_TIME_FOREVER);
}

public MenuHandler_Players(Handle:menu, MenuAction:action, param1, param2)
{
	if (action == MenuAction_End)
	{
		CloseHandle(menu);
	}
	else if (action == MenuAction_Cancel)
	{
		if (param2 == MenuCancel_ExitBack && hAdminMenu != INVALID_HANDLE)
		{
			DisplayTopMenu(hAdminMenu, param1, TopMenuPosition_LastCategory);
		}
	}
	else if (action == MenuAction_Select)
	{
		decl String:info[32];
		new userid, target;

		GetMenuItem(menu, param2, info, sizeof(info));
		userid = StringToInt(info);

		if ((target = GetClientOfUserId(userid)) == 0)
		{
			PrintToChat(param1, "[SM] %t", "Player no longer available");
		}
		else if (!CanUserTarget(param1, target))
		{
			PrintToChat(param1, "[SM] %t", "Unable to target");
		}
		else
		{
			new String:name[32];
			GetClientName(target, name, sizeof(name));

			RespawnPlayer(param1, target);
			ShowActivity2(param1, "[SM] ", "%t", "Toggled respawn on target", "_s", name);
		}

		/* Re-draw the menu if they're still valid */
		if (IsClientInGame(param1) && !IsClientInKickQueue(param1))
		{
			DisplayPlayerMenu(param1);
		}
	}
}