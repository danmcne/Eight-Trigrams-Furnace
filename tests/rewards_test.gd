extends SceneTree
## Milestone 7: the little demons, the pedestals (gourd, vase, peach), the
## two-chamber gourd, class switching and the cheats.
## Run: godot --headless --path . --fixed-fps 60 -s tests/rewards_test.gd

const Dungeon := preload("res://dungeon.gd")
const Intent := preload("res://intent.gd")

var failures := 0
var main: Node


func _initialize() -> void:
	_run()


func check(name: String, ok: bool, detail := "") -> void:
	print(("PASS  " if ok else "FAIL  ") + name + ("" if ok else "   " + detail))
	if not ok:
		failures += 1


func fresh() -> CharacterBody3D:
	if main:
		main.queue_free()
		await process_frame
	Engine.time_scale = 1.0
	main = load("res://main.tscn").instantiate()
	root.add_child(main)
	await process_frame
	main._start_solo("reed_marsh")
	var p: CharacterBody3D = main.local_player
	p.input_source = null
	for t in main.toads.values():
		t.aggro_range = 0.0
	await physics_frame
	return p


func place(p: Node3D, tile: Vector2i) -> void:
	p.global_position = Vector3(tile.x * 2.0 + 1.0, 0.05, tile.y * 2.0 + 1.0)


func prop_at(tile: Vector2i):
	for pr in main.dungeon.props:
		if tile in pr.tiles:
			return pr
	return null


func use(p: Node3D, toward: Vector3) -> void:
	var d := toward - p.global_position
	d.y = 0.0
	main.dungeon.gourd_use(p, d.normalized())


func steps(n: int) -> void:
	for k in n:
		await physics_frame


func _run() -> void:
	# ---- The gourd pedestal and the little demons ----
	var p := await fresh()
	var gp = prop_at(Vector2i(27, 3))
	var demons := []
	for e in main.toads.values():
		if "boss_name" in e and e.kind in ["clever", "wily"]:
			demons.append(e)
	check("two little demons guard the gourd, as siblings", demons.size() == 2 and demons[0].sibling == demons[1])
	check("the gourd's pedestal is sealed while they stand", gp.kind == "pickup" and gp.item == "gourd" and gp.state == 0)
	for d in demons:
		d.take_hit(1.0e6, Vector3.ZERO)
	await steps(3)
	check("their fall unseals it and opens the door", gp.state == 1 and prop_at(Vector2i(25, 7)).state == 1, "pedestal %d door %d" % [gp.state, prop_at(Vector2i(25, 7)).state])
	place(p, Vector2i(27, 3))
	await steps(3)
	check("walking over it takes the gourd", gp.state == 2 and p.has_gourd and p.gourd_slots == 1)

	# ---- Two chambers ----
	p.gourd_slots = 2
	var ef = prop_at(Vector2i(25, 10))
	place(p, Vector2i(25, 12))
	use(p, ef.point_near(p.global_position))
	check("with room in the gourd, facing a source draws it in", p.held() == [Dungeon.FIRE])
	use(p, ef.point_near(p.global_position))
	check("the second chamber takes a second draw", p.held() == [Dungeon.FIRE, Dungeon.FIRE])
	p.set_held([Dungeon.FIRE, Dungeon.WATER])
	var fw = prop_at(Vector2i(10, 10))
	fw.set_state(0)
	place(p, Vector2i(11, 10))
	var moat = prop_at(Vector2i(11, 8))
	moat.set_state(1)   # drained, so the player can stand beside the wall
	use(p, fw.point_near(p.global_position))
	check("pouring picks what the target accepts, not merely the oldest", fw.state == 1 and p.held() == [Dungeon.FIRE], "wall %d held %s" % [fw.state, p.held()])
	p.set_held([Dungeon.WATER, Dungeon.FIRE])
	place(p, Vector2i(15, 10))
	use(p, p.global_position + Vector3(0, 0, -5))   # nothing there
	check("into nothing, the oldest goes first", p.held() == [Dungeon.FIRE], str(p.held()))
	var br = prop_at(Vector2i(22, 12))
	br.set_state(1)
	p.set_held([Dungeon.WATER])
	place(p, Vector2i(22, 10))
	use(p, br.point_near(p.global_position))
	check("with room left, facing a lit brazier draws its fire (it goes out)", p.held() == [Dungeon.WATER, Dungeon.FIRE] and br.state == 0, "%s %d" % [p.held(), br.state])

	# ---- The kings' rewards ----
	p = await fresh()
	var vase = prop_at(Vector2i(26, 16))
	var peach = prop_at(Vector2i(28, 18))
	var other: CharacterBody3D = main._spawn_player(2, "bow")
	other.input_source = null
	p.has_gourd = true
	check("the vase and peach are sealed while the kings stand", vase.state == 0 and peach.state == 0)
	for e in main.toads.values():
		if "boss_name" in e and e.kind in ["golden", "silver"]:
			e.take_hit(1.0e6, Vector3.ZERO)
	await steps(3)
	check("the kings' fall unseals both, and the exit", vase.state == 1 and peach.state == 1 and prop_at(Vector2i(28, 16)).state == 1)
	place(other, Vector2i(26, 16))   # the bow player takes the vase
	await steps(3)
	check("the vase joins the gourd, whoever takes it", p.gourd_slots == 2 and not other.has_gourd, "holder slots %d, taker gourd %s" % [p.gourd_slots, other.has_gourd])
	var before := [p.max_hp, other.max_hp]
	place(other, Vector2i(28, 18))
	await steps(3)
	check("a peach strengthens every player", p.max_hp == before[0] + p.PEACH_HP and other.max_hp == before[1] + other.PEACH_HP and other.hp == other.max_hp)

	# ---- Springs heal ----
	p = await fresh()
	p.hp = 40.0
	place(p, Vector2i(2, 20))   # the spring before the kings' door
	await steps(60)
	check("standing in a spring heals (about 10 per second)", p.hp > 48.0 and p.hp < 52.0, "hp %.1f" % p.hp)

	# ---- Class switching keeps what you had ----
	p = await fresh()
	p.has_gourd = true
	p.gourd_slots = 2
	p.set_held([Dungeon.WATER, Dungeon.TOAD])
	p.add_peach()
	p.hp = p.max_hp * 0.5
	p.qi = 33.0
	var msg: String = main._cheat("class dao")
	var q: CharacterBody3D = main.local_player
	check("switching class keeps health as a fraction, qi, gourd, vase, contents and peaches",
		q != p and q.kit_name == "dao" and absf(q.hp - q.max_hp * 0.5) < 0.01 and q.max_hp == 85.0 + q.PEACH_HP and q.qi == 33.0
		and q.has_gourd and q.gourd_slots == 2 and q.held() == [Dungeon.WATER, Dungeon.TOAD], "%s hp %.1f/%.1f qi %.0f held %s" % [msg, q.hp, q.max_hp, q.qi, q.held()])

	# ---- Cheats ----
	main._cheat("god")
	check("god: nothing hurts", q.take_hit(50.0, Vector3.ZERO, null, false) == "ignored" and q.god)
	main._cheat("warp kings")
	check("warp kings: into the hall", main.dungeon.share_room(q.global_position, main.dungeon.enemy_spawns.filter(func(sp): return sp["kind"] == "golden")[0]["pos"]))
	var alive := 0
	main._cheat("kill")
	await steps(2)
	for e in main.toads.values():
		if not e.is_dead() and main.dungeon.share_room(e.global_position, q.global_position):
			alive += 1
	check("kill: everything in the room", alive == 0)
	main._cheat("open")
	var all_open := true
	for pr in main.dungeon.props:
		if pr.kind == "door":
			all_open = all_open and pr.state == 1
	check("open: every door", all_open)
	check("unknown cheats explain themselves", main._cheat("fly").begins_with("unknown"))

	main.queue_free()
	await process_frame
	print("%d failure(s)" % failures)
	quit(1 if failures else 0)
