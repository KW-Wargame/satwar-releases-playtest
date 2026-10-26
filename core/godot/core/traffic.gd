## Civil radio traffic: the relays, probes and tugs that share the Jovian
## X-band with Red. Each reports on its own schedule; ears hear them like any
## other burst, so the waterfall is busy and the work is telling Red's few
## quiet reports from everyone else's. Some sit close to Red's frequencies on
## purpose. They have their own random stream, so Red's draws are unchanged.
class_name Traffic
extends RefCounted

var sim: Sim
var rng := RandomNumberGenerator.new()


func _init(sim_: Sim) -> void:
	sim = sim_
	rng.seed = 2041
	for s in sim.ships:
		if s.get("kind", "") == "civil":
			s.bursts = []
			s.next_tx = rng.randf_range(0.0, float(s.cls.ttc.every[1]))


## Schedule whoever is due. Called every look.
func think() -> void:
	for s in sim.ships:
		if s.get("kind", "") != "civil" or not s.alive:
			continue
		if sim.t >= float(s.next_tx):
			var t: Dictionary = s.cls.ttc
			s.bursts.append({"start": sim.t, "end": sim.t + float(t.burst) * rng.randf_range(0.7, 1.3), "kind": "ttc"})
			s.next_tx = sim.t + rng.randf_range(float(t.every[0]), float(t.every[1]))
			if s.bursts.size() > 12:
				s.bursts = s.bursts.slice(s.bursts.size() - 12)
