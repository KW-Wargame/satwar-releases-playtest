"""Counterspace effects: the one-way jammer equation, spot vs barrage spread,
the coherent turnaround, beam pointing, the laser spot and irradiance (Airy
pattern with jitter, numerically), HPM field strength, and the kill vehicle's
Rayleigh hit probability."""
import math
from fractions import Fraction

import numpy as np
import pytest
import scipy.constants as sc
from scipy.integrate import quad
from scipy.optimize import brentq
from scipy.special import j0, j1, jn_zeros
from scipy.stats import rayleigh

from .test_antenna import itu_gain


@pytest.fixture(autouse=True)
def _scenario_effects(game):
    """The effects' parameters (jammers, uplinks, the laser, HPM, kill vehicles) come
    from a scenario file. xGEO Core on its own ships none (the scenario,
    campaign.json, is part of xGEO Live), so there these checks skip."""
    if not game["effects"].get("jam"):
        pytest.skip("needs a scenario's effects; Core alone has no scenario file")

MODEL = "effects"


def _gain_db(D, f):
    return 10 * math.log10(0.55 * (math.pi * D * f / sc.c) ** 2)


def _angle(at, a, b):
    u, w = np.asarray(a) - at, np.asarray(b) - at
    return math.degrees(math.acos(max(-1.0, min(1.0, float(u @ w / (np.linalg.norm(u) * np.linalg.norm(w)))))))


def _js_db(cfg, c, dJ_m=None):
    """Adamy (2001) EW 101 (Jamming chapter) one-way jamming equation; the public-domain
    NAWCWD TP 8347 (2013) support-jamming equations reduce to the same form for a one-way link,
    J/S = ERP_J - ERP_S - 20 log d_J + 20 log d_S + G_RJ - G_R (same frequency),
    with the receive gains G_RJ, G_R and the jammer's own gain taken from the
    ITU-R patterns (test_antenna.itu_gain) at the geometry's angles: the jammer
    aims at the track (c["aim"]), the victim's dish at its handler."""
    j, up = cfg["jam"]["jammer"], cfg["jam"]["handlerUplink"]
    f = j["f"]
    sh, tg, h = np.array(c["shooter_r"]), np.array(c["target_r"]), np.array(c["handler"])
    dJ = dJ_m if dJ_m is not None else np.linalg.norm(sh - tg) * 1000
    dS = np.linalg.norm(tg - h) * 1000
    erp_j = 10 * math.log10(j["Pj"]) + itu_gain(j["dish"], f, _angle(sh, c["aim"], tg))
    erp_s = 10 * math.log10(up["Pt"]) + _gain_db(up["dish"], f)
    g_rj = itu_gain(c["victim_dish"], f, _angle(tg, h, sh))
    g_r = itu_gain(c["victim_dish"], f, 0.0)
    return erp_j - erp_s - 20 * math.log10(dJ) + 20 * math.log10(dS) + g_rj - g_r


def test_jammer(game, check, published):
    cfg = game["constants"]["effects_cfg"]
    need = cfg["jam"]["needJsDb"]
    w, wr = 0.0, 0.0
    for c in game["effects"]["jam"]:
        w = max(w, abs(c["js_raw_db"] - _js_db(cfg, c)))
        R = _reach_km(cfg, c, need)
        got = c["range_for_need_km"]
        wr = max(wr, abs(got - R) / R if R > 0 else abs(got))
    check.bound(f"J/S through the ITU patterns, {len(game['effects']['jam'])} geometries", w, 1e-9, "Adamy (2001) EW 101 one-way jamming equation with ITU-R SA.509-3 / S.465-5 gains", unit="dB")
    check.bound("jamming range for the needed J/S (farthest point on the line)", wr, 1e-6, "brentq root of the same equation, the shooter moved along the line from the target",
                note="the game bisects 20 times inside a 1.4x step: 1.4^(2^-20) - 1 = 3e-7")
    up = published["rf"]["x_uplink_band_hz"]
    spread = 10 * math.log10((up["hi"] - up["lo"]) / game["constants"]["UPLINK_BW_HZ"])
    check.abs("barrage spread over the deep-space X uplink", game["effects"]["jam"][0]["spread_db"], spread, 1e-9, up["source"], unit="dB",
              note="10 log(45 MHz / 1 MHz) = 16.5 dB (19.5 dB before this pass, which used 7145-7235 MHz)")
    check.true("jammer tuned inside the deep-space uplink band", up["lo"] <= cfg["jam"]["jammer"]["f"] <= up["hi"], up["source"])


def _reach_km(cfg, c, need):
    """Farthest distance (km) from the target, out along the line through the
    shooter, where J/S still meets the need. The jammer keeps aiming at the
    track, so its pointing loss changes as it moves: J/S is recomputed at each
    distance, not scaled by 1/R². Same scan as the game (x1.4 from 0.05 km to
    max(4R, 2e5) km), then brentq inside the last bracket."""
    tg = np.array(c["target_r"])
    u = np.array(c["shooter_r"]) - tg
    u = u / np.linalg.norm(u)

    def g(d):
        return _js_db(cfg, dict(c, shooter_r=list(tg + u * d))) - c["spread_db"] - need

    d, best, miss = 0.05, 0.0, 0.0
    while d <= c["reach_far_km"]:
        if g(d) >= 0:
            best, miss = d, 0.0
        elif best > 0 and miss == 0:
            miss = d
        d *= 1.4
    if best <= 0:
        return 0.0
    if miss == 0:
        miss = best * 1.4
    return brentq(g, best, miss, xtol=1e-12, rtol=1e-14)


def test_turnaround(game, check, published):
    t = published["rf"]["x_band_turnaround"]
    check.rel("uplink/downlink ratio 749/880", game["constants"]["TURNAROUND"], t["den"] / t["num"], 1e-15, t["source"])
    assert Fraction(749, 880) == Fraction(t["den"], t["num"])
    up, dn = published["rf"]["x_uplink_band_hz"], published["rf"]["x_downlink_band_hz"]
    for u_ in game["effects"]["uplinks"]:
        if dn["lo"] <= u_["down"] <= dn["hi"]:
            check.true(f"{u_['class']} {u_['down'] / 1e6:.0f} MHz downlink -> {u_['up'] / 1e6:.1f} MHz uplink in band", up["lo"] <= u_["up"] <= up["hi"], up["source"])


def test_pointing(game, check, published):
    hp = published["rf"]["hpbw_tapered_deg_lambda_over_D"]
    bad = 0
    for c in game["effects"]["pointing"]:
        half = math.radians(hp["value"] * sc.c / c["f"] / c["dish"]) / 2
        # A telescope that sees the target slaves the antenna to it (effects.gd sees_to_aim).
        bad += (c.get("scope", False) or c["sigma_km"] / c["range_km"] < half) != c["can_point"]
    check.true(f"beam on target iff the telescope sees it or 1-sigma across the line < HPBW/2 ({bad} of {len(game['effects']['pointing'])} differ)", bad == 0, hp["source"])


def _airy_jitter_peak(P, D, lam, R, jit):
    """Peak irradiance on axis of a uniformly filled aperture's Airy pattern, smeared by Gaussian pointing
    jitter of `jit` rad 1-sigma per axis (long-exposure average; numerical convolution)."""
    I0 = P * math.pi * D ** 2 / (4 * lam ** 2 * R ** 2)  # Fraunhofer on-axis (Born & Wolf sec. 8.5.2)
    psf = lambda th: (2 * j1(math.pi * D * th / lam) / (math.pi * D * th / lam)) ** 2 if th > 0 else 1.0
    if jit == 0:
        return I0
    g = lambda th: math.exp(-th * th / (2 * jit * jit)) / (2 * math.pi * jit * jit)
    lim = 12 * max(jit, lam / D)
    edges = np.linspace(0, lim, 60)
    val = sum(quad(lambda th: psf(th) * g(th) * 2 * math.pi * th, a, b, epsrel=1e-10)[0] for a, b in zip(edges[:-1], edges[1:]))
    return I0 * val


def test_laser(game, check):
    L = game["effects"].get("laser")
    assert L, "no laser in the campaign"
    w = L["w"]
    x1 = jn_zeros(1, 1)[0] / math.pi
    sat = game["constants"]["effects_cfg"]["dazzle"]["saturationWm2"]
    for s in L["spots"]:
        R = s["R_km"] * 1000
        ref = R * math.hypot(x1 * w["lambda"] / w["aperture"], w["jitter"])
        check.rel(f"spot radius at {s['R_km']:g} km", s["spot_m"], ref, 3e-4, "Airy first dark ring 1.2197 lambda/D (scipy jn_zeros) in quadrature with jitter")
        check.rel(f"irradiance P/(pi spot^2) at {s['R_km']:g} km", s["irradiance"], w["power"] / (math.pi * s["spot_m"] ** 2), 1e-12, "definition")
    R = L["dazzle_range_km"] * 1000
    spot = R * math.hypot(1.22 * w["lambda"] / w["aperture"], w["jitter"])
    check.rel("irradiance at the dazzle range = saturation", w["power"] / (math.pi * spot ** 2), sat, 1e-9, "self-consistency")
    check.abs("dazzle range as in LORE.md", L["dazzle_range_km"], 263600, 100, "docs/LORE.md (HEL-1M)", unit="km")
    # How the game's mean-disc irradiance compares with the true on-axis peak (the number that saturates a sensor).
    peak = _airy_jitter_peak(w["power"], w["aperture"], w["lambda"], R, w["jitter"])
    ratio = peak / sat
    check.info("true peak / game irradiance at the dazzle range (Airy + 0.2 urad jitter)", ratio, "numerical Airy x Gaussian-jitter convolution (Born & Wolf 8.5)",
               note=f"the game is conservative: a perfect 2 m optic would dazzle out to {L['dazzle_range_km'] * math.sqrt(ratio):,.0f} km; "
                    f"equivalently the game assumes a Strehl ratio of {1 / ratio:.2f}")
    gauss = 0.8145 * w["power"] * math.pi * w["aperture"] ** 2 / (4 * w["lambda"] ** 2 * R ** 2)
    check.info("optimally truncated Gaussian beam (M^2 = 1) peak / game", gauss / sat, "Klein & Degnan (1974), Appl. Opt. 13:2134: 81.45% of the uniform Airy peak (max of 2(1 - e^-a^2)^2 / a^2 = 0.8145 at a = 1.12)",
               note="no jitter")
    # Energy inside the first dark ring (no jitter): the game's disc holds 83.8% of the power, not all of it.
    ee = 1 - j0(math.pi * x1) ** 2 - j1(math.pi * x1) ** 2
    check.rel("Airy encircled energy inside the first dark ring", ee, 0.8378, 1e-3, "Rayleigh (1881); Born & Wolf eq. 8.5.(19)",
              note="the game puts all P inside that disc: +19% over the true disc mean, still below the peak")


def test_hpm(game, check):
    h = game["constants"]["effects_cfg"]["hpm"]
    eta0 = sc.mu_0 * sc.c
    S_coef = eta0 / (4 * math.pi)  # E^2 = eta0 * P G / (4 pi R^2)
    R = math.sqrt(S_coef * h["peakW"] * 10 ** (h["gainDbi"] / 10)) / h["upsetVm"] / 1000
    check.rel("HPM reach where E = upset field", game["effects"]["hpm_range_km"], R, 1e-3, "E = sqrt(eta0 S), S = PG/(4 pi R^2), eta0 = mu0 c (scipy)",
              note="the game's 30 is eta0/(4 pi) = 29.98 rounded (Balanis 2016)")


def test_kill_probability(game, check):
    for c in game["effects"]["kill_probability"]:
        p = c["in"]
        check.rel(f"Pk reach {p['reach']:g} km, sigma {p['sigma']:g} km", c["pk"], p["rel"] * rayleigh.cdf(p["reach"], scale=p["sigma"]), 1e-10,
                  "scipy.stats.rayleigh CDF x reliability", floor=1e-12)
