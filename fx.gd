extends RefCounted
## Visual helpers: materials, hit flashes, telegraph markers.
## Telegraph colours carry meaning across the whole game:
##   UNBLOCKABLE (red)    -> get out of the way
##   PARRYABLE   (gold)   -> block just before impact, or get out of the way
##   HOLD        (purple) -> don't act (no attack, special or gourd); moving is fine

const UNBLOCKABLE := Color(0.8, 0.1, 0.08)
const PARRYABLE := Color(0.98, 0.76, 0.1)
const HOLD := Color(0.62, 0.32, 0.95)

## Element palette: every fire in the game is FIRE, every water is WATER, so the
## eye learns each element once. Objects are told apart by shape, not colour.
const FIRE := Color(1.0, 0.5, 0.1)
const WATER := Color(0.3, 0.58, 0.88)
const WATER_DEEP := Color(0.2, 0.38, 0.6)   # a pool: the same water, deeper
const MUD := Color(0.36, 0.3, 0.22)          # a drained pool
const TOAD_GREEN := Color(0.5, 0.65, 0.3)

## One-off effects go through play(). When hosting, main sets `relay` so each
## effect is also replayed on the clients.
static var relay: Callable


static func play(parent: Node, kind: String, args: Array) -> void:
	match kind:
		"arc":
			flash_arc(parent, args[0], args[1], args[2], args[3], args[4])
		"line":
			flash_line(parent, args[0], args[1], args[2], args[3], args[4])
		"ring":
			flash_ring(parent, args[0], args[1], args[2])
		"stream":
			stream(parent, args[0], args[1], args[2])
		"arrow":
			arrow(parent, args[0], args[1], args[2])
		"ward":
			ward(parent, args[0], args[1], args[2])
	if relay.is_valid():
		relay.call(kind, args)


static func mat(color: Color, unshaded := false) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	if color.a < 1.0:
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	if unshaded:
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	return m


static func arc_mesh(arc_deg: float, radius: float, segments := 24) -> ArrayMesh:
	var verts := PackedVector3Array()
	var half := deg_to_rad(minf(arc_deg, 360.0)) * 0.5
	for i in segments:
		var a0 := -half + 2.0 * half * float(i) / segments
		var a1 := -half + 2.0 * half * float(i + 1) / segments
		verts.append(Vector3.ZERO)
		verts.append(Vector3(-sin(a0), 0.0, -cos(a0)) * radius)
		verts.append(Vector3(-sin(a1), 0.0, -cos(a1)) * radius)
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


static func _fading(parent: Node, mesh: Mesh, color: Color, pos: Vector3, yaw: float, life: float) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	var m := mat(color, true)
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	mi.material_override = m
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(mi)
	mi.global_position = pos
	mi.rotation.y = yaw
	var tw := mi.create_tween()
	tw.tween_property(m, "albedo_color:a", 0.0, life)
	tw.tween_callback(mi.queue_free)
	return mi


## Wedge showing exactly where an arc attack connected.
static func flash_arc(parent: Node, origin: Vector3, yaw: float, arc_deg: float, radius: float, color: Color) -> void:
	_fading(parent, arc_mesh(arc_deg, radius), color, origin + Vector3(0, 0.08, 0), yaw, 0.16)


## Strip showing where a straight attack connected.
static func flash_line(parent: Node, origin: Vector3, yaw: float, length: float, width: float, color: Color) -> void:
	var bm := BoxMesh.new()
	bm.size = Vector3(width, 0.02, length)
	var fwd := Vector3(-sin(yaw), 0.0, -cos(yaw))
	_fading(parent, bm, color, origin + fwd * (length * 0.5) + Vector3(0, 0.08, 0), yaw, 0.18)


## Expanding ring (parry, guard break).
static func flash_ring(parent: Node, pos: Vector3, radius: float, color: Color) -> void:
	var torus := TorusMesh.new()
	torus.inner_radius = radius * 0.8
	torus.outer_radius = radius
	var mi := _fading(parent, torus, color, pos + Vector3(0, 1.0, 0), 0.0, 0.25)
	mi.rotation.x = PI * 0.5
	mi.create_tween().tween_property(mi, "scale", Vector3.ONE * 2.0, 0.25)


## Ground marker for an incoming area attack.
static func ground_ring(parent: Node, pos: Vector3, radius: float, color: Color) -> Node3D:
	var root := Node3D.new()
	var ring := MeshInstance3D.new()
	var torus := TorusMesh.new()
	torus.inner_radius = maxf(radius - 0.15, 0.05)
	torus.outer_radius = radius
	ring.mesh = torus
	ring.material_override = mat(Color(color, 0.9), true)
	var disc := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = radius
	cyl.bottom_radius = radius
	cyl.height = 0.02
	disc.mesh = cyl
	disc.material_override = mat(Color(color, 0.25), true)
	for mi: MeshInstance3D in [ring, disc]:
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		root.add_child(mi)
	parent.add_child(root)
	root.global_position = Vector3(pos.x, 0.05, pos.z)
	return root


## A blob travelling from one point to another (gourd drawing in or pouring out).
static func stream(parent: Node, from: Vector3, to: Vector3, color: Color) -> void:
	for k in 4:
		var mi := MeshInstance3D.new()
		var sm := SphereMesh.new()
		sm.radius = 0.28 - 0.05 * k
		sm.height = sm.radius * 2.0
		mi.mesh = sm
		mi.material_override = mat(color, true)
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		parent.add_child(mi)
		mi.global_position = from
		var tw := mi.create_tween()
		tw.tween_interval(0.04 * k)
		tw.tween_property(mi, "global_position", to, 0.22)
		tw.tween_callback(mi.queue_free)


## A fast projectile's streak from one point to another.
static func arrow(parent: Node, from: Vector3, to: Vector3, color: Color) -> void:
	var d := to - from
	if d.length() < 0.05:
		return
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(0.06, 0.06, d.length())
	mi.mesh = bm
	var m := mat(color, true)
	mi.material_override = m
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(mi)
	mi.global_position = from + d * 0.5
	mi.look_at(to, Vector3.UP if absf(d.normalized().y) < 0.99 else Vector3.RIGHT)
	var tw := mi.create_tween()
	tw.tween_property(m, "albedo_color:a", 0.0, 0.2)
	tw.tween_callback(mi.queue_free)


## A healing circle on the ground that lasts `seconds`.
static func ward(parent: Node, pos: Vector3, radius: float, seconds: float) -> void:
	var root := ground_ring(parent, pos, radius, Color(0.45, 0.9, 0.6))
	var tw := root.create_tween()
	tw.tween_interval(maxf(seconds - 0.5, 0.0))
	tw.tween_property(root, "scale", Vector3(0.05, 1.0, 0.05), 0.5)
	tw.tween_callback(root.queue_free)
