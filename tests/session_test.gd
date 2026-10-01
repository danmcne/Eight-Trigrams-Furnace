extends SceneTree
## Checks of the session rules that live in main: revive, all-down, reset.
## Run: godot --headless --path . --fixed-fps 60 -s tests/session_test.gd

var failures := 0


func _initialize() -> void:
	_run()


func check(name: String, ok: bool, detail := "") -> void:
	print(("PASS  " if ok else "FAIL  ") + name + ("" if ok else "   " + detail))
	if not ok:
		failures += 1


func _run() -> void:
	var main = load("res://main.tscn").instantiate()
	root.add_child(main)
	await process_frame
	main._start_solo("arena")
	var p1: CharacterBody3D = main.local_player
	var p2: CharacterBody3D = main._spawn_player(2, "glaive")   # a second player with no input
	for t in main.toads.values():
		t.despawn()
	main.toads.clear()
	main._between_waves = true   # hold the next wave while testing
	await physics_frame

	p2.take_hit(500.0, Vector3.ZERO, null, false)
	check("heavy hit downs a player", p2.is_dead())
	p1.global_position = p2.global_position + Vector3(4.0, 0, 0)
	for k in 60:
		await physics_frame
	check("no revive without an ally beside", p2.is_dead() and p2.revive_progress == 0.0, "progress %.2f" % p2.revive_progress)

	p1.input_source = null
	p1.global_position = p2.global_position + Vector3(1.0, 0, 0)
	for k in int(main.REVIVE_TIME * 60.0) + 10:
		await physics_frame
	check("ally beside revives at half health", not p2.is_dead() and absf(p2.hp - p2.max_hp * 0.5) < 0.01, "downed=%s hp=%.1f" % [p2.is_dead(), p2.hp])

	main._between_waves = false
	p1.take_hit(500.0, Vector3.ZERO, null, false)
	p2.iframes = 0.0
	p2.take_hit(500.0, Vector3.ZERO, null, false)
	await physics_frame
	check("all down is detected", main._all_down() and main.message != "", main.message)

	main._reset_level()
	await physics_frame
	check("reset stands everyone up at full health", not p1.is_dead() and not p2.is_dead() and p1.hp == p1.max_hp and p2.hp == p2.max_hp)
	check("reset restarts at wave 1 with fresh toads", main.wave == 1 and main.toads.size() > 0 and main.kills == 0, "wave %d toads %d" % [main.wave, main.toads.size()])
	var small := 0
	for t in main.toads.values():
		if not t.big:
			small += 1
	check("two players get 60% more small toads (3 -> 5)", small == 5, "small %d" % small)

	main.queue_free()
	await process_frame
	print("%d failure(s)" % failures)
	quit(1 if failures else 0)
