#!/usr/bin/env python3
"""Offline unit-meta extractor for the CTF (battle_zones) bot.
Scrapes each RobZ unit's unlock time (trailing ;NNNNsec comment) and tonnage (t() tag),
then rewrites bot.data.lua: adds unlock=, adds weight= on UnitClass.Tank lines, strips
recharge=. Run by hand; output is committed. Never ships to the game."""
import re, zipfile, argparse

ROBZ_PAK = ("/mnt/storage/steam/steamapps/common/Men of War Assault Squad 2/"
            "mods/robz realism mod 1.30.10/resource/gamelogic.pak")

_UNIT_ID = re.compile(r'^\s*\{"([A-Za-z0-9_]+)"')
_UNLOCK = re.compile(r';\s*(\d+)\s*sec')
_TTAG = re.compile(r'\bt\(([^)]*)\)')
_WEIGHTS = ("sheavy", "heavy", "medium", "light")  # sheavy before heavy (substring)

def parse_units(text):
    """unit id -> {'unlock': int|None, 'weight': str|None} for each unit definition line."""
    out = {}
    for line in text.splitlines():
        mid = _UNIT_ID.match(line)
        if not mid:
            continue
        uid = mid.group(1)
        mu = _UNLOCK.search(line)
        unlock = int(mu.group(1)) if mu else None
        weight = None
        mt = _TTAG.search(line)
        if mt:
            tags = mt.group(1)
            for w in _WEIGHTS:
                if re.search(r'\b' + w + r'\b', tags):
                    weight = w
                    break
        out.setdefault(uid, {"unlock": unlock, "weight": weight})
    return out

def scrape_pak(pak_path):
    meta = {}
    with zipfile.ZipFile(pak_path) as z:
        for name in z.namelist():
            if name.startswith("set/multiplayer/units/") and name.endswith(".set"):
                text = z.read(name).decode("latin-1")
                for uid, val in parse_units(text).items():
                    meta.setdefault(uid, val)  # keep first
    return meta

_BD_ID = re.compile(r'unit="([A-Za-z0-9_]+)"')
_RECHARGE = re.compile(r'\s*recharge=(\d+),')
_UNLOCK_FIELD = re.compile(r'\s*unlock=\d+,')
_WEIGHT_FIELD = re.compile(r'\s*weight="[^"]*",')

def _inject_line(line, info):
    """Rewrite a single bot.data unit line. Returns (new_line, action) where action is
    'injected' | 'mismatch' | 'skip'. info is the meta entry for this line's id."""
    unlock = info.get("unlock")
    weight = info.get("weight")
    is_tank = "class=UnitClass.Tank," in line
    mr = _RECHARGE.search(line)
    if mr:
        expected = unlock if unlock is not None else 0
        if int(mr.group(1)) != expected:
            return line, "mismatch"
    # strip any prior recharge/unlock/weight tokens (idempotency)
    new = _RECHARGE.sub("", line)
    new = _UNLOCK_FIELD.sub("", new)
    new = _WEIGHT_FIELD.sub("", new)
    # insert fresh fields just before the closing '},'
    add = ""
    if unlock is not None:
        add += " unlock=%d," % unlock
    if is_tank and weight is not None:
        add += ' weight="%s",' % weight
    if add:
        new = re.sub(r'\},\s*$', add + "},", new, count=1)
    return new, "injected"

def inject(bot_data_text, meta):
    report = {"injected": [], "mismatch": [], "no_match": [], "tanks_no_weight": []}
    out_lines = []
    for line in bot_data_text.splitlines(keepends=True):
        mid = _BD_ID.search(line)
        if not mid:
            out_lines.append(line)
            continue
        uid = mid.group(1)
        if uid not in meta:
            report["no_match"].append(uid)
            out_lines.append(line)
            continue
        body = line.rstrip("\n")
        nl = "\n" if line.endswith("\n") else ""
        new_body, action = _inject_line(body, meta[uid])
        if action == "mismatch":
            mr = _RECHARGE.search(body)
            report["mismatch"].append((uid, int(mr.group(1)), meta[uid].get("unlock")))
            out_lines.append(line)
            continue
        report["injected"].append(uid)
        if "class=UnitClass.Tank," in body and meta[uid].get("weight") is None:
            report["tanks_no_weight"].append(uid)
        out_lines.append(new_body + nl)
    return "".join(out_lines), report

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--robz-pak", default=ROBZ_PAK)
    ap.add_argument("--bot-data", default="../resource/script/multiplayer/bot.data.lua")
    args = ap.parse_args()
    meta = scrape_pak(args.robz_pak)
    with open(args.bot_data, encoding="utf-8") as f:
        text = f.read()
    out, rep = inject(text, meta)
    with open(args.bot_data, "w", encoding="utf-8") as f:
        f.write(out)
    print("injected:", len(rep["injected"]))
    print("mismatch (recharge != unlock):", rep["mismatch"])
    print("no RobZ match:", sorted(set(rep["no_match"])))
    print("tanks with no weight:", sorted(set(rep["tanks_no_weight"])))

if __name__ == "__main__":
    main()
