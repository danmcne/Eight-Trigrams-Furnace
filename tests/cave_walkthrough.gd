extends SceneTree
## Plays the Reed Marsh cave start to finish in the real game: the solver's
## plan, carried out by an agent that walks, fights and uses the gourd through
## the same Intents a player produces.
## Run: godot --headless --path . --fixed-fps 60 -s tests/cave_walkthrough.gd

const Solver := preload("res://tests/cave_solver.gd")
const Intent := preload("res://intent.gd")
const STEP_LIMIT := 60.0    # seconds of game time allowed per plan step
const BOSS_STEP_LIMIT := 300.0
const DIRS: Array[Vector2i] = [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]


class Walker:
	var main: Node
	var dg: Node
	var solver: RefCounted
	var plan: Array = []
	var step := 0
	var t_step := 0.0
	var frame := 0
	var presses := 0
	var press_wait := 0
	var heavy_hold := 0
	var failed := ""
	var ward_hold := 0   # scholar: frames left to stand in its ward
	var healing := false
	var log: Array[String] = []

	func tile_of(pos: Vector3) -> Vector2i:
		return Vector2i(floori(pos.x / 2.0), floori(pos.z / 2.0))

	func center(t: Vector2i) -> Vector3:
		return Vector3(t.x * 2.0 + 1.0, 0.0, t.y * 2.0 + 1.0)

	func walkable(t: Vector2i) -> bool:
		if t.y < 0 or t.y >= dg.height or t.x < 0 or t.x >= dg.width:
			return false
		if dg.terrain[t.y][t.x] == "#":
			return false
		if dg.terrain[t.y][t.x] == "X" and step < plan.size() and plan[step]["do"] != "exit":
			return false   # don't leave by accident before the plan is done
		for pr in dg.props:
			if pr.blocks() and t in pr.tiles:
				return false
		return true

	## Breadth-first path over walkable tiles to any goal tile.
	func path_to(from: Vector2i, goals: Dictionary) -> Array:
		var prev := {from: from}
		var queue := [from]
		while not queue.is_empty():
			var q: Vector2i = queue.pop_front()
			if goals.has(q):
				var path := [q]
				while prev[q] != q:
					q = prev[q]
					path.push_front(q)
				return path
			for d in DIRS:
				var n := q + d
				if not prev.has(n) and walkable(n):
					prev[n] = q
					queue.append(n)
		return []

	func goal_tiles(a: Dictionary) -> Dictionary:
		var g := {}
		match a["do"]:
			"chest":
				for d in DIRS:
					var t: Vector2i = solver.props[a["prop"]]["tiles"][0] + d
					if walkable(t):
						g[t] = true
			"toads":
				var room: int = solver.groups[a["group"]]["room"]
				for t: Vector2i in solver.rooms:
					if solver.rooms[t] == room and walkable(t):
						g[t] = true
			"take", "give":
				var pr: Dictionary = solver.props[a["prop"]]
				for t: Vector2i in solver.rooms:
					if not pr["rooms"].has(solver.rooms[t]) or not walkable(t):
						continue
					for pt: Vector2i in pr["tiles"]:
						if Vector2(t - pt).length() <= 2.0:
							g[t] = true
			"exit":
				g[solver.exit_tile] = true
			"pickup":
				g[solver.props[a["prop"]]["tiles"][0]] = true
		return g

	func _boss_step() -> bool:
		if step >= plan.size() or plan[step]["do"] != "toads":
			return false
		for t: Vector2i in solver.groups[plan[step]["group"]]["tiles"]:
			if dg.terrain[t.y][t.x] in ["K", "k"]:
				return true
		return false

	func room_toads(room: int) -> Array:
		var out := []
		for e in main.get_tree().get_nodes_in_group("enemies"):
			if room in dg.rooms_at(e.global_position):
				out.append(e)
		return out

	func my_room(p: Node3D, prefer := -1) -> int:
		var rs: Array = dg.rooms_at(p.global_position)
		if prefer in rs:
			return prefer
		return rs[0] if not rs.is_empty() else -1

	## Fight whatever shares the player's room. Returns an Intent, or null if nothing to fight.
	func fight(p: Node3D, only_near: bool, prefer := -1) -> Intent:
		var room: int = my_room(p, prefer)
		var near: Node3D = null
		var best := INF
		for e in room_toads(room):
			var dd: float = e.global_position.distance_to(p.global_position)
			if dd < best:
				best = dd
				near = e
		if near == null or (only_near and best > 7.0):
			return null
		var i := Intent.new()
		var called := false
		for e in room_toads(room):
			var th: Dictionary = e.threat_to(p.global_position, p.radius)
			if not th.is_empty() and th["kind"] == "hold" and th["target"] == p.peer_id:
				called = true
		for e in room_toads(room):
			var th: Dictionary = e.threat_to(p.global_position, p.radius)
			if th.is_empty() or th["kind"] == "hold":
				continue
			var eta: float = th["eta"]
			if th["kind"] == "red" and eta < 1.0:
				# Run out of a ring while there's time, sidestep a cone, and dodge only at the end.
				var from: Vector3 = th["from"]
				var away: Vector3 = p.global_position - from
				away.y = 0.0
				if from.distance_to(e.global_position) < 0.5:   # a cone from the attacker: go sideways
					away = Vector3(-away.z, 0.0, away.x)
				away = away.normalized() if away.length() > 0.1 else Vector3.RIGHT
				i.move = Vector2(away.x, away.z)
				i.dodge = eta < 0.2
				return i
			if th["kind"] == "gold" and eta < 0.15:
				if p.kit_name == "glaive" and not called:
					i.block = true   # parry
					i.block_held = true
					return i
				if p.kit_name == "dao" and not called:
					i.block = true   # counter stance
					return i
				var away2: Vector3 = p.global_position - th["from"]
				away2.y = 0.0
				away2 = away2.normalized() if away2.length() > 0.1 else Vector3.RIGHT
				i.move = Vector2(away2.x, away2.z)
				i.dodge = true
				return i
		var d := near.global_position - p.global_position
		d.y = 0.0
		var dn := d.normalized()
		# Class tactics: the bow keeps its distance and shoots; the scholar wards when hurt.
		if p.kit_name == "scholar":
			if ward_hold > 0:
				ward_hold -= 1
				if best <= 2.3 + near.radius - 0.6 and frame % 9 == 0 and not called:
					i.light = true
				i.move = Vector2(dn.x, dn.z) * 0.05
				return i
			if p.hp < p.max_hp * 0.5 and p.qi >= 40.0 and not called:
				i.block = true
				ward_hold = 300
				return i
		if p.kit_name == "bow":
			var aim := dn
			var retreat: Vector3 = p.global_position - dn * 4.0
			if best < 5.5 and room in dg.rooms_at(retreat) and dg.walkable_tile(dg._tile(retreat)):
				var back: Vector3 = dg.step_toward(p.global_position, retreat, 0.4)
				i.move = Vector2(back.x, back.z)
			elif best > 11.0 or not dg.clear_line(p.global_position, near.global_position, 0.3):
				var way2: Vector3 = dg.step_toward(p.global_position, near.global_position, 0.4)
				i.move = Vector2(way2.x, way2.z)
			i.aim = aim
			if best <= 12.0 and frame % 12 == 0 and not called and dg.clear_line(p.global_position, near.global_position, 0.3):
				i.light = true
			return i
		var reach: float = 2.3 + near.radius - 0.6
		if best > reach:
			var way: Vector3 = dg.step_toward(p.global_position, near.global_position, 0.4)
			i.move = Vector2(way.x, way.z)
		else:
			i.move = Vector2(dn.x, dn.z) * 0.3
			if frame % 9 == 0 and not called:
				i.light = true
		return i

	func poll(p: Node3D) -> Intent:
		frame += 1
		t_step += 1.0 / 60.0
		if failed != "" or step >= plan.size():
			return Intent.new()
		var limit := BOSS_STEP_LIMIT if _boss_step() else STEP_LIMIT
		if t_step > limit:
			failed = "step %d (%s) took longer than %.0f s" % [step, plan[step]["do"], limit]
			return Intent.new()
		var a: Dictionary = plan[step]
		var here := tile_of(p.global_position)
		# Before a boss, top up in a spring the way a player would.
		if _boss_step() and not healing and p.hp < p.max_hp * 0.8 and not (solver.groups[a["group"]]["room"] in dg.rooms_at(p.global_position)):
			healing = true
		if healing:
			if p.hp >= p.max_hp * 0.97:
				healing = false
			else:
				var springs := {}
				for pr in dg.props:
					if pr.kind == "spring":
						springs[pr.tiles[0]] = true
				if springs.has(here) and p.global_position.distance_to(center(here)) < 0.5:
					return Intent.new()
				var sp_path := path_to(here, springs)
				if not sp_path.is_empty():
					var nx: Vector2i = sp_path[1] if sp_path.size() > 1 else sp_path[0]
					var tv := center(nx) - p.global_position
					tv.y = 0.0
					var hi := Intent.new()
					hi.move = Vector2(tv.x, tv.z).normalized() * clampf(tv.length() * 2.0, 0.25, 1.0)
					return hi
				healing = false

		if a["do"] == "toads":
			var room: int = solver.groups[a["group"]]["room"]
			if room in dg.rooms_at(p.global_position):
				if room_toads(room).is_empty():
					return _advance("beat the toads in room %d" % room)
				return fight(p, false, room)
		else:
			var f := fight(p, true)
			if f:
				return f

		if a["do"] == "splash":
			return _press(p, -p.global_transform.basis.z, "poured out the oldest contents")

		var goals := goal_tiles(a)
		if a["do"] == "chest" and solver.props[a["prop"]]["kind"] == "chest" and dg.props[a["prop"]].state == 1:
			return _advance("opened the chest and took the gourd")
		if a["do"] == "pickup" and dg.props[a["prop"]].state == 2:
			return _advance("took the %s" % dg.props[a["prop"]].item)
		if goals.has(here) and p.global_position.distance_to(center(here)) < 0.4:
			match a["do"]:
				"take", "give":
					return _use(p, a)
				"exit":
					return _advance("reached the exit")
		var path := path_to(here, goals)
		if path.is_empty():
			failed = "step %d (%s): no path from %s" % [step, a["do"], here]
			return Intent.new()
		var next: Vector2i = path[1] if path.size() > 1 else path[0]
		var to := center(next) - p.global_position
		to.y = 0.0
		var i := Intent.new()
		if to.length() > 0.05:
			i.move = Vector2(to.x, to.z).normalized() * clampf(to.length() * 2.0, 0.25, 1.0)
		return i

	func _use(p: Node3D, a: Dictionary) -> Intent:
		var prop = dg.props[a["prop"]]
		var done: bool = p.held() == a["hold"]
		if done:
			return _advance("%s %s at %s" % ["took from" if a["do"] == "take" else "gave to", prop.kind, prop.tiles[0]])
		var aim: Vector3 = prop.point_near(p.global_position) - p.global_position
		aim.y = 0.0
		return _press(p, aim.normalized(), "")

	func _press(p: Node3D, dir: Vector3, done_msg: String) -> Intent:
		var i := Intent.new()
		i.aim = dir
		if press_wait > 0:
			press_wait -= 1
			return i
		if presses >= 4:
			failed = "step %d (%s): gourd press had no effect" % [step, plan[step]["do"]]
			return i
		i.item = true
		presses += 1
		press_wait = 30
		if done_msg != "":
			return _advance(done_msg, i)
		return i

	func _advance(msg: String, i: Intent = null) -> Intent:
		log.append("%6.1f s  %s" % [frame / 60.0, msg])
		step += 1
		t_step = 0.0
		presses = 0
		press_wait = 0
		return i if i else Intent.new()


func _initialize() -> void:
	_run()


func _run() -> void:
	var solver := Solver.new()
	solver.load_map(FileAccess.get_file_as_string("res://levels/reed_marsh.txt"))
	var plan: Array = solver.solve()["plan"]
	# Collect every reward the plan doesn't need before leaving (the vase, the peach).
	var taken := {}
	for act: Dictionary in plan:
		if act["do"] == "pickup":
			taken[act["prop"]] = true
	for i in solver.props.size():
		if solver.props[i]["kind"] == "pickup" and not taken.has(i):
			plan.append({"do": "pickup", "prop": i})
	plan.append({"do": "exit"})

	var main = load("res://main.tscn").instantiate()
	root.add_child(main)
	await process_frame
	if not main._started:   # `-- --host --level reed_marsh` makes main host instead
		main._start_solo("reed_marsh")
	var w := Walker.new()
	w.main = main
	w.dg = main.dungeon
	w.solver = solver
	w.plan = plan
	var p: Node3D = main.local_player
	p.input_source = w
	# The solver's prop order must be the game's.
	var same: bool = solver.props.size() == main.dungeon.props.size()
	for i in mini(solver.props.size(), main.dungeon.props.size()):
		same = same and solver.props[i]["kind"] == main.dungeon.props[i].kind and solver.props[i]["tiles"][0] == main.dungeon.props[i].tiles[0]
	print(("PASS" if same else "FAIL") + "  solver and game list the same props in the same order")

	var frames := 0
	while not main.dungeon.cleared and w.failed == "" and not p.is_dead() and frames < 60 * 60 * 10:
		await physics_frame
		frames += 1
	for line in w.log:
		print(line)
	var ok: bool = main.dungeon.cleared and same
	if w.failed != "":
		print("FAIL  " + w.failed)
	elif p.is_dead():
		print("FAIL  the player went down at step %d" % w.step)
	elif ok:
		print("PASS  cave cleared in %.0f s of game time, hp %.0f/%.0f, enemies defeated %d, gourd chambers %d" % [frames / 60.0, p.hp, p.max_hp, main.kills, p.gourd_slots])
	else:
		print("FAIL  cave not cleared")
	if "--host" in OS.get_cmdline_user_args():
		for k in 120:   # let the client receive the final state before the host leaves
			await physics_frame
		print("HOST props=%s" % main.prop_states())
	main.queue_free()
	await process_frame
	quit(0 if ok else 1)
