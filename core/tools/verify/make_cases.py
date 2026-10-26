"""Write fixtures/cases.json: the inputs the game is asked to evaluate.

    tools/verify/.venv/Scripts/python tools/verify/make_cases.py

The Godot side (godot/tests/dump_physics.gd) reads this file, runs every case
through the game's own functions, adds cases built from the live campaign data
(every ship, sensor, emitter and weapon), and writes tools/verify/out/game_physics.json.
The pytest suite compares that output with independent references.
Deterministic: the same file every time (fixed seed).
"""
import json
import math
import pathlib

import numpy as np

HERE = pathlib.Path(__file__).resolve().parent
MU = 126.687e6  # only used to build sensible orbits; the tests read the game's mu from the dump
RJ = 71492.0
JD_J2000 = 2451545.0


def circ(r, ang=0.0, inc=0.0):
    v = math.sqrt(MU / r)
    c, s = math.cos(ang), math.sin(ang)
    ci, si = math.cos(inc), math.sin(inc)
    return [r * c, r * s, 0.0], [-v * s * ci, v * c * ci, v * si]


def peri(rp, e, ang=0.0, inc=0.0):
    """State at periapsis of an orbit with periapsis rp and eccentricity e."""
    v = math.sqrt(MU * (1 + e) / rp)
    c, s = math.cos(ang), math.sin(ang)
    ci, si = math.cos(inc), math.sin(inc)
    return [rp * c, rp * s, 0.0], [-v * s * ci, v * c * ci, v * si]


def main():
    rng = np.random.default_rng(20410314)
    day = 86400.0
    orbits = {
        "circular_ganymede": circ(1.0704e6),
        "circular_low": circ(1.5e5, 1.0),
        "ellipse_e0.5": peri(5e5, 0.5, 0.3),
        "ellipse_e0.95": peri(1.0e5, 0.95, 2.0),
        "near_parabolic_e0.999": peri(2e5, 0.999, 4.0),
        "hyperbola_e1.5": peri(2e5, 1.5, 1.2),
        "hyperbola_e3": peri(4e5, 3.0, -0.4),
        "inclined_3d": ([8e5, 1e5, 1e5], [-2.0, 12.0, 3.0]),
        "retrograde": ([1.2e6, 3e5, 0.0], [2.0, -9.5, 0.0]),
    }
    propagate = []
    for name, (r, v) in orbits.items():
        for dt in [60.0, 3600.0, day, 7 * day, -2 * day, 30 * day]:
            propagate.append({"name": name, "r": r, "v": v, "dt": dt})

    elements = []
    for e in [0.0, 0.004, 0.1, 0.5, 0.9, 0.99]:
        for M in [0.0, 37.0, 179.0, 300.0]:
            for t in [0.0, 12345.0, 3.1e6]:
                elements.append({"el": {"a": 8.0e5, "e": e, "M": M, "node": 30.0, "w": 75.0}, "t": t})

    lambert = []
    r1 = [1.0e6, 0.0, 0.0]
    for deg in [20.0, 75.0, 150.0, 179.0, 200.0, 290.0, 345.0]:
        for rr in [6e5, 1.3e6, 2.0e6]:
            for tof_days in [0.25, 1.0, 3.0, 8.0]:
                th = math.radians(deg)
                lambert.append({"r1": r1, "r2": [rr * math.cos(th), rr * math.sin(th), 0.0], "tof": tof_days * day})

    accel = []
    pts = [[1.0e6, 0.0, 0.0], [0.0, 3.0e5, 0.0], [2.0e5, 0.0, 2.0e5], [1.5e5, 5e4, -8e4], [-7e5, 6e5, 1e4], [0.0, 0.0, 1.0e5],
           [1.9e6, 1.0e5, 0.0], [4.25e5, 1.0e4, 0.0]]
    for p in pts:
        for t in [0.0, 1.0e5]:
            for j2, moons in [(True, False), (False, True), (True, True), (False, False)]:
                accel.append({"r": p, "t": t, "j2": j2, "moons": moons})

    coast = []
    # Full model, the sim's own sub-step (60 s) and the tracker's (120 s).
    for name in ["circular_ganymede", "ellipse_e0.5", "retrograde", "inclined_3d"]:
        r, v = orbits[name]
        for max_h in [60.0, 120.0]:
            coast.append({"name": name, "r": r, "v": v, "t0": 0.0, "dt": day, "max_h": max_h, "j2": True, "moons": True, "samples": 4})
    # Long arc for the analytic J2 secular rates: a = 2.2e5 km, e = 0.1, i = 30°, J2 only.
    rp = 2.2e5 * 0.9
    r, v = peri(rp, 0.1, 0.0, math.radians(30.0))
    coast.append({"name": "j2_secular", "r": r, "v": v, "t0": 0.0, "dt": 20 * day, "max_h": 30.0, "j2": True, "moons": False, "samples": 480})

    # Moon states: the Horizons sample times (TDB), as game seconds after the campaign start.
    hz = json.loads((HERE / "fixtures" / "horizons_moons.json").read_text())
    jd = sorted({row["jd_tdb"] for row in hz["sets"]["campaign"]["io"]} | {row["jd_tdb"] for row in hz["sets"]["j2000"]["io"]})
    moon_jd = jd + [row["jd_tdb"] for row in hz["sets"]["decade"]["io"]][::30]

    # Sun and Earth seen from Jupiter: the Horizons sample times, as UTC ms (astropy).
    from astropy.time import Time
    se = json.loads((HERE / "fixtures" / "horizons_sun_earth.json").read_text())
    ephem = []
    for w in ["campaign", "span"]:
        for row in se["sets"][w]["sun"]:
            ephem.append({"set": w, "jd_tdb": row["jd_tdb"], "utc_ms": float(Time(row["jd_tdb"], format="jd", scale="tdb").utc.unix * 1000.0)})
    # The Sun and the planets seen from Jupiter (fetch_planets.py): the Horizons sample times, as UTC ms.
    planets = []
    pl = HERE / "fixtures" / "horizons_planets.json"
    if pl.exists():
        pj = json.loads(pl.read_text())
        for w in pj["sets"]:
            for row in pj["sets"][w]["sun"]:
                planets.append({"set": w, "jd_tdb": row["jd_tdb"], "utc_ms": float(Time(row["jd_tdb"], format="jd", scale="tdb").utc.unix * 1000.0)})

    rf = {
        "db": [1e-3, 0.5, 1.0, 2.0, 1e6],
        "dish_gain": [{"D": D, "f": f} for D in [0.8, 1.5, 3.0, 4.0, 12.0, 34.0, 70.0] for f in [2.2965e9, 7.18e9, 8.43e9, 1e10, 32e9]],
        "friis": [{"Pt": Pt, "Gt": Gt, "Gr": Gr, "R": R, "f": f} for Pt, Gt, Gr in [(20.0, 10 ** -1.5, 1e5), (1.0, 1.0, 1.0), (1000.0, 2e4, 10 ** 3.3)]
                  for R in [1e3, 1e6, 1.6e9, 7.8e11] for f in [2.2965e9, 8.43e9, 32e9]],
        "noise": [{"Ts": Ts, "B": B} for Ts in [20.0, 30.0, 80.0, 290.0, 400.0] for B in [1.0, 5e5, 2e6, 1e8]],
        "integrate": [{"snr": snr, "B": B, "tau": tau} for snr in [1e-4, 3e-3, 1.0] for B in [5e5, 2e6] for tau in [0.0, 60.0, 120.0, 3600.0]],
        "df_sigma": [{"f": f, "d": d, "snr": snr, "n": n} for f in [8.43e9, 2.2965e9] for d in [4.0, 12.0, 200.0] for snr in [10.0, 30.0, 1e3]
                     for n in [0.0, 6e7, 2.4e8]],
        "diffraction": [{"lam": lam, "D": D} for lam in [5.5e-7, 1.06e-6, 1e-5] for D in [0.2, 0.5, 1.0, 2.0]],
        "fspl": [{"R": R, "f": f} for R in [1e3, 1e6, 1.6e9, 7.8e11] for f in [2.2965e9, 7.18e9, 8.43e9, 32e9]],
        "grey": [{"T": T, "eps": eps, "A": A} for T in [110.0, 260.0, 1400.0] for eps in [0.05, 0.85] for A in [1.0, 1200.0]],
        "delta_v": [{"ve": ve, "dry": dry, "prop": prop} for ve in [3.138, 8.825985] for dry in [10.0, 45.0] for prop in [0.0, 5.0, 75.0]],
        # Dish patterns: every dish size in the data, the uplink and downlink bands,
        # angles that land in each piece of the ITU-R SA.509-3 / S.465-5 envelopes.
        "antenna": [{"D": D, "f": f, "phi_deg": p} for D in [0.8, 1.2, 1.5, 1.6, 2.0, 3.0, 3.4, 12.0, 34.0] for f in [7.18e9, 8.43e9]
                    for p in [0.0, 0.01, 0.05, 0.1, 0.2, 0.4, 0.8, 1.0, 1.5, 2.0, 3.0, 5.0, 8.0, 12.0, 20.0, 35.0, 47.9, 48.1, 60.0, 79.9, 80.1, 100.0, 119.9, 120.1, 150.0, 180.0]],
        # Energy-detector Pd: integrated SNR around the threshold, per-sample SNR small and not.
        "detect": [{"snr": snr, "n": n, "pfa": pfa} for pfa in [1e-3, 1e-6] for n in [1e3, 1e5, 2.4e8] for snr in [0.0, 2.0, 4.0, 4.75, 5.5, 7.0, 10.0]],
    }

    occult = []
    for _ in range(300):
        a = rng.uniform(-4e5, 4e5, 3) * np.array([1, 1, 0.3])
        b = rng.uniform(-4e5, 4e5, 3) * np.array([1, 1, 0.3])
        occult.append({"a": a.tolist(), "b": b.tolist()})

    # Tracker cases: an estimate x, P and one measurement.
    ukf = []
    for k in range(24):
        x = [rng.uniform(-1.5e6, 1.5e6), rng.uniform(-1.5e6, 1.5e6), rng.normal(0, 8), rng.normal(0, 8)]
        sp = [rng.uniform(200, 20000), rng.uniform(200, 20000), rng.uniform(0.01, 0.5), rng.uniform(0.01, 0.5)]
        A = rng.normal(size=(4, 4)) * 0.3 + np.eye(4)
        P = (np.diag(sp) @ A @ A.T @ np.diag(sp)).tolist()
        s = [x[0] + rng.uniform(-4e5, 4e5), x[1] + rng.uniform(-4e5, 4e5), 0.0]
        kind = "bearing" if k % 2 == 0 else "range"
        true_ = np.array(x[:2]) + rng.normal(0, 1, 2) * np.sqrt(sp[:2])
        d = true_ - np.array(s[:2])
        z = math.atan2(d[1], d[0]) if kind == "bearing" else float(np.hypot(*d))
        ukf.append({"x": x, "P": P, "kind": kind, "s": s, "z": z, "sigma": 5e-5 if kind == "bearing" else 0.05})
    stm = [{"x": [1.0704e6 * math.cos(a), 1.0704e6 * math.sin(a), -10.88 * math.sin(a) * f, 10.88 * math.cos(a) * f], "dt": dt}
           for a, f, dt in [(0.3, 1.0, 600.0), (2.0, 1.1, 3600.0), (4.0, 0.85, 21600.0), (5.5, 1.0, 86400.0)]]
    cross = []
    for k in range(12):
        tgt = rng.uniform(-1.5e6, 1.5e6, 2)
        lines = []
        for j in range(2 + k % 3):
            o = rng.uniform(-1.5e6, 1.5e6, 2)
            lines.append({"from": [o[0], o[1], 0.0], "bearing": math.atan2(tgt[1] - o[1], tgt[0] - o[0]), "sigma": float(rng.uniform(2e-5, 3e-4))})
        cross.append({"target": tgt.tolist(), "lines": lines})

    # Published worked examples (inputs and printed answers), run through the game's solvers.
    worked = {
        "propagate": [
            {"source": "Curtis (2020), Orbital Mechanics for Engineering Students, 4th ed., Example 3.7 (Algorithm 3.4)",
             "mu": 398600.0, "r": [7000.0, -12124.0, 0.0], "v": [2.6679, 4.6210, 0.0], "dt": 3600.0,
             "expect": {"r": [-3297.8, 7413.4, 0.0], "v": [-8.2976, -0.96404, 0.0]}, "digits": 5},
            {"source": "Vallado (2013), Fundamentals of Astrodynamics and Applications, 4th ed., Example 2-4 (KEPLER)",
             "mu": 398600.4418, "r": [1131.340, -2282.343, 6672.423], "v": [-5.64305, 4.30333, 2.42879], "dt": 2400.0,
             "expect": {"r": [-4219.7527, 4363.0292, -3958.7666], "v": [3.689866, -1.916735, -6.112511]}, "digits": 7},
        ],
        "lambert": [
            {"source": "Curtis (2020), Example 5.2", "mu": 398600.0, "r1": [5000.0, 10000.0, 2100.0], "r2": [-14600.0, 2500.0, 7000.0], "tof": 3600.0,
             "expect": {"v1": [-5.9925, 1.9254, 3.2456], "v2": [-3.3125, -4.1966, -0.38529]}, "digits": 5},
        ],
    }

    cases = {
        "worked": worked,
        "note": "Generated by tools/verify/make_cases.py. Inputs only; the game evaluates them in godot/tests/dump_physics.gd.",
        "propagate": propagate, "elements": elements, "lambert": lambert, "accel": accel, "coast": coast,
        "moon_jd_tdb": moon_jd, "jd_j2000": JD_J2000, "rf": rf, "occult": occult, "ukf": ukf, "stm": stm, "cross_fix": cross,
        "laser_R_km": [1e3, 1e4, 5e4, 1e5, 2.6e5, 1e6],
        "kill_probability": [{"reach": r, "sigma": s, "rel": 0.9} for r in [10.0, 100.0, 1000.0] for s in [5.0, 50.0, 500.0, 5000.0]],
        "radar_R_km": [1e3, 5e3, 1.5e4, 3e4, 1e5],
        "ephem": ephem,
        "planets": planets,
    }
    (HERE / "fixtures" / "cases.json").write_text(json.dumps(cases, indent=0))
    print("wrote fixtures/cases.json:", {k: len(v) for k, v in cases.items() if isinstance(v, list)})


if __name__ == "__main__":
    main()
