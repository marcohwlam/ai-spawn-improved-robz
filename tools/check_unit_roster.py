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
