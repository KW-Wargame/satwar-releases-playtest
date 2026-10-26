## The running world: time, the moons, every ship coasting under real gravity
## (gravity.gd), and the systems that act on it each look: sensing (what Blue
## learns), Red's behaviour, the effects, and the campaign's bookkeeping.
## Content: data/game.json (exported from the JS engine) and
## data/campaign.json (Operation NIGHT HERON).
class_name Sim
extends RefCounted

signal logged(entry: Dictionary)

const HOUR := 3600.0
const DAY := 86400.0
const LOOK := 600.0 # s between sensor looks (as the JS game)

var data: Dictionary
var camp: Dictionary
var mu: float
var t := 0.0
var ships: Array = [] # Dictionary per ship: exported fields plus r, v, cls, state flags
var by_id := {}
var moons: Array
var gravity: Gravity
var rng := RandomNumberGenerator.new()
var intercepts: Array = [] # recordings: {id, ship, kind, f, bw, start, end, heard_by: {ear: snr}, df, classified}
var tracks := {} # ship id -> Track (Blue's belief)
var track_n := 4417
var log: Array = []
var escalation := 0.0
var next_look := LOOK
var sensing: Sensing
var thermal: Thermal
var red: RedAI
var traffic: Traffic
var effects: Effects
var campaign: Campaign
var debris: Array = [] # clouds (Breakup.cloud): {r, v, t, n, M, cat, of, frags}
var scheduled: Array = [] # planned burns: {at, id, target, tof}


## The campaign a plain Sim.new() plays: the shadowing (data/campaign.json), or
## Operation NIGHT HERON (data/night_heron.json, shelved) for its films and tests.
static var campaign_path := "res://data/campaign.json"
const NIGHT_HERON := "res://data/night_heron.json"


func _init(path := "res://data/game.json", camp_path := "*", seed_ := -1) -> void:
	if camp_path == "*":
		camp_path = campaign_path
	data = JSON.parse_string(FileAccess.get_file_as_string(path))
	camp = JSON.parse_string(FileAccess.get_file_as_string(camp_path)) if camp_path != "" and FileAccess.file_exists(camp_path) else {}
	interplanetary = bool(camp.get("interplanetary", false)) or OS.get_cmdline_user_args().has("--interplanetary")
	mu = data.jupiter.gm
	moons = data.moons
	gravity = Gravity.new(mu, moons, moon_state)
	gravity.utc_of = utc_ms
	Track.gravity = gravity
	rng.seed = int(data.scenario.seed) if seed_ < 0 else seed_
	for k in camp.get("classes", {}):
		data.classes[k] = camp.classes[k]
	for k in camp.get("hulls", {}):
		data.hulls[k] = camp.hulls[k]
	# A class without a hull drawing (the kill vehicle: a model of its own) gets an empty one.
	for k in data.classes:
		if not data.hulls.has(k):
			data.hulls[k] = {"parts": []}
	# A campaign may bring its own cast in place of the JS game's.
	for s in camp.get("ships", data.scenario.ships):
		var d: Dictionary = s.duplicate(true)
		if d.has("orbit"):
			_place(d)
		_add(d)
	if not camp.is_empty():
		_add_campaign()
	_update_fixed()
	thermal = Thermal.new(self)
	sensing = Sensing.new(self)
	red = RedAI.new(self)
	traffic = Traffic.new(self)
	effects = Effects.new(self)
	campaign = Campaign.new(self)
	sensing.begin()
	thermal.step(LOOK)


func _add(s: Dictionary) -> void:
	s.cls = data.classes[s.classId]
	if s.has("r0"):
		s.r = V.from(s.r0)
		s.v = V.from(s.v0)
	if s.cls.has("prop") and not s.has("prop"):
		s.prop = s.cls.prop
		s.dry = s.cls.dry
	# A ship with no part in a campaign (game.json alone) has no Red role.
	if not s.has("role"):
		s.role = ""
	s.alive = true
	s.flash_until = -1.0
	ships.append(s)
	by_id[s.id] = s


## A campaign ship on a circular orbit in the plane: {radius_km, phase_deg,
## along_km (+ ahead along the orbit), radial_km (+ out)}. Circular under the
## game's gravity, J2 included: v² = μ/r + (3/2)μJ2R²/r³ in the equator.
func _place(d: Dictionary) -> void:
	var o: Dictionary = d.orbit
	var rn := float(o.radius_km) + float(o.get("radial_km", 0.0))
	var ang := deg_to_rad(float(o.get("phase_deg", 0.0))) + float(o.get("along_km", 0.0)) / float(o.radius_km)
	var vc := sqrt(mu / rn + 1.5 * Gravity.J2 * mu * Gravity.R_REF * Gravity.R_REF / (rn * rn * rn))
	d.r0 = [rn * cos(ang), rn * sin(ang), 0.0]
	d.v0 = [-vc * sin(ang), vc * cos(ang), 0.0]
	d.t0 = 0.0


func _add_campaign() -> void:
	for r in camp.get("red", []):
		if r.get("from_game", false):
			by_id[r.id].role = r.role
			by_id[r.id].pocket = r.pocket
			continue
		var choices: Array = r.pocket if r.pocket is Array else [r.pocket]
		var pk: Dictionary = pocket(choices[rng.randi() % choices.size()])
		var st := pocket_state(pk, 0.0)
		var off := V.of(float(r.offset[0]), float(r.offset[1]))
		var s := {"id": r.id, "name": r.name, "short": r.short, "side": "red", "kind": "hostile", "classId": r.class, "role": r.role, "pocket": pk.id, "operator": "UNKNOWN", "flag": "NONE",
			"r0": [st[0][0] + off[0], st[0][1] + off[1], 0.0], "v0": [st[1][0], st[1][1], 0.0], "t0": 0.0, "plan": r.duplicate()}
		_add(s)
	# Civil traffic on circular orbits: each one its own emitter (traffic.gd).
	for c in camp.get("civil", []):
		var rn := float(c.radius_km)
		var ang := deg_to_rad(float(c.phase_deg))
		var vc := sqrt(mu / rn)
		var s := {"id": c.id, "name": c.name, "short": c.short, "side": "neutral", "kind": "civil", "classId": c.class, "role": "CIVIL TRAFFIC", "operator": c.get("operator", ""),
			"r0": [rn * cos(ang), rn * sin(ang), 0.0], "v0": [-vc * sin(ang), vc * cos(ang), 0.0], "t0": 0.0}
		_add(s)
		if c.has("f"):
			# Its own channel: a copy of the class with this frequency.
			s.cls = s.cls.duplicate(true)
			s.cls.ttc.f = float(c.f)
	for b in camp.get("blue_extra", []):
		var g := moon_state(b.staged.moon, 0.0)
		var rn := V.norm(g[0])
		var ang := atan2(g[0][1], g[0][0]) - float(b.staged.trail_km) / rn
		var vc := sqrt(mu / rn)
		var s: Dictionary = b.duplicate(true)
		s.classId = b.class
		s.r0 = [rn * cos(ang), rn * sin(ang), 0.0]
		s.v0 = [-vc * sin(ang), vc * cos(ang), 0.0]
		s.t0 = 0.0
		_add(s)


func pocket(id: String) -> Dictionary:
	for p in camp.get("pockets", []):
		if p.id == id:
			return p
	return {}


## The point a pocket is centred on at time at, and its velocity: a Lagrange
## point leads or trails its moon by 60° on the same orbit.
func pocket_state(p: Dictionary, at: float) -> Array:
	if p.kind == "lagrange":
		var m := moon_state(p.moon, at)
		var a := deg_to_rad(float(p.lead))
		return [V.of(m[0][0] * cos(a) - m[0][1] * sin(a), m[0][0] * sin(a) + m[0][1] * cos(a)), V.of(m[1][0] * cos(a) - m[1][1] * sin(a), m[1][0] * sin(a) + m[1][1] * cos(a))]
	var mv: Dictionary = by_id.get("mv", {})
	return [mv.r, mv.v] if not mv.is_empty() else [V.of(float(p.radius), 0), V.of(0, 0)]


func pocket_center(p: Dictionary, at := NAN) -> PackedFloat64Array:
	return pocket_state(p, t if is_nan(at) else at)[0]


func moon(id: String) -> Dictionary:
	for m in moons:
		if m.id == id:
			return m
	return {}


## Moon state from JPL mean elements at sim time at. Returns [r, v].
func moon_state(id: String, at: float) -> Array:
	var m := moon(id)
	return Kepler.from_elements(m, float(data.epochOffset) + at, mu + float(m.gm))


func ship(id: String) -> Dictionary:
	return by_id.get(id, {})


func pos(id: String) -> PackedFloat64Array:
	return by_id[id].r


## Does Blue know what this ship is? Ours, or a track it has classified. A
## track it hasn't is drawn only as its symbol: no hull on the map, a blur of
## heat in the infrared camera, until it is identified.
func class_known(id: String) -> bool:
	if by_id.has(id) and by_id[id].side == "blue":
		return true
	return tracks.has(id) and String(tracks[id].class_id) != ""


func range_km(a: String, b: String) -> float:
	return V.dist(pos(a), pos(b))


## The velocity that keeps a ship at r alongside one at (tr, tv): the
## target's own orbit, turned about Jupiter to r. Same energy, so the same
## period, and the same flight-path angle: the two coast round together at
## their offset, where matching velocity alone (equal speeds at different
## places in the field) lets them drift apart (Clohessy–Wiltshire; Vallado
## 2013, §6.8). In the orbital plane, as the game is.
func station_v(r: PackedFloat64Array, tr: PackedFloat64Array, tv: PackedFloat64Array) -> PackedFloat64Array:
	var th := atan2(tr[0] * r[1] - tr[1] * r[0], tr[0] * r[0] + tr[1] * r[1])
	var c := cos(th)
	var s := sin(th)
	var v2 := V.dot(tv, tv) + 2.0 * mu * (1.0 / V.norm(r) - 1.0 / V.norm(tr))
	var spd := sqrt(maxf(v2, 0.0)) / maxf(V.norm(tv), 1e-9)
	return V.of((tv[0] * c - tv[1] * s) * spd, (tv[0] * s + tv[1] * c) * spd, 0.0)


func range_rate(a: String, b: String) -> float:
	var d := V.sub(pos(b), pos(a))
	var dv := V.sub(by_id[b].v, by_id[a].v)
	return V.dot(d, dv) / maxf(V.norm(d), 1e-9)


func utc(at := NAN) -> Dictionary:
	var ms := float(data.startUtc) + (t if is_nan(at) else at) * 1000.0
	return Time.get_datetime_dict_from_unix_time(int(ms / 1000.0))


func delta_v(id: String) -> float:
	var s: Dictionary = by_id[id]
	if not s.cls.has("engine") or not s.has("prop"):
		return 0.0
	return RF.delta_v(float(s.cls.engine.ve), float(s.dry), float(s.prop))


## A line in the log. code: a stable id; text: what the player reads (already
## in the chosen language); kind: info / good / warn / alert.
func say(code: String, text: String, kind := "info", data_ := {}) -> void:
	var e := {"t": t, "code": code, "text": text, "kind": kind, "data": data_}
	log.append(e)
	logged.emit(e)


## Advance the world by dt seconds. Systems act at every look boundary.
func advance(dt: float) -> void:
	while dt > 1e-9:
		var h := minf(dt, next_look - t)
		if h <= 1e-9:
			h = minf(dt, LOOK)
		h = minf(h, effects.max_step()) # fine steps while a kill vehicle homes
		_step(h)
		dt -= h
		for b in scheduled.duplicate():
			if t >= b.at:
				scheduled.erase(b)
				var tgt: String = b.target
				var plan := plan_to(b.id, pocket_center(pocket(tgt.substr(7)), t + b.tof), b.tof, 0.0, tgt) if tgt.begins_with("pocket:") else (plan_planet(b.id, tgt.substr(7), b.tof) if tgt.begins_with("planet:") else plan_intercept(b.id, tgt, b.tof))
				execute(plan)
		if t >= next_look - 1e-6:
			thermal.step(LOOK)
			sensing.look()
			red.think()
			traffic.think()
			effects.tick(LOOK)
			campaign.check()
			next_look += LOOK


func _step(h: float) -> void:
	var sub_h := minf(60.0, h)
	for s in ships:
		if s.has("r") and not s.has("onMoon") and s.alive:
			# Civil traffic keeps to Kepler orbits (cheap); everyone else feels the moons.
			var st: Array = Kepler.propagate(s.r, s.v, h, mu) if s.get("kind", "") == "civil" else gravity.coast(s.r, s.v, t, h, sub_h)
			s.r = st[0]
			s.v = st[1]
	# Debris: the cloud's centre and each fragment flown on its own orbit.
	for d in debris:
		var st := Kepler.propagate(d.r, d.v, h, mu)
		d.r = st[0]
		d.v = st[1]
		for f in d.get("frags", []):
			var fs := Kepler.propagate(f.r, f.v, h, mu)
			f.r = fs[0]
			f.v = fs[1]
	effects.step(h)
	t += h
	_update_fixed()


func _update_fixed() -> void:
	for s in ships:
		if s.has("onMoon"):
			var st := moon_state(s.onMoon, t)
			s.r = st[0]
			s.v = st[1]


## Coast a copy of a ship's state ahead under full gravity (its true future).
func predict(id: String, hours: float, points := 120) -> Array:
	var s: Dictionary = by_id[id]
	return predict_state(s.r, s.v, hours, points)


func predict_state(r: PackedFloat64Array, v: PackedFloat64Array, hours: float, points := 120) -> Array:
	var out := [r]
	var st := [r, v]
	var dt := hours * HOUR / points
	for i in points:
		st = gravity.coast(st[0], st[1], t + i * dt, dt, 300.0)
		out.append(st[0])
	return out


## The osculating Kepler ellipse through a state: the orbit with Jupiter alone,
## drawn from its elements (r = p / (1 + e cos θ)) rather than by propagating.
func osculating(r: PackedFloat64Array, v: PackedFloat64Array, points := 256) -> Array:
	var h := V.cross(r, v)
	var ev := V.sub(V.scale(V.cross(v, h), 1.0 / mu), V.scale(r, 1.0 / V.norm(r)))
	var e := V.norm(ev)
	if e >= 0.999:
		return []
	var p := V.dot(h, h) / mu
	var w := atan2(ev[1], ev[0]) if e > 1e-9 else 0.0
	var out := []
	for i in points + 1:
		var th := TAU * i / points
		var rr := p / (1.0 + e * cos(th))
		out.append(V.of(rr * cos(th + w), rr * sin(th + w)))
	return out


## How far (km) an ear hears one of a Red class's command reports at even odds,
## from a bystander's angle: 90° off the line to its handler (a far sidelobe),
## with the ear looking straight at it.
func ear_range(ear_id: String, red_class := "vesper", off_t := PI / 2.0) -> float:
	return Sensing.reach_km(data.classes[red_class].ttc, by_id[ear_id].cls.esm, off_t, float(data.cfg.radio.get("pfa", 1e-6)))


## Plan a transfer that meets a target tof seconds from now. For a Red ship
## it aims at Blue's track (its forecast), unless truth is asked for (tests);
## sigma says how wide the target's uncertainty will be on arrival.
func plan_intercept(id: String, target: String, tof: float, truth := false) -> Dictionary:
	var s: Dictionary = by_id[id]
	var tgt: Dictionary = by_id[target]
	var node: PackedFloat64Array
	var sigma := 0.0
	if tgt.side == "red" and not truth:
		if not tracks.has(target):
			return {"ok": false, "why": "no track on it"}
		var f: Track = tracks[target].forecast(t + tof)
		node = f.pos()
		sigma = f.ellipse().major
	else:
		node = predict(target, tof / HOUR, maxi(12, int(tof / 600.0))).back()
	return plan_to(id, node, tof, sigma, target)


func plan_to(id: String, node: PackedFloat64Array, tof: float, sigma := 0.0, target := "") -> Dictionary:
	var s: Dictionary = by_id[id]
	var sol := Lambert.solve(s.r, node, tof, mu)
	if sol.is_empty():
		return {"ok": false, "why": "no transfer"}
	var dv_vec := V.sub(sol[0], s.v)
	var dv := V.norm(dv_vec)
	var ok := dv <= delta_v(id)
	return {"ok": ok, "why": "" if ok else "not enough fuel", "id": id, "target": target, "dv_vec": dv_vec, "dv": dv, "arrive": t + tof, "node": node, "sigma": sigma, "v2": sol[1]}


## Lambert's transfer is two-body. Close to Jupiter its oblateness (J2) bends a
## few hours' coast by thousands of km, so the burn actually flown is corrected
## by shooting: coast the trial transfer under the game's full gravity, move the
## aim point by the miss, re-solve, until it arrives within 50 m (a few passes;
## the classic differential-correction method, Vallado 2013; single shooting as in
## NASA/TP-20220014814, §5.2.1). Far out,
## where J2 is small, the first pass already lands. Updates dv_vec, dv, v2.
func refine(plan: Dictionary, tol_km := 0.05) -> void:
	if not plan.has("node") or not plan.has("arrive"):
		return
	if plan.get("kind", "") == "planet":
		refine_planet(plan)
		return
	var s: Dictionary = by_id[plan.id]
	var tof := float(plan.arrive) - t
	if tof <= 0.0:
		return
	var node: PackedFloat64Array = plan.node
	var aim := node
	var v1 := V.add(s.v, plan.dv_vec)
	for i in 6:
		var st := gravity.coast(s.r, v1, t, tof, 60.0)
		var miss := V.sub(st[0], node)
		plan.v2 = st[1]
		if V.norm(miss) < tol_km:
			break
		aim = V.sub(aim, miss)
		var sol := Lambert.solve(s.r, aim, tof, mu)
		if sol.is_empty():
			return
		v1 = sol[0]
	plan.dv_vec = V.sub(v1, s.v)
	plan.dv = V.norm(plan.dv_vec)


## Flights between planets (core/transfer.gd). Off unless the campaign says
## "interplanetary": true (or the game is started with --interplanetary): the
## shadowing scenario plays inside Jupiter's system as before.
var interplanetary := false


## Which body's pull a ship is under now: "jupiter", a planet, or "sun".
func home_of(id: String) -> String:
	return Transfer.home(by_id[id].r, utc_ms())


## A ship's state relative to a body (game frame axes).
func rel_state(id: String, body: String, at := NAN) -> Array:
	var s: Dictionary = by_id[id]
	var P := Ephem.state(body, utc_ms(at))
	return [V.sub(s.r, P[0]), V.sub(s.v, P[1])]


## Plan a flight to a planet arriving tof seconds from now (patched conics,
## refined under full gravity when flown).
func plan_planet(id: String, body: String, tof: float) -> Dictionary:
	var from := home_of(id)
	if from == body:
		return {"ok": false, "why": "already there"}
	if from == "sun":
		return _course_correction(id, body, tof)
	var rv := rel_state(id, from)
	var tr := Transfer.patched(rv[0], rv[1], from, body, utc_ms(), tof)
	if tr.is_empty():
		return {"ok": false, "why": "no transfer"}
	var s: Dictionary = by_id[id]
	var dv_vec := V.sub(V.add(tr.v1, Ephem.state(from, utc_ms())[1]), s.v)
	var dv := V.norm(dv_vec)
	var ok := dv <= delta_v(id)
	return {"ok": ok, "why": "" if ok else "not enough fuel", "id": id, "target": "planet:" + body, "kind": "planet", "body": body, "from": from,
		"dv_vec": dv_vec, "dv": dv, "arrive": t + tof, "node": V.add(Ephem.pos(body, utc_ms(t + tof)), tr.aim_off), "sigma": 0.0,
		"vinf": tr.vinf, "R1": tr.R1, "V1": tr.V1, "R2": tr.R2, "capture": tr.capture, "total": tr.total, "v2": V.add(tr.vinf_arr, Ephem.state(body, utc_ms(t + tof))[1])}


## One cell of the planner's chart for a planet: wait dep seconds (coasting on
## the two-body orbit about where the ship is), then fly tof. Patched conics
## only, no refining: cheap enough for a grid. {} when no transfer.
func planet_cell(id: String, body: String, dep: float, tof: float) -> Dictionary:
	var from := home_of(id)
	if from == body:
		return {}
	var rv := rel_state(id, from)
	var st := Kepler.propagate(rv[0], rv[1], dep, Ephem.gm(from))
	var ms0 := utc_ms(t + dep)
	if from != "sun":
		var tr := Transfer.patched(st[0], st[1], from, body, ms0, tof)
		if tr.is_empty():
			return {}
		return {"dv": tr.dv, "capture": tr.capture, "total": tr.total, "node": V.add(Ephem.pos(body, utc_ms(t + dep + tof)), tr.aim_off)}
	# Deep space: straight to it, a Lambert arc about the Sun (rel_state was heliocentric).
	var ms1 := utc_ms(t + dep + tof)
	var sun1 := Ephem.state("sun", ms1)
	var P1 := Ephem.state(body, ms1)
	var sol := Lambert.solve(st[0], V.sub(P1[0], sun1[0]), tof, Ephem.GM_SUN)
	if sol.is_empty():
		return {}
	var dv := V.dist(sol[0], st[1])
	var v2n := V.dist(sol[1], V.sub(P1[1], sun1[1]))
	var mu2 := Ephem.gm(body)
	var rp := Transfer.CAPTURE_R * float(Ephem.BODY[body].re)
	var cap := sqrt(v2n * v2n + 2.0 * mu2 / rp) - sqrt(mu2 / rp)
	return {"dv": dv, "capture": cap, "total": dv + cap, "node": P1[0]}


## In deep space, a course correction (what missions call a TCM): the burn
## that puts the ship on the Lambert arc about the Sun from where it is to the
## aim point, refined under full gravity like any other transfer.
func _course_correction(id: String, body: String, tof: float) -> Dictionary:
	var s: Dictionary = by_id[id]
	var ms0 := utc_ms()
	var sun0 := Ephem.state("sun", ms0)
	var R1 := V.sub(s.r, sun0[0])
	var V1 := V.sub(s.v, sun0[1])
	var ms1 := utc_ms(t + tof)
	var sun1 := Ephem.state("sun", ms1)
	var P1 := Ephem.state(body, ms1)
	var sol := Lambert.solve(R1, V.sub(P1[0], sun1[0]), tof, Ephem.GM_SUN)
	if sol.is_empty():
		return {"ok": false, "why": "no transfer"}
	var vinf2 := V.sub(sol[1], V.sub(P1[1], sun1[1]))
	var v2n := V.norm(vinf2)
	var mu2 := Ephem.gm(body)
	var rp := Transfer.CAPTURE_R * float(Ephem.BODY[body].re)
	var b := rp * sqrt(1.0 + 2.0 * mu2 / (rp * v2n * v2n))
	var side := V.cross(V.of(0, 0, 1), vinf2)
	var off := V.scale(side, b / maxf(1e-9, V.norm(side)))
	sol = Lambert.solve(R1, V.add(V.sub(P1[0], sun1[0]), off), tof, Ephem.GM_SUN)
	if sol.is_empty():
		return {"ok": false, "why": "no transfer"}
	var dv_vec := V.sub(sol[0], V1)
	var dv := V.norm(dv_vec)
	var capture := sqrt(v2n * v2n + 2.0 * mu2 / rp) - sqrt(mu2 / rp)
	var plan := {"ok": dv <= delta_v(id), "why": "" if dv <= delta_v(id) else "not enough fuel", "id": id, "target": "planet:" + body, "kind": "planet", "body": body, "from": "sun",
		"dv_vec": dv_vec, "dv": dv, "arrive": t + tof, "node": V.add(P1[0], off), "sigma": 0.0, "vinf": dv_vec, "R1": R1, "V1": V1,
		"R2": V.add(V.sub(P1[0], sun1[0]), off), "capture": capture, "total": dv + capture, "v2": V.add(vinf2, P1[1]), "tcm": true}
	return plan # its "v∞" is the burn itself, about the ship's own velocity


## Fly the trial under full gravity and correct v∞ by Newton's method until
## the ship arrives within a tenth of the target's sphere of influence of the
## aim point. The Jacobian (arrival per km/s of v∞) is the two-body arc's
## about the Sun, by finite differences: cheap, and close enough that each pass
## cuts the miss many times over; the full-gravity flight supplies the miss.
func refine_planet(plan: Dictionary) -> void:
	var s: Dictionary = by_id[plan.id]
	var tof := float(plan.arrive) - t
	var from: String = plan.from
	var rv := rel_state(plan.id, from if from != "sun" else "jupiter")
	var Pv: PackedFloat64Array = Ephem.state(from if from != "sun" else "jupiter", utc_ms())[1]
	var vinf: PackedFloat64Array = plan.vinf
	var v1 := V.add(s.v, plan.dv_vec)
	var tol := 0.1 * Ephem.soi(String(plan.body))
	var J := Transfer.jacobian(plan.R1, plan.V1, vinf, tof)
	var last := PackedFloat64Array()
	var dx := PackedFloat64Array()
	for i in Transfer.PASSES:
		var st := gravity.coast(s.r, v1, t, tof, 60.0)
		var miss := V.sub(st[0], plan.node)
		plan.v2 = st[1]
		plan.miss_km = V.norm(miss)
		if V.norm(miss) < tol:
			break
		if not last.is_empty():
			J = Transfer.broyden(J, dx, V.sub(miss, last))
		last = miss
		var step := Transfer.solve3(J, miss)
		if step.is_empty():
			break
		dx = V.scale(step, -1.0)
		vinf = V.add(vinf, dx)
		if from == "sun":
			v1 = V.add(s.v, vinf)
			continue
		var cands := Transfer.departure(rv[0], vinf, Ephem.gm(from))
		if cands.is_empty():
			break
		var best: PackedFloat64Array = cands[0]
		for c in cands:
			if V.dist(c, rv[1]) < V.dist(best, rv[1]):
				best = c
		v1 = V.add(best, Pv)
	plan.dv_vec = V.sub(v1, s.v)
	plan.dv = V.norm(plan.dv_vec)
	plan.vinf = vinf


## Settle into a circular orbit about whatever the ship is near, at its present
## distance, turning the way it is already going.
func plan_orbit(id: String) -> Dictionary:
	var body := home_of(id)
	if body == "sun":
		return {"ok": false, "why": "no planet near"}
	var rv := rel_state(id, body)
	var rn := V.norm(rv[0])
	var hz := V.cross(rv[0], rv[1])
	if V.norm(hz) < 1e-9:
		hz = V.of(0, 0, 1)
	var tdir := V.cross(hz, rv[0])
	tdir = V.scale(tdir, 1.0 / V.norm(tdir))
	var vc := V.scale(tdir, sqrt(Ephem.gm(body) / rn))
	var dv_vec := V.sub(vc, rv[1])
	var dv := V.norm(dv_vec)
	var ok := dv <= delta_v(id)
	return {"ok": ok, "why": "" if ok else "not enough fuel", "id": id, "target": "orbit:" + body, "dv_vec": dv_vec, "dv": dv, "arrive": t, "node": by_id[id].r, "kind": "orbit"}


## Burn: change velocity now and pay for it by the rocket equation; the drive
## glows for the length of the burn (thrust-limited), and at least 5 min.
func burn(id: String, dv_vec: PackedFloat64Array) -> bool:
	var s: Dictionary = by_id[id]
	var dv := V.norm(dv_vec)
	if not s.alive or not s.cls.has("engine") or dv > delta_v(id) + 1e-9:
		return false
	var ve: float = s.cls.engine.ve
	var used := (float(s.dry) + float(s.prop)) * (1.0 - exp(-dv / ve))
	var seconds := used * 1000.0 * ve * 1000.0 / float(s.cls.engine.thrust)
	s.prop = float(s.prop) - used
	s.v = V.add(s.v, dv_vec)
	s.flash_until = t + maxf(seconds, 300.0)
	s.burn_seconds = seconds
	s.burn_dir = V.scale(dv_vec, 1.0 / maxf(dv, 1e-12))
	s.burn_at = t
	s.burns = int(s.get("burns", 0)) + 1
	return true


func execute(plan: Dictionary) -> bool:
	if not plan.get("ok", false):
		return false
	if plan.get("kind", "") != "orbit":
		refine(plan)
	var ok := burn(plan.id, plan.dv_vec)
	if ok and by_id[plan.id].side == "blue":
		by_id[plan.id].plan_arrive = plan.arrive
		by_id[plan.id].plan_target = plan.target
		by_id[plan.id].plan_node = plan.node
		by_id[plan.id].plan_sigma = plan.get("sigma", 0.0)
		say("burn", Lang.f("burn", [by_id[plan.id].short, plan.dv]), "info")
	return ok


func burning(id: String) -> bool:
	return float(by_id[id].get("flash_until", -1.0)) > t


func blue_ships() -> Array:
	return ships.filter(func(s): return s.side == "blue" and s.alive)


func red_ships() -> Array:
	return ships.filter(func(s): return s.side == "red")


func day() -> int:
	return int(t / DAY) + 1


## Release a listening buoy from a warship, where it is and moving as it moves.
func drop_buoy(from_id: String) -> String:
	var s: Dictionary = by_id[from_id]
	if int(s.get("buoys", 1 if s.kind == "warship" else 0)) <= 0 or not s.alive:
		return ""
	s.buoys = int(s.get("buoys", 1)) - 1
	var n := 1
	while by_id.has("b%d" % n):
		n += 1
	# Out of the back, clear of the hull: a hull's length and a half behind the
	# ship along its track, pushed off backward at 1 m/s, as spring deployers
	# eject small satellites (design value, in the 1–2 m/s of CubeSat
	# dispensers: Cal Poly CubeSat Design Specification rev. 14, 2022).
	var aft := V.scale(s.v, -1.0 / maxf(V.norm(s.v), 1e-9))
	var r0 := V.add(s.r, V.scale(aft, 1.5 * float(s.cls.get("length", 20.0)) / 1000.0))
	var v0 := V.add(s.v, V.scale(aft, 0.001))
	var b := {"id": "b%d" % n, "classId": "wren", "name": "WREN-%d ES BUOY" % n, "short": "WREN-%d" % n, "side": "blue", "kind": "buoy", "role": "PASSIVE ES · DIRECTION FINDING", "registry": "USA %d" % (660 + n), "operator": "U.S. SPACE CORPS · SPACE DELTA 7 (ISR)", "flag": "UNITED STATES", "status": "LISTENING",
		"r0": [r0[0], r0[1], 0.0], "v0": [v0[0], v0[1], 0.0], "t0": t}
	_add(b)
	say("buoy", ("%s dropped WREN-%d: another ear." if not Lang.doctrinal else "%s deployed WREN-%d (ES).") % [s.short, n], "good")
	return b.id


## Where Red's handler sits: the outpost near Callisto.
func handler_pos(at := NAN) -> PackedFloat64Array:
	return moon_state("callisto", t if is_nan(at) else at)[0]


func utc_ms(at := NAN) -> float:
	return float(data.startUtc) + (t if is_nan(at) else at) * 1000.0


## Unit vectors from Jupiter toward the Sun and toward Earth, in the game plane
## (JPL approximate planetary positions, core/ephem.gd). At 5 AU the direction
## barely changes across the system, so it serves for any ship.
func sun_dir(at := NAN) -> PackedFloat64Array:
	return _planar_unit(Ephem.sun(utc_ms(at)))


func earth_dir(at := NAN) -> PackedFloat64Array:
	return _planar_unit(Ephem.earth(utc_ms(at)))


static func _planar_unit(v: PackedFloat64Array) -> PackedFloat64Array:
	var n := sqrt(v[0] * v[0] + v[1] * v[1])
	return V.of(v[0] / n, v[1] / n)
