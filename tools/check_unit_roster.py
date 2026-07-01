#!/usr/bin/env python3
"""Cross-checks unit="..." ids in bot.data.lua against the real RobZ roster
data per faction. Read-only report; never modifies bot.data.lua.
Run: python3 tools/check_unit_roster.py <gamelogic.pak> <bot.data.lua>"""
import re, sys, zipfile, argparse

FACTIONS = ["eng", "ger", "ger_ss", "ger2", "usa", "rus", "rus_guard", "jap"]

ID_PATTERNS = [
    re.compile(r'\bv1\(([A-Za-z0-9_\-.]+)\)'),     # vehicle breed reference
    re.compile(r'\{"([A-Za-z0-9_\-.]+)"\s*\('),    # roster button key (fallback)
]
# Squad name(...) ids are intentionally NOT scanned by directory here: RobZ
# multiplexes several factions' squads into one shared .set file, tagged
# side(<faction>) name(<id>), rather than segregating them per directory
# (e.g. ger_ss's squads live inside ger/squads_44.set). A directory-based
# name() scan would attribute every faction's squads sharing that file to
# whichever faction owns the directory, masking real MISMATCH bugs in that
# direction. scan_side_tagged_ids() below is the sole source of squad ids,
# keyed off the side() tag rather than the file's physical location.

def scan_faction_ids(pak_path, faction):
    """Return (ids, matched_filenames) for set/multiplayer/units/<faction>/*.set."""
    ids = set()
    prefix = "set/multiplayer/units/%s/" % faction
    with zipfile.ZipFile(pak_path) as z:
        names = [n for n in z.namelist() if n.startswith(prefix) and n.endswith(".set")]
        for n in names:
            text = z.read(n).decode("latin-1")
            for pat in ID_PATTERNS:
                ids.update(pat.findall(text))
    return ids, names

SIDE_NAME_RE = re.compile(r'side\((\w+)\)\s*name\(([A-Za-z0-9_\-.]+)\)')

def scan_side_tagged_ids(pak_path):
    """Return {faction: set(ids)} for squad entries tagged side(<faction>)
    name(<id>) anywhere under set/multiplayer/units/, regardless of which
    faction's directory the .set file physically lives in. RobZ multiplexes
    several factions' squads into one shared file (e.g. ger_ss's squads are
    tagged side(ger_ss) inside ger/squads_44.set, not in a ger_ss/ file)."""
    ids = {}
    prefix = "set/multiplayer/units/"
    with zipfile.ZipFile(pak_path) as z:
        names = [n for n in z.namelist() if n.startswith(prefix) and n.endswith(".set")]
        for n in names:
            text = z.read(n).decode("latin-1")
            for side, name in SIDE_NAME_RE.findall(text):
                ids.setdefault(side, set()).add(name)
    return ids

def build_roster_index(pak_path, factions):
    """Return ({faction: set(ids)}, {faction: [set-file names]})."""
    index, files = {}, {}
    for f in factions:
        ids, names = scan_faction_ids(pak_path, f)
        index[f] = ids
        files[f] = names
    side_tagged = scan_side_tagged_ids(pak_path)
    for f in factions:
        index[f] |= side_tagged.get(f, set())
    return index, files

FACTION_BLOCK_RE = re.compile(r'^\s*\["(\w+)"\]\s*=\s*\{\s*$')
UNIT_RE = re.compile(r'unit\s*=\s*"([^"]+)"')

def extract_bot_units(bot_data_path):
    """Return [(faction, id, lineno), ...] for every unit="..." entry inside a
    ["faction"] = { ... } block in bot.data.lua. A block opens on a line that
    ends in an unqualified "= {" (FACTION_BLOCK_RE) and closes when brace
    depth returns to zero. Single-line ["faction"] = { mid = ..., late = ... }
    entries (FactionPhases) never match FACTION_BLOCK_RE and are skipped."""
    out = []
    current = None
    depth = 0
    with open(bot_data_path) as fh:
        for lineno, line in enumerate(fh, start=1):
            if current is None:
                m = FACTION_BLOCK_RE.match(line)
                if m:
                    current = m.group(1)
                    depth = 1
                continue
            depth += line.count("{") - line.count("}")
            for um in UNIT_RE.finditer(line):
                out.append((current, um.group(1), lineno))
            if depth <= 0:
                current = None
    return out

def strip_suffix(unit_id):
    """Return the id with a trailing "(word)" annotation removed, or the id
    unchanged if it has none."""
    m = re.match(r'^(.+)\(\w+\)$', unit_id)
    return m.group(1) if m else unit_id

def check(roster_index, bot_units):
    """Return a list of problem dicts: {faction, id, line, kind, other?}."""
    problems = []
    for faction, unit_id, lineno in bot_units:
        bare = strip_suffix(unit_id)
        candidates = {unit_id, bare}
        if candidates & roster_index.get(faction, set()):
            continue
        found_in = [f for f, ids in roster_index.items()
                    if f != faction and candidates & ids]
        if found_in:
            problems.append({"faction": faction, "id": unit_id, "line": lineno,
                              "kind": "MISMATCH", "other": found_in[0]})
        else:
            problems.append({"faction": faction, "id": unit_id, "line": lineno,
                              "kind": "NOT_FOUND"})
    return problems

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("pak", help="path to RobZ gamelogic.pak")
    ap.add_argument("bot_data", help="path to bot.data.lua")
    a = ap.parse_args()

    roster_index, roster_files = build_roster_index(a.pak, FACTIONS)
    skip_factions = set()
    for f in FACTIONS:
        if not roster_files[f]:
            print("WARNING: no roster .set files found for faction %r -- skipping its cross-check" % f, file=sys.stderr)
            skip_factions.add(f)

    bot_units = [u for u in extract_bot_units(a.bot_data) if u[0] not in skip_factions]
    problems = check(roster_index, bot_units)

    if not problems:
        print("check_unit_roster: no problems found (%d units checked)" % len(bot_units))
        return

    for p in sorted(problems, key=lambda p: (p["faction"], p["line"])):
        if p["kind"] == "MISMATCH":
            print("%s line %d: %s -- MISMATCH (belongs to %s)"
                  % (p["faction"], p["line"], p["id"], p["other"]))
        else:
            print("%s line %d: %s -- NOT_FOUND"
                  % (p["faction"], p["line"], p["id"]))
    print("%d problem(s) found out of %d units checked" % (len(problems), len(bot_units)))
    sys.exit(1)

if __name__ == "__main__":
    main()
