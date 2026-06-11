//============================================================================
// ARCHON — Tavern system (buy + revive + count + gating)
//----------------------------------------------------------------------------
// Paste this into a custom-script section and call ArchonTavern_Init() at map
// init (after CreateAllUnits). Coexists with the existing resource/share triggers.
//
// Teams: team 0 = main P0 + support P2 ; team 1 = main P1 + support P3.
// Depends on the objdata from generate_dummies.py (rawcodes in the CONFIG block)
// and the dependency-equivalents: dummyHero->Hero, dummyAltar->Altar, dummyT2/3->tiers.
//
// v1 simplifications (marked TODO): revive-fake spawns on death (not the ~5s
// "becomes-revivable" moment), and the altar-destroyed-mid-revive edge is left to
// a future reconcile pass. Everything else follows TAVERN_DESIGN.md.
//============================================================================

globals
    // ---- CONFIG: dummy rawcodes (from generate_dummies.py) ----
    constant integer DUMMY_ALTAR = 'arx0'
    constant integer DUMMY_HERO  = 'arx1'
    constant integer DUMMY_T2    = 'arx2'
    constant integer DUMMY_T3    = 'arx3'

    // ---- runtime state ----
    hashtable AT_ht = null
    unit array AT_dummyAltar   // [team] support's dummy altar (TALT)
    unit array AT_dummyT2      // [team]
    unit array AT_dummyT3      // [team]
    real array AT_x            // [team] spawn point for dummies (support start loc)
    real array AT_y
    trigger AT_trainStart = null
    trigger AT_trainFinish = null
    trigger AT_trainCancel = null
    trigger AT_sell = null
    trigger AT_death = null
    trigger AT_buildFinish = null
    trigger AT_reviveStart = null
    trigger AT_reviveFinish = null
    trigger AT_reviveCancel = null
endglobals

// hashtable parent keys (namespaces)
//  1: realHeroType -> reviveDummyType        2: proxyType -> neutralHeroType
//  3: rawcode -> 1 if a reviveDummy type     4: rawcode -> 1 if an altar type
//  5: rawcode -> tier (2 or 3) for town-hall types
//  6: handle(deadHero) -> handle(reviveDummy)  7: handle(reviveDummy) -> deadHero unit
function AT_SaveTypeMap takes integer pk, integer key, integer val returns nothing
    call SaveInteger(AT_ht, pk, key, val)
endfunction

//---------------------------------------------------------------- team helpers
function AT_TeamOf takes player p returns integer
    local integer id = GetPlayerId(p)
    if id == 0 or id == 2 then
        return 0
    elseif id == 1 or id == 3 then
        return 1
    endif
    return -1
endfunction

function AT_Main takes integer team returns player
    return Player(team) // P0 or P1
endfunction

function AT_Support takes integer team returns player
    return Player(team + 2) // P2 or P3
endfunction

function AT_IsMainPlayer takes player p returns boolean
    return GetPlayerId(p) == 0 or GetPlayerId(p) == 1
endfunction

// True only when this team's support slot holds a real HUMAN player. Anything else — an empty
// slot, a computer, or an AI support that AC_RemoveAISupports removed (RemovePlayer can leave the
// slot still reading PLAYING, so we must NOT rely on slot state alone) — means the main just plays
// vanilla, and we MUST skip every dummy mechanic: creating/ordering units for a non-present player
// (e.g. at its start location, which is -1) crashes the game.
function AT_SupportActive takes integer team returns boolean
    return GetPlayerController(AT_Support(team)) == MAP_CONTROL_USER and GetPlayerSlotState(AT_Support(team)) == PLAYER_SLOT_STATE_PLAYING
endfunction


//---------------------------------------------------------------- count system
// Permanent +1 to the support's hero count via the monotonic create+remove quirk.
function AT_CountPlusPermanent takes integer team returns nothing
    local unit u
    if not AT_SupportActive(team) then
        return
    endif
    set u = CreateUnit(AT_Support(team), DUMMY_HERO, AT_x[team], AT_y[team], 0.0)
    call RemoveUnit(u)
    set u = null
endfunction

// Queue an in-training dummyHero on the support's dummy altar (cancellable count
// for the window while the main is training a hero).
// Cancellable in-progress count: while the main is training a hero, a queued dummyHero on the
// support's dummy trainer (arx0, a Locust barracks that CAN train it) bumps the support's hero
// count, greying the tavern at cap. Start = queue one; Stop (main finished/cancelled) = cancel one
// via order 851976 (the real "cancel training" order — the string "cancel" only cancels building
// construction, not a training-queue slot).
function AT_CountTrainStart takes integer team returns nothing
    if AT_SupportActive(team) and AT_dummyAltar[team] != null then
        call IssueImmediateOrderById(AT_dummyAltar[team], DUMMY_HERO)
    endif
endfunction

function AT_CountTrainStop takes integer team returns nothing
    if AT_SupportActive(team) and AT_dummyAltar[team] != null then
        call IssueImmediateOrderById(AT_dummyAltar[team], 851976)
    endif
endfunction

//---------------------------------------------------------- dummy altar / tier
// Reconcile-from-truth: ensure the support's dummy altar/tier mirror the main's
// real buildings. Removing them re-fires the team-wide defeat check (intended).
function AT_MainAltarCount takes integer team returns integer
    local group g = CreateGroup()
    local integer n = 0
    local unit u
    call GroupEnumUnitsOfPlayer(g, AT_Main(team), null)
    loop
        set u = FirstOfGroup(g)
        exitwhen u == null
        if HaveSavedInteger(AT_ht, 4, GetUnitTypeId(u)) and GetUnitState(u, UNIT_STATE_LIFE) > 0.0 then
            set n = n + 1
        endif
        call GroupRemoveUnit(g, u)
    endloop
    call DestroyGroup(g)
    set g = null
    return n
endfunction

// Highest tier among the main's town halls (1/2/3).
function AT_MainTier takes integer team returns integer
    local group g = CreateGroup()
    local integer best = 1
    local integer t
    local unit u
    call GroupEnumUnitsOfPlayer(g, AT_Main(team), null)
    loop
        set u = FirstOfGroup(g)
        exitwhen u == null
        if HaveSavedInteger(AT_ht, 5, GetUnitTypeId(u)) and GetUnitState(u, UNIT_STATE_LIFE) > 0.0 then
            set t = LoadInteger(AT_ht, 5, GetUnitTypeId(u))
            if t > best then
                set best = t
            endif
        endif
        call GroupRemoveUnit(g, u)
    endloop
    call DestroyGroup(g)
    set g = null
    return best
endfunction

function AT_ReconcileBuildings takes integer team returns nothing
    local boolean hasAltar
    local integer tier
    if not AT_SupportActive(team) then
        return
    endif
    set hasAltar = AT_MainAltarCount(team) > 0
    set tier = AT_MainTier(team)
    // altar (the Locust barracks dummy trainer)
    if hasAltar and AT_dummyAltar[team] == null then
        set AT_dummyAltar[team] = CreateUnit(AT_Support(team), DUMMY_ALTAR, AT_x[team], AT_y[team], 0.0)
    elseif (not hasAltar) and AT_dummyAltar[team] != null then
        call RemoveUnit(AT_dummyAltar[team])
        set AT_dummyAltar[team] = null
    endif
    // tier 2
    if tier >= 2 and AT_dummyT2[team] == null then
        set AT_dummyT2[team] = CreateUnit(AT_Support(team), DUMMY_T2, AT_x[team], AT_y[team], 0.0)
    elseif tier < 2 and AT_dummyT2[team] != null then
        call RemoveUnit(AT_dummyT2[team])
        set AT_dummyT2[team] = null
    endif
    // tier 3
    if tier >= 3 and AT_dummyT3[team] == null then
        set AT_dummyT3[team] = CreateUnit(AT_Support(team), DUMMY_T3, AT_x[team], AT_y[team], 0.0)
    elseif tier < 3 and AT_dummyT3[team] != null then
        call RemoveUnit(AT_dummyT3[team])
        set AT_dummyT3[team] = null
    endif
endfunction

//---------------------------------------------------------- duplicate lockout
// After hero type X is acquired, lock both the real and proxy X for both players.
function AT_LockHeroType takes integer team, integer realType returns nothing
    call SetPlayerTechMaxAllowed(AT_Main(team), realType, 0)
    call SetPlayerTechMaxAllowed(AT_Support(team), realType, 0)
    // if this real hero is a neutral one, also lock its BuyProxy for both (no duplicate)
    if HaveSavedInteger(AT_ht, 10, realType) then
        call SetPlayerTechMaxAllowed(AT_Main(team), LoadInteger(AT_ht, 10, realType), 0)
        call SetPlayerTechMaxAllowed(AT_Support(team), LoadInteger(AT_ht, 10, realType), 0)
    endif
endfunction

//---------------------------------------------------------------- revive fakes
function AT_MakeReviveDummy takes integer team, unit deadHero returns nothing
    local integer rt = GetUnitTypeId(deadHero)
    local integer dummyType
    local unit rd
    if not AT_SupportActive(team) then
        return // no support on this team -> main revives vanilla at its own altar
    endif
    if not HaveSavedInteger(AT_ht, 1, rt) then
        return // not a roster hero (no revive dummy mapped)
    endif
    set dummyType = LoadInteger(AT_ht, 1, rt)
    set rd = CreateUnit(AT_Support(team), dummyType, AT_x[team], AT_y[team], 0.0)
    call SetHeroLevel(rd, GetHeroLevel(deadHero), false) // mirror level -> native revive cost
    call KillUnit(rd) // inherits the real hero's death timer -> greys then unlocks in the
                      // support's tavern in sync with when the main could revive
    // map both directions so we can find/clean up later
    call SaveUnitHandle(AT_ht, 7, GetHandleId(rd), deadHero)
    call SaveUnitHandle(AT_ht, 6, GetHandleId(deadHero), rd)
    set rd = null
endfunction

function AT_RemoveReviveDummyFor takes unit deadHero returns nothing
    local unit rd
    if HaveSavedHandle(AT_ht, 6, GetHandleId(deadHero)) then
        set rd = LoadUnitHandle(AT_ht, 6, GetHandleId(deadHero))
        if rd != null then
            call RemoveSavedHandle(AT_ht, 7, GetHandleId(rd))
            call RemoveUnit(rd)
        endif
        call RemoveSavedHandle(AT_ht, 6, GetHandleId(deadHero))
        set rd = null
    endif
endfunction

//---- reserve: flip the ReviveDummy's owner so it leaves/returns to the support's tavern,
//---- WITHOUT destroying it (no death-timer reset). Mirrors the 1v1 "a hero being revived at
//---- the altar isn't available at the tavern" reservation, so the support can't tavern-revive
//---- a hero the main has queued at an altar (preserving the cancel-then-tavern micro).
function AT_ReserveReviveDummy takes unit hero returns nothing
    local unit rd
    if HaveSavedHandle(AT_ht, 6, GetHandleId(hero)) then
        set rd = LoadUnitHandle(AT_ht, 6, GetHandleId(hero))
        if rd != null then
            call SetUnitOwner(rd, Player(PLAYER_NEUTRAL_PASSIVE), false)
        endif
        set rd = null
    endif
endfunction

function AT_UnreserveReviveDummy takes unit hero returns nothing
    local integer team = AT_TeamOf(GetOwningPlayer(hero))
    local unit rd
    if team >= 0 and HaveSavedHandle(AT_ht, 6, GetHandleId(hero)) then
        set rd = LoadUnitHandle(AT_ht, 6, GetHandleId(hero))
        if rd != null then
            call SetUnitOwner(rd, AT_Support(team), false)
        endif
        set rd = null
    endif
endfunction

//==== CONFIRM these two against your GUI "begins reviving a unit" event ====================
// One of them is GetTriggerUnit(); wire the OTHER to the matching native (you've seen both in
// the editor). If AT_RevivingAltar can't be obtained, leave it returning null: the reserve
// still works on start/cancel/finish; only the rare altar-dies-mid-revive auto-unreserve is lost.
function AT_RevivingAltar takes nothing returns unit
    return GetTriggerUnit()   // the altar = the triggering unit (CONFIRMED by user)
endfunction
function AT_RevivedHero takes nothing returns unit
    // GUI "Reviving Hero" = the unit being revived (CONFIRMED via convert-to-custom-text).
    return GetRevivingUnit()
endfunction

//================================================================ EVENT HANDLERS
//------------------------------------------------ main trains a hero (start)
function AT_OnTrainStart takes nothing returns nothing
    // GetTriggerUnit() = the training structure (altar, main-owned). GetTrainedUnit() can be
    // null at START, so detect the hero by its TYPE (every trainable hero is in roster key 1).
    local integer team = AT_TeamOf(GetOwningPlayer(GetTriggerUnit()))
    if team >= 0 and AT_IsMainPlayer(GetOwningPlayer(GetTriggerUnit())) and HaveSavedInteger(AT_ht, 1, GetTrainedUnitType()) then
        call AT_CountTrainStart(team)
    endif
endfunction

//------------------------------------------------ main trains a hero (finish)
function AT_OnTrainFinish takes nothing returns nothing
    local unit u = GetTrainedUnit()
    local integer team
    if IsUnitType(u, UNIT_TYPE_HERO) and AT_IsMainPlayer(GetOwningPlayer(u)) then
        set team = AT_TeamOf(GetOwningPlayer(u))
        if team >= 0 then
            call AT_CountTrainStop(team)        // cancel the in-training dummyHero
            call AT_CountPlusPermanent(team)    // permanent +1
            call AT_LockHeroType(team, GetUnitTypeId(u))
        endif
    endif
    set u = null
endfunction

//------------------------------------------------ main cancels hero training
function AT_OnTrainCancel takes nothing returns nothing
    // At TRAIN_CANCEL the trained unit may not exist (cancelled before completion) so
    // GetTrainedUnit() is null -> IsUnitType(null,HERO) was false and the dummy never got cancelled.
    // Detect the hero by TYPE (roster key 1), same as AT_OnTrainStart.
    local integer team = AT_TeamOf(GetOwningPlayer(GetTriggerUnit()))
    if team >= 0 and AT_IsMainPlayer(GetOwningPlayer(GetTriggerUnit())) and HaveSavedInteger(AT_ht, 1, GetTrainedUnitType()) then
        call AT_CountTrainStop(team)
    endif
endfunction

//------------------------------------------------ support buys a BuyProxy
function AT_OnSell takes nothing returns nothing
    local unit sold = GetSoldUnit()
    local player buyer = GetOwningPlayer(sold)
    local integer ptype = GetUnitTypeId(sold)
    local integer team = AT_TeamOf(buyer)
    local integer neutral
    local unit realHero
    local integer mainId
    local item tpItem
    if team < 0 then
        set sold = null
        return
    endif
    if HaveSavedInteger(AT_ht, 2, ptype) then
        // A BuyProxy was bought (by main OR support) -> spawn the real hero for the MAIN, remove proxy.
        set neutral = LoadInteger(AT_ht, 2, ptype)
        // The proxy is itself a HERO sold at a neutral building, so the stock melee "first hero gets a
        // Scroll of Town Portal" handler already fired on it: it put a 'stwp' on the PROXY (which we
        // delete) and bumped bj_meleeTwinkedHeroes[buyer]. Undo both...
        set tpItem = UnitItemInSlot(sold, 0)
        if GetItemTypeId(tpItem) == 'stwp' then
            set bj_meleeTwinkedHeroes[GetPlayerId(buyer)] = bj_meleeTwinkedHeroes[GetPlayerId(buyer)] - 1
            call RemoveItem(tpItem)
        endif
        set realHero = CreateUnit(AT_Main(team), neutral, GetUnitX(sold), GetUnitY(sold), bj_UNIT_FACING)
        call RemoveUnit(sold)
        // ...then re-grant the TP to the REAL hero, keyed to the MAIN's counter (the same slot the melee
        // uses for the main's ALTAR heroes -> the team's first-N rule holds and we never double-grant;
        // later team heroes, count >= MAX, correctly get nothing).
        set mainId = GetPlayerId(AT_Main(team))
        if bj_meleeTwinkedHeroes[mainId] < bj_MELEE_MAX_TWINKED_HEROES then
            call UnitAddItemById(realHero, 'stwp')
            set bj_meleeTwinkedHeroes[mainId] = bj_meleeTwinkedHeroes[mainId] + 1
        endif
        call AT_CountPlusPermanent(team)
        call AT_LockHeroType(team, neutral)          // locks the real + its proxy (no duplicate)
        set realHero = null
        set tpItem = null
    elseif HaveSavedInteger(AT_ht, 1, ptype) and AT_IsMainPlayer(buyer) then
        // MAIN bought a real tavern hero directly -> count it + lock (no spawn needed).
        call AT_CountPlusPermanent(team)
        call AT_LockHeroType(team, ptype)
    elseif (not AT_IsMainPlayer(buyer)) and (not IsUnitType(sold, UNIT_TYPE_HERO)) then
        // SUPPORT bought a non-hero (e.g. a mercenary) -> hand it to the main; the support owns
        // nothing. Safe in this SELL handler: dummies are CreateUnit'd, never SOLD, so it never
        // sees them (unlike the old enter-map AC_OnSpawn that grabbed the dummy altar).
        call SetUnitOwner(sold, AT_Main(team), true)
    endif
    set sold = null
endfunction

//------------------------------------------------ a unit dies
function AT_OnDeath takes nothing returns nothing
    local unit u = GetTriggerUnit()
    local integer team = AT_TeamOf(GetOwningPlayer(u))
    local unit h
    if team < 0 then
        set u = null
        return
    endif
    // Altar that was mid-revive just died (no native cancel event fires) -> un-reserve its hero.
    if HaveSavedHandle(AT_ht, 8, GetHandleId(u)) then
        set h = LoadUnitHandle(AT_ht, 8, GetHandleId(u))
        call RemoveSavedHandle(AT_ht, 9, GetHandleId(h))
        call RemoveSavedHandle(AT_ht, 8, GetHandleId(u))
        call AT_UnreserveReviveDummy(h)
        set h = null
    endif
    if IsUnitType(u, UNIT_TYPE_HERO) and AT_IsMainPlayer(GetOwningPlayer(u)) then
        // Spawn the ReviveDummy on death; it inherits the real hero's death timer, so it
        // greys-then-unlocks in the tavern in sync (confirmed in-editor). The ReviveDummy then
        // simply persists until the real hero revives (by either the altar or our redirect).
        call AT_MakeReviveDummy(team, u)
    elseif HaveSavedInteger(AT_ht, 4, GetUnitTypeId(u)) or HaveSavedInteger(AT_ht, 5, GetUnitTypeId(u)) then
        call AT_ReconcileBuildings(team)   // main lost an altar/tier -> re-sync dummies
    endif
    set u = null
endfunction

//------------------------------------------------ a building finishes / upgrades
function AT_OnBuildFinish takes nothing returns nothing
    local integer team = AT_TeamOf(GetOwningPlayer(GetTriggerUnit()))
    if team >= 0 and AT_IsMainPlayer(GetOwningPlayer(GetTriggerUnit())) then
        call AT_ReconcileBuildings(team)
    endif
endfunction

//------------------------------------------------ altar STARTS reviving a real hero -> reserve
function AT_OnReviveStart takes nothing returns nothing
    local unit hero = AT_RevivedHero()
    local unit altar = AT_RevivingAltar()
    if AT_TeamOf(GetOwningPlayer(hero)) >= 0 and AT_IsMainPlayer(GetOwningPlayer(hero)) then
        call AT_ReserveReviveDummy(hero)               // pull it from the support's tavern
        if altar != null then                          // track for the altar-death edge
            call SaveUnitHandle(AT_ht, 8, GetHandleId(altar), hero)
            call SaveUnitHandle(AT_ht, 9, GetHandleId(hero), altar)
        endif
    endif
    set hero = null
    set altar = null
endfunction

//------------------------------------------------ altar revive CANCELLED -> un-reserve
function AT_OnReviveCancel takes nothing returns nothing
    local unit hero = AT_RevivedHero()
    local unit altar
    if HaveSavedHandle(AT_ht, 9, GetHandleId(hero)) then
        set altar = LoadUnitHandle(AT_ht, 9, GetHandleId(hero))
        if altar != null then
            call RemoveSavedHandle(AT_ht, 8, GetHandleId(altar))
        endif
        call RemoveSavedHandle(AT_ht, 9, GetHandleId(hero))
    endif
    call AT_UnreserveReviveDummy(hero)                 // hero still dead -> back to the tavern
    set hero = null
    set altar = null
endfunction

//------------------------------------------------ a hero REVIVES (completes)
function AT_OnReviveFinish takes nothing returns nothing
    local unit u = AT_RevivedHero()
    local integer team = AT_TeamOf(GetOwningPlayer(u))
    local unit dead
    local unit altar
    if team >= 0 and HaveSavedHandle(AT_ht, 7, GetHandleId(u)) then
        // u is a ReviveDummy the support revived at the tavern -> redirect to the real hero.
        set dead = LoadUnitHandle(AT_ht, 7, GetHandleId(u))
        if dead != null then
            call ReviveHero(dead, GetUnitX(u), GetUnitY(u), true)
            call AT_RemoveReviveDummyFor(dead)
        endif
        call RemoveUnit(u) // remove the (briefly alive, model-less) ReviveDummy
    else
        // a real main hero finished reviving at its altar -> drop tracking + its ReviveDummy
        if HaveSavedHandle(AT_ht, 9, GetHandleId(u)) then
            set altar = LoadUnitHandle(AT_ht, 9, GetHandleId(u))
            if altar != null then
                call RemoveSavedHandle(AT_ht, 8, GetHandleId(altar))
            endif
            call RemoveSavedHandle(AT_ht, 9, GetHandleId(u))
        endif
        call AT_RemoveReviveDummyFor(u)
    endif
    set u = null
    set dead = null
    set altar = null
endfunction

//============================================================== INIT
function AT_RegisterRosterEntry takes integer realType, integer reviveType returns nothing
    call SaveInteger(AT_ht, 1, realType, reviveType)
    call SaveInteger(AT_ht, 3, reviveType, 1)
endfunction

function AT_RegisterProxy takes integer proxyType, integer neutralType returns nothing
    call SaveInteger(AT_ht, 2, proxyType, neutralType)   // proxy -> neutral
    call SaveInteger(AT_ht, 10, neutralType, proxyType)  // neutral -> proxy (for dup-lockout)
endfunction

function AT_InitRoster takes nothing returns nothing
    // ReviveDummies (real hero -> Ar<race><n>), user-confirmed order
    call AT_RegisterRosterEntry('Hpal', 'ArH1')
    call AT_RegisterRosterEntry('Hamg', 'ArH2')
    call AT_RegisterRosterEntry('Hmkg', 'ArH3')
    call AT_RegisterRosterEntry('Hblm', 'ArH4')
    call AT_RegisterRosterEntry('Obla', 'ArO1')
    call AT_RegisterRosterEntry('Ofar', 'ArO2')
    call AT_RegisterRosterEntry('Otch', 'ArO3')
    call AT_RegisterRosterEntry('Oshd', 'ArO4')
    call AT_RegisterRosterEntry('Udea', 'ArU1')
    call AT_RegisterRosterEntry('Ulic', 'ArU2')
    call AT_RegisterRosterEntry('Udre', 'ArU3')
    call AT_RegisterRosterEntry('Ucrl', 'ArU4')
    call AT_RegisterRosterEntry('Ekee', 'ArE1')
    call AT_RegisterRosterEntry('Emoo', 'ArE2')
    call AT_RegisterRosterEntry('Edem', 'ArE3')
    call AT_RegisterRosterEntry('Ewar', 'ArE4')
    call AT_RegisterRosterEntry('Nalc', 'ArN1')
    call AT_RegisterRosterEntry('Nngs', 'ArN2')
    call AT_RegisterRosterEntry('Ntin', 'ArN3')
    call AT_RegisterRosterEntry('Nbst', 'ArN4')
    call AT_RegisterRosterEntry('Npbm', 'ArN5')
    call AT_RegisterRosterEntry('Nbrn', 'ArN6')
    call AT_RegisterRosterEntry('Nfir', 'ArN7')
    call AT_RegisterRosterEntry('Nplh', 'ArN8')
    // BuyProxies (ArT<n> -> neutral hero)
    call AT_RegisterProxy('ArT1', 'Nalc')
    call AT_RegisterProxy('ArT2', 'Nngs')
    call AT_RegisterProxy('ArT3', 'Ntin')
    call AT_RegisterProxy('ArT4', 'Nbst')
    call AT_RegisterProxy('ArT5', 'Npbm')
    call AT_RegisterProxy('ArT6', 'Nbrn')
    call AT_RegisterProxy('ArT7', 'Nfir')
    call AT_RegisterProxy('ArT8', 'Nplh')
    // altar types (dependency-equivalent set)
    call SaveInteger(AT_ht, 4, 'halt', 1) // Altar of Kings
    call SaveInteger(AT_ht, 4, 'oalt', 1) // Altar of Storms
    call SaveInteger(AT_ht, 4, 'uaod', 1) // Altar of Darkness
    call SaveInteger(AT_ht, 4, 'eate', 1) // Altar of Elders
    // town-hall types -> tier
    call SaveInteger(AT_ht, 5, 'hkee', 2) // Keep
    call SaveInteger(AT_ht, 5, 'hcas', 3) // Castle
    call SaveInteger(AT_ht, 5, 'ostr', 2) // Stronghold
    call SaveInteger(AT_ht, 5, 'ofrt', 3) // Fortress
    call SaveInteger(AT_ht, 5, 'unp1', 2) // Halls of the Dead
    call SaveInteger(AT_ht, 5, 'unp2', 3) // Black Citadel
    call SaveInteger(AT_ht, 5, 'etoa', 2) // Tree of Ages
    call SaveInteger(AT_ht, 5, 'etoe', 3) // Tree of Eternity
endfunction

// No-op: the tavern now sells ONLY the 8 BuyProxies (proxies-only), bought by both the main and the
// support, so there's nothing to hide per-player. (Selling the 8 real neutrals too overflowed the
// tavern's ~12-button command card, hiding 4 proxies from the support.) The no-duplicate lockout is
// applied at buy time by AT_LockHeroType.
function AT_InitTavernLocks takes integer team returns nothing
endfunction

function ArchonTavern_Init takes nothing returns nothing
    local integer t = 0
    // init globals (vanilla JASS forbids function-call initializers in the globals block)
    set AT_ht = InitHashtable()
    set AT_trainStart = CreateTrigger()
    set AT_trainFinish = CreateTrigger()
    set AT_trainCancel = CreateTrigger()
    set AT_sell = CreateTrigger()
    set AT_death = CreateTrigger()
    set AT_buildFinish = CreateTrigger()
    set AT_reviveStart = CreateTrigger()
    set AT_reviveFinish = CreateTrigger()
    set AT_reviveCancel = CreateTrigger()
    // (AI-support removal lives in core.j / ArchonCore_Init)
    call AT_InitRoster()
    loop
        exitwhen t > 1
        call AT_InitTavernLocks(t)        // hide proxies from the main (real heroes only)
        if AT_SupportActive(t) then       // only wire dummy mechanics for teams that HAVE a support
            set AT_x[t] = GetStartLocationX(GetPlayerStartLocation(AT_Support(t)))
            set AT_y[t] = GetStartLocationY(GetPlayerStartLocation(AT_Support(t)))
            call AT_ReconcileBuildings(t)
        endif
        set t = t + 1
    endloop
    // events (any unit, then filtered in the handlers)
    call TriggerRegisterAnyUnitEventBJ(AT_trainStart, EVENT_PLAYER_UNIT_TRAIN_START)
    call TriggerAddAction(AT_trainStart, function AT_OnTrainStart)
    call TriggerRegisterAnyUnitEventBJ(AT_trainFinish, EVENT_PLAYER_UNIT_TRAIN_FINISH)
    call TriggerAddAction(AT_trainFinish, function AT_OnTrainFinish)
    call TriggerRegisterAnyUnitEventBJ(AT_trainCancel, EVENT_PLAYER_UNIT_TRAIN_CANCEL)
    call TriggerAddAction(AT_trainCancel, function AT_OnTrainCancel)
    call TriggerRegisterAnyUnitEventBJ(AT_sell, EVENT_PLAYER_UNIT_SELL)
    call TriggerAddAction(AT_sell, function AT_OnSell)
    call TriggerRegisterAnyUnitEventBJ(AT_death, EVENT_PLAYER_UNIT_DEATH)
    call TriggerAddAction(AT_death, function AT_OnDeath)
    call TriggerRegisterAnyUnitEventBJ(AT_buildFinish, EVENT_PLAYER_UNIT_CONSTRUCT_FINISH)
    call TriggerRegisterAnyUnitEventBJ(AT_buildFinish, EVENT_PLAYER_UNIT_UPGRADE_FINISH)
    call TriggerAddAction(AT_buildFinish, function AT_OnBuildFinish)
    call TriggerRegisterAnyUnitEventBJ(AT_reviveStart, EVENT_PLAYER_HERO_REVIVE_START)
    call TriggerAddAction(AT_reviveStart, function AT_OnReviveStart)
    call TriggerRegisterAnyUnitEventBJ(AT_reviveFinish, EVENT_PLAYER_HERO_REVIVE_FINISH)
    call TriggerAddAction(AT_reviveFinish, function AT_OnReviveFinish)
    call TriggerRegisterAnyUnitEventBJ(AT_reviveCancel, EVENT_PLAYER_HERO_REVIVE_CANCEL)
    call TriggerAddAction(AT_reviveCancel, function AT_OnReviveCancel)
endfunction
