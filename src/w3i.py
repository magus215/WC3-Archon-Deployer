"""Phase 2b — edit war3map.w3i to set up the Archon lobby: 4 players in 2 teams
(P0+P2 and P1+P3), supports sharing the mains' start positions, with allied/shared-control
force flags. Derived from diffing a vanilla melee w3i against a working Archon one (v33).

Player record:  int num, type, race, fixed ; cstring name ; float startX, startY ; int[4] priorities
Force record:   int flags, mask ; cstring name
The header before the players block and any trailing sections are preserved verbatim.
"""

from __future__ import annotations

import struct

# Archon force flags = allied | allied-victory | shared vision | shared unit control | shared adv control
FORCE_FLAGS = 0x3B
# team masks (mirror the working map: team-0 force also owns the unused upper slots)
TEAM0_MASK = 0xFFFFFFF5   # everything except P1,P3  -> {P0,P2,(unused)}
TEAM1_MASK = 0x0000000A   # {P1,P3}
# map-level flags. Set exactly the bits the working AutumnLeaves Archon map has over a vanilla
# melee map, so the lobby shows our 2 forces as 2 teams: vanilla BoulderVale=0xdc18,
# AutumnLeaves=0x1dc5a; the delta is 0x40 (use custom forces) | 0x02 (modify ally priorities)
# | 0x10000 (Reforged bit AutumnLeaves sets). We deliberately do NOT set 0x20 "fixed player
# settings" — it would lock player colors, which we want to stay changeable.
MAP_FLAGS_SET = 0x40 | 0x02 | 0x10000


def _cstr(b, o):
    e = b.index(b"\0", o)
    return b[o:e].decode("latin-1", "replace"), e + 1


def _map_flags_offset(w: bytes) -> int:
    """Walk the w3i header to the map-flags int (after the 4 strings, camera data, w/h)."""
    o = 0
    ver = struct.unpack_from("<i", w, o)[0]; o += 12   # version, saves, editor version
    if ver >= 28:
        o += 16                                        # Reforged game-version block (4 ints)
    for _ in range(4):                                 # name, author, description, recommended
        o = w.index(b"\0", o) + 1
    o += 32 + 16                                       # camera bounds (8 floats) + complements (4 ints)
    o += 8                                             # playable width + height
    return o                                           # flags int


def _set_map_flags(w: bytes) -> bytes:
    off = _map_flags_offset(w)
    flags = struct.unpack_from("<I", w, off)[0]
    flags |= MAP_FLAGS_SET
    return w[:off] + struct.pack("<I", flags) + w[off + 4:]


def _locate_players(w: bytes) -> int:
    """Return the offset of the maxPlayers int by validating the players+forces records."""
    for off in range(40, len(w) - 8):
        o = off
        n = struct.unpack_from("<i", w, o)[0]; o += 4
        if not (1 <= n <= 28):
            continue
        ok = True
        for _ in range(n):
            if o + 16 > len(w):
                ok = False; break
            num, typ, race, _fx = struct.unpack_from("<iiii", w, o); o += 16
            if not (0 <= num <= 27 and 1 <= typ <= 4 and 0 <= race <= 4):
                ok = False; break
            if b"\0" not in w[o:]:
                ok = False; break
            o = w.index(b"\0", o) + 1
            o += 8 + 16   # startXY + 4 priority ints
        if not ok or o + 4 > len(w):
            continue
        nf = struct.unpack_from("<i", w, o)[0]; o += 4
        if not (1 <= nf <= 28):
            continue
        for _ in range(nf):
            if o + 8 > len(w) or b"\0" not in w[o + 8:]:
                ok = False; break
            o = w.index(b"\0", o + 8) + 1
        if ok and o <= len(w):
            return off
    raise ValueError("could not locate players block in war3map.w3i")


def _read_block(w: bytes, off: int):
    """Return (header, mains[2 (num,start)], trailing) from a w3i, parsing players+forces."""
    o = off
    n = struct.unpack_from("<i", w, o)[0]; o += 4
    players = []
    for _ in range(n):
        num, typ, race, fx = struct.unpack_from("<iiii", w, o); o += 16
        name, o = _cstr(w, o)
        sx, sy = struct.unpack_from("<ff", w, o); o += 8
        o += 16
        players.append((num, name, sx, sy))
    nf = struct.unpack_from("<i", w, o)[0]; o += 4
    for _ in range(nf):
        o += 8
        _name, o = _cstr(w, o)
    return w[:off], players, w[o:]


def _ser_player(num, name, sx, sy, race=0, typ=1, fixed=2):
    return (struct.pack("<iiii", num, typ, race, fixed)
            + name.encode("latin-1", "replace") + b"\0"
            + struct.pack("<ff", sx, sy)
            + struct.pack("<iiii", 0, 0, 0, 0))


def _ser_force(flags, mask, name):
    return struct.pack("<II", flags & 0xFFFFFFFF, mask & 0xFFFFFFFF) + name.encode("latin-1", "replace") + b"\0"


def archonify(w3i: bytes) -> bytes:
    """Return a war3map.w3i set up for a 4-player Archon lobby (P0+P2 / P1+P3)."""
    w3i = _set_map_flags(w3i)   # turn on "use custom forces" so the lobby honors our 2 teams
    off = _locate_players(w3i)
    header, players, trailing = _read_block(w3i, off)
    if len(players) < 2:
        raise ValueError("source map has fewer than 2 players; not a standard melee map")
    # main 0 = red (Player 0); main 1 = the player whose start is FARTHEST from red. This mirrors the
    # script's red-anchored placement so the lobby preview matches the in-game spawns. On a 1v1 (2
    # players) "farthest" is just the other player = unchanged.
    red = next((p for p in players if p[0] == 0), players[0])
    others = [p for p in players if p is not red] or [red]
    mb = max(others, key=lambda p: (p[2] - red[2]) ** 2 + (p[3] - red[3]) ** 2)

    new_players = struct.pack("<i", 4)
    new_players += _ser_player(0, red[1], red[2], red[3])   # main 0 = red (keep name+start)
    new_players += _ser_player(1, mb[1], mb[2], mb[3])      # main 1 = farthest from red
    new_players += _ser_player(2, "", red[2], red[3])       # support 0 -> shares red's start
    new_players += _ser_player(3, "", mb[2], mb[3])         # support 1 -> shares main 1's start

    new_forces = struct.pack("<i", 2)
    new_forces += _ser_force(FORCE_FLAGS, TEAM0_MASK, "Team 1")
    new_forces += _ser_force(FORCE_FLAGS, TEAM1_MASK, "Team 2")

    return header + new_players + new_forces + trailing


if __name__ == "__main__":
    import sys
    sys.path.insert(0, __import__("os").path.dirname(__file__))
    import mpq
    a = mpq.MPQArchive(sys.argv[1])
    out = archonify(a.read_file("war3map.w3i"))
    open(sys.argv[2], "wb").write(out)
    print("wrote archon w3i:", sys.argv[2], len(out), "bytes")
