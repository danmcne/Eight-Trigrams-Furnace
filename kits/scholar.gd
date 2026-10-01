extends "res://kits/kit.gd"
## Scholar (fan): controlling the fight. Light fan cuts whose third stroke
## gusts enemies back; a talisman that seals a toad in place (tap heavy) or a
## gale that knocks back and interrupts everything in front (hold heavy); and a
## ward on the block button that heals whoever stands in it.

# ---------------- Tuning ----------------
const CUTS := [
	{"windup": 0.10, "recovery": 0.22, "damage": 8.0, "knockback": 3.0},
	{"windup": 0.09, "recovery": 0.22, "damage": 8.0, "knockback": 3.0},
	{"windup": 0.14, "recovery": 0.34, "damage": 10.0, "knockback": 12.0},   # the gust
]
const ARC := 110.0
const REACH := 2.4
const QI_PER_HIT := 5.0
const TALISMAN_WINDUP := 0.2      # also the tap/hold decision point
const TALISMAN_COST := 20.0
const TALISMAN_RANGE := 12.0
const TALISMAN_DAMAGE := 8.0
const SEAL_TIME := 2.5
const SEAL_TIME_BIG := 1.2
const GALE_WINDUP := 0.45
const GALE_COST := 35.0
const GALE_RANGE := 7.0
const GALE_ARC := 90.0
const GALE_DAMAGE := 6.0
const GALE_KNOCKBACK := 14.0
const GALE_STAGGER := 0.7
const HEAVY_RECOVERY := 0.3
const WARD_COST := 40.0
const WARD_WINDUP := 0.25
const WARD_RECOVERY := 0.2
const WARD_RADIUS := 3.0
const WARD_TIME := 6.0
const WARD_HEAL := 6.0            # health per second to each standing player inside
# ----------------------------------------

enum M { NONE, CUT, HEAVY, WARD }
var move := M.NONE
var _t := 0.0
var _i := 0
var _fired := false
var _deciding := false
var _gale := false
var _fan: Node3D
var _leaf: MeshInstance3D


func stats() -> Dictionary:
	return {"hp": 75.0, "speed": 7.0, "dodge_cooldown": 0.35, "qi_regen": 10.0}


func build(root: Node3D) -> void:
	root.add_child(p.cyl(Vector3(0, 1.88, 0), 0.5, 0.06, Color(0.15, 0.13, 0.12)))   # hat brim
	root.add_child(p.cyl(Vector3(0, 2.0, 0), 0.22, 0.22, Color(0.15, 0.13, 0.12)))
	_fan = Node3D.new()
	_fan.position = Vector3(0.62, 1.15, -0.25)
	root.add_child(_fan)
	_leaf = MeshInstance3D.new()
	_leaf.mesh = p.fan_mesh(0.75)
	var m: StandardMaterial3D = p.mat(Color(0.95, 0.9, 0.72))
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED   # a flat leaf has no useful normals
	_leaf.material_override = m
	_leaf.rotation.x = -1.1   # held open and tilted back, so its face shows from above
	_fan.add_child(_leaf)
	var ribs: MeshInstance3D = p.box(Vector3(0.05, 0.05, 0.05), Vector3.ZERO, Color(0.3, 0.2, 0.1))
	_fan.add_child(ribs)


func neutral() -> bool:
	match p.buffer:
		"light":
			p.take_buffer()
			_cut(0)
			return true
		"heavy":
			p.take_buffer()
			if p.qi < TALISMAN_COST:
				p.deny_qi()
				return false
			_begin(M.HEAVY)
			_deciding = true
			_gale = false
			p.face(p.attack_dir(TALISMAN_RANGE, 25.0))
			return true
		"special":
			p.take_buffer()
			if p.qi < WARD_COST:
				p.deny_qi()
				return false
			_begin(M.WARD)
			return true
	return false


func _begin(m: M) -> void:
	move = m
	_t = 0.0
	_fired = false
	p.begin_action()


func _cut(i: int) -> void:
	_begin(M.CUT)
	_i = i
	p.face(p.attack_dir(REACH))


func tick(delta: float) -> bool:
	_t += delta
	p.friction(delta)
	match move:
		M.CUT:
			var spec: Dictionary = CUTS[_i]
			var windup: float = spec["windup"]
			var side := 1.0 if _i % 2 == 0 else -1.0
			if not _fired:
				p.pose.x = lerpf(p.pose.x, side * 0.9, 1.0 - exp(-30.0 * delta))
				if _t >= windup:
					_fired = true
					_t = 0.0
					p.lunge(2.0)
					var gust := _i == CUTS.size() - 1
					p.fx("arc", [p.global_position, p.rotation.y, ARC, REACH + (1.5 if gust else 0.0), Color(0.85, 0.95, 0.9, 0.45)])
					var hits: int = p.hit_arc(REACH + (1.5 if gust else 0.0), ARC, spec["damage"], spec["knockback"])
					p.stats["light_hits"] += hits
					p.add_qi(mini(hits, 2) * QI_PER_HIT)
					if hits > 0:
						p.hitstop(p.HITSTOP)
				return true
			p.pose.x = lerpf(side * 0.9, -side * 0.9, clampf(_t / 0.08, 0.0, 1.0))
			if _t > 0.08 and p.buffer == "dodge" and p.can_dodge():
				p.take_buffer()
				p.start_dodge()
				return true
			var recovery: float = spec["recovery"]
			if _t >= recovery * 0.5 and p.buffer == "light" and _i < CUTS.size() - 1:
				p.take_buffer()
				_cut(_i + 1)
				return true
			return _t < recovery
		M.HEAVY:
			if _deciding and _t >= TALISMAN_WINDUP:
				_deciding = false
				if p.intent.heavy_held:
					if p.qi >= GALE_COST:
						_gale = true
					else:
						p.deny_qi()   # can't afford the gale: the talisman flies instead
			p.pose.y = lerpf(p.pose.y, 1.0 if (_gale or _deciding) else 0.3, 1.0 - exp(-20.0 * delta))
			if not _fired and not _deciding:
				var windup := GALE_WINDUP if _gale else TALISMAN_WINDUP
				if _t >= windup:
					_fired = true
					_t = 0.0
					if _gale:
						_cast_gale()
					else:
						_throw_talisman()
				return true
			if _fired and p.buffer == "dodge" and p.can_dodge():
				p.take_buffer()
				p.start_dodge()
				return true
			return not _fired or _t < HEAVY_RECOVERY
		M.WARD:
			p.pose.y = lerpf(p.pose.y, 1.0, 1.0 - exp(-20.0 * delta))
			if not _fired and _t >= WARD_WINDUP:
				_fired = true
				_t = 0.0
				p.spend_qi(WARD_COST)
				p.stats["wards"] += 1
				p.place_ward(WARD_RADIUS, WARD_TIME, WARD_HEAL)
			return not _fired or _t < WARD_RECOVERY
	return false


func _throw_talisman() -> void:
	p.spend_qi(TALISMAN_COST)
	var dir: Vector3 = p.forward()
	var length: float = p.ray_length(dir, TALISMAN_RANGE)
	var hit: Array = p.hit_line(length, 0.6, TALISMAN_DAMAGE, 1.0, false)
	var end: Vector3 = p.global_position + dir * length
	if not hit.is_empty():
		var e: Node3D = hit[0]
		end = e.global_position
		e.seal(SEAL_TIME_BIG if e.big else SEAL_TIME)
		p.stats["seals"] += 1
	p.fx("arrow", [p.global_position + Vector3(0, 1.1, 0), end + Vector3(0, 0.6, 0), Color(0.95, 0.8, 0.3, 1)])


func _cast_gale() -> void:
	p.spend_qi(GALE_COST)
	p.stats["gales"] += 1
	p.fx("arc", [p.global_position, p.rotation.y, GALE_ARC, GALE_RANGE, Color(0.8, 0.95, 0.9, 0.5)])
	for e in p.enemies_in_arc(GALE_RANGE, GALE_ARC):
		var d: Vector3 = p.flat_to(e).normalized()
		e.take_hit(GALE_DAMAGE, d * GALE_KNOCKBACK)
		e.stagger(GALE_STAGGER)   # interrupts any warning, big toads included


func show(delta: float) -> void:
	if not p.in_action() and p.authority:
		var k := 1.0 - exp(-12.0 * delta)
		p.pose.x = lerpf(p.pose.x, 0.0, k)
		p.pose.y = lerpf(p.pose.y, 0.0, k)
	_fan.rotation.y = p.pose.x
	_fan.position = Vector3(0.62, 1.15 + p.pose.y * 0.5, -0.25 - p.pose.y * 0.3)
	_leaf.scale = Vector3.ONE * (1.0 + 0.4 * p.pose.y)
