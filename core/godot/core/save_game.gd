## Save and continue: the whole running world in one file (user://), written
## with Godot's own var_to_str so packed arrays survive exactly.
class_name SaveGame

const PATH := "user://night_heron.save"
const SHIP_SKIP := ["cls", "plan_ref"]


static func save(sim: Sim) -> void:
	var ships := []
	for s in sim.ships:
		var d := {}
		for k in s:
			if not SHIP_SKIP.has(k):
				d[k] = s[k]
		ships.append(d)
	var tracks := {}
	for id in sim.tracks:
		var tr: Track = sim.tracks[id]
		tracks[id] = {"label": tr.label, "x": tr.x, "P": tr.P, "t": tr.t, "ident": tr.ident, "class_id": tr.class_id, "side": tr.side, "last_seen": tr.last_seen, "in_contact": tr.in_contact, "intercepts": tr.intercepts, "lkp": tr.lkp, "lkp_t": tr.lkp_t}
	var state := {"t": sim.t, "next_look": sim.next_look, "escalation": sim.escalation, "ships": ships, "tracks": tracks, "track_n": sim.track_n,
		"intercepts": sim.intercepts, "log": sim.log, "debris": sim.debris, "scheduled": sim.scheduled, "rng": sim.rng.state,
		"jamming": sim.effects.jamming, "kvs": sim.effects.kvs, "radar": sim.effects.radar_on, "found": sim.campaign.found, "pending": sim.sensing.pending,
		"auto": sim.sensing.auto, "dish_aim": sim.sensing.dish_aim, "last_look": sim.sensing.last_look, "doctrinal": Lang.doctrinal}
	var f := FileAccess.open(PATH, FileAccess.WRITE)
	f.store_string(var_to_str(state))


static func load_into(sim: Sim) -> bool:
	if not FileAccess.file_exists(PATH):
		return false
	var state = str_to_var(FileAccess.get_file_as_string(PATH))
	if typeof(state) != TYPE_DICTIONARY:
		return false
	sim.t = state.t
	sim.next_look = state.next_look
	sim.escalation = state.escalation
	sim.ships.clear()
	sim.by_id.clear()
	for d in state.ships:
		d.cls = Damage.cls_for(sim.data.classes[d.classId], d.get("damage", []))
		sim.ships.append(d)
		sim.by_id[d.id] = d
	sim.tracks.clear()
	for id in state.tracks:
		var s: Dictionary = state.tracks[id]
		var tr := Track.new(id, s.label, s.x, s.P, s.t)
		for k in ["ident", "class_id", "side", "last_seen", "in_contact", "intercepts", "lkp_t"]:
			tr.set(k, s.get(k, tr.get(k)))
		tr.lkp = PackedFloat64Array(s.get("lkp", tr.pos()))
		sim.tracks[id] = tr
	sim.track_n = state.track_n
	sim.intercepts = state.intercepts
	sim.log = state.log
	sim.debris = state.debris
	sim.scheduled = state.scheduled
	sim.rng.state = state.rng
	sim.effects.jamming = state.jamming
	sim.effects.kvs = state.kvs
	sim.effects.radar_on = state.radar
	sim.campaign.found = state.found
	sim.sensing.pending = state.pending
	sim.sensing.auto = state.auto
	sim.sensing.dish_aim = state.get("dish_aim", {})
	sim.sensing.last_look = state.last_look
	Lang.doctrinal = state.doctrinal
	return true
