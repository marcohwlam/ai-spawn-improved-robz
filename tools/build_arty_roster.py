#!/usr/bin/env python3
"""Offline artillery-roster generator. Merges the validated artillery roster with
the existing artillery rows in bot.data.lua, drops ids not present in each nation's
RobZ mp-set, classifies each by its engine t() tag, and rewrites the per-nation
artillery span in bot.data.lua. Run by hand; the output is committed. Never ships
to the game."""
import re, zipfile, argparse, sys, os

ROBZ_PAK = ("/mnt/storage/steam/steamapps/common/Men of War Assault Squad 2/"
            "mods/robz realism mod 1.30.10/resource/gamelogic.pak")

# nation -> [(unit, min_income, unlock)]
ROSTER = {
    "ger":       [("wespe",2.0,900),("hummel",2.0,1200),("sdkfz4",2.0,1200),("np_sdkfz251_1w",2.5,1200)],
    "ger2":      [("wespe_ger2",2.0,900),("sdkfz138_1",2.0,900),("sdkfz251_1_stuka",2.5,1200)],
    "ger_ss":    [("wespe_ss",2.0,900),("hummel_ss",2.0,1200),("sdkfz4_ss",2.0,1200),("np_sdkfz251_1w_ss",2.5,1200)],
    "eng":       [("m7_eng",2.0,900)],
    "usa":       [("m7",2.0,900),("m12gmc",2.5,1200),("m4a3c",2.0,1200),("np_t19",2.0,900)],
    "rus":       [("su122",2.0,1120),("su152",2.0,1120),("isu152",2.0,1120),("bm13",2.0,1200),
                  ("bm_8_24",2.0,900),("bm8-48",2.0,900),("np_bm31",2.5,1200),("280br5",2.5,1200)],
    "rus_guard": [("203b4_guard",2.5,1200),("bm13_guard",2.0,1200),("bm_8_24_guard",2.0,1200),
                  ("bm8-48_guard",2.0,900),("isu152_guard",2.0,1120),("np_bm31_guard",2.5,1200),
                  ("su122_guard",2.0,1120)],
    "jap":       [("ha-to",2.0,1200),("ho-ni2",2.0,900),("ho-ro",2.0,1200)],
}

_PRIORITY = {"rocket": 0.3, "heavy": 0.5, "field": 0.8}

# Rocket platforms whose RobZ t() tag omits the "rocket" token (data gap); force rocket.
_ROCKET_OVERRIDE = {"sdkfz251_1_stuka"}

def subtype_of(tag, unit=None):
    """Map a RobZ t() tag string to an arty subtype."""
    if unit in _ROCKET_OVERRIDE: return "rocket"
    if "rocket" in tag: return "rocket"
    if "heavyart" in tag or "heavy" in tag: return "heavy"
    return "field"

def priority_of(subtype):
    return _PRIORITY[subtype]

def render_row(unit, subtype, min_income, unlock):
    """One bot.data.lua artillery row (4 tabs of indent, matching the nation tables)."""
    return ('\t\t\t\t{priority=%s, class=UnitClass.ArtilleryTank, unit="%s", '
            'min_income=%s, min_team=1, unlock=%d, arty="%s",},'
            % (priority_of(subtype), unit, min_income, unlock, subtype))

# --- RobZ mp-set scraping (tag classification + id validation) ---
_RX_Q = re.compile(r'\{"([^"]+)"')
_RX_N = re.compile(r'\bname\(([^)]+)\)')

def nation_mpset(z, nation):
    """Return {unit_id: tag_string} for one nation's mp unit sets."""
    out = {}
    for n in z.namelist():
        if n.startswith("set/multiplayer/units/%s/" % nation) and n.endswith(".set"):
            d = z.read(n).decode("latin-1")
            for uid in set(_RX_Q.findall(d)) | set(s.strip() for s in _RX_N.findall(d)):
                i = d.find('"%s"' % uid)
                if i < 0: i = d.find("name(%s)" % uid)
                mt = re.search(r't\(([^)]*)\)', d[i:i+400]) if i >= 0 else None
                out[uid] = mt.group(1) if mt else ""
    return out

def merge_nation(nation, existing_ids, mpset):
    """Return rendered rows for one nation. Union of reference + existing ids, deduped,
    filtered to ids present in mpset, classified by tag. mpset maps id -> tag string."""
    ref = {u: (mi, ul) for (u, mi, ul) in ROSTER.get(nation, [])}
    order = [u for (u, _, _) in ROSTER.get(nation, [])]
    for u in existing_ids:
        if u not in ref:
            order.append(u)
    rows, seen = [], set()
    for u in order:
        if u in seen: continue
        seen.add(u)
        if u not in mpset:
            print("DROP %s/%s: not in mp-set" % (nation, u), file=sys.stderr)
            continue
        sub = subtype_of(mpset[u], u)
        mi, ul = ref.get(u, (2.0, 900))
        rows.append(render_row(u, sub, mi, ul))
    return rows

# --- bot.data.lua rewrite ---
def existing_arty_ids(text, nation):
    """Unit ids on the ArtilleryTank rows inside one nation block."""
    block = _nation_block(text, nation)
    return re.findall(r'class=UnitClass\.ArtilleryTank, unit="([^"]+)"', block)

def _nation_block_span(text, nation):
    """Return (start, end) char offsets of one nation table body, or raise. End is the
    next nation header (so the span is scoped to this nation only)."""
    key = '["%s"] = {' % nation
    s = text.find(key)
    if s < 0: raise SystemExit("nation %s not found" % nation)
    nxt = re.search(r'\n\s*\["[a-z0-9_]+"\] = \{', text[s + len(key):])
    e = (s + len(key) + nxt.start()) if nxt else len(text)
    return s, e

def _nation_block(text, nation):
    s, e = _nation_block_span(text, nation)
    return text[s:e]

def rewrite_nation_block(text, nation, rows):
    """Replace the contiguous run of ArtilleryTank lines in one nation block with rows.
    Existing artillery rows are contiguous per nation (verified); replace that slice in place."""
    lines = text.split("\n")
    key = '["%s"] = {' % nation
    start = next((i for i, ln in enumerate(lines) if key in ln), None)
    if start is None: raise SystemExit("nation %s not found" % nation)
    arty = [i for i in range(start, len(lines))
            if "class=UnitClass.ArtilleryTank" in lines[i]]
    # stop collecting at the next nation header (contiguity guard within this block)
    nxt = next((i for i in range(start + 1, len(lines))
                if re.match(r'\s*\["[a-z0-9_]+"\] = \{', lines[i])), len(lines))
    arty = [i for i in arty if i < nxt]
    if not arty:
        raise SystemExit("no ArtilleryTank rows in nation %s" % nation)
    first, last = arty[0], arty[-1]
    if last - first + 1 != len(arty):
        raise SystemExit("ArtilleryTank rows not contiguous in %s" % nation)
    return "\n".join(lines[:first] + rows + lines[last + 1:])

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--robz-pak", default=ROBZ_PAK)
    ap.add_argument("--bot-data", default="../resource/script/multiplayer/bot.data.lua")
    ap.add_argument("--check", action="store_true", help="validate only; do not write")
    a = ap.parse_args()
    z = zipfile.ZipFile(a.robz_pak)
    text = open(a.bot_data, encoding="latin-1").read()
    total = 0
    for nation in ROSTER:
        mpset = nation_mpset(z, nation)
        existing = existing_arty_ids(text, nation)
        rows = merge_nation(nation, existing, mpset)
        total += len(rows)
        if not a.check:
            text = rewrite_nation_block(text, nation, rows)
    if a.check:
        print("validated", total, "rows across", len(ROSTER), "nations")
        return
    open(a.bot_data, "w", encoding="latin-1").write(text)
    print("wrote", a.bot_data, "rows:", total)

if __name__ == "__main__":
    main()
