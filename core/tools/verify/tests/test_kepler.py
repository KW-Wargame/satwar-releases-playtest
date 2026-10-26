"""Two-body propagation (universal variables) against hapsira's Farnocchia
and Vallado propagators, scipy DOP853, and published worked examples."""
import math

import numpy as np
from hapsira.core.angles import E_to_nu, M_to_E
from hapsira.core.elements import coe2rv, rv2coe
from hapsira.core.propagation import farnocchia, vallado
from scipy.integrate import solve_ivp

MODEL = "kepler"


def _two_body(r0, v0, dt, mu):
    f = lambda t, y: np.concatenate([y[3:], -mu * y[:3] / np.linalg.norm(y[:3]) ** 3])
    s = solve_ivp(f, (0, dt), np.concatenate([r0, v0]), method="DOP853", rtol=1e-13, atol=1e-10)
    return s.y[:3, -1], s.y[3:, -1]


def test_propagate_vs_references(game, check):
    mu = game["constants"]["mu"]
    cases = game["kepler"]["propagate"]
    worst = {}
    for c in cases:
        r0, v0, dt = np.array(c["r0"]), np.array(c["v0"]), c["dt"]
        r, v = np.array(c["out"]["r"]), np.array(c["out"]["v"])
        refs = {}
        # hapsira converts to elements internally and is singular for planar retrograde
        # orbits (i = 180 deg); those cases are checked against DOP853 alone.
        if np.cross(r0, v0)[2] > 0 or abs(r0[2]) + abs(v0[2]) > 0:
            refs["hapsira farnocchia"] = farnocchia(mu, r0, v0, dt)
            f, g, fd, gd = vallado(mu, r0, v0, dt, 350)
            refs["hapsira vallado"] = (f * r0 + g * v0, fd * r0 + gd * v0)
        if abs(dt) <= 7 * 86400 or c["name"].startswith("retro"):
            refs["scipy DOP853"] = _two_body(r0, v0, dt, mu)
        for k, (rr, vv) in refs.items():
            er = np.linalg.norm(r - rr) / np.linalg.norm(rr)
            ev = np.linalg.norm(v - vv) / np.linalg.norm(vv)
            w = worst.setdefault(k, [0.0, 0.0, ""])
            if er > w[0]:
                w[0], w[2] = er, f"{c['name']} dt={dt:g}"
            w[1] = max(w[1], ev)
    for k, (er, ev, where) in worst.items():
        check.bound(f"position vs {k} (worst of {len(cases)})", er, 1e-8, k + (" 0.18" if "hapsira" in k else ", rtol 1e-13"),
                    note=f"relative |dr|/|r|; worst at {where}. Cases: circular, e 0.5-0.999, hyperbolic, 3-D, retrograde, every campaign ship")
        check.bound(f"velocity vs {k}", ev, 1e-8, k)


def test_conservation(game, check):
    mu = game["constants"]["mu"]
    we, wh = 0.0, 0.0
    for c in game["kepler"]["propagate"]:
        r0, v0 = np.array(c["r0"]), np.array(c["v0"])
        r, v = np.array(c["out"]["r"]), np.array(c["out"]["v"])
        e0 = v0 @ v0 / 2 - mu / np.linalg.norm(r0)
        e1 = v @ v / 2 - mu / np.linalg.norm(r)
        we = max(we, abs(e1 - e0) / abs(e0))
        wh = max(wh, np.linalg.norm(np.cross(r, v) - np.cross(r0, v0)) / np.linalg.norm(np.cross(r0, v0)))
        assert math.isclose(c["energy"], e0, rel_tol=1e-12)
        assert math.isclose(c["a"], -mu / (2 * e0), rel_tol=1e-9)
    check.bound("energy conserved (worst case)", we, 1e-9, "vis-viva")
    check.bound("angular momentum conserved (worst case)", wh, 1e-9, "Kepler's second law")


def test_period(game, check):
    mu = game["constants"]["mu"]
    for c in game["kepler"]["propagate"]:
        if c["period"] > 0 and c["dt"] == 60.0:
            p, ecc, inc, raan, argp, nu = rv2coe(mu, np.array(c["r0"]), np.array(c["v0"]))
            a = p / (1 - ecc ** 2)
            check.rel(f"period {c['name']}", c["period"], 2 * math.pi * math.sqrt(a ** 3 / mu), 1e-9, "hapsira rv2coe + Kepler III")


def test_worked_examples(game, check):
    for w in game["kepler"]["worked"]:
        c, out = w["in"], w["out"]
        tol = 0.6 * 10 ** (1 - c["digits"])  # about half a unit in the last printed digit, relative
        tag = c["source"].split("(")[0].strip() + " " + c["source"].split(",")[-1].strip().split(" ")[0] + " " + c["source"].split(",")[-1].strip().split(" ")[1]
        for k in ("r", "v"):
            err = np.linalg.norm(np.array(out[k]) - c["expect"][k]) / np.linalg.norm(c["expect"][k])
            check.bound(f"{tag} {k}", err, tol, c["source"], note="relative to the printed answer")


def test_from_elements_vs_hapsira(game, check):
    """Pure Kepler ellipses from mean elements (no measured periods): Kepler's equation and the geometry."""
    mu = game["constants"]["mu"]
    wr, wv = 0.0, 0.0
    for c in game["kepler"]["elements"]:
        el, t = c["el"], c["t"]
        a, e = el["a"], el["e"]
        n = math.sqrt(mu / a ** 3)
        M = (math.radians(el["M"]) + n * t + math.pi) % (2 * math.pi) - math.pi
        nu = E_to_nu(M_to_E(M, e), e) if e > 0 else M
        r, v = coe2rv(mu, a * (1 - e * e), e, 0.0, math.radians(el["node"]), math.radians(el["w"]), nu)
        wr = max(wr, np.linalg.norm(np.array(c["out"]["r"]) - r) / np.linalg.norm(r))
        wv = max(wv, np.linalg.norm(np.array(c["out"]["v"]) - v) / np.linalg.norm(v))
    check.bound("position from elements (e 0-0.99)", wr, 1e-10, "hapsira M_to_E, E_to_nu, coe2rv")
    check.bound("velocity from elements (e 0-0.99)", wv, 1e-10, "hapsira coe2rv")


def _series(z, k0):
    return sum((-z) ** k / math.factorial(2 * k + k0) for k in range(80))


def test_stumpff(game, check):
    for c in game["kepler"]["stumpff"]:
        check.rel(f"Stumpff C({c['z']:g})", c["C"], _series(c["z"], 2), 1e-9, "Maclaurin series, 80 terms (Curtis 2020 eq. 3.52)")
        check.rel(f"Stumpff S({c['z']:g})", c["S"], _series(c["z"], 3), 1e-9, "Maclaurin series, 80 terms (Curtis 2020 eq. 3.53)")
