"""The Galilean moons the game flies against, compared with JPL Horizons
(ephemeris JUP365) in Jupiter's equatorial frame.

The game's moons are planar Kepler ellipses from JPL's mean elements, with the
mean longitude advancing at the observed sidereal rate and the mean anomaly at
JPL's tabulated rate (Kepler's third law alone would put Io 114 deg off by
2041). That is a deliberate simplification: no inclinations, no mutual
perturbations or resonance librations. These tests bound its error.
"""
import math

import numpy as np

from conftest import jupiter_equator_frame, wrap

MODEL = "moons"
JD_J2000 = 2451545.0


def _frame(published, jd):
    p = published["jupiter"]["pole_iau2015"]
    T = (jd - JD_J2000) / 36525.0
    return jupiter_equator_frame(p["ra0_deg"] + p["ra_rate_deg_per_century"] * T, p["dec0_deg"] + p["dec_rate_deg_per_century"] * T)


def _pairs(game, horizons, published, set_name):
    """(game state, Horizons state in Jupiter's equator frame) at the same TDB instants."""
    out = {}
    for mid, rows in game["moons"].items():
        by_jd = {round(r["jd_tdb"], 6): r for r in rows}
        pairs = []
        for h in horizons["sets"][set_name][mid]:
            g = by_jd.get(round(h["jd_tdb"], 6))
            if g is None:
                continue
            F = _frame(published, h["jd_tdb"])
            pairs.append((h["jd_tdb"], np.array(g["out"]["r"]), np.array(g["out"]["v"]), F @ np.array(h["r"]), F @ np.array(h["v"])))
        out[mid] = pairs
    return out


# Bounds per moon over the campaign window (2041-10-12 + 20 days), planar position (km) and
# longitude (deg). The game ignores inclination (|z| up to ~10,000 km for Callisto) and the
# moons' mutual perturbations; Callisto's residual is mostly its 0.007 eccentricity vector.
BOUNDS = {"io": (5000, 0.7), "europa": (5000, 0.5), "ganymede": (10000, 0.6), "callisto": (30000, 1.0)}


def test_campaign_window_vs_horizons(game, horizons, published, check):
    for mid, pairs in _pairs(game, horizons, published, "campaign").items():
        assert len(pairs) > 200, mid
        dpos = max(np.linalg.norm(g[:2] - h[:2]) for _, g, _, h, _ in pairs)
        dlon = max(abs(math.degrees(wrap(math.atan2(g[1], g[0]) - math.atan2(h[1], h[0])))) for _, g, _, h, _ in pairs)
        drad = max(abs(np.linalg.norm(g[:2]) - np.linalg.norm(h[:2])) for _, g, _, h, _ in pairs)
        dz = max(abs(h[2]) for _, _, _, h, _ in pairs)
        dv = max(np.linalg.norm(gv[:2] - hv[:2]) / np.linalg.norm(hv) for _, _, gv, _, hv in pairs)
        bp, bl = BOUNDS[mid]
        ref = "JPL Horizons API (JUP365), 2041-10-12..11-01, 2 h steps"
        check.bound(f"{mid} planar position error", dpos, bp, ref, unit="km")
        check.bound(f"{mid} longitude error", dlon, bl, ref, unit="deg")
        check.bound(f"{mid} radius error", drad, bp, ref, unit="km")
        check.bound(f"{mid} out-of-plane distance ignored", dz, 12000, ref, unit="km", note="the game is planar")
        check.bound(f"{mid} velocity error", dv, 0.015, ref, note="relative, in the plane")


def test_long_term_vs_horizons(game, horizons, published, check):
    """2036-2046, every 30 days: the mean motions hold for a decade either side of the campaign."""
    for mid, pairs in _pairs(game, horizons, published, "decade").items():
        dlon = max(abs(math.degrees(wrap(math.atan2(g[1], g[0]) - math.atan2(h[1], h[0])))) for _, g, _, h, _ in pairs)
        check.bound(f"{mid} longitude error 2036-2046 ({len(pairs)} dates)", dlon, 2.0, "JPL Horizons API (JUP365), 1 d steps, sampled every 30 d", unit="deg")


def test_j2000_elements_epoch(game, horizons, published, check):
    for mid, pairs in _pairs(game, horizons, published, "j2000").items():
        _, g, _, h, _ = pairs[0]
        dlon = abs(math.degrees(wrap(math.atan2(g[1], g[0]) - math.atan2(h[1], h[0]))))
        check.bound(f"{mid} longitude at the elements' epoch J2000", dlon, 1.0, "JPL Horizons at 2000-01-01 12:00 TDB", unit="deg",
                    note="JPL's mean elements are rounded to 0.1 deg; true minus mean longitude is up to 2e")


def test_mean_motion(game, horizons, published, check):
    """The game's mean longitude rate against a least-squares fit to ten years of Horizons positions."""
    for m in game["constants"]["moons"]:
        rows = horizons["sets"]["decade"][m["id"]]
        t = np.array([r["jd_tdb"] - JD_J2000 for r in rows])
        lam = np.array([math.atan2(*(_frame(published, r["jd_tdb"]) @ np.array(r["r"]))[1::-1]) for r in rows])
        n0 = 2 * math.pi / m["observedPeriodDays"]
        L = np.unwrap(lam - n0 * t) + n0 * t
        fit = np.polyfit(t, L, 1)[0]
        check.rel(f"{m['id']} mean longitude rate", n0, fit, 2e-6 if m["id"] == "callisto" else 5e-7, "least-squares fit to JPL Horizons 2036-2046",
                  note=f"Kepler's third law would give {math.sqrt((game['constants']['mu'] + m['gm']) / m['a'] ** 3) * 86400 / fit:.7f} x the true rate")


def test_laplace_resonance(game, horizons, published, check):
    """Io, Europa and Ganymede are locked: lambda_I - 3 lambda_E + 2 lambda_G = 180 deg (Laplace; Peale 1976;
    Peale & Lee 2002, Science 298:593, arXiv:astro-ph/0210589)."""
    pairs = _pairs(game, horizons, published, "campaign")
    worst, worst_h = 0.0, 0.0
    for k in range(len(pairs["io"])):
        lg = [math.atan2(pairs[m][k][1][1], pairs[m][k][1][0]) for m in ("io", "europa", "ganymede")]
        lh = [math.atan2(pairs[m][k][3][1], pairs[m][k][3][0]) for m in ("io", "europa", "ganymede")]
        g = wrap(lg[0] - 3 * lg[1] + 2 * lg[2] - math.pi)
        h = wrap(lh[0] - 3 * lh[1] + 2 * lh[2] - math.pi)
        worst = max(worst, abs(math.degrees(wrap(g - h))))
        worst_h = max(worst_h, abs(math.degrees(h)))
    check.bound("Laplace angle, game minus Horizons", worst, 1.5, "Laplace resonance (Peale 1976, ARA&A 14:215; Peale & Lee 2002) as JPL Horizons has it", unit="deg",
                note=f"in true longitudes the angle swings up to {worst_h:.1f} deg from 180 (equations of centre); the game follows it")
