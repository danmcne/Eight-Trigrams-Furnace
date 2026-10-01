extends Node3D
## A dungeon built from a text map (see levels/reed_marsh.txt).
##
## The host runs the rules: the gourd, triggers, doors, the chest and the exit.
## Clients receive one byte per prop each tick and show the same state.

const Prop := preload("res://prop.gd")
const Fx := preload("res://fx.gd")
const TILE := 2.0
const COLLIDE_HEIGHT := 4.0   # see _build_static

# Gourd contents (also stored on the player).
const EMPTY := 0
const WATER := 1
const FIRE := 2
const TOAD := 3

# ---------------- Tuning ----------------
const GOURD_RANGE := 4.5          # metres to the nearest tile of the target
const GOURD_HALF_ANGLE := 60.0    # degrees either side of facing
const BURST_RANGE := 3.5          # released into nothing: fire burns, water splashes
const FIRE_BURST_DAMAGE := 15.0
const WATER_SPLASH_DAMAGE := 4.0
const THROW_RANGE := 10.0         # a released toad flies this far
const THROW_DAMAGE := 25.0
const CHEST_RANGE := 2.3
const PICKUP_RANGE := 1.3
const SPRING_HEAL := 10.0         # health per second to anyone standing in a spring
const SPRING_RANGE := 0.9
const EXIT_RANGE := 1.4
# ----------------------------------------

## Set by main (host): spawn_toad(pos: Vector3, dazed: bool) for thrown toads,
## and gourd_changed(player) when a player's gourd changes.
var host: Object

var terrain: PackedStringArray = []
var links: PackedStringArray = []
var width := 0
var height := 0
var props: Array = []                  # Prop nodes, in a fixed order (replication)
var enemy_spawns: Array = []           # {pos, kind, link}; kind: toad, big_toad, golden, silver
var start := Vector3.ZERO
var cleared := false                   # exit reached
var _room := {}                        # Vector2i -> room id
var _link_toads := {}                  # link -> {net_id: true}, alive toads that gate a door


## Split a map file into its two grids.
static func parse(text: String) -> Dictionary:
	var t := PackedStringArray()
	var l := PackedStringArray()
	var in_links := false
	for line in text.split("\n"):
		if line.begins_with("# "):
			continue   # comment (map rows never contain spaces)
		if line.strip_edges() == "":
			continue
		if line.strip_edges() == "---":
			in_links = true
			continue
		if in_links:
			l.append(line)
		else:
			t.append(line)
	return {"terrain": t, "links": l}


static func is_boundary(c: String) -> bool:
	return c == "#" or c == "D" or c == "F" or c == "T"


## Rooms: flood fill over everything except walls, doors, fire walls and brambles.
static func compute_rooms(t: PackedStringArray) -> Dictionary:
	var room := {}
	var next := 0
	for y in t.size():
		for x in t[y].length():
			var p := Vector2i(x, y)
			if room.has(p) or is_boundary(t[y][x]):
				continue
			var stack := [p]
			room[p] = next
			while not stack.is_empty():
				var q: Vector2i = stack.pop_back()
				for d: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
					var n := q + d
					if n.y < 0 or n.y >= t.size() or n.x < 0 or n.x >= t[n.y].length():
						continue
					if room.has(n) or is_boundary(t[n.y][n.x]):
						continue
					room[n] = next
					stack.append(n)
			next += 1
	return room


func load_map(text: String) -> void:
	var m := parse(text)
	terrain = m["terrain"]
	links = m["links"]
	height = terrain.size()
	width = terrain[0].length()
	_room = compute_rooms(terrain)
	_build_static()
	_build_props()


func room_at(pos: Vector3) -> int:
	var t := Vector2i(floori(pos.x / TILE), floori(pos.z / TILE))
	return _room.get(t, -1)


## The rooms a point belongs to. A doorway tile (an open door, a doused fire
## wall, burnt brambles) belongs to both rooms it joins, so nobody standing in
## a doorway is outside every room.
func rooms_at(pos: Vector3) -> Array:
	var t := Vector2i(floori(pos.x / TILE), floori(pos.z / TILE))
	if _room.has(t):
		return [_room[t]]
	var out := []
	for d: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
		var r: int = _room.get(t + d, -1)
		if r >= 0 and not r in out:
			out.append(r)
	return out


func share_room(a: Vector3, b: Vector3) -> bool:
	var ra := rooms_at(a)
	for r in rooms_at(b):
		if r in ra:
			return true
	return false


## Enemies only notice players in a room they share, and only within their
## own home rooms: one carried out by a dash or a shove goes back instead of
## fighting next door.
func can_see(toad: Node3D, player: Node3D) -> bool:
	if not share_room(toad.global_position, player.global_position):
		return false
	var home: Array = toad.home_rooms
	if home.is_empty():
		return true
	for r in rooms_at(player.global_position):
		if r in home:
			for r2 in rooms_at(toad.global_position):
				if r2 in home:
					return true
	return false


func _link_at(x: int, y: int) -> int:
	if y < links.size() and x < links[y].length() and links[y][x].is_valid_int():
		return int(links[y][x])
	return -1


# ---------------- Building ----------------

func _build_static() -> void:
	var floor_mi := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(width * TILE, height * TILE)
	floor_mi.mesh = pm
	floor_mi.material_override = Fx.mat(Color(0.5, 0.52, 0.42))
	floor_mi.position = Vector3(width * TILE * 0.5, 0, height * TILE * 0.5)
	add_child(floor_mi)
	var ground := StaticBody3D.new()
	var gs := CollisionShape3D.new()
	var gb := BoxShape3D.new()
	gb.size = Vector3(width * TILE, 1.0, height * TILE)
	gs.shape = gb
	ground.add_child(gs)
	ground.position = Vector3(width * TILE * 0.5, -0.5, height * TILE * 0.5)
	add_child(ground)

	# Walls: one box per horizontal run of '#'.
	var walls := StaticBody3D.new()
	add_child(walls)
	var wall_mat := Fx.mat(Color(0.36, 0.35, 0.32))
	for y in height:
		var x := 0
		while x < width:
			if terrain[y][x] != "#":
				x += 1
				continue
			var x0 := x
			while x < width and terrain[y][x] == "#":
				x += 1
			var size := Vector3((x - x0) * TILE, 1.2, TILE)
			var center := Vector3((x0 + x) * TILE * 0.5, 0.6, y * TILE + TILE * 0.5)
			# Walls are drawn low so the camera sees over them, but collide far
			# higher than anything can leap, so nothing ever ends up on top.
			var cs := CollisionShape3D.new()
			var bs := BoxShape3D.new()
			bs.size = Vector3(size.x, COLLIDE_HEIGHT, size.z)
			cs.shape = bs
			cs.position = Vector3(center.x, COLLIDE_HEIGHT * 0.5, center.z)
			walls.add_child(cs)
			var mi := MeshInstance3D.new()
			var bm := BoxMesh.new()
			bm.size = size
			mi.mesh = bm
			mi.material_override = wall_mat
			mi.position = center
			add_child(mi)

	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.2, 0.21, 0.2)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.75, 0.74, 0.7)
	env.ambient_light_energy = 0.75
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-60, 30, 0)
	sun.shadow_enabled = true
	add_child(sun)


const KINDS := {"~": "pool", "F": "firewall", "T": "bramble", "D": "door", "b": "brazier", "B": "brazier",
	"E": "eternal", "w": "spring", "U": "basin", "C": "chest", "X": "exit", "G": "pickup", "V": "pickup", "P": "pickup"}
const PICKUPS := {"G": "gourd", "V": "vase", "P": "peach"}
const REGIONS := ["~", "F", "T"]   # contiguous tiles of these form one prop
const ENEMIES := {"t": "toad", "g": "big_toad", "K": "golden", "k": "silver", "c": "clever", "j": "wily"}


func _build_props() -> void:
	var seen := {}
	for y in height:
		for x in width:
			var c := terrain[y][x]
			var p := Vector2i(x, y)
			if c == "S":
				start = Prop.tile_center(p)
			elif ENEMIES.has(c):
				enemy_spawns.append({"pos": Prop.tile_center(p), "kind": ENEMIES[c], "link": _link_at(x, y)})
			if not KINDS.has(c) or seen.has(p):
				continue
			var prop := Prop.new()
			prop.kind = KINDS[c]
			prop.item = PICKUPS.get(c, "")
			prop.link = _link_at(x, y)
			if c in REGIONS:
				var stack := [p]
				seen[p] = true
				while not stack.is_empty():
					var q: Vector2i = stack.pop_back()
					prop.tiles.append(q)
					for d: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
						var n := q + d
						if n.x >= 0 and n.y >= 0 and n.x < width and n.y < height and not seen.has(n) and terrain[n.y][n.x] == c:
							seen[n] = true
							stack.append(n)
			else:
				seen[p] = true
				prop.tiles.append(p)
			if c == "B":
				prop.state = 1
			for t in prop.tiles:
				if _room.has(t):
					prop.rooms[_room[t]] = true
				for d: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
					if _room.has(t + d):
						prop.rooms[_room[t + d]] = true
			add_child(prop)
			prop.build()
			props.append(prop)


# ---------------- Host: triggers and doors ----------------

func register_toad(net_id: int, link: int) -> void:
	if link < 0:
		return
	if not _link_toads.has(link):
		_link_toads[link] = {}
	_link_toads[link][net_id] = true


## A toad is gone (killed or captured): it no longer holds its door shut.
func toad_gone(net_id: int) -> void:
	for l in _link_toads:
		_link_toads[l].erase(net_id)


func _satisfied(prop) -> bool:
	match prop.kind:
		"brazier", "basin", "chest":
			return prop.state == 1
	return true   # pickups and the rest never hold a door shut


## Host, every tick: springs, pickups, doors, exit. `players` are the standing players.
func tick(players: Array, delta: float) -> void:
	for prop in props:
		if prop.kind == "spring":
			for p in players:
				if _flat_dist(p.global_position, prop.point_near(p.global_position)) <= SPRING_RANGE:
					p.heal(SPRING_HEAL * delta)
		if prop.kind == "chest" and prop.state == 0:
			for p in players:
				if _flat_dist(p.global_position, prop.point_near(p.global_position)) <= CHEST_RANGE:
					prop.set_state(1)
					p.has_gourd = true
					p.gourd = EMPTY
					break
		elif prop.kind == "pickup":
			if prop.state == 0 and _link_open(prop.link, prop):
				prop.set_state(1)
			if prop.state == 1:
				for p in players:
					if _flat_dist(p.global_position, prop.point_near(p.global_position)) <= PICKUP_RANGE:
						prop.set_state(2)
						_grant(prop.item, p)
						break
		elif prop.kind == "exit":
			if prop.state == 0 and _link_open(prop.link, prop):
				prop.set_state(1)   # unsealed
			if prop.state == 1:
				for p in players:
					if _flat_dist(p.global_position, prop.point_near(p.global_position)) <= EXIT_RANGE:
						prop.set_state(2)
						cleared = true
	for door in props:
		if door.kind == "door" and door.state == 0 and _link_open(door.link, door):
			door.set_state(1)


## Everything sharing `link` (other than `except`) is done, and its enemies are gone.
func _link_open(link: int, except) -> bool:
	if link < 0:
		return true
	if not _link_toads.get(link, {}).is_empty():
		return false
	for prop in props:
		if prop != except and prop.link == link and not prop.kind in ["door", "exit", "pickup"] and not _satisfied(prop):
			return false
	return true


## Rewards never gate anything; they go to the party.
##   gourd: to whoever takes it.  vase: joins the gourd, whoever carries it.
##   peach: every player grows stronger.
func _grant(item: String, taker: Node3D) -> void:
	match item:
		"gourd":
			taker.has_gourd = true
			taker.set_held([])
		"vase":
			var holder: Node3D = taker
			for q in get_tree().get_nodes_in_group("players"):
				if q.has_gourd:
					holder = q
			holder.has_gourd = true
			holder.gourd_slots = 2
		"peach":
			for q in get_tree().get_nodes_in_group("players"):
				q.add_peach()


static func _flat_dist(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x - b.x, a.z - b.z).length()


# ---------------- Host: the gourd ----------------

func _can_take(prop) -> int:
	match prop.kind:
		"pool":
			return WATER if prop.state == 0 else EMPTY
		"spring":
			return WATER
		"brazier":
			return FIRE if prop.state == 1 else EMPTY
		"eternal":
			return FIRE
	return EMPTY


func _accepts(prop, what: int) -> bool:
	match what:
		FIRE:
			return (prop.kind == "brazier" and prop.state == 0) or (prop.kind == "bramble" and prop.state == 0)
		WATER:
			return (prop.kind == "firewall" and prop.state == 0) or (prop.kind == "basin" and prop.state == 0) \
				or (prop.kind == "brazier" and prop.state == 1)
	return false


## The nearest prop in reach, in the facing cone and usable from the player's room.
func _pick_prop(p: Node3D, dir: Vector3, want: Callable) -> Object:
	var best: Object = null
	var best_d := INF
	var here := rooms_at(p.global_position)
	for prop in props:
		if not want.call(prop):
			continue
		var usable := false
		for r in here:
			usable = usable or prop.rooms.has(r)
		if not usable:
			continue
		var c: Vector3 = prop.point_near(p.global_position)
		var d := c - p.global_position
		d.y = 0.0
		var dist := d.length()
		if dist > GOURD_RANGE or dist >= best_d:
			continue
		if dist > 0.5 and dir.angle_to(d / dist) > deg_to_rad(GOURD_HALF_ANGLE):
			continue
		best = prop
		best_d = dist
	return best


func _pick_toad(p: Node3D, dir: Vector3) -> Node3D:
	var best: Node3D = null
	var best_d := INF
	for t in get_tree().get_nodes_in_group("enemies"):
		if t.big or not t.is_weakened() or not can_see(t, p):
			continue
		var d: Vector3 = t.global_position - p.global_position
		d.y = 0.0
		var dist := d.length()
		if dist > GOURD_RANGE or dist >= best_d:
			continue
		if dist > 0.5 and dir.angle_to(d / dist) > deg_to_rad(GOURD_HALF_ANGLE):
			continue
		best = t
		best_d = dist
	return best


const WHAT_COLOR := {WATER: Color(Fx.WATER, 0.9), FIRE: Color(Fx.FIRE, 0.9), TOAD: Color(Fx.TOAD_GREEN, 0.9)}


## The player pressed the gourd button. With room in the gourd, it draws in
## what the player faces. Otherwise (or if nothing there can be drawn in) it
## pours: into whatever faced thing accepts something it holds, or, if nothing
## does, the oldest contents go into nothing.
func gourd_use(p: Node3D, dir: Vector3) -> void:
	var here: Vector3 = p.global_position + Vector3(0, 1.0, 0)
	var held: Array = p.held()
	if held.size() < p.gourd_slots:
		var toad := _pick_toad(p, dir)
		var prop = _pick_prop(p, dir, func(q) -> bool: return _can_take(q) != EMPTY)
		if toad and (prop == null or toad.global_position.distance_to(p.global_position) < p.global_position.distance_to(prop.point_near(p.global_position))):
			Fx.play(self, "stream", [toad.global_position + Vector3(0, 0.5, 0), here, WHAT_COLOR[TOAD]])
			toad.capture()
			held.append(TOAD)
			p.set_held(held)
			return
		if prop:
			var taken := _can_take(prop)
			Fx.play(self, "stream", [prop.point_near(p.global_position) + Vector3(0, 0.8, 0), here, WHAT_COLOR[taken]])
			if prop.kind == "pool" or prop.kind == "brazier":
				prop.set_state(1 if prop.kind == "pool" else 0)
			held.append(taken)
			p.set_held(held)
			return
	if held.is_empty():
		return

	var target = _pick_prop(p, dir, func(q) -> bool:
		for w in held:
			if _accepts(q, w):
				return true
		return false)
	if target:
		var poured: int = EMPTY
		for w in held:
			if _accepts(target, w):
				poured = w
				break
		held.erase(poured)
		p.set_held(held)
		Fx.play(self, "stream", [here, target.point_near(p.global_position) + Vector3(0, 0.8, 0), WHAT_COLOR[poured]])
		match target.kind:
			"brazier":
				target.set_state(1 if poured == FIRE else 0)
			_:
				target.set_state(1)
		return

	var what: int = held.pop_front()
	p.set_held(held)
	if what != TOAD:
		# Nothing takes it: fire scorches, water splashes, everything in a short cone.
		var arc := GOURD_HALF_ANGLE * 2.0
		Fx.play(self, "arc", [p.global_position, atan2(-dir.x, -dir.z), arc, BURST_RANGE, WHAT_COLOR[what]])
		for t in get_tree().get_nodes_in_group("enemies"):
			var d: Vector3 = t.global_position - p.global_position
			d.y = 0.0
			if d.length() <= BURST_RANGE + t.radius and (d.length() < 0.5 or dir.angle_to(d.normalized()) <= deg_to_rad(GOURD_HALF_ANGLE)):
				t.take_hit(FIRE_BURST_DAMAGE if what == FIRE else WATER_SPLASH_DAMAGE, d.normalized() * 6.0)
		return

	# A toad is flung straight ahead; it strikes the first enemy or wall, then lands dazed.
	var end := p.global_position + dir * THROW_RANGE
	var hit: Node3D = null
	var hit_along := THROW_RANGE
	for t in get_tree().get_nodes_in_group("enemies"):
		var rel: Vector3 = t.global_position - p.global_position
		rel.y = 0.0
		var along := rel.dot(dir)
		if along > 0.3 and along < hit_along and (rel - dir * along).length() < t.radius + 0.4:
			hit = t
			hit_along = along
	var step := 0.25
	var s := 0.5
	while s < hit_along:
		var q := p.global_position + dir * s
		if _solid_at(q):
			hit = null
			hit_along = s - 0.5
			break
		s += step
	end = p.global_position + dir * maxf(hit_along, 0.8)
	Fx.play(self, "stream", [here, end + Vector3(0, 0.5, 0), WHAT_COLOR[TOAD]])
	if hit:
		hit.take_hit(THROW_DAMAGE, dir * 8.0)
	if host:
		host.spawn_toad(end - dir * 0.8, true)


# ---------------- Navigation (used by toads and the test agent) ----------------

func _tile(pos: Vector3) -> Vector2i:
	return Vector2i(floori(pos.x / TILE), floori(pos.z / TILE))


func walkable_tile(t: Vector2i) -> bool:
	if t.y < 0 or t.y >= height or t.x < 0 or t.x >= width or terrain[t.y][t.x] == "#":
		return false
	for prop in props:
		if prop.blocks() and t in prop.tiles:
			return false
	return true


## True if a body of radius r can pass straight from a to b (walls and blocking props).
func clear_line(a: Vector3, b: Vector3, r: float) -> bool:
	var d := b - a
	d.y = 0.0
	var length := d.length()
	if length < 0.01:
		return true
	var dir := d / length
	var side := Vector3(-dir.z, 0.0, dir.x) * r
	var s := 0.0
	while s <= length:
		var p := a + dir * s
		if _solid_at(p) or _solid_at(p + side) or _solid_at(p - side):
			return false
		s += 0.5
	return true


## Direction to move from a toward b: straight if the way is clear, otherwise
## toward the next tile of a shortest tile path. With `home` (room ids), the
## mover stays in those rooms: a goal outside them is replaced by the nearest
## tile inside.
func step_toward(a: Vector3, b: Vector3, r: float, home: Array = []) -> Vector3:
	var d := b - a
	d.y = 0.0
	var goal := _tile(b)
	var goal_ok := home.is_empty() or _in_rooms(goal, home)
	if goal_ok and clear_line(a, b, r):
		return d.normalized() if d.length() > 0.01 else Vector3.ZERO
	var from := _tile(a)
	var prev := {from: from}
	var queue := [from]
	var best := from
	var best_d := Vector2(from - goal).length()
	while not queue.is_empty():
		var q: Vector2i = queue.pop_front()
		if q == goal:
			best = q
			break
		var qd := Vector2(q - goal).length()
		if qd < best_d:
			best = q
			best_d = qd
		for dd: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			var n := q + dd
			if not prev.has(n) and walkable_tile(n) and (home.is_empty() or _in_rooms(n, home)):
				prev[n] = q
				queue.append(n)
	if best == from:
		var c0 := Prop.tile_center(from) - a
		c0.y = 0.0
		return c0.normalized() if c0.length() > 0.3 else Vector3.ZERO
	var nxt := best
	while prev[nxt] != from:
		nxt = prev[nxt]
	var c := Prop.tile_center(nxt) - a
	c.y = 0.0
	return c.normalized() if c.length() > 0.01 else d.normalized()


func _in_rooms(t: Vector2i, home: Array) -> bool:
	for rr in rooms_at(Prop.tile_center(t)):
		if rr in home:
			return true
	return false


func _solid_at(pos: Vector3) -> bool:
	var t := Vector2i(floori(pos.x / TILE), floori(pos.z / TILE))
	if t.y < 0 or t.y >= height or t.x < 0 or t.x >= width:
		return true
	if terrain[t.y][t.x] == "#":
		return true
	for prop in props:
		if prop.blocks() and t in prop.tiles:
			return true
	return false


# ---------------- Replication ----------------

func write_net(b: StreamPeerBuffer) -> void:
	b.put_u16(props.size())
	for prop in props:
		b.put_u8(prop.state)


func read_net(b: StreamPeerBuffer) -> void:
	var n := b.get_u16()
	for i in n:
		var s := b.get_u8()
		if i < props.size():
			props[i].set_state(s)
