extends SceneTree
## Deterministic checks of the combat rules. Run:
##   godot --headless --path . --fixed-fps 60 -s tests/combat_test.gd
## Each case builds a fresh arena, scripts the player's intents, and checks one rule.

const PlayerScript := preload("res://player.gd")
const ToadScript := preload("res://toad.gd")
const Intent := preload("res://intent.gd")

var failures := 0
var world: Node3D


class Script_:
	## Input source that replays a per-frame function.
	var frame := 0
	var fn: Callable
	func poll(_p: Node3D) -> Intent:
		var i: Intent = fn.call(frame)
		frame += 1
		return i


func _initialize() -> void:
	_run()


func check(name: String, ok: bool, detail := "") -> void:
	print(("PASS  " if ok else "FAIL  ") + name + ("" if ok else "   " + detail))
	if not ok:
		failures += 1


func fresh(fn: Callable) -> CharacterBody3D:
	if world:
		world.queue_free()
		await process_frame
	Engine.time_scale = 1.0   # no hit-stop carried over from the previous case
	world = Node3D.new()
	root.add_child(world)
	var ground := StaticBody3D.new()
	var gs := CollisionShape3D.new()
	var gb := BoxShape3D.new()
	gb.size = Vector3(60, 1, 60)
	gs.shape = gb
	gs.position.y = -0.5
	ground.add_child(gs)
	world.add_child(ground)
	var p: CharacterBody3D = PlayerScript.new()
	var src := Script_.new()
	src.fn = fn
	p.input_source = src
	p.position = Vector3(0, 0.05, 0)
	world.add_child(p)
	return p


func toad_at(pos: Vector3, player: Node3D, big := false) -> CharacterBody3D:
	var t: CharacterBody3D = ToadScript.new()
	t.setup(big, 1)
	t.player = player
	t.position = pos
	world.add_child(t)
	t._cd = 999.0          # passive unless a test drives it
	t.aggro_range = 0.0
	return t


func steps(n: int) -> void:
	for k in n:
		await physics_frame


func idle(_f: int) -> Intent:
	return Intent.new()


func _run() -> void:
	await physics_frame

	# 1. Tapping heavy fires a thrust and costs 30 qi.
	var p := await fresh(func(f): var i := Intent.new(); i.heavy = f == 0; i.heavy_held = f < 3; return i)
	await steps(40)
	check("tap heavy -> thrust", p.stats["thrusts"] == 1 and p.stats["sweeps"] == 0, str(p.stats))
	check("thrust costs 30 qi", absf(p.qi - 70.0) < 0.01, "qi=%.2f" % p.qi)

	# 2. Holding heavy through the thrust windup becomes a sweep costing 40.
	p = await fresh(func(f): var i := Intent.new(); i.heavy = f == 0; i.heavy_held = f < 40; return i)
	await steps(50)
	check("hold heavy -> sweep", p.stats["sweeps"] == 1 and p.stats["thrusts"] == 0, str(p.stats))
	check("sweep costs 40 qi", absf(p.qi - 60.0) < 0.01, "qi=%.2f" % p.qi)

	# 3. Not enough qi: the heavy attack is refused.
	p = await fresh(func(f): var i := Intent.new(); i.heavy = f == 2; return i)
	p.qi = 10.0
	await steps(30)
	check("heavy refused without qi", p.stats["qi_denied"] == 1 and p.stats["thrusts"] == 0, str(p.stats))

	# 4. The thrust pierces a line: both toads straight ahead are hit, one beside is not.
	p = await fresh(func(f): var i := Intent.new(); i.heavy = f == 2; i.heavy_held = f < 4; return i)
	var t1 := toad_at(Vector3(0, 0.05, -2.0), p)
	var t2 := toad_at(Vector3(0, 0.05, -4.3), p)
	var t3 := toad_at(Vector3(3.0, 0.05, -2.0), p)
	await steps(30)
	check("thrust pierces the line", t1.hp < t1.max_hp and t2.hp < t2.max_hp, "hp %.0f %.0f" % [t1.hp, t2.hp])
	check("thrust stays narrow", t3.hp == t3.max_hp, "hp %.0f" % t3.hp)

	# 5. Light hits restore qi (8 per toad struck).
	p = await fresh(func(f): var i := Intent.new(); i.light = f == 2; return i)
	p.qi = 50.0
	toad_at(Vector3(0, 0.05, -1.6), p)
	await steps(15)
	check("light hit restores qi", absf(p.qi - 58.0) < 0.01, "qi=%.2f" % p.qi)

	# 6. Soft assist turns an attack toward an enemy 30 degrees off, not 90 degrees off.
	p = await fresh(func(f): var i := Intent.new(); i.light = f == 2; return i)
	var ta := toad_at(Vector3(sin(deg_to_rad(30)) * 2.5, 0.05, -cos(deg_to_rad(30)) * 2.5), p)
	await steps(4)
	var fwd: Vector3 = -p.global_transform.basis.z
	var to_t := (ta.global_position - p.global_position) * Vector3(1, 0, 1)
	check("assist turns toward a target in the cone", fwd.angle_to(to_t) < 0.05, "off by %.2f rad" % fwd.angle_to(to_t))
	p = await fresh(func(f): var i := Intent.new(); i.light = f == 2; return i)
	toad_at(Vector3(2.5, 0.05, 0), p)
	await steps(4)
	fwd = -p.global_transform.basis.z
	check("assist ignores a target outside the cone", fwd.angle_to(Vector3.FORWARD) < 0.05, "turned %.2f rad" % fwd.angle_to(Vector3.FORWARD))

	# 7-10. Block rules, calling take_hit directly with a toad in front or behind.
	var block_held := func(f): var i := Intent.new(); i.block = f == 0; i.block_held = true; return i
	p = await fresh(block_held)
	var front := toad_at(Vector3(0, 0.05, -2.5), p)
	await steps(30)   # the parry window has long expired
	var r: String = p.take_hit(9.0, Vector3.ZERO, front, true)
	check("held block absorbs a frontal hit", r == "blocked" and p.hp == p.max_hp, r)
	check("blocked hit drains qi (2.5 per damage)", absf(p.qi - 77.5) < 0.01, "qi=%.2f" % p.qi)
	r = p.take_hit(12.0, Vector3.ZERO, front, false)
	check("unblockable attack goes through a block", r == "hit" and p.hp == p.max_hp - 12.0, "%s hp=%.0f" % [r, p.hp])

	p = await fresh(block_held)
	var behind := toad_at(Vector3(0, 0.05, 3.0), p)
	toad_at(Vector3(0, 0.05, -2.0), p)   # nearer, so the block turns to face it
	await steps(30)
	r = p.take_hit(9.0, Vector3.ZERO, behind, true)
	check("block does not cover the back", r == "hit", r)

	p = await fresh(block_held)
	front = toad_at(Vector3(0, 0.05, -2.5), p)
	await steps(30)
	p.qi = 5.0
	r = p.take_hit(12.0, Vector3.ZERO, front, true)
	check("guard break: half damage when qi runs out", r == "hit" and p.hp == p.max_hp - 6.0 and p.stats["guard_breaks"] == 1, "%s hp=%.0f" % [r, p.hp])

	p = await fresh(block_held)
	front = toad_at(Vector3(0, 0.05, -2.5), p)
	await steps(5)    # block pressed 5 frames ago: inside the parry window
	r = p.take_hit(9.0, Vector3.ZERO, front, true)
	check("fresh block parries at no cost", r == "parried" and p.qi == p.max_qi, "%s qi=%.1f" % [r, p.qi])

	# 11. A parried tongue lash severs the tongue; the toad then only leaps.
	var windup := 0.75
	var press_at := int((windup - 0.1) * 60.0)   # block 0.1 s before the lash lands
	p = await fresh(func(f): var i := Intent.new(); i.block = f == press_at; i.block_held = f >= press_at; return i)
	var tt := toad_at(Vector3(0, 0.05, -5.0), p)
	await steps(1)
	tt._begin_tongue(Vector3.BACK)
	await steps(int(windup * 60.0) + 5)
	check("parried lash severs the tongue", not tt.has_tongue and p.hp == p.max_hp, "tongue=%s hp=%.0f" % [tt.has_tongue, p.hp])

	# 12. An unparried lash hits and pulls the player toward the toad.
	p = await fresh(idle)
	tt = toad_at(Vector3(0, 0.05, -5.0), p)
	await steps(1)
	tt._begin_tongue(Vector3.BACK)
	await steps(int(windup * 60.0) + 3)
	check("lash hits and pulls toward the toad", p.hp < p.max_hp and p.global_position.z < 0.0, "hp=%.0f z=%.2f" % [p.hp, p.global_position.z])

	# 13. Snapshot encoding: sizes match the declared layout, and values round-trip.
	p = await fresh(idle)
	var tn := toad_at(Vector3(2.0, 0.05, -3.0), p)
	tn.net_id = 77
	tn._begin_tongue(Vector3(0.6, 0, 0.8))
	tn.has_tongue = false
	p.hp = 63.0
	p.qi = 41.5
	await steps(3)
	var b := StreamPeerBuffer.new()
	p.write_net(b)
	check("player entry size", b.data_array.size() == 4 + PlayerScript.BYTES_AFTER_ID, "%d bytes" % b.data_array.size())
	var b2 := StreamPeerBuffer.new()
	tn.write_net(b2)
	check("toad entry size", b2.data_array.size() == 4 + ToadScript.BYTES_AFTER_ID, "%d bytes" % b2.data_array.size())
	var pp: CharacterBody3D = PlayerScript.new()
	pp.authority = false
	world.add_child(pp)
	b.seek(0)
	b.get_u32()
	pp.read_net(b)
	check("player round-trip", pp.global_position.distance_to(p.global_position) < 0.001 and absf(pp.hp - 63.0) < 0.05 and absf(pp.qi - 41.5) < 0.05 and pp.state == p.state,
		"pos %s hp %.2f qi %.2f" % [pp.global_position, pp.hp, pp.qi])
	var tp: CharacterBody3D = ToadScript.new()
	tp.authority = false
	tp.setup(false, 1)
	world.add_child(tp)
	b2.seek(0)
	b2.get_u32()
	tp.read_net(b2)
	check("toad round-trip", tp.global_position.distance_to(tn.global_position) < 0.001 and tp.state == tn.state and not tp.has_tongue and tp._dir.distance_to(tn._dir) < 0.01,
		"state %d dir %s" % [tp.state, tp._dir])

	world.queue_free()
	await process_frame
	print("%d failure(s)" % failures)
	quit(1 if failures else 0)
