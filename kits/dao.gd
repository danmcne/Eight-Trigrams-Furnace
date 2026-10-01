extends "res://kits/kit.gd"
## Dao: staying in motion. A very fast combo that a dodge can cut off at any
## instant; a dash that passes through enemies; a counter stance that turns a
## well-timed hit, even an unblockable one, into a strike from behind; and
## perfect dodges that pay qi and quicken the blade.

# ---------------- Tuning ----------------
const COMBO := [
	{"windup": 0.06, "recovery": 0.14, "damage": 7.0, "knockback": 2.5},
	{"windup": 0.06, "recovery": 0.14, "damage": 7.0, "knockback": 2.5},
	{"windup": 0.06, "recovery": 0.14, "damage": 7.0, "knockback": 2.5},
	{"windup": 0.10, "recovery": 0.26, "damage": 13.0, "knockback": 7.0},
]
const ARC := 110.0
const REACH := 2.2
const LUNGE := 2.5
const QI_PER_HIT := 4.0
const DASH_COST := 25.0
const DASH_WINDUP := 0.08
const DASH_TIME := 0.18
const DASH_SPEED := 34.0          # about 6 m
const DASH_DAMAGE := 22.0
const DASH_WIDTH := 1.3
const DASH_RECOVERY := 0.3
const COUNTER_WINDOW := 0.35
const COUNTER_WHIFF := 0.35       # exposed afterwards if nothing came
const COUNTER_DAMAGE := 30.0
const COUNTER_QI := 15.0
const PERFECT_QI := 15.0
const FLOW_TIME := 2.0            # after a perfect dodge, the combo runs faster
const FLOW_SPEED := 0.6           # windups and recoveries scaled by this
# ----------------------------------------

enum M { NONE, COMBO, DASH, STANCE, COUNTER }
var move := M.NONE
var _t := 0.0
var _i := 0
var _fired := false
var _flow := 0.0
var _dashed := {}
var _blade: Node3D


func stats() -> Dictionary:
	return {"hp": 85.0, "speed": 8.5, "dodge_cooldown": 0.2, "qi_regen": 6.0, "radius": 0.4}


func build(root: Node3D) -> void:
	_blade = Node3D.new()
	_blade.position = Vector3(0, 1.0, 0)
	root.add_child(_blade)
	_blade.add_child(p.box(Vector3(0.06, 0.06, 0.3), Vector3(0.3, 0, -0.35), Color(0.2, 0.15, 0.1)))
	var edge: MeshInstance3D = p.box(Vector3(0.04, 0.16, 0.85), Vector3(0.3, 0.02, -0.9), Color(0.82, 0.84, 0.86))
	edge.rotation.x = 0.12   # a slight curve
	_blade.add_child(edge)
	# A red sash and a topknot: the lightly armoured duellist.
	var sash := MeshInstance3D.new()
	var tm := TorusMesh.new()
	tm.inner_radius = p.radius - 0.02
	tm.outer_radius = p.radius + 0.07
	sash.mesh = tm
	sash.material_override = p.mat(Color(0.75, 0.12, 0.1))
	sash.position.y = 0.95
	root.add_child(sash)
	root.add_child(p.box(Vector3(0.3, 0.06, 0.6), Vector3(0.25, 0.8, 0.3), Color(0.75, 0.12, 0.1)))   # sash tail
	var knot := MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = 0.13
	sm.height = 0.26
	knot.mesh = sm
	knot.material_override = p.mat(Color(0.1, 0.08, 0.07))
	knot.position = Vector3(0, 1.88, 0.05)
	root.add_child(knot)
	p.pose = Vector3(0.6, 0, 0)


func pre_tick(delta: float) -> void:
	_flow = maxf(0.0, _flow - delta)


func _scale() -> float:
	return FLOW_SPEED if _flow > 0.0 else 1.0


func neutral() -> bool:
	match p.buffer:
		"light":
			p.take_buffer()
			_combo(0)
			return true
		"heavy":
			p.take_buffer()
			if p.qi < DASH_COST:
				p.deny_qi()
				return false
			_begin(M.DASH)
			p.face(p.attack_dir(DASH_TIME * DASH_SPEED))
			return true
		"special":
			p.take_buffer()
			_begin(M.STANCE)
			return true
	return false


func _begin(m: M) -> void:
	move = m
	_t = 0.0
	_fired = false
	p.begin_action()


func _combo(i: int) -> void:
	_begin(M.COMBO)
	_i = i
	p.face(p.attack_dir(REACH))


func tick(delta: float) -> bool:
	_t += delta
	# A dodge cuts off anything except the dash itself, at any moment.
	if move != M.DASH and move != M.COUNTER and p.buffer == "dodge" and p.can_dodge():
		p.take_buffer()
		p.start_dodge()
		return true
	match move:
		M.COMBO:
			p.friction(delta)
			var spec: Dictionary = COMBO[_i]
			var windup: float = spec["windup"] * _scale()
			var recovery: float = spec["recovery"] * _scale()
			var side := 1.0 if _i % 2 == 0 else -1.0
			if not _fired:
				p.pose.x = lerpf(p.pose.x, side * 1.0, 1.0 - exp(-40.0 * delta))
				if _t >= windup:
					_fired = true
					_t = 0.0
					p.lunge(LUNGE)
					p.fx("arc", [p.global_position, p.rotation.y, ARC, REACH, Color(0.95, 0.92, 0.8, 0.4)])
					var hits: int = p.hit_arc(REACH, ARC, spec["damage"], spec["knockback"])
					p.stats["light_hits"] += hits
					p.add_qi(mini(hits, 2) * QI_PER_HIT)
					if hits > 0:
						p.hitstop(p.HITSTOP * 0.6)
				return true
			p.pose.x = lerpf(side, -side, clampf(_t / 0.06, 0.0, 1.0))
			if _t >= recovery * 0.4 and p.buffer == "light" and _i < COMBO.size() - 1:
				p.take_buffer()
				_combo(_i + 1)
				return true
			return _t < recovery
		M.DASH:
			if not _fired:
				p.friction(delta)
				p.pose.x = lerpf(p.pose.x, -1.4, 1.0 - exp(-30.0 * delta))
				if _t >= DASH_WINDUP:
					_fired = true
					_t = 0.0
					_dashed = {}
					p.spend_qi(DASH_COST)
					p.stats["dashes"] += 1
					p.pass_through(true)
					p.iframes = maxf(p.iframes, DASH_TIME + 0.05)
				return true
			if _t <= DASH_TIME:
				var f: Vector3 = p.forward()
				p.velocity.x = f.x * DASH_SPEED
				p.velocity.z = f.z * DASH_SPEED
				for e in p.enemies_within(DASH_WIDTH):
					if not _dashed.has(e):
						_dashed[e] = true
						e.take_hit(DASH_DAMAGE, p.flat_to(e).normalized() * 5.0)
				if _t + delta > DASH_TIME:
					p.pass_through(false)
					p.fx("line", [p.global_position - f * DASH_TIME * DASH_SPEED, p.rotation.y, DASH_TIME * DASH_SPEED, DASH_WIDTH * 2.0, Color(0.95, 0.92, 0.8, 0.4)])
				return true
			p.friction(delta * 2.0)
			return _t < DASH_TIME + DASH_RECOVERY
		M.STANCE:
			p.friction(delta)
			p.pose.x = lerpf(p.pose.x, 0.0, 1.0 - exp(-30.0 * delta))
			return _t < COUNTER_WINDOW + COUNTER_WHIFF
		M.COUNTER:
			p.friction(delta)
			p.pose.x = lerpf(-1.2, 1.2, clampf(_t / 0.08, 0.0, 1.0))
			return _t < 0.3
	return false


## In the stance's window, any hit (red or gold) is evaded: the dao reappears
## on the attacker's far side and strikes.
func intercept(_damage: float, _push: Vector3, source: Node3D, _blockable: bool) -> String:
	if move != M.STANCE or not p.in_action() or _t > COUNTER_WINDOW or source == null:
		return ""
	var d: Vector3 = p.flat_to(source)
	var dir: Vector3 = d.normalized() if d.length() > 0.01 else p.forward()
	var sr: float = source.radius
	# Reappear behind the attacker if there is room to stand there, else beside
	# it, else strike from where you are. Never inside a wall.
	var gap: float = sr + 0.9
	var side := Vector3(-dir.z, 0.0, dir.x)
	for way: Vector3 in [dir, side, -side]:
		if p.world_ray(source.global_position, way, gap + p.radius) >= gap + p.radius - 0.05:
			p.global_position = source.global_position + way * gap
			p.global_position.y = maxf(p.global_position.y, 0.05)
			break
	var to_source: Vector3 = p.flat_to(source)
	p.face(to_source.normalized() if to_source.length() > 0.01 else -dir)
	p.velocity = Vector3.ZERO
	source.take_hit(COUNTER_DAMAGE, dir * 6.0)
	source.stagger(0.8)
	p.add_qi(COUNTER_QI)
	p.iframes = maxf(p.iframes, 0.4)
	p.stats["counters"] += 1
	p.fx("ring", [p.global_position, 0.9, Color(0.95, 0.95, 1.0, 0.9)])
	p.hitstop(0.1)
	move = M.COUNTER
	_t = 0.0
	return "countered"


func on_perfect_dodge() -> void:
	p.add_qi(PERFECT_QI)
	_flow = FLOW_TIME
	p.stats["perfect_dodges"] += 1
	p.fx("ring", [p.global_position, 0.7, Color(0.7, 0.9, 1.0, 0.8)])


func show(delta: float) -> void:
	if not p.in_action() and p.authority:
		p.pose.x = lerpf(p.pose.x, 0.6, 1.0 - exp(-12.0 * delta))
	_blade.rotation.y = p.pose.x
