## Lambert's problem: the orbit joining r1 to r2 in a given time of flight.
## Universal-variable method of Curtis (2020) Algorithm 5.2, solved by
## bisection on z so it cannot diverge. Single revolution, prograde. A port of
## src/engine/lambert.js, tested against it and against Izzo's independent
## solver (Izzo 2015, CMDA 121:1–15).
##
## Lambert is exact for Jupiter alone. Under real gravity (J2 and the moons)
## a transfer drifts off its aim, which is why ships fly correction burns.
class_name Lambert


## Returns [v1, v2], or [] when no single-revolution transfer exists.
static func solve(r1: PackedFloat64Array, r2: PackedFloat64Array, tof: float, mu: float, prograde := true) -> Array:
	var r1n := V.norm(r1)
	var r2n := V.norm(r2)
	var cos_t := clampf(V.dot(r1, r2) / (r1n * r2n), -1.0, 1.0)
	var theta := acos(cos_t)
	var cz := V.cross(r1, r2)[2]
	if (cz < 0.0) if prograde else (cz >= 0.0):
		theta = TAU - theta
	if absf(1.0 - cos(theta)) < 1e-10:
		return []
	var A := sin(theta) * sqrt(r1n * r2n / (1.0 - cos(theta)))
	var sqmu := sqrt(mu)
	var y := func(z: float) -> float:
		return r1n + r2n + A * (z * Kepler.stumpff_s(z) - 1.0) / sqrt(Kepler.stumpff_c(z))
	var time_of := func(z: float) -> float:
		var yz: float = y.call(z)
		if yz <= 0.0:
			return -INF
		return (pow(yz / Kepler.stumpff_c(z), 1.5) * Kepler.stumpff_s(z) + A * sqrt(yz)) / sqmu
	var hi := 4.0 * PI * PI * (1.0 - 1e-9)
	var lo := -4.0
	while time_of.call(lo) > tof and lo > -1e6:
		lo *= 2.0
	if time_of.call(lo) > tof or time_of.call(hi) < tof:
		return []
	for i in 200:
		var mid := (lo + hi) / 2.0
		if time_of.call(mid) < tof:
			lo = mid
		else:
			hi = mid
		if hi - lo < 1e-12:
			break
	var z := (lo + hi) / 2.0
	if not (absf(time_of.call(z) - tof) < 1e-6 * tof + 1e-3):
		return []
	var yz: float = y.call(z)
	var f := 1.0 - yz / r1n
	var g := A * sqrt(yz / mu)
	var gdot := 1.0 - yz / r2n
	return [V.scale(V.sub(r2, V.scale(r1, f)), 1.0 / g), V.scale(V.sub(V.scale(r2, gdot), r1), 1.0 / g)]
