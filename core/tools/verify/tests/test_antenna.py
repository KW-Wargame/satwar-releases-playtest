"""Antenna patterns and detection: the ITU-R reference patterns every emitter,
ear, jammer and victim uses (godot/core/antenna.gd), the receive arrays' scan
loss, the link budgets through those patterns, and the energy detector's
probability of detection (godot/core/rf.gd detect_pd)."""
import math

import numpy as np
import scipy.constants as sc
from scipy.optimize import brentq
from scipy.stats import chi2, ncx2, norm

MODEL = "antenna"
ETA = 0.55


def itu_gain(D, f, phi_deg):
    """Coded here from the Recommendations' text, not from the game:
    ITU-R SA.509-3 §1.1 (main lobe G0 - 3 (phi/phi0)^2, phi0 = 20 sqrt(3) / (D/lambda) deg)
    and its single-entry pattern for D/lambda >= 100; ITU-R S.465-5 Note 4
    (52 - 10 log(D/lambda) - 25 log(phi) from 100 lambda/D, 10 - 10 log(D/lambda) from 48 deg)
    for smaller dishes, held at the envelope's value at phi_min inside it."""
    lam = sc.c / f
    dl = D / lam
    g0 = 10 * math.log10(ETA * (math.pi * dl) ** 2)
    p = abs(phi_deg)
    phi0 = 20 * math.sqrt(3) / dl
    main = g0 - 3 * (p / phi0) ** 2
    if dl >= 100:
        phi1 = phi0 * math.sqrt(17 / 3)
        phi2 = 10 ** ((49 - g0) / 25)
        if p < phi1:
            return main
        if p < phi2:
            return g0 - 17
        if p < 48:
            return 32 - 25 * math.log10(p)
        if p < 80:
            return -10.0
        if p < 120:
            return -5.0
        return -10.0

    def env(q):
        return 52 - 10 * math.log10(dl) - 25 * math.log10(q) if q < 48 else 10 - 10 * math.log10(dl)

    pmin = 100 / dl
    if p < pmin:
        return min(g0, max(main, env(pmin)))
    return env(p)


def test_itu_patterns(game, check):
    cases = game["rf"]["antenna"]
    worst = max(abs(c["gain_dbi"] - itu_gain(c["in"]["D"], c["in"]["f"], c["in"]["phi_deg"])) for c in cases)
    check.abs(f"dish gain off boresight, {len(cases)} cases, 0.8-34 m", worst, 0.0, 1e-9, "ITU-R SA.509-3 §1.1/§1.3 and S.465-5 Note 4, coded from the text", unit="dB")
    for c in cases:
        if c["in"]["phi_deg"] == 0.0:
            lam = sc.c / c["in"]["f"]
            check.rel(f"peak = eta (pi D/lambda)^2, D={c['in']['D']:g} f={c['in']['f'] / 1e9:g}", 10 ** (c["gain_dbi"] / 10), ETA * (math.pi * c["in"]["D"] / lam) ** 2, 1e-12, "IEEE Std 145-2013")
            check.rel(f"3 dB width = 40 sqrt(3) lambda/D deg, D={c['in']['D']:g}", c["beamwidth"], math.radians(40 * math.sqrt(3) * lam / c["in"]["D"]), 1e-12, "ITU-R SA.509-3 §1.1")


def test_pattern_shape(game, check):
    """Shape checks that don't depend on how the curves were coded: gain never
    rises off boresight, never exceeds the peak, and the far sidelobes of a
    D/lambda < 100 dish sit at 10 - 10 log(D/lambda) as S.465-5 states."""
    by = {}
    for c in game["rf"]["antenna"]:
        by.setdefault((c["in"]["D"], c["in"]["f"]), []).append((c["in"]["phi_deg"], c["gain_dbi"], c["peak_dbi"]))
    rises = 0
    over = 0.0
    for (D, f), rows in by.items():
        rows.sort()
        g = [r[1] for r in rows]
        # S.465-5 itself steps up 0.03 dB at 48 deg (52 - 25 log 48 = 9.97 against 10).
        rises += sum(1 for a, b in zip(g, g[1:]) if b > a + 0.035 and not (D / (sc.c / f) >= 100))
        over = max(over, max(r[1] - r[2] for r in rows))
        if D / (sc.c / f) < 100:
            far = [r[1] for r in rows if r[0] > 48.5]
            check.abs(f"far sidelobes, D={D:g} f={f / 1e9:g}", far, 10 - 10 * math.log10(D / (sc.c / f)), 1e-9, "ITU-R S.465-5 Note 4", unit="dB")
    check.true("gain never rises off boresight (S.465 dishes; its own 0.03 dB step at 48 deg allowed)", rises == 0, "monotone envelope", got=rises)
    check.bound("gain never above the peak", over, 1e-12, "definition of peak gain", unit="dB")


def test_receive_arrays(game, check):
    """An array beam toward theta has gain G_peak + 10 log cos(scan), scan the angle off the nearest face."""
    worst = 0.0
    for c in game["sensing"]["arrays"]:
        lam = sc.c / c["f"]
        g0 = 10 * math.log10(ETA * (math.pi * c["esm"]["dish"] / lam) ** 2)
        step = 2 * math.pi / c["esm"].get("faces", 4)
        k = round(c["theta"] / step)
        scan = abs(math.remainder(c["theta"] - k * step, 2 * math.pi))
        worst = max(worst, abs(c["gain_dbi"] - (g0 + 10 * math.log10(math.cos(scan)))))
    check.abs(f"array gain all round, {len(game['sensing']['arrays'])} directions", worst, 0.0, 1e-9, "planar array, projected aperture cos(scan)", unit="dB")


def _link_db(c, R):
    """dB-form budget through the patterns: Pt + Gt + Gr - L_bf - 10 log(kTB) + 5 log(B tau)."""
    ttc, esm = c["ttc"], c["esm"]
    f, bw = ttc["f"], ttc["bw"]
    lam = sc.c / f
    gt = itu_gain(ttc["dish"], f, c["off_deg"])
    gr = 10 * math.log10(ETA * (math.pi * esm["dish"] / lam) ** 2)
    return 10 * math.log10(ttc["Pt"]) + gt + gr - 20 * math.log10(4 * math.pi * R / lam) - 10 * math.log10(sc.k * esm["Ts"] * bw) + 5 * math.log10(bw * ttc["burst"])


def test_links_through_patterns(game, check):
    k = norm.isf(game["sensing"]["pfa"])
    wsnr = wrng = 0.0
    for c in game["sensing"]["links"]:
        ref = 10 ** (_link_db(c, c["R_m"]) / 10)
        wsnr = max(wsnr, abs(c["snr"] - ref) / ref)
        R = brentq(lambda R: _link_db(c, R) - 10 * math.log10(k), 1.0, 1e16, xtol=1e-6, rtol=1e-14)
        wrng = max(wrng, abs(c["range_km"] - R / 1000) / (R / 1000))
    n = len(game["sensing"]["links"])
    check.bound(f"burst SNR through both patterns, {n} cases", wsnr, 1e-9, "dB-form link budget (DSN 810-005 Module 201 layout) with ITU-R patterns")
    check.bound(f"even-odds range (SNR = Q^-1(Pfa)), {n} cases", wrng, 1e-6, "brentq root of the dB-form budget; Q^-1 from scipy.stats.norm.isf")


def test_detection_probability(game, check):
    """Against the exact distributions of an energy detector over n complex samples:
    2 sum |z|^2 is chi-square with 2n degrees of freedom without a signal, and
    non-central chi-square (non-centrality 2 n s) with one of per-sample SNR s
    (Urkowitz 1967; scipy.stats). The game uses the Gaussian approximation."""
    for c in game["rf"]["detect"][:1]:
        check.rel("Q^-1(Pfa)", c["q_inv"], norm.isf(c["in"]["pfa"]), 1e-7, "scipy.stats.norm.isf")
    tight = loose = 0.0
    for c in game["rf"]["detect"]:
        snr, n, pfa = c["in"]["snr"], c["in"]["n"], c["in"]["pfa"]
        check.rel(f"Q^-1({pfa:g})", c["q_inv"], norm.isf(pfa), 1e-7, "scipy.stats.norm.isf")
        s = snr / math.sqrt(n)
        thr = chi2.isf(pfa, 2 * n)
        exact = ncx2.sf(thr, 2 * n, 2 * n * s) if s > 0 else pfa
        err = abs(c["pd"] - exact)
        if n >= 1e5:
            tight = max(tight, err)
        else:
            loose = max(loose, err)
    check.bound("Pd vs exact chi-square, n >= 1e5 samples (every burst in the game has n > 3e7)", tight, 0.01, "scipy.stats chi2 / ncx2")
    check.info("Pd vs exact chi-square at n = 1e3 (skewed; outside the game's range)", loose, "scipy.stats chi2 / ncx2",
               note="the Gaussian approximation needs many samples; the game never has fewer than 3e7")
