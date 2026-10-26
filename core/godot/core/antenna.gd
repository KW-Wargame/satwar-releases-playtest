## Dish antenna gain off boresight, from the ITU-R reference patterns
## (docs/REALISM-SOURCES.md §1). The same function serves every emitter, ear,
## jammer and jamming victim, so geometry decides what is heard and what is jammed.
##
## - Peak gain G0 = η(πD/λ)² and the main lobe G0 − 3(φ/φ0)², with the 3 dB
##   half-width φ0 = 20√3/(D/λ) degrees (ITU-R SA.509-3 §1.1, §1.3; full width ≈ 69.3λ/D).
## - Large dishes (D/λ ≥ 100): the SA.509-3 single-entry pattern exactly:
##   G0 − 17 out to φ2 = 10^((49 − G0)/25), then 32 − 25 log φ to 48°,
##   −10 dBi to 80°, −5 dBi (spillover) to 120°, −10 dBi behind. SA.509-3 is
##   stated for about 1–30 GHz; at the 32 GHz Ka crosslink it is extrapolated.
## - Smaller dishes (D/λ < 100): ITU-R S.465-5 Note 4 (stated for networks
##   coordinated before 1993; the game adopts it for every small dish), 52 − 10 log(D/λ) − 25 log φ
##   from φmin = 100λ/D to 48°, then 10 − 10 log(D/λ) to 180°. S.465 gives no main
##   lobe, so inside φmin the gain is the SA.509 main lobe, held at no less than
##   the envelope's value at φmin (a shoulder, as SA.509's own G0 − 17 step is).
##   That join is ours; both curves it joins are ITU's.
## These are envelopes of sidelobe peaks used for interference coordination: an
## upper bound for a well-made dish (SA.509-3 considering b, c). The user chose them
## over any assumed low-sidelobe margin, since real military patterns aren't public.
class_name Antenna
extends RefCounted

const ETA := 0.55 # aperture efficiency, as RF.dish_gain


static func d_over_lambda(D: float, f: float) -> float:
	return D / RF.wavelength(f)


## Peak gain (dBi).
static func peak_dbi(D: float, f: float, eta := ETA) -> float:
	return RF.db(RF.dish_gain(D, f, eta))


## Full 3 dB beamwidth (rad): 2φ0 = 40√3/(D/λ) degrees ≈ 69.3λ/D.
static func beamwidth(D: float, f: float) -> float:
	return deg_to_rad(40.0 * sqrt(3.0) / d_over_lambda(D, f))


## Gain (dBi) at angle phi (rad) off boresight.
static func gain_dbi(D: float, f: float, phi: float, eta := ETA) -> float:
	var dl := d_over_lambda(D, f)
	var g0 := peak_dbi(D, f, eta)
	var p := rad_to_deg(absf(phi))
	if p > 180.0:
		p = 360.0 - p
	var phi0 := 20.0 * sqrt(3.0) / dl
	var main := g0 - 3.0 * (p / phi0) * (p / phi0)
	if dl >= 100.0:
		var phi1 := phi0 * sqrt(17.0 / 3.0)
		var phi2 := pow(10.0, (49.0 - g0) / 25.0)
		if p < phi1:
			return main
		if p < phi2:
			return g0 - 17.0
		if p < 48.0:
			return 32.0 - 25.0 * log(p) / log(10.0)
		if p < 80.0:
			return -10.0
		if p < 120.0:
			return -5.0
		return -10.0
	var ldl := log(dl) / log(10.0)
	var pmin := 100.0 / dl
	if p < pmin:
		return minf(g0, maxf(main, _s465(ldl, pmin)))
	return _s465(ldl, p)


## S.465-5 Note 4 envelope at p degrees (p ≥ 100λ/D).
static func _s465(ldl: float, p: float) -> float:
	if p < 48.0:
		return 52.0 - 10.0 * ldl - 25.0 * log(p) / log(10.0)
	return 10.0 - 10.0 * ldl


## Angle (rad) at `at` between the directions to a and to b (planar or 3-D).
static func angle_at(at: PackedFloat64Array, a: PackedFloat64Array, b: PackedFloat64Array) -> float:
	var u := V.sub(a, at)
	var w := V.sub(b, at)
	var nu := V.norm(u)
	var nw := V.norm(w)
	if nu < 1e-9 or nw < 1e-9:
		return 0.0
	return acos(clampf(V.dot(u, w) / (nu * nw), -1.0, 1.0))
