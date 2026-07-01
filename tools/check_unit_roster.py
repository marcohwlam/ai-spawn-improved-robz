#!/usr/bin/env python3
"""Cross-checks unit="..." ids in bot.data.lua against the real RobZ roster
data per faction. Read-only report; never modifies bot.data.lua.
Run: python3 tools/check_unit_roster.py <gamelogic.pak> <bot.data.lua>"""
import re, sys, zipfile, argparse

FACTIONS = ["eng", "ger", "ger_ss", "ger2", "usa", "rus", "rus_guard", "jap"]

ID_PATTERNS = [
    re.compile(r'\bv1\(([A-Za-z0-9_\-.]+)\)'),     # vehicle breed reference
    re.compile(r'\bname\(([A-Za-z0-9_\-.]+)\)'),   # squad name id
    re.compile(r'\{"([A-Za-z0-9_\-.]+)"\s*\('),    # roster button key (fallback)
]

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

def build_roster_index(pak_path, factions):
    """Return ({faction: set(ids)}, {faction: [set-file names]})."""
    index, files = {}, {}
    for f in factions:
        ids, names = scan_faction_ids(pak_path, f)
        index[f] = ids
        files[f] = names
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
