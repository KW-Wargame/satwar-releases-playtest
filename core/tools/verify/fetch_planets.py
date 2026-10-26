"""Download JPL Horizons vectors of the Sun and the planets seen from Jupiter's
centre, for the game's solar-system ephemeris (godot/core/ephem.gd), into
fixtures/horizons_planets.json. Run once; the suite then runs offline.

    tools/verify/.venv/Scripts/python tools/verify/fetch_planets.py

Bodies are the system barycentres Standish & Williams' elements describe
(1 Mercury, 2 Venus, 3 Earth-Moon, 4 Mars, 6 Saturn, 7 Uranus, 8 Neptune) and
the Sun (10). Two windows: 2030-2050 at 73 d (Table 1's years) and 2060-2199 at
199 d (Table 2a/2b; Horizons has no Jupiter-centred data past 2200), TDB, ICRF, km.
"""
import json
import sys
import time

from fetch_fixtures import API, FIX, vectors

BODIES = {"sun": "10", "mercury": "1", "venus": "2", "earth": "3", "mars": "4", "saturn": "6", "uranus": "7", "neptune": "8"}
WINDOWS = {"t1": ("2030-01-01", "2050-01-01", "73 d"), "t2": ("2060-01-01", "2199-12-01", "199 d")}


def main():
    out = {"source": "JPL Horizons API, " + API, "fetched": time.strftime("%Y-%m-%d"), "center": "500@599", "frame": "ICRF",
           "units": "km, km/s", "time_scale": "TDB", "bodies": BODIES, "sets": {}}
    for w, (a, b, s) in WINDOWS.items():
        for name, cmd in BODIES.items():
            _, rows, _ = vectors(cmd, a, b, s)
            out["sets"].setdefault(w, {})[name] = [{"jd_tdb": r["jd_tdb"], "r": r["r"], "v": r["v"]} for r in rows]
            print(name, w, len(rows), "rows", file=sys.stderr)
    (FIX / "horizons_planets.json").write_text(json.dumps(out))
    print("wrote", FIX / "horizons_planets.json", file=sys.stderr)


if __name__ == "__main__":
    main()
