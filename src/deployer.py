"""Archon deployer — converts a vanilla melee .w3x into an Archon map.

Strategy: COPY the source map, then use MPQEditor to add/replace only the files we change
(merged war3map.w3u, war3mapMisc.txt, and later the spliced script). MPQEditor preserves the
source's compression / (attributes) / header, so the output is as WC3-valid as the input.
Reading/merging is pure-Python (mpq.py, objdata.py, constants.py); only the repack is MPQEditor.

Phases done here: 2c (object data merge) + 2d (constants). TODO: 2a script splice, 2b W3I.
"""

from __future__ import annotations

import argparse
import glob
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.dont_write_bytecode = True  # keep the user's folder clean — no __pycache__
import mpq          # noqa: E402
import objdata      # noqa: E402
import constants    # noqa: E402
import w3i          # noqa: E402

import re             # noqa: E402

MPQEDITOR = os.path.join(HERE, "..", "tools", "MPQEditor.exe")
DUMMY_W3O = os.path.join(HERE, "..", "helpers", "archon_objdata.w3o")
CORE_J = os.path.join(HERE, "..", "jass", "core.j")
TAVERN_J = os.path.join(HERE, "..", "jass", "tavern.j")
CORE_LUA = os.path.join(HERE, "..", "lua", "core.lua")
TAVERN_LUA = os.path.join(HERE, "..", "lua", "tavern.lua")
PJASS = os.path.join(HERE, "..", "tools", "pjass.exe")
COMMON_J = os.path.join(HERE, "..", "tools", "jass", "common.j")
BLIZZARD_J = os.path.join(HERE, "..", "tools", "jass", "Blizzard.j")


def pjass_check(spliced_j: str):
    """Compile-check the spliced war3map.j with pjass against common.j/Blizzard.j. Raises with
    the compiler output on any error, so a bad splice never ships a 'corrupted' map.

    Retries a known pjass non-determinism bug: it occasionally reports a perfectly valid identifier
    as `Undeclared <kind> X. Maybe you meant X` (the suggestion is identical to the missing name) —
    a re-run on the same input clears it. We only retry on that exact signature, so real (and
    deterministic) errors still fail fast on the first attempt."""
    if not (os.path.exists(PJASS) and os.path.exists(COMMON_J)):
        print("  note: optional JASS compile-check skipped (pjass/common.j not present)")
        return
    with tempfile.TemporaryDirectory() as td:
        jf = os.path.join(td, "check.j")
        open(jf, "w", encoding="latin-1").write(spliced_j)
        out = ""
        for _ in range(3):
            r = subprocess.run([os.path.abspath(PJASS), os.path.abspath(COMMON_J),
                                os.path.abspath(BLIZZARD_J), jf], capture_output=True, text=True)
            if r.returncode == 0:
                print("  pjass: spliced war3map.j compiles OK")
                return
            out = (r.stdout or "") + (r.stderr or "")
            if not re.search(r"Undeclared \w+ (\w+)\. Maybe you meant \1\b", out):
                break  # deterministic / real error — don't waste retries
            print("  pjass: transient non-determinism, retrying...")
    raise RuntimeError("pjass rejected the spliced war3map.j:\n" + out)


def _split_module(src: str):
    """Return (globals_body, functions) — the lines inside the module's globals block, and
    everything after it (the function definitions)."""
    gi = src.index("globals")
    ge = src.index("endglobals")
    return src[gi + len("globals"):ge], src[ge + len("endglobals"):]


def _archonify_config(map_j: str) -> str:
    """Make config() a 4-player Archon lobby, mirroring the working AutumnLeaves map: bump
    SetPlayers->4 / SetTeams->4, give the supports their OWN start-location indices (2,3) that
    DUPLICATE the mains' coordinates (distinct indices stop melee placement from shuffling a
    support to a random corner), open P2/P3 slots, and add them to InitCustomPlayerSlots.
    No-ops if the map already has P2/P3 (a 2v2 map)."""
    # which player ids does InitCustomPlayerSlots already configure?
    pi = map_j.index("function InitCustomPlayerSlots")
    pend = map_j.index("endfunction", pi)
    slots = map_j[pi:pend]
    present = set(int(m) for m in re.findall(r"SetPlayerController\(\s*Player\((\d+)\)", slots))
    if 2 in present and 3 in present:
        return map_j  # already a 4-player map; leave config alone
    # which start-loc index does each main use, and where is it?
    locs = {int(p): int(l) for p, l in
            re.findall(r"SetPlayerStartLocation\(\s*Player\((\d+)\)\s*,\s*(\d+)\s*\)", slots)}
    coords = {int(i): (x, y) for i, x, y in
              re.findall(r"DefineStartLocation\(\s*(\d+)\s*,\s*([-\d.]+)\s*,\s*([-\d.]+)\s*\)", map_j)}
    m0, m1 = locs.get(0, 0), locs.get(1, 1)            # P0/P1 start-loc indices
    (x0, y0), (x1, y1) = coords[m0], coords[m1]
    # 1) SetPlayers/SetTeams -> 4
    map_j = re.sub(r"(call\s+SetPlayers\(\s*)(\d+)(\s*\))",
                   lambda m: m.group(1) + str(max(int(m.group(2)), 4)) + m.group(3), map_j, count=1)
    map_j = re.sub(r"(call\s+SetTeams\(\s*)(\d+)(\s*\))",
                   lambda m: m.group(1) + str(max(int(m.group(2)), 4)) + m.group(3), map_j, count=1)
    # placement -> USE_MAP_SETTINGS: each player spawns at its ASSIGNED start location with no
    # engine shuffle. The default TEAMS_TOGETHER randomizes the 4 players across the 4 locations
    # and, because supports duplicate the mains' coords, can drop two enemy mains on one spot.
    # (core.j AC_RandomizeStartCorners then does a controlled team-corner coin-flip for fairness.)
    map_j = re.sub(r"call\s+SetGamePlacement\(\s*MAP_PLACEMENT_\w+\s*\)",
                   "call SetGamePlacement( MAP_PLACEMENT_USE_MAP_SETTINGS )", map_j, count=1)
    # 2) define start locations 2 & 3 duplicating the mains' coords, before InitCustomPlayerSlots
    map_j = map_j.replace(
        "call InitCustomPlayerSlots(  )",
        "call DefineStartLocation( 2, %s, %s )\n"
        "    call DefineStartLocation( 3, %s, %s )\n"
        "    call InitCustomPlayerSlots(  )" % (x0, y0, x1, y1), 1)
    # 3) open the support slots, and REPLACE InitGenericPlayerSlots (which dispatches to the melee
    #    FFA slot setup -> one team per player = 4 teams) with explicit Archon 2-team assignment,
    #    mirroring AutumnLeaves' InitCustomTeams. The Reforged lobby reads config()'s team setup,
    #    so this is what collapses the lobby to 2 teams. (Alliance/shared-control is asserted in
    #    core.j AC_FinalizeArchon.)
    team_setup = (
        "call SetPlayerSlotAvailable( Player(2), MAP_CONTROL_USER )\n"
        "    call SetPlayerSlotAvailable( Player(3), MAP_CONTROL_USER )\n"
        "    // Archon teams: P0+P2 = team 0, P1+P3 = team 1\n"
        "    call SetPlayerTeam( Player(0), 0 )\n"
        "    call SetPlayerTeam( Player(2), 0 )\n"
        "    call SetPlayerTeam( Player(1), 1 )\n"
        "    call SetPlayerTeam( Player(3), 1 )")
    if "call InitGenericPlayerSlots(  )" in map_j:
        map_j = map_j.replace("call InitGenericPlayerSlots(  )", team_setup, 1)
    else:
        map_j = map_j.replace("call InitAllyPriorities(  )",
                              team_setup + "\n    call InitAllyPriorities(  )", 1)
    # 4) add P2/P3 to InitCustomPlayerSlots at their own start-loc indices (2,3 -> mains' coords)
    add = (
        "\n    // Player 2 (Archon support, co-located with Player 0)\n"
        "    call SetPlayerStartLocation( Player(2), 2 )\n"
        "    call SetPlayerColor( Player(2), ConvertPlayerColor(2) )\n"
        "    call SetPlayerRacePreference( Player(2), RACE_PREF_RANDOM )\n"
        "    call SetPlayerRaceSelectable( Player(2), true )\n"
        "    call SetPlayerController( Player(2), MAP_CONTROL_USER )\n"
        "\n    // Player 3 (Archon support, co-located with Player 1)\n"
        "    call SetPlayerStartLocation( Player(3), 3 )\n"
        "    call SetPlayerColor( Player(3), ConvertPlayerColor(3) )\n"
        "    call SetPlayerRacePreference( Player(3), RACE_PREF_RANDOM )\n"
        "    call SetPlayerRaceSelectable( Player(3), true )\n"
        "    call SetPlayerController( Player(3), MAP_CONTROL_USER )\n")
    pend = map_j.index("endfunction", map_j.index("function InitCustomPlayerSlots"))
    map_j = map_j[:pend] + add + map_j[pend:]
    return map_j


def splice_jass(map_j: str, core_j: str, tavern_j: str,
                hide_support_score: bool = True, match_support_color: bool = True,
                pre_game_timer: int = 0) -> str:
    """Inject the Archon core + tavern modules into a vanilla melee war3map.j and hook their
    inits in before the melee init runs."""
    if not hide_support_score:
        # keep supports on the post-game score screen (some ranking sites track via the scoreboard)
        core_j = core_j.replace("AC_HIDE_SUPPORT_SCORE = true", "AC_HIDE_SUPPORT_SCORE = false", 1)
    if not match_support_color:
        # supports keep their own lobby color instead of matching the main
        core_j = core_j.replace("AC_MATCH_SUPPORT_COLOR = true", "AC_MATCH_SUPPORT_COLOR = false", 1)
    if pre_game_timer > 0:
        # pre-game coordinate-countdown that freezes units for N seconds at start
        core_j = core_j.replace("AC_PREGAME_TIMER = 0", "AC_PREGAME_TIMER = %d" % pre_game_timer, 1)
    cg, cf = _split_module(core_j)
    tg, tf = _split_module(tavern_j)
    map_j = _archonify_config(map_j)
    # 1) merge Archon globals into the map's globals block (before its endglobals)
    mge = map_j.index("endglobals")
    map_j = map_j[:mge] + "\n// === Archon globals ===\n" + cg + tg + map_j[mge:]
    # 2) inject the Archon functions at the TOP (right after the globals block) so the map's
    #    melee-init function can call AC_MeleePlaceMains (JASS needs callees defined first).
    ge = map_j.index("endglobals") + len("endglobals")
    map_j = map_j[:ge] + "\n\n// === Archon core ===\n" + cf + "\n// === Archon tavern ===\n" + tf + "\n" + map_j[ge:]
    # 3) replace the stock all-players MeleeStartingUnits() with our mains-only placement, so the
    #    supports never get starting units at all (no spawn, no vision flash, nothing to clean up).
    map_j, n = re.subn(r"call\s+MeleeStartingUnits\s*\(\s*\)", "call AC_MeleePlaceMains(  )", map_j, count=1)
    if n != 1:
        raise RuntimeError("could not find MeleeStartingUnits() call to replace in the melee init")
    # 4) hook the inits around the melee init: ArchonCore_Init BEFORE (AI-support removal precedes
    #    MeleeStartingAI; the merc spawn-fix registers here), AC_FinalizeArchon (teams + shared
    #    control, asserted last) + ArchonTavern_Init (town hall now exists) AFTER.
    new, n = re.subn(r"call\s+RunInitializationTriggers\s*\(\s*\)",
                     "call ArchonCore_Init()\n    call RunInitializationTriggers(  )\n"
                     "    call AC_FinalizeArchon()\n    call ArchonTavern_Init()",
                     map_j, count=1)
    if n != 1:
        raise RuntimeError("could not find RunInitializationTriggers call in main()")
    return new


# ============================================================ Lua path (twin of the JASS one)
def _lua_func_end(src: str, start: int) -> int:
    """Index of the closing `end` of a top-level Lua function whose `function` keyword is at `start`.
    Assumes a FLAT body (no nested if/while/for) — true for the stock melee config /
    InitCustomPlayerSlots we touch — so the first column-0 `end` after the header is the closer."""
    m = re.compile(r"^end\b", re.M).search(src, start + 1)
    if not m:
        raise RuntimeError("could not find the Lua function end after index %d" % start)
    return m.start()


def _archonify_config_lua(map_lua: str) -> str:
    """Lua twin of _archonify_config: make config() a 4-player Archon lobby."""
    pi = map_lua.index("function InitCustomPlayerSlots")
    slots = map_lua[pi:_lua_func_end(map_lua, pi)]
    present = set(int(m) for m in re.findall(r"SetPlayerController\(\s*Player\((\d+)\)", slots))
    if 2 in present and 3 in present:
        return map_lua  # already a 4-player map
    locs = {int(p): int(l) for p, l in
            re.findall(r"SetPlayerStartLocation\(\s*Player\((\d+)\)\s*,\s*(\d+)\s*\)", slots)}
    coords = {int(i): (x, y) for i, x, y in
              re.findall(r"DefineStartLocation\(\s*(\d+)\s*,\s*([-\d.]+)\s*,\s*([-\d.]+)\s*\)", map_lua)}
    m0, m1 = locs.get(0, 0), locs.get(1, 1)
    (x0, y0), (x1, y1) = coords[m0], coords[m1]
    # SetPlayers/SetTeams -> 4 ; placement -> USE_MAP_SETTINGS
    map_lua = re.sub(r"(SetPlayers\(\s*)(\d+)(\s*\))",
                     lambda m: m.group(1) + str(max(int(m.group(2)), 4)) + m.group(3), map_lua, count=1)
    map_lua = re.sub(r"(SetTeams\(\s*)(\d+)(\s*\))",
                     lambda m: m.group(1) + str(max(int(m.group(2)), 4)) + m.group(3), map_lua, count=1)
    map_lua = re.sub(r"SetGamePlacement\(\s*MAP_PLACEMENT_\w+\s*\)",
                     "SetGamePlacement(MAP_PLACEMENT_USE_MAP_SETTINGS)", map_lua, count=1)
    # define start locs 2&3 (mains' coords) before the InitCustomPlayerSlots() CALL (not its def)
    map_lua = re.sub(r"(?<!function )InitCustomPlayerSlots\(\s*\)",
                     "DefineStartLocation(2, %s, %s)\nDefineStartLocation(3, %s, %s)\nInitCustomPlayerSlots()"
                     % (x0, y0, x1, y1), map_lua, count=1)
    # explicit Archon 2-team setup, replacing the FFA InitGenericPlayerSlots()
    team_setup = (
        "SetPlayerSlotAvailable(Player(2), MAP_CONTROL_USER)\n"
        "SetPlayerSlotAvailable(Player(3), MAP_CONTROL_USER)\n"
        "-- Archon teams: P0+P2 = team 0, P1+P3 = team 1\n"
        "SetPlayerTeam(Player(0), 0)\n"
        "SetPlayerTeam(Player(2), 0)\n"
        "SetPlayerTeam(Player(1), 1)\n"
        "SetPlayerTeam(Player(3), 1)")
    if "InitGenericPlayerSlots()" in map_lua:
        map_lua = map_lua.replace("InitGenericPlayerSlots()", team_setup, 1)
    else:
        map_lua = map_lua.replace("InitAllyPriorities()", team_setup + "\nInitAllyPriorities()", 1)
    # add P2/P3 to InitCustomPlayerSlots, before its end
    add = (
        "SetPlayerStartLocation(Player(2), 2)\n"
        "SetPlayerColor(Player(2), ConvertPlayerColor(2))\n"
        "SetPlayerRacePreference(Player(2), RACE_PREF_RANDOM)\n"
        "SetPlayerRaceSelectable(Player(2), true)\n"
        "SetPlayerController(Player(2), MAP_CONTROL_USER)\n"
        "SetPlayerStartLocation(Player(3), 3)\n"
        "SetPlayerColor(Player(3), ConvertPlayerColor(3))\n"
        "SetPlayerRacePreference(Player(3), RACE_PREF_RANDOM)\n"
        "SetPlayerRaceSelectable(Player(3), true)\n"
        "SetPlayerController(Player(3), MAP_CONTROL_USER)\n")
    pi = map_lua.index("function InitCustomPlayerSlots")
    pend = _lua_func_end(map_lua, pi)
    return map_lua[:pend] + add + map_lua[pend:]


def lua_check(spliced_lua: str):
    """Optional Lua syntax gate (mirrors pjass_check). Uses luaparser if installed, else skips —
    so the shipped deployer needs no extra dependency."""
    try:
        from luaparser import ast as _lua_ast
    except ImportError:
        print("  note: optional Lua syntax-check skipped (luaparser not installed)")
        return
    try:
        _lua_ast.parse(spliced_lua)
        print("  luaparser: spliced war3map.lua parses OK")
    except Exception as e:
        raise RuntimeError("luaparser rejected the spliced war3map.lua: %s: %s" % (type(e).__name__, e))


def splice_lua(map_lua: str, core_lua: str, tavern_lua: str,
               hide_support_score: bool = True, match_support_color: bool = True,
               pre_game_timer: int = 0) -> str:
    """Lua twin of splice_jass: inject core.lua + tavern.lua and hook the inits."""
    if not hide_support_score:
        core_lua = core_lua.replace("AC_HIDE_SUPPORT_SCORE = true", "AC_HIDE_SUPPORT_SCORE = false", 1)
    if not match_support_color:
        core_lua = core_lua.replace("AC_MATCH_SUPPORT_COLOR = true", "AC_MATCH_SUPPORT_COLOR = false", 1)
    if pre_game_timer > 0:
        core_lua = core_lua.replace("AC_PREGAME_TIMER = 0", "AC_PREGAME_TIMER = %d" % pre_game_timer, 1)
    map_lua = _archonify_config_lua(map_lua)
    # inject our modules just before main() (top-level defs load before main() runs at game start)
    inject = "\n-- === Archon core ===\n" + core_lua + "\n-- === Archon tavern ===\n" + tavern_lua + "\n"
    mi = map_lua.index("function main()")
    map_lua = map_lua[:mi] + inject + map_lua[mi:]
    # replace the all-players MeleeStartingUnits() with mains-only placement (won't match
    # MeleeStartingUnitsForPlayer, which has args)
    map_lua, n = re.subn(r"MeleeStartingUnits\(\s*\)", "AC_MeleePlaceMains()", map_lua, count=1)
    if n != 1:
        raise RuntimeError("could not find MeleeStartingUnits() in the Lua melee init")
    # hook the inits around the RunInitializationTriggers() CALL in main (lookbehind skips the def)
    new, n = re.subn(r"(?<!function )RunInitializationTriggers\(\s*\)",
                     "ArchonCore_Init()\nRunInitializationTriggers()\nAC_FinalizeArchon()\nArchonTavern_Init()",
                     map_lua, count=1)
    if n != 1:
        raise RuntimeError("could not find RunInitializationTriggers() call in Lua main()")
    return new


def _mpq(args):
    """Run an MPQEditor console command, waiting for completion. errorlevel 0 = ok, 5 = perms."""
    r = subprocess.run([os.path.abspath(MPQEDITOR)] + args, capture_output=True, text=True)
    if r.returncode not in (0,):
        raise RuntimeError(f"MPQEditor {args[0]} failed (exit {r.returncode})")
    return r


def mpq_add(archive: str, local_file: str, internal_path: str):
    _mpq(["a", os.path.abspath(archive), os.path.abspath(local_file), internal_path])


def mpq_flush(archive: str):
    _mpq(["f", os.path.abspath(archive)])


def _merged_w3u(src: "mpq.MPQArchive") -> bytes:
    """Read the map's existing war3map.w3u (if any) and merge in the Archon dummies."""
    if src.has_file("war3map.w3u"):
        target = objdata._read_table(objdata._Reader(src.read_file("war3map.w3u")))
    else:
        target = objdata.Table(version=3)
    additions = objdata.read_w3o(DUMMY_W3O).sections["w3u"]
    objdata.merge_table(target, additions)
    w = objdata._Writer(); objdata._write_table(w, target)
    return w.getvalue()


def _merged_misc(src: "mpq.MPQArchive") -> bytes:
    existing = src.read_file("war3mapMisc.txt").decode("latin-1") if src.has_file("war3mapMisc.txt") else ""
    return constants.merge_dependency_equivalents(existing).encode("latin-1")


def convert(vanilla_path: str, out_path: str,
            hide_support_score: bool = True, match_support_color: bool = True,
            pre_game_timer: int = 0):
    """Convert one vanilla map. Currently applies objdata + constants (not the script splice)."""
    os.makedirs(os.path.dirname(os.path.abspath(out_path)), exist_ok=True)
    shutil.copyfile(vanilla_path, out_path)
    src = mpq.MPQArchive(vanilla_path)

    with tempfile.TemporaryDirectory() as td:
        w3u_path = os.path.join(td, "war3map.w3u")
        misc_path = os.path.join(td, "war3mapMisc.txt")
        w3i_path = os.path.join(td, "war3map.w3i")
        open(w3u_path, "wb").write(_merged_w3u(src))                      # 2c objdata
        open(misc_path, "wb").write(_merged_misc(src))                    # 2d constants
        open(w3i_path, "wb").write(w3i.archonify(src.read_file("war3map.w3i")))  # 2b lobby
        mpq_add(out_path, w3u_path, "war3map.w3u")
        mpq_add(out_path, misc_path, "war3mapMisc.txt")
        mpq_add(out_path, w3i_path, "war3map.w3i")
        # 2a script splice — JASS (war3map.j) or Lua (war3map.lua)
        if src.has_file("war3map.j"):
            map_j = src.read_file("war3map.j").decode("latin-1")
            core_j = open(CORE_J, encoding="latin-1").read()
            tavern_j = open(TAVERN_J, encoding="latin-1").read()
            spliced = splice_jass(map_j, core_j, tavern_j, hide_support_score,
                                  match_support_color, pre_game_timer)
            pjass_check(spliced)   # fail loudly here rather than shipping a 'corrupted' map
            j_path = os.path.join(td, "war3map.j")
            open(j_path, "w", encoding="latin-1").write(spliced)
            mpq_add(out_path, j_path, "war3map.j")
        elif src.has_file("war3map.lua"):
            map_lua = src.read_file("war3map.lua").decode("latin-1")
            core_lua = open(CORE_LUA, encoding="latin-1").read()
            tavern_lua = open(TAVERN_LUA, encoding="latin-1").read()
            spliced = splice_lua(map_lua, core_lua, tavern_lua, hide_support_score,
                                 match_support_color, pre_game_timer)
            lua_check(spliced)     # optional Lua syntax gate (skips if luaparser absent)
            lua_path = os.path.join(td, "war3map.lua")
            open(lua_path, "w", encoding="latin-1").write(spliced)
            mpq_add(out_path, lua_path, "war3map.lua")
        else:
            print("  WARNING: no war3map.j or war3map.lua found — script splice skipped")
        mpq_flush(out_path)
    return out_path


def _archon_out_name(src_path: str) -> str:
    """<name>_archon<ext> for a source map (preserves the .w3x/.w3m extension)."""
    name, ext = os.path.splitext(os.path.basename(src_path))
    return name + "_archon" + ext


def convert_batch(src_dir: str, out_dir: str, hide_support_score: bool = True,
                  match_support_color: bool = True, pre_game_timer: int = 0):
    """Convert every melee map in src_dir into out_dir. Safe by design: the source folder is only
    READ, outputs go to a separate folder, an output that already exists is SKIPPED (never
    overwritten), and one map's failure doesn't stop the rest."""
    found = sorted(set(glob.glob(os.path.join(src_dir, "*.w3x")) + glob.glob(os.path.join(src_dir, "*.w3m"))))
    found = [m for m in found if not os.path.splitext(os.path.basename(m))[0].endswith("_archon")]
    if not found:
        print("No .w3x/.w3m maps found in:", src_dir)
        return {"ok": [], "skipped": [], "failed": []}
    ok, skipped, failed = [], [], []
    for m in found:
        base = os.path.basename(m)
        out_path = os.path.join(out_dir, _archon_out_name(m))
        if os.path.exists(out_path):
            print("  SKIP (already exists):", base)
            skipped.append(base)
            continue
        print("  converting:", base)
        try:
            convert(m, out_path, hide_support_score=hide_support_score,
                    match_support_color=match_support_color, pre_game_timer=pre_game_timer)
            ok.append(base)
        except Exception as e:  # noqa: BLE001 — keep going; report failures at the end
            print("  FAILED:", base, "->", e)
            failed.append((base, str(e)))
    print("\nBatch done: %d converted, %d skipped, %d failed (of %d found)."
          % (len(ok), len(skipped), len(failed), len(found)))
    for base, e in failed:
        print("  - FAILED:", base, "->", e)
    return {"ok": ok, "skipped": skipped, "failed": failed}


if __name__ == "__main__":
    ap = argparse.ArgumentParser(description="Convert a vanilla melee .w3x into an Archon map.")
    ap.add_argument("src", help="vanilla melee map (.w3x), or a FOLDER of maps with --batch")
    ap.add_argument("out_dir", help="folder to write the converted map(s) into (named <name>_archon.w3x)")
    ap.add_argument("--show-support-score", action="store_true",
                    help="keep support players on the post-game score screen "
                         "(default: hidden, since their only score is dummy-unit noise)")
    ap.add_argument("--keep-support-color", action="store_true",
                    help="support keeps its own lobby color "
                         "(default: match the main's, so team visuals like rally flags align)")
    ap.add_argument("--pre-game-timer", type=int, default=0, metavar="SECONDS",
                    help="freeze units for SECONDS at game start (countdown shown) so queue partners "
                         "can chat-coordinate; default 0 = off")
    ap.add_argument("--batch", action="store_true",
                    help="treat <src> as a FOLDER and convert every melee map in it")
    args = ap.parse_args()
    opts = dict(hide_support_score=not args.show_support_score,
                match_support_color=not args.keep_support_color,
                pre_game_timer=args.pre_game_timer)
    if args.batch or os.path.isdir(args.src):
        convert_batch(args.src, args.out_dir, **opts)
    else:
        out_path = os.path.join(args.out_dir, _archon_out_name(args.src))
        print("converted ->", convert(args.src, out_path, **opts))
