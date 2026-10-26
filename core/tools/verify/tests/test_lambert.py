"""Lambert's problem against hapsira's Izzo (2015) solver and Curtis Example 5.2."""
import numpy as np
from hapsira.core.iod import izzo
from hapsira.core.propagation import farnocchia

MODEL = "lambert"


def test_vs_izzo(game, check):
    worst, worst_name, n, none, arrive = 0.0, "", 0, [], 0.0
    for c in game["lambert"]:
        if c["name"] == "worked":
            continue
        r1, r2, tof, mu = np.array(c["r1"]), np.array(c["r2"]), c["tof"], c["mu"]
        ang = np.degrees(np.arctan2(np.cross(r1, r2)[2], r1 @ r2)) % 360
        if c["v1"] is None:
            # 0 and 180 deg transfers are degenerate (the plane is undefined): no solution is right.
            if min(ang, 360 - ang) > 0.01 and abs(ang - 180) > 0.01:
                none.append(c)
            continue
        v1, v2 = izzo(mu, r1, r2, tof, 0, True, True, 35, 1e-11)
        e = max(np.linalg.norm(np.array(c["v1"]) - v1) / np.linalg.norm(v1), np.linalg.norm(np.array(c["v2"]) - v2) / np.linalg.norm(v2))
        if e > worst:
            worst, worst_name = e, f"{c['name'] or 'grid'} {np.degrees(np.arctan2(r2[1], r2[0])) % 360:.0f} deg, {tof / 3600:.0f} h"
        rr, _ = farnocchia(mu, r1, np.array(c["v1"]), tof)
        arrive = max(arrive, np.linalg.norm(rr - r2))
        n += 1
    check.bound(f"v1, v2 vs Izzo (worst of {n})", worst, 1e-6, "hapsira 0.18 izzo (Izzo 2015, Celest. Mech. Dyn. Astr. 121:1)", note=f"relative; worst at {worst_name}")
    check.bound("game's transfer flown by hapsira lands on r2", arrive, 1e-2, "hapsira farnocchia", unit="km")
    check.true(f"a solution for every non-degenerate transfer ({len(none)} missing)", len(none) == 0, "Izzo finds all of them",
               note="; ".join(f"{np.degrees(np.arctan2(c['r2'][1], c['r2'][0])) % 360:.0f} deg {c['tof'] / 3600:.0f} h" for c in none))


def test_curtis_example(game, check):
    for c in game["lambert"]:
        if c["name"] != "worked":
            continue
        w = c["worked"]
        for k in ("v1", "v2"):
            err = np.linalg.norm(np.array(c[k]) - w["expect"][k]) / np.linalg.norm(w["expect"][k])
            check.bound(f"Curtis Ex. 5.2 {k}", err, 6e-5, w["source"], note="relative to the printed answer")
