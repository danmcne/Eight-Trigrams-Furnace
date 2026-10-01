extends "res://boss.gd"
## The Golden Horned King: the brawler. A wide sword sweep with a GOLD warning
## (parry it and his posture suffers badly) and a leaping slam with a RED ring.

# ---------------- Tuning ----------------
const SWORD_WINDUP := 0.75
const SWORD_REACH := 4.2
const SWORD_ARC := 150.0
const SWORD_DAMAGE := 16.0
const SWORD_KNOCKBACK := 8.0
const PARRY_POISE := 50.0
const SLAM_CROUCH := 0.85
const SLAM_AIR := 0.6
const SLAM_RADIUS := 3.2
const SLAM_DAMAGE := 22.0
const SLAM_RANGE := 11.0
const SWORD_RECOVERY := 0.6
const SLAM_RECOVERY := 1.1
# ----------------------------------------

const SWORD_WIND := 10
const SWORD_HIT := 11
const SLAM_CROUCH_S := 12
const SLAM_AIR_S := 13

var _sword: Node3D


func _init() -> void:
	kind = "golden"
	boss_name = "Golden Horned King"
	radius = 1.0
	max_hp = 420.0
	speed = 4.5
	_base_color = Color(0.85, 0.66, 0.2)


func _build_body() -> void:
	var cm := CapsuleMesh.new()
	cm.radius = radius
	cm.height = radius * 3.0
	_part(cm, Vector3(0, radius * 1.5, 0), _mat)
	_horns(radius * 3.05, Color(0.95, 0.85, 0.55))
	_sword = Node3D.new()
	_sword.position = Vector3(radius * 0.9, 1.4, 0)
	_vis.add_child(_sword)
	var bm := BoxMesh.new()
	bm.size = Vector3(0.1, 0.25, 2.4)
	var blade := MeshInstance3D.new()
	blade.mesh = bm
	blade.material_override = Fx.mat(Color(0.8, 0.82, 0.86))
	blade.position = Vector3(0, 0, -1.2)
	_sword.add_child(blade)


func _decide(delta: float, to_p: Vector3, dist: float) -> void:
	_face(to_p, delta)
	var clear := _clear_to(player)
	if clear and _cd <= 0.0:
		if dist <= SWORD_REACH and rng.randf() < 0.65:
			_enter(SWORD_WIND)
			_dir = to_p / dist
			_face(_dir)
			return
		if dist <= SLAM_RANGE:
			_enter(SLAM_CROUCH_S)
			_target = player.global_position
			return
	if dist > SWORD_REACH * 0.8:
		_walk(delta, player.global_position)
	else:
		_friction(delta)


func _act(delta: float, _to_p: Vector3, _dist: float) -> void:
	_t += delta
	match state:
		SWORD_WIND:
			_friction(delta)
			if _t >= _w(SWORD_WINDUP):
				_enter(SWORD_HIT)
				_swing()
		SWORD_HIT:
			_friction(delta)
			if _t >= 0.2:
				_recover(SWORD_RECOVERY)
		SLAM_CROUCH_S:
			_friction(delta)
			if _t >= _w(SLAM_CROUCH):
				_enter(SLAM_AIR_S)
				var d := _target - global_position
				d.y = 0.0
				velocity.x = d.x / SLAM_AIR
				velocity.z = d.z / SLAM_AIR
				velocity.y = 0.5 * GRAVITY * SLAM_AIR
				collision_mask = 1 | 4
		SLAM_AIR_S:
			if _t > 0.1 and is_on_floor():
				_land()


func _swing() -> void:
	Fx.play(get_parent(), "arc", [global_position, atan2(-_dir.x, -_dir.z), SWORD_ARC, SWORD_REACH, Color(1.0, 0.85, 0.4, 0.6)])
	for p: Node3D in _standing_players():
		var d := p.global_position - global_position
		d.y = 0.0
		var pr: float = p.radius
		if d.length() > SWORD_REACH + pr:
			continue
		if d.length() > 0.3 and _dir.angle_to(d.normalized()) > deg_to_rad(SWORD_ARC) * 0.5:
			continue
		var result: String = p.take_hit(SWORD_DAMAGE, d.normalized() * SWORD_KNOCKBACK, self, true)
		if result == "parried":
			_add_poise(PARRY_POISE)


func _land() -> void:
	collision_mask = 1 | 2 | 4
	velocity = Vector3.ZERO
	Fx.play(get_parent(), "ring", [global_position, SLAM_RADIUS, Color(0.9, 0.3, 0.1, 0.9)])
	for p: Node3D in _standing_players():
		var d := p.global_position - global_position
		d.y = 0.0
		var pr: float = p.radius
		if d.length() <= SLAM_RADIUS + pr:
			p.take_hit(SLAM_DAMAGE, (d.normalized() if d.length() > 0.01 else Vector3.BACK) * 9.0, self, false)
	_recover(SLAM_RECOVERY)


func _on_interrupted() -> void:
	collision_mask = 1 | 2 | 4


func threat_to(p: Vector3, pr: float) -> Dictionary:
	if state == SWORD_WIND:
		var d := p - global_position
		d.y = 0.0
		if d.length() <= SWORD_REACH + pr + 0.3 and (d.length() < 0.3 or _dir.angle_to(d.normalized()) <= deg_to_rad(SWORD_ARC) * 0.5):
			return {"kind": "gold", "eta": _w(SWORD_WINDUP) - _t, "from": global_position}
	elif state == SLAM_CROUCH_S or state == SLAM_AIR_S:
		var d := p - _target
		d.y = 0.0
		if d.length() <= SLAM_RADIUS + pr + 0.5:
			var eta := (_w(SLAM_CROUCH) - _t + SLAM_AIR) if state == SLAM_CROUCH_S else (SLAM_AIR - _t)
			return {"kind": "red", "eta": eta, "from": _target}
	return {}


func _pose(delta: float) -> void:
	var k := 1.0 - exp(-14.0 * delta)
	var swing := 0.0
	var lift := 0.0
	match state:
		SWORD_WIND:
			swing = 1.4
		SWORD_HIT:
			swing = -1.4
		SLAM_CROUCH_S:
			lift = 1.2
	_sword.rotation.y = lerp_angle(_sword.rotation.y, swing, k)
	_sword.rotation.x = lerpf(_sword.rotation.x, lift, k)


func _telegraphs() -> void:
	var yaw := atan2(-_dir.x, -_dir.z)
	var w: MeshInstance3D = _marker("sword", state == SWORD_WIND, func() -> Node3D: return _wedge(SWORD_ARC, SWORD_REACH, Color(Fx.PARRYABLE, 0.35)))
	if w:
		w.global_position = Vector3(global_position.x, 0.07, global_position.z)
		w.rotation.y = yaw
		var m: StandardMaterial3D = w.material_override
		m.albedo_color.a = lerpf(0.2, 0.6, clampf(_t / _w(SWORD_WINDUP), 0.0, 1.0))
	var r: Node3D = _marker("slam", state == SLAM_CROUCH_S or state == SLAM_AIR_S, func() -> Node3D: return Fx.ground_ring(get_parent(), _target, SLAM_RADIUS, Fx.UNBLOCKABLE))
	if r:
		r.global_position = Vector3(_target.x, 0.05, _target.z)
