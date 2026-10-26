"""The radar equation (monostatic, average-power / dwell form) and monopulse
angle accuracy, for every radar class in the campaign against every hull."""
import math

import scipy.constants as sc
from scipy.optimize import brentq

MODEL = "radar"


def _snr_db(rd, rcs, R):
    """Skolnik (2008) radar equation in dB: Pavg + 2G + 2 lambda + sigma + t - 3(4 pi) - 4R - k - Ts."""
    lam = sc.c / rd["f"]
    G = 10 * math.log10(0.55 * (math.pi * rd["dish"] / lam) ** 2)
    return (10 * math.log10(rd["pAvg"]) + 2 * G + 20 * math.log10(lam) + 10 * math.log10(rcs) + 10 * math.log10(rd["tau"])
            - 30 * math.log10(4 * math.pi) - 40 * math.log10(R) - 10 * math.log10(sc.k) - 10 * math.log10(rd["Ts"]))


def test_radar_equation(game, check):
    w = 0.0
    for c in game["sensing"]["radar"]:
        ref = 10 ** (_snr_db(c["radar"], c["rcs"], c["R_km"] * 1000) / 10)
        w = max(w, abs(c["snr"] - ref) / ref)
    check.bound(f"radar SNR, {len(game['sensing']['radar'])} radar x hull x range cases", w, 1e-9,
                "Skolnik (2008) Radar Handbook (chapter not verified; same form in NAWCWD TP 8347 sec. 4-5 eq. [1]), average-power form, independent dB implementation", note="no losses modelled (design simplification)")


def test_radar_range_claim(game, check):
    """LORE.md / the tutorial: ~13,000 km on a 0.5 m^2 hull at 13 dB (25 kW average, inside the 100 kWe plant)."""
    rd = next(c["radar"] for c in game["sensing"]["radar"] if c["radar_class"] == "sentinel")
    R = brentq(lambda R: _snr_db(rd, 0.5, R) - 10 * math.log10(20.0), 1e3, 1e12)
    check.rel("detection range on 0.5 m^2 at 13 dB", R / 1000, 13000.0, 0.05, "docs/LORE.md realism audit; src/content/why.js",
              note=f"{R / 1000:,.0f} km (aperture efficiency 0.55; the JS mirror used 0.6 before this pass: 15,292 km)")


def test_monopulse_angle(game, check, published):
    km = published["rf"]["monopulse_slope_km"]["value"]
    hp = published["rf"]["hpbw_tapered_deg_lambda_over_D"]["value"]
    w = 0.0
    for c in game["sensing"]["radar"]:
        rd = c["radar"]
        theta3 = math.radians(hp) * (sc.c / rd["f"]) / rd["dish"]
        ref = theta3 / (km * math.sqrt(2 * c["snr"]))
        w = max(w, abs(c["angle_sigma"] - ref) / ref)
    check.bound("monopulse angle sigma = theta3 / (km sqrt(2 SNR))", w, 2e-3, published["rf"]["monopulse_slope_km"]["source"],
                note="theta3 = 1.22 lambda/D in the game vs 70 deg lambda/D = 1.2217; before this pass the game used 1.22 lambda/D / sqrt(SNR), 2.26x larger")
