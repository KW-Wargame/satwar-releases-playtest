## Red's behaviour, one brain per role. Red flies by the same physics as Blue
## and knows only what its own sensors and its handler tell it.
## - tender: stalks INDUSTRIAL INTENT for a rendezvous (an RPO, the real
##   inspector behaviour reported of Luch/Olymp-K); corrects its transfer under
##   real gravity; goes quiet when hunted; dodges; gives up when the fuel to
##   finish the job runs out or a Blue warship guards the freighter.
## - relay: sits at a Lagrange point and passes the handler's orders; on the
##   wake day it sends the sleeper its activation.
## - inspector: shadows HYDRA and tells the network where Blue's hunter is.
## - sleeper: silent and cold until woken; then a co-orbital intercept on
##   EXCALIBUR (after Cosmos 2543's 2020 co-orbital test, USSPACECOM).
## Red's links to its handler: jammed, spoofed, captured or a dead relay all
## cut the commands that keep its plans fresh.
class_name RedAI
extends RefCounted

const H := 3600.0
## The world this belongs to, held weakly: Sim holds this too, and a strong
## reference each way is a cycle that RefCounted never frees.
var sim: Sim:
	get:
		return _sim.get_ref()
	set(v):
		_sim = weakref(v)
var _sim := WeakRef.new()
var knows := {} # red id -> {blue id: true} from its own sensors and the inspector


func _init(sim_: Sim) -> void:
	sim = sim_
	for s in sim.red_ships():
		s.ai = {"next_tx": _first_tx(s), "silent_until": 0.0, "evasions": 2, "last_evade": -1e9, "state": "idle", "arrival": INF, "fixes": 0}
		s.bursts = []
	for s in sim.red_ships():
		if s.get("role", "") == "shadow":
			s.ai.state = "phase"
			s.ai.leg = 0
			s.ai.last_link = 0.0
	if sim.by_id.has("h1") and sim.by_id.h1.get("role", "") == "tender":
		var h: Dictionary = sim.by_id.h1
		h.ai.state = "stalk"
		h.ai.arrival = float(sim.data.scenario.hostileArrival)
		h.ai.next_tx = 2.0 * H
	if sim.by_id.has("r2"):
		sim.by_id.r2.ai.state = "wait"
	if sim.by_id.has("r3"):
		sim.by_id.r3.ai.state = "dormant"


func _first_tx(s: Dictionary) -> float:
	if not s.cls.has("ttc"):
		return INF
	return sim.rng.randf_range(0.2, 1.0) * float(s.cls.ttc.every[0])


## Is this Red ship still taking orders from its handler?
func linked(s: Dictionary) -> bool:
	if s.get("jammed_until", -1.0) > sim.t or s.get("captured", false) or s.get("disabled", false):
		return false
	if s.id != "r1" and sim.by_id.has("r1"):
		var relay: Dictionary = sim.by_id.r1
		if not relay.alive or relay.get("captured", false) or relay.get("disabled", false):
			return false
	return true


func can_see(s: Dictionary) -> bool:
	return s.get("dazzled_until", -1.0) <= sim.t and not s.get("disabled", false)


## Which Blue warships does this Red ship know about, and how?
func threats(s: Dictionary) -> Array:
	var out := []
	for b in sim.blue_ships():
		if b.kind != "warship":
			continue
		var seen: bool = can_see(s) and s.cls.has("ir") and sim.sensing.ir_sees(s, b)
		var told: bool = knows.get(s.id, {}).has(b.id) and linked(s)
		var loud := float(b.get("loud_until", -1.0)) > sim.t
		if seen or told or loud:
			var d := V.sub(b.r, s.r)
			var closing := V.dot(d, V.sub(b.v, s.v)) < 0.0
			out.append({"s": b, "range": V.norm(d), "closing": closing, "burning": sim.burning(b.id) and seen, "loud": loud})
	return out


func think() -> void:
	knows.clear()
	# The inspector tells the network what it sees.
	if sim.by_id.has("r2") and sim.by_id.r2.alive and not sim.by_id.r2.get("disabled", false) and linked(sim.by_id.r2):
		var insp: Dictionary = sim.by_id.r2
		for b in sim.blue_ships():
			if can_see(insp) and sim.sensing.ir_sees(insp, b):
				for r in sim.red_ships():
					if not knows.has(r.id):
						knows[r.id] = {}
					knows[r.id][b.id] = true
	for s in sim.red_ships():
		if not s.alive or s.get("captured", false) or s.get("disabled", false):
			continue
		_talk(s)
		_heat(s)
		match s.role:
			"tender": _tender(s)
			"relay": _relay(s)
			"inspector": _inspector(s)
			"sleeper": _sleeper(s)
			"shadow": _shadow(s)


## Reports home on a habit, unless it feels hunted.
func _talk(s: Dictionary) -> void:
	if not s.cls.has("ttc") or s.role == "sleeper":
		return
	var ai: Dictionary = s.ai
	var hunted := false
	for th in threats(s):
		if th.burning or th.loud or (th.range < 150000.0 and th.closing):
			hunted = true
	if hunted and ai.silent_until < sim.t:
		if sim.tracks.has(s.id):
			sim.say("red_quiet", Lang.f("red_quiet", [sim.sensing.label_for(s.id)]), "warn")
	if hunted:
		ai.silent_until = maxf(ai.silent_until, sim.t + 6.0 * H)
	if sim.t >= ai.next_tx and sim.t >= ai.silent_until:
		s.bursts.append({"start": sim.t, "end": sim.t + float(s.cls.ttc.burst), "kind": "ttc"})
		ai.next_tx = sim.t + sim.rng.randf_range(float(s.cls.ttc.every[0]), float(s.cls.ttc.every[1]))


func _mv() -> Dictionary:
	return sim.by_id.get("mv", {})


## Δv to finish the rendezvous: transfer now, then match the freighter.
func _need(s: Dictionary, arrive: float) -> Dictionary:
	var mv := _mv()
	var f: Array = sim.predict_state(mv.r, mv.v, (arrive - sim.t) / H, maxi(8, int((arrive - sim.t) / 1800.0)))
	var fr: PackedFloat64Array = f.back()
	var sol := Lambert.solve(s.r, fr, arrive - sim.t, sim.mu)
	if sol.is_empty():
		return {"dv": INF}
	var fv: PackedFloat64Array = Kepler.propagate(mv.r, mv.v, arrive - sim.t, sim.mu)[1]
	return {"dv": V.norm(V.sub(sol[0], s.v)) + V.norm(V.sub(fv, sol[1])), "v1": sol[0], "node": fr}


func _tender(s: Dictionary) -> void:
	var ai: Dictionary = s.ai
	var mv := _mv()
	if ai.state == "docked":
		if sim.t - ai.docked_at > float(sim.data.cfg.get("boardingSeconds", 3600.0)) and not ai.get("boarded", false):
			ai.boarded = true
			sim.say("boarded", Lang.f("boarded", []), "alert")
		else:
			s.r = mv.r
			s.v = mv.v
		return
	if ai.state != "stalk":
		return
	var left: float = ai.arrival - sim.t
	if left <= 0.0:
		if V.dist(s.r, mv.r) < 200.0:
			sim.burn(s.id, V.sub(mv.v, s.v)) # match her velocity: a burn the sensors see
			ai.state = "docked"
			ai.docked_at = sim.t
			sim.say("docked", Lang.f("docked", [sim.sensing.label_for(s.id)]), "alert")
		else:
			ai.state = "missed"
		return
	# Guarded: a known Blue warship close to the freighter near the end means it can't board.
	if left < 6.0 * H:
		for th in threats(s):
			if V.dist(th.s.r, mv.r) < 30000.0:
				ai.state = "aborted"
				sim.burn(s.id, V.scale(V.of(s.v[0], s.v[1]), minf(1.0, sim.delta_v(s.id)) / V.norm(s.v)))
				sim.say("red_abort", Lang.f("red_abort", [sim.sensing.label_for(s.id)]), "good")
				return
	# Its handler keeps its transfer accurate: course corrections need the link
	# (and spoofed ranging makes them aim wrong).
	var due: bool = int(ai.fixes) < 3 and left < float(sim.data.scenario.hostileArrival) * (1.0 - 0.3 * (int(ai.fixes) + 1))
	var close: bool = left < 2.0 * H and V.dist(s.r, mv.r) < 8000.0 and can_see(s) and not ai.get("terminal", false)
	if (due and linked(s)) or close:
		var need := _need(s, ai.arrival)
		if need.dv > sim.delta_v(s.id):
			ai.state = "aborted"
			sim.say("red_abort", Lang.f("red_abort", [sim.sensing.label_for(s.id)]), "good")
			return
		var err: float = float(s.get("spoof_err_km", 0.0))
		var aim: PackedFloat64Array = need.v1
		if err > 0.0 and not close:
			# Ranging pulled off by `err` km: it corrects toward a point that far off.
			var sol := Lambert.solve(V.add(s.r, V.of(err, -err * 0.5)), need.node, left, sim.mu)
			if not sol.is_empty():
				aim = sol[0]
		sim.burn(s.id, V.sub(aim, s.v))
		if close:
			ai.terminal = true
		else:
			ai.fixes = int(ai.fixes) + 1
	# Dodge a closing warship, once in a while, if it can still afford the job.
	if int(ai.evasions) > 0 and left > 3.0 * H and sim.t - float(ai.last_evade) > 3.0 * H and sim.t - float(ai.get("last_dodge_check", -1e9)) >= H:
		ai.last_dodge_check = sim.t
		for th in threats(s):
			if th.closing and th.range < 150000.0:
				var later := _need(s, ai.arrival + 3.0 * H)
				if later.dv < sim.delta_v(s.id) * 0.9:
					sim.burn(s.id, V.sub(later.v1, s.v))
					ai.arrival += 3.0 * H
					ai.evasions = int(ai.evasions) - 1
					ai.last_evade = sim.t
					if sim.tracks.has(s.id):
						sim.say("red_dodge", Lang.f("red_dodge", [sim.tracks[s.id].label]), "warn")
				break


func _relay(s: Dictionary) -> void:
	var plan: Dictionary = sim.by_id.r3.plan if sim.by_id.has("r3") else {}
	if plan.is_empty() or sim.by_id.r3.ai.state != "dormant":
		return
	if sim.t >= float(plan.wake_day - 1) * Sim.DAY and float(s.ai.get("wake_try", -1e9)) < sim.t - 6.0 * H:
		s.ai.wake_try = sim.t
		# A long, high-power burst: hard to miss. If it is jammed, the sleeper doesn't hear it.
		s.bursts.append({"start": sim.t, "end": sim.t + 300.0, "kind": "wake", "power": 4.0, "aim_at": "r3"})
		if linked(s):
			sim.by_id.r3.ai.state = "woken"
			sim.by_id.r3.ai.woke_at = sim.t


func _inspector(s: Dictionary) -> void:
	var ai: Dictionary = s.ai
	var plan: Dictionary = s.plan
	var tgt: Dictionary = sim.by_id.get("hydra", {})
	if tgt.is_empty() or not tgt.alive:
		return
	if ai.state == "wait" and sim.t >= float(plan.depart_day - 1) * Sim.DAY:
		ai.state = "shadow"
	if ai.state != "shadow" or not linked(s):
		return
	# Every 12 h, re-aim to arrive 20,000 km off HYDRA in 24 h, while fuel lasts.
	if sim.t - float(ai.get("last_plan", -1e9)) < 12.0 * H:
		return
	ai.last_plan = sim.t
	var f: Array = sim.predict_state(tgt.r, tgt.v, 24.0, 48)
	var node: PackedFloat64Array = V.add(f.back(), V.of(14000.0, 14000.0))
	var sol := Lambert.solve(s.r, node, 24.0 * H, sim.mu)
	if sol.is_empty():
		return
	var dv := V.sub(sol[0], s.v)
	if V.norm(dv) < sim.delta_v(s.id) * 0.6:
		sim.burn(s.id, dv)
		if sim.tracks.has(s.id) and V.dist(s.r, tgt.r) < 60000.0:
			sim.say("inspector_close", Lang.f("inspector_close", [sim.tracks[s.id].label, "HYDRA"]), "warn")


## The shadowing: an uncooperative rendezvous and proximity operation on Blue's
## radar satellite, in the order LeoLabs reported the real one (Oct 2026):
## close in from long range, reposition ahead of and behind the target,
## loiter in extreme proximity, then a controlled departure. Its legs are
## plan.legs, [along-track km (+ ahead), hours to hold there, hours to get there];
## each hop is two burns (go, then match) that its handler must command, so a
## hop waits while the link is down. Lost its link for LOST_H inside 200 km
## with a Blue ship shadowing it (within PRESENCE_KM), it retreats on its own to
## a higher, slower orbit and drifts off, as visiting vehicles abort an approach
## on loss of contact (Progress M-06M, 2010). Cut off but alone, it holds its
## slot and waits for its link: an autonomous vehicle's safe choice when nothing
## threatens it (design values). So jamming from afar stalls it; it takes
## jamming and presence together to make it leave.
## Running out of legs means the inspection is complete.
const LOST_H := 3.0
const PRESENCE_KM := 25.0 # design value: wide enough that one MATCH keeps you inside it for the 3 h cut-off (a match drifts ~20 km in 3 h)


## The nearest live Blue ship within PRESENCE_KM of s, or "".
func _shadowed_by(s: Dictionary) -> String:
	var best := ""
	var bd := PRESENCE_KM
	for b in sim.blue_ships():
		if b.has("onMoon") or b.get("kind", "") in ["station", "kv", "buoy", "freighter", "commercial"]: # a warship, not its target or a buoy
			continue
		var d := V.dist(b.r, s.r)
		if d <= bd:
			bd = d
			best = b.id
	return best


func _shadow(s: Dictionary) -> void:
	var ai: Dictionary = s.ai
	var tgt: Dictionary = sim.by_id.get(String(s.plan.get("target", "")), {})
	if tgt.is_empty() or not tgt.alive or ai.state in ["departed", "complete"]:
		return
	var up := linked(s)
	if up:
		ai.last_link = sim.t
	var rng := V.dist(s.r, tgt.r)
	match ai.state:
		"retreat":
			if rng > 200.0:
				ai.state = "departed"
				sim.say("shadow_gone", Lang.f("shadow_gone", [_label(s), Lang.km(rng)]), "good", {"from": s.id})
			return
		"match":
			if sim.t >= float(ai.match_at) - 1.0:
				sim.burn(s.id, V.sub(_slot_v(s, tgt), s.v))
				ai.state = "hold"
				ai.hold_until = sim.t + float(s.plan.legs[ai.leg][1]) * H
				_report(s)
				if sim.tracks.has(s.id):
					sim.say("shadow_hold", Lang.f("shadow_hold", [_label(s), _where_rel(float(s.plan.legs[ai.leg][0])), tgt.short]), "warn", {"from": s.id})
	var cut_off: bool = ai.state in ["match", "hold"] and rng < 200.0 and sim.t - float(ai.last_link) > LOST_H * H
	if cut_off and _shadowed_by(s) == "":
		# Cut off but nobody alongside: it holds and waits for its link.
		if not ai.get("told_waiting", false) and sim.tracks.has(s.id):
			ai.told_waiting = true
			sim.say("shadow_waits", Lang.f("shadow_waits", [_label(s), Lang.km(PRESENCE_KM)]), "warn", {"from": s.id})
	elif cut_off:
		# Lost its handler with one of ours alongside: back off to a safe, higher orbit (~40 km up).
		sim.burn(s.id, V.scale(V.scale(s.v, 1.0 / V.norm(s.v)), 0.004))
		ai.state = "retreat"
		sim.say("shadow_retreat", Lang.f("shadow_retreat", [_label(s)]), "good", {"from": s.id})
		return
	if not up:
		return
	if ai.state == "phase" or (ai.state == "hold" and sim.t >= float(ai.hold_until)):
		if ai.state == "hold":
			ai.leg = int(ai.leg) + 1
		if int(ai.leg) >= s.plan.legs.size():
			ai.state = "complete"
			sim.burn(s.id, V.scale(V.scale(s.v, 1.0 / V.norm(s.v)), 0.004))
			sim.say("shadow_done", Lang.f("shadow_done", [_label(s), tgt.short]), "alert", {"from": s.id})
			return
		_hop(s, tgt)


## Go to the next leg's slot: Lambert, corrected under full gravity, arriving on a look.
func _hop(s: Dictionary, tgt: Dictionary) -> void:
	var ai: Dictionary = s.ai
	var leg: Array = s.plan.legs[ai.leg]
	var tof := maxf(1.0, roundf(float(leg[2]) * H / Sim.LOOK)) * Sim.LOOK
	var st := sim.gravity.coast(tgt.r, tgt.v, sim.t, tof, 60.0)
	var node := V.add(st[0], V.scale(V.scale(st[1], 1.0 / V.norm(st[1])), float(leg[0])))
	var sol := Lambert.solve(s.r, node, tof, sim.mu)
	if sol.is_empty():
		return
	var plan := {"id": s.id, "node": node, "arrive": sim.t + tof, "dv_vec": V.sub(sol[0], s.v)}
	sim.refine(plan)
	if V.norm(plan.dv_vec) * 2.2 > sim.delta_v(s.id):
		ai.state = "complete"
		return
	sim.burn(s.id, plan.dv_vec)
	ai.state = "match"
	ai.match_at = plan.arrive
	_report(s)


## The velocity that keeps it in its slot: the target's, turned through the
## angle between them, so it rides the same circular orbit a little ahead or behind.
func _slot_v(s: Dictionary, tgt: Dictionary) -> PackedFloat64Array:
	var a := atan2(tgt.r[0] * s.r[1] - tgt.r[1] * s.r[0], V.dot(tgt.r, s.r))
	var v: PackedFloat64Array = tgt.v
	return V.of(v[0] * cos(a) - v[1] * sin(a), v[0] * sin(a) + v[1] * cos(a))


## Each manoeuvre is followed by a report home: something for Blue to hear.
func _report(s: Dictionary) -> void:
	if s.cls.has("ttc") and sim.t >= float(s.ai.silent_until):
		s.bursts.append({"start": sim.t, "end": sim.t + float(s.cls.ttc.burst), "kind": "ttc"})


func _label(s: Dictionary) -> String:
	return sim.tracks[s.id].label if sim.tracks.has(s.id) else "An unknown craft"


func _where_rel(along: float) -> String:
	return ("%s ahead of" if along > 0.0 else "%s behind") % Lang.km(absf(along))


func _sleeper(s: Dictionary) -> void:
	var ai: Dictionary = s.ai
	var tgt: Dictionary = sim.by_id.get("excal", {})
	if tgt.is_empty():
		return
	if ai.state == "woken" and sim.t - float(ai.woke_at) > 2.0 * H:
		# Its strike: arrive on EXCALIBUR in 30 h.
		var f: Array = sim.predict_state(tgt.r, tgt.v, 30.0, 60)
		var sol := Lambert.solve(s.r, f.back(), 30.0 * H, sim.mu)
		if not sol.is_empty() and V.norm(V.sub(sol[0], s.v)) < sim.delta_v(s.id):
			sim.burn(s.id, V.sub(sol[0], s.v))
			ai.state = "strike"
			ai.arrival = sim.t + 30.0 * H
			ai.fixes = 0
			sim.say("sleeper_burn", Lang.f("sleeper_burn", [_where(s)]), "alert")
		return
	if ai.state != "strike":
		return
	var left: float = ai.arrival - sim.t
	var d := V.dist(s.r, tgt.r)
	if d < float(s.cls.kill_km) and tgt.alive:
		tgt.alive = false
		ai.state = "done"
		sim.say("excal_dead", Lang.f("excal_dead", []), "alert")
		return
	# Homing: it needs its own IR on the target. Blinded, it flies on blind and misses.
	if left > 0.0 and left < 15.0 * H and can_see(s) and sim.sensing.ir_sees(s, tgt) and int(ai.fixes) < 4 and sim.t - float(ai.get("last_fix", -1e9)) > 3.0 * H:
		var f: Array = sim.predict_state(tgt.r, tgt.v, left / H, maxi(8, int(left / 1800.0)))
		var sol := Lambert.solve(s.r, f.back(), maxf(left, 600.0), sim.mu)
		if not sol.is_empty():
			var dv := V.sub(sol[0], s.v)
			if V.norm(dv) < sim.delta_v(s.id):
				sim.burn(s.id, dv)
				ai.fixes = int(ai.fixes) + 1
				ai.last_fix = sim.t
	if left < -6.0 * H:
		ai.state = "spent"


## Heat discipline: go dark on the heat sink while any Blue telescope it knows
## of (warships it has seen or been told of, and Ganymede's fixed site) would
## still see the radiator's edge, and put off refreezing the sink while the
## extra heat that takes would show.
func _heat(s: Dictionary) -> void:
	if not s.cls.has("thermal") or not s.cls.thermal.has("radiator") or not s.has("heat"):
		return
	var h: Dictionary = s.heat
	var eyes := []
	for th in threats(s):
		if th.s.cls.has("ir"):
			eyes.append(th.s)
	if sim.by_id.has("gstn") and sim.by_id.gstn.alive:
		eyes.append(sim.by_id.gstn)
	if eyes.is_empty():
		return
	var Q := Thermal.waste(s.cls)
	var exposed := _shows(s, eyes, Q)
	var sink: Dictionary = s.cls.thermal.get("sink", {})
	var room := not sink.is_empty() and float(h.get("stored", 0.0)) < 0.9 * float(sink.kg) * float(sink.kJkg) * 1000.0
	if exposed and room and not h.get("dark", false):
		h.dark = true
	elif not exposed and h.get("dark", false):
		h.dark = false
	h.hold = float(h.get("stored", 0.0)) > 0.0 and _shows(s, eyes, Q * (1.0 + Thermal.RECHARGE))


## Would any of these telescopes see the radiator's edge, rejecting Q?
func _shows(s: Dictionary, eyes: Array, Q: float) -> bool:
	var ri := Thermal.radiator_I(s.cls.thermal.radiator, Thermal.radiator_T(s.cls.thermal.radiator, Q), PI / 2.0)
	var skin := Thermal.grey_band(s.cls.sig, sim.thermal.skin_now(s))
	for b in eyes:
		var R := V.dist(b.r, s.r) * 1000.0
		if (skin + float(ri.edge)) / (R * R) / float(b.cls.ir.get("neiBand", b.cls.ir.nei)) >= float(sim.data.cfg.ir.band.threshold):
			return true
	return false


func _where(s: Dictionary) -> String:
	return sim.sensing._where(s.r)
