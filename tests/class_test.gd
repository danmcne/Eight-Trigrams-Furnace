extends SceneTree
## Rules that make each class play differently.
## Run: godot --headless --path . --fixed-fps 60 -s tests/class_test.gd

const PlayerScript := preload("res://player.gd")
const ToadScript := preload("res://toad.gd")
const Intent := preload("res://intent.gd")

var failures := 0
var world: Node3D


class Scripted:
	var frame := 0
	var fn: Callable
	func poll(_p: Node3D) -> Intent:
		var i: Intent = fn.call(frame)
		frame += 1
		return i


class FakeWorld extends Node3D:
	var wards := []
	var walls_behind_z := -INF   # optional: everything beyond this z is wall
	func add_ward(owner: Node3D, pos: Vector3, r: float, seconds: float, heal: float) -> void:
		wards.append({"owner": owner, "pos": pos, "r": r, "t": seconds, "heal": heal})
	func ray_length(from: Vector3, dir: Vector3, max_length: float) -> float:
		if dir.z < -0.01 and walls_behind_z > -INF:
			return clampf((from.z - walls_behind_z) / -dir.z, 0.0, max_length)
		return max_length


func _initialize() -> void:
	_run()


func check(name: String, ok: bool, detail := "") -> void:
	print(("PASS  " if ok else "FAIL  ") + name + ("" if ok else "   " + detail))
	if not ok:
		failures += 1


func fresh(kit: String, fn: Callable) -> CharacterBody3D:
	if world:
		world.queue_free()
		await process_frame
	Engine.time_scale = 1.0
	world = FakeWorld.new()
	root.add_child(world)
	var ground := StaticBody3D.new()
	var gs := CollisionShape3D.new()
	var gb := BoxShape3D.new()
	gb.size = Vector3(80, 1, 80)
	gs.shape = gb
	gs.position.y = -0.5
	ground.add_child(gs)
	world.add_child(ground)
	var p: CharacterBody3D = PlayerScript.new()
	p.kit_name = kit
	p.world = world
	var src := Scripted.new()
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
	t._cd = 999.0
	t.aggro_range = 0.0
	return t


func steps(n: int) -> void:
	for k in n:
		await physics_frame


func _run() -> void:
	await physics_frame

	# ---- Health and speed differ ----
	var hp := {}
	for c in PlayerScript.CLASSES:
		var q := await fresh(c, func(_f): return Intent.new())
		await steps(1)
		hp[c] = [q.max_hp, q.speed]
	check("classes differ in health and speed", hp["glaive"][0] == 100.0 and hp["bow"][0] == 80.0 and hp["dao"][0] == 85.0 and hp["scholar"][0] == 75.0 and hp["dao"][1] > hp["glaive"][1], str(hp))

	# ---- Bow ----
	var p := await fresh("bow", func(f): var i := Intent.new(); i.light = f == 2; return i)
	var far := toad_at(Vector3(0, 0.05, -12.0), p)
	await steps(20)
	check("bow: a snap shot hits at 12 m", far.hp < far.max_hp, "hp %.0f" % far.hp)

	p = await fresh("bow", func(f): var i := Intent.new(); i.heavy = f == 2; i.heavy_held = f >= 2 and f < 14; return i)   # ~0.2 s draw
	var near := toad_at(Vector3(0, 0.05, -6.0), p)
	var behind := toad_at(Vector3(0, 0.05, -9.0), p)
	await steps(30)
	var weak: float = near.max_hp - near.hp
	check("bow: a short draw is weak and stops at the first toad", weak > 0.0 and weak < 20.0 and behind.hp == behind.max_hp, "dmg %.1f behind %.0f" % [weak, behind.hp])

	var slowed := [0.0]
	p = await fresh("bow", func(f): var i := Intent.new(); i.move = Vector2(1, 0); i.heavy = f == 30; i.heavy_held = f >= 30 and f < 90; return i)
	near = toad_at(Vector3(4.0, 0.05, -6.0), p, true)
	behind = toad_at(Vector3(6.0, 0.05, -9.0), p)
	await steps(29)
	var v_free: float = Vector2(p.velocity.x, p.velocity.z).length()
	await steps(40)
	var v_draw: float = Vector2(p.velocity.x, p.velocity.z).length()
	check("bow: drawing slows you", v_draw < v_free * 0.5, "%.1f -> %.1f m/s" % [v_free, v_draw])
	p = await fresh("bow", func(f): var i := Intent.new(); i.heavy = f == 2; i.heavy_held = f >= 2 and f < 60; return i)   # full draw
	var a := toad_at(Vector3(0, 0.05, -5.0), p, true)
	var b := toad_at(Vector3(0, 0.05, -10.0), p)
	await steps(70)
	check("bow: a full draw pierces the line and costs 20 qi", a.hp < a.max_hp and b.hp < b.max_hp and p.stats["full_draws"] == 1 and absf(p.qi - 80.0) < 1.0,
		"a %.0f b %.0f qi %.1f" % [a.hp, b.hp, p.qi])
	check("bow: a full draw staggers even a big toad", a.state == a.S.STAGGER, "state %d" % a.state)

	p = await fresh("bow", func(f): var i := Intent.new(); i.block = f == 2; return i)
	var close := toad_at(Vector3(0, 0.05, -1.2), p)
	var z0: float = close.global_position.z
	await steps(20)
	check("bow: the kick shoves a toad away and staggers it", close.global_position.z < z0 - 1.0 and close.state == close.S.STAGGER, "z %.2f -> %.2f state %d" % [z0, close.global_position.z, close.state])

	# ---- Dao ----
	p = await fresh("dao", func(f): var i := Intent.new(); i.light = f in [2, 12, 22, 32]; return i)
	var t := toad_at(Vector3(0, 0.05, -1.6), p, true)
	await steps(50)
	check("dao: four-hit combo lands every hit", p.stats["light_hits"] == 4, "hits %d" % p.stats["light_hits"])
	p = await fresh("dao", func(f): var i := Intent.new(); i.light = f == 2; i.dodge = f == 4; i.move = Vector2(1, 0) if f >= 4 else Vector2.ZERO; return i)
	await steps(6)
	check("dao: a dodge cuts off a swing even mid-windup", p.state == p.State.DODGE, "state %d" % p.state)
	p = await fresh("dao", func(f): var i := Intent.new(); i.heavy = f == 2; return i)
	var d1 := toad_at(Vector3(0, 0.05, -2.5), p)
	var d2 := toad_at(Vector3(0.4, 0.05, -4.5), p)
	await steps(40)
	check("dao: the dash passes through, hitting everything on the path", d1.hp < d1.max_hp and d2.hp < d2.max_hp and p.global_position.z < -5.0,
		"hp %.0f %.0f z %.1f" % [d1.hp, d2.hp, p.global_position.z])
	p = await fresh("dao", func(f): var i := Intent.new(); i.block = f == 2; return i)
	t = toad_at(Vector3(0, 0.05, -3.0), p)
	await steps(6)
	var r: String = p.take_hit(12.0, Vector3.ZERO, t, false)
	await steps(1)
	check("dao: the counter stance turns even an unblockable hit into a counter", r == "countered" and p.hp == p.max_hp and t.hp < t.max_hp and p.global_position.z < t.global_position.z,
		"%s hp %.0f toad %.0f pz %.1f tz %.1f" % [r, p.hp, t.hp, p.global_position.z, t.global_position.z])
	# Countering an attacker whose back is to a wall must not put you in the wall.
	p = await fresh("dao", func(f): var i := Intent.new(); i.block = f == 2; return i)
	world.walls_behind_z = -3.8   # a wall just behind the toad
	t = toad_at(Vector3(0, 0.05, -3.0), p)
	await steps(6)
	r = p.take_hit(12.0, Vector3.ZERO, t, false)
	await steps(1)
	check("dao: a counter against a wall reappears beside the attacker, not in the wall", r == "countered" and p.global_position.z > -3.8 and absf(p.global_position.x) > 1.0,
		"%s pos %s" % [r, p.global_position])
	world.walls_behind_z = -INF

	p = await fresh("dao", func(f): var i := Intent.new(); i.block = f == 2; return i)
	t = toad_at(Vector3(0, 0.05, -3.0), p)
	await steps(30)   # the window has passed
	r = p.take_hit(12.0, Vector3.ZERO, t, true)
	check("dao: a mistimed stance leaves you exposed", r == "hit" and p.hp == p.max_hp - 12.0, r)
	p = await fresh("dao", func(f): var i := Intent.new(); i.dodge = f == 2; i.move = Vector2(1, 0) if f >= 2 else Vector2.ZERO; return i)
	t = toad_at(Vector3(0, 0.05, -3.0), p)
	p.qi = 50.0
	await steps(4)
	r = p.take_hit(12.0, Vector3.ZERO, t, true)
	check("dao: a perfect dodge pays qi", r == "ignored" and p.stats["perfect_dodges"] == 1 and p.qi >= 65.0, "%s qi %.1f" % [r, p.qi])

	# ---- Scholar ----
	p = await fresh("scholar", func(f): var i := Intent.new(); i.heavy = f == 2; return i)
	t = toad_at(Vector3(0, 0.05, -8.0), p)
	await steps(30)
	check("scholar: a talisman seals a toad in place", t.state == t.S.SEALED and p.stats["seals"] == 1, "state %d" % t.state)
	check("scholar: a sealed toad can be drawn into the gourd", t.is_weakened())
	p = await fresh("scholar", func(f): var i := Intent.new(); i.heavy = f == 2; i.heavy_held = f >= 2 and f < 40; return i)
	var g1 := toad_at(Vector3(-1.5, 0.05, -4.0), p, true)
	var g2 := toad_at(Vector3(1.5, 0.05, -5.0), p)
	g1._begin_tongue(Vector3.BACK)   # a big toad winding up a lash
	var z1: float = g2.global_position.z
	await steps(45)
	check("scholar: the gale interrupts a big toad's warning and knocks toads back", g1.state == g1.S.STAGGER and g2.global_position.z < z1 - 1.0 and p.stats["gales"] == 1,
		"big state %d, z %.1f -> %.1f" % [g1.state, z1, g2.global_position.z])
	p = await fresh("scholar", func(f): var i := Intent.new(); i.block = f == 2; return i)
	await steps(30)
	check("scholar: the ward is placed for 40 qi", world.wards.size() == 1 and absf(p.qi - 60.0) < 1.0, "wards %d qi %.1f" % [world.wards.size(), p.qi])
	p = await fresh("scholar", func(f): var i := Intent.new(); i.light = f in [2, 20, 38]; return i)
	t = toad_at(Vector3(0, 0.05, -1.8), p)
	var zt: float = t.global_position.z
	var farthest := zt
	for k in 90:   # how far back the toad is driven, before it recovers and returns
		await physics_frame
		farthest = minf(farthest, t.global_position.z)
	check("scholar: the third fan cut gusts the toad back", farthest < zt - 1.5, "driven from z %.1f to %.1f" % [zt, farthest])

	world.queue_free()
	await process_frame
	print("%d failure(s)" % failures)
	quit(1 if failures else 0)
