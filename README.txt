FRACTURED SPACE - SOLO TRAINER (TEAM MANAGER FIX13)
=====================================================

For the local SOLO spserver.exe only.


TEAM MANAGER FIX13
-----------------
- The trainer window is now wider with ALLIED TEAM on the left and ENEMY TEAM on the right.
- Enemy side has the same controls as allied side: ship dropdown, difficulty dropdown, spawn, team God Mode, live ship list, Delete Selected, and Delete All Enemies.
- Enemy team id is read from the real GameState.PlayerArray and cached, so enemy spawning can continue after Delete All Enemies.
- Allied and enemy rosters refresh automatically; there are no manual refresh buttons.
- Allied and enemy God Modes keep separate health locks and can be enabled independently.
- The working FIX7 allied spawn/delete logic is preserved and reused for the enemy side.
- Enemy roster ship names now prefer the live ShipPawn ShipLayoutGUID instead of PlayerState desiredShipGUID. This fixes Last Stand wave bots being mislabeled as Reaper when their actual pawn is another ship.

WHAT CHANGED
------------
1. Ship spawning now uses a scrollable SHIP dropdown.
2. Difficulty stays in its own dropdown.
3. The trainer uses the selected ship's internal FGuid BEFORE the bot pawn is
   spawned, instead of passing a display name as layoutName.
4. Allied Bot God Mode is more persistent:
   - partial scans are merged instead of replacing good results;
   - already-working locks are kept during refreshes;
   - respawning bots are retried automatically;
   - a new HealthComponent after respawn gets a fresh lock;
   - newly spawned trainer bots are added to the cache immediately;
   - quiet player-list refreshes run automatically while Allied God Mode is ON;
   - healing is allowed to raise the protected HP value.

QUICK START
-----------
1. Launch Fractured Space.
2. Start a SOLO match and wait until your ship is flying.
3. Double-click START_TRAINER.bat.
4. Wait for "Server: CONNECTED".
5. Choose a ship from the Ship dropdown.
6. Choose the bot difficulty.
7. Click SPAWN SELECTED SHIP ON MY TEAM.
8. Turn ALLIED BOT GOD MODE ON if you want allied ships protected.

SHIP MENU
---------
The old free-text layout box has been removed. Display names such as "Pioneer"
are mapped internally to the game's ship GUIDs. This avoids the invalid-layout
fallback that could make the server create Punisher instead of the requested
ship.

The selected GUID is written to the newly-created bot PlayerState before the
trainer asks the game's normal ServerSpawnBotShip path to create its pawn.
This is intended to preserve normal ship/AI/weapon initialization.

ALLIED GOD MODE
---------------
The old FIX2 version could lose previously found bots when a later player-state
scan returned only part of the match. It could also temporarily fail while a
bot had no Pawn during spawn/respawn.

This version keeps and merges known PlayerStates instead. A temporarily missing
Pawn is treated as "spawning/respawning" and retried. The status may show:

    Allied bots: 4 locked / 5 allied (1 spawning/respawning)

That is normal while one ship is between pawns. The trainer refreshes allied bot discovery automatically while Allied God Mode is enabled.

PLAYER GOD MODE
---------------
Player God Mode keeps the stable pointer path used by the working FIX2 build.

BUILD NOTE
----------
The native ship-selection helper is build-specific to the supplied spserver.exe.
The trainer checks key function signatures before using it. If the executable
changes, Spawn will refuse the helper rather than blindly calling the old RVA.

NOTES
-----
- This trainer targets only the local solo spserver.exe process.
- A different spserver.exe build can require updated offsets/function RVAs.
- If normal launch cannot access spserver.exe, use START_TRAINER_AS_ADMIN.bat.
- START_TRAINER_DEBUG.bat leaves PowerShell visible if you need an error message.


FIX 2 NOTES
-----------
- Selected-ship spawning now uses the game's validated desiredShipGUID setter before the normal bot ship spawn.
- The previous menu build wrote the GUID into the wrong PlayerState field (ForcedLoadout), which is why no pawn spawned.
- Allied God Mode keeps old locks and scans the memory area around your live PlayerState first, then expands outward.
- A partial refresh no longer erases bots that were already protected.


ALLY MANAGER UPDATE
-------------------
- Adds a scrollable allied-ship list with ship name, bot/player name, and status.
- Select a row and click DELETE SELECTED ALLY to remove that AI player from the local solo server.
- The local player is never placed in the delete list.
- Trainer-spawned and existing allied bots use the verified PlayerState name field for this exact build, so the delete list can target them by the same name the local server uses.
- Allied God Mode now caches validated controller addresses, which helps it keep following bots through brief Owner/Pawn gaps during spawn and respawn.


ALLY MANAGER FIX2
- Allied list now shows only validated LIVE allied ships (no raw/stale PlayerState names).
- DELETE SELECTED destroys the bot controller and ship actor together.
- DELETE ALL ALLIES removes every live ally in one operation (your own ship is excluded).
- PlayerState scanner now rejects stale same-class objects by validating Controller -> PlayerState back-links.


ALLY MANAGER FIX5
- Reverted the over-strict scanner check that caused the ally list to become empty.
- Live filtering still happens later through Controller/Pawn/HealthComponent validation, so stale rows are not intentionally displayed.
- Newly spawned controllers are tracked for up to 15 seconds until their PlayerState becomes available, so spawned ships can appear in the ally list even when creation is asynchronous.
- A successful native spawn is now final: optional roster/cache errors can no longer replace the success message with "argument types do not match".
- The ally list refresh is triggered after every successful spawn even when Allied God Mode is OFF.


FIX5 CHANGES:
- Spawned allies are registered directly from the BotController returned by the working spawn call.
- Ally list no longer depends on the PlayerState scanner for trainer-spawned ships.
- Newly spawned ships appear as Spawning until their Pawn is possessed, then Ready/God.
- Delete Selected / Delete All operate on these directly tracked controller+pawn pairs.
- Removed the local-controller prerequisite that could prevent the generic ally scan from starting at all.
- Existing/pre-match allied bots are still merged when the generic scan discovers them.


FIX5 CHANGES
------------
- Removed the old same-UClass process memory scan that could cache 500+ false PlayerStates.
- Allied roster and Allied God Mode now start from GameState.PlayerArray directly.
- If PlayerState.Owner is temporarily unavailable, ULevel.Actors is used to match a Pawn by Pawn.PlayerState.
- Trainer-spawned BotControllers are still tracked immediately, so a spawned ship can appear even before its PlayerState finishes initializing.
- Added a short post-spawn cooldown to reduce overlapping bot initialization when spawning repeatedly.

Important Windows PowerShell 5.1 fix:
- Ally roster code now uses normal PowerShell arrays instead of Generic.List[object]. The latter can trigger the misleading "Argument types do not match" binder error on Windows PowerShell 5.1 and could prevent the roster from rendering even after a successful spawn.

ALLY MANAGER FIX7
-----------------
- Removed the manual RESCAN ALLIED BOTS button; Allied God Mode refreshes automatically.
- Removed the manual REFRESH LIST button; the allied ship list refreshes automatically.
- Simplified the UI text and removed the internal implementation note from the main window.

ALLY MANAGER FIX7
-----------------
- Fixed the debug-log error after DELETE ALL ALLIES.
- FIX6 removed the REFRESH LIST button from the UI but two old lines still tried to enable/disable that deleted button.
- Those stale references are now removed. Delete All behavior itself is unchanged.


FIX13 changes:
- Enemy roster now ignores Final Stand small escort/frigate craft (beam/gunner/healer/kamikaze/missile/frigate/corvette classes).
- Enemy God Mode also ignores those minor craft so the enemy team count refers to full-size ships.
- Full-size ship names now use ShipPawn.GetShipGUID through the game's own virtual getter first. This avoids the unreliable pawn-class fallback that could label multiple Last Stand capitals as Furion.
- Raw ShipLayoutGUID and PlayerState desiredShipGUID remain fallbacks only.
- The live PlayerArray is refreshed about every 0.6 seconds so new full-size wave ships should appear quickly.


FIX13 - in-game bot difficulty verification
-------------------------------------------
- Both allied and enemy rosters now show a Difficulty column read directly from the live BotController.
- The value is read from the game's BotController difficulty-type field after the game has created/configured the bot.
- Spawn status now shows both the requested dropdown value and the value actually stored by the game, e.g.:
    requested Hard 3 | game Hard 3
- This is a diagnostic/read-back feature; the working FIX13 spawn, roster, delete, God Mode and Final Stand ship-name logic are otherwise unchanged.


FIX13 - DEBUG DIFFICULTY VERIFICATION
-------------------------------------
Use START_TRAINER_DEBUG.bat when you want to verify bot difficulty.

Every trainer-spawned full-size bot prints a LIVE difficulty report to the
PowerShell/CMD window. The detailed values are not added to the trainer UI.
The report reads:
- the requested difficulty enum
- the live BotController difficulty byte
- the difficulty enum inside the game's active cached BotDifficultyPreset
- real numeric preset values such as MainFireSequencePeriod,
  FireAccuracyHoningTime, AutoAimLeadFactor, objective/navigation periods,
  and accuracy/wobble ranges

For the clearest test, spawn the same ship once at Easy 1 and once at Hard 3
and compare the two blocks in the debug window. If the preset numbers differ,
the game loaded different real AI presets rather than only displaying a label.
