"""Jupiter's shadow and the skin's heat capacity (godot/core/thermal.gd).

- Sunlight share: the game traces ~400 rays across a limb-darkened solar disc
  past an oblate Jupiter. The reference integrates the same disc on a fine
  polar grid (400 x 720) with numpy, ray by ray against the same ellipsoid, and
  the umbra and penumbra edges are checked against the cone geometry of a
  sphere: umbra while the angular separation s + rho_sun < rho_body, clear once
  s > rho_sun + rho_body (Montenbruck & Gill 2000, §3.4.2).
- Skin: C dT/dt = leak + alpha S f A/4 - eps sigma A T^4, solved by scipy's
  solve_ivp (RK45, rtol 1e-9) against the game's linearised implicit steps.
"""
import math

import numpy as np
from scipy.integrate import solve_ivp

MODEL = "thermal"
SIGMA = 5.670374419e-8


def reference_share(r, sun, re, rp, R_sun, u, nq=400, nphi=720):
    r = np.array(r, float)
    sv = np.array(sun, float) - r
    ds = np.linalg.norm(sv)
    sh = sv / ds
    rho = math.asin(R_sun / ds)
    a = np.cross(sh, [0.0, 0.0, 1.0])
    a /= np.linalg.norm(a)
    b = np.cross(sh, a)
    q = (np.arange(nq) + 0.5) / nq
    ph = (np.arange(nphi) + 0.5) / nphi * 2 * math.pi
    Q, P = np.meshgrid(q, ph, indexing="ij")
    mu = np.sqrt(1 - Q ** 2)
    wgt = Q * (1 - u * (1 - mu))  # area element q dq dphi times limb darkening
    tr = math.tan(rho)
    d = sh[None, None, :] + tr * (Q[..., None] * np.cos(P)[..., None] * a + Q[..., None] * np.sin(P)[..., None] * b)
    d /= np.linalg.norm(d, axis=-1, keepdims=True)
    k = re / rp
    o = np.array([r[0], r[1], r[2] * k])
    dd = d.copy()
    dd[..., 2] *= k
    A = (dd ** 2).sum(-1)
    B = (dd * o).sum(-1)
    t = -B / A
    cl = o + dd * t[..., None]
    hit = (t > 0) & ((cl ** 2).sum(-1) < re * re)
    return float((wgt * ~hit).sum() / wgt.sum())


def test_shadow_share(game, check):
    sh = game["shadow"]
    worst = 0.0
    umbra_bad = 0
    clear_bad = 0
    for p in sh["points"]:
        ref = reference_share(p["r"], sh["sun"], sh["re"], sh["rp"], sh["R_sun"], sh["limb_u"])
        worst = max(worst, abs(p["f"] - ref))
        # Cone geometry for the sphere of the radius on that side.
        R = sh["re"] if p["side"] == "eq" else sh["rp"]
        r = np.array(p["r"])
        sv = np.array(sh["sun"]) - r
        ov = -r
        s = math.acos(float(sv @ ov / (np.linalg.norm(sv) * np.linalg.norm(ov))))
        rs = math.asin(sh["R_sun"] / np.linalg.norm(sv))
        rb = math.asin(R / np.linalg.norm(ov))
        if s + rs < rb * 0.999 and p["f"] > 1e-9:
            umbra_bad += 1
        if s > (rs + rb) * 1.001 and p["f"] < 1 - 1e-9:
            clear_bad += 1
    ref = "numpy ray integration of the limb-darkened disc, 400x720 grid"
    check.bound("sunlight share across Jupiter's shadow edge, 200 points", worst, 0.02, ref,
                note="the game's 397-ray disc against a 288,000-ray one")
    check.bound("points inside the umbra cone that see the Sun", umbra_bad, 0, "Montenbruck & Gill 2000, §3.4.2 (cone geometry)", unit="count")
    check.bound("points outside the penumbra cone in any shadow", clear_bad, 0, "Montenbruck & Gill 2000, §3.4.2 (cone geometry)", unit="count")


def test_skin_heat_capacity(game, check):
    sk = game["skin"]
    sig, S, C, leak = sk["sig"], sk["S"], sk["C"], sk["leak"]
    A, eps, alpha = sig["A"], sig["eps"], sig.get("alpha", sig["eps"])
    worst = 0.0
    for run in sk["runs"]:
        f = run["to"]

        def dT(t, T):
            return [(leak + alpha * S * f * A / 4 - eps * SIGMA * A * T[0] ** 4) / C]

        sol = solve_ivp(dT, (0, 6 * 3600), [run["T"][0]], t_eval=[3600 * i for i in range(7)], rtol=1e-9, atol=1e-9)
        worst = max(worst, float(np.max(np.abs(np.array(run["T"]) - sol.y[0]))))
    check.bound("skin temperature through 6 h into and out of shadow", worst, 0.05,
                "scipy solve_ivp (RK45) of the lumped-capacitance equation", unit="K")
