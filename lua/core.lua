--============================================================================
-- ARCHON — Core module (Lua port of jass/core.j)
------------------------------------------------------------------------------
-- Turns a 4-player melee game into 2 Archon teams: P0+P2 and P1+P3 (P0/P1 mains,
-- P2/P3 supports). Call ArchonCore_Init() at map init (the deployer's splice adds
-- the call + the 4-player W3I/config). Runs alongside tavern.lua.
--============================================================================

AC_gold = nil
AC_lumber = nil
AC_food = nil
AC_cap = nil
AC_tokens = nil
AC_research = nil
AC_spawnfix = nil
AC_HIDE_SUPPORT_SCORE = true   -- deployer flips to false with --show-support-score
AC_MATCH_SUPPORT_COLOR = true  -- deployer flips to false with --keep-support-color
AC_PREGAME_TIMER = 0           -- seconds; deployer sets via --pre-game-timer N (0 = off)
AC_pgDialog = nil

---------------------------------------------------------------- team helpers
function AC_TeamOf(p)
    local id = GetPlayerId(p)
    if id == 0 or id == 2 then
        return 0
    elseif id == 1 or id == 3 then
        return 1
    end
    return -1
end

function AC_Main(team)
    return Player(team)        -- P0 / P1
end

function AC_Support(team)
    return Player(team + 2)    -- P2 / P3
end

function AC_IsSupport(p)
    return GetPlayerId(p) == 2 or GetPlayerId(p) == 3
end

------------------------------------------- shared full control (both ways)
function AC_AssertShare(team)
    local m = AC_Main(team)
    local s = AC_Support(team)
    SetPlayerAllianceStateAllyBJ(m, s, true)
    SetPlayerAllianceStateAllyBJ(s, m, true)
    SetPlayerAllianceStateVisionBJ(m, s, true)
    SetPlayerAllianceStateVisionBJ(s, m, true)
    SetPlayerAllianceStateControlBJ(m, s, true)
    SetPlayerAllianceStateControlBJ(s, m, true)
    SetPlayerAllianceStateFullControlBJ(m, s, true)
    SetPlayerAllianceStateFullControlBJ(s, m, true)
end

-- Periodic re-assert — the actual shared-control lock (see core.j for the why). Cheap: re-setting
-- an already-true alliance fires no event, so 0.1s does not lag.
function AC_ReassertTick()
    AC_AssertShare(0)
    AC_AssertShare(1)
end

------------------------------------------------------- resource equalizers
function AC_SyncState(from, st)
    local t = AC_TeamOf(from)
    local v
    if t < 0 then
        return
    end
    v = GetPlayerState(from, st)
    if from == AC_Main(t) then
        SetPlayerState(AC_Support(t), st, v)
    else
        SetPlayerState(AC_Main(t), st, v)
    end
end

function AC_OnGold()
    AC_SyncState(GetTriggerPlayer(), PLAYER_STATE_RESOURCE_GOLD)
end
function AC_OnLumber()
    AC_SyncState(GetTriggerPlayer(), PLAYER_STATE_RESOURCE_LUMBER)
end
function AC_OnFood()
    AC_SyncState(GetTriggerPlayer(), PLAYER_STATE_RESOURCE_FOOD_USED)
end
function AC_OnCap()
    AC_SyncState(GetTriggerPlayer(), PLAYER_STATE_RESOURCE_FOOD_CAP)
end
function AC_OnTokens()
    AC_SyncState(GetTriggerPlayer(), PLAYER_STATE_RESOURCE_HERO_TOKENS)
end

-- Research: keep the ally's tech level equal to the upgrader's.
function AC_OnResearch()
    local t = AC_TeamOf(GetOwningPlayer(GetTriggerUnit()))
    local tech = GetResearched()
    local from = GetOwningPlayer(GetTriggerUnit())
    local ally
    if t < 0 then
        return
    end
    if from == AC_Main(t) then
        ally = AC_Support(t)
    else
        ally = AC_Main(t)
    end
    SetPlayerTechResearched(ally, tech, GetPlayerTechCount(from, tech, true))
end

------------------------------------------------- merc spawn-fix (non-heroes)
function AC_OnSpawn()
    local u = GetTriggerUnit()
    local t = AC_TeamOf(GetOwningPlayer(u))
    if t >= 0 and AC_IsSupport(GetOwningPlayer(u)) and not IsUnitType(u, UNIT_TYPE_HERO) then
        SetUnitOwner(u, AC_Main(t), true)
    end
    u = nil
end

------------------------------------- Archon melee placement (mains only)
function AC_MeleeCamFor(p, x, y)
    if GetLocalPlayer() == p then
        SetCameraPosition(x, y)
    end
end

function AC_MeleePlaceMains()
    local l
    local tmp
    local ax
    local ay
    local bx
    local by
    -- coin-flip: swap the two teams' assigned start locations (each support follows its main)
    if GetRandomInt(0, 1) == 1 then
        tmp = GetPlayerStartLocation(AC_Main(0))
        SetPlayerStartLocation(AC_Main(0), GetPlayerStartLocation(AC_Main(1)))
        SetPlayerStartLocation(AC_Main(1), tmp)
        tmp = GetPlayerStartLocation(AC_Support(0))
        SetPlayerStartLocation(AC_Support(0), GetPlayerStartLocation(AC_Support(1)))
        SetPlayerStartLocation(AC_Support(1), tmp)
    end
    ax = GetStartLocationX(GetPlayerStartLocation(AC_Main(0)))
    ay = GetStartLocationY(GetPlayerStartLocation(AC_Main(0)))
    bx = GetStartLocationX(GetPlayerStartLocation(AC_Main(1)))
    by = GetStartLocationY(GetPlayerStartLocation(AC_Main(1)))
    -- build ONLY the mains' starting bases
    l = GetStartLocationLoc(GetPlayerStartLocation(AC_Main(0)))
    MeleeStartingUnitsForPlayer(GetPlayerRace(AC_Main(0)), AC_Main(0), l, true)
    RemoveLocation(l)
    l = GetStartLocationLoc(GetPlayerStartLocation(AC_Main(1)))
    MeleeStartingUnitsForPlayer(GetPlayerRace(AC_Main(1)), AC_Main(1), l, true)
    RemoveLocation(l)
    -- cameras: each support shares its main's corner
    AC_MeleeCamFor(AC_Main(0), ax, ay)
    AC_MeleeCamFor(AC_Support(0), ax, ay)
    AC_MeleeCamFor(AC_Main(1), bx, by)
    AC_MeleeCamFor(AC_Support(1), bx, by)
end

------------------------------------------------- AI in a support slot = out
function AC_RemoveAISupports()
    local t = 0
    while true do
        if t > 1 then break end
        if GetPlayerController(AC_Support(t)) == MAP_CONTROL_COMPUTER and GetPlayerSlotState(AC_Support(t)) == PLAYER_SLOT_STATE_PLAYING then
            DisplayTimedTextToForce(GetPlayersAll(), 8.0, "Support-role bots do nothing - removing the support bot.")
            RemovePlayer(AC_Support(t), PLAYER_GAME_RESULT_DEFEAT)
        end
        t = t + 1
    end
end

--================================================================ INIT
function AC_RegisterStateEqualizer(trg, st, act)
    local i = 0
    while true do
        if i > 3 then break end
        TriggerRegisterPlayerStateEvent(trg, Player(i), st, GREATER_THAN_OR_EQUAL, 0.0)
        i = i + 1
    end
    TriggerAddAction(trg, act)
end

------------------------------------------------- optional pre-game timer
function AC_PreGameEnd()
    PauseAllUnitsBJ(false)
    TimerDialogDisplay(AC_pgDialog, false)
    DestroyTimerDialog(AC_pgDialog)
    DestroyTimer(GetExpiredTimer())
end

function AC_StartPreGame()
    local t
    if AC_PREGAME_TIMER <= 0 then
        return
    end
    PauseAllUnitsBJ(true)
    t = CreateTimer()
    AC_pgDialog = CreateTimerDialog(t)
    TimerDialogSetTitle(AC_pgDialog, "Coordinate! Game begins in")
    TimerDialogDisplay(AC_pgDialog, true)
    TimerStart(t, AC_PREGAME_TIMER, false, AC_PreGameEnd)
    t = nil
end

-- Runs AFTER the melee init: asserts teams/alliance/shared control as the LAST word.
function AC_FinalizeArchon()
    local t = 0
    while true do
        if t > 1 then break end
        SetPlayerTeam(AC_Main(t), t)
        SetPlayerTeam(AC_Support(t), t)
        SetPlayerState(AC_Main(t), PLAYER_STATE_ALLIED_VICTORY, 1)
        SetPlayerState(AC_Support(t), PLAYER_STATE_ALLIED_VICTORY, 1)
        AC_AssertShare(t)          -- ally + vision + control + full control, both ways
        -- QoL: support takes the main's color (toggle: deployer --keep-support-color)
        if AC_MATCH_SUPPORT_COLOR then
            SetPlayerColor(AC_Support(t), GetPlayerColor(AC_Main(t)))
        end
        t = t + 1
    end
    -- Runtime map-flag locks (see core.j). The AC_ReassertTick timer is the real shared-control lock.
    SetMapFlag(MAP_LOCK_ALLIANCE_CHANGES, true)
    SetMapFlag(MAP_ALLIANCE_CHANGES_HIDDEN, true)
    SetMapFlag(MAP_LOCK_RESOURCE_TRADING, true)
    TimerStart(CreateTimer(), 0.1, true, AC_ReassertTick)
    AC_StartPreGame()   -- optional coordinate-countdown (freezes units); no-op if AC_PREGAME_TIMER==0
end

function ArchonCore_Init()
    local t = 0
    AC_gold = CreateTrigger()
    AC_lumber = CreateTrigger()
    AC_food = CreateTrigger()
    AC_cap = CreateTrigger()
    AC_tokens = CreateTrigger()
    AC_research = CreateTrigger()
    AC_spawnfix = CreateTrigger()
    AC_RemoveAISupports()  -- before MeleeStartingAI (this init runs before the melee init)

    while true do
        if t > 1 then break end
        -- hero cap: the team can have 3; the support's dummy-count (tavern.lua) gates buying.
        SetPlayerMaxHeroesAllowed(3, AC_Main(t))
        SetPlayerMaxHeroesAllowed(3, AC_Support(t))
        -- drop supports from the post-game score screen (display-only; toggle --show-support-score)
        if AC_HIDE_SUPPORT_SCORE then
            SetPlayerOnScoreScreen(AC_Support(t), false)
        end
        t = t + 1
    end

    -- resource pooling
    AC_RegisterStateEqualizer(AC_gold, PLAYER_STATE_RESOURCE_GOLD, AC_OnGold)
    AC_RegisterStateEqualizer(AC_lumber, PLAYER_STATE_RESOURCE_LUMBER, AC_OnLumber)
    AC_RegisterStateEqualizer(AC_food, PLAYER_STATE_RESOURCE_FOOD_USED, AC_OnFood)
    AC_RegisterStateEqualizer(AC_cap, PLAYER_STATE_RESOURCE_FOOD_CAP, AC_OnCap)
    AC_RegisterStateEqualizer(AC_tokens, PLAYER_STATE_RESOURCE_HERO_TOKENS, AC_OnTokens)
    TriggerRegisterAnyUnitEventBJ(AC_research, EVENT_PLAYER_UNIT_RESEARCH_FINISH)
    TriggerAddAction(AC_research, AC_OnResearch)

    -- (merc spawn-fix AC_OnSpawn DISABLED, as in core.j)

    -- UI fidelity
    SetReservedLocalHeroButtons(0)
    MultiboardAllowDisplayBJ(false)
end
