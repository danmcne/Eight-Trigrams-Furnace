extends "res://boss.gd"
## Wily Worm, the other little demon: quick and darting. He circles, then
## stabs along a line (GOLD: parry it and he loses his footing badly).

# ---------------- Tuning ----------------
const DART_WINDUP := 0.55
const DART_TIME := 0.22
const DART_LENGTH := 6.0
const DART_WIDTH := 1.0
const DART_DAMAGE := 10.0
const PARRY_POISE := 60.0
const DART_RECOVERY := 0.7
const CIRCLE_DIST := 4.5
# ----------------------------------------

const DART_WIND := 10
const DART := 11

var _hit_this_dart := false
var _spear: MeshInstance3D


func _init() -> void:
	kind = "wily"
	boss_name = "Wily Worm"
	radius = 0.55
	max_hp = 110.0
	speed = 6.5
	_base_color = Color(0.62, 0.5, 0.7)


func _build_body() -> void:
	var cm := CapsuleMesh.new()
	cm.radius = radius
	cm.height = radius * 3.0
	_part(cm, Vector3(0, radius * 1.5, 0), _mat)
	_horns(radius * 3.05, Color(0.85, 0.85, 0.8))
	var bm := BoxMesh.new()
	bm.size = Vector3(0.06, 0.06, 1.6)
	_spear = _part(bm, Vector3(radius + 0.05, 0.9, -0.6), Fx.mat(Color(0.35, 0.25, 0.15)))


func _decide(delta: float, to_p: Vector3, dist: float) -> void:
	_face(to_p, delta)
	if _cd <= 0.0 and dist <= DART_LENGTH - 0.5 and _clear_to(player):
		_dir = to_p / dist
		_face(_dir)
		_enter(DART_WIND)
		return
	# Circle the target at a little distance.
	var side := Vector3(-to_p.z, 0.0, to_p.x).normalized()
	var want := player.global_position - to_p.normalized() * CIRCLE_DIST + side * 2.0
	_walk(delta, want)


func _act(delta: float, _to_p: Vector3, _dist: float) -> void:
	_t += delta
	match state:
		DART_WIND:
			_friction(delta)
			if _t >= _w(DART_WINDUP):
				_enter(DART)
				_hit_this_dart = false
				collision_mask = 1 | 4   # darts past players
		DART:
			var v := _dir * (DART_LENGTH / DART_TIME)
			velocity.x = v.x
			velocity.z = v.z
			if not _hit_this_dart:
				for p: Node3D in _standing_players():
					var d := p.global_position - global_position
					d.y = 0.0
					var pr: float = p.radius
					if d.length() <= radius + pr + 0.4:
						_hit_this_dart = true
						var result: String = p.take_hit(DART_DAMAGE, _dir * 6.0, self, true)
						if result == "parried":
							_add_poise(PARRY_POISE)
							if state == BROKEN:
								collision_mask = 1 | 2 | 4
								return
			if _t >= DART_TIME:
				collision_mask = 1 | 2 | 4
				velocity = Vector3.ZERO
				_recover(DART_RECOVERY)


func _on_interrupted() -> void:
	collision_mask = 1 | 2 | 4


func threat_to(p: Vector3, pr: float) -> Dictionary:
	if state == DART_WIND:
		var rel := p - global_position
		rel.y = 0.0
		var along := rel.dot(_dir)
		if along > -0.5 and along < DART_LENGTH + pr and (rel - _dir * along).length() < DART_WIDTH * 0.5 + pr + 0.3:
			return {"kind": "gold", "eta": _w(DART_WINDUP) - _t, "from": global_position}
	return {}


func _pose(delta: float) -> void:
	_spear.position.z = lerpf(_spear.position.z, 0.2 if state == DART_WIND else -0.6, 1.0 - exp(-14.0 * delta))


func _telegraphs() -> void:
	var line: MeshInstance3D = _marker("dart", state == DART_WIND, func() -> Node3D:
		var mi := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = Vector3(DART_WIDTH, 0.04, DART_LENGTH)
		mi.mesh = bm
		mi.material_override = Fx.mat(Color(Fx.PARRYABLE, 0.35), true)
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		get_parent().add_child(mi)
		return mi)
	if line:
		var mid := global_position + _dir * (DART_LENGTH * 0.5)
		line.global_position = Vector3(mid.x, 0.06, mid.z)
		line.rotation.y = atan2(-_dir.x, -_dir.z)
		var m: StandardMaterial3D = line.material_override
		m.albedo_color.a = lerpf(0.25, 0.7, clampf(_t / _w(DART_WINDUP), 0.0, 1.0))
