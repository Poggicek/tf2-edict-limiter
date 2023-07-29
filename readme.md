
# TF2 Edict Limiter
Ported to TF2 from https://forums.alliedmods.net/showthread.php?t=340973

This plugin prevents the server from crashing because of no remaining free edicts, crash known as "ED_Alloc: no free edicts".
When there's more edicts than ed_lowedict_threshold allows no further entities will be allowed to be created unless the edict count goes below such threshold.

**Note**
When there are no left edicts (2048 max) the plugins prevents the creation of any new entities.
Improperly coded plugins will start throwing errors, as they won't check whether their newly created entity was actually created, **I do not take any responsibility for such errors.**

## Forwards
```c
forward void OnEntityLockdown(); // Fired when an edict limit is reached, get's called everytime the threshold is reached. Use this to cleanup less useful entities.
```
## Natives
```c
native int GetEdictCount(); // Returns current count of edicts, edicts are stored in a variable and changed in realtime. There should be no performance hit calling this native
```
## ConVars
```c
ed_lowedict_action "1"
// 0 - no action
// 1 - only prevent entity spawns
// 2 - attempt to restart the game, if applicable
// 3 - restart the map
// 4 - go to the next map in the map cycle
// 5 - spew all edicts.

ed_lowedict_threshold "8"
// When only this many edicts are free, take the action specified by sv_lowedict_action. (0 - 1920)

ed_lowedict_block_threshold "8"
// When only this many edicts are free, prevent entity spawns. (0 - 1920)
// Ideally keep the same as ed_lowedict_threshold
// 0 Disables entity spawn prevention, rather than allowing 0 free edicts and keeping the server on thin ice

ed_announce_cooldown "1"
// Cooldown preventing OnEntityLockdown forward from being called multiple times in a short period of time
```
## Commands
```c
sm_edictcount
// ROOT ONLY
// Shows current amount of free edicts
// Example: GetEntityCount: 1974 | Used edicts: 1625 | Used edicts (Precise, expensive): 1625

sm_spewedicts
// ROOT ONLY
// Dumps edict usage in server/client console
// Example:
// (Percent) Count Classname (Sorted by count)
// -------------------------------------------------
// (63.98%) 1043 prop_dynamic
// (5.09%) 83 ambient_generic
// ...
```