extends SceneTree
## Gourd and dungeon rules not covered by the walkthrough.
## Run: godot --headless --path . --fixed-fps 60 -s tests/gourd_test.gd

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
	p.has_gourd = true
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


func _run() -> void:
	var p := await fresh()

	# Taking fire from a lit brazier puts it out; water puts a lit brazier out too.
	var br = prop_at(Vector2i(22, 12))
	br.set_state(1)
	place(p, Vector2i(22, 10))
	use(p, br.point_near(p.global_position))
	check("taking fire from a brazier puts it out", p.gourd == Dungeon.FIRE and br.state == 0, "gourd %d state %d" % [p.gourd, br.state])
	use(p, br.point_near(p.global_position))
	check("pouring fire relights it", p.gourd == Dungeon.EMPTY and br.state == 1)
	p.gourd = Dungeon.WATER
	use(p, br.point_near(p.global_position))
	check("water puts a lit brazier out", br.state == 0 and p.gourd == Dungeon.EMPTY)
	use(p, br.point_near(p.global_position))
	check("nothing to take from an unlit brazier", p.gourd == Dungeon.EMPTY)

	# Reach is limited to what faces the player, within range, in the player's room.
	var ef = prop_at(Vector2i(25, 10))
	place(p, Vector2i(25, 13))
	use(p, p.global_position + Vector3(0, 0, 5))   # facing away
	check("the gourd ignores what is behind you", p.gourd == Dungeon.EMPTY)
	place(p, Vector2i(15, 10))   # the next room, beyond the wall and door
	use(p, ef.point_near(p.global_position))
	check("the gourd cannot reach into another room", p.gourd == Dungeon.EMPTY)

	# Draining the moat makes it walkable.
	var moat = prop_at(Vector2i(11, 10))
	place(p, Vector2i(13, 10))
	use(p, moat.point_near(p.global_position))
	check("draining the moat", p.gourd == Dungeon.WATER and moat.state == 1 and main.dungeon.walkable_tile(Vector2i(11, 10)))

	# Released into nothing: fire burns toads in a short cone.
	p.gourd = Dungeon.FIRE
	var t: CharacterBody3D = main._make_toad(Vector3(29.0, 0.1, 21.0), false, -1, 1.0)
	await physics_frame
	place(p, Vector2i(13, 10))   # (27, 21)
	var before: float = t.hp
	use(p, t.global_position)
	check("fire released into nothing scorches a toad", t.hp == before - Dungeon.FIRE_BURST_DAMAGE, "hp %.0f -> %.0f" % [before, t.hp])

	# A weakened small toad can be captured, then flung: it hits the next toad and lands dazed.
	t.daze(2.0)
	use(p, t.global_position)
	await physics_frame
	check("a weakened toad is captured", p.gourd == Dungeon.TOAD and t.is_dead())
	var target: CharacterBody3D = main._make_toad(Vector3(35.0, 0.1, 21.0), false, -1, 1.0)
	target.aggro_range = 0.0
	await physics_frame
	var count: int = main.toads.size()
	before = target.hp
	use(p, target.global_position)
	await physics_frame
	check("a flung toad strikes the next one", target.hp == before - Dungeon.THROW_DAMAGE, "hp %.0f -> %.0f" % [before, target.hp])
	var landed := false
	for tt in main.toads.values():
		if tt != target and tt.is_weakened():
			landed = true
	check("and lands dazed", main.toads.size() == count + 1 and landed, "toads %d -> %d" % [count, main.toads.size()])

	# A toad whose line to the player is blocked by a wall does not attack.
	p = await fresh()
	var tw: CharacterBody3D = main._make_toad(Vector3(22.6, 0.1, 5.0), false, -1, 1.0)
	tw._cd = 0.0
	tw.aggro_range = 16.0
	p.global_position = Vector3(18.0, 0.05, 5.0)   # same room, other side of the wall stub
	var attacked := false
	for k in 90:
		await physics_frame
		if tw.state == tw.S.TONGUE_WIND or tw.state == tw.S.CROUCH:
			attacked = attacked or not main.dungeon.clear_line(tw.global_position, p.global_position, tw.radius * 0.8)
	check("no attacks through walls", not attacked)

	main.queue_free()
	await process_frame
	print("%d failure(s)" % failures)
	quit(1 if failures else 0)
