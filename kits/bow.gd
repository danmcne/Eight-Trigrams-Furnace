extends "res://kits/kit.gd"
## Bow: keeping distance. Quick snap shots; a held draw that slows you and grows
## in power until a full draw pierces the whole line; a kick to make room.

# ---------------- Tuning ----------------
const SNAP := {"windup": 0.12, "recovery": 0.20, "damage": 9.0, "knockback": 3.0, "range": 14.0}
const DRAW_TIME := 0.8            # seconds to a full draw
const DRAW_MOVE_FACTOR := 0.4
const DRAW_MIN_DAMAGE := 10.0
const DRAW_MAX_DAMAGE := 26.0
const FULL_DAMAGE := 35.0         # a full draw with qi to spend
const FULL_COST := 20.0
const DRAW_RANGE := 20.0
const DRAW_RECOVERY := 0.25
const KICK := {"windup": 0.08, "recovery": 0.25, "damage": 4.0, "knockback": 11.0, "arc": 120.0, "range": 1.9}
const KICK_COOLDOWN := 0.8
const KICK_STAGGER := 0.6
const QI_PER_HIT := 6.0
const AIM_HALF_ANGLE := 25.0      # narrower than melee assist, but reaching much further
# ----------------------------------------

enum M { NONE, SNAP, DRAW, RELEASE, KICK }
var move := M.NONE
var _t := 0.0
var _fired := false
var _kick_cd := 0.0
var _bow: Node3D
var _string: MeshInstance3D
var _arrow: MeshInstance3D


func stats() -> Dictionary:
	return {"hp": 80.0, "speed": 7.0, "dodge_cooldown": 0.35, "qi_regen": 6.0}


func build(root: Node3D) -> void:
	# Held out at the right side, bulging forward; the string is drawn back.
	_bow = Node3D.new()
	_bow.position = Vector3(0.62, 1.15, -0.25)
	_bow.rotation.z = -1.15   # canted sideways, horse-archer style, so it reads from above
	root.add_child(_bow)
	var wood := Color(0.42, 0.26, 0.12)
	var n := 9
	for k in n:
		var a := lerpf(-1.25, 1.25, float(k) / (n - 1))
		var seg: MeshInstance3D = p.box(Vector3(0.07, 0.26, 0.07), Vector3(0.0, sin(a) * 0.85, -cos(a) * 0.32), wood)
		seg.rotation.x = -a * 0.35
		_bow.add_child(seg)
	_string = p.box(Vector3(0.025, 1.6, 0.025), Vector3(0, 0, -cos(1.25) * 0.32), Color(0.92, 0.92, 0.86))
	_bow.add_child(_string)
	_arrow = p.box(Vector3(0.04, 0.04, 1.1), Vector3(0, 0, -0.4), Color(0.85, 0.8, 0.6))
	_bow.add_child(_arrow)
	var quiver: MeshInstance3D = p.box(Vector3(0.24, 0.8, 0.24), Vector3(-0.2, 1.25, 0.45), Color(0.45, 0.3, 0.15))
	quiver.rotation.z = 0.35
	root.add_child(quiver)


func pre_tick(delta: float) -> void:
	_kick_cd = maxf(0.0, _kick_cd - delta)


func neutral() -> bool:
	match p.buffer:
		"light":
			p.take_buffer()
			_begin(M.SNAP)
			p.face(p.attack_dir(SNAP["range"], AIM_HALF_ANGLE))
			return true
		"heavy":
			p.take_buffer()
			_begin(M.DRAW)
			return true
		"special":
			p.take_buffer()
			if _kick_cd <= 0.0:
				_begin(M.KICK)
				p.face(p.attack_dir(KICK["range"]))
				return true
	return false


func _begin(m: M) -> void:
	move = m
	_t = 0.0
	_fired = false
	p.begin_action()


func tick(delta: float) -> bool:
	_t += delta
	match move:
		M.SNAP:
			p.friction(delta)
			var windup: float = SNAP["windup"]
			if not _fired and _t >= windup:
				_fired = true
				var hits := _shoot(SNAP["range"], SNAP["damage"], SNAP["knockback"], false, false)
				p.stats["snap_hits"] += hits
				p.add_qi(hits * QI_PER_HIT)
			p.pose.x = clampf(_t / windup, 0.0, 1.0) * 0.4 if not _fired else 0.0
			return _dodge_cancel() and _t < windup + float(SNAP["recovery"])
		M.DRAW:
			# Aim with movement while drawing, slowed; release the button to loose.
			p.move_input(delta, p.speed * DRAW_MOVE_FACTOR, 10.0)
			p.pose.x = clampf(_t / DRAW_TIME, 0.0, 1.0)
			if p.buffer == "dodge" and p.can_dodge():
				p.take_buffer()
				p.start_dodge()
				return true
			if not p.intent.heavy_held:
				_loose()
				move = M.RELEASE
				_t = 0.0
			return true
		M.RELEASE:
			p.friction(delta)
			p.pose.x = 0.0
			return _dodge_cancel() and _t < DRAW_RECOVERY
		M.KICK:
			p.friction(delta)
			var windup: float = KICK["windup"]
			if not _fired and _t >= windup:
				_fired = true
				_kick_cd = KICK_COOLDOWN
				p.lunge(2.0)
				p.fx("arc", [p.global_position, p.rotation.y, KICK["arc"], KICK["range"], Color(0.95, 0.92, 0.8, 0.45)])
				for e in p.enemies_in_arc(KICK["range"], KICK["arc"]):
					var d: Vector3 = p.flat_to(e).normalized()
					e.take_hit(KICK["damage"], d * KICK["knockback"])
					if not e.big:
						e.stagger(KICK_STAGGER)
					p.stats["kicks"] += 1
			return _dodge_cancel() and _t < windup + float(KICK["recovery"])
	return false


func _dodge_cancel() -> bool:
	if _fired and p.buffer == "dodge" and p.can_dodge():
		p.take_buffer()
		p.start_dodge()
	return true


func _loose() -> void:
	var power := clampf(_t / DRAW_TIME, 0.0, 1.0)
	var full := power >= 1.0
	if full and p.qi < FULL_COST:
		p.deny_qi()
		full = false
		power = 0.99
	p.face(p.attack_dir(DRAW_RANGE, AIM_HALF_ANGLE))
	if full:
		p.spend_qi(FULL_COST)
		p.stats["full_draws"] += 1
		_shoot(DRAW_RANGE, FULL_DAMAGE, 10.0, true, true)
	else:
		_shoot(DRAW_RANGE, lerpf(DRAW_MIN_DAMAGE, DRAW_MAX_DAMAGE, power), 5.0, false, false)


## Arrows fly straight and fast: resolved at once along the line, stopped by walls.
func _shoot(reach: float, damage: float, knock: float, pierce: bool, stagger: bool) -> int:
	var dir: Vector3 = p.forward()
	var length: float = p.ray_length(dir, reach)
	var hit: Array = p.hit_line(length, 0.5, damage, knock, pierce)
	var end: Vector3 = p.global_position + dir * length
	if not pierce and not hit.is_empty():
		end = hit[0].global_position
	for e in hit:
		if stagger:
			e.stagger(0.5)
	p.fx("arrow", [p.global_position + Vector3(0, 1.1, 0), end + Vector3(0, 0.8, 0), Color(1, 0.95, 0.7, 1) if pierce else Color(0.9, 0.85, 0.7, 1)])
	if not hit.is_empty():
		p.hitstop(p.HITSTOP)
	return hit.size()


func show(_delta: float) -> void:
	var draw: float = p.pose.x
	var rest := -cos(1.25) * 0.32
	_string.position.z = rest + draw * 0.5
	_string.scale.y = 1.0 - 0.12 * draw
	_arrow.visible = draw > 0.02
	_arrow.position.z = rest - 0.45 + draw * 0.5
