#include <sourcemod>
#include <sdktools>
#include <dhooks>
#pragma newdecls required
#pragma semicolon 1

bool edictExists[2049];

#define MAX_EDICTS 2048

bool announcedLimitation;
int edicts = 0;
float nextActionIn = 0.0;
GlobalForward g_entityLockdownForward;
ConVar g_cvLowEdictAction;
ConVar g_cvLowEdictThreshold;
ConVar g_cvLowEdictBlockThreshold;
ConVar g_cvForwardOnce;

public Plugin myinfo =
{
  name = "Edict Limiter",
  author = "Poggu",
  description = "Prevents edict limit crashes",
  version = "2.0.0"
};

public void OnMapStart()
{
  nextActionIn = 0.0;
}

public void OnPluginStart()
{
  // edicts = MaxClients + 1; // +1 for worldspawn
  edicts = ExpensivelyGetUsedEdicts();
  GameData hGameConf;
  char error[128];

  hGameConf = LoadGameConfigFile("edict_limiter");
  if(!hGameConf)
  {
    Format(error, sizeof error, "Failed to find edict_limiter gamedata");
    SetFailState(error);
  }

  Handle hDetour = DHookCreateFromConf(hGameConf, "IServerPluginCallbacks::OnEdictAllocated");
  if( !hDetour )
    SetFailState("Failed to find IServerPluginCallbacks::OnEdictAllocated");

  StartPrepSDKCall(SDKCall_Static);
  if(!PrepSDKCall_SetFromConf(hGameConf, SDKConf_Signature, "CreateInterface"))
      SetFailState("Failed to get CreateInterface");

  PrepSDKCall_AddParameter(SDKType_String, SDKPass_Pointer);
  PrepSDKCall_AddParameter(SDKType_PlainOldData, SDKPass_Pointer, VDECODE_FLAG_ALLOWNULL);
  PrepSDKCall_SetReturnInfo(SDKType_PlainOldData, SDKPass_Plain);

  Handle createInterfaceCall = EndPrepSDKCall();
  Address addr = SDKCall(createInterfaceCall, "ISERVERPLUGINHELPERS001", 0);
  if(!addr)
      SetFailState("Failed to get ISERVERPLUGINHELPERS001 ptr");

  DHookRaw(hDetour, true, addr, _, OnEdictAllocate);

  hDetour = DHookCreateFromConf(hGameConf, "IServerPluginCallbacks::OnEdictFreed");
  if( !hDetour )
    SetFailState("Failed to find IServerPluginCallbacks::OnEdictFreed");

  DHookRaw(hDetour, false, addr, _, OnEdictFreed);

  HookEngineEntities(hGameConf);
  delete hGameConf;

  RegAdminCmd("sm_edictcount", Command_EdictCount, ADMFLAG_ROOT);
  RegAdminCmd("sm_spewedicts", Command_SpewEdicts, ADMFLAG_ROOT);
  HookEvent("teamplay_round_start", EventRoundPreStart);

  g_entityLockdownForward = new GlobalForward("OnEntityLockdown", ET_Ignore);
  g_cvLowEdictAction = CreateConVar("ed_lowedict_action", "1", "0 - no action, 1 - only prevent entity spawns, 2 - attempt to restart the game, if applicable, 3 - restart the map, 4 - go to the next map in the map cycle, 5 - spew all edicts.", _, true, 0.0, true, 5.0);
  g_cvLowEdictThreshold = CreateConVar("ed_lowedict_threshold", "8", "When only this many edicts are free, take the action specified by sv_lowedict_action.", _, true, 0.0, true, 1920.0);
  g_cvLowEdictBlockThreshold = CreateConVar("ed_lowedict_block_threshold", "8", "When only this many edicts are free, prevent entity spawns.", _, true, 0.0, true, 1920.0);
  g_cvForwardOnce = CreateConVar("ed_announce_once", "1", "Whether OnEntityLockdown gets called only once per round", _, true, 0.0, true, 1.0);
}

public MRESReturn OnEdictAllocate(Handle hParams)
{
  int edict = DHookGetParam(hParams, 1);
  if(edict > MaxClients && !edictExists[edict]) // Engine reserves MaxClients edicts for players including wordspawn. We don't want to count those as they are always non-free.
  {
    edicts++;
    edictExists[edict] = true;
  }
  return MRES_Ignored;
}

public MRESReturn OnEdictFreed(Handle hParams)
{
  int edict = DHookGetParam(hParams, 1);
  if(edict > MaxClients && edictExists[edict])
  {
    edicts--;
    edictExists[edict] = false;
  }
  return MRES_Ignored;
}

public APLRes AskPluginLoad2(Handle plugin, bool late, char[] error, int err_max)
{
  RegPluginLibrary("EdictLimiter");
  CreateNative("GetEdictCount", Native_GetEdictCount);
  return APLRes_Success;
}

void HookEngineEntities(GameData hGameConf)
{
  Handle hCreateEntityByName = DHookCreateDetour(Address_Null, CallConv_THISCALL, ReturnType_Int, ThisPointer_Ignore);
  if (!hCreateEntityByName)
    SetFailState("Failed to setup detour for CEntityFactoryDictionary::Create");

  if (!DHookSetFromConf(hCreateEntityByName, hGameConf, SDKConf_Signature, "CEntityFactoryDictionary::Create"))
    SetFailState("Failed to load CEntityFactoryDictionary::Create signature from gamedata");

  DHookAddParam(hCreateEntityByName, HookParamType_CharPtr);

  if (!DHookEnableDetour(hCreateEntityByName, false, Detour_CreateEntityByName))
      SetFailState("Failed to detour CEntityFactoryDictionary::Create.");
}

// This is a list of entities that are allowed to be created even if the edict limit is reached, could result in a crash otherwise.
char ignoreEnts[][] = {"tf_bot", "player", "ai_network", "tf_player_manager", "worldspawn", "instanced_scripted_scene", "info_target", "tf_team", "tf_gamerules", "tf_objective_resource", "monster_resource", "tf_viewmodel", "scene_manager", "team_round_timer"};

public MRESReturn Detour_CreateEntityByName(Handle hReturn, Handle hParams)
{
  if(g_cvLowEdictAction.IntValue > 0 && MAX_EDICTS - edicts <= g_cvLowEdictThreshold.IntValue)
  {
    PrintToServer("[Edict Limiter] Warning: free edicts below threshold. %i free edict%s remaining", MAX_EDICTS - edicts, MAX_EDICTS - edicts == 1 ? "" : "s");

    if(!announcedLimitation || !g_cvForwardOnce.BoolValue)
    {
      AnnounceEntityLockDown();
      announcedLimitation = true;
    }

    if(nextActionIn <= GetGameTime() || nextActionIn == 0.0)
    {
      switch(g_cvLowEdictAction.IntValue)
      {
        case 2: // restart game
        {
          PrintToServer("Trying to restart game as requested by ed_lowedict_action");
          ServerCommand("mp_restartgame 1");
          nextActionIn = GetGameTime() + 1.0;
        }
        case 3: // restart map
        {
          PrintToServer("Trying to restart map as requested by ed_lowedict_action");
          char map[PLATFORM_MAX_PATH];
          GetCurrentMap(map, sizeof map);
          ForceChangeLevel(map, "Action of ed_lowedict_action");
          nextActionIn = GetGameTime() + 2.0;
        }
        case 4: // go to the next map
        {
          PrintToServer("Trying to cycle to the next map as requested by ed_lowedict_action");
          char map[PLATFORM_MAX_PATH];
          if(GetNextMap(map, sizeof map))
            ForceChangeLevel(map, "Action of ed_lowedict_action");
          else
            PrintToServer("[Edict Limiter] No available next map");

          nextActionIn = GetGameTime() + 1.0;
        }
        case 5: // spew all edicts
        {
          PrintToServer("Spewing edict counts as requested by ed_lowedict_action");
          SpewEdicts();
          nextActionIn = GetGameTime() + 5.0;
        }
      }
    }

    char classname[32];
    DHookGetParamString(hParams, 1, classname, sizeof classname);

    for(int i = 0; i < sizeof ignoreEnts; i++)
    {
      if(StrEqual(classname, ignoreEnts[i]))
      {
        return MRES_Ignored;
      }
    }

    if(g_cvLowEdictBlockThreshold.IntValue > 0 && MAX_EDICTS - edicts <= g_cvLowEdictBlockThreshold.IntValue)
    {
      PrintToServer("[Edict Limiter] Blocking entity creation of %s", classname);
      DHookSetReturn(hReturn, 0);
      return MRES_Supercede;
    }
  }

  return MRES_Ignored;
}

void AnnounceEntityLockDown()
{
  Call_StartForward(g_entityLockdownForward);
  Call_Finish();
}

int ExpensivelyGetUsedEdicts()
{
  int edict_ents = MaxClients + 1; // +1 for worldspawn
  for(int i = MaxClients + 1; i < MAX_EDICTS; i++)
  {
    if(IsValidEdict(i))
    {
      edict_ents++;
      edictExists[i] = true;
    }
  }

  return edict_ents;
}

public Action Command_EdictCount(int client, int args)
{
  ReplyToCommand(client, "GetEntityCount: %i | Used edicts: %i | Used edicts (Precise, expensive): %i", GetEntityCount(), edicts, ExpensivelyGetUsedEdicts());
  return Plugin_Handled;
}

public Action Command_SpewEdicts(int client, int args)
{
  if(client)
    PrintToChat(client, "Open console for edict spew");

  SpewEdicts(client);
  return Plugin_Handled;
}

public Action EventRoundPreStart(Event event, char[] name, bool dontBroadcast)
{
  announcedLimitation = false;
  return Plugin_Continue;
}

int Native_GetEdictCount(Handle plugin, int numParams)
{
  return edicts;
}

void SpewEdicts(int client = 0)
{
  StringMap classnames = new StringMap();
  ArrayList clsCount = new ArrayList(2);

  for(int i = 0; i < MAX_EDICTS; i++)
  {
    if(IsValidEdict(i))
    {
      char classname[64];
      GetEdictClassname(i, classname, sizeof classname);

      int index;
      bool isFound = classnames.GetValue(classname, index);
      if(!isFound)
      {
        int newIndex = clsCount.Push(1);
        classnames.SetValue(classname, newIndex);
        clsCount.Set(newIndex, newIndex, 1);
      }
      else
      {
        int count = clsCount.Get(index);
        clsCount.Set(index, count + 1);
      }
    }
  }

  clsCount.Sort(Sort_Descending, Sort_Integer);
  StringMapSnapshot clsSnapshot = classnames.Snapshot();

  if(client == 0)
  {
    PrintToServer("(Percent)  \tCount\tClassname (Sorted by count)");
    PrintToServer("-------------------------------------------------");
  }
  else
  {
    PrintToConsole(client, "(Percent)  \tCount\tClassname (Sorted by count)");
    PrintToConsole(client, "-------------------------------------------------");
  }
  for(int i = 0; i < clsCount.Length; i++)
  {
    int count = clsCount.Get(i);

    for(int x = 0; x < clsSnapshot.Length; x++)
		{
      char classname[64];
      clsSnapshot.GetKey(x, classname, sizeof classname);

      int index;
      if(classnames.GetValue(classname, index))
      {
        if(index == clsCount.Get(i, 1))
        {
          if(client == 0)
            PrintToServer("(%3.2f%%)  \t%i\t%s", float(count) / float(edicts) * 100.0, count, classname);
          else
            PrintToConsole(client, "(%3.2f%%)  \t%i\t%s", float(count) / float(edicts) * 100.0, count, classname);
          break;
        }
      }
    }
  }

  delete clsSnapshot;
  delete clsCount;
  delete classnames;

  if(client == 0)
    PrintToServer("Total edicts: %i", edicts);
  else
    PrintToConsole(client, "Total edicts: %i", edicts);
}