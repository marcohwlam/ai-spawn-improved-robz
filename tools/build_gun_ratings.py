"""Generate gun_ratings.lua: unit_id -> AP peak penetration (mm) from RobZ paks.

Rating = max over a unit's weapons of the weapon's default-AP curve peak band a().
AP only; APCR/HEAT/FG ignored. Run from repo root: python tools/build_gun_ratings.py
"""
import os
import re
import sys
import zipfile

# top-level default-AP curve: first ("damage_NNN" a(NN) ...) not inside a {parameters ..} block.
_AP_A = re.compile(r'\("damage_\d+"\s+a\((\d+)\)')
_FROM = re.compile(r'\{from\s+"([^"]+)"')
_WEAPON = re.compile(r'\{weapon\s+"([^"]+)"')

def _strip_param_blocks(text: str) -> str:
    """Remove {parameters "apcr"/"heat"/... ( ... )} blocks so their a() is not matched."""
    out, depth, i, keep = [], 0, 0, True
    # simple brace-scan: drop any {parameters ...} span
    tokens = re.split(r'(\{parameters\b|\{|\})', text)
    skip_depth = None
    depth = 0
    for tok in tokens:
        if tok == '{parameters':
            if skip_depth is None:
                skip_depth = depth
            depth += 1
            continue
        if tok == '{':
            depth += 1
        elif tok == '}':
            depth -= 1
            if skip_depth is not None and depth == skip_depth:
                skip_depth = None
                continue
        if skip_depth is None:
            out.append(tok)
    return ''.join(out)

def resolve_ap_peak(name, gun_files, _seen=None):
    _seen = _seen or set()
    if name in _seen:
        return None
    _seen.add(name)
    text = gun_files.get(name)
    if text is None:
        # RobZ .def weapon references don't always match the gun .set filename
        # verbatim: (a) some units reference a plain name but only a veteran-
        # suffixed file exists on disk (e.g. "85mm_d5t" -> "85mm_d5t_vet"), and
        # (b) some weapon tokens differ in case from the filename on disk
        # (e.g. "75mm_kwk40(L48)" -> file "75mm_kwk40(l48)"). Try both.
        for candidate in (name.lower(), name + "_vet", (name + "_vet").lower()):
            if candidate not in _seen and candidate in gun_files:
                return resolve_ap_peak(candidate, gun_files, _seen)
        return None
    m = _AP_A.search(_strip_param_blocks(text))
    if m:
        return int(m.group(1))
    fm = _FROM.search(text)
    if fm:
        return resolve_ap_peak(fm.group(1), gun_files, _seen)
    return None

def gun_rating_for_weapons(weapons, gun_files):
    best = 0
    for w in weapons:
        v = resolve_ap_peak(w, gun_files)
        if v and v > best:
            best = v
    return best

def _read_gun_files(gamelogic_path):
    out = {}
    with zipfile.ZipFile(gamelogic_path) as z:
        for n in z.namelist():
            if "set/stuff/gun/" in n and not n.endswith("/"):
                out[os.path.basename(n)] = z.read(n).decode("latin-1", "replace")
    return out

_UNIT_LINE = re.compile(r'\{"([A-Za-z0-9_]+)"\s+\("v[A-Za-z0-9_]*"')
_V1_BREED = re.compile(r'v1\(([A-Za-z0-9_]+)\)')

def _read_unit_ids(gamelogic_path):
    """unit_id -> breed id to resolve weapons/rating from.

    Unit type token starts with "v" (not always exactly "v" -- RobZ uses
    "v_ss", "v_seq", "v_rus_g", etc. for faction/campaign variants). A unit
    that carries v1(BREED) shares its weapons/def with BREED and has no
    .def of its own; otherwise the unit is its own breed.
    """
    ids = {}
    with zipfile.ZipFile(gamelogic_path) as z:
        for n in z.namelist():
            if "set/multiplayer/units/" in n and n.endswith(".set"):
                text = z.read(n).decode("latin-1", "replace")
                for line in text.splitlines():
                    m = _UNIT_LINE.search(line)
                    if not m:
                        continue
                    uid = m.group(1)
                    vm = _V1_BREED.search(line)
                    ids[uid] = vm.group(1) if vm else uid
    return ids

def _read_defs(entity_path):
    """basename(without .def) -> list of weapon names."""
    out = {}
    with zipfile.ZipFile(entity_path) as z:
        for n in z.namelist():
            if "/-vehicle/" in n and n.endswith(".def"):
                base = os.path.basename(n)[:-4]
                text = z.read(n).decode("latin-1", "replace")
                out[base] = _WEAPON.findall(text)
    return out

def build_ratings(gamelogic_path, entity_path):
    gun_files = _read_gun_files(gamelogic_path)
    defs = _read_defs(entity_path)
    ratings = {}
    for uid, breed in _read_unit_ids(gamelogic_path).items():
        weapons = defs.get(breed)  # guarded: missing breed .def -> None -> skip
        if not weapons:
            continue
        r = gun_rating_for_weapons(weapons, gun_files)
        if r > 0:
            ratings[uid] = r
    return ratings

_VALID_LUA_IDENT = re.compile(r'^[A-Za-z_][A-Za-z0-9_]*$')

def _lua_key(uid):
    # Most unit ids are valid bare Lua identifiers ("sdkfz222"). A handful of
    # RobZ unit ids are purely numeric (e.g. "22", an axis_minor mortar) and
    # are not valid as a bare "key = value" table field -- quote those.
    if _VALID_LUA_IDENT.match(uid):
        return uid + ' ='
    return '["%s"] =' % uid

def _emit_lua(ratings):
    lines = ["-- GENERATED by tools/build_gun_ratings.py against RobZ 1.30.10.",
             "-- unit_id -> AP peak penetration (mm). Do not edit by hand.",
             "return {"]
    for uid in sorted(ratings):
        lines.append('    %s %d,' % (_lua_key(uid), ratings[uid]))
    lines.append("}")
    return "\n".join(lines) + "\n"

def main():
    robz = os.environ.get("ROBZ_RESOURCE",
        "/mnt/storage/steam/steamapps/common/Men of War Assault Squad 2/"
        "mods/robz realism mod 1.30.10/resource")
    gl = os.path.join(robz, "gamelogic.pak")
    en = os.path.join(robz, "entity.pak")
    ratings = build_ratings(gl, en)
    here = os.path.dirname(os.path.abspath(__file__))
    out = os.path.join(here, "..", "resource", "script", "multiplayer", "gun_ratings.lua")
    with open(out, "w") as f:
        f.write(_emit_lua(ratings))
    print("wrote %d ratings to %s" % (len(ratings), os.path.normpath(out)))

if __name__ == "__main__":
    main()
