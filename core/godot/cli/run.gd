## xGEO Core's command-line front door: run a scenario with no window and
## write what happens as JSON lines, one object per line.
##   godot --headless --path godot --script res://cli/run.gd -- [options]
## Options (all optional):
##   --scenario=res://data/campaign.json   the scenario file ("" for none)
##   --hours=24        how long to run (sim hours)
##   --step=600        seconds between snapshots (the sensor look is 600 s)
##   --seed=N          the random seed (default: the scenario's)
##   --out=path        write to a file instead of standard output
##   --truth=false     also report Red's and neutrals' true states
## Lines: {"type":"start",...}, then per step {"type":"step",...} with every
## log entry since the last step, Blue's ships and Blue's tracks (the belief,
## with its 1σ ellipse); a final {"type":"end",...} with the debrief.
## Units: km, km/s, s; positions are Jupiter-centred, in the game's plane.
## Nothing here touches ui/ or scenes/: it is Core alone, as the tests run it.
extends SceneTree


func _init() -> void:
	var o := _options()
	Sim.campaign_path = o.get("scenario", Sim.campaign_path)
	var sim := Sim.new("res://data/game.json", "*", int(o.get("seed", "-1")))
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
		"seed": sim.rng.seed, "utc": Time.get_datetime_string_from_unix_time(int(float(sim.data.startUtc) / 1000.0)) + "Z",
		"hours": hours, "step": step, "units": {"distance": "km", "speed": "km/s", "time": "s"}})
	var seen := sim.log.size()
	var end_t := hours * Sim.HOUR
	while sim.t < end_t - 1e-6 and not sim.campaign.over:
		sim.advance(minf(step, end_t - sim.t))
		emit.call(_snapshot(sim, sim.log.slice(seen), truth))
		seen = sim.log.size()
	var dbf := sim.campaign.debrief() if not sim.camp.is_empty() else {}
	emit.call({"type": "end", "t": sim.t, "over": sim.campaign.over, "result": sim.campaign.result, "debrief": JSON.parse_string(JSON.stringify(dbf))})
	if f:
		f.close()
	quit(0)


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
