# WC3 Archon Deployer

Convert an unmodified **Warcraft III** melee map into an **Archon mode** version — automatically.

## What is Archon mode?

A 4-player game played as **two teams of two**. In each pair:

- the **main** owns the units and economy;
- the **support** shares **full control** — they move units, build, cast, and buy/revive heroes at the tavern — but owns nothing themselves.

It plays just like a normal 1v1 (or 2v2) melee game, only with two minds sharing each side. This tool takes a stock melee `.w3x` and produces its Archon version, so you don't have to hand-edit maps. Both **JASS** and **Lua** script maps are supported — the deployer detects which automatically.

## Requirements

- **Windows** — the tool repacks maps with the bundled `MPQEditor.exe` (Windows-only).
- **Python 3.8+** to run from source. The GUI uses `tkinter`, which ships with Python; there are **no other dependencies** (no `pip install`).

## Usage

### GUI

Double-click **`run_gui.bat`** (or run `python gui.py` from a terminal).

Pick a vanilla melee `.w3x`, pick an output folder, set the options, click **Convert**. The result is saved as `<map-name>_archon.w3x` in your chosen folder.

### Command line

```
python src/deployer.py <vanilla.w3x> <output-folder> [options]
```

| Option | Default | Effect |
| --- | --- | --- |
| `--show-support-score` | off (hidden) | Keep support players on the post-game score screen. They're hidden by default because their only "score" comes from internal helper units. |
| `--keep-support-color` | off (match) | Supports keep their own lobby color. By default a support takes its main's color so team visuals (rally flags, etc.) line up. |
| `--pre-game-timer N` | `0` (off) | Freeze all units for `N` seconds at the start, with a countdown, so queue partners can chat-coordinate. |

## Playing a converted map

Host the converted `.w3x` as a normal custom game. The lobby shows **two teams of two**; each team picks a main and a support. The support shares control of the main's base — no extra setup needed.

## Map compatibility

**The base map must be a standard 1v1 or 2v2 melee map** — two teams, **up to 4 starting players**. Archon mode turns each side into a *main + support* pair and produces a two-team game, so anything with more players or more than two teams (**3v3, 4v4, FFA**) is out of scope: it will still *convert* and produce a file, but the result won't play correctly. (A 6-player 3v3 map, for example, converts without error but doesn't work in-game.) Stick to 2-player (1v1) and 4-player (2v2) melee maps.

- **Unmodified (vanilla) melee maps — fully supported.** That's the primary target.
- **Modified maps — it depends what they change.** The deployer is *additive* wherever possible: it
  appends its units to the map's object data and *merges* (never overwrites) the gameplay constants,
  so maps that simply add their own custom units/creeps usually work. We tested several
  **W3Champions** ladder maps that tweak unit data and they converted fine.

What can make a modified map incompatible:

- **Rawcode collision.** The tool adds units under these rawcodes: `arx0`–`arx3`, plus the
  `Ar`-prefixed set `ArH1`–`ArN8` (hero revive dummies) and `ArT1`–`ArT8` (tavern proxies). If a map
  already uses any of those exact codes they'll collide and the conversion won't work correctly. In
  short: if a map uses `ar`/`Ar`-prefixed rawcodes, be cautious.
- **A heavily rewritten script.** The deployer splices the *standard* melee `config` / `main` /
  melee-init structure (JASS or Lua). If a map's script has been substantially rewritten, the splice
  may not find its anchors — in which case the tool errors out during conversion rather than shipping
  a broken map.

## Troubleshooting

- **Double-clicking `run_gui.bat` flashes a window / says Python isn't found.** Install **Python 3.8+** from [python.org](https://www.python.org/downloads/) and, on the installer's first screen, tick **"Add Python to PATH"**. Then run it again. (The GUI needs nothing else — `tkinter` ships with Python.)
- **Conversion fails at the repack step, or `MPQEditor.exe` is missing/blocked.** If you got the repo as a **ZIP download**, Windows tags the bundled `MPQEditor.exe` as "from the internet" and Defender/SmartScreen may block it. Either **`git clone`** the repo instead of downloading the ZIP, or right-click **`tools\MPQEditor.exe` → Properties → Unblock**.
- **The tool errors out, or the converted map won't play.** It's almost always a compatibility issue — see [Map compatibility](#map-compatibility): the map is larger than 2v2 (3v3/4v4/FFA), uses an `ar`/`Ar` rawcode the tool also uses, or has a heavily rewritten script. The deployer errors out rather than shipping a broken map, so a failed conversion is the tool protecting you.

## Maps

A ready-made Archon **map pack** is on HiveWorkshop: _link to be added_.
This repository ships **only the deployer** — point it at any vanilla melee map and convert it yourself.

## Licensing

- **Deployer tooling** (`src/`, `gui.py`, `jass/`, `helpers/`) — **MIT**, see [`LICENSE`](LICENSE).
- **`MPQEditor.exe`** (bundled) © Ladislav Zezula — **GPL v2**, see [`LICENSE-MPQEditor.txt`](LICENSE-MPQEditor.txt). It's invoked only as a separate command-line program, so it doesn't place the GPL on this project's own code.
- **Warcraft III content** produced by the tool is governed by Blizzard's Custom Game Acceptable Use Policy.

Full breakdown in [`NOTICE`](NOTICE).

## Credits

- MPQ repacking via **[MPQEditor](http://www.zezula.net/)** by Ladislav Zezula.
- Archon Deployer by **magus215**.
