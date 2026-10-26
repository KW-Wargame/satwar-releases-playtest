"""Physical constants and Jupiter-system parameters against CODATA (scipy),
IAU (astropy), JPL Horizons and the Juno gravity papers."""
import math

import astropy.constants as ac
import astropy.units as u
from astropy.time import Time
import scipy.constants as sc

MODEL = "constants"


def test_si_constants(game, check):
    c = game["constants"]
    check.rel("speed of light", c["C_MS"], sc.c, 1e-15, "exact since the 2019 SI (scipy.constants, CODATA 2022)")
    check.rel("Boltzmann k", c["K_BOLTZ"], sc.k, 1e-15, "exact since the 2019 SI (scipy.constants, CODATA 2022)")
    check.rel("Stefan-Boltzmann sigma", c["SIGMA_SB"], sc.Stefan_Boltzmann, 1e-9, "exact since the 2019 SI (scipy.constants, CODATA 2022)")
    check.rel("standard gravity g0", c["G0"] * 1000, sc.g, 1e-15, "CGPM 1901 / NIST SP 811 (scipy.constants)")
    check.rel("NTR exhaust velocity = 900 s * g0", c["NTR_VE"], 900 * sc.g / 1000, 1e-12, "Tsiolkovsky definition of Isp")


def test_jupiter(game, horizons, published, check):
    c = game["constants"]
    j = published["jupiter"]
    check.rel("Jupiter GM vs JPL Horizons (JUP365)", c["mu"], horizons["gm"]["jupiter"], 1e-5, "JPL Horizons 599 header",
              note="game uses the NASA fact-sheet 126.687e6; 3.7e-6 relative, ~370 sigma of JPL's estimate but 1.8e-6 in any period")
    check.rel("Jupiter GM vs Juno (Durante 2020)", c["mu"], j["gm_durante2020"]["value"], 1e-5, j["gm_durante2020"]["source"])
    check.rel("Jupiter GM vs IAU 2015 nominal", c["mu"], ac.GM_jup.to(u.km ** 3 / u.s ** 2).value, 1e-5, "IAU 2015 Resolution B3 (astropy.constants.GM_jup)")
    check.rel("tracker mu = world mu", c["track_mu"], c["mu"], 1e-12, "internal consistency")
    check.rel("equatorial radius", c["R_J"], ac.R_jup.to(u.km).value, 1e-12, "IAU 2015 Resolution B3 (astropy.constants.R_jup)")
    check.rel("J2 reference radius", c["R_REF"], j["reference_radius_km"]["value"], 1e-12, j["reference_radius_km"]["source"])
    check.rel("J2 vs Iess et al. 2018", c["J2"], j["J2_iess2018"]["value"], 1e-5, j["J2_iess2018"]["source"],
              note="game's Folkner 2017 value is 3.9e-6 relative lower")
    check.rel("J2 vs Folkner et al. 2017 (cited)", c["J2"], j["J2_folkner2017"]["value"], 1e-9, j["J2_folkner2017"]["source"])


def test_moon_gm(game, horizons, check):
    for m in game["constants"]["moons"]:
        check.rel(f"GM {m['id']}", m["gm"], horizons["gm"][m["id"]], 2e-8, "JPL Horizons body header (JUP365)")


def test_epoch(game, check):
    """The game's clock: start 2041-10-12 16:10 UTC, moon elements at J2000 (2000-01-01 12:00 TT)."""
    c = game["constants"]
    start = Time("2041-10-12T16:10:00", scale="utc")
    j2000 = Time("J2000.0", scale="tt")
    true_s = (start.tdb - j2000.tdb).to(u.s).value
    check.rel("start time (UTC epoch)", c["startUtc"] / 1000, start.unix, 1e-12, "astropy.time (Unix time, no leap seconds)")
    check.bound("element clock offset ignores leap seconds", abs(c["epochOffset"] - true_s), 75.0, "astropy.time (IERS leap seconds to 2017, none after)",
                note="5 s of leap seconds plus the 64.184 s TT-UTC at J2000 (69.2 s in all) moves Io 0.16 deg and Ganymede 0.04 deg", unit="s")
