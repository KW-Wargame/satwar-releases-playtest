"""Interferometer direction finding: the game's bearing sigma against a Monte
Carlo of the actual measurement (two antennas a baseline d apart, each
receiving an unknown noise-like signal in thermal noise; the bearing comes
from the phase of their cross-correlation), and against the analytic
cross-correlation phase variance (1 + 2s) / (2 N s^2). The form follows from the
Knapp & Carter (1976) Cramer-Rao bound written in terms of coherence,
gamma^2 = s^2 / (1 + s)^2, in the narrowband limit; its weak-signal limit
sigma_phi = 1 / (sqrt(2) SNR) is Thompson, Moran & Swenson 2017 sec. 6.2.4, eq. 6.64."""
import math

import numpy as np
import scipy.constants as sc

MODEL = "df"


def _mc_phase_sigma(s, N, trials, rng, phi=0.7):
    est = np.empty(trials)
    for k in range(trials):
        sig = (rng.standard_normal(N) + 1j * rng.standard_normal(N)) * math.sqrt(s / 2)
        x1 = sig + (rng.standard_normal(N) + 1j * rng.standard_normal(N)) / math.sqrt(2)
        x2 = sig * np.exp(1j * phi) + (rng.standard_normal(N) + 1j * rng.standard_normal(N)) / math.sqrt(2)
        est[k] = np.angle(np.vdot(x1, x2))
    return float(np.std(est - phi))


def test_df_sigma_monte_carlo(game, check):
    rng = np.random.default_rng(11)
    f, d = 8.43e9, 12.0
    scale = sc.c / f / (2 * math.pi * d)
    for s, N in [(0.01, 200000), (0.05, 20000), (1.0, 2000)]:
        snr = s * math.sqrt(N)
        # The game's df_sigma on these inputs, via its dumped grid and the closed form it must equal.
        sig_mc = _mc_phase_sigma(s, N, 600, rng) * scale
        game_form = scale * math.sqrt((1 + 2 * s) / (2 * snr * snr))
        check.rel(f"bearing sigma, s={s:g}, N={N} (SNR {snr:.0f})", game_form, sig_mc, 0.08, "Monte Carlo of a two-element correlator, 600 trials",
                  note="8% ~ 3 sigma of the Monte Carlo; before this pass the game used lambda/(2 pi d sqrt(2 SNR)), "
                       f"{math.sqrt(2 * snr) / math.sqrt(1 + 2 * s) / math.sqrt(2):.1f}x too large here")


def test_df_sigma_closed_form(game, check):
    w = 0.0
    for c in game["rf"]["df_sigma"]:
        p = c["in"]
        lam = sc.c / p["f"]
        s = p["snr"] / math.sqrt(p["n"]) if p["n"] > 0 else 0.0
        ref = lam / (2 * math.pi * p["d"]) * math.sqrt((1 + 2 * s) / (2 * p["snr"] ** 2))
        w = max(w, abs(c["out"] - ref) / ref)
    check.bound(f"df_sigma vs (1+2s)/(2 N s^2), {len(game['rf']['df_sigma'])} cases", w, 1e-12, "Knapp & Carter 1976, IEEE TASSP 24:320 (coherence CRLB, narrowband limit; the (1+2s) factor); TMS 2017 sec. 6.2.4, eq. 6.64 (weak-signal limit)")


def test_weak_signal_limit(game, check):
    """df_sigma without n is the weak-signal limit s << 1. The sim always passes n = B*tau; the database
    window quotes 'DF sigma at SNR 30' for a 1 MHz, 60 s report without it. Bound that use."""
    s = 30.0 / math.sqrt(1e6 * 60.0)
    check.bound("weak-limit error of the database window's DF figure", math.sqrt(1 + 2 * s) - 1, 0.01, "(1+2s)/(2 N s^2) with s = 30/sqrt(B tau)")
    side = [c for c in game["sensing"]["links"] if c["off_deg"] >= 90]
    s_max = max(c["snr"] / math.sqrt(c["ttc"]["bw"] * c["ttc"]["burst"]) for c in side)
    check.bound("per-sample SNR of the strongest burst at 1e6 km, heard 90 deg or more off its beam", s_max, 1.0, "link budgets of every emitter x receiver class")
    s_main = max(c["snr"] / math.sqrt(c["ttc"]["bw"] * c["ttc"]["burst"]) for c in game["sensing"]["links"])
    check.info("per-sample SNR of the strongest burst at 1e6 km in its main beam (why the sim passes n)", s_main, "link budgets of every emitter x receiver class",
               note="s grows as 1/R^2 and with the emitter's gain: the (1+2s) term matters in a main beam")
