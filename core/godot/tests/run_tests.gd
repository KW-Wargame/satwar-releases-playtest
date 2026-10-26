## Physics tests, run headless:
##   godot --headless --path godot --script res://tests/run_tests.gd
## Parity: the GDScript physics against the JS engine's own results
## (tests/fixtures/parity.json, from tools/export-godot.mjs). Validation: the
## n-body integrator against exact Kepler motion, energy, and Jupiter's J2
## apsidal precession against the analytic rate.
extends SceneTree

var fails := 0
var passes := 0


func check(name: String, ok: bool, detail := "") -> void:
	if ok:
		passes += 1
	else:
		fails += 1
		print("FAIL ", name, "  ", detail)


func rel(a: float, b: float) -> float:
	return absf(a - b) / maxf(absf(b), 1e-300)


func vrel(a: PackedFloat64Array, b: Array) -> float:
	return V.dist(a, V.from(b)) / maxf(V.norm(V.from(b)), 1e-12)


func _init() -> void:
	# These check Operation NIGHT HERON (shelved), whose numbers they were written for.
	Sim.campaign_path = Sim.NIGHT_HERON
	var fx: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://tests/fixtures/parity.json"))
	var mu: float = fx.mu

	# --- parity with the JS engine ---
	for c in fx.propagate:
		var s := Kepler.propagate(V.from(c.r), V.from(c.v), c.dt, mu)
		check("propagate dt=%s" % c.dt, vrel(s[0], c.out.r) < 1e-9 and vrel(s[1], c.out.v) < 1e-9, str(vrel(s[0], c.out.r)) + " " + str(vrel(s[1], c.out.v)))
	var sim := Sim.new()
	for c in fx.moons:
		var m := sim.moon(c.id)
		var s := Kepler.from_elements(m, float(sim.data.epochOffset) + c.t, mu + float(m.gm))
		check("moon %s t=%s" % [c.id, c.t], vrel(s[0], c.out.r) < 1e-10 and vrel(s[1], c.out.v) < 1e-10)
	for c in fx.lambert:
		var sol := Lambert.solve(V.from(c.r1), V.from(c.r2), c.tof, mu)
		if c.out == null:
			check("lambert none", sol.is_empty())
		else:
			check("lambert tof=%s" % c.tof, not sol.is_empty() and vrel(sol[0], c.out.v1) < 1e-8 and vrel(sol[1], c.out.v2) < 1e-8)
	for c in fx.rf.stumpff:
		check("stumpff z=%s" % c.z, rel(Kepler.stumpff_c(c.z), c.C) < 1e-12 and rel(Kepler.stumpff_s(c.z), c.S) < 1e-12)
	for c in fx.rf.dishGain:
		check("dish gain", rel(RF.dish_gain(c.D, c.f), c.out) < 1e-12)
	var fr: Dictionary = fx.rf.friis
	check("friis", rel(RF.friis(fr.Pt, fr.Gt, fr.Gr, fr.R, fr.f), fr.out) < 1e-12)
	check("noise", rel(RF.noise(fx.rf.noise.Ts, fx.rf.noise.B), fx.rf.noise.out) < 1e-12)
	check("integrate", rel(RF.integrate(fx.rf.integrate.snr, fx.rf.integrate.B, fx.rf.integrate.tau), fx.rf.integrate.out) < 1e-12)
	check("df sigma", rel(RF.df_sigma(fx.rf.dfSigma.f, fx.rf.dfSigma.d, fx.rf.dfSigma.snr), fx.rf.dfSigma.out) < 1e-9, str(RF.df_sigma(fx.rf.dfSigma.f, fx.rf.dfSigma.d, fx.rf.dfSigma.snr)) + " vs " + str(fx.rf.dfSigma.out))
	var ttc: Dictionary = sim.data.classes.vesper.ttc
	var em := {"Pt": ttc.Pt, "G": RF.from_db(ttc.towardUsDbi), "f": ttc.f, "bw": ttc.bw}
	for c in fx.rf.interceptRangeKm:
		check("intercept range", rel(RF.intercept_range_km(em, c.esm, ttc.burst, fx.detectSnr), c.out) < 1e-12)
	for c in fx.rf.signature:
		var r := RF.signature_ranges(c.sig, c.engine, fx.nei)
		check("IR range %s" % c.id, rel(r.cold, c.out.cold) < 1e-12 and rel(r.burning, c.out.burning) < 1e-12)
	for c in fx.rf.deltaV:
		check("delta-v %s" % c.id, rel(RF.delta_v(c.ve, c.dry, c.prop), c.out) < 1e-12)

	# --- the integrator: with J2 and the moons off it must reproduce Kepler ---
	var g := Gravity.new(mu, sim.moons, sim.moon_state)
	g.use_j2 = false
	g.use_moons = false
	var hy: Dictionary = sim.ship("hydra")
	var exact := Kepler.propagate(hy.r, hy.v, 86400.0, mu)
	var num := g.coast(hy.r, hy.v, 0.0, 86400.0, 60.0)
	check("RK4 = Kepler over a day", V.dist(num[0], exact[0]) < 0.01, "%f km" % V.dist(num[0], exact[0]))
	var e0 := Kepler.energy(hy.r, hy.v, mu)
	check("energy kept", rel(Kepler.energy(num[0], num[1], mu), e0) < 1e-10)

	# --- J2 turns an eccentric equatorial orbit's periapsis at 1.5 n J2 (R/p)² ---
	# (dω/dt + dΩ/dt at i = 0; Vallado 2013 eq. 9-41, Curtis 2020 eq. 4.52–4.53)
	g.use_j2 = true
	var a := 300000.0
	var e := 0.3
	var rp := a * (1.0 - e)
	var r0 := V.of(rp, 0.0)
	var v0 := V.of(0.0, sqrt(mu * (1.0 + e) / rp))
	var n := sqrt(mu / (a * a * a))
	var p := a * (1.0 - e * e)
	var rate := 1.5 * n * Gravity.J2 * pow(Gravity.R_REF / p, 2.0)
	var days := 60.0
	var st := g.coast(r0, v0, 0.0, days * 86400.0, 30.0)
	var ev := V.sub(V.scale(V.cross(st[1], V.cross(st[0], st[1])), 1.0 / mu), V.scale(st[0], 1.0 / V.norm(st[0])))
	var drift := atan2(ev[1], ev[0])
	var want := fmod(rate * days * 86400.0 + PI, TAU) - PI
	check("J2 apsidal precession", rel(drift, want) < 0.03, "got %.5f rad, analytic %.5f" % [drift, want])

	# --- the moons matter: Ganymede's pull over a week, near its orbit ---
	g.use_moons = true
	var with_moons := g.coast(hy.r, hy.v, 0.0, 7 * 86400.0, 60.0)
	g.use_moons = false
	var without := g.coast(hy.r, hy.v, 0.0, 7 * 86400.0, 60.0)
	var gap := V.dist(with_moons[0], without[0])
	check("moons perturb HYDRA over a week", gap > 100.0, "%f km" % gap)
	print("moons move HYDRA %.0f km in a week" % gap)

	# --- hearing: GAN STN hears a report out to the engine's range ---
	# (Red's reporting habit is the scenario's: Core alone, with no scenario file, has none to hear.)
	sim.advance(3.0 * 3600.0)
	if not sim.camp.is_empty():
		check("first report heard by someone", sim.intercepts.size() >= 1, "%d intercepts" % sim.intercepts.size())

	# --- an intercept flown under real gravity: Lambert aims, gravity drifts it, one correction fixes it ---
	var game := Sim.new()
	var plan := game.plan_intercept("hydra", "h1", 18.0 * 3600.0, true)
	check("intercept plan affordable", plan.ok, str(plan.get("why")))
	game.execute(plan)
	var best := INF
	var miss_first := 0.0
	for i in 18 * 6:
		if i == 9 * 6:
			var fix := game.plan_intercept("hydra", "h1", plan.arrive - game.t, true)
			miss_first = V.dist(game.predict("hydra", (plan.arrive - game.t) / 3600.0, 54).back(), fix.node)
			game.execute(fix)
		game.advance(600.0)
		best = minf(best, game.range_km("hydra", "h1"))
	for i in 60:
		game.advance(30.0)
		best = minf(best, game.range_km("hydra", "h1"))
	print("without the correction HYDRA would miss by %.0f km; with it, closest %.1f km" % [miss_first, best])
	check("correction brings HYDRA within 50 km", best < 50.0, "%f km" % best)
	print("%d passed, %d failed" % [passes, fails])
	quit(1 if fails > 0 else 0)
