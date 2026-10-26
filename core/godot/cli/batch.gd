## xGEO Core's batch runner: many runs of a scenario for each course of action,
## one JSON line of outcomes per run, for Monte Carlo and course-of-action
## comparison.
##   godot --headless --path godot --script res://cli/batch.gd -- --coa=a.json,b.json [options]
## Options:
##   --coa=a.json,b.json  the courses of action, comma-separated (core/orders.gd);
##                        "none" plays one with no orders
##   --runs=20            runs 0..19 of the seed; or a range, --runs=20-39, so
##                        several processes can share a batch
##   --scenario=, --seed=, --hours=72, --out=   as cli/run.gd
## Common random numbers: run k of a seed is the same world for every course of
## action (Sim.stream: every subsystem's stream starts from seed, run and name),
## so two courses of action meet the same opening track error, the same
## detections and the same chance draws until their own orders change what
## happens. The difference between them is then measured on paired runs, with
## far less noise than independent runs give (Law 2015, Simulation Modeling and
## Analysis, 5th ed., §11.2).
## Lines: {"type":"batch", ...} first, then one {"type":"run", coa, run, ...} per
## run and course of action, in run order, each course of action in turn.
extends SceneTree


func _init() -> void:
	var o := _options()
	Sim.campaign_path = o.get("scenario", Sim.campaign_path)
	var coas := []
	for path in String(o.get("coa", "none")).split(","):
		var list = [] if path == "none" else Orders.read(path)
		if list == null:
			printerr("cannot read the course of action %s" % path)
			quit(1)
			return
		coas.append({"name": path.get_file().get_basename() if path != "none" else "none", "path": path, "orders": list})
	var span := String(o.get("runs", "20")).split("-")
	var first := int(span[0]) if span.size() == 2 else 0
	var last := int(span[1]) if span.size() == 2 else int(span[0]) - 1
	var hours := float(o.get("hours", "72"))
	var seed := int(o.get("seed", "-1"))
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
			f.flush()
		else:
			print(line)
	var probe := Sim.new("res://data/game.json", "*", seed, first)
	emit.call({"type": "batch", "engine": "xGEO Core", "scenario": Sim.campaign_path, "name": probe.camp.get("name", ""), "seed": probe.master_seed,
		"runs": [first, last], "hours": hours, "coas": coas.map(func(c): return {"name": c.name, "path": c.path, "orders": c.orders.size()})})
	probe = null
	for k in range(first, last + 1):
		for c in coas:
			emit.call(play(seed, k, c, hours))
	if f:
		f.close()
	quit(0)


## One run of one course of action, to the end of the operation or of hours.
static func play(seed: int, run: int, coa: Dictionary, hours: float) -> Dictionary:
	var sim := Sim.new("res://data/game.json", "*", seed, run)
	var orders := Orders.new(coa.orders)
	var dv0 := {}
	for s in sim.blue_ships():
		if s.cls.has("engine"):
			dv0[s.id] = sim.delta_v(s.id)
	var end_t := hours * Sim.HOUR
	while sim.t < end_t - 1e-6 and not sim.campaign.over:
		orders.due(sim)
		sim.advance(maxf(minf(minf(orders.next_t(), sim.t + Sim.LOOK), end_t) - sim.t, 0.0))
	var used := 0.0
	for id in dv0:
		used += float(dv0[id]) - (sim.delta_v(id) if sim.by_id[id].alive else 0.0)
	var dbf: Dictionary = JSON.parse_string(JSON.stringify(sim.campaign.debrief())) if not sim.camp.is_empty() else {}
	var objectives := {}
	for x in dbf.get("objectives", []):
		objectives[x.id] = x.state
	var refused := orders.reports.filter(func(r): return not r.ok).map(func(r): return "%s at %d s: %s" % [r.order.do, int(r.t), r.why])
	return {"type": "run", "coa": coa.name, "run": run, "seed": sim.master_seed, "t_end": sim.t, "over": sim.campaign.over,
		"result": sim.campaign.result, "won": sim.campaign.result == "won", "escalation": sim.escalation, "blue_dv_used": used,
		"objectives": objectives, "reds": dbf.get("reds", []), "debris": sim.debris.size(),
		"orders": {"given": orders.reports.size(), "ok": orders.reports.size() - refused.size(), "refused": refused}}


static func _options() -> Dictionary:
	var o := {}
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--") and a.contains("="):
			var i := a.find("=")
			o[a.substr(2, i - 2)] = a.substr(i + 1)
	return o
