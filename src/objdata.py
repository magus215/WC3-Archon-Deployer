"""Read/write Warcraft III object-data (.w3u and the combined .w3o export).

Targets the Reforged format (.w3u table version 3, with per-object "sets"). Round-trip
fidelity is the contract: reading a file and writing it back must reproduce it byte-for-byte,
so generated output is guaranteed import-valid in the World Editor.

A .w3o ("export all object data") is: int32 version, then 7 sections in fixed order
(units w3u, items w3t, destructables w3b, doodads w3d, abilities w3a, buffs w3h, upgrades w3q),
each prefixed by an int32 "used" flag (1 = body follows, 0 = absent).

A table body (e.g. w3u): int32 tableVersion, then the originals table, then the customs table;
each table is int32 count followed by that many objects.

An object (v3): origId[4], newId[4], int32 setCount, then each set: int32 setMarker, int32
modCount, then modCount mods. A mod: modId[4], int32 varType (0 int, 1/2 float, 3 string),
the value, then a 4-byte terminator (0).
"""

from __future__ import annotations

import struct
from dataclasses import dataclass, field

# .w3o section order and the table tag each maps to.
W3O_SECTIONS = ["w3u", "w3t", "w3b", "w3d", "w3a", "w3h", "w3q"]

VAR_INT, VAR_REAL, VAR_UNREAL, VAR_STRING = 0, 1, 2, 3


@dataclass
class Mod:
    id: str            # 4-char field code, e.g. "umdl"
    var_type: int      # 0 int, 1 real, 2 unreal, 3 string
    value: object      # int | float | str
    term: int = 0      # trailing 4-byte terminator (observed 0)


@dataclass
class Set:
    marker: int            # per-set variation/skin marker (0 = base)
    mods: list             # list[Mod]


@dataclass
class Obj:
    orig_id: str           # base unit id, e.g. "Hpal"
    new_id: str            # custom id, e.g. "ArH1"  (4 NUL chars for original-object edits)
    sets: list             # list[Set]


@dataclass
class Table:
    version: int
    originals: list = field(default_factory=list)   # list[Obj] (edits to existing objects)
    customs: list = field(default_factory=list)      # list[Obj] (new objects)


@dataclass
class W3O:
    version: int
    sections: dict = field(default_factory=dict)     # tag -> Table (only present sections)


class _Reader:
    def __init__(self, data: bytes):
        self.d = data
        self.o = 0

    def i32(self) -> int:
        v = struct.unpack_from("<i", self.d, self.o)[0]; self.o += 4; return v

    def f32(self) -> float:
        v = struct.unpack_from("<f", self.d, self.o)[0]; self.o += 4; return v

    def tag(self) -> str:
        v = self.d[self.o:self.o + 4]; self.o += 4; return v.decode("latin-1")

    def cstr(self) -> str:
        end = self.d.index(b"\0", self.o)
        s = self.d[self.o:end].decode("latin-1"); self.o = end + 1; return s


class _Writer:
    def __init__(self):
        self.parts: list[bytes] = []

    def i32(self, v: int): self.parts.append(struct.pack("<i", v))
    def f32(self, v: float): self.parts.append(struct.pack("<f", v))
    def tag(self, s: str): self.parts.append(s.encode("latin-1").ljust(4, b"\0")[:4])
    def cstr(self, s: str): self.parts.append(s.encode("latin-1") + b"\0")
    def getvalue(self) -> bytes: return b"".join(self.parts)


def _read_mod(r: _Reader) -> Mod:
    mid = r.tag()
    vt = r.i32()
    if vt == VAR_INT:
        val = r.i32()
    elif vt in (VAR_REAL, VAR_UNREAL):
        val = r.f32()
    elif vt == VAR_STRING:
        val = r.cstr()
    else:
        raise ValueError(f"unknown var type {vt} for mod {mid}")
    term = r.i32()
    return Mod(mid, vt, val, term)


def _write_mod(w: _Writer, m: Mod):
    w.tag(m.id)
    w.i32(m.var_type)
    if m.var_type == VAR_INT:
        w.i32(int(m.value))
    elif m.var_type in (VAR_REAL, VAR_UNREAL):
        w.f32(float(m.value))
    elif m.var_type == VAR_STRING:
        w.cstr(str(m.value))
    else:
        raise ValueError(f"unknown var type {m.var_type}")
    w.i32(m.term)


def _read_obj(r: _Reader) -> Obj:
    orig = r.tag()
    new = r.tag()
    set_count = r.i32()
    sets = []
    for _ in range(set_count):
        marker = r.i32()
        mod_count = r.i32()
        mods = [_read_mod(r) for _ in range(mod_count)]
        sets.append(Set(marker, mods))
    return Obj(orig, new, sets)


def _write_obj(w: _Writer, obj: Obj):
    w.tag(obj.orig_id)
    w.tag(obj.new_id)
    w.i32(len(obj.sets))
    for s in obj.sets:
        w.i32(s.marker)
        w.i32(len(s.mods))
        for m in s.mods:
            _write_mod(w, m)


def _read_table(r: _Reader) -> Table:
    version = r.i32()
    n_orig = r.i32()
    originals = [_read_obj(r) for _ in range(n_orig)]
    n_cust = r.i32()
    customs = [_read_obj(r) for _ in range(n_cust)]
    return Table(version, originals, customs)


def _write_table(w: _Writer, t: Table):
    w.i32(t.version)
    w.i32(len(t.originals))
    for o in t.originals:
        _write_obj(w, o)
    w.i32(len(t.customs))
    for o in t.customs:
        _write_obj(w, o)


def read_w3o(path: str) -> W3O:
    r = _Reader(open(path, "rb").read())
    version = r.i32()
    sections = {}
    for tag in W3O_SECTIONS:
        used = r.i32()
        if used:
            sections[tag] = _read_table(r)
    return W3O(version, sections)


def write_w3o(w3o: W3O, path: str):
    w = _Writer()
    w.i32(w3o.version)
    for tag in W3O_SECTIONS:
        if tag in w3o.sections:
            w.i32(1)
            _write_table(w, w3o.sections[tag])
        else:
            w.i32(0)
    open(path, "wb").write(w.getvalue())


import copy as _copy


class RawcodeCollision(Exception):
    """A generated custom id already exists in the target map."""


def merge_table(target: Table, additions: Table, list_fields=("useu",)) -> Table:
    """Merge `additions` into `target` in place (and return it), preserving the target's
    existing objects. Custom objects are appended (collision-checked by new_id). Original-object
    edits are merged by orig_id: list-type fields (e.g. the tavern's `useu` sold list) are
    appended-and-deduped; other fields override. Used for deployer Phase 2c on maps that already
    carry custom objdata (e.g. W3Champions creeps)."""
    have = {o.new_id for o in target.customs}
    clash = [o.new_id for o in additions.customs if o.new_id in have]
    if clash:
        raise RawcodeCollision(f"custom ids already present in target: {clash}")
    target.customs.extend(_copy.deepcopy(o) for o in additions.customs)

    by_id = {o.orig_id: o for o in target.originals}
    for add_obj in additions.originals:
        tgt = by_id.get(add_obj.orig_id)
        if tgt is None:
            target.originals.append(_copy.deepcopy(add_obj))
            continue
        tmods = tgt.sets[0].mods
        tmap = {m.id: m for m in tmods}
        for am in add_obj.sets[0].mods:
            if am.id in list_fields and am.id in tmap:
                cur = [x for x in str(tmap[am.id].value).split(",") if x]
                cur += [x for x in str(am.value).split(",") if x and x not in cur]
                tmap[am.id].value = ",".join(cur)
            elif am.id in tmap:
                tmap[am.id].value = am.value
            else:
                tmods.append(_copy.deepcopy(am))
    return target


# Standalone .w3u (inside a map MPQ) is just a Table with no section wrapper.
def read_w3u(path: str) -> Table:
    return _read_table(_Reader(open(path, "rb").read()))


def write_w3u(table: Table, path: str):
    w = _Writer(); _write_table(w, table); open(path, "wb").write(w.getvalue())


if __name__ == "__main__":
    import sys
    src = sys.argv[1]
    w3o = read_w3o(src)
    # Round-trip check: write back and compare bytes.
    import io
    w = _Writer(); w.i32(w3o.version)
    for tag in W3O_SECTIONS:
        if tag in w3o.sections:
            w.i32(1); _write_table(w, w3o.sections[tag])
        else:
            w.i32(0)
    out = w.getvalue()
    orig = open(src, "rb").read()
    print(f"round-trip: {'IDENTICAL' if out == orig else 'DIFF'} "
          f"({len(out)} vs {len(orig)} bytes)")
    if out != orig:
        for i, (a, b) in enumerate(zip(out, orig)):
            if a != b:
                print(f"  first diff at byte {i}: wrote {a:#04x} expected {b:#04x}")
                break
    for tag, t in w3o.sections.items():
        print(f"section {tag}: v{t.version}, {len(t.originals)} originals, "
              f"{len(t.customs)} customs")
        for o in t.customs:
            names = [m.value for s in o.sets for m in s.mods if m.id == "unam"]
            print(f"  {o.orig_id} -> {o.new_id}  ({names[0] if names else '?'})")
