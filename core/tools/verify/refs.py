"""Reference models built from independent libraries (hapsira, scipy).

The one exception is `game_moon_state`, a transcription of the game's
mean-element moon model. It is needed only so the reference integrator can
feel the same moons the game does (the integrator test is about integration
error, not about the ephemeris), and test_gravity.py checks it against the
game's own moon states before using it. The ephemeris itself is checked
against JPL Horizons in test_moons.py.
"""
import math

import numpy as np
from hapsira.core.perturbations import J2_perturbation, third_body
from scipy.integrate import solve_ivp


def game_moon_state(m, t_elem):
    """Planar Kepler ellipse from the game's mean elements at t_elem s after J2000."""
    a, e = m["a"], m["e"]
    n_lam = 2 * math.pi / (m["observedPeriodDays"] * 86400.0)
    n = 2 * math.pi / (m["anomalisticPeriodDays"] * 86400.0)
    wdot = n_lam - n
    M = math.radians(m["M"]) + n * t_elem
    E = M
    for _ in range(50):
        E -= (E - e * math.sin(E) - M) / (1 - e * math.cos(E))
    varpi = math.radians(m["node"] + m["w"]) + wdot * t_elem
    px, py = a * (math.cos(E) - e), a * math.sqrt(1 - e * e) * math.sin(E)
    c, s = math.cos(varpi), math.sin(varpi)
    return np.array([px * c - py * s, px * s + py * c, 0.0])


def accel(r, t, mu, J2, R, moons, epoch_offset, j2=True, use_moons=True):
    """Point mass + hapsira's J2 term + hapsira's third-body term for each moon."""
    r = np.asarray(r, dtype=float)
    state = np.concatenate([r, np.zeros(3)])
    a = -mu * r / np.linalg.norm(r) ** 3
    if j2:
        a = a + J2_perturbation(t, state, mu, J2, R)
    if use_moons:
        for m in moons:
            a = a + third_body(t, state, mu, m["gm"], lambda tt, m=m: game_moon_state(m, epoch_offset + tt))
    return a


def integrate(r0, v0, t0, dt, mu, J2, R, moons, epoch_offset, j2=True, use_moons=True, t_eval=None, rtol=1e-13, atol=1e-9):
    """scipy DOP853 (Hairer, Nørsett & Wanner 1993) at tight tolerances."""
    def f(t, y):
        return np.concatenate([y[3:], accel(y[:3], t, mu, J2, R, moons, epoch_offset, j2, use_moons)])
    sol = solve_ivp(f, (t0, t0 + dt), np.concatenate([r0, v0]), method="DOP853", rtol=rtol, atol=atol, t_eval=t_eval, dense_output=False)
    assert sol.success, sol.message
    return sol


def two_body_stm(x, dt, mu):
    """Planar two-body state-transition matrix from the variational equations, integrated by DOP853."""
    def f(t, y):
        r = y[:2]
        rn = np.linalg.norm(r)
        G = mu * (3 * np.outer(r, r) / rn ** 5 - np.eye(2) / rn ** 3)
        A = np.block([[np.zeros((2, 2)), np.eye(2)], [G, np.zeros((2, 2))]])
        Phi = y[4:].reshape(4, 4)
        return np.concatenate([y[2:4], -mu * r / rn ** 3, (A @ Phi).ravel()])
    y0 = np.concatenate([x, np.eye(4).ravel()])
    sol = solve_ivp(f, (0, dt), y0, method="DOP853", rtol=1e-12, atol=1e-12)
    return sol.y[4:, -1].reshape(4, 4), sol.y[:4, -1]
