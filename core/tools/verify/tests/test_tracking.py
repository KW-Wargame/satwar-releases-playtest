"""The tracker: unscented measurement update against filterpy's
UnscentedKalmanFilter (Julier sigma points, kappa = 0), the state-transition
matrix against the variational equations, process noise against filterpy's
continuous white-noise model, and the bearing-line fix against scipy least squares."""
import math

import numpy as np
from filterpy.common import Q_continuous_white_noise
from filterpy.kalman import JulierSigmaPoints, UnscentedKalmanFilter
from hapsira.core.propagation import farnocchia
from scipy.optimize import least_squares

import refs

MODEL = "tracking"


def _wrap(a):
    return (a + np.pi) % (2 * np.pi) - np.pi


def test_unscented_update(game, check):
    wx, wp = 0.0, 0.0
    for c in game["tracking"]["update"]:
        k = c["in"]
        x, P, s = np.array(k["x"]), np.array(k["P"]), np.array(k["s"])
        pts = JulierSigmaPoints(4, kappa=0.0)
        if k["kind"] == "bearing":
            hx = lambda p: np.array([math.atan2(p[1] - s[1], p[0] - s[0])])
            ukf = UnscentedKalmanFilter(4, 1, 1.0, hx, lambda x, dt: x, pts,
                                        residual_z=lambda a, b: _wrap(a - b),
                                        z_mean_fn=lambda sig, w: np.array([math.atan2(np.sum(np.sin(sig[:, 0]) * (w != 0)), np.sum(np.cos(sig[:, 0]) * (w != 0)))]))
        else:
            hx = lambda p: np.array([math.hypot(p[0] - s[0], p[1] - s[1])])
            ukf = UnscentedKalmanFilter(4, 1, 1.0, hx, lambda x, dt: x, pts)
        ukf.x, ukf.P = x.copy(), P.copy()
        ukf.sigmas_f = pts.sigma_points(x, P)
        ukf.update(np.array([k["z"]]), R=np.array([[k["sigma"] ** 2]]))
        dx_ref, dx = ukf.x - x, np.array(c["x"]) - x
        wx = max(wx, np.linalg.norm(dx - dx_ref) / max(np.linalg.norm(dx_ref), 1e-9))
        wp = max(wp, np.linalg.norm(np.array(c["P"]) - ukf.P) / np.linalg.norm(ukf.P))
    n = len(game["tracking"]["update"])
    ref = "filterpy 1.4.5 UnscentedKalmanFilter, JulierSigmaPoints(kappa=0) (Julier & Uhlmann 2004)"
    check.bound(f"UKF state correction, {n} bearing/range updates", wx, 1e-6, ref,
                note="the game's circular mean uses equal weights; filterpy's z_mean_fn here does the same over the 2n points")
    check.bound(f"UKF covariance, {n} updates", wp, 1e-6, ref)


def test_stm_and_predict(game, check):
    mu = game["constants"]["track_mu"]
    for c in game["tracking"]["stm"]:
        x, dt = np.array(c["x"]), c["dt"]
        F_ref, x1 = refs.two_body_stm(x, dt, mu)
        F = np.array(c["F"])
        check.rel(f"STM over {dt / 3600:g} h", np.linalg.norm(F - F_ref) / np.linalg.norm(F_ref), 0.0, 1e-5,
                  "variational equations of the two-body problem, scipy DOP853", floor=1.0, note="the game differences its Kepler solver (central, 1 km / 1e-4 km/s steps)")
        rr, vv = farnocchia(mu, np.array([x[0], x[1], 0.0]), np.array([x[2], x[3], 0.0]), dt)
        check.rel(f"mean coast {dt / 3600:g} h", np.linalg.norm(np.array(c["coast"])[:2] - rr[:2]) / np.linalg.norm(rr), 0.0, 1e-10, "hapsira farnocchia", floor=1.0)
        # P' = F P F^T + Q, Q the continuous white-noise-acceleration model (Bar-Shalom et al. 2001 sec. 6.2.2; Labbe, Kalman and Bayesian Filters in Python, ch. 7)
        q = c["accel_noise"] ** 2
        Qf = Q_continuous_white_noise(dim=2, dt=dt, spectral_density=q, block_size=2)  # order x, vx, y, vy
        Q = np.empty((4, 4))
        order = [0, 2, 1, 3]  # filterpy index of game index i
        for i in range(4):
            for j in range(4):
                Q[i, j] = Qf[order[i], order[j]]
        P_ref = F_ref @ np.array(c["P0"]) @ F_ref.T + Q
        check.rel(f"covariance prediction {dt / 3600:g} h", np.linalg.norm(np.array(c["P"]) - P_ref) / np.linalg.norm(P_ref), 0.0, 1e-4,
                  "F P F^T + Q with filterpy Q_continuous_white_noise", floor=1.0)


def test_cross_fix(game, check):
    w, wcov = 0.0, 0.0
    for c in game["tracking"]["cross_fix"]:
        lines = c["in"]["lines"]
        def res(p):
            return [(-math.sin(l["bearing"]) * (p[0] - l["from"][0]) + math.cos(l["bearing"]) * (p[1] - l["from"][1])) / (l["sigma"] * 1e5) for l in lines]
        sol = least_squares(res, x0=np.array(lines[0]["from"][:2]) + 1.0, xtol=1e-15, ftol=1e-15, gtol=1e-15)
        w = max(w, np.linalg.norm(np.array(c["r"])[:2] - sol.x))
        w = max(w, np.linalg.norm(np.array(c["r"])[:2] - c["in"]["target"]))
        # Fisher information of the lines at their true distances
        I = np.zeros((2, 2))
        for l in lines:
            n = np.array([-math.sin(l["bearing"]), math.cos(l["bearing"])])
            rr = max(1000.0, np.linalg.norm(sol.x - l["from"][:2]))
            I += np.outer(n, n) / (l["sigma"] * rr) ** 2
        wcov = max(wcov, np.linalg.norm(np.array(c["P2"]) - np.linalg.inv(I)) / np.linalg.norm(np.linalg.inv(I)))
    check.bound(f"bearing-line fix, {len(game['tracking']['cross_fix'])} noiseless cases", w, 1e-3, "scipy.optimize.least_squares, and the true target", unit="km")
    check.bound("fix covariance = inverse Fisher information", wcov, 1e-9, "Cramer-Rao bound for crossing bearings (Poisel 2012; AoA Fisher information, Herath & Pathirana 2013, Sensors 13:12277)")
