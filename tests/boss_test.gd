extends SceneTree
## The Horned Kings' rules.
## Run: godot --headless --path . --fixed-fps 60 -s tests/boss_test.gd

const PlayerScript := preload("res://player.gd")
const Golden := preload("res://bosses/golden_king.gd")
const Silver := preload("res://bosses/silver_king.gd")
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


func _initialize() -> void:
	_run()


func check(name: String, ok: bool, detail := "") -> void:
	print(("PASS  " if ok else "FAIL  ") + name + ("" if ok else "   " + detail))
	if not ok:
		failures += 1


func arena() -> void:
	if world:
		world.queue_free()
		await process_frame
	Engine.time_scale = 1.0
	world = Node3D.new()
	root.add_child(world)
	var ground := StaticBody3D.new()
	var gs := CollisionShape3D.new()
	var gb := BoxShape3D.new()
	gb.size = Vector3(80, 1, 80)
	gs.shape = gb
	gs.position.y = -0.5
	ground.add_child(gs)
	world.add_child(ground)


func player(kit: String, fn: Callable, pos := Vector3.ZERO) -> CharacterBody3D:
	var p: CharacterBody3D = PlayerScript.new()
	p.kit_name = kit
	var src := Scripted.new()
	src.fn = fn
	p.input_source = src
	p.position = pos + Vector3(0, 0.05, 0)
	world.add_child(p)
	return p


func boss(script: Script, pos: Vector3) -> CharacterBody3D:
	var b: CharacterBody3D = script.new()
	b.setup(1)
	b.position = pos + Vector3(0, 0.05, 0)
	world.add_child(b)
	return b


func idle(_f: int) -> Intent:
	return Intent.new()


func steps(n: int) -> void:
	for k in n:
		await physics_frame


func call_on(s: CharacterBody3D, p: CharacterBody3D) -> void:
	s._call_cd = 0.0
	s._cd = 99.0
	s.state = s.APPROACH


func _run() -> void:
	await physics_frame

	# ---- The Silver King's call ----
	await arena()
	var p := player("glaive", func(f): var i := Intent.new(); i.light = f == 20; return i)
	var s := boss(Silver, Vector3(0, 0, -7))
	await steps(2)
	call_on(s, p)
	await steps(3)
	check("the Silver King calls a visible player", s.state == s.CALL and s.aux == p.peer_id, "state %d aux %d" % [s.state, s.aux])
	await steps(25)
	check("attacking during the call is answering: drawn into the vase", p.is_trapped(), "state %d" % p.state)
	var hp_in: float = p.hp
	await steps(60)
	check("inside the vase you lose health", p.hp < hp_in)
	await steps(160)
	check("and come out after a few seconds, beside him", not p.is_trapped() and p.global_position.distance_to(s.global_position) < 3.0, "trapped %s" % p.is_trapped())

	await arena()
	p = player("glaive", func(f): var i := Intent.new(); i.move = Vector2(1, 0) if f > 10 else Vector2.ZERO; i.dodge = f == 30; return i)
	s = boss(Silver, Vector3(0, 0, -7))
	await steps(2)
	call_on(s, p)
	await steps(110)
	check("moving and dodging are not answering", not p.is_trapped() and p.stats["dodges"] == 1, "trapped %s" % p.is_trapped())
	check("an unanswered call leaves him flustered", s.state == s.RECOVER and s._recover_for == s.FLUSTERED, "state %d" % s.state)

	await arena()
	p = player("glaive", func(f): var i := Intent.new(); i.light = f == 6; return i)   # the call begins about frame 5
	s = boss(Silver, Vector3(0, 0, -7))
	await steps(2)
	call_on(s, p)
	await steps(110)
	check("acting in the call's first instant (reaction time) isn't answering", not p.is_trapped() and p.stats["light_hits"] + p.acts > 0, "trapped %s acts %d" % [p.is_trapped(), p.acts])

	await arena()
	p = player("glaive", func(f): var i := Intent.new(); i.light = f == 35; return i)   # past the grace
	s = boss(Silver, Vector3(0, 0, -7))
	await steps(2)
	call_on(s, p)
	await steps(45)
	var trapped_first: bool = p.is_trapped()
	s.take_hit(45.0, Vector3.ZERO)
	await steps(2)
	check("striking him hard shakes a trapped ally loose", trapped_first and not p.is_trapped(), "first %s now %s" % [trapped_first, p.is_trapped()])

	# ---- The Golden King ----
	await arena()
	var ctl := {"press": -1}
	p = player("glaive", func(f): var i := Intent.new(); i.block = f == ctl["press"]; i.block_held = ctl["press"] >= 0 and f >= ctl["press"]; return i)
	var g := boss(Golden, Vector3(0, 0, -3))
	await steps(2)
	g._cd = 99.0
	g._dir = Vector3.BACK   # toward the player
	g._enter(g.SWORD_WIND)
	ctl["press"] = p.input_source.frame + int(g.SWORD_WINDUP * 60.0) - 6   # block 0.1 s before the blow
	var parried := false
	var poise_before: float = g.poise
	for k in 90:
		await physics_frame
		if g.state == g.SWORD_HIT or g.state == g.BROKEN:
			parried = p.stats["parries"] > 0
			break
	check("a parried sword sweep costs him heavily in poise", parried and (g.poise >= poise_before + 45.0 or g.state == g.BROKEN), "parried %s poise %.0f" % [parried, g.poise])

	await arena()
	p = player("glaive", func(f): var i := Intent.new(); i.block_held = true; return i)
	g = boss(Golden, Vector3(0, 0, -7))
	await steps(20)
	g._target = p.global_position
	g._enter(g.SLAM_CROUCH_S)
	await steps(120)
	check("the slam goes through a block", p.hp == p.max_hp - g.SLAM_DAMAGE, "hp %.0f" % p.hp)

	await arena()
	p = player("glaive", idle, Vector3(0, 0, 6))
	g = boss(Golden, Vector3(0, 0, -3))
	await steps(2)
	g._enter(g.SWORD_WIND)
	g.stagger(1.5)   # a heavy stagger: 60 poise
	var still_winding: bool = g.state == g.SWORD_WIND
	g.stagger(1.2)   # another: over 100
	check("ordinary staggers don't interrupt him until his posture breaks", still_winding and g.state == g.BROKEN, "state %d" % g.state)

	# ---- Siblings ----
	await arena()
	p = player("glaive", idle, Vector3(0, 0, 12))
	g = boss(Golden, Vector3(-3, 0, 0))
	s = boss(Silver, Vector3(3, 0, 0))
	g.sibling = s
	s.sibling = g
	await steps(2)
	g.take_hit(10000.0, Vector3.ZERO)
	check("when one king falls the other is enraged", g.is_dead() and s.enraged)

	# ---- Replication ----
	await arena()
	s = boss(Silver, Vector3(2, 0, -5))
	s.net_id = 9
	await steps(1)
	s._enter(s.FAN_WIND)
	s.aux = 12345
	s.enraged = true
	s.hp = 111.0
	var b := StreamPeerBuffer.new()
	s.write_net(b)
	var copy: CharacterBody3D = Silver.new()
	copy.authority = false
	world.add_child(copy)
	b.seek(4)
	copy.read_net(b)
	check("a boss's state crosses the network intact", copy.state == s.FAN_WIND and copy.aux == 12345 and copy.enraged and absf(copy.hp - 111.0) < 0.01 and copy.global_position.distance_to(s.global_position) < 0.001)

	world.queue_free()
	await process_frame
	print("%d failure(s)" % failures)
	quit(1 if failures else 0)
