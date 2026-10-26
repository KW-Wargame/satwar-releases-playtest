"""Where the Sun and Earth lie seen from Jupiter (godot/core/ephem.gd: JPL's
approximate planetary elements), against JPL Horizons vectors (DE441) rotated
into Jupiter's equatorial frame with the IAU 2015 pole coded here."""
import math

import numpy as np

MODEL = "ephem"


def to_game(v, jd_tdb):
    """ICRF -> Jupiter equator: z the IAU 2015 pole (Archinal et al. 2018, Table 2), x = z_ICRF x pole."""
    T = (jd_tdb - 2451545.0) / 36525.0
    ra = math.radians(268.056595 - 0.006499 * T)
    dec = math.radians(64.495303 + 0.002413 * T)
    z = np.array([math.cos(dec) * math.cos(ra), math.cos(dec) * math.sin(ra), math.sin(dec)])
    x = np.cross([0.0, 0.0, 1.0], z)
    x /= np.linalg.norm(x)
    y = np.cross(z, x)
    return np.array([x @ v, y @ v, z @ v])


def ang(a, b):
    return math.degrees(math.acos(max(-1.0, min(1.0, float(a @ b / (np.linalg.norm(a) * np.linalg.norm(b)))))))


def test_sun_and_earth_vs_horizons(game, sun_earth, check):
    hz = sun_earth["sets"]
    rows = {(w, round(r["jd_tdb"], 6)): {"sun": np.array(r["r"])} for w in hz for r in hz[w]["sun"]}
    for w in hz:
        for r in hz[w]["earth"]:
            rows[(w, round(r["jd_tdb"], 6))]["earth"] = np.array(r["r"])
    for w, label in [("campaign", "campaign window 2041-10-12..11-01"), ("span", "2030-2050")]:
        worst = {"sun": [0.0, 0.0, 0.0], "earth": [0.0, 0.0, 0.0]}
        for c in game["ephem"]:
            if c["in"]["set"] != w:
                continue
            ref = rows[(w, round(c["in"]["jd_tdb"], 6))]
            for body in ["sun", "earth"]:
                g = np.array(c[body])
                h = to_game(ref[body], c["in"]["jd_tdb"])
                worst[body][0] = max(worst[body][0], ang(g, h))
                worst[body][1] = max(worst[body][1], abs(np.linalg.norm(g) - np.linalg.norm(h)) / np.linalg.norm(h))
                # In-plane direction, the one the game uses (sim.sun_dir / earth_dir).
                worst[body][2] = max(worst[body][2], abs(math.degrees(math.remainder(math.atan2(g[1], g[0]) - math.atan2(h[1], h[0]), 2 * math.pi))))
        ref = f"JPL Horizons (DE441), Jupiter-centred, {label}"
        for body in ["sun", "earth"]:
            check.bound(f"{body} direction, {label}", worst[body][0], 0.2, ref, unit="deg",
                        note="Standish's Table 1 elements are good to a few hundred arcsec for Jupiter over 1800-2050")
            check.bound(f"{body} in-plane bearing, {label}", worst[body][2], 0.2, ref, unit="deg")
            check.bound(f"{body} distance, {label}", worst[body][1], 2e-3, ref)


# JPL's nominal errors of the approximate elements (https://ssd.jpl.nasa.gov/planets/approx_pos.html):
# heliocentric longitude and latitude (arcsec) and distance (1000 km), Table 1 (1800-2050) and Table 2 (3000 BC-3000 AD).
NOMINAL = {
    "t1": {"mercury": (15, 1, 1), "venus": (20, 1, 4), "earth": (20, 8, 6), "mars": (40, 2, 25), "jupiter": (400, 10, 600),
           "saturn": (600, 25, 1500), "uranus": (50, 2, 1000), "neptune": (10, 1, 200)},
    "t2": {"mercury": (20, 15, 1), "venus": (40, 30, 8), "earth": (40, 15, 15), "mars": (100, 40, 30), "jupiter": (600, 100, 1000),
           "saturn": (1000, 100, 4000), "uranus": (2000, 30, 8000), "neptune": (400, 15, 4000)},
}
A_AU = {"mercury": 0.387, "venus": 0.723, "earth": 1.0, "mars": 1.524, "jupiter": 5.203, "saturn": 9.537, "uranus": 19.19, "neptune": 30.07}
AS = math.pi / 180 / 3600
AU = 149597870.7


def nominal_km(w, body):
    if body == "sun":
        return 0.0
    lam, phi, rho = NOMINAL[w][body]
    a = A_AU[body] * AU
    return math.sqrt((lam * AS * a) ** 2 + (phi * AS * a) ** 2 + (rho * 1000.0) ** 2)


def test_planets_vs_horizons(game, check):
    """Every planet and the Sun from Jupiter (ephem.gd, both tables), and the
    gravity model's interpolated cache against the tables it interpolates."""
    import json
    from conftest import FIX
    hz = json.loads((FIX / "horizons_planets.json").read_text())
    rows = {}
    for w in hz["sets"]:
        for b, rs in hz["sets"][w].items():
            for r in rs:
                rows[(w, round(r["jd_tdb"], 6), b)] = np.array(r["r"])
    cases = game.get("planets", [])
    assert cases, "no planet cases: run make_cases.py after fetch_planets.py"
    for w, label in [("t1", "Table 1, 2030-2050"), ("t2", "Tables 2a+2b, 2060-2199")]:
        worst = {}
        interp = 0.0
        for c in cases:
            if c["in"]["set"] != w:
                continue
            for b, g in c["exact"].items():
                h = to_game(rows[(w, round(c["in"]["jd_tdb"], 6), b)], c["in"]["jd_tdb"])
                e = float(np.linalg.norm(np.array(g) - h))
                worst[b] = max(worst.get(b, 0.0), e)
                interp = max(interp, float(np.linalg.norm(np.array(c["interp"][b]) - np.array(g))))
        ref = f"JPL Horizons (DE441), Jupiter-centred, {label}"
        for b, e in worst.items():
            bound = 1.5 * (nominal_km(w, b) + nominal_km(w, "jupiter"))
            check.bound(f"{b} position, {label}", e, bound, ref, unit="km",
                        note="bound: 1.5x JPL's nominal errors of the body and of Jupiter, added")
        check.bound(f"interpolated cache vs tables, {label}", interp, 2.0, "ephem.gd's own tables", unit="km",
                    note="cubic Hermite at 6 h nodes")
