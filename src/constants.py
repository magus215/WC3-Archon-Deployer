"""Phase 2d — merge the Archon dependency-equivalents into war3mapMisc.txt.

The gameplay-constants override is INI-like: `[SECTION]` then `key=value`. Dependency
equivalents use `DependencyOr=<comma-separated rawcodes>`. That key REPLACES the default list,
so adding a dummy means: append to the map's existing override if present, otherwise write the
full DEFAULT list + the dummy (writing just the dummy would un-classify every real unit).

This editor preserves all other sections/keys/order/case and only touches the four
`DependencyOr` lines we care about.
"""

from __future__ import annotations

# Default dependency-equivalent lists (base-game). HERO is confirmed = the 24 real heroes.
# ALTAR/tier section NAMES and defaults are best-guesses pending a reference war3mapMisc.txt
# that has all four set in-editor — see CONFIRM notes.
HERO_DEFAULTS = [
    "Hpal", "Hamg", "Hmkg", "Hblm", "Obla", "Ofar", "Otch", "Oshd",
    "Udea", "Ulic", "Udre", "Ucrl", "Ekee", "Emoo", "Edem", "Ewar",
    "Nalc", "Nngs", "Ntin", "Nbst", "Npbm", "Nbrn", "Nfir", "Nplh",
]
ALTAR_DEFAULTS = ["halt", "oalt", "uaod", "eate"]
TIER1_DEFAULTS = ["htow", "ogre", "unpl", "etol"]   # Town Hall / Great Hall / Necropolis / Tree of Life
TIER2_DEFAULTS = ["hkee", "ostr", "unp1", "etoa"]   # Keep / Stronghold / Halls of the Dead / Tree of Ages
TIER3_DEFAULTS = ["hcas", "ofrt", "unp2", "etoe"]   # Castle / Fortress / Black Citadel / Tree of Eternity

# (section, default list, dummy rawcode to ensure present)
# Section names CONFIRMED from the working AutumnLeaves map's war3mapMisc.txt.
CATEGORIES = [
    ("HERO", HERO_DEFAULTS,  "arx1"),
    ("TALT", ALTAR_DEFAULTS, "arx0"),
    # arx0 also counts as a tier-1 town hall so the support is never "crippled" (MeleePlayerIsCrippled
    # = structures>0 AND townhalls==0): it either has a town hall (arx0 present) or no buildings at
    # all -> no rebuild-or-lose reveal timer. Matches AutumnLeaves ([TWN1] has its dummy nvk2).
    ("TWN1", TIER1_DEFAULTS, "arx0"),
    ("TWN2", TIER2_DEFAULTS, "arx2"),
    ("TWN3", TIER3_DEFAULTS, "arx3"),
]
DEP_KEY = "DependencyOr"


class MiscFile:
    """Order/case-preserving INI editor for war3mapMisc.txt."""

    def __init__(self, text: str = ""):
        # store as a flat list of ("section", name) | ("kv", section, key, value) | ("raw", line)
        self.lines = []
        section = None
        for raw in text.replace("\r\n", "\n").replace("\r", "\n").split("\n"):
            s = raw.strip()
            if s.startswith("[") and s.endswith("]"):
                section = s[1:-1]
                self.lines.append(["section", section])
            elif "=" in s and not s.startswith(";"):
                k, _, v = s.partition("=")
                self.lines.append(["kv", section, k.strip(), v.strip()])
            elif s == "":
                pass  # drop blank lines; we re-emit cleanly
            else:
                self.lines.append(["raw", raw])

    def get(self, section, key):
        for e in self.lines:
            if e[0] == "kv" and e[1] == section and e[2] == key:
                return e[3]
        return None

    def set(self, section, key, value):
        for e in self.lines:
            if e[0] == "kv" and e[1] == section and e[2] == key:
                e[3] = value
                return
        # find the section; append the kv right after its header (or create the section)
        for i, e in enumerate(self.lines):
            if e[0] == "section" and e[1] == section:
                self.lines.insert(i + 1, ["kv", section, key, value])
                return
        self.lines.append(["section", section])
        self.lines.append(["kv", section, key, value])

    def serialize(self) -> str:
        out = []
        for e in self.lines:
            if e[0] == "section":
                out.append("[%s]" % e[1])
            elif e[0] == "kv":
                out.append("%s=%s" % (e[2], e[3]))
            else:
                out.append(e[1])
        return "\n".join(out) + "\n"


def merge_dependency_equivalents(misc_text: str = "") -> str:
    """Return war3mapMisc.txt text with the Archon dummies ensured in each DependencyOr list, and
    ally resource trading disabled."""
    misc = MiscFile(misc_text)
    for section, defaults, dummy in CATEGORIES:
        existing = misc.get(section, DEP_KEY)
        base = [x for x in existing.split(",") if x] if existing is not None else list(defaults)
        if dummy not in base:
            base.append(dummy)
        misc.set(section, DEP_KEY, ",".join(base))
    # QoL: disable ally resource trading by zeroing the trade-amount increments — players can never
    # raise the amount above 0, so trading is effectively off (keeps the shared-economy equalizer
    # from being poked, without "punishing" a curious player). Gameplay constants live in [Misc].
    # NOTE: keys are "TradingIncLarge"/"TradingIncSmall" (Inc, NOT Incl) — confirmed by diffing a
    # blueprint map saved from the editor. The misspelled "Incl*" keys are silently ignored.
    misc.set("Misc", "TradingIncLarge", "0")
    misc.set("Misc", "TradingIncSmall", "0")
    return misc.serialize()


if __name__ == "__main__":
    print("=== from scratch (no existing war3mapMisc.txt) ===")
    print(merge_dependency_equivalents(""))
    print("=== onto an existing [HERO] override (append, keep others) ===")
    sample = "[HERO]\nDependencyOr=Hpal,Hamg,H000\n[SomethingElse]\nFoo=Bar\n"
    print(merge_dependency_equivalents(sample))
