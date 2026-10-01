extends "res://kits/kit.gd"
## Glaive: holding ground. Wide committed swings, a thrust or a sweep on the
## heavy button, and a block that parries when pressed just before impact.

# ---------------- Tuning ----------------
const LIGHT_COMBO := [
	{"windup": 0.10, "recovery": 0.24, "damage": 10.0, "knockback": 4.0, "arc": 130.0, "range": 2.7, "lunge": 3.0},
	{"windup": 0.09, "recovery": 0.24, "damage": 10.0, "knockback": 4.0, "arc": 130.0, "range": 2.7, "lunge": 3.0},
	{"windup": 0.16, "recovery": 0.40, "damage": 20.0, "knockback": 10.0, "arc": 170.0, "range": 3.0, "lunge": 5.0},
]
const THRUST := {"windup": 0.20, "recovery": 0.40, "damage": 26.0, "knockback": 8.0, "range": 5.0, "width": 1.2, "lunge": 9.0, "cost": 30.0}
const SWEEP := {"windup": 0.50, "recovery": 0.45, "damage": 28.0, "knockback": 12.0, "arc": 360.0, "range": 3.3, "lunge": 0.0, "cost": 40.0}
const QI_PER_LIGHT_HIT := 8.0
const BLOCK_MOVE_FACTOR := 0.35
const BLOCK_TURN_RATE := 4.0
const BLOCK_ARC := 120.0
const BLOCK_QI_PER_DAMAGE := 2.5
const PARRY_WINDOW := 0.22
const GUARD_BREAK_TIME := 0.6
const SWING_TIME := 0.08
const REST_ANGLE := 0.9
# ----------------------------------------

enum M { NONE, LIGHT, HEAVY, BLOCK }


func _init() -> void:
	special_is_held = true
var move := M.NONE
var _t := 0.0
var _winding := false
var _deciding := false
var _atk: Dictionary = {}
var _combo := 0
var _from := 0.0
var _to := 0.0
var _parry_t := 0.0
var _pivot: Node3D


func stats() -> Dictionary:
	return {"hp": 100.0, "speed": 7.0, "dodge_cooldown": 0.35, "qi_regen": 6.0}


func build(root: Node3D) -> void:
	_pivot = Node3D.new()
	_pivot.position.y = 1.0
	root.add_child(_pivot)
	_pivot.add_child(p.box(Vector3(0.06, 0.06, 2.4), Vector3(0, 0, -0.8), Color(0.35, 0.22, 0.12)))
	_pivot.add_child(p.box(Vector3(0.05, 0.32, 0.7), Vector3(0, 0.06, -2.2), Color(0.78, 0.8, 0.82)))
	p.pose = Vector3(REST_ANGLE, 0.0, 0.0)


func pre_tick(delta: float) -> void:
	_parry_t = maxf(0.0, _parry_t - delta)
	if p.intent.block:
		_parry_t = PARRY_WINDOW


func neutral() -> bool:
	if p.intent.block_held:
		_enter_block()
		return true
	match p.buffer:
		"light":
			p.take_buffer()
			_start(LIGHT_COMBO[0], 0)
			return true
		"heavy":
			p.take_buffer()
			_start(THRUST, -1)
			return true
	return false


func _enter_block() -> void:
	move = M.BLOCK
	p.begin_action()
	var e: Node3D = p.nearest_enemy_within(8.0)
	if e:
		p.face(p.flat_to(e))


func _start(spec: Dictionary, combo_index: int) -> void:
	var cost: float = spec.get("cost", 0.0)
	if cost > p.qi:
		p.deny_qi()
		return
	move = M.LIGHT if combo_index >= 0 else M.HEAVY
	p.begin_action()
	_atk = spec
	_combo = combo_index
	_winding = true
	_deciding = combo_index < 0
	_t = 0.0
	var reach: float = spec["range"]
	p.face(p.attack_dir(reach))
	_set_swing(spec, combo_index)


func _set_swing(spec: Dictionary, combo_index: int) -> void:
	if spec.has("width"):
		_from = 0.0
		_to = 0.0
		return
	var arc: float = spec["arc"]
	if arc >= 360.0:
		_from = PI * 0.9
		_to = _from - TAU
	else:
		var side := 1.0 if combo_index % 2 == 0 else -1.0
		_from = side * deg_to_rad(arc) * 0.5
		_to = -_from


func tick(delta: float) -> bool:
	var k := 1.0 - exp(-25.0 * delta)
	if move == M.BLOCK:
		p.move_input(delta, p.speed * BLOCK_MOVE_FACTOR, BLOCK_TURN_RATE)
		p.pose.x = lerp_angle(p.pose.x, PI * 0.5, k)
		p.pose.y = lerpf(p.pose.y, -0.5, k)
		if p.buffer == "dodge" and p.can_dodge():
			p.take_buffer()
			p.start_dodge()
			return true
		return p.intent.block_held

	_t += delta
	p.friction(delta)
	if _winding:
		var thrust_windup: float = THRUST["windup"]
		if _deciding and _t >= thrust_windup:
			_deciding = false
			if p.intent.heavy_held:
				var sweep_cost: float = SWEEP["cost"]
				if p.qi >= sweep_cost:
					_atk = SWEEP
					_set_swing(SWEEP, -1)
				else:
					p.deny_qi()   # can't afford the sweep: the thrust fires instead
		if _atk.has("width") or _deciding:
			p.pose.x = lerp_angle(p.pose.x, 0.0, k)
			p.pose.y = lerpf(p.pose.y, 0.6, k)   # draw back
		else:
			p.pose.x = lerp_angle(p.pose.x, _from, k)
			p.pose.y = lerpf(p.pose.y, 0.0, k)
		var windup: float = _atk["windup"]
		if not _deciding and _t >= windup:
			_winding = false
			_t = 0.0
			_strike()
		return true

	var swing := SWING_TIME * (2.0 if _atk == SWEEP else 1.0)
	if _atk.has("width"):
		if _t > swing:
			p.pose.y = lerpf(p.pose.y, 0.0, 1.0 - exp(-8.0 * delta))
	elif _t <= swing:
		p.pose.x = lerpf(_from, _to, _t / swing)
	else:
		p.pose.x = lerp_angle(wrapf(p.pose.x, -PI, PI), REST_ANGLE, 1.0 - exp(-8.0 * delta))

	var recovery: float = _atk["recovery"]
	if _t > swing:
		if p.buffer == "dodge" and p.can_dodge():
			p.take_buffer()
			p.start_dodge()
			return true
		if p.intent.block_held:
			_enter_block()
			return true
	if _t >= recovery * 0.5 and p.buffer == "light" and _combo >= 0 and _combo < LIGHT_COMBO.size() - 1:
		p.take_buffer()
		_start(LIGHT_COMBO[_combo + 1], _combo + 1)
		return true
	return _t < recovery


func _strike() -> void:
	var lunge: float = _atk["lunge"]
	p.lunge(lunge)
	var cost: float = _atk.get("cost", 0.0)
	p.spend_qi(cost)
	var reach: float = _atk["range"]
	var damage: float = _atk["damage"]
	var knock: float = _atk["knockback"]
	var hits := 0
	if _atk.has("width"):
		var width: float = _atk["width"]
		p.fx("line", [p.global_position, p.rotation.y, reach, width, Color(0.95, 0.92, 0.8, 0.5)])
		p.pose.y = -1.2
		hits = p.hit_line(reach, width, damage, knock, true).size()
		p.stats["thrusts"] += 1
	else:
		var arc: float = _atk["arc"]
		p.fx("arc", [p.global_position, p.rotation.y, arc, reach, Color(0.95, 0.92, 0.8, 0.45)])
		hits = p.hit_arc(reach, arc, damage, knock)
		if _combo >= 0:
			p.stats["light_hits"] += hits
			p.add_qi(mini(hits, 2) * QI_PER_LIGHT_HIT)
		else:
			p.stats["sweeps"] += 1
	if hits > 0:
		p.hitstop(p.HITSTOP)


func intercept(damage: float, push: Vector3, source: Node3D, blockable: bool) -> String:
	if move != M.BLOCK or not p.in_action() or not blockable or source == null or not p.covers(source, BLOCK_ARC):
		return ""
	if _parry_t > 0.0:
		_parry_t = 0.0
		p.stats["parries"] += 1
		p.fx("ring", [p.global_position, 1.0, Color(1, 1, 0.9, 0.9)])
		p.hitstop(0.12)
		return "parried"
	var cost := damage * BLOCK_QI_PER_DAMAGE
	if p.qi >= cost:
		p.spend_qi(cost)
		p.stats["blocks"] += 1
		p.velocity.x = push.x * 0.4
		p.velocity.z = push.z * 0.4
		return "blocked"
	# Guard break: the block collapses; the hit lands at half strength with a longer stagger.
	p.stats["guard_breaks"] += 1
	p.spend_qi(p.qi)
	p.fx("ring", [p.global_position, 1.0, Color(0.8, 0.1, 0.08, 0.9)])
	p.land_hit(damage * 0.5, push, GUARD_BREAK_TIME)
	return "hit"


func show(delta: float) -> void:
	if not p.in_action() and p.authority:
		var k := 1.0 - exp(-12.0 * delta)
		p.pose.x = lerp_angle(p.pose.x, REST_ANGLE, k)
		p.pose.y = lerpf(p.pose.y, 0.0, k)
	_pivot.rotation.y = p.pose.x
	_pivot.position.z = p.pose.y
