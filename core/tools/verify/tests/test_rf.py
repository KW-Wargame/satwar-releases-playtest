"""Radio physics: dB, wavelength, dish gain, Friis / free-space loss (ITU-R
P.525), kTB noise, the radiometer equation (Monte Carlo of an energy
detector), and the rocket equation for every ship. Link budgets through the
antenna patterns are in test_antenna.py."""
import math

import numpy as np
import scipy.constants as sc
from scipy.optimize import brentq
from scipy.special import jn_zeros

MODEL = "rf"


def test_db_and_wavelength(game, check):
    for c in game["rf"]["db"]:
        check.rel(f"10 log10({c['x']:g})", c["db"], 10 * math.log10(c["x"]), 1e-14, "numpy/math log10")
        check.rel(f"from_db(db({c['x']:g}))", c["back"], c["x"], 1e-13, "inverse")
    for c in game["rf"]["wavelength"]:
        check.rel(f"wavelength {c['f'] / 1e9:g} GHz", c["lam"], sc.c / c["f"], 1e-15, "c / f (scipy.constants)")


def test_dish_gain(game, check):
    """G = 4 pi Ae / lambda^2 with Ae = eta pi D^2 / 4 (IEEE Std 145-2013 definitions), eta = 0.55."""
    worst = 0.0
    for c in game["rf"]["dish_gain"]:
        lam = sc.c / c["f"]
        Ae = 0.55 * math.pi * c["D"] ** 2 / 4
        worst = max(worst, abs(c["G"] - 4 * math.pi * Ae / lam ** 2) / (4 * math.pi * Ae / lam ** 2))
    check.bound(f"dish gain, {len(game['rf']['dish_gain'])} dishes 0.8-70 m, S to Ka", worst, 1e-12, "IEEE Std 145-2013: G = 4 pi Ae / lambda^2")
    # DSN's published 34 m BWG X-band downlink gain is 68.24 dBi X-only / 68.19 dBi S/X at 8425 MHz (DSS-24; 810-005
    # Module 104 Rev. O, Table 8), taken here as 68.2 dBi, i.e. eta ~ 0.69;
    # the game's 0.55 is a conservative, typical aperture efficiency for small spacecraft dishes.
    g34 = next(c["G"] for c in game["rf"]["dish_gain"] if c["D"] == 34.0 and abs(c["f"] - 8.43e9) < 1)
    check.bound("34 m dish at 8.43 GHz below DSN's 68.2 dBi (eta 0.55 vs ~0.69)", 68.2 - 10 * math.log10(g34), 1.5, "DSN 810-005 Module 104 Rev. O, Table 8 (34 m BWG, 68.24 dBi at 8425 MHz)", unit="dB",
                note="positive: the game is conservative by this much")


def test_friis_and_free_space_loss(game, check, published):
    k = published["rf"]["itu_r_p525_constant_db"]["value"]
    wl, wi, we = 0.0, 0.0, 0.0
    for c in game["rf"]["friis"]:
        p = c["in"]
        lbf = k + 20 * math.log10(p["f"] / 1e6) + 20 * math.log10(p["R"] / 1e3)
        pr_itu = 10 * math.log10(p["Pt"] * p["Gt"] * p["Gr"]) - lbf
        wl = max(wl, abs(10 * math.log10(c["Pr"]) - pr_itu))
        exact = p["Pt"] * p["Gt"] * p["Gr"] * (sc.c / p["f"] / (4 * math.pi * p["R"])) ** 2
        we = max(we, abs(c["Pr"] - exact) / exact)
    check.bound("Friis received power vs ITU-R P.525 (32.4 dB form)", wl, 0.05, published["rf"]["itu_r_p525_constant_db"]["source"], unit="dB",
                note="eq. (4) rounds the exact eq. (3) constant 20 log10(4 pi 1e9 / c) = 32.4478 to 32.4")
    check.bound("Friis received power vs exact form", we, 1e-12, "Friis 1946 with scipy.constants c")
    for c in game["rf"]["fspl"]:
        p = c["in"]
        lbf = k + 20 * math.log10(p["f"] / 1e6) + 20 * math.log10(p["R"] / 1e3)
        wi = max(wi, abs(c["db"] - lbf))
        check.abs(f"effects FSPL = -Friis unity gains, {p['f'] / 1e9:g} GHz {p['R']:.0e} m", c["db"], c["friis_unity_db"], 1e-9, "internal consistency", unit="dB")
    check.bound("jammer free-space loss vs ITU-R P.525", wi, 0.05, published["rf"]["itu_r_p525_constant_db"]["source"], unit="dB")


def test_noise(game, check, published):
    for c in game["rf"]["noise"]:
        check.rel(f"kTB T={c['in']['Ts']:g} K B={c['in']['B']:g} Hz", c["N"], sc.k * c["in"]["Ts"] * c["in"]["B"], 1e-14, "k exact since the 2019 SI (scipy.constants, CODATA 2022) x T x B")
    n290 = next(c["N"] for c in game["rf"]["noise"] if c["in"]["Ts"] == 290.0 and c["in"]["B"] == 1.0)
    check.abs("kT0 = -174 dBm/Hz at 290 K", 10 * math.log10(n290 * 1000), published["rf"]["kT0_dbm_per_hz_290K"]["value"], 0.03, published["rf"]["kT0_dbm_per_hz_290K"]["source"], unit="dB")
    check.abs("10 log k = -228.6 dBW/K/Hz", 10 * math.log10(n290 / 290), published["rf"]["boltzmann_dbw_per_k_hz"]["value"], 0.01, published["rf"]["boltzmann_dbw_per_k_hz"]["source"], unit="dB")


def test_radiometer_monte_carlo(game, check):
    """integrate(snr, B, tau) = snr sqrt(B tau): the deflection of an energy detector (Dicke 1946;
    Wilson, Rohlfs & Huttemeister 2013, eq. number unverified; the total-power radiometer equation,
    Condon & Ransom, Essential Radio Astronomy ch. 3 eq. 3.154; a Dicke-switched radiometer is 2x worse). Simulated: N = B tau complex samples, signal power s."""
    rng = np.random.default_rng(7)
    g = [c for c in game["rf"]["integrate"] if c["in"]["tau"] > 0][0]
    assert math.isclose(g["out"], g["in"]["snr"] * math.sqrt(g["in"]["B"] * g["in"]["tau"]), rel_tol=1e-12)
    trials = 2000
    for s, N in [(0.02, 40000), (0.05, 10000), (0.1, 2500)]:
        on, off = np.empty(trials), np.empty(trials)
        for k in range(trials):
            x = (rng.standard_normal(N) + 1j * rng.standard_normal(N)) * math.sqrt((1 + s) / 2)  # signal + noise, both Gaussian
            y = (rng.standard_normal(N) + 1j * rng.standard_normal(N)) / math.sqrt(2)  # noise alone
            on[k], off[k] = np.mean(np.abs(x) ** 2), np.mean(np.abs(y) ** 2)
        deflection = (on.mean() - off.mean()) / off.std()
        check.rel(f"radiometer gain, s={s:g}, N={N}", s * math.sqrt(N), deflection, 0.06, f"Monte Carlo energy detector, {trials} trials",
                  note="the game's integrate() is exactly s*sqrt(B*tau) (asserted); 6% is ~3.5 sigma of the Monte Carlo's scatter")
    for c in game["rf"]["integrate"]:
        p = c["in"]
        check.rel(f"integrate({p['snr']:g}, {p['B']:g}, {p['tau']:g})", c["out"], p["snr"] * math.sqrt(p["B"] * p["tau"]), 1e-12, "radiometer equation", floor=1e-300)


def test_diffraction(game, check):
    x1 = jn_zeros(1, 1)[0] / math.pi  # first dark ring of the Airy pattern: 1.2197 lambda / D
    for c in game["rf"]["diffraction"]:
        check.rel(f"1.22 lambda/D, lambda={c['in']['lam']:g} D={c['in']['D']:g}", c["out"], x1 * c["in"]["lam"] / c["in"]["D"], 3e-4,
                  "first zero of J1 / pi (scipy.special.jn_zeros; Airy 1835, Born & Wolf sec. 8.5)", note="1.22 is 1.2197 rounded")


def test_rocket_equation(game, check):
    for c in game["rf"]["delta_v"]:
        p = c["in"]
        ref = p["ve"] * math.log((p["dry"] + p["prop"]) / p["dry"])
        check.abs(f"dv ve={p['ve']:g} dry={p['dry']:g} prop={p['prop']:g}", c["out"], ref, 1e-12, "Tsiolkovsky 1903", unit="km/s")


# Delta-v quoted in docs/LORE.md's realism audit, by class.
LORE_DV = {"sentinel": 8.66, "pfs": 4.94, "vesper": 9.70, "moth": 9.70, "gadfly": 2.66, "wren": 1.84}


def test_lore_delta_v(game, check):
    seen = set()
    for s in game["platforms"]["ships"]:
        if s["class"] in LORE_DV and "delta_v" in s and s["class"] not in seen:
            seen.add(s["class"])
            check.abs(f"{s['class']} dv as in LORE.md", s["delta_v"], LORE_DV[s["class"]], 0.006, "docs/LORE.md realism audit", unit="km/s")
