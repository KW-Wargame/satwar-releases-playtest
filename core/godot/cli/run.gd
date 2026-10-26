## xGEO Core's command-line front door: run a scenario with no window and
## write what happens as JSON lines, one object per line.
##   godot --headless --path godot --script res://cli/run.gd -- [options]
## Options (all optional):
##   --scenario=res://data/campaign.json   the scenario file ("" for none)
##   --hours=24        how long to run (sim hours)
##   --step=600        seconds between snapshots (the sensor look is 600 s)
##   --seed=N          the master random seed (default: the scenario's)
##   --run=K           the run of that seed (default 0): run K of seed N is the
##                     same world everywhere; each subsystem draws from its own
##                     stream (Sim.stream), so runs 0..K-1 make a Monte Carlo set
##   --coa=path        a course of action: orders to give at set times (below)
##   --out=path        write to a file instead of standard output (a relative
##                     path is relative to the godot/ folder: Godot starts there)
##   --truth=false     also report Red's and neutrals' true states
## Lines: {"type":"start",...}, then per step {"type":"step",...} with every
## log entry since the last step, Blue's ships and Blue's tracks (the belief,
## with its 1σ ellipse); a final {"type":"end",...} with the debrief. Each
## order given adds {"type":"order",...} with whether it was carried out.
## A course of action is a JSON file {"orders": [...]}, each order one of:
##   {"t": 3600, "do": "burn", "ship": "lancer", "dv": [0.01, 0, 0]}   km/s
##   {"t": 3600, "do": "intercept", "ship": "lancer", "target": "h1", "tof": 21600}
##       a transfer that meets the target tof seconds later, planned on Blue's
##       track of a Red ship (not its truth), refined and flown
##   {"t": 3600, "do": "effect", "effect": "jam", "ship": "excal", "target": "h1"}
##       jam, spoof, dazzle, hpm, cyber or kinetic, if it can be used then
##   {"t": 3600, "do": "buoy", "ship": "lancer"}
## t is seconds from the start; the run stops at each order's time to give it.
## Units: km, km/s, s; positions are Jupiter-centred, in the game's plane.
## Nothing here touches ui/ or scenes/: it is Core alone, as the tests run it.
extends SceneTree


func _init() -> void:
	var o := _options()
	Sim.campaign_path = o.get("scenario", Sim.campaign_path)
	var sim := Sim.new("res://data/game.json", "*", int(o.get("seed", "-1")), int(o.get("run", "0")))
	var orders := []
	if o.has("coa"):
		var coa = JSON.parse_string(FileAccess.get_file_as_string(o.coa)) if FileAccess.file_exists(o.coa) else null
		if not (coa is Dictionary and coa.get("orders") is Array):
			printerr("cannot read the course of action %s" % o.coa)
			quit(1)
			return
		orders = coa.orders.duplicate()
		orders.sort_custom(func(a, b): return float(a.get("t", 0.0)) < float(b.get("t", 0.0)))
	var hours := float(o.get("hours", "24"))
	var step := maxf(1.0, float(o.get("step", str(Sim.LOOK))))
	var truth: bool = o.get("truth", "false") == "true"
	var f: FileAccess = null
	if o.has("out"):
		f = FileAccess.open(o.out, FileAccess.WRITE)
		if f == null:
			printerr("cannot write %s" % o.out)
			quit(1)
			return
	var emit := func(d: Dictionary) -> void:
		var line := JSON.stringify(d)
		if f:
			f.store_line(line)
		else:
			print(line)
	emit.call({"type": "start", "engine": "xGEO Core", "scenario": Sim.campaign_path, "name": sim.camp.get("name", ""),
		"seed": sim.master_seed, "run": sim.run, "orders": orders.size(), "utc": Time.get_datetime_string_from_unix_time(int(float(sim.data.startUtc) / 1000.0)) + "Z",
		"hours": hours, "step": step, "units": {"distance": "km", "speed": "km/s", "time": "s"}})
	var seen := sim.log.size()
	var end_t := hours * Sim.HOUR
	var next_snap := minf(step, end_t)
	while sim.t < end_t - 1e-6 and not sim.campaign.over:
		while not orders.is_empty() and float(orders[0].get("t", 0.0)) <= sim.t + 1e-6:
			emit.call(_give(sim, orders.pop_front()))
		var stop := next_snap if orders.is_empty() else minf(next_snap, float(orders[0].get("t", 0.0)))
		sim.advance(maxf(stop - sim.t, 0.0))
		if sim.t >= next_snap - 1e-6 or sim.campaign.over:
			emit.call(_snapshot(sim, sim.log.slice(seen), truth))
			seen = sim.log.size()
			next_snap = minf(next_snap + step, end_t)
	var dbf := sim.campaign.debrief() if not sim.camp.is_empty() else {}
	emit.call({"type": "end", "t": sim.t, "over": sim.campaign.over, "result": sim.campaign.result, "debrief": JSON.parse_string(JSON.stringify(dbf))})
	if f:
		f.close()
	quit(0)


## Give one order of the course of action; report whether it was carried out.
func _give(sim: Sim, order: Dictionary) -> Dictionary:
	var out := {"type": "order", "t": sim.t, "order": order, "ok": false, "why": ""}
	var id := String(order.get("ship", ""))
	var target := String(order.get("target", ""))
	if not sim.by_id.has(id) or sim.by_id[id].side != "blue":
		out.why = "no Blue ship %s" % id
		return out
	if target != "" and not sim.by_id.has(target):
		out.why = "no target %s" % target
		return out
	match String(order.get("do", "")):
		"burn":
			var dv: Array = order.get("dv", [])
			out.ok = dv.size() == 3 and sim.burn(id, V.of(float(dv[0]), float(dv[1]), float(dv[2])))
			out.why = "" if out.ok else "cannot burn that"
		"intercept":
			var plan := sim.plan_intercept(id, target, float(order.get("tof", 6.0 * Sim.HOUR)))
			out.ok = sim.execute(plan)
			out.why = "" if out.ok else String(plan.get("why", "cannot fly it"))
			if out.ok:
				out.dv = plan.dv
		"effect":
			out.ok = sim.effects.use(String(order.get("effect", "")), id, target)
			if not out.ok:
				for x in sim.effects.options(id, target):
					if x.key == order.get("effect", ""):
						out.why = String(x.get("line", ""))
				if out.why == "":
					out.why = "no such effect"
		"buoy":
			var b := sim.drop_buoy(id)
			out.ok = b != ""
			out.why = "" if out.ok else "no buoy to drop"
		_:
			out.why = "unknown order %s" % order.get("do", "")
	return out


func _snapshot(sim: Sim, new_log: Array, truth: bool) -> Dictionary:
	var ships := []
	for s in sim.ships:
		if s.side != "blue" and not truth:
			continue
		ships.append({"id": s.id, "name": s.get("name", s.id), "side": s.side, "class": s.classId, "alive": s.alive,
			"r": _v(s.r), "v": _v(s.v), "delta_v": sim.delta_v(s.id)})
	var tracks := []
	for id in sim.tracks:
		var tr: Track = sim.tracks[id]
		var e := tr.ellipse()
		var d := {"label": tr.label, "ident": tr.ident, "side": tr.side, "class": tr.class_id, "in_contact": tr.in_contact,
			"last_seen": tr.last_seen, "r": _v(tr.pos()), "v": _v(tr.vel()),
			"sigma_km": {"major": e.major, "minor": e.minor, "angle": e.angle}}
		if truth:
			d.truth = id
		tracks.append(d)
	var log := []
	for e in new_log:
		log.append({"t": e.t, "code": e.code, "kind": e.kind, "text": e.text})
	return {"type": "step", "t": sim.t, "utc": Time.get_datetime_string_from_unix_time(int(sim.utc_ms() / 1000.0)) + "Z",
		"escalation": sim.escalation, "ships": ships, "tracks": tracks, "log": log}


static func _v(a: PackedFloat64Array) -> Array:
	return Array(a)


static func _options() -> Dictionary:
	var o := {}
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--") and a.contains("="):
			var i := a.find("=")
			o[a.substr(2, i - 2)] = a.substr(i + 1)
	return o
