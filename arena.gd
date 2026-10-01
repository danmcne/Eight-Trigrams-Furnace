extends RefCounted
## The placeholder marsh: light, ground, stone rim, pools and reeds.

const Fx := preload("res://fx.gd")
const HALF := 22.0   # half-width of the playable square


static func build(parent: Node3D) -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.83, 0.81, 0.73)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.78, 0.77, 0.72)
	env.ambient_light_energy = 0.7
	env.fog_enabled = true
	env.fog_light_color = Color(0.83, 0.81, 0.73)
	env.fog_density = 0.008
	var we := WorldEnvironment.new()
	we.environment = env
	parent.add_child(we)

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-55, 35, 0)
	sun.shadow_enabled = true
	parent.add_child(sun)

	var size := HALF * 2.0 + 4.0
	var ground := StaticBody3D.new()
	var gs := CollisionShape3D.new()
	var gb := BoxShape3D.new()
	gb.size = Vector3(size, 1.0, size)
	gs.shape = gb
	gs.position.y = -0.5
	ground.add_child(gs)
	var gm := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(size, size)
	gm.mesh = plane
	gm.material_override = Fx.mat(Color(0.55, 0.57, 0.43))
	ground.add_child(gm)
	parent.add_child(ground)

	for i in 4:
		var horizontal := i < 2
		var s := -1.0 if i % 2 == 0 else 1.0
		var wall := StaticBody3D.new()
		var ws := CollisionShape3D.new()
		var wb := BoxShape3D.new()
		var drawn := Vector3(HALF * 2.0 + 2.0, 1.2, 1.0) if horizontal else Vector3(1.0, 1.2, HALF * 2.0 + 2.0)
		wb.size = Vector3(drawn.x, 4.0, drawn.z)   # collides higher than drawn: nothing lands on the rim
		ws.shape = wb
		ws.position.y = 1.4
		wall.add_child(ws)
		var wm := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = drawn
		wm.mesh = bm
		wm.material_override = Fx.mat(Color(0.38, 0.37, 0.34))
		wall.add_child(wm)
		wall.position = Vector3(0, 0.6, s * (HALF + 0.5)) if horizontal else Vector3(s * (HALF + 0.5), 0.6, 0)
		parent.add_child(wall)

	# Decorative, no collision; fixed seed so every peer sees the same marsh.
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	for i in 6:
		var pool := MeshInstance3D.new()
		var cyl := CylinderMesh.new()
		var r := rng.randf_range(2.0, 4.5)
		cyl.top_radius = r
		cyl.bottom_radius = r
		cyl.height = 0.02
		pool.mesh = cyl
		pool.material_override = Fx.mat(Color(0.36, 0.45, 0.47))
		pool.position = Vector3(rng.randf_range(-HALF + 4, HALF - 4), 0.01, rng.randf_range(-HALF + 4, HALF - 4))
		parent.add_child(pool)
	var reed_mat := Fx.mat(Color(0.47, 0.5, 0.3))
	for c in 14:
		var center := Vector3(rng.randf_range(-HALF + 1, HALF - 1), 0, rng.randf_range(-HALF + 1, HALF - 1))
		for j in 9:
			var reed := MeshInstance3D.new()
			var rb := BoxMesh.new()
			var h := rng.randf_range(0.8, 1.8)
			rb.size = Vector3(0.05, h, 0.05)
			reed.mesh = rb
			reed.material_override = reed_mat
			reed.position = center + Vector3(rng.randf_range(-0.8, 0.8), h * 0.5, rng.randf_range(-0.8, 0.8))
			reed.rotation.z = rng.randf_range(-0.15, 0.15)
			parent.add_child(reed)
