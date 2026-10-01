extends "res://boss.gd"
## The Silver Horned King: the trickster. He keeps his distance, fans fire
## along the ground (RED), and calls one player's name (PURPLE: don't act).
## A player who answers during the call (attacks, uses the special or the
## gourd; moving and dodging are fine) is drawn into his jade vase. A call left
## unanswered leaves him flustered and open. Striking him hard enough while
## someone is inside shakes them loose.

# ---------------- Tuning (vars, so a lesser caller can reuse this script) ----------------
var CALL_TIME := 1.6
var CALL_GRACE := 0.3           # reaction time: acting this early in a call (or an attack
                                  # already queued when it began) isn't answering
var CALL_COOLDOWN := 7.0
var CALL_COOLDOWN_ENRAGED := 4.5
var TRAP_TIME := 3.0
var TRAP_DPS := 7.0
var SHAKE_LOOSE := 40.0         # damage he must take to release whoever is inside
var FLUSTERED := 1.6            # recovery after an unanswered call
var FAN_WINDUP := 0.8
var FAN_BURN := 0.35
var FAN_REACH := 7.0
var FAN_ARC := 60.0
var FAN_DAMAGE := 14.0
var FAN_RECOVERY := 0.8
var KEEP_MIN := 5.0             # backs away inside this distance
var KEEP_MAX := 8.5             # closes in beyond it
# ----------------------------------------

const CALL := 10
const FAN_WIND := 11
const FAN_BURN_S := 12

var _call_cd := 3.0
var _called: Node3D
var _called_acts := 0
var _trapped := []
var _shake := 0.0
var _vase: MeshInstance3D
var _fan: MeshInstance3D
var fans := true                  # the Clever Devil calls but has no fire fan


func _init() -> void:
	kind = "silver"
	boss_name = "Silver Horned King"
	radius = 0.8
	max_hp = 320.0
	speed = 5.0
	_base_color = Color(0.78, 0.8, 0.86)


func _build_body() -> void:
	var cm := CapsuleMesh.new()
	cm.radius = radius
	cm.height = radius * 3.0
	_part(cm, Vector3(0, radius * 1.5, 0), _mat)
	_horns(radius * 3.05, Color(0.85, 0.88, 0.95))
	var vm := CylinderMesh.new()
	vm.top_radius = 0.12
	vm.bottom_radius = 0.26
	vm.height = 0.55
	_vase = _part(vm, Vector3(-radius * 0.95, 1.25, -0.2), Fx.mat(Color(0.75, 0.88, 0.78)))
	_fan = MeshInstance3D.new()
	_fan.mesh = Fx.arc_mesh(120.0, 0.8, 8)
	var fm := Fx.mat(Color(0.6, 0.15, 0.1))
	fm.cull_mode = BaseMaterial3D.CULL_DISABLED
	_fan.material_override = fm
	_fan.position = Vector3(radius * 0.95, 1.3, -0.3)
	_fan.rotation.x = -1.0
	_vis.add_child(_fan)


func _simulate(delta: float) -> void:
	_call_cd = maxf(0.0, _call_cd - delta)
	# Whoever is inside the vase travels with him.
	_trapped = _trapped.filter(func(p) -> bool: return is_instance_valid(p) and p.is_trapped())
	super._simulate(delta)


func _decide(delta: float, to_p: Vector3, dist: float) -> void:
	_face(to_p, delta)
	if _call_cd <= 0.0:
		var choices := _visible_players()
		if not choices.is_empty():
			_called = choices[rng.randi() % choices.size()]
			_called_acts = _called.acts
			aux = _called.peer_id
			_dir = _flat(_called.global_position - global_position).normalized()
			_enter(CALL)
			_call_cd = CALL_COOLDOWN_ENRAGED if enraged else CALL_COOLDOWN
			return
	if fans and _cd <= 0.0 and dist <= FAN_REACH and _clear_to(player):
		_dir = to_p / dist
		_face(_dir)
		_enter(FAN_WIND)
		return
	if dist < KEEP_MIN:
		_walk(delta, player.global_position, true)
	elif dist > KEEP_MAX:
		_walk(delta, player.global_position)
	else:
		_friction(delta)


func _act(delta: float, _to_p: Vector3, _dist: float) -> void:
	_t += delta
	_friction(delta)
	match state:
		CALL:
			if not is_instance_valid(_called) or not _standing(_called):
				_end_call()
				_recover(0.5)
				return
			_face(_flat(_called.global_position - global_position), delta)
			_dir = _flat(_called.global_position - global_position).normalized()
			if _t < CALL_GRACE:
				_called_acts = _called.acts
			elif _called.acts != _called_acts:
				# The called player answered: into the vase.
				Fx.play(get_parent(), "stream", [_called.global_position + Vector3(0, 1.0, 0), global_position + Vector3(0, 1.3, 0), Color(Fx.HOLD, 0.9)])
				_called.trap(TRAP_TIME, TRAP_DPS, self)
				_trapped.append(_called)
				_shake = 0.0
				_end_call()
				_recover(0.5)
			elif _t >= _w(CALL_TIME):
				# Nobody answered: he is left flustered and open.
				Fx.play(get_parent(), "ring", [global_position, radius * 1.5, Color(Fx.HOLD, 0.8)])
				_end_call()
				_recover(FLUSTERED)
		FAN_WIND:
			if _t >= _w(FAN_WINDUP):
				_enter(FAN_BURN_S)
				_burn()
		FAN_BURN_S:
			if _t >= FAN_BURN:
				_recover(FAN_RECOVERY)


func _end_call() -> void:
	_called = null
	aux = 0


func _burn() -> void:
	Fx.play(get_parent(), "arc", [global_position, atan2(-_dir.x, -_dir.z), FAN_ARC, FAN_REACH, Color(Fx.FIRE, 0.7)])
	for p: Node3D in _standing_players():
		var d := _flat(p.global_position - global_position)
		var pr: float = p.radius
		if d.length() <= FAN_REACH + pr and (d.length() < 0.3 or _dir.angle_to(d.normalized()) <= deg_to_rad(FAN_ARC) * 0.5):
			p.take_hit(FAN_DAMAGE, d.normalized() * 5.0, self, false)


func _on_damaged(damage: float) -> void:
	if _trapped.is_empty():
		return
	_shake += damage
	if _shake >= SHAKE_LOOSE:
		for p in _trapped:
			if is_instance_valid(p):
				p.release()
		_trapped.clear()


func _on_interrupted() -> void:
	_end_call()


func _die() -> void:
	for p in _trapped:
		if is_instance_valid(p):
			p.release()
	_trapped.clear()
	super._die()


func _flat(v: Vector3) -> Vector3:
	v.y = 0.0
	return v


func threat_to(p: Vector3, pr: float) -> Dictionary:
	if state == CALL:
		return {"kind": "hold", "eta": _w(CALL_TIME) - _t, "target": aux}
	if state == FAN_WIND:
		var d := _flat(p - global_position)
		if d.length() <= FAN_REACH + pr + 0.3 and (d.length() < 0.3 or _dir.angle_to(d.normalized()) <= deg_to_rad(FAN_ARC) * 0.5):
			return {"kind": "red", "eta": _w(FAN_WINDUP) - _t, "from": global_position}
	return {}


func _pose(delta: float) -> void:
	var k := 1.0 - exp(-14.0 * delta)
	var lift := 0.0
	if state == CALL:
		lift = 0.9 + 0.1 * sin(_t * 20.0)   # the vase raised, trembling
	_vase.position.y = lerpf(_vase.position.y, 1.25 + lift, k)
	_fan.rotation.y = lerp_angle(_fan.rotation.y, 0.9 if state == FAN_WIND else 0.0, k)


func _telegraphs() -> void:
	var yaw := atan2(-_dir.x, -_dir.z)
	var w: MeshInstance3D = _marker("fan", state == FAN_WIND, func() -> Node3D: return _wedge(FAN_ARC, FAN_REACH, Color(Fx.UNBLOCKABLE, 0.3)))
	if w:
		w.global_position = Vector3(global_position.x, 0.07, global_position.z)
		w.rotation.y = yaw
		var m: StandardMaterial3D = w.material_override
		m.albedo_color.a = lerpf(0.2, 0.6, clampf(_t / _w(FAN_WINDUP), 0.0, 1.0))
	# The call: a purple beam to the called player, and a ring under them.
	var target: Node3D = null
	if state == CALL and aux != 0:
		for p in get_tree().get_nodes_in_group("players"):
			if p.peer_id == aux:
				target = p
	var beam: MeshInstance3D = _marker("beam", target != null, func() -> Node3D:
		var mi := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = Vector3(0.18, 0.18, 1.0)
		mi.mesh = bm
		mi.material_override = Fx.mat(Color(Fx.HOLD, 0.8), true)
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		get_parent().add_child(mi)
		return mi)
	var ring: Node3D = _marker("called", target != null, func() -> Node3D: return Fx.ground_ring(get_parent(), target.global_position, 1.1, Fx.HOLD))
	if target:
		var a := global_position + Vector3(0, 1.6, 0)
		var b := target.global_position + Vector3(0, 1.2, 0)
		beam.global_position = (a + b) * 0.5
		beam.scale.z = maxf(a.distance_to(b), 0.1)
		beam.look_at(b, Vector3.UP)
		ring.global_position = Vector3(target.global_position.x, 0.05, target.global_position.z)
		ring.scale = Vector3.ONE * (1.0 + 0.15 * sin(_t * 12.0))
