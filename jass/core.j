//============================================================================
// ARCHON — Core module (team setup, shared control, resource equalizers,
//          merc spawn-fix, hero limits, support-unit cleanup, AI-support removal)
//----------------------------------------------------------------------------
// Turns a 4-player melee game into 2 Archon teams: P0+P2 and P1+P3 (P0/P1 mains,
// P2/P3 supports). Call ArchonCore_Init() at map init (the deployer's splice adds
// the call + the 4-player W3I/config). Runs alongside tavern.j.
//
// Pairs with the design: shared control is locked via MAP_LOCK_ALLIANCE_CHANGES (the old GUI
// "Lock Alliance Changes" action) so a main can't strip the support's control mid-game;
// supports get no starting units; resources/research are pooled across each team.
//============================================================================

globals
    trigger AC_gold = null
    trigger AC_lumber = null
    trigger AC_food = null
    trigger AC_cap = null
    trigger AC_tokens = null
    trigger AC_research = null
    trigger AC_spawnfix = null
    boolean AC_HIDE_SUPPORT_SCORE = true   // deployer flips to false with --show-support-score
    boolean AC_MATCH_SUPPORT_COLOR = true  // deployer flips to false with --keep-support-color
    integer AC_PREGAME_TIMER = 0           // seconds; deployer sets via --pre-game-timer N (0 = off)
    timerdialog AC_pgDialog = null
endglobals

//---------------------------------------------------------------- team helpers
function AC_TeamOf takes player p returns integer
    local integer id = GetPlayerId(p)
    if id == 0 or id == 2 then
        return 0
    elseif id == 1 or id == 3 then
        return 1
    endif
    return -1
endfunction

function AC_Main takes integer team returns player
    return Player(team)        // P0 / P1
endfunction

function AC_Support takes integer team returns player
    return Player(team + 2)    // P2 / P3
endfunction

function AC_IsSupport takes player p returns boolean
    return GetPlayerId(p) == 2 or GetPlayerId(p) == 3
endfunction

//------------------------------------------- shared full control (both ways)
// Mirror the working AutumnLeaves InitCustomTeams exactly: ally + vision + basic shared control
// + full (advanced) shared control. The basic SHARED_CONTROL is required — advanced alone does
// not grant the ally control of your units.
function AC_AssertShare takes integer team returns nothing
    local player m = AC_Main(team)
    local player s = AC_Support(team)
    call SetPlayerAllianceStateAllyBJ(m, s, true)
    call SetPlayerAllianceStateAllyBJ(s, m, true)
    call SetPlayerAllianceStateVisionBJ(m, s, true)
    call SetPlayerAllianceStateVisionBJ(s, m, true)
    call SetPlayerAllianceStateControlBJ(m, s, true)
    call SetPlayerAllianceStateControlBJ(s, m, true)
    call SetPlayerAllianceStateFullControlBJ(m, s, true)
    call SetPlayerAllianceStateFullControlBJ(s, m, true)
endfunction

// Periodic re-assert — the actual shared-control lock. Reforged gives us NO way (that we've found)
// to disable the diplomacy "shared unit control" toggle: no alliance event fires when it's used,
// the map flags (LOCK_ALLIANCE_CHANGES / ALLIANCE_CHANGES_HIDDEN / SHARED_ADVANCED_CONTROL) don't
// lock the sub-toggles, and the panel has no reachable UI frame. (Some maps DO have it disabled,
// method unknown — likely protected maps.) So a fast timer re-asserting is the only reliable lock —
// exactly what the user's original Archon did. Cheap: when nothing was revoked these are no-ops
// (re-setting an already-true alliance fires no event), so 0.1s does not lag. Interval is tunable.
function AC_ReassertTick takes nothing returns nothing
    call AC_AssertShare(0)
    call AC_AssertShare(1)
endfunction

//------------------------------------------------------- resource equalizers
// On a team member's resource change, copy it to their ally so the pool stays synced.
function AC_SyncState takes player from, playerstate st returns nothing
    local integer t = AC_TeamOf(from)
    local integer v
    if t < 0 then
        return
    endif
    set v = GetPlayerState(from, st)
    if from == AC_Main(t) then
        call SetPlayerState(AC_Support(t), st, v)
    else
        call SetPlayerState(AC_Main(t), st, v)
    endif
endfunction

function AC_OnGold takes nothing returns nothing
    call AC_SyncState(GetTriggerPlayer(), PLAYER_STATE_RESOURCE_GOLD)
endfunction
function AC_OnLumber takes nothing returns nothing
    call AC_SyncState(GetTriggerPlayer(), PLAYER_STATE_RESOURCE_LUMBER)
endfunction
function AC_OnFood takes nothing returns nothing
    call AC_SyncState(GetTriggerPlayer(), PLAYER_STATE_RESOURCE_FOOD_USED)
endfunction
function AC_OnCap takes nothing returns nothing
    call AC_SyncState(GetTriggerPlayer(), PLAYER_STATE_RESOURCE_FOOD_CAP)
endfunction
function AC_OnTokens takes nothing returns nothing
    call AC_SyncState(GetTriggerPlayer(), PLAYER_STATE_RESOURCE_HERO_TOKENS)
endfunction

// Research: keep the ally's tech level equal to the upgrader's.
function AC_OnResearch takes nothing returns nothing
    local integer t = AC_TeamOf(GetOwningPlayer(GetTriggerUnit()))
    local integer tech = GetResearched()
    local player from = GetOwningPlayer(GetTriggerUnit())
    local player ally
    if t < 0 then
        return
    endif
    if from == AC_Main(t) then
        set ally = AC_Support(t)
    else
        set ally = AC_Main(t)
    endif
    call SetPlayerTechResearched(ally, tech, GetPlayerTechCount(from, tech, true))
endfunction

//------------------------------------------------- merc spawn-fix (non-heroes)
// A unit owned by a support entering the map (e.g. a bought mercenary) is reassigned
// to the main. Restricted to NON-heroes so it never fights tavern.j's hero handling.
function AC_OnSpawn takes nothing returns nothing
    local unit u = GetTriggerUnit()
    local integer t = AC_TeamOf(GetOwningPlayer(u))
    if t >= 0 and AC_IsSupport(GetOwningPlayer(u)) and not IsUnitType(u, UNIT_TYPE_HERO) then
        call SetUnitOwner(u, AC_Main(t), true)
    endif
    set u = null
endfunction

//------------------------------------- Archon melee placement (mains only)
// REPLACES the stock MeleeStartingUnits() inside the map's melee init (the splice rewires that
// call to AC_MeleePlaceMains). MeleeStartingUnits builds a base for EVERY player; we build one
// only for the mains, so supports never get any units — no spawn, no vision flash, nothing to
// clean up. A coin-flip swaps which team gets which start corner (fairness), keeping each support
// co-located with its main. Cameras are set per-player (local-only -> GetLocalPlayer is desync-safe).
function AC_MeleeCamFor takes player p, real x, real y returns nothing
    if GetLocalPlayer() == p then
        call SetCameraPosition(x, y)
    endif
endfunction

function AC_MeleePlaceMains takes nothing returns nothing
    local location l
    local integer tmp
    local real ax
    local real ay
    local real bx
    local real by
    // coin-flip: swap the two teams' assigned start locations (each support follows its main)
    if GetRandomInt(0, 1) == 1 then
        set tmp = GetPlayerStartLocation(AC_Main(0))
        call SetPlayerStartLocation(AC_Main(0), GetPlayerStartLocation(AC_Main(1)))
        call SetPlayerStartLocation(AC_Main(1), tmp)
        set tmp = GetPlayerStartLocation(AC_Support(0))
        call SetPlayerStartLocation(AC_Support(0), GetPlayerStartLocation(AC_Support(1)))
        call SetPlayerStartLocation(AC_Support(1), tmp)
    endif
    set ax = GetStartLocationX(GetPlayerStartLocation(AC_Main(0)))
    set ay = GetStartLocationY(GetPlayerStartLocation(AC_Main(0)))
    set bx = GetStartLocationX(GetPlayerStartLocation(AC_Main(1)))
    set by = GetStartLocationY(GetPlayerStartLocation(AC_Main(1)))
    // build ONLY the mains' starting bases
    set l = GetStartLocationLoc(GetPlayerStartLocation(AC_Main(0)))
    call MeleeStartingUnitsForPlayer(GetPlayerRace(AC_Main(0)), AC_Main(0), l, true)
    call RemoveLocation(l)
    set l = GetStartLocationLoc(GetPlayerStartLocation(AC_Main(1)))
    call MeleeStartingUnitsForPlayer(GetPlayerRace(AC_Main(1)), AC_Main(1), l, true)
    call RemoveLocation(l)
    // cameras: each support shares its main's corner
    call AC_MeleeCamFor(AC_Main(0), ax, ay)
    call AC_MeleeCamFor(AC_Support(0), ax, ay)
    call AC_MeleeCamFor(AC_Main(1), bx, by)
    call AC_MeleeCamFor(AC_Support(1), bx, by)
endfunction

//------------------------------------------------- AI in a support slot = out
function AC_RemoveAISupports takes nothing returns nothing
    local integer t = 0
    loop
        exitwhen t > 1
        if GetPlayerController(AC_Support(t)) == MAP_CONTROL_COMPUTER and GetPlayerSlotState(AC_Support(t)) == PLAYER_SLOT_STATE_PLAYING then
            call DisplayTimedTextToForce(GetPlayersAll(), 8.0, "Support-role bots do nothing - removing the support bot.")
            call RemovePlayer(AC_Support(t), PLAYER_GAME_RESULT_DEFEAT)
        endif
        set t = t + 1
    endloop
endfunction

//================================================================ INIT
function AC_RegisterStateEqualizer takes trigger trg, playerstate st, code act returns nothing
    local integer i = 0
    loop
        exitwhen i > 3
        call TriggerRegisterPlayerStateEvent(trg, Player(i), st, GREATER_THAN_OR_EQUAL, 0.0)
        set i = i + 1
    endloop
    call TriggerAddAction(trg, act)
endfunction

//------------------------------------------------- optional pre-game timer
// Countdown before the game becomes interactive, so random-queue partners can chat-coordinate.
// Units are already spawned (melee init ran) — we just FREEZE them so players see their start spot
// and race, then resume. PauseAllUnitsBJ (not PauseGame) so the countdown timer keeps ticking.
function AC_PreGameEnd takes nothing returns nothing
    call PauseAllUnitsBJ(false)
    call TimerDialogDisplay(AC_pgDialog, false)
    call DestroyTimerDialog(AC_pgDialog)
    call DestroyTimer(GetExpiredTimer())
endfunction

function AC_StartPreGame takes nothing returns nothing
    local timer t
    if AC_PREGAME_TIMER <= 0 then
        return
    endif
    call PauseAllUnitsBJ(true)
    set t = CreateTimer()
    set AC_pgDialog = CreateTimerDialog(t)
    call TimerDialogSetTitle(AC_pgDialog, "Coordinate! Game begins in")
    call TimerDialogDisplay(AC_pgDialog, true)
    call TimerStart(t, I2R(AC_PREGAME_TIMER), false, function AC_PreGameEnd)
    set t = null
endfunction

// Runs AFTER the melee init (RunInitializationTriggers): asserts teams/alliance/shared control as
// the LAST word. (Supports never get units — AC_MeleePlaceMains handles that — so there is nothing
// to wipe here, and cameras were set in AC_MeleePlaceMains.)
function AC_FinalizeArchon takes nothing returns nothing
    local integer t = 0
    loop
        exitwhen t > 1
        call SetPlayerTeam(AC_Main(t), t)
        call SetPlayerTeam(AC_Support(t), t)
        call SetPlayerState(AC_Main(t), PLAYER_STATE_ALLIED_VICTORY, 1)
        call SetPlayerState(AC_Support(t), PLAYER_STATE_ALLIED_VICTORY, 1)
        call AC_AssertShare(t)          // ally + vision + control + full control, both ways
        // QoL: the support takes the main's (lobby-chosen) color, so shared visuals (rally flags,
        // etc.) match the team. Done at runtime so it follows whatever color the main actually picked.
        // Toggle via deployer --keep-support-color (flips AC_MATCH_SUPPORT_COLOR=false).
        if AC_MATCH_SUPPORT_COLOR then
            call SetPlayerColor(AC_Support(t), GetPlayerColor(AC_Main(t)))
        endif
        set t = t + 1
    endloop
    // Runtime map-flag locks (the old GUI "Game -" lock actions). Set AFTER AC_AssertShare.
    //   LOCK_ALLIANCE_CHANGES   - locks the ally/enemy status (NOT the shared-control sub-toggles).
    //   ALLIANCE_CHANGES_HIDDEN - suppresses the alliance-change announcements (kept; harmless).
    //   LOCK_RESOURCE_TRADING   - hard-lock trading (the 0-increment constant is kept as a backstop).
    // TESTED in-game: none of these (incl. SHARED_ADVANCED_CONTROL, now dropped) lock the shared-
    // CONTROL toggle — the diplomacy panel still lets a main strip the support's control. The
    // AC_ReassertTick timer below is the real lock.
    call SetMapFlag(MAP_LOCK_ALLIANCE_CHANGES, true)
    call SetMapFlag(MAP_ALLIANCE_CHANGES_HIDDEN, true)
    call SetMapFlag(MAP_LOCK_RESOURCE_TRADING, true)
    call TimerStart(CreateTimer(), 0.1, true, function AC_ReassertTick)
    call AC_StartPreGame()   // optional coordinate-countdown (freezes units); no-op if AC_PREGAME_TIMER==0
endfunction

function ArchonCore_Init takes nothing returns nothing
    local integer t = 0
    // init globals (vanilla JASS forbids function-call initializers in the globals block)
    set AC_gold = CreateTrigger()
    set AC_lumber = CreateTrigger()
    set AC_food = CreateTrigger()
    set AC_cap = CreateTrigger()
    set AC_tokens = CreateTrigger()
    set AC_research = CreateTrigger()
    set AC_spawnfix = CreateTrigger()
    call AC_RemoveAISupports()  // before MeleeStartingAI (this init runs before the melee init)

    loop
        exitwhen t > 1
        // hero cap: the team can have 3; the support's dummy-count (tavern.j) gates buying.
        call SetPlayerMaxHeroesAllowed(3, AC_Main(t))
        call SetPlayerMaxHeroesAllowed(3, AC_Support(t))
        // Drop supports from the post-game score screen — their only "score" is dummy-unit noise
        // (the tavern/hero-count dummies). Display-only: the support still shares the allied result.
        // Deployer flips AC_HIDE_SUPPORT_SCORE=false (--show-support-score) for sites that want to
        // track the support via the scoreboard.
        if AC_HIDE_SUPPORT_SCORE then
            call SetPlayerOnScoreScreen(AC_Support(t), false)
        endif
        set t = t + 1
    endloop

    // resource pooling
    call AC_RegisterStateEqualizer(AC_gold, PLAYER_STATE_RESOURCE_GOLD, function AC_OnGold)
    call AC_RegisterStateEqualizer(AC_lumber, PLAYER_STATE_RESOURCE_LUMBER, function AC_OnLumber)
    call AC_RegisterStateEqualizer(AC_food, PLAYER_STATE_RESOURCE_FOOD_USED, function AC_OnFood)
    call AC_RegisterStateEqualizer(AC_cap, PLAYER_STATE_RESOURCE_FOOD_CAP, function AC_OnCap)
    call AC_RegisterStateEqualizer(AC_tokens, PLAYER_STATE_RESOURCE_HERO_TOKENS, function AC_OnTokens)
    call TriggerRegisterAnyUnitEventBJ(AC_research, EVENT_PLAYER_UNIT_RESEARCH_FINISH)
    call TriggerAddAction(AC_research, function AC_OnResearch)

    // (merc spawn-fix DISABLED: it was reassigning the tavern's support-owned dummy units — e.g.
    //  the dummy altar arx0 — to the main the instant they spawned, breaking the tavern. Re-add
    //  later with dummy-awareness, e.g. tagging dummies via SetUnitUserData and skipping them.)

    // UI fidelity
    call SetReservedLocalHeroButtons(0)
    call MultiboardAllowDisplayBJ(false)
    // teams/alliance/shared-control + support-unit wipe happen in AC_FinalizeArchon, which the
    // splice calls right AFTER RunInitializationTriggers (the melee init).
endfunction
