## Tracking: what Blue believes about a target, never the truth itself.
## A port of src/engine/tracking.js. State x = [x, y, vx, vy] (km, km/s).
## - The mean coasts on the two-body solution; the covariance moves with a
##   state-transition matrix from finite differences of that same solution
##   (Bar-Shalom, Li & Kirubarajan 2001, ch. 6; Labbe, Kalman and Bayesian
##   Filters in Python, ch. 7).
## - Measurements (bearings, ranges) fold in by an unscented update (Julier &
##   Uhlmann 2004): sample points spread by the covariance are pushed through
##   the true, curved measurement function.
## - The estimate's mean coasts on the full force model (Jupiter with J2 and
##   the four moons), as real orbit determination does; the covariance moves
##   with a two-body transition matrix, an approximation that is standard
##   practice. Process noise covers what neither models: small unseen pushes.
## - New tracks start from crossing bearings: a least-squares fix from two or
##   more lines taken at nearly the same time.
class_name Track
extends RefCounted

const MU := 126.687e6
static var gravity: Gravity # the world's force model, set by Sim
var id: String # the truth it follows (sim uses it only to name the track)
var label: String
var x: PackedFloat64Array
var P: Array # 4×4, rows of PackedFloat64Array
var t: float
## Past this 1σ / range, a bearing is too curved for the unscented update (design value).
const CURVED := 0.1
## Bearings alone don't tell how far: between two craft in nearly the same
## orbit (linearised relative motion), angles-only range can't be observed unless the observer manoeuvres
## (Woffinden & Geller 2009, IEEE Trans. AES 45(3)). So close in, without a
## recent range, the estimate keeps at least this 1σ along the line of sight,
## as a share of the range (design value, from the shadowing's own runs: the
## range error held near 0.37 of the range). A radar range lifts it.
const RANGE_FLOOR := 0.5
const RANGED_FOR := 1800.0 # s a range measurement counts as recent
## Manoeuvre detection by the innovation (Bar-Shalom, Li & Kirubarajan 2001,
## ch. 11; Labbe, ch. 14): a bearing whose normalised innovation squared passes the χ²(1)
## 99.9% point (10.83) is taken as a burn nobody saw; the track widens as for
## a burn of up to MANEUVER_DV (km/s) in the last look (design values).
const MANEUVER_GATE := 10.83
const MANEUVER_DV := 0.05
const MANEUVER_SINCE := 600.0
var unseen_burns := 0
var ranged_at := -INF
var accel_noise := 6e-7 # km/s²: covers the two-body covariance approximation and small unseen pushes (tuned on the retired NIGHT HERON campaign test)
var ident := "unknown" # unknown → classified → identified
var seen_id := false # named by a telescope (the hull seen): ident "identified"
var heard_id := false # its signal matched in the threat library: its uplink is known
var class_id := ""
var side := "unknown"
var last_seen := 0.0
var lkp := PackedFloat64Array() # last known position: the estimate when it was last detected (km)
var lkp_t := -1.0
var in_contact := false
var how := ""
var lobs: Array = [] # recent detections, for drawing: {t, from, bearing, kind (ir, vis, df, radar), by (sensor id), range (km, radar only), sigma (rad, df)}
var intercepts := 0 # strong recordings of its command link (for cyber)


func _init(id_: String, label_: String, x_: PackedFloat64Array, P_: Array, t_: float) -> void:
	id = id_
	label = label_
	x = x_
	P = P_
	t = t_
	lkp = pos()
	lkp_t = t_


static func coast(s: PackedFloat64Array, dt: float) -> PackedFloat64Array:
	var st := Kepler.propagate(V.of(s[0], s[1]), V.of(s[2], s[3]), dt, MU)
	return PackedFloat64Array([st[0][0], st[0][1], st[1][0], st[1][1]])


static func stm(s: PackedFloat64Array, dt: float) -> Array:
	var steps := [1.0, 1.0, 1e-4, 1e-4]
	var cols := []
	for j in 4:
		var up := s.duplicate()
		var dn := s.duplicate()
		up[j] += steps[j]
		dn[j] -= steps[j]
		var a := coast(up, dt)
		var b := coast(dn, dt)
		var c := PackedFloat64Array()
		for i in 4:
			c.append((a[i] - b[i]) / (2.0 * steps[j]))
		cols.append(c)
	var F := []
	for i in 4:
		var row := PackedFloat64Array()
		for j in 4:
			row.append(cols[j][i])
		F.append(row)
	return F


static func mul(A: Array, B: Array) -> Array:
	var out := []
	for i in A.size():
		var row := PackedFloat64Array()
		for j in B[0].size():
			var s := 0.0
			for k in B.size():
				s += A[i][k] * B[k][j]
			row.append(s)
		out.append(row)
	return out


static func transpose(A: Array) -> Array:
	var out := []
	for j in A[0].size():
		var row := PackedFloat64Array()
		for i in A.size():
			row.append(A[i][j])
		out.append(row)
	return out


static func diag(v: Array) -> Array:
	var out := []
	for i in v.size():
		var row := PackedFloat64Array([0.0, 0.0, 0.0, 0.0])
		row[i] = v[i]
		out.append(row)
	return out


## Move the estimate forward to time to.
## fast: coast the mean on Jupiter alone, for quick on-screen estimates
## (the filter itself always uses the full force model).
func predict(to: float, fast := false) -> void:
	var dt := to - t
	if dt <= 0.0:
		return
	var F := stm(x, dt)
	if gravity != null and not fast:
		var st := gravity.coast(V.of(x[0], x[1]), V.of(x[2], x[3]), t, dt, 120.0)
		x = PackedFloat64Array([st[0][0], st[0][1], st[1][0], st[1][1]])
	else:
		x = coast(x, dt)
	var q := accel_noise * accel_noise
	var d3 := dt * dt * dt / 3.0 * q
	var d2 := dt * dt / 2.0 * q
	var d1 := dt * q
	var Q := [PackedFloat64Array([d3, 0, d2, 0]), PackedFloat64Array([0, d3, 0, d2]), PackedFloat64Array([d2, 0, d1, 0]), PackedFloat64Array([0, d2, 0, d1])]
	var FP := mul(mul(F, P), transpose(F))
	for i in 4:
		for j in 4:
			FP[i][j] += Q[i][j]
	P = FP
	t = to


static func wrap_angle(a: float) -> float:
	return atan2(sin(a), cos(a))


static func cholesky(A: Array) -> Array:
	var n := A.size()
	var L := []
	for i in n:
		L.append(PackedFloat64Array([0.0, 0.0, 0.0, 0.0]))
	for i in n:
		for j in i + 1:
			var s: float = A[i][j]
			for k in j:
				s -= L[i][k] * L[j][k]
			L[i][j] = sqrt(maxf(s, 1e-18)) if i == j else s / L[j][j]
	return L


## One scalar unscented update. h maps a state to the predicted measurement.
func _update(z: float, h: Callable, R: float, angle: bool) -> void:
	var n := 4
	var Pn := []
	for row in P:
		var r := PackedFloat64Array()
		for v in row:
			r.append(v * n)
		Pn.append(r)
	var L := cholesky(Pn)
	var pts := []
	for j in n:
		var a := x.duplicate()
		var b := x.duplicate()
		for i in n:
			a[i] += L[i][j]
			b[i] -= L[i][j]
		pts.append(a)
		pts.append(b)
	var w := 1.0 / (2.0 * n)
	var ys := []
	for p in pts:
		ys.append(h.call(p))
	var mean := 0.0
	if angle:
		var sx := 0.0
		var cx := 0.0
		for y in ys:
			sx += sin(y)
			cx += cos(y)
		mean = atan2(sx, cx)
	else:
		for y in ys:
			mean += y * w
	var d := []
	for y in ys:
		d.append(wrap_angle(y - mean) if angle else y - mean)
	var Pyy := R
	for v in d:
		Pyy += w * v * v
	var K := PackedFloat64Array()
	for i in n:
		var s := 0.0
		for k in pts.size():
			s += w * (pts[k][i] - x[i]) * d[k]
		K.append(s / Pyy)
	var innov := wrap_angle(z - mean) if angle else z - mean
	for i in n:
		x[i] += K[i] * innov
	for i in n:
		for j in n:
			P[i][j] -= K[i] * Pyy * K[j]
	for i in n:
		for j in i:
			var m: float = (P[i][j] + P[j][i]) / 2.0
			P[i][j] = m
			P[j][i] = m


## A bearing (rad from +x, in the plane) measured from s at time tm.
## Unsure compared with how far it is from the sensor (a ship alongside, a
## few km off, after a burn has widened the track to tens of km), one bearing
## is too curved for the unscented update: its sample points sit all round the
## sensor. Then it goes in as what it says in a straight line: the target is
## on the measured line of bearing, its distance across that line 0 ± σ·range,
## a measurement linear in position (the pseudo-linear estimator: Lindgren &
## Gong 1978, IEEE Trans. AES 14(4); Aidala & Nardone 1982, IEEE Trans. AES
## 18(4):432–441).
func update_bearing(s: PackedFloat64Array, bearing: float, sigma: float, tm := NAN) -> void:
	var dt := 0.0 if is_nan(tm) else tm - t
	# Where the estimate puts it when the bearing was taken (a recording's
	# bearing can be minutes old), and how that moves with the state now.
	var xm := x if absf(dt) < 1.0 else coast(x, dt)
	# A bearing far outside what the estimate expects means the target moved in
	# a way it didn't model: an unseen burn. Widen the track for one first.
	if nis_bearing(xm, s, bearing, sigma) > MANEUVER_GATE:
		maneuver_seen(MANEUVER_SINCE, MANEUVER_DV)
		unseen_burns += 1
		xm = x if absf(dt) < 1.0 else coast(x, dt)
	var rng := sqrt((xm[0] - s[0]) * (xm[0] - s[0]) + (xm[1] - s[1]) * (xm[1] - s[1]))
	if ellipse().major > CURVED * rng:
		var n0 := -sin(bearing)
		var n1 := cos(bearing)
		var H := PackedFloat64Array([n0, n1, 0.0, 0.0])
		if absf(dt) >= 1.0:
			var F := stm(x, dt)
			for j in 4:
				H[j] = n0 * F[0][j] + n1 * F[1][j]
		var cross := n0 * (xm[0] - s[0]) + n1 * (xm[1] - s[1])
		# Without a range, a bearing says nothing about distance along it; the
		# pseudo-linear gain still pulls the estimate toward the observer (its
		# known short-range bias), so keep its position step across the line.
		var unranged := t - ranged_at > RANGED_FOR
		_update_linear(H, -cross, sigma * sigma * rng * rng, V.of(n0, n1) if unranged else PackedFloat64Array())
		if unranged:
			_floor_along(s, RANGE_FLOOR * rng)
		return
	if absf(dt) < 1.0:
		_update(bearing, func(p): return atan2(p[1] - s[1], p[0] - s[0]), sigma * sigma, true)
	else:
		var h := func(p):
			var q := coast(p, dt)
			return atan2(q[1] - s[1], q[0] - s[0])
		_update(bearing, h, sigma * sigma, true)


## One scalar Kalman update for a measurement linear in the state: H·x,
## with innovation `innov` and variance R (Joseph form, so P stays symmetric
## and positive, and right for any gain). Given a unit vector `across`, the
## position step is held to it.
func _update_linear(H: PackedFloat64Array, innov: float, R: float, across := PackedFloat64Array()) -> void:
	var PH := PackedFloat64Array([0.0, 0.0, 0.0, 0.0])
	for i in 4:
		for j in 4:
			PH[i] += P[i][j] * H[j]
	var S := R
	for i in 4:
		S += H[i] * PH[i]
	var K := PackedFloat64Array([0.0, 0.0, 0.0, 0.0])
	for i in 4:
		K[i] = PH[i] / S
	if not across.is_empty():
		var k := K[0] * across[0] + K[1] * across[1]
		K[0] = k * across[0]
		K[1] = k * across[1]
	for i in 4:
		x[i] += K[i] * innov
	# P = (I − K H) P (I − K H)ᵀ + K R Kᵀ
	var A := []
	for i in 4:
		var row := PackedFloat64Array([0.0, 0.0, 0.0, 0.0])
		for j in 4:
			row[j] = (1.0 if i == j else 0.0) - K[i] * H[j]
		A.append(row)
	P = mul(mul(A, P), transpose(A))
	for i in 4:
		for j in 4:
			P[i][j] += K[i] * R * K[j]


## Keep at least sd (km, 1σ) of position uncertainty along the line from s
## to the estimate, adding only what is missing in that direction.
func _floor_along(s: PackedFloat64Array, sd: float) -> void:
	var u := V.of(x[0] - s[0], x[1] - s[1])
	var un := V.norm(u)
	if un < 1e-9:
		return
	u = V.scale(u, 1.0 / un)
	var have: float = u[0] * u[0] * P[0][0] + 2.0 * u[0] * u[1] * P[0][1] + u[1] * u[1] * P[1][1]
	var add := sd * sd - have
	if add <= 0.0:
		return
	P[0][0] += add * u[0] * u[0]
	P[0][1] += add * u[0] * u[1]
	P[1][0] += add * u[0] * u[1]
	P[1][1] += add * u[1] * u[1]


## The normalised innovation squared of a bearing taken from s, against the
## estimate's state xm (linearised: the bearing moves by n/r per km across it).
func nis_bearing(xm: PackedFloat64Array, s: PackedFloat64Array, z: float, sigma: float) -> float:
	var dx: float = xm[0] - s[0]
	var dy: float = xm[1] - s[1]
	var r2 := dx * dx + dy * dy
	if r2 < 1e-12:
		return 0.0
	var h0 := -dy / r2
	var h1 := dx / r2
	var S: float = h0 * h0 * P[0][0] + 2.0 * h0 * h1 * P[0][1] + h1 * h1 * P[1][1] + sigma * sigma
	var nu := wrap_angle(z - atan2(dy, dx))
	return nu * nu / S


## 1σ position uncertainty across the line of sight from s (km): what decides
## whether a beam aimed from s lands on it (how far along it hardly matters).
func cross_sigma(s: PackedFloat64Array) -> float:
	var u := V.of(x[0] - s[0], x[1] - s[1])
	var un := V.norm(u)
	if un < 1e-9:
		return ellipse().major
	var n := V.of(-u[1] / un, u[0] / un)
	return sqrt(maxf(0.0, n[0] * n[0] * P[0][0] + 2.0 * n[0] * n[1] * P[0][1] + n[1] * n[1] * P[1][1]))


func update_range(s: PackedFloat64Array, rng: float, sigma: float) -> void:
	ranged_at = t
	# 64-bit: a 32-bit Vector2 rounds a 10⁶ km range to ~0.06 km, the size of a radar range sigma.
	_update(rng, func(p): return sqrt((p[0] - s[0]) * (p[0] - s[0]) + (p[1] - s[1]) * (p[1] - s[1])), sigma * sigma, false)


## Widen the estimate after a burn is seen (a white-noise velocity jump).
func maneuver_seen(since: float, vel_sigma := 3.0) -> void:
	var v := vel_sigma * vel_sigma
	for pq in [[0, 2], [1, 3]]:
		var p: int = pq[0]
		var q: int = pq[1]
		P[p][p] += v * since * since
		P[p][q] += v * since
		P[q][p] += v * since
		P[q][q] += v


## 1σ position ellipse: {major, minor, angle} (km, km, rad).
func ellipse() -> Dictionary:
	var a: float = P[0][0]
	var b: float = P[0][1]
	var d: float = P[1][1]
	var mid := (a + d) / 2.0
	var diff := sqrt(pow((a - d) / 2.0, 2.0) + b * b)
	return {"major": sqrt(maxf(0.0, mid + diff)), "minor": sqrt(maxf(0.0, mid - diff)), "angle": 0.5 * atan2(2.0 * b, a - d)}


## Where the estimate says the target is at time at (a copy, coasted).
func forecast(at: float, fast := false) -> Track:
	var c := Track.new(id, label, x.duplicate(), P.map(func(r): return r.duplicate()), t)
	c.accel_noise = accel_noise
	c.predict(at, fast)
	return c


## A detection folded in at time at: remember where it was.
func mark_seen(at: float) -> void:
	last_seen = maxf(last_seen, at)
	lkp = pos()
	lkp_t = at


## Drop it once nobody has detected it for DROP_AFTER s, or once its 1σ
## position is wider than DROP_SIGMA_KM. Real trackers delete tracks that go
## unconfirmed for N scans (Blackman & Popoli 1999; MathWorks trackHistoryLogic);
## dropping on a too-wide gate, and both thresholds, are design values.
const DROP_AFTER := 24.0 * 3600.0
const DROP_SIGMA_KM := 100000.0


func stale(at: float) -> bool:
	return at - last_seen > DROP_AFTER or ellipse().major > DROP_SIGMA_KM


func pos() -> PackedFloat64Array:
	return V.of(x[0], x[1])


func vel() -> PackedFloat64Array:
	return V.of(x[2], x[3])


## Least-squares fix of where lines of bearing cross. lines: [{from, bearing, sigma}].
## Returns {ok, r, P2} with a 2×2 position covariance from the line geometry.
static func cross_fix(lines: Array) -> Dictionary:
	var A := [[0.0, 0.0], [0.0, 0.0]]
	var b := [0.0, 0.0]
	for l in lines:
		var n := PackedFloat64Array([-sin(l.bearing), cos(l.bearing)]) # normal to the line (64-bit: not a Vector2)
		var dist := 1e5 # weight lines by their cross-track error at a nominal 100,000 km
		var w := 1.0 / pow(l.sigma * dist, 2.0)
		var o: PackedFloat64Array = l.from
		var c := n[0] * o[0] + n[1] * o[1]
		A[0][0] += w * n[0] * n[0]
		A[0][1] += w * n[0] * n[1]
		A[1][1] += w * n[1] * n[1]
		b[0] += w * n[0] * c
		b[1] += w * n[1] * c
	A[1][0] = A[0][1]
	var det: float = A[0][0] * A[1][1] - A[0][1] * A[1][0]
	if absf(det) < 1e-30:
		return {"ok": false}
	var rx: float = (A[1][1] * b[0] - A[0][1] * b[1]) / det
	var ry: float = (-A[1][0] * b[0] + A[0][0] * b[1]) / det
	# Re-weight each line by its true distance to the fix for the covariance.
	var I := [[0.0, 0.0], [0.0, 0.0]]
	for l in lines:
		var n := PackedFloat64Array([-sin(l.bearing), cos(l.bearing)])
		var o: PackedFloat64Array = l.from
		var rr := maxf(1000.0, sqrt((rx - o[0]) * (rx - o[0]) + (ry - o[1]) * (ry - o[1])))
		var w := 1.0 / pow(l.sigma * rr, 2.0)
		I[0][0] += w * n[0] * n[0]
		I[0][1] += w * n[0] * n[1]
		I[1][1] += w * n[1] * n[1]
	I[1][0] = I[0][1]
	var d2: float = I[0][0] * I[1][1] - I[0][1] * I[1][0]
	if absf(d2) < 1e-30:
		return {"ok": false}
	var P2 := [[I[1][1] / d2, -I[0][1] / d2], [-I[1][0] / d2, I[0][0] / d2]]
	return {"ok": true, "r": V.of(rx, ry), "P2": P2}


## Start a track at a fix, with a circular-orbit prior on velocity.
static func start(id_: String, label_: String, fix: Dictionary, at: float) -> Track:
	var r: PackedFloat64Array = fix.r
	var rn := V.norm(r)
	var vc := sqrt(MU / rn)
	var vx := -r[1] / rn * vc
	var vy := r[0] / rn * vc
	var P2: Array = fix.P2
	var vs := 1.0 * 1.0 # (km/s)²: it could be on any nearby orbit
	var P0 := [PackedFloat64Array([P2[0][0], P2[0][1], 0, 0]), PackedFloat64Array([P2[1][0], P2[1][1], 0, 0]), PackedFloat64Array([0, 0, vs, 0]), PackedFloat64Array([0, 0, 0, vs])]
	return Track.new(id_, label_, PackedFloat64Array([r[0], r[1], vx, vy]), P0, at)
