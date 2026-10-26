"""Shared fixtures for the physics verification suite.

The suite never re-derives the game's numbers: it loads what the game itself
computed (tools/verify/out/game_physics.json, written by
godot/tests/dump_physics.gd) and compares each value with an independent
reference: a maintained library (hapsira, scipy, astropy, filterpy), JPL data
(fixtures/, fetched by fetch_fixtures.py), a published worked example, or a
Monte Carlo of the physical process.

Every comparison is recorded with its tolerance; the terminal summary prints
the whole table and writes out/results.json and out/results.md.
"""
import json
import math
import pathlib

import numpy as np
import pytest

HERE = pathlib.Path(__file__).resolve().parent
OUT = HERE / "out"
FIX = HERE / "fixtures"
RESULTS = []


def load(path):
    return json.loads(pathlib.Path(path).read_text(encoding="utf-8"))


@pytest.fixture(scope="session")
def game():
    p = OUT / "game_physics.json"
    if not p.exists():
        pytest.exit("tools/verify/out/game_physics.json is missing: run `node tools/godot.mjs verify` (it dumps the game's physics first).", 2)
    return load(p)


@pytest.fixture(scope="session")
def horizons():
    return load(FIX / "horizons_moons.json")


@pytest.fixture(scope="session")
def sun_earth():
    return load(FIX / "horizons_sun_earth.json")


@pytest.fixture(scope="session")
def jpl_elements():
    return load(FIX / "jpl_sat_elem.json")["elements"]


@pytest.fixture(scope="session")
def published():
    return load(FIX / "published_values.json")


class Checker:
    """Collects comparisons for one test; fails the test at the end if any is out of tolerance."""

    def __init__(self, test_name, model):
        self.test = test_name
        self.model = model
        self.failures = []

    def _rec(self, name, err, tol, kind, ok, got, ref, ref_name, note):
        RESULTS.append({"model": self.model, "test": self.test, "check": name, "error": err, "tol": tol, "kind": kind, "ok": bool(ok),
                        "got": got, "ref": ref, "reference": ref_name, "note": note})
        if not ok:
            self.failures.append(f"{name}: {kind} error {err:.3g} > tol {tol:.3g} (game {got!r}, reference {ref!r})")

    def rel(self, name, got, ref, tol, reference="", note="", floor=1e-300):
        """Largest relative error over (arrays of) values."""
        g = np.atleast_1d(np.asarray(got, dtype=float))
        r = np.atleast_1d(np.asarray(ref, dtype=float))
        err = float(np.max(np.abs(g - r) / np.maximum(np.abs(r), floor))) if g.size else 0.0
        self._rec(name, err, tol, "rel", err <= tol, _short(got), _short(ref), reference, note)
        return err

    def abs(self, name, got, ref, tol, reference="", note="", unit=""):
        g = np.atleast_1d(np.asarray(got, dtype=float))
        r = np.atleast_1d(np.asarray(ref, dtype=float))
        err = float(np.max(np.abs(g - r))) if g.size else 0.0
        self._rec(name, err, tol, "abs" + (f" {unit}" if unit else ""), err <= tol, _short(got), _short(ref), reference, note)
        return err

    def true(self, name, ok, reference="", note="", got=None, ref=None):
        self._rec(name, 0.0 if ok else 1.0, 0.0, "bool", ok, got, ref, reference, note)

    def bound(self, name, value, limit, reference="", note="", unit=""):
        """A documented simplification: value must stay within its stated bound."""
        self._rec(name, float(value), float(limit), "bound" + (f" {unit}" if unit else ""), value <= limit, _short(value), _short(limit), reference, note)

    def info(self, name, value, reference="", note="", unit=""):
        """A known simplification that is due to be replaced: measured and reported, not judged."""
        RESULTS.append({"model": self.model, "test": self.test, "check": name, "error": float(value), "tol": float("nan"), "kind": "info" + (f" {unit}" if unit else ""),
                        "ok": True, "got": _short(value), "ref": None, "reference": reference, "note": note, "info": True})


def _short(x):
    if isinstance(x, (list, tuple, np.ndarray)):
        a = np.asarray(x, dtype=float).ravel()
        return [float(f"{v:.6g}") for v in a[:3]] + (["..."] if a.size > 3 else [])
    if isinstance(x, (float, np.floating)):
        return float(f"{float(x):.8g}")
    return x


@pytest.fixture
def check(request):
    model = getattr(request.module, "MODEL", request.module.__name__)
    return Checker(request.node.name, model)


@pytest.hookimpl(hookwrapper=True)
def pytest_runtest_call(item):
    outcome = yield
    c = getattr(item, "funcargs", {}).get("check")
    if c is not None and c.failures and outcome.excinfo is None:
        outcome.force_exception(AssertionError("out of tolerance:\n  " + "\n  ".join(c.failures)))


def pytest_terminal_summary(terminalreporter, exitstatus, config):
    if not RESULTS:
        return
    OUT.mkdir(exist_ok=True)
    (OUT / "results.json").write_text(json.dumps(RESULTS, indent=1, default=str), encoding="utf-8")
    tr = terminalreporter
    tr.section("SATWAR physics verification")
    w = max(len(r["check"]) for r in RESULTS)
    w = min(w, 58)
    tr.write_line(f"{'model':<14} {'check':<{w}} {'error':>10} {'tol':>9}  {'kind':<9} result")
    lines = ["| Model | Check | Error | Tolerance | Kind | Result | Reference |", "|---|---|---|---|---|---|---|"]
    npass = ninfo = 0
    for r in RESULTS:
        info = r.get("info", False)
        res = "INFO" if info else "PASS" if r["ok"] else "FAIL"
        npass += r["ok"] and not info
        ninfo += info
        tol = "-" if info else f"{r['tol']:.3g}"
        tr.write_line(f"{r['model'][:14]:<14} {r['check'][:w]:<{w}} {r['error']:>10.3g} {tol:>9}  {r['kind'][:9]:<9} {res}", red=not r["ok"], green=r["ok"] and not info, yellow=info)
        lines.append(f"| {r['model']} | {r['check']} | {r['error']:.3g} | {tol} | {r['kind']} | {res} | {r['reference']} |")
    tr.write_line(f"{npass} of {len(RESULTS) - ninfo} comparisons within tolerance; {ninfo} known simplifications reported (INFO)")
    (OUT / "results.md").write_text("\n".join(lines) + "\n", encoding="utf-8")


# ---------------------------------------------------------------------------
# Small helpers used by several test files.

def wrap(a):
    return (a + math.pi) % (2 * math.pi) - math.pi


def jupiter_equator_frame(ra_deg, dec_deg):
    """Rows: x toward the ascending node of Jupiter's equator on the ICRF equator, z the pole."""
    ra, dec = math.radians(ra_deg), math.radians(dec_deg)
    z = np.array([math.cos(dec) * math.cos(ra), math.cos(dec) * math.sin(ra), math.sin(dec)])
    x = np.cross([0.0, 0.0, 1.0], z)
    x /= np.linalg.norm(x)
    return np.array([x, np.cross(z, x), z])
