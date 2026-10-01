extends CharacterBody3D
## Giant marsh toad (milestone 3), the first Five Poisons family.
## Each state has its own silhouette, and the telegraph colour names the answer:
##   compressed, trembling, RED ring        -> leap; unblockable, get off the ring
##   reared back, throat turning GOLD, gold line -> tongue lash; parry it (severs
##                                             the tongue), block it, or sidestep
##   flat and pale                          -> recovering; punish it
##
## On the host (`authority`) the toad thinks and moves. On a client it is a
## puppet: position and a few state variables arrive from the host, and
## everything drawn (pose, markers) is computed from them by _present().

signal died(toad: Node)

const Fx := preload("res://fx.gd")

# ---------------- Tuning (small toad; big toad overrides in setup) ----------------
var max_hp := 30.0
var poise := 0.0            # hits below this damage don't interrupt a telegraph
var radius := 0.6
var aggro_range := 16.0
var hop_speed := 4.5
var hop_interval := 0.55
var leap_range := 6.5
var tongue_min := 3.0
var tongue_max := 8.0
var crouch_time := 0.65
var leap_time := 0.55
var leap_damage := 12.0
var leap_radius := 1.7
var tongue_windup := 0.75
var tongue_length := 7.5
var tongue_width := 0.7
var tongue_damage := 9.0
var tongue_pull := 6.0
var sever_damage := 10.0
var sever_stagger := 1.2
var recover_time := 1.0
var cooldown_min := 0.8
var cooldown_max := 1.8
var stagger_time := 0.35
const GRAVITY := 30.0
const PALE := Color(0.86, 0.84, 0.66)      # recovering: the only pale state
const THROAT := Color(0.62, 0.66, 0.36)    # turns gold (parryable) as a lash approaches
const FLASH := Color(1.0, 0.88, 0.82)
const SEALED_TINT := Color(0.95, 0.85, 0.5)   # wrapped in a talisman's paper
# -----------------------------------------------------------------------------------

enum S { IDLE, APPROACH, CROUCH, LEAP, TONGUE_WIND, TONGUE_LASH, RECOVER, STAGGER, DEAD, SEALED }

var state := S.IDLE
var authority := true
var net_id := 0
var player: Node3D          # current target: the nearest standing player it can see
var sight: Callable         # optional (toad, player) -> bool; dungeons limit sight to one room
var clear_line: Callable    # optional (a, b, radius) -> bool: attacks need a clear line
var step_toward: Callable   # optional (a, b, radius, home) -> direction around walls
var rooms_at: Callable      # dungeons: which rooms a point is in
var home_rooms: Array = []  # dungeons: the rooms this enemy never leaves
var big := false
var hp := 0.0
var has_tongue := true
var rng := RandomNumberGenerator.new()

var _t := 0.0
var _stagger_for := 0.0
var _hop_t := 0.0
var _nav_t := 0.0
var _nav_dir := Vector3.ZERO
var _home_pos := Vector3.ZERO
var _cd := 0.0
var _target := Vector3.ZERO
var _dir := Vector3.FORWARD
var _flash := 0.0
var _ring: Node3D
var _line: MeshInstance3D
var _line_mat: StandardMaterial3D
var _lash: MeshInstance3D
var _vis: Node3D
var _throat: MeshInstance3D
var _throat_mat: StandardMaterial3D
var _mat: StandardMaterial3D
var _base_color := Color(0.42, 0.5, 0.26)
var _jitter := RandomNumberGenerator.new()   # visual only; keeps AI randomness untouched


func setup(is_big: bool, seed_value: int, hp_scale := 1.0) -> void:
	big = is_big
	rng.seed = seed_value
	_jitter.seed = seed_value + 7919
	if big:
		max_hp = 90.0
		poise = 18.0
		radius = 1.0
		hop_speed = 3.5
		leap_range = 8.0
		crouch_time = 0.8
		leap_damage = 18.0
		leap_radius = 2.4
		tongue_windup = 0.85
		tongue_length = 9.0
		tongue_damage = 13.0
		recover_time = 1.2
		_base_color = Color(0.3, 0.34, 0.2)
	max_hp *= hp_scale


func _ready() -> void:
	hp = max_hp
	_home_pos = global_position
	add_to_group("enemies")
	if authority:
		collision_layer = 4
		collision_mask = 1 | 2 | 4
		var shape := CollisionShape3D.new()
		var sph := SphereShape3D.new()
		sph.radius = radius
		shape.shape = sph
		shape.position.y = radius
		add_child(shape)
	else:
		collision_layer = 0
		collision_mask = 0
	_cd = rng.randf_range(0.3, cooldown_max)

	_vis = Node3D.new()   # pivots at the feet, so squashing keeps it on the ground
	add_child(_vis)
	var body := MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = radius
	sm.height = radius * 1.4
	body.mesh = sm
	body.position.y = radius * 0.7
	_mat = Fx.mat(_base_color)
	body.material_override = _mat
	_vis.add_child(body)
	_throat = MeshInstance3D.new()
	var tm := SphereMesh.new()
	tm.radius = radius * 0.42
	tm.height = radius * 0.84
	_throat.mesh = tm
	_throat.position = Vector3(0, radius * 0.4, -radius * 0.62)
	_throat_mat = Fx.mat(THROAT)
	_throat.material_override = _throat_mat
	_vis.add_child(_throat)
	for side: float in [-1.0, 1.0]:
		var eye := MeshInstance3D.new()
		var em := SphereMesh.new()
		em.radius = radius * 0.2
		em.height = radius * 0.4
		eye.mesh = em
		eye.position = Vector3(side * radius * 0.45, radius * 1.25, -radius * 0.55)
		eye.material_override = Fx.mat(Color(0.85, 0.75, 0.2))
		_vis.add_child(eye)


func is_dead() -> bool:
	return state == S.DEAD


## Weakened small toads can be drawn into the gourd.
func is_weakened() -> bool:
	return state == S.RECOVER or state == S.STAGGER or state == S.SEALED


## Knocked off balance whatever its poise: interrupts any warning.
func stagger(seconds: float) -> void:
	if state == S.DEAD or state == S.LEAP or state == S.SEALED:
		return
	_enter(S.STAGGER)
	_stagger_for = maxf(seconds, stagger_time)


## Pinned by a talisman: cannot move or attack until it wears off.
func seal(seconds: float) -> void:
	if state == S.DEAD or state == S.LEAP:
		return
	_enter(S.SEALED)
	_stagger_for = seconds
	velocity.x = 0.0
	velocity.z = 0.0


func capture() -> void:
	if state != S.DEAD:
		_die()


## A toad flung from the gourd lands stunned.
func daze(seconds: float) -> void:
	_enter(S.STAGGER)
	_stagger_for = seconds


## For the self-test bot only: the attack currently aimed at point p, if any.
func threat_to(p: Vector3, pr: float) -> Dictionary:
	if state == S.CROUCH or state == S.LEAP:
		var d := p - _target
		d.y = 0.0
		if d.length() <= leap_radius + pr + 0.5:
			var eta := (crouch_time - _t + leap_time) if state == S.CROUCH else (leap_time - _t)
			return {"kind": "red", "eta": eta, "from": _target}
	elif state == S.TONGUE_WIND and _in_line(p, pr):
		return {"kind": "gold", "eta": tongue_windup - _t, "from": global_position}
	return {}


func _physics_process(delta: float) -> void:
	if authority:
		_simulate(delta)
	_present(delta)


# ---------------- Replication ----------------
# Fixed binary layout, written after the net id (which main reads to route it).

const BYTES_AFTER_ID := 30


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
	b.put_u8(1 if has_tongue else 0)
	b.put_half(_flash)


func read_net(b: StreamPeerBuffer) -> void:
	var pos := Vector3(b.get_float(), b.get_float(), b.get_float())
	var yaw := b.get_half()
	var st := b.get_u8()
	var t := b.get_half()
	var tx := b.get_float()
	var tz := b.get_float()
	var dir_yaw := b.get_half()
	var tongue := b.get_u8() == 1
	var flash := b.get_half()
	if state == S.DEAD:
		return   # dying locally; the rest of the entry is already consumed
	global_position = pos
	rotation.y = yaw
	state = st as S
	_t = t
	_target = Vector3(tx, 0.0, tz)
	_dir = Vector3(-sin(dir_yaw), 0.0, -cos(dir_yaw))
	has_tongue = tongue
	_flash = flash


## Client side: the host reports this toad's death.
func net_die() -> void:
	if state == S.DEAD:
		return
	state = S.DEAD
	remove_from_group("enemies")
	_death_visual()


## Host side: remove without a death (arena reset).
func despawn() -> void:
	remove_from_group("enemies")
	_clear_telegraphs()
	queue_free()


# ---------------- Simulation (host only) ----------------

func _simulate(delta: float) -> void:
	velocity.y -= GRAVITY * delta
	_cd = maxf(0.0, _cd - delta)
	if state == S.IDLE or state == S.APPROACH:
		player = _nearest_player()

	var to_p := Vector3.ZERO
	var dist := INF
	if is_instance_valid(player) and not player.is_dead():
		to_p = player.global_position - global_position
		to_p.y = 0.0
		dist = to_p.length()

	match state:
		S.IDLE:
			if _outside_home():
				_walk_home(delta, hop_speed)
			else:
				_friction(delta)
			if dist < aggro_range:
				state = S.APPROACH
		S.APPROACH:
			_approach(delta, to_p, dist)
		S.CROUCH:
			_t += delta
			_friction(delta)
			if _t >= crouch_time:
				_launch()
		S.LEAP:
			_t += delta
			if _t > 0.1 and is_on_floor():
				_land()
		S.TONGUE_WIND:
			_t += delta
			_friction(delta)
			if _t >= tongue_windup:
				_lash_out()
		S.TONGUE_LASH:
			_t += delta
			if _t >= 0.3:
				_enter(S.RECOVER)
		S.RECOVER:
			_t += delta
			_friction(delta)
			if _t >= recover_time:
				state = S.APPROACH
				_cd = rng.randf_range(cooldown_min, cooldown_max)
		S.STAGGER, S.SEALED:
			_t += delta
			_friction(delta)
			if _t >= _stagger_for:
				state = S.APPROACH
		S.DEAD:
			_friction(delta)
	move_and_slide()


func _enter(s: S) -> void:
	state = s
	_t = 0.0


func _standing_players() -> Array:
	var out := []
	for p in get_tree().get_nodes_in_group("players"):
		if not p.is_dead() and not p.is_trapped():
			out.append(p)
	return out


func _nearest_player() -> Node3D:
	var best: Node3D = null
	var best_d := INF
	for p: Node3D in _standing_players():
		if sight.is_valid() and not sight.call(self, p):
			continue
		var d := p.global_position.distance_to(global_position)
		if d < best_d:
			best = p
			best_d = d
	return best


func _approach(delta: float, to_p: Vector3, dist: float) -> void:
	if dist == INF:
		state = S.IDLE
		return
	if is_on_floor():
		_friction(delta)
	rotation.y = lerp_angle(rotation.y, atan2(-to_p.x, -to_p.z), 1.0 - exp(-8.0 * delta))
	var clear: bool = not clear_line.is_valid() or clear_line.call(global_position, player.global_position, radius * 0.8)
	if clear and _cd <= 0.0 and dist <= maxf(tongue_max, leap_range):
		var can_tongue := has_tongue and dist >= tongue_min and dist <= tongue_max
		var can_leap := dist <= leap_range
		if can_leap and (not can_tongue or rng.randf() < 0.55):
			_begin_crouch()
			return
		if can_tongue:
			_begin_tongue(to_p / dist)
			return
	_hop_t -= delta
	_nav_t -= delta
	if step_toward.is_valid() and _nav_t <= 0.0:
		_nav_dir = step_toward.call(global_position, player.global_position, radius * 0.8, home_rooms)
		_nav_t = 0.25
	if _hop_t <= 0.0 and is_on_floor() and dist > 2.0:
		var d := _nav_dir if step_toward.is_valid() and _nav_dir != Vector3.ZERO else to_p / dist
		velocity.x = d.x * hop_speed * 2.0
		velocity.z = d.z * hop_speed * 2.0
		velocity.y = 5.0
		_hop_t = hop_interval


func _friction(delta: float) -> void:
	var h := Vector2(velocity.x, velocity.z).move_toward(Vector2.ZERO, 30.0 * delta)
	velocity.x = h.x
	velocity.z = h.y


func _begin_crouch() -> void:
	_enter(S.CROUCH)
	_target = player.global_position   # locked now: step off the ring to avoid it


func _launch() -> void:
	_enter(S.LEAP)
	var d := _target - global_position
	d.y = 0.0
	velocity.x = d.x / leap_time
	velocity.z = d.z / leap_time
	velocity.y = 0.5 * GRAVITY * leap_time
	collision_mask = 1 | 4   # sail over players


## The landing hits every standing player on the ring, not only the target.
func _land() -> void:
	collision_mask = 1 | 2 | 4
	velocity = Vector3.ZERO
	for p: Node3D in _standing_players():
		var d := p.global_position - global_position
		d.y = 0.0
		var pr: float = p.radius
		if d.length() <= leap_radius + pr:
			var away := d.normalized() if d.length() > 0.01 else Vector3.BACK
			p.take_hit(leap_damage, away * 6.0, self, false)
	_enter(S.RECOVER)


func _begin_tongue(dir: Vector3) -> void:
	_enter(S.TONGUE_WIND)
	_dir = dir
	rotation.y = atan2(-dir.x, -dir.z)


func _in_line(p: Vector3, pr: float) -> bool:
	var rel := p - global_position
	rel.y = 0.0
	var along := rel.dot(_dir)
	return along > 0.0 and along < tongue_length + pr and (rel - _dir * along).length() < tongue_width * 0.5 + pr


## The tongue strikes the first standing player along the line.
func _lash_out() -> void:
	_enter(S.TONGUE_LASH)
	var victim: Node3D = null
	var nearest := INF
	for p: Node3D in _standing_players():
		var pr: float = p.radius
		if _in_line(p.global_position, pr):
			var along := (p.global_position - global_position).dot(_dir)
			if along < nearest:
				nearest = along
				victim = p
	if victim:
		var result: String = victim.take_hit(tongue_damage, -_dir * tongue_pull, self, true)
		if result == "parried":
			_sever()


## A parried lash is cut off: the toad is hurt, stunned, and can only leap from now on.
func _sever() -> void:
	has_tongue = false
	take_hit(sever_damage, _dir * 3.0)
	if state != S.DEAD:
		_enter(S.STAGGER)
		_stagger_for = sever_stagger


func take_hit(damage: float, push: Vector3) -> void:
	if state == S.DEAD:
		return
	hp -= damage
	_flash = 0.12
	if hp <= 0.0:
		_die()
		return
	if state == S.LEAP or state == S.SEALED:
		return   # airborne or pinned: no knockback, no interruption
	var k := 0.5 if big else 1.0
	velocity.x = push.x * k
	velocity.z = push.z * k
	if state == S.RECOVER or damage < poise:
		return
	_enter(S.STAGGER)
	_stagger_for = stagger_time


func _die() -> void:
	state = S.DEAD
	remove_from_group("enemies")
	died.emit(self)
	_death_visual()


# ---------------- Presentation (host and clients) ----------------

func _present(delta: float) -> void:
	_flash = maxf(0.0, _flash - delta)
	_throat.visible = has_tongue
	_pose(delta)
	_sync_telegraphs()


## Silhouette and colour per state, eased toward each frame.
func _pose(delta: float) -> void:
	var s := Vector3.ONE
	var tilt := 0.0
	var throat := 1.0
	var gold := 0.0
	var pale := 0.0
	var jitter := 0.0
	match state:
		S.CROUCH:
			s = Vector3(1.12, 0.68, 1.12)   # compressed and trembling, not flat
			jitter = 0.06
		S.LEAP:
			s = Vector3(0.85, 1.25, 0.85)
		S.TONGUE_WIND:
			gold = clampf(_t / tongue_windup, 0.0, 1.0)
			tilt = 0.6
			throat = lerpf(1.0, 2.4, gold)
		S.TONGUE_LASH:
			tilt = -0.15
			throat = 0.7
		S.RECOVER:
			s = Vector3(1.35, 0.38, 1.35)
			pale = 0.7
		S.STAGGER:
			jitter = 0.08
			pale = 0.3
		S.DEAD:
			pale = 0.8
	var sealed := state == S.SEALED
	var k := 1.0 - exp(-18.0 * delta)
	_vis.scale = _vis.scale.lerp(s, k)
	_vis.rotation.x = lerpf(_vis.rotation.x, tilt, k)
	_throat.scale = Vector3.ONE * lerpf(_throat.scale.x, throat, k)
	_vis.position = Vector3(_jitter.randf_range(-jitter, jitter), 0.0, _jitter.randf_range(-jitter, jitter))
	_mat.albedo_color = FLASH if _flash > 0.0 else (_base_color.lerp(SEALED_TINT, 0.65) if sealed else _base_color.lerp(PALE, pale))
	_throat_mat.albedo_color = THROAT.lerp(Fx.PARRYABLE, gold)


## Warning markers exist exactly while their state lasts, so a client that knows
## only the state draws the same markers as the host.
func _sync_telegraphs() -> void:
	var parent := get_parent()
	var yaw := atan2(-_dir.x, -_dir.z)
	var mid := global_position + _dir * (tongue_length * 0.5)

	if state == S.CROUCH or state == S.LEAP:
		if not is_instance_valid(_ring):
			_ring = Fx.ground_ring(parent, _target, leap_radius, Fx.UNBLOCKABLE)
		_ring.global_position = Vector3(_target.x, 0.05, _target.z)
	elif is_instance_valid(_ring):
		_ring.queue_free()
		_ring = null

	if state == S.TONGUE_WIND:
		if not is_instance_valid(_line):
			_line = MeshInstance3D.new()
			var bm := BoxMesh.new()
			bm.size = Vector3(tongue_width, 0.04, tongue_length)
			_line.mesh = bm
			_line_mat = Fx.mat(Color(Fx.PARRYABLE, 0.3), true)
			_line.material_override = _line_mat
			_line.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			parent.add_child(_line)
		var f := clampf(_t / tongue_windup, 0.0, 1.0)
		_line_mat.albedo_color.a = lerpf(0.3, 0.85, f)
		_line.scale.x = 1.0 + 0.3 * sin(_t * 30.0) * f   # pulses harder as it nears
		_line.global_position = Vector3(mid.x, 0.06, mid.z)
		_line.rotation.y = yaw
	elif is_instance_valid(_line):
		_line.queue_free()
		_line = null

	if state == S.TONGUE_LASH:
		if not is_instance_valid(_lash):
			_lash = MeshInstance3D.new()
			var bm := BoxMesh.new()
			bm.size = Vector3(0.28, 0.28, tongue_length)
			_lash.mesh = bm
			_lash.material_override = Fx.mat(Color(0.9, 0.42, 0.48))
			parent.add_child(_lash)
		_lash.global_position = Vector3(mid.x, global_position.y + radius * 0.6, mid.z)
		_lash.rotation.y = yaw
	elif is_instance_valid(_lash):
		_lash.queue_free()
		_lash = null


func _clear_telegraphs() -> void:
	for n: Node in [_ring, _line, _lash]:
		if is_instance_valid(n):
			n.queue_free()
	_ring = null
	_line = null
	_lash = null


func _death_visual() -> void:
	_clear_telegraphs()
	collision_layer = 0
	collision_mask = 1
	var tw := create_tween()
	tw.tween_property(self, "scale", Vector3.ONE * 0.05, 0.35)
	tw.tween_callback(queue_free)


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
