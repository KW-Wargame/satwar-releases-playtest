# xGEO Core: fidelity of each model

Every model and value in xGEO Core carries one of three labels
(docs/XGEO.md):

- **Real:** sourced and checked against an independent reference
  ([PHYSICS-VERIFICATION.md](PHYSICS-VERIFICATION.md)).
- **Projected:** near-future, grounded in programmes that exist today.
- **Notional:** invented for a scenario, the way studies fly notional systems.

A Real model can be fed Notional inputs: the radar equation is Real, a Red
jammer's power is Notional, and the range it yields is only as good as both.

| Model | File | Label | Checked against | What it leaves out |
|---|---|---|---|---|
| Two-body motion | `kepler.gd` | Real | hapsira, DOP853; Curtis and Vallado worked examples | nothing within two-body |
| Lambert intercepts | `lambert.gd` | Real | hapsira `izzo`; Curtis Ex. 5.2 | multi-revolution solutions |
| Gravity: Jupiter J2 and the Galilean moons | `gravity.gd` | Real | hapsira J2 and third-body terms; DOP853 | higher harmonics (J4 and up), Sun and Saturn, relativity, radiation pressure |
| Moon positions | `gravity.gd`, `ephem.gd` | Real, simplified | JPL Horizons, 2036–2046 | planar mean elements, no mutual perturbations: up to 23,000 km and 0.72° off |
| Sun and planets | `ephem.gd` | Real | JPL approximate positions (Standish & Williams 1992) | arc-minute accuracy only |
| Propagation overall | `sim.gd` | Real, not operational | RK4 against DOP853 at 60 s steps | not the high-fidelity propagation used in operations |
| Radio link budgets, noise, integration | `rf.gd` | Real | ITU-R P.525, published examples | atmospheric and plasma effects, multipath |
| Antenna patterns | `antenna.gd` | Real | ITU-R reference patterns | real dishes' measured patterns |
| Radar range equation | `rf.gd` | Real | radar handbooks (REALISM-SOURCES) | clutter, Swerling fluctuation beyond the stated case |
| Direction finding | `sensing.gd` | Real | interferometer accuracy formula | multipath, calibration errors |
| Jamming (J/S, spot and barrage) | `effects.gd`, `rf.gd` | Real equations, Notional powers | jamming equation; powers are design values | effect is binary (cut or not), Red does not hop or null |
| Heat and infrared | `thermal.gd` | Real | Stefan–Boltzmann, Planck band fractions | Jupiter as a grey body, zodiacal background not verified at 5.2 AU |
| Heat forecast | `forecast.gd` | Real model, Notional thresholds | the same IR look as `sensing.gd` | |
| Tracking filter | `tracking.gd` | Real | filterpy; consistency (NEES) over many runs | data association is by truth id; drop thresholds are design values |
| Breakup and debris | `breakup.gd` | Real | NASA Standard Breakup Model | long-term debris evolution |
| Component damage | `damage.gd` | Notional | | |
| Nuclear-thermal drives at 900 s | `game.json` classes | Projected | NASA tested specific impulse | |
| Ship classes, equipment sizes | `game.json`, `campaign.json` | Notional | sizes are design values; performance follows the physics | |
| Red's behaviour | `red_ai.gd` | Notional | | does not adapt by hopping, nulling or optical links |
| Escalation scores, objectives | `effects.gd`, `campaign.gd` | Notional | | |
| Civil radio traffic | `traffic.gd` | Notional | | |
| Timescale (weeks compressed to days) | `campaign.json` | Notional | | |

Run the checks: `node tools/godot.mjs test` (the game's own tests) and
`node tools/godot.mjs verify` (every number against independent references).
