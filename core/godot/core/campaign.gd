## The campaign's bookkeeping: objectives, pockets found, how it ends, and the
## debrief. Objectives and their wording come from the campaign file: the
## shadowing (data/campaign.json) or Operation NIGHT HERON (night_heron.json).
class_name Campaign
extends RefCounted

## The world this belongs to, held weakly: Sim holds this too, and a strong
## reference each way is a cycle that RefCounted never frees.
var sim: Sim:
	get:
		return _sim.get_ref()
	set(v):
		_sim = weakref(v)
var _sim := WeakRef.new()
var found := {} # pocket id -> time found
var over := false
var result := "" # "won", "lost", "time"
var why := ""
var ended_by := "" # the objective whose failure ended it
var ended_at := 0.0 # sim time it ended


func _init(sim_: Sim) -> void:
	sim = sim_


func pockets_with_red() -> Array:
	var ids := []
	for r in sim.red_ships():
		if r.has("pocket") and not ids.has(r.pocket):
			ids.append(r.pocket)
	return ids


## Red neutralized: destroyed, captured, disabled, out of fuel for its job, or never woken.
func neutralized(r: Dictionary) -> bool:
	if not r.alive or r.get("captured", false) or r.get("disabled", false):
		return true
	var st: String = r.get("ai", {}).get("state", "")
	return st in ["aborted", "missed", "spent", "departed"] or (r.role == "sleeper" and st == "dormant" and sim.t >= float(r.plan.wake_day) * Sim.DAY and not _relay_alive())


## The shadowing craft, if this campaign has one.
func _shadow() -> Dictionary:
	for r in sim.red_ships():
		if r.get("role", "") == "shadow":
			return r
	return {}


func _relay_alive() -> bool:
	var r: Dictionary = sim.by_id.get("r1", {})
	return not r.is_empty() and r.alive and not r.get("captured", false) and not r.get("disabled", false)


func status() -> Array:
	var out := []
	var mv_taken: bool = sim.by_id.get("h1", {}).get("ai", {}).get("boarded", false)
	var excal_alive: bool = sim.by_id.get("excal", {}).get("alive", true)
	var need := pockets_with_red()
	var sl: Dictionary = sim.by_id.get("r3", {})
	for o in sim.camp.get("objectives", []):
		var st := "open"
		match o.id:
			"protect":
				st = "failed" if mv_taken else ("done" if neutralized(sim.by_id.h1) else "open")
			"find":
				st = "done" if found.size() >= need.size() else "open"
			"sleeper":
				st = "done" if not sl.is_empty() and neutralized(sl) and sl.ai.state in ["dormant", "spent"] or (not sl.is_empty() and (not sl.alive or sl.get("disabled", false) or sl.get("captured", false))) else ("failed" if sl.get("ai", {}).get("state", "") == "done" else "open")
			"excal":
				st = "failed" if not excal_alive else ("done" if over else "open")
			"signal":
				st = "done" if sim.intercepts.any(func(r): return sim.by_id[r.ship].get("role", "") == "shadow" and r.classified) else "open"
			"stop":
				var sh := _shadow()
				st = "failed" if sh.get("ai", {}).get("state", "") == "complete" else ("done" if not sh.is_empty() and neutralized(sh) else "open")
			"debris":
				st = "failed" if not sim.debris.is_empty() else ("done" if over else "open")
			"protect_sat":
				var asset: Dictionary = sim.by_id.get(String(_shadow().get("plan", {}).get("target", "")), {})
				st = "failed" if not asset.is_empty() and not asset.alive else ("done" if over else "open")
			"peace":
				st = "failed" if sim.escalation >= float(sim.camp.escalation.war) else ("done" if over else "open")
		var progress := ""
		if o.id == "find":
			progress = "%d of %d" % [found.size(), need.size()]
		out.append({"id": o.id, "text": o.text, "state": st, "fail": o.fail, "progress": progress})
	return out


func check() -> void:
	if over:
		return
	# A pocket is found when a classified hostile track sits inside it, tight enough to say so.
	for p in sim.camp.get("pockets", []):
		if found.has(p.id):
			continue
		for id in sim.tracks:
			var tr: Track = sim.tracks[id]
			if tr.side != "hostile" or sim.by_id[id].get("pocket", "") != p.id:
				continue
			var c := sim.pocket_center(p)
			var inside := V.dist(tr.pos(), c) < float(p.get("size", p.get("width", 200000.0))) * 1.5 if p.kind == "lagrange" else absf(V.norm(tr.pos()) - float(p.radius)) < float(p.width)
			if inside and tr.ellipse().major < float(p.get("size", p.get("width", 200000.0))):
				found[p.id] = sim.t
				sim.say("pocket_found", Lang.f("pocket_found", [p.name]), "good")
				break
	for o in status():
		if o.fail and o.state == "failed":
			ended_by = String(o.id)
			_end("lost", o.text)
			return
	if sim.red_ships().all(func(r): return neutralized(r)) and found.size() >= pockets_with_red().size():
		_end("won", "Every Red asset is out of the fight.")
	elif sim.camp.has("days") and sim.t >= float(sim.camp.days) * Sim.DAY:
		_end("time", "The operation's %d days are up." % int(sim.camp.days))


func _end(res: String, reason: String) -> void:
	over = true
	result = res
	why = reason
	ended_at = sim.t


## Grades for the debrief: what was done, and at what price.
func debrief() -> Dictionary:
	var reds := []
	for r in sim.red_ships():
		var how := "still active"
		if r.get("captured", false):
			how = "captured"
		elif r.get("destroyed", false):
			how = "destroyed (debris)"
		elif r.get("disabled", false):
			how = "disabled"
		elif neutralized(r):
			how = "out of the fight (%s)" % String(r.ai.state)
		reds.append({"name": sim.tracks[r.id].label if sim.tracks.has(r.id) else "never found", "class": r.cls.name, "how": how})
	# What to do differently: the advice of each failed objective, the one that ended it first.
	var advice := []
	var objs: Array = sim.camp.get("objectives", [])
	for o in status():
		if o.state != "failed":
			continue
		var a := ""
		for c in objs:
			if c.id == o.id:
				a = String(c.get("advice", ""))
		if a != "":
			if o.id == ended_by:
				advice.push_front(a)
			else:
				advice.append(a)
	return {"result": result, "why": why, "advice": advice, "objectives": status(), "reds": reds, "escalation": sim.escalation, "days": sim.t / Sim.DAY, "debris": sim.debris.size()}
