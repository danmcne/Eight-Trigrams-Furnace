extends CharacterBody3D
## Shared machinery for bosses (milestone 6). A boss is an enemy like a toad
## (group "enemies", take_hit, stagger, seal) with three differences:
##   - Poise: hits, kicks, counters, seals and parries build poise damage;
##     at POISE_BREAK its posture breaks for a long opening. Ordinary
##     staggers don't interrupt it otherwise.
##   - A sibling: when one boss of a pair falls, the other is enraged.
##   - A name and a health bar on the HUD.
## As with toads, the host simulates and every peer draws from the replicated
## state (_present), including the warning markers.

signal died(enemy: Node)

const Fx := preload("res://fx.gd")
const GRAVITY := 30.0
const POISE_BREAK := 100.0
const POISE_FROM_DAMAGE := 0.6
const POISE_FROM_STAGGER := 40.0   # per second of stagger a move would inflict
const POISE_FROM_SEAL := 35.0
const POISE_DECAY := 12.0          # per second, after POISE_DECAY_DELAY without a hit
const POISE_DECAY_DELAY := 2.0
const BREAK_TIME := 1.8
const ENRAGE_SPEED := 1.25         # movement faster
const ENRAGE_WINDUP := 0.75        # warnings shorter

# States every boss has; subclasses add their own from 10 up.
const IDLE := 0
const APPROACH := 1
const RECOVER := 2
const BROKEN := 3
const DEAD := 4

var kind := ""
var boss_name := ""
var authority := true
var net_id := 0
var big := true
var radius := 1.0
var max_hp := 400.0
var hp := 0.0
var speed := 4.5
var aggro_range := 18.0
var poise := 0.0
var enraged := false
var sibling: Node3D
var player: Node3D
var sight: Callable
var clear_line: Callable
var step_toward: Callable
var rooms_at: Callable      # dungeons: which rooms a point is in
var home_rooms: Array = []    # dungeons: the rooms this enemy never leaves
var rng := RandomNumberGenerator.new()
var state := IDLE
var aux := 0                        # one replicated integer a boss may use (the Silver King: who is called)

var _t := 0.0
var _cd := 1.5
var _recover_for := 1.0
var _since_hit := 0.0
var _target := Vector3.ZERO
var _dir := Vector3.FORWARD
var _flash := 0.0
var _nav_t := 0.0
var _nav_dir := Vector3.ZERO
var _home_pos := Vector3.ZERO
var _vis: Node3D
var _mat: StandardMaterial3D
var _base_color := Color.WHITE
var _markers := {}


func setup(seed_value: int, hp_scale := 1.0) -> void:
	rng.seed = seed_value
	max_hp *= hp_scale


func _ready() -> void:
	hp = max_hp
	_home_pos = global_position
	add_to_group("enemies")
	if authority:
		collision_layer = 4
		collision_mask = 1 | 2 | 4
		var shape := CollisionShape3D.new()
		var cap := CapsuleShape3D.new()
		cap.radius = radius
		cap.height = radius * 3.0
		shape.shape = cap
		shape.position.y = radius * 1.5
		add_child(shape)
	else:
		collision_layer = 0
		collision_mask = 0
	_vis = Node3D.new()
	add_child(_vis)
	_mat = Fx.mat(_base_color)
	_build_body()


func is_dead() -> bool:
	return state == DEAD


func is_weakened() -> bool:
	return false


func _w(seconds: float) -> float:
	return seconds * (ENRAGE_WINDUP if enraged else 1.0)


func _physics_process(delta: float) -> void:
	if authority:
		_simulate(delta)
	_present(delta)


# ---------------- Simulation (host) ----------------

func _simulate(delta: float) -> void:
	velocity.y -= GRAVITY * delta
	_cd = maxf(0.0, _cd - delta)
	_since_hit += delta
	if _since_hit > POISE_DECAY_DELAY:
		poise = maxf(0.0, poise - POISE_DECAY * delta)
	if state == IDLE or state == APPROACH:
		player = _nearest_player()
	var to_p := Vector3.ZERO
	var dist := INF
	if is_instance_valid(player) and _standing(player):
		to_p = player.global_position - global_position
		to_p.y = 0.0
		dist = to_p.length()
	match state:
		IDLE:
			if _outside_home():
				_walk_home(delta, speed)
			else:
				_friction(delta)
			if dist < aggro_range:
				state = APPROACH
		APPROACH:
			if dist == INF:
				state = IDLE
			else:
				_decide(delta, to_p, dist)
		RECOVER:
			_t += delta
			_friction(delta)
			if _t >= _recover_for:
				_enter(APPROACH)
		BROKEN:
			_t += delta
			_friction(delta)
			if _t >= BREAK_TIME:
				_enter(APPROACH)
		DEAD:
			_friction(delta)
		_:
			_act(delta, to_p, dist)
	move_and_slide()


## Subclasses: choose what to do while approaching.
func _decide(_delta: float, _to_p: Vector3, _dist: float) -> void:
	pass


## Subclasses: run their own states (10 and up).
func _act(_delta: float, _to_p: Vector3, _dist: float) -> void:
	pass


func _enter(s: int) -> void:
	state = s
	_t = 0.0


func _recover(seconds: float) -> void:
	_enter(RECOVER)
	_recover_for = seconds
	_cd = rng.randf_range(0.6, 1.4) * (0.6 if enraged else 1.0)


func _standing(p: Node3D) -> bool:
	return not p.is_dead() and not p.is_trapped()


func _standing_players() -> Array:
	var out := []
	for p in get_tree().get_nodes_in_group("players"):
		if _standing(p):
			out.append(p)
	return out


func _visible_players() -> Array:
	var out := []
	for p: Node3D in _standing_players():
		if not sight.is_valid() or sight.call(self, p):
			out.append(p)
	return out


func _nearest_player() -> Node3D:
	var best: Node3D = null
	var best_d := INF
	for p: Node3D in _visible_players():
		var d := p.global_position.distance_to(global_position)
		if d < best_d:
			best = p
			best_d = d
	return best


func _clear_to(p: Node3D) -> bool:
	return not clear_line.is_valid() or clear_line.call(global_position, p.global_position, radius * 0.8)


## Walk toward (or, with away=true, away from) a point, around walls.
func _walk(delta: float, to: Vector3, away := false) -> void:
	_nav_t -= delta
	if _nav_t <= 0.0:
		var goal := to
		if away:
			var d := global_position - to
			d.y = 0.0
			goal = global_position + (d.normalized() if d.length() > 0.01 else Vector3.BACK) * 4.0
		if step_toward.is_valid():
			_nav_dir = step_toward.call(global_position, goal, radius * 0.8, home_rooms)
		else:
			var d2 := goal - global_position
			d2.y = 0.0
			_nav_dir = d2.normalized()
		_nav_t = 0.2
	var v := _nav_dir * speed * (ENRAGE_SPEED if enraged else 1.0)
	velocity.x = v.x
	velocity.z = v.z


func _face(dir: Vector3, delta := -1.0) -> void:
	if dir.length() < 0.01:
		return
	var yaw := atan2(-dir.x, -dir.z)
	rotation.y = yaw if delta < 0.0 else lerp_angle(rotation.y, yaw, 1.0 - exp(-8.0 * delta))


func _friction(delta: float) -> void:
	var h := Vector2(velocity.x, velocity.z).move_toward(Vector2.ZERO, 30.0 * delta)
	velocity.x = h.x
	velocity.z = h.y


func take_hit(damage: float, push: Vector3) -> void:
	if state == DEAD:
		return
	hp -= damage
	_flash = 0.12
	_since_hit = 0.0
	_on_damaged(damage)
	if hp <= 0.0:
		_die()
		return
	velocity.x += push.x * 0.15
	velocity.z += push.z * 0.15
	_add_poise(damage * POISE_FROM_DAMAGE)


func _on_damaged(_damage: float) -> void:
	pass


## A stagger a move would inflict on a toad becomes poise damage here.
func stagger(seconds: float) -> void:
	if state != DEAD:
		_add_poise(seconds * POISE_FROM_STAGGER)


func seal(_seconds: float) -> void:
	if state != DEAD:
		_add_poise(POISE_FROM_SEAL)


func _add_poise(amount: float) -> void:
	if state == BROKEN or state == DEAD:
		return
	poise += amount
	if poise >= POISE_BREAK:
		poise = 0.0
		_on_interrupted()
		_enter(BROKEN)
		Fx.play(get_parent(), "ring", [global_position, radius * 1.6, Color(1, 1, 1, 0.9)])


## Subclasses: clean up whatever their current move was doing.
func _on_interrupted() -> void:
	pass


func enrage() -> void:
	if state != DEAD:
		enraged = true


func _die() -> void:
	state = DEAD
	remove_from_group("enemies")
	_on_interrupted()
	died.emit(self)
	if is_instance_valid(sibling):
		sibling.enrage()
	_death_visual()


## For the self-test agents: the attack currently aimed at a point, if any.
func threat_to(_p: Vector3, _pr: float) -> Dictionary:
	return {}


# ---------------- Replication ----------------

func write_net(b: StreamPeerBuffer) -> void:
	b.put_u32(net_id)
	b.put_float(global_position.x)
	b.put_float(global_position.y)
	b.put_float(global_position.z)
	b.put_half(rotation.y)
	b.put_u8(state)
	b.put_half(_t)
	b.put_float(_target.x)
	b.put_float(_target.z)
	b.put_half(atan2(-_dir.x, -_dir.z))
	b.put_half(_flash)
	b.put_float(hp)
	b.put_u8((1 if enraged else 0) | ((1 if poise > POISE_BREAK * 0.6 else 0) << 1))
	b.put_u32(aux)


func read_net(b: StreamPeerBuffer) -> void:
	var pos := Vector3(b.get_float(), b.get_float(), b.get_float())
	var yaw := b.get_half()
	var st := b.get_u8()
	var t := b.get_half()
	var tx := b.get_float()
	var tz := b.get_float()
	var dy := b.get_half()
	var fl := b.get_half()
	var h := b.get_float()
	var flags := b.get_u8()
	var ax := b.get_u32()
	if state == DEAD:
		return
	global_position = pos
	rotation.y = yaw
	state = st
	_t = t
	_target = Vector3(tx, 0.0, tz)
	_dir = Vector3(-sin(dy), 0.0, -cos(dy))
	_flash = fl
	hp = h
	enraged = (flags & 1) == 1
	poise = POISE_BREAK * 0.7 if (flags & 2) != 0 else 0.0
	aux = ax


func net_die() -> void:
	if state == DEAD:
		return
	state = DEAD
	remove_from_group("enemies")
	_death_visual()


func despawn() -> void:
	remove_from_group("enemies")
	_clear_markers()
	queue_free()


# ---------------- Presentation (every peer) ----------------

func _build_body() -> void:
	pass


func _present(delta: float) -> void:
	_flash = maxf(0.0, _flash - delta)
	var c := _base_color
	if enraged:
		c = c.lerp(Color(0.85, 0.2, 0.1), 0.35)
	if state == BROKEN:
		c = c.lerp(Color(0.95, 0.95, 1.0), 0.5)
	_mat.albedo_color = Color(1, 0.9, 0.85) if _flash > 0.0 else c
	var s := Vector3.ONE
	if state == BROKEN:
		s = Vector3(1.15, 0.8, 1.15)   # doubled over
	_vis.scale = _vis.scale.lerp(s, 1.0 - exp(-12.0 * delta))
	_pose(delta)
	_telegraphs()


func _pose(_delta: float) -> void:
	pass


func _telegraphs() -> void:
	pass


## Keep a marker alive while `want` is true (build it on first need), free it otherwise.
func _marker(key: String, want: bool, build: Callable) -> Node3D:
	var m: Node3D = _markers.get(key)
	if want:
		if not is_instance_valid(m):
			m = build.call()
			_markers[key] = m
		return m
	if is_instance_valid(m):
		m.queue_free()
	_markers.erase(key)
	return null


func _clear_markers() -> void:
	for m in _markers.values():
		if is_instance_valid(m):
			m.queue_free()
	_markers.clear()


func _wedge(arc_deg: float, reach: float, color: Color) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = Fx.arc_mesh(arc_deg, reach)
	var m := Fx.mat(color, true)
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	mi.material_override = m
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	get_parent().add_child(mi)
	return mi


func _death_visual() -> void:
	_clear_markers()
	collision_layer = 0
	collision_mask = 1
	var tw := create_tween()
	tw.tween_property(self, "scale", Vector3(1.4, 0.05, 1.4), 0.8)
	tw.tween_callback(queue_free)


# ---------------- Mesh helpers ----------------

func _part(mesh: Mesh, pos: Vector3, material: Material) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = material
	mi.position = pos
	_vis.add_child(mi)
	return mi


func _horns(y: float, color: Color) -> void:
	for side: float in [-1.0, 1.0]:
		var cm := CylinderMesh.new()
		cm.top_radius = 0.0
		cm.bottom_radius = 0.14
		cm.height = 0.6
		var h := _part(cm, Vector3(side * radius * 0.45, y, -0.05), Fx.mat(color))
		h.rotation.z = -side * 0.35


## Outside its home room (a dash or a shove carried it out) and with nobody in
## sight: head back.
func _outside_home() -> bool:
	if home_rooms.is_empty() or not rooms_at.is_valid():
		return false
	for r in rooms_at.call(global_position):
		if r in home_rooms:
			return false
	return true


func _walk_home(delta: float, top_speed: float) -> void:
	var dir: Vector3 = step_toward.call(global_position, _home_pos, radius * 0.8, []) if step_toward.is_valid() else Vector3.ZERO
	var h := Vector2(velocity.x, velocity.z).move_toward(Vector2(dir.x, dir.z) * top_speed, 30.0 * delta)
	velocity.x = h.x
	velocity.z = h.y
