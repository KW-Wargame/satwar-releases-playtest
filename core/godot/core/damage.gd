## Partial damage: a ship that survives a hit (a non-catastrophic collision,
## Breakup) loses the components the hit and its spall reached. Each one is a
## tag in s.damage; the ship's working class (s.cls) is its class with those
## components taken out, so every system that reads the class (burns, sensing,
## heat, effects) sees the loss without knowing about damage.
class_name Damage

## What each tag means, for the log and the Details window.
const NAMES := {"engine": "main engine", "tank": "propellant tank", "radiator": "radiator", "telescope": "telescope",
	"laser": "laser", "interceptors": "interceptor launcher", "ttc": "command antenna", "radar": "radar", "esm": "ES antenna",
	"datalink": "datalink", "cargo": "cargo pod", "structure": "structure"}


## The class as damaged by tags: a deep copy with the struck systems removed.
## A struck radiator loses half its area per hit (design value).
static func cls_for(base: Dictionary, tags: Array) -> Dictionary:
	if tags.is_empty():
		return base
	var c: Dictionary = base.duplicate(true)
	for t in tags:
		match String(t):
			"engine":
				c.erase("engine")
			"telescope":
				c.erase("ir")
				c.erase("optical")
			"laser":
				if c.get("weapon", {}).get("kind", "") == "laser":
					c.erase("weapon")
			"ttc", "radar", "esm", "datalink":
				c.erase(String(t))
			"radiator":
				if c.get("thermal", {}).has("radiator"):
					c.thermal.radiator.A = float(c.thermal.radiator.A) * 0.5
	return c


## Apply new tags to a ship: its state (propellant vented, launcher wrecked)
## and its working class.
static func apply(s: Dictionary, base: Dictionary, tags: Array) -> void:
	var all: Array = s.get("damage", [])
	for t in tags:
		all.append(t)
		match String(t):
			"tank":
				s.prop = 0.0 # a holed tank vents (design value: all of it)
			"interceptors":
				s.rounds = 0
	s.damage = all
	s.cls = cls_for(base, all)


## Radiative cooling of a hot body of radiating area-to-mass a (m²/kg) from
## T0 (K), t seconds on, in the dark: m·c·dT/dt = −εσ·a·m·T⁴, so
## T = (T0⁻³ + 3εσ·a·t/c)^(−1/3). It never cools below floor (what sunlight
## and its own leak hold it at).
static func cool(T0: float, a: float, t: float, floor_T := 0.0, eps := 0.8, c := C_AL) -> float:
	var T := pow(pow(T0, -3.0) + 3.0 * eps * Thermal.SIGMA * a * maxf(t, 0.0) / c, -1.0 / 3.0)
	return maxf(T, floor_T)


## The hot metal a hit leaves. Aluminium: specific heat 897 J/(kg·K) at 298 K
## (NIST-JANAF, Chase 1998), melts at 933 K (CRC Handbook of Chemistry and Physics). A hypervelocity crater's
## lining is melted, so it starts at the melting point; the struck skin is a
## 2 mm sheet radiating from both faces, a = 2/(ρ·t) (design value), and the
## glowing patch is CRATER_M across (design value).
const C_AL := 897.0
const T_MELT_AL := 933.0
const RHO_AL := 2700.0
const SKIN_M := 0.002
const CRATER_M := 1.5


static func crater_T(age: float, floor_T: float) -> float:
	return cool(T_MELT_AL, 2.0 / (RHO_AL * SKIN_M), age, floor_T)


## A fragment's temperature: the SBM gives its A/m with A its mean cross-section;
## a convex body's surface is four times that (Cauchy), and it starts molten.
static func fragment_T(am: float, age: float, floor_T: float) -> float:
	return cool(T_MELT_AL, 4.0 * am, age, floor_T)


## A radiation-cooled nozzle after shutdown: niobium C-103, specific heat
## 265 J/(kg·K), density 8,570 kg/m³ (CRC), a 1 mm wall radiating from both
## faces (design value), from its running temperature.
static func nozzle_T(T_hot: float, since_off: float, floor_T: float, eps := 0.85) -> float:
	return cool(T_hot, 2.0 / (8570.0 * 0.001), since_off, floor_T, eps, 265.0)


static func describe(tags: Array) -> String:
	var names := []
	for t in tags:
		var n: String = NAMES.get(String(t), String(t))
		if not names.has(n):
			names.append(n)
	return ", ".join(names)
