--============================================================================
-- ARCHON — Tavern system (Lua port of jass/tavern.j)
------------------------------------------------------------------------------
-- Call ArchonTavern_Init() at map init (after the melee init). Teams:
-- team 0 = main P0 + support P2 ; team 1 = main P1 + support P3.
-- Rawcode literals use FourCC('xxxx') (the WC3-Lua form of JASS 'xxxx').
--============================================================================

-- ---- CONFIG: dummy rawcodes (from generate_dummies.py) ----
DUMMY_ALTAR = FourCC('arx0')
DUMMY_HERO  = FourCC('arx1')
DUMMY_T2    = FourCC('arx2')
DUMMY_T3    = FourCC('arx3')

-- ---- runtime state ----
AT_ht = nil
AT_dummyAltar = {}   -- [team] support's dummy altar (TALT)
AT_dummyT2 = {}      -- [team]
AT_dummyT3 = {}      -- [team]
AT_x = {}            -- [team] spawn point for dummies (support start loc)
AT_y = {}
AT_trainStart = nil
AT_trainFinish = nil
AT_trainCancel = nil
AT_sell = nil
AT_death = nil
AT_buildFinish = nil
AT_reviveStart = nil
AT_reviveFinish = nil
AT_reviveCancel = nil

-- hashtable parent keys (namespaces) — see tavern.j header for the full map.
function AT_SaveTypeMap(pk, key, val)
    SaveInteger(AT_ht, pk, key, val)
end

---------------------------------------------------------------- team helpers
function AT_TeamOf(p)
    local id = GetPlayerId(p)
    if id == 0 or id == 2 then
        return 0
    elseif id == 1 or id == 3 then
        return 1
    end
    return -1
end

function AT_Main(team)
    return Player(team) -- P0 or P1
end

function AT_Support(team)
    return Player(team + 2) -- P2 or P3
end

function AT_IsMainPlayer(p)
    return GetPlayerId(p) == 0 or GetPlayerId(p) == 1
end

-- True only when this team's support slot holds a real HUMAN player (see tavern.j for the why).
function AT_SupportActive(team)
    return GetPlayerController(AT_Support(team)) == MAP_CONTROL_USER and GetPlayerSlotState(AT_Support(team)) == PLAYER_SLOT_STATE_PLAYING
end

---------------------------------------------------------------- count system
function AT_CountPlusPermanent(team)
    local u
    if not AT_SupportActive(team) then
        return
    end
    u = CreateUnit(AT_Support(team), DUMMY_HERO, AT_x[team], AT_y[team], 0.0)
    RemoveUnit(u)
    u = nil
end

function AT_CountTrainStart(team)
    if AT_SupportActive(team) and AT_dummyAltar[team] ~= nil then
        IssueImmediateOrderById(AT_dummyAltar[team], DUMMY_HERO)
    end
end

function AT_CountTrainStop(team)
    if AT_SupportActive(team) and AT_dummyAltar[team] ~= nil then
        IssueImmediateOrderById(AT_dummyAltar[team], 851976)
    end
end

---------------------------------------------------------- dummy altar / tier
function AT_MainAltarCount(team)
    local g = CreateGroup()
    local n = 0
    local u
    GroupEnumUnitsOfPlayer(g, AT_Main(team), nil)
    while true do
        u = FirstOfGroup(g)
        if u == nil then break end
        if HaveSavedInteger(AT_ht, 4, GetUnitTypeId(u)) and GetUnitState(u, UNIT_STATE_LIFE) > 0.0 then
            n = n + 1
        end
        GroupRemoveUnit(g, u)
    end
    DestroyGroup(g)
    g = nil
    return n
end

function AT_MainTier(team)
    local g = CreateGroup()
    local best = 1
    local t
    local u
    GroupEnumUnitsOfPlayer(g, AT_Main(team), nil)
    while true do
        u = FirstOfGroup(g)
        if u == nil then break end
        if HaveSavedInteger(AT_ht, 5, GetUnitTypeId(u)) and GetUnitState(u, UNIT_STATE_LIFE) > 0.0 then
            t = LoadInteger(AT_ht, 5, GetUnitTypeId(u))
            if t > best then
                best = t
            end
        end
        GroupRemoveUnit(g, u)
    end
    DestroyGroup(g)
    g = nil
    return best
end

function AT_ReconcileBuildings(team)
    local hasAltar
    local tier
    if not AT_SupportActive(team) then
        return
    end
    hasAltar = AT_MainAltarCount(team) > 0
    tier = AT_MainTier(team)
    -- altar (the Locust barracks dummy trainer)
    if hasAltar and AT_dummyAltar[team] == nil then
        AT_dummyAltar[team] = CreateUnit(AT_Support(team), DUMMY_ALTAR, AT_x[team], AT_y[team], 0.0)
    elseif (not hasAltar) and AT_dummyAltar[team] ~= nil then
        RemoveUnit(AT_dummyAltar[team])
        AT_dummyAltar[team] = nil
    end
    -- tier 2
    if tier >= 2 and AT_dummyT2[team] == nil then
        AT_dummyT2[team] = CreateUnit(AT_Support(team), DUMMY_T2, AT_x[team], AT_y[team], 0.0)
    elseif tier < 2 and AT_dummyT2[team] ~= nil then
        RemoveUnit(AT_dummyT2[team])
        AT_dummyT2[team] = nil
    end
    -- tier 3
    if tier >= 3 and AT_dummyT3[team] == nil then
        AT_dummyT3[team] = CreateUnit(AT_Support(team), DUMMY_T3, AT_x[team], AT_y[team], 0.0)
    elseif tier < 3 and AT_dummyT3[team] ~= nil then
        RemoveUnit(AT_dummyT3[team])
        AT_dummyT3[team] = nil
    end
end

---------------------------------------------------------- duplicate lockout
function AT_LockHeroType(team, realType)
    SetPlayerTechMaxAllowed(AT_Main(team), realType, 0)
    SetPlayerTechMaxAllowed(AT_Support(team), realType, 0)
    if HaveSavedInteger(AT_ht, 10, realType) then
        SetPlayerTechMaxAllowed(AT_Main(team), LoadInteger(AT_ht, 10, realType), 0)
        SetPlayerTechMaxAllowed(AT_Support(team), LoadInteger(AT_ht, 10, realType), 0)
    end
end

---------------------------------------------------------------- revive fakes
function AT_MakeReviveDummy(team, deadHero)
    local rt = GetUnitTypeId(deadHero)
    local dummyType
    local rd
    if not AT_SupportActive(team) then
        return
    end
    if not HaveSavedInteger(AT_ht, 1, rt) then
        return
    end
    dummyType = LoadInteger(AT_ht, 1, rt)
    rd = CreateUnit(AT_Support(team), dummyType, AT_x[team], AT_y[team], 0.0)
    SetHeroLevel(rd, GetHeroLevel(deadHero), false)
    KillUnit(rd)
    SaveUnitHandle(AT_ht, 7, GetHandleId(rd), deadHero)
    SaveUnitHandle(AT_ht, 6, GetHandleId(deadHero), rd)
    rd = nil
end

function AT_RemoveReviveDummyFor(deadHero)
    local rd
    if HaveSavedHandle(AT_ht, 6, GetHandleId(deadHero)) then
        rd = LoadUnitHandle(AT_ht, 6, GetHandleId(deadHero))
        if rd ~= nil then
            RemoveSavedHandle(AT_ht, 7, GetHandleId(rd))
            RemoveUnit(rd)
        end
        RemoveSavedHandle(AT_ht, 6, GetHandleId(deadHero))
        rd = nil
    end
end

function AT_ReserveReviveDummy(hero)
    local rd
    if HaveSavedHandle(AT_ht, 6, GetHandleId(hero)) then
        rd = LoadUnitHandle(AT_ht, 6, GetHandleId(hero))
        if rd ~= nil then
            SetUnitOwner(rd, Player(PLAYER_NEUTRAL_PASSIVE), false)
        end
        rd = nil
    end
end

function AT_UnreserveReviveDummy(hero)
    local team = AT_TeamOf(GetOwningPlayer(hero))
    local rd
    if team >= 0 and HaveSavedHandle(AT_ht, 6, GetHandleId(hero)) then
        rd = LoadUnitHandle(AT_ht, 6, GetHandleId(hero))
        if rd ~= nil then
            SetUnitOwner(rd, AT_Support(team), false)
        end
        rd = nil
    end
end

function AT_RevivingAltar()
    return GetTriggerUnit()   -- the altar = the triggering unit
end
function AT_RevivedHero()
    return GetRevivingUnit()
end

--================================================================ EVENT HANDLERS
function AT_OnTrainStart()
    local team = AT_TeamOf(GetOwningPlayer(GetTriggerUnit()))
    if team >= 0 and AT_IsMainPlayer(GetOwningPlayer(GetTriggerUnit())) and HaveSavedInteger(AT_ht, 1, GetTrainedUnitType()) then
        AT_CountTrainStart(team)
    end
end

function AT_OnTrainFinish()
    local u = GetTrainedUnit()
    local team
    if IsUnitType(u, UNIT_TYPE_HERO) and AT_IsMainPlayer(GetOwningPlayer(u)) then
        team = AT_TeamOf(GetOwningPlayer(u))
        if team >= 0 then
            AT_CountTrainStop(team)        -- cancel the in-training dummyHero
            AT_CountPlusPermanent(team)    -- permanent +1
            AT_LockHeroType(team, GetUnitTypeId(u))
        end
    end
    u = nil
end

function AT_OnTrainCancel()
    local team = AT_TeamOf(GetOwningPlayer(GetTriggerUnit()))
    if team >= 0 and AT_IsMainPlayer(GetOwningPlayer(GetTriggerUnit())) and HaveSavedInteger(AT_ht, 1, GetTrainedUnitType()) then
        AT_CountTrainStop(team)
    end
end

function AT_OnSell()
    local sold = GetSoldUnit()
    local buyer = GetOwningPlayer(sold)
    local ptype = GetUnitTypeId(sold)
    local team = AT_TeamOf(buyer)
    local neutral
    local realHero
    local mainId
    local tpItem
    if team < 0 then
        sold = nil
        return
    end
    if HaveSavedInteger(AT_ht, 2, ptype) then
        -- A BuyProxy was bought (by main OR support) -> spawn the real hero for the MAIN, remove proxy.
        neutral = LoadInteger(AT_ht, 2, ptype)
        -- Undo the melee "first hero gets a Town Portal" handler that already fired on the proxy.
        tpItem = UnitItemInSlot(sold, 0)
        if GetItemTypeId(tpItem) == FourCC('stwp') then
            bj_meleeTwinkedHeroes[GetPlayerId(buyer)] = bj_meleeTwinkedHeroes[GetPlayerId(buyer)] - 1
            RemoveItem(tpItem)
        end
        realHero = CreateUnit(AT_Main(team), neutral, GetUnitX(sold), GetUnitY(sold), bj_UNIT_FACING)
        RemoveUnit(sold)
        -- ...then re-grant the TP to the REAL hero, keyed to the MAIN's counter (shared with altar heroes).
        mainId = GetPlayerId(AT_Main(team))
        if bj_meleeTwinkedHeroes[mainId] < bj_MELEE_MAX_TWINKED_HEROES then
            UnitAddItemById(realHero, FourCC('stwp'))
            bj_meleeTwinkedHeroes[mainId] = bj_meleeTwinkedHeroes[mainId] + 1
        end
        AT_CountPlusPermanent(team)
        AT_LockHeroType(team, neutral)          -- locks the real + its proxy (no duplicate)
        realHero = nil
        tpItem = nil
    elseif HaveSavedInteger(AT_ht, 1, ptype) and AT_IsMainPlayer(buyer) then
        -- MAIN bought a real tavern hero directly -> count it + lock (no spawn needed).
        AT_CountPlusPermanent(team)
        AT_LockHeroType(team, ptype)
    elseif (not AT_IsMainPlayer(buyer)) and (not IsUnitType(sold, UNIT_TYPE_HERO)) then
        -- SUPPORT bought a non-hero (mercenary) -> hand it to the main (support owns nothing).
        -- Safe here: dummies are CreateUnit'd, never SOLD, so this SELL handler never sees them.
        SetUnitOwner(sold, AT_Main(team), true)
    end
    sold = nil
end

function AT_OnDeath()
    local u = GetTriggerUnit()
    local team = AT_TeamOf(GetOwningPlayer(u))
    local h
    if team < 0 then
        u = nil
        return
    end
    -- Altar that was mid-revive just died -> un-reserve its hero.
    if HaveSavedHandle(AT_ht, 8, GetHandleId(u)) then
        h = LoadUnitHandle(AT_ht, 8, GetHandleId(u))
        RemoveSavedHandle(AT_ht, 9, GetHandleId(h))
        RemoveSavedHandle(AT_ht, 8, GetHandleId(u))
        AT_UnreserveReviveDummy(h)
        h = nil
    end
    if IsUnitType(u, UNIT_TYPE_HERO) and AT_IsMainPlayer(GetOwningPlayer(u)) then
        AT_MakeReviveDummy(team, u)
    elseif HaveSavedInteger(AT_ht, 4, GetUnitTypeId(u)) or HaveSavedInteger(AT_ht, 5, GetUnitTypeId(u)) then
        AT_ReconcileBuildings(team)   -- main lost an altar/tier -> re-sync dummies
    end
    u = nil
end

function AT_OnBuildFinish()
    local team = AT_TeamOf(GetOwningPlayer(GetTriggerUnit()))
    if team >= 0 and AT_IsMainPlayer(GetOwningPlayer(GetTriggerUnit())) then
        AT_ReconcileBuildings(team)
    end
end

function AT_OnReviveStart()
    local hero = AT_RevivedHero()
    local altar = AT_RevivingAltar()
    if AT_TeamOf(GetOwningPlayer(hero)) >= 0 and AT_IsMainPlayer(GetOwningPlayer(hero)) then
        AT_ReserveReviveDummy(hero)
        if altar ~= nil then
            SaveUnitHandle(AT_ht, 8, GetHandleId(altar), hero)
            SaveUnitHandle(AT_ht, 9, GetHandleId(hero), altar)
        end
    end
    hero = nil
    altar = nil
end

function AT_OnReviveCancel()
    local hero = AT_RevivedHero()
    local altar
    if HaveSavedHandle(AT_ht, 9, GetHandleId(hero)) then
        altar = LoadUnitHandle(AT_ht, 9, GetHandleId(hero))
        if altar ~= nil then
            RemoveSavedHandle(AT_ht, 8, GetHandleId(altar))
        end
        RemoveSavedHandle(AT_ht, 9, GetHandleId(hero))
    end
    AT_UnreserveReviveDummy(hero)
    hero = nil
    altar = nil
end

function AT_OnReviveFinish()
    local u = AT_RevivedHero()
    local team = AT_TeamOf(GetOwningPlayer(u))
    local dead
    local altar
    if team >= 0 and HaveSavedHandle(AT_ht, 7, GetHandleId(u)) then
        dead = LoadUnitHandle(AT_ht, 7, GetHandleId(u))
        if dead ~= nil then
            ReviveHero(dead, GetUnitX(u), GetUnitY(u), true)
            AT_RemoveReviveDummyFor(dead)
        end
        RemoveUnit(u)
    else
        if HaveSavedHandle(AT_ht, 9, GetHandleId(u)) then
            altar = LoadUnitHandle(AT_ht, 9, GetHandleId(u))
            if altar ~= nil then
                RemoveSavedHandle(AT_ht, 8, GetHandleId(altar))
            end
            RemoveSavedHandle(AT_ht, 9, GetHandleId(u))
        end
        AT_RemoveReviveDummyFor(u)
    end
    u = nil
    dead = nil
    altar = nil
end

--============================================================== INIT
function AT_RegisterRosterEntry(realType, reviveType)
    SaveInteger(AT_ht, 1, realType, reviveType)
    SaveInteger(AT_ht, 3, reviveType, 1)
end

function AT_RegisterProxy(proxyType, neutralType)
    SaveInteger(AT_ht, 2, proxyType, neutralType)   -- proxy -> neutral
    SaveInteger(AT_ht, 10, neutralType, proxyType)  -- neutral -> proxy (for dup-lockout)
end

function AT_InitRoster()
    -- ReviveDummies (real hero -> Ar<race><n>)
    AT_RegisterRosterEntry(FourCC('Hpal'), FourCC('ArH1'))
    AT_RegisterRosterEntry(FourCC('Hamg'), FourCC('ArH2'))
    AT_RegisterRosterEntry(FourCC('Hmkg'), FourCC('ArH3'))
    AT_RegisterRosterEntry(FourCC('Hblm'), FourCC('ArH4'))
    AT_RegisterRosterEntry(FourCC('Obla'), FourCC('ArO1'))
    AT_RegisterRosterEntry(FourCC('Ofar'), FourCC('ArO2'))
    AT_RegisterRosterEntry(FourCC('Otch'), FourCC('ArO3'))
    AT_RegisterRosterEntry(FourCC('Oshd'), FourCC('ArO4'))
    AT_RegisterRosterEntry(FourCC('Udea'), FourCC('ArU1'))
    AT_RegisterRosterEntry(FourCC('Ulic'), FourCC('ArU2'))
    AT_RegisterRosterEntry(FourCC('Udre'), FourCC('ArU3'))
    AT_RegisterRosterEntry(FourCC('Ucrl'), FourCC('ArU4'))
    AT_RegisterRosterEntry(FourCC('Ekee'), FourCC('ArE1'))
    AT_RegisterRosterEntry(FourCC('Emoo'), FourCC('ArE2'))
    AT_RegisterRosterEntry(FourCC('Edem'), FourCC('ArE3'))
    AT_RegisterRosterEntry(FourCC('Ewar'), FourCC('ArE4'))
    AT_RegisterRosterEntry(FourCC('Nalc'), FourCC('ArN1'))
    AT_RegisterRosterEntry(FourCC('Nngs'), FourCC('ArN2'))
    AT_RegisterRosterEntry(FourCC('Ntin'), FourCC('ArN3'))
    AT_RegisterRosterEntry(FourCC('Nbst'), FourCC('ArN4'))
    AT_RegisterRosterEntry(FourCC('Npbm'), FourCC('ArN5'))
    AT_RegisterRosterEntry(FourCC('Nbrn'), FourCC('ArN6'))
    AT_RegisterRosterEntry(FourCC('Nfir'), FourCC('ArN7'))
    AT_RegisterRosterEntry(FourCC('Nplh'), FourCC('ArN8'))
    -- BuyProxies (ArT<n> -> neutral hero)
    AT_RegisterProxy(FourCC('ArT1'), FourCC('Nalc'))
    AT_RegisterProxy(FourCC('ArT2'), FourCC('Nngs'))
    AT_RegisterProxy(FourCC('ArT3'), FourCC('Ntin'))
    AT_RegisterProxy(FourCC('ArT4'), FourCC('Nbst'))
    AT_RegisterProxy(FourCC('ArT5'), FourCC('Npbm'))
    AT_RegisterProxy(FourCC('ArT6'), FourCC('Nbrn'))
    AT_RegisterProxy(FourCC('ArT7'), FourCC('Nfir'))
    AT_RegisterProxy(FourCC('ArT8'), FourCC('Nplh'))
    -- altar types (dependency-equivalent set)
    SaveInteger(AT_ht, 4, FourCC('halt'), 1) -- Altar of Kings
    SaveInteger(AT_ht, 4, FourCC('oalt'), 1) -- Altar of Storms
    SaveInteger(AT_ht, 4, FourCC('uaod'), 1) -- Altar of Darkness
    SaveInteger(AT_ht, 4, FourCC('eate'), 1) -- Altar of Elders
    -- town-hall types -> tier
    SaveInteger(AT_ht, 5, FourCC('hkee'), 2) -- Keep
    SaveInteger(AT_ht, 5, FourCC('hcas'), 3) -- Castle
    SaveInteger(AT_ht, 5, FourCC('ostr'), 2) -- Stronghold
    SaveInteger(AT_ht, 5, FourCC('ofrt'), 3) -- Fortress
    SaveInteger(AT_ht, 5, FourCC('unp1'), 2) -- Halls of the Dead
    SaveInteger(AT_ht, 5, FourCC('unp2'), 3) -- Black Citadel
    SaveInteger(AT_ht, 5, FourCC('etoa'), 2) -- Tree of Ages
    SaveInteger(AT_ht, 5, FourCC('etoe'), 3) -- Tree of Eternity
end

-- No-op: the tavern sells ONLY the 8 BuyProxies (proxies-only), so there's nothing to hide per-player.
function AT_InitTavernLocks(team)
end

function ArchonTavern_Init()
    local t = 0
    AT_ht = InitHashtable()
    AT_trainStart = CreateTrigger()
    AT_trainFinish = CreateTrigger()
    AT_trainCancel = CreateTrigger()
    AT_sell = CreateTrigger()
    AT_death = CreateTrigger()
    AT_buildFinish = CreateTrigger()
    AT_reviveStart = CreateTrigger()
    AT_reviveFinish = CreateTrigger()
    AT_reviveCancel = CreateTrigger()
    AT_InitRoster()
    while true do
        if t > 1 then break end
        AT_InitTavernLocks(t)
        if AT_SupportActive(t) then       -- only wire dummy mechanics for teams that HAVE a support
            AT_x[t] = GetStartLocationX(GetPlayerStartLocation(AT_Support(t)))
            AT_y[t] = GetStartLocationY(GetPlayerStartLocation(AT_Support(t)))
            AT_ReconcileBuildings(t)
        end
        t = t + 1
    end
    -- events (any unit, then filtered in the handlers)
    TriggerRegisterAnyUnitEventBJ(AT_trainStart, EVENT_PLAYER_UNIT_TRAIN_START)
    TriggerAddAction(AT_trainStart, AT_OnTrainStart)
    TriggerRegisterAnyUnitEventBJ(AT_trainFinish, EVENT_PLAYER_UNIT_TRAIN_FINISH)
    TriggerAddAction(AT_trainFinish, AT_OnTrainFinish)
    TriggerRegisterAnyUnitEventBJ(AT_trainCancel, EVENT_PLAYER_UNIT_TRAIN_CANCEL)
    TriggerAddAction(AT_trainCancel, AT_OnTrainCancel)
    TriggerRegisterAnyUnitEventBJ(AT_sell, EVENT_PLAYER_UNIT_SELL)
    TriggerAddAction(AT_sell, AT_OnSell)
    TriggerRegisterAnyUnitEventBJ(AT_death, EVENT_PLAYER_UNIT_DEATH)
    TriggerAddAction(AT_death, AT_OnDeath)
    TriggerRegisterAnyUnitEventBJ(AT_buildFinish, EVENT_PLAYER_UNIT_CONSTRUCT_FINISH)
    TriggerRegisterAnyUnitEventBJ(AT_buildFinish, EVENT_PLAYER_UNIT_UPGRADE_FINISH)
    TriggerAddAction(AT_buildFinish, AT_OnBuildFinish)
    TriggerRegisterAnyUnitEventBJ(AT_reviveStart, EVENT_PLAYER_HERO_REVIVE_START)
    TriggerAddAction(AT_reviveStart, AT_OnReviveStart)
    TriggerRegisterAnyUnitEventBJ(AT_reviveFinish, EVENT_PLAYER_HERO_REVIVE_FINISH)
    TriggerAddAction(AT_reviveFinish, AT_OnReviveFinish)
    TriggerRegisterAnyUnitEventBJ(AT_reviveCancel, EVENT_PLAYER_HERO_REVIVE_CANCEL)
    TriggerAddAction(AT_reviveCancel, AT_OnReviveCancel)
end
