## Real gravity for everything that coasts: Jupiter as an oblate body (point
## mass plus its J2 zonal harmonic) and the pull of the four Galilean moons.
##
## - J2 = 14696.514e-6 at reference radius 71,492 km, measured from Juno's
##   first orbits: Folkner, W. M. et al. (2017), "Jupiter gravity field
##   estimated from the first two Juno orbits", Geophys. Res. Lett. 44,
##   4694–4700, Table 2 (also tabulated in A&A 613, A32, 2018, Table 1).
## - The J2 acceleration is the gradient of the zonal potential term
##   −μJ2R²(3z²−r²)/(2r⁵); in the equatorial plane it is purely radial,
##   −(3/2)μJ2R²/r⁴ (Vallado 2013, Fundamentals of Astrodynamics, §8.6; corroborated
##   by hapsira's J2_perturbation, which the repo test matches to 9e-11).
## - The moons act as third bodies. The frame is centred on Jupiter, which the
##   moons also pull, so each moon adds its direct pull minus the pull it
##   gives Jupiter (the "indirect" term): μm[(rm−r)/|rm−r|³ − rm/|rm|³]
##   (Curtis 2020, ch. 10; Montenbruck & Gill 2000, §3.3; corroborated by
##   NASA/TP-20220014814, §7.1, Eq. 117).
## - The Sun and the eight planets act the same way, from JPL's approximate
##   planetary positions (ephem.gd), GMs from DE440: the Sun everywhere (its
##   tide moves a ship near Ganymede ~10 km in three days), the planets once a
##   ship is out past the Galilean system (FAR), where their pull can matter;
##   inside it their tides are below 1e-12 km/s² (under 1e-7 of Jupiter's pull). So a ship can leave Jupiter
##   and fly to Mars or Earth in the same frame, no patching of conics: Cowell's
##   method in a Jupiter-centred frame (Montenbruck & Gill 2000, §3.3;
##   NASA/TP-20220014814, §7.1).
## The moons' own motion is the JPL mean-element ephemeris (moons.gd).
## Integrated by classical fourth-order Runge–Kutta: inside FAR in the fixed
## steps asked for; beyond it in steps of ETA × the shortest local orbital
## time sqrt(d³/μ) over the bodies (a standard step control for few-body
## problems; Aarseth 2003, Gravitational N-Body Simulations, ch. 2, time-step
## criteria; corroborated by Pelupessy et al. 2012, New Astron. 17:711, Eq. 13).
class_name Gravity

const J2 := 14696.514e-6
const R_REF := 71492.0
const FAR := 3.0e6 # km from Jupiter: past Callisto (1.88e6) the planets join in
const ETA := 0.004

var mu: float
var moons: Array # of Dictionary (with gm)
var moon_state: Callable # (id, t) -> [r, v]
var use_j2 := true
var use_moons := true
var use_sun := true
var utc_of: Callable # (t) -> UTC ms; unset, no Sun or planets


func _init(mu_: float, moons_: Array, moon_state_: Callable) -> void:
	mu = mu_
	moons = moons_
	moon_state = moon_state_


## Acceleration (km/s²) at position r and sim time t.
func accel(r: PackedFloat64Array, t: float) -> PackedFloat64Array:
	var r2 := V.dot(r, r)
	var rn := sqrt(r2)
	var a := V.scale(r, -mu / (r2 * rn))
	if use_j2:
		var z2 := r[2] * r[2] / r2
		var k := -1.5 * J2 * mu * R_REF * R_REF / (r2 * r2 * rn)
		a = V.add(a, V.of(k * r[0] * (1.0 - 5.0 * z2), k * r[1] * (1.0 - 5.0 * z2), k * r[2] * (3.0 - 5.0 * z2)))
	if use_moons:
		for m in moons:
			var rm: PackedFloat64Array = moon_state.call(m.id, t)[0]
			var d := V.sub(rm, r)
			var dn := V.norm(d)
			var rmn := V.norm(rm)
			var gm: float = m.gm
			a = V.add(a, V.sub(V.scale(d, gm / (dn * dn * dn)), V.scale(rm, gm / (rmn * rmn * rmn))))
	if use_sun and utc_of.is_valid():
		var ms: float = utc_of.call(t)
		a = V.add(a, _third(r, _sun_at(t, ms), Ephem.GM_SUN))
		if rn > FAR:
			for b in Ephem.PLANETS:
				if b != "jupiter":
					a = V.add(a, _third(r, Ephem.pos(b, ms), float(Ephem.BODY[b].gm)))
	return a


## The Sun for this instant: every ship in a tick asks at the same RK4 times.
var _sun_memo := {}


func _sun_at(t: float, ms: float) -> PackedFloat64Array:
	if _sun_memo.has(t):
		return _sun_memo[t]
	if _sun_memo.size() > 64:
		_sun_memo.clear()
	var p := Ephem.pos("sun", ms)
	_sun_memo[t] = p
	return p


## A third body at rb: its pull on the ship less its pull on Jupiter.
static func _third(r: PackedFloat64Array, rb: PackedFloat64Array, gm: float) -> PackedFloat64Array:
	var d := V.sub(rb, r)
	var dn := V.norm(d)
	var bn := V.norm(rb)
	return V.sub(V.scale(d, gm / (dn * dn * dn)), V.scale(rb, gm / (bn * bn * bn)))


## The longest step that stays accurate at r (beyond FAR): ETA × the shortest
## sqrt(d³/μ) over Jupiter, the Sun and the planets.
func step_limit(r: PackedFloat64Array, t: float) -> float:
	var rn := V.norm(r)
	var best := sqrt(rn * rn * rn / mu)
	if utc_of.is_valid():
		var ms: float = utc_of.call(t)
		var ds := V.dist(r, Ephem.pos("sun", ms))
		best = minf(best, sqrt(ds * ds * ds / Ephem.GM_SUN))
		for b in Ephem.PLANETS:
			if b != "jupiter":
				var d := V.dist(r, Ephem.pos(b, ms))
				best = minf(best, sqrt(d * d * d / float(Ephem.BODY[b].gm)))
	return ETA * best


## One RK4 step of length h from (r, v) at time t. Returns [r, v].
func step(r: PackedFloat64Array, v: PackedFloat64Array, t: float, h: float) -> Array:
	var k1v := accel(r, t)
	var k1r := v
	var r2 := V.add(r, V.scale(k1r, h / 2.0))
	var v2 := V.add(v, V.scale(k1v, h / 2.0))
	var k2v := accel(r2, t + h / 2.0)
	var k2r := v2
	var r3 := V.add(r, V.scale(k2r, h / 2.0))
	var v3 := V.add(v, V.scale(k2v, h / 2.0))
	var k3v := accel(r3, t + h / 2.0)
	var k3r := v3
	var r4 := V.add(r, V.scale(k3r, h))
	var v4 := V.add(v, V.scale(k3v, h))
	var k4v := accel(r4, t + h)
	var k4r := v4
	var rn := V.add(r, V.scale(V.add(V.add(k1r, V.scale(k2r, 2.0)), V.add(V.scale(k3r, 2.0), k4r)), h / 6.0))
	var vn := V.add(v, V.scale(V.add(V.add(k1v, V.scale(k2v, 2.0)), V.add(V.scale(k3v, 2.0), k4v)), h / 6.0))
	return [rn, vn]


## Coast for dt seconds (either sign) in steps no longer than max_h.
## Beyond FAR the steps grow (and shrink again near a planet) with step_limit.
func coast(r: PackedFloat64Array, v: PackedFloat64Array, t: float, dt: float, max_h := 60.0) -> Array:
	var n := maxi(1, ceili(absf(dt) / max_h))
	var h := dt / n
	var s := [r, v]
	for i in n:
		if V.norm(s[0]) > FAR:
			return _coast_far(s[0], s[1], t + i * h, dt - i * h, max_h)
		s = step(s[0], s[1], t + i * h, h)
	return s


func _coast_far(r: PackedFloat64Array, v: PackedFloat64Array, t: float, dt: float, max_h: float) -> Array:
	var s := [r, v]
	var done := 0.0
	var sg := signf(dt)
	var left := absf(dt)
	while left > 1e-9:
		var lim := maxf(max_h, step_limit(s[0], t + done)) if V.norm(s[0]) > FAR else max_h
		var h := minf(left, lim)
		s = step(s[0], s[1], t + done, sg * h)
		done += sg * h
		left -= h
	return s
