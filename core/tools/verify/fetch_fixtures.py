"""Download the reference data the verification suite needs, once, into
tools/verify/fixtures/ so the suite itself runs offline.

    tools/verify/.venv/Scripts/python tools/verify/fetch_fixtures.py

- JPL Horizons (https://ssd.jpl.nasa.gov/horizons/), API documented at
  https://ssd-api.jpl.nasa.gov/doc/horizons.html: state vectors of Io, Europa,
  Ganymede and Callisto relative to Jupiter's centre (500@599), ICRF axes
  (REF_PLANE=FRAME), km and km/s; and each body's physical-data header (GM).
- JPL SSD "Planetary Satellite Mean Elements" (https://ssd.jpl.nasa.gov/sats/elem/),
  the JUP365 table the game's moon elements are copied from.

Everything is stored raw (the API's JSON text) next to a parsed copy, so a
reader can check the parse against the original.
"""
import json
import pathlib
import re
import sys
import time

import requests

HERE = pathlib.Path(__file__).resolve().parent
FIX = HERE / "fixtures"
API = "https://ssd.jpl.nasa.gov/api/horizons.api"
MOONS = {"io": "501", "europa": "502", "ganymede": "503", "callisto": "504", "jupiter": "599"}


def horizons(params):
    base = {"format": "json", "MAKE_EPHEM": "YES", "OBJ_DATA": "YES"}
    base.update(params)
    q = {k: (v if k == "format" else f"'{v}'") for k, v in base.items()}
    for attempt in range(4):
        r = requests.get(API, params=q, timeout=120)
        if r.ok:
            return r.json()
        time.sleep(3 * (attempt + 1))
    r.raise_for_status()


def vectors(cmd, start, stop, step):
    j = horizons({"COMMAND": cmd, "EPHEM_TYPE": "VECTORS", "CENTER": "500@599", "START_TIME": start,
                  "STOP_TIME": stop, "STEP_SIZE": step, "REF_PLANE": "FRAME", "REF_SYSTEM": "ICRF",
                  "OUT_UNITS": "KM-S", "VEC_TABLE": "2", "CSV_FORMAT": "YES", "TIME_TYPE": "TDB",
                  "VEC_LABELS": "NO"})
    text = j["result"]
    body = text.split("$$SOE")[1].split("$$EOE")[0]
    rows = []
    for line in body.strip().splitlines():
        f = [x.strip() for x in line.split(",")]
        rows.append({"jd_tdb": float(f[0]), "r": [float(f[2]), float(f[3]), float(f[4])], "v": [float(f[5]), float(f[6]), float(f[7])]})
    gm = re.search(r"GM[^=\n]*\(km\^3/s\^2\)\s*=\s*([0-9.]+)", text) or re.search(r"GM,? km\^3/s\^2\s*=\s*([0-9.]+)", text)
    return text, rows, (float(gm.group(1)) if gm else None)


def main():
    FIX.mkdir(exist_ok=True)
    out = {"source": "JPL Horizons API, " + API, "fetched": time.strftime("%Y-%m-%d"), "center": "500@599", "frame": "ICRF", "units": "km, km/s",
           "time_scale": "TDB", "sets": {}, "gm": {}}
    raw = {}
    # J2000 (the elements' epoch) and the game's start, 2041-10-12 16:10 UTC (16:11:09 TDB), then
    # a 20-day window (the campaign's length) at 2 h steps, and 2039-2043 at 1 d
    # steps to measure mean motions.
    windows = {
        "j2000": ("2000-01-01 12:00", "2000-01-01 13:00", "1 h"),
        "campaign": ("2041-10-12 16:11:09", "2041-11-01 16:11:09", "2 h"),
        "decade": ("2036-03-14", "2046-03-14", "1 d"),
    }
    for name, cmd in MOONS.items():
        if name == "jupiter":
            continue
        for w, (a, b, s) in windows.items():
            text, rows, gm = vectors(cmd, a, b, s)
            out["sets"].setdefault(w, {})[name] = rows
            raw[f"{name}_{w}"] = text if w != "decade" else text.split("$$SOE")[0]
            if gm:
                out["gm"][name] = gm
            print(name, w, len(rows), "rows", "GM", gm, file=sys.stderr)
    # Jupiter's own header (GM, radius, J2 where listed).
    j = horizons({"COMMAND": "599", "EPHEM_TYPE": "VECTORS", "CENTER": "500@10", "START_TIME": "2041-10-12", "STOP_TIME": "2041-10-13", "STEP_SIZE": "1 d"})
    raw["jupiter_header"] = j["result"].split("$$SOE")[0]
    m = re.search(r"GM[^=\n]*\(km\^3/s\^2\)\s*=\s*([0-9.]+)", j["result"]) or re.search(r"GM,? km\^3/s\^2\s*=\s*([0-9.]+)", j["result"])
    if m:
        out["gm"]["jupiter"] = float(m.group(1))
    (FIX / "horizons_moons.json").write_text(json.dumps(out))
    (FIX / "horizons_raw.json").write_text(json.dumps(raw, indent=0))

    # The Sun (10) and Earth (399) seen from Jupiter's centre, for the game's
    # approximate ephemeris (godot/core/ephem.gd): the campaign window at 1 d
    # steps, and 2030-2050 at 60 d steps for the long run.
    se = {"source": "JPL Horizons API, " + API, "fetched": time.strftime("%Y-%m-%d"), "center": "500@599", "frame": "ICRF", "units": "km",
          "time_scale": "TDB", "sets": {}}
    for name, cmd in {"sun": "10", "earth": "399"}.items():
        for w, (a, b, s) in {"campaign": ("2041-10-12 16:11:09", "2041-11-01 16:11:09", "1 d"), "span": ("2030-01-01", "2050-01-01", "60 d")}.items():
            _, rows, _ = vectors(cmd, a, b, s)
            se["sets"].setdefault(w, {})[name] = [{"jd_tdb": r["jd_tdb"], "r": r["r"]} for r in rows]
            print(name, w, len(rows), "rows", file=sys.stderr)
    (FIX / "horizons_sun_earth.json").write_text(json.dumps(se))

    # JPL mean elements table (JUP365), the four Galilean rows.
    page = requests.get("https://ssd.jpl.nasa.gov/sats/elem/sep.html", timeout=60).text
    txt = re.sub(r"\s+", " ", re.sub("<[^>]+>", " ", page)).replace("&nbsp;", " ")
    elems = {}
    for name, code in [("io", 501), ("europa", 502), ("ganymede", 503), ("callisto", 504)]:
        m = re.search(name.capitalize() + r" " + str(code) + r" ((?:[-0-9.]+ ){12})", txt)
        f = [float(x) for x in m.group(1).split()]
        elems[name] = dict(zip(["a", "e", "w", "M", "i", "node", "P_days", "P_apsis_yr", "P_node_yr", "ra", "dec", "tilt"], f))
    (FIX / "jpl_sat_elem.json").write_text(json.dumps({"source": "https://ssd.jpl.nasa.gov/sats/elem/sep.html (JUP365, epoch 2000-01-01.5 TDB, local Laplace planes)",
                                                     "fetched": time.strftime("%Y-%m-%d"), "elements": elems}, indent=1))
    print("wrote", FIX, file=sys.stderr)


if __name__ == "__main__":
    main()
