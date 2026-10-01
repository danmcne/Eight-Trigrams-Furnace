extends Node3D
## One interactive dungeon object. Everything about it (look, collision) follows
## from `state`, so a client that only receives the state shows the same thing.
##
## Kinds and states:
##   pool      0 full (blocks)      1 drained          region of '~'
##   firewall  0 burning (blocks)   1 doused           region of 'F'
##   bramble   0 intact (blocks)    1 burnt            region of 'T'
##   door      0 closed (blocks)    1 open
##   brazier   0 unlit              1 lit
##   basin     0 empty              1 filled
##   chest     0 closed             1 opened (the gourd is taken)
##   exit      0 sealed             1 open             2 reached (a linked exit
##             opens when its link is satisfied; an unlinked one at once)
##   pickup    0 sealed             1 available        2 taken  (item: gourd, vase, peach;
##             unsealed when its link is satisfied; walk over it to take it)
##   eternal, spring: always usable; state unused

const Fx := preload("res://fx.gd")
const TILE := 2.0

var kind := ""
var item := ""           # pickups only
var tiles: Array[Vector2i] = []
var link := -1
var rooms := {}          # room ids this prop can be used from
var state := 0

var _bodies: Array[StaticBody3D] = []
var _parts := {}         # named visuals


static func tile_center(t: Vector2i) -> Vector3:
	return Vector3(t.x * TILE + TILE * 0.5, 0.0, t.y * TILE + TILE * 0.5)


## Nearest tile centre of this prop to a point (regions are several tiles).
func point_near(p: Vector3) -> Vector3:
	var best := tile_center(tiles[0])
	for t in tiles:
		var c := tile_center(t)
		if Vector2(c.x - p.x, c.z - p.z).length() < Vector2(best.x - p.x, best.z - p.z).length():
			best = c
	return best


func blocks() -> bool:
	match kind:
		"pool", "firewall", "bramble", "door":
			return state == 0
		"brazier", "basin", "chest", "eternal":
			return true
	return false


func build() -> void:
	for t in tiles:
		var c := tile_center(t)
		match kind:
			"pool":
				_add_part("water%d" % _parts.size(), _flat(c, Vector2(TILE, TILE), Fx.WATER_DEEP, 0.03))
			"spring":
				var disc := _cyl(c + Vector3(0, 0.02, 0), 0.8, 0.04, Fx.WATER)
				add_child(disc)
			"firewall":
				var f := _box(c + Vector3(0, 0.8, 0), Vector3(TILE, 1.6, 0.9 * TILE), Color(Fx.FIRE, 0.75), true)
				_add_part("fire%d" % _parts.size(), f)
			"bramble":
				var root := Node3D.new()
				root.position = c
				for k in 7:
					var b := _box(Vector3.ZERO, Vector3(0.12, 1.1, 1.9), Color(0.25, 0.3, 0.12))
					b.rotation = Vector3(0.35 * sin(k * 1.7), k * PI / 7.0, 0.3 * cos(k * 2.3))
					b.position.y = 0.55
					root.add_child(b)
				add_child(root)
				_add_part("thorns%d" % _parts.size(), root)
			"door":
				_add_part("door", _box(c + Vector3(0, 0.6, 0), Vector3(TILE, 1.2, TILE), Color(0.45, 0.2, 0.12)))
			"brazier":
				add_child(_cyl(c + Vector3(0, 0.45, 0), 0.35, 0.9, Color(0.35, 0.33, 0.3)))
				add_child(_cyl(c + Vector3(0, 0.95, 0), 0.55, 0.15, Color(0.3, 0.28, 0.25)))
				_add_part("flame", _flame(c + Vector3(0, 1.3, 0), Fx.FIRE))
			"eternal":
				add_child(_cyl(c + Vector3(0, 0.6, 0), 0.4, 1.2, Color(0.5, 0.5, 0.52)))
				add_child(_box(c + Vector3(0, 1.3, 0), Vector3(1.0, 0.2, 1.0), Color(0.45, 0.45, 0.47)))
				add_child(_flame(c + Vector3(0, 1.65, 0), Fx.FIRE))   # the lantern shape, not the colour, marks it eternal
			"basin":
				add_child(_cyl(c + Vector3(0, 0.3, 0), 0.85, 0.6, Color(0.42, 0.4, 0.37)))
				_add_part("fill", _cyl(c + Vector3(0, 0.62, 0), 0.7, 0.04, Fx.WATER))
			"chest":
				add_child(_box(c + Vector3(0, 0.35, 0), Vector3(1.3, 0.7, 0.9), Color(0.5, 0.3, 0.12)))
				_add_part("lid", _box(c + Vector3(0, 0.78, 0), Vector3(1.35, 0.16, 0.95), Color(0.6, 0.45, 0.1)))
			"pickup":
				add_child(_cyl(c + Vector3(0, 0.25, 0), 0.55, 0.5, Color(0.45, 0.43, 0.4)))   # pedestal
				var shown := Node3D.new()
				shown.position = c + Vector3(0, 0.75, 0)
				match item:
					"gourd":
						shown.add_child(_sphere(Vector3(0, 0.0, 0), 0.24, Color(0.72, 0.35, 0.12)))
						shown.add_child(_sphere(Vector3(0, 0.34, 0), 0.16, Color(0.72, 0.35, 0.12)))
					"vase":
						var vm := CylinderMesh.new()
						vm.top_radius = 0.12
						vm.bottom_radius = 0.28
						vm.height = 0.6
						var v := MeshInstance3D.new()
						v.mesh = vm
						v.material_override = Fx.mat(Color(0.78, 0.9, 0.8))
						v.position.y = 0.2
						shown.add_child(v)
					"peach":
						shown.add_child(_sphere(Vector3(0, 0.1, 0), 0.3, Color(1.0, 0.62, 0.6)))
						shown.add_child(_sphere(Vector3(0.12, 0.42, 0), 0.08, Color(0.3, 0.55, 0.25)))
				_add_part("item", shown)
			"exit":
				_add_part("ring", _cyl(c + Vector3(0, 0.03, 0), 0.9, 0.04, Color(0.98, 0.8, 0.3)))
		if blocks():
			var body := StaticBody3D.new()
			var cs := CollisionShape3D.new()
			var bs := BoxShape3D.new()
			# Tall like the walls, so nothing can land on top of it.
			bs.size = Vector3(TILE, 4.0, TILE) if kind in ["pool", "firewall", "bramble", "door"] else Vector3(1.3, 4.0, 1.3)
			cs.shape = bs
			body.add_child(cs)
			body.position = c + Vector3(0, 2.0, 0)
			add_child(body)
			_bodies.append(body)
	_apply()


func set_state(s: int) -> void:
	if s == state:
		return
	state = s
	_apply()


func _apply() -> void:
	var blocking := blocks()
	for b in _bodies:
		b.process_mode = Node.PROCESS_MODE_INHERIT if blocking else Node.PROCESS_MODE_DISABLED
		b.collision_layer = 1 if blocking else 0
	match kind:
		"pool":
			for n in _parts.values():
				n.material_override = Fx.mat(Fx.WATER_DEEP if state == 0 else Fx.MUD)
		"firewall", "bramble":
			for n in _parts.values():
				n.visible = state == 0
		"door":
			var d: Node3D = _parts["door"]
			var y := 0.6 if state == 0 else -0.65
			if is_inside_tree():
				create_tween().tween_property(d, "position:y", y, 0.4)
			else:
				d.position.y = y
		"brazier":
			_parts["flame"].visible = state == 1
		"basin":
			_parts["fill"].visible = state == 1
		"pickup":
			_parts["item"].visible = state == 1
		"exit":
			_parts["ring"].material_override = Fx.mat(Color(0.35, 0.33, 0.3) if state == 0 else Color(0.98, 0.8, 0.3))
		"chest":
			_parts["lid"].rotation.x = 0.0 if state == 0 else -1.2
			_parts["lid"].position.z = tile_center(tiles[0]).z + (0.0 if state == 0 else 0.4)


func _process(delta: float) -> void:
	if kind == "pickup" and state == 1:
		_parts["item"].rotation.y += delta * 1.5
	if kind == "firewall" and state == 0:
		var t := Time.get_ticks_msec() / 1000.0
		for n in _parts.values():
			n.scale.y = 1.0 + 0.12 * sin(t * 9.0 + n.position.x)


# ---------------- mesh helpers ----------------

func _add_part(key: String, n: Node3D) -> void:
	_parts[key] = n
	if n.get_parent() == null:
		add_child(n)


func _box(pos: Vector3, size: Vector3, color: Color, unshaded := false) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	mi.material_override = Fx.mat(color, unshaded)
	mi.position = pos
	return mi


func _cyl(pos: Vector3, r: float, h: float, color: Color) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = r
	cm.bottom_radius = r
	cm.height = h
	mi.mesh = cm
	mi.material_override = Fx.mat(color)
	mi.position = pos
	return mi


func _flat(pos: Vector3, size: Vector2, color: Color, y: float) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = size
	mi.mesh = pm
	mi.material_override = Fx.mat(color)
	mi.position = pos + Vector3(0, y, 0)
	return mi


func _sphere(pos: Vector3, r: float, color: Color) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = r
	sm.height = r * 2.0
	mi.mesh = sm
	mi.material_override = Fx.mat(color)
	mi.position = pos
	return mi


func _flame(pos: Vector3, color: Color) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = 0.32
	sm.height = 0.8
	mi.mesh = sm
	mi.material_override = Fx.mat(color, true)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.position = pos
	return mi
