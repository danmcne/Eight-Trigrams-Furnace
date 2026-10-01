extends CharacterBody3D
## A player character (milestone 5). What every class shares lives here:
## movement, dodge, health, qi, the gourd, downed/revive, replication.
## What makes a class play differently lives in its kit (kits/*.gd).
##
## On the host (`authority`) it reads one Intent per tick from `input_source`
## and simulates; on a client it is a puppet mirroring the host's state.

signal health_changed(hp: float, max_hp: float)
signal qi_changed(qi: float, max_qi: float)
signal qi_denied
signal died   # downed; an ally can revive
signal item_used(player: Node3D, dir: Vector3)   # the gourd button, handled by the level

const Fx := preload("res://fx.gd")
const Intent := preload("res://intent.gd")
const KITS := {
	"glaive": preload("res://kits/glaive.gd"),
	"bow": preload("res://kits/bow.gd"),
	"dao": preload("res://kits/dao.gd"),
	"scholar": preload("res://kits/scholar.gd"),
}
const CLASSES := ["glaive", "bow", "dao", "scholar"]

# ---------------- Shared tuning ----------------
const ACCEL := 70.0
const FRICTION := 40.0
const DODGE_SPEED := 17.0
const DODGE_TIME := 0.17
const DODGE_IFRAMES := 0.22
const PERFECT_DODGE := 0.15      # a hit arriving this soon after a dodge starts was dodged perfectly
const HURT_TIME := 0.22
const HURT_IFRAMES := 0.6
const INPUT_BUFFER := 0.25
const HITSTOP := 0.055
const ASSIST_HALF_ANGLE := 40.0
const ASSIST_EXTRA_RANGE := 2.5
const MAX_QI := 100.0
const PEACH_HP := 25.0
const QI_REGEN_DELAY := 1.0
const ITEM_TIME := 0.3
const GRAVITY := 30.0
const LAYER_WORLD := 1
const LAYER_ENEMY := 4
# -----------------------------------------------

enum State { NORMAL, ACTION, DODGE, HURT, DOWNED, ITEM, TRAPPED }

var state := State.NORMAL
var kit_name := "glaive"
var kit
var hp := 0.0
var max_hp := 100.0
var qi := 0.0
var max_qi := MAX_QI
var speed := 7.0
var radius := 0.45
var input_source          # any object with poll(player) -> Intent
var world: Node           # the session (main): wards, wall-aware ranges
var authority := true
var peer_id := 1
var color := Color(0.55, 0.16, 0.12)
var allow_hitstop := true # off in networked sessions: a time freeze would stall everyone
var revive_progress := 0.0
var has_gourd := false
var gourd_slots := 1      # 2 once the jade vase joins the gourd
var gourd := 0            # first chamber: see dungeon.gd (EMPTY, WATER, FIRE, TOAD)
var gourd2 := 0           # second chamber (with the vase); poured after the first
var peaches := 0          # peaches of immortality eaten: each adds PEACH_HP to max health
var god := false          # cheat: nothing hurts
var pose := Vector3.ZERO  # the kit's weapon pose; the only kit state clients receive
var intent: Intent = Intent.new()
var buffer := ""
var iframes := 0.0
var stats := {}
var acts := 0             # counts attacks, specials and gourd uses: "answering" a boss's call

var _t := 0.0
var _hurt_for := 0.0
var _buffer_t := 0.0
var _dodge_cd := 0.0
var _dodge_cooldown := 0.35
var _qi_regen := 6.0
var _perfect_used := false
var _blink := 0.0
var _qi_idle := 0.0
var _dodge_dir := Vector3.ZERO
var _trap_left := 0.0
var _trap_dps := 0.0
var _trap_holder: Node3D

var _body: MeshInstance3D
var _body_mat: StandardMaterial3D
var _gourd_node: Node3D
var _gourd_glow: StandardMaterial3D
var _vase_node: Node3D
var _vase_glow: StandardMaterial3D
const GOURD_GLOW := [Color(0.3, 0.2, 0.1), Fx.WATER, Fx.FIRE, Fx.TOAD_GREEN]
const STAT_KEYS := ["light_hits", "thrusts", "sweeps", "blocks", "parries", "guard_breaks", "dodges", "qi_denied",
	"snap_hits", "full_draws", "kicks", "dashes", "counters", "perfect_dodges", "seals", "gales", "wards"]


func _ready() -> void:
	for k in STAT_KEYS:
		stats[k] = 0
	kit = KITS[kit_name].new()
	kit.p = self
	var ks: Dictionary = kit.stats()
	max_hp = ks["hp"] + PEACH_HP * peaches
	speed = ks["speed"]
	_dodge_cooldown = ks["dodge_cooldown"]
	_qi_regen = ks["qi_regen"]
	radius = ks.get("radius", 0.45)
	hp = max_hp
	qi = max_qi
	add_to_group("players")
	if authority:
		collision_layer = 2
		collision_mask = LAYER_WORLD | LAYER_ENEMY
		var shape := CollisionShape3D.new()
		var cap := CapsuleShape3D.new()
		cap.radius = radius
		cap.height = 1.8
		shape.shape = cap
		shape.position.y = 0.9
		add_child(shape)
	else:
		collision_layer = 0
		collision_mask = 0

	_body = MeshInstance3D.new()
	var cm := CapsuleMesh.new()
	cm.radius = radius
	cm.height = 1.8
	_body.mesh = cm
	_body.position.y = 0.9
	_body_mat = Fx.mat(color)
	_body.material_override = _body_mat
	add_child(_body)
	add_child(box(Vector3(0.25, 0.12, 0.2), Vector3(0, 1.45, -radius + 0.03), Color(0.15, 0.12, 0.1)))   # shows facing

	_gourd_node = Node3D.new()   # the gourd at the hip; its mouth glows with what it holds
	_gourd_node.position = Vector3(-0.5, 0.85, 0.0)
	add_child(_gourd_node)
	var gourd_mat := Fx.mat(Color(0.72, 0.35, 0.12))
	for part: Array in [[0.0, 0.2], [0.3, 0.14]]:
		var gm := MeshInstance3D.new()
		var gs := SphereMesh.new()
		gs.radius = part[1]
		gs.height = part[1] * 2.0
		gm.mesh = gs
		gm.material_override = gourd_mat
		gm.position.y = part[0]
		_gourd_node.add_child(gm)
	var glow := MeshInstance3D.new()
	var gl := SphereMesh.new()
	gl.radius = 0.08
	gl.height = 0.16
	glow.mesh = gl
	_gourd_glow = Fx.mat(GOURD_GLOW[0], true)
	glow.material_override = _gourd_glow
	glow.position.y = 0.46
	_gourd_node.add_child(glow)

	_vase_node = Node3D.new()   # the jade vase beside the gourd, once won
	_vase_node.position = Vector3(-0.45, 0.8, 0.35)
	add_child(_vase_node)
	var vm := CylinderMesh.new()
	vm.top_radius = 0.08
	vm.bottom_radius = 0.18
	vm.height = 0.4
	var vmi := MeshInstance3D.new()
	vmi.mesh = vm
	vmi.material_override = Fx.mat(Color(0.78, 0.9, 0.8))
	_vase_node.add_child(vmi)
	var vg := MeshInstance3D.new()
	var vgs := SphereMesh.new()
	vgs.radius = 0.07
	vgs.height = 0.14
	vg.mesh = vgs
	_vase_glow = Fx.mat(GOURD_GLOW[0], true)
	vg.material_override = _vase_glow
	vg.position.y = 0.24
	_vase_node.add_child(vg)

	var weapon := Node3D.new()
	add_child(weapon)
	kit.build(weapon)


func is_dead() -> bool:
	return state == State.DOWNED


func in_action() -> bool:
	return state == State.ACTION


func is_trapped() -> bool:
	return state == State.TRAPPED


## What the gourd holds, oldest first.
func held() -> Array:
	var out := []
	for w in [gourd, gourd2]:
		if w != 0:
			out.append(w)
	return out


func set_held(contents: Array) -> void:
	gourd = contents[0] if contents.size() > 0 else 0
	gourd2 = contents[1] if contents.size() > 1 else 0


func set_peaches(n: int) -> void:
	peaches = n
	max_hp = kit.stats()["hp"] + PEACH_HP * peaches


func add_peach() -> void:
	peaches += 1
	max_hp += PEACH_HP
	if state != State.DOWNED:
		hp = max_hp
	health_changed.emit(hp, max_hp)


func _physics_process(delta: float) -> void:
	if authority:
		_simulate(delta)
	_blink = maxf(0.0, _blink - delta)
	visible = state != State.TRAPPED   # inside the jade vase
	_body.visible = _blink <= 0.0 or fmod(_blink, 0.1) < 0.06
	_body_mat.albedo_color = color.lerp(Color(0.5, 0.5, 0.5), 0.6) if state == State.DOWNED else color
	_gourd_node.visible = has_gourd
	_gourd_glow.albedo_color = GOURD_GLOW[clampi(gourd, 0, 3)]
	_vase_node.visible = has_gourd and gourd_slots >= 2
	_vase_glow.albedo_color = GOURD_GLOW[clampi(gourd2, 0, 3)]
	var raised := state == State.ITEM
	_gourd_node.position = _gourd_node.position.lerp(Vector3(0.0, 1.4, -0.6) if raised else Vector3(-0.5, 0.85, 0.0), 1.0 - exp(-20.0 * delta))
	kit.show(delta)


func _simulate(delta: float) -> void:
	intent = input_source.poll(self) if input_source else Intent.new()
	_dodge_cd = maxf(0.0, _dodge_cd - delta)
	iframes = maxf(0.0, iframes - delta)
	_qi_idle += delta
	if _qi_idle >= QI_REGEN_DELAY and state != State.DOWNED:
		add_qi(_qi_regen * delta)
	if _buffer_t > 0.0:
		_buffer_t -= delta
		if _buffer_t <= 0.0:
			buffer = ""
	if state != State.DOWNED:
		if intent.dodge:
			_set_buffer("dodge")
		elif intent.heavy:
			_set_buffer("heavy")
		elif intent.light:
			_set_buffer("light")
		elif intent.block and not kit.special_is_held:
			_set_buffer("special")
		elif intent.item:
			_set_buffer("item")
	kit.pre_tick(delta)

	velocity.y -= GRAVITY * delta
	match state:
		State.NORMAL:
			move_input(delta, speed, 15.0)
			_act_from_neutral()
		State.ACTION:
			var busy: bool = kit.tick(delta)
			if state == State.ACTION and not busy:
				state = State.NORMAL
				_act_from_neutral()
		State.DODGE:
			_t += delta
			velocity.x = _dodge_dir.x * DODGE_SPEED
			velocity.z = _dodge_dir.z * DODGE_SPEED
			if _t >= DODGE_TIME:
				pass_through(false)
				state = State.NORMAL
		State.HURT:
			_t += delta
			friction(delta)
			if _t >= _hurt_for:
				state = State.NORMAL
		State.ITEM:
			_t += delta
			friction(delta)
			if _t >= ITEM_TIME:
				state = State.NORMAL
		State.DOWNED:
			friction(delta)
		State.TRAPPED:
			_trap_tick(delta)
			return
	move_and_slide()


func _set_buffer(what: String) -> void:
	buffer = what
	_buffer_t = INPUT_BUFFER


func take_buffer() -> String:
	var b := buffer
	buffer = ""
	_buffer_t = 0.0
	return b


## From a free state: dodge first, then whatever the kit starts, then the gourd.
func _act_from_neutral() -> void:
	if buffer == "dodge":
		if can_dodge():
			take_buffer()
			start_dodge()
		return
	if kit.neutral():
		return
	if buffer == "item":
		take_buffer()
		if has_gourd:
			var mv := move_vec()
			var dir := intent.aim if intent.aim != Vector3.ZERO else (mv.normalized() if mv.length() > 0.2 else forward())
			face(dir)
			state = State.ITEM
			_t = 0.0
			acts += 1
			item_used.emit(self, dir)


func begin_action() -> void:
	if state != State.ACTION:
		acts += 1
	state = State.ACTION


# ---------------- Movement, facing, aim ----------------

func move_vec() -> Vector3:
	return Vector3(intent.move.x, 0.0, intent.move.y)


func move_input(delta: float, top_speed: float, turn_rate: float) -> void:
	var mv := move_vec()
	var target := mv * top_speed
	var h := Vector2(velocity.x, velocity.z).move_toward(Vector2(target.x, target.z), ACCEL * delta)
	velocity.x = h.x
	velocity.z = h.y
	if mv.length() > 0.1:
		rotation.y = lerp_angle(rotation.y, _yaw_of(mv), 1.0 - exp(-turn_rate * delta))


func friction(delta: float) -> void:
	var h := Vector2(velocity.x, velocity.z).move_toward(Vector2.ZERO, FRICTION * delta)
	velocity.x = h.x
	velocity.z = h.y


func lunge(amount: float) -> void:
	var f := forward()
	velocity.x += f.x * amount
	velocity.z += f.z * amount


func _yaw_of(dir: Vector3) -> float:
	return atan2(-dir.x, -dir.z)


func face(dir: Vector3) -> void:
	if dir.length() > 0.001:
		rotation.y = _yaw_of(dir)


func forward() -> Vector3:
	var f := -global_transform.basis.z
	f.y = 0.0
	return f.normalized()


func flat_to(node: Node3D) -> Vector3:
	var d := node.global_position - global_position
	d.y = 0.0
	return d


## Direction for a new attack: explicit aim if given (cursor mode, no assist);
## otherwise movement direction or facing, turned toward the nearest enemy
## inside the assist cone and reach.
func attack_dir(reach: float, half_angle := ASSIST_HALF_ANGLE) -> Vector3:
	if intent.aim != Vector3.ZERO:
		return intent.aim
	var mv := move_vec()
	var base := mv.normalized() if mv.length() > 0.2 else forward()
	var best := base
	var best_d := INF
	var half := deg_to_rad(half_angle)
	for e: Node3D in get_tree().get_nodes_in_group("enemies"):
		var d := flat_to(e)
		var dist := d.length()
		if dist < 0.01 or dist > reach + ASSIST_EXTRA_RANGE or dist >= best_d:
			continue
		if base.angle_to(d / dist) <= half and ray_length(d / dist, dist) >= dist - 0.5:
			best = d / dist
			best_d = dist
	return best


func nearest_enemy_within(r: float) -> Node3D:
	var best: Node3D = null
	var best_d := r
	for e: Node3D in get_tree().get_nodes_in_group("enemies"):
		var dist := flat_to(e).length()
		if dist < best_d:
			best = e
			best_d = dist
	return best


## How far a straight shot can travel before a wall stops it.
func ray_length(dir: Vector3, max_length: float) -> float:
	return world_ray(global_position, dir, max_length)


## The same from any point.
func world_ray(from: Vector3, dir: Vector3, max_length: float) -> float:
	if world and world.has_method("ray_length"):
		return world.ray_length(from, dir, max_length)
	return max_length


func covers(source: Node3D, arc_deg: float) -> bool:
	var d := flat_to(source)
	if d.length() < 0.01:
		return true
	return forward().angle_to(d.normalized()) <= deg_to_rad(arc_deg) * 0.5


## Pass through enemies (dodges, dashes) or collide with them again.
func pass_through(on: bool) -> void:
	collision_mask = LAYER_WORLD if on else LAYER_WORLD | LAYER_ENEMY


# ---------------- Hitting ----------------

func enemies_in_arc(reach: float, arc_deg: float) -> Array:
	var out := []
	var fwd := forward()
	var half := deg_to_rad(arc_deg) * 0.5
	for e: Node3D in get_tree().get_nodes_in_group("enemies"):
		if e.is_dead():
			continue
		var d := flat_to(e)
		var dist := d.length()
		var er: float = e.radius
		if dist > reach + er:
			continue
		if half < PI and dist > 0.01 and fwd.angle_to(d / dist) > half:
			continue
		out.append(e)
	return out


func enemies_within(r: float) -> Array:
	var out := []
	for e: Node3D in get_tree().get_nodes_in_group("enemies"):
		var er: float = e.radius
		if not e.is_dead() and flat_to(e).length() <= r + er:
			out.append(e)
	return out


## Hit everything in an arc in front. Returns how many were hit.
func hit_arc(reach: float, arc_deg: float, damage: float, knock: float) -> int:
	var hits := enemies_in_arc(reach, arc_deg)
	for e: Node3D in hits:
		var d := flat_to(e)
		e.take_hit(damage, (d.normalized() if d.length() > 0.01 else forward()) * knock)
	return hits.size()


## Hit along a straight strip ahead: every enemy on it (pierce) or only the nearest.
## Returns the enemies hit, nearest first.
func hit_line(reach: float, width: float, damage: float, knock: float, pierce: bool) -> Array:
	var fwd := forward()
	var on_line := []
	for e: Node3D in get_tree().get_nodes_in_group("enemies"):
		if e.is_dead():
			continue
		var d := flat_to(e)
		var er: float = e.radius
		var along := d.dot(fwd)
		if along < -er or along > reach + er or (d - fwd * along).length() > width * 0.5 + er:
			continue
		on_line.append([along, e])
	on_line.sort_custom(func(a: Array, b: Array) -> bool: return a[0] < b[0])
	var hit := []
	for pair: Array in on_line:
		pair[1].take_hit(damage, fwd * knock)
		hit.append(pair[1])
		if not pierce:
			break
	return hit


func hitstop(duration: float) -> void:
	if duration <= 0.0 or not allow_hitstop:
		return
	Engine.time_scale = 0.05
	# The restore belongs to the engine, not to this node, so it still happens
	# if the player is freed mid-freeze.
	var timer := get_tree().create_timer(duration, true, false, true)
	timer.timeout.connect(Engine.set.bind("time_scale", 1.0))


func fx(kind: String, args: Array) -> void:
	Fx.play(get_parent(), kind, args)


func place_ward(r: float, seconds: float, heal: float) -> void:
	if world and world.has_method("add_ward"):
		world.add_ward(self, global_position, r, seconds, heal)


# ---------------- Qi ----------------

func add_qi(amount: float) -> void:
	var before := qi
	qi = minf(max_qi, qi + amount)
	if qi != before:
		qi_changed.emit(qi, max_qi)


func spend_qi(amount: float) -> void:
	if amount <= 0.0:
		return
	qi = maxf(0.0, qi - amount)
	_qi_idle = 0.0
	qi_changed.emit(qi, max_qi)


func deny_qi() -> void:
	stats["qi_denied"] += 1
	qi_denied.emit()


func heal(amount: float) -> void:
	if state == State.DOWNED or hp >= max_hp:
		return
	hp = minf(max_hp, hp + amount)
	health_changed.emit(hp, max_hp)


# ---------------- Dodge ----------------

func can_dodge() -> bool:
	return _dodge_cd <= 0.0


func start_dodge() -> void:
	var mv := move_vec()
	_dodge_dir = mv.normalized() if mv.length() > 0.2 else -forward()
	state = State.DODGE
	_t = 0.0
	_perfect_used = false
	iframes = maxf(iframes, DODGE_IFRAMES)
	_dodge_cd = _dodge_cooldown + DODGE_TIME
	pass_through(true)
	stats["dodges"] += 1


# ---------------- Damage ----------------

## Called by enemies. Returns "ignored", "parried", "blocked", "countered" or "hit";
## the attacker reacts to "parried".
func take_hit(damage: float, push: Vector3, source: Node3D = null, blockable := true) -> String:
	if state == State.DOWNED or state == State.TRAPPED or god:
		return "ignored"
	if iframes > 0.0:
		if state == State.DODGE and _t <= PERFECT_DODGE and not _perfect_used:
			_perfect_used = true
			kit.on_perfect_dodge()
		return "ignored"
	var handled: String = kit.intercept(damage, push, source, blockable)
	if handled != "":
		return handled
	land_hit(damage, push, HURT_TIME)
	return "hit"


func land_hit(damage: float, push: Vector3, hurt_for: float) -> void:
	hp = maxf(0.0, hp - damage)
	health_changed.emit(hp, max_hp)
	velocity.x = push.x
	velocity.z = push.z
	iframes = HURT_IFRAMES
	_blink = HURT_IFRAMES
	pass_through(false)
	if hp <= 0.0:
		state = State.DOWNED
		_body.visible = true
		rotation.x = -PI * 0.5 * 0.9
		died.emit()
		return
	state = State.HURT
	_hurt_for = hurt_for
	_t = 0.0


# ---------------- Trapped in a vase (host) ----------------

## Drawn into a vessel: hidden, untouchable, losing health, carried by `holder`.
func trap(seconds: float, dps: float, holder: Node3D) -> void:
	if state == State.DOWNED or state == State.TRAPPED or god:
		return
	state = State.TRAPPED
	_trap_left = seconds
	_trap_dps = dps
	_trap_holder = holder
	buffer = ""
	collision_layer = 0
	collision_mask = 0
	velocity = Vector3.ZERO


func _trap_tick(delta: float) -> void:
	if is_instance_valid(_trap_holder):
		global_position = _trap_holder.global_position
	_trap_left -= delta
	hp = maxf(0.0, hp - _trap_dps * delta)
	health_changed.emit(hp, max_hp)
	if hp <= 0.0 or _trap_left <= 0.0:
		release()


## Out of the vessel, beside whoever held it.
func release() -> void:
	if state != State.TRAPPED:
		return
	var out := Vector3.RIGHT
	var holder_r := 1.0
	if is_instance_valid(_trap_holder):
		holder_r = _trap_holder.radius
		out = _trap_holder.global_transform.basis.x   # out at his side
		out.y = 0.0
		out = out.normalized()
		global_position = _trap_holder.global_position + out * (holder_r + radius + 0.4)
	global_position.y = maxf(global_position.y, 0.05)
	_trap_holder = null
	if authority:
		collision_layer = 2
		pass_through(false)
	velocity = out * 6.0
	if hp <= 0.0:
		state = State.DOWNED
		rotation.x = -PI * 0.5 * 0.9
		died.emit()
		return
	state = State.HURT
	_hurt_for = 0.4
	_t = 0.0
	iframes = 1.0
	_blink = 1.0


# ---------------- Revive (host) ----------------

func revive(hp_fraction: float) -> void:
	hp = max_hp * hp_fraction
	qi = max_qi
	state = State.NORMAL
	rotation.x = 0.0
	revive_progress = 0.0
	iframes = 1.5
	_blink = 1.5
	pass_through(false)
	health_changed.emit(hp, max_hp)
	qi_changed.emit(qi, max_qi)


# ---------------- Replication ----------------
# Fixed binary layout, written after the peer id (which main reads to route it).
# BYTES_AFTER_ID lets a reader skip an entry for a player it doesn't know yet.

const BYTES_AFTER_ID := 37


func write_net(b: StreamPeerBuffer) -> void:
	b.put_u32(peer_id)
	b.put_float(global_position.x)
	b.put_float(global_position.y)
	b.put_float(global_position.z)
	b.put_half(rotation.y)
	b.put_half(rotation.x)
	b.put_u8(state)
	b.put_half(hp)
	b.put_half(qi)
	b.put_half(pose.x)
	b.put_half(pose.y)
	b.put_half(pose.z)
	b.put_half(_blink)
	b.put_u8(int(revive_progress * 255.0))
	b.put_u16(mini(stats["qi_denied"], 65535))
	b.put_u8((1 if has_gourd else 0) | (2 if gourd_slots >= 2 else 0))
	b.put_u8(gourd)
	b.put_u8(gourd2)
	b.put_half(max_hp)


func read_net(b: StreamPeerBuffer) -> void:
	global_position = Vector3(b.get_float(), b.get_float(), b.get_float())
	rotation.y = b.get_half()
	rotation.x = b.get_half()
	var was_down := state == State.DOWNED
	state = b.get_u8() as State
	var new_hp := b.get_half()
	var new_qi := b.get_half()
	if new_hp != hp:
		hp = new_hp
		health_changed.emit(hp, max_hp)
	if new_qi != qi:
		qi = new_qi
		qi_changed.emit(qi, max_qi)
	pose = Vector3(b.get_half(), b.get_half(), b.get_half())
	_blink = b.get_half()
	revive_progress = b.get_u8() / 255.0
	var denied := b.get_u16()
	if denied > stats["qi_denied"]:
		stats["qi_denied"] = denied
		qi_denied.emit()
	var flags := b.get_u8()
	has_gourd = (flags & 1) != 0
	gourd_slots = 2 if (flags & 2) != 0 else 1
	gourd = b.get_u8()
	gourd2 = b.get_u8()
	var new_max := b.get_half()
	if new_max != max_hp:
		max_hp = new_max
		health_changed.emit(hp, max_hp)
	if state == State.DOWNED and not was_down:
		died.emit()


# ---------------- Mesh helpers for kits ----------------

func mat(c: Color) -> StandardMaterial3D:
	return Fx.mat(c)


func box(size: Vector3, pos: Vector3, c: Color) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	mi.material_override = Fx.mat(c)
	mi.position = pos
	return mi


func cyl(pos: Vector3, r: float, h: float, c: Color) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = r
	cm.bottom_radius = r
	cm.height = h
	mi.mesh = cm
	mi.material_override = Fx.mat(c)
	mi.position = pos
	return mi


## A flat half-disc (an open fan), in the vertical plane facing forward.
func fan_mesh(r: float) -> ArrayMesh:
	var verts := PackedVector3Array()
	var n := 10
	for i in n:
		var a0 := PI * float(i) / n
		var a1 := PI * float(i + 1) / n
		verts.append(Vector3.ZERO)
		verts.append(Vector3(cos(a0) * r, sin(a0) * r, 0))
		verts.append(Vector3(cos(a1) * r, sin(a1) * r, 0))
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh
