extends "res://bosses/silver_king.gd"
## Clever Devil, one of the two little demons the Horned Kings send out with
## the gourd. He calls your name with it (PURPLE: don't act), a gentler version
## of what the Silver King does in the hall, so the cave teaches the rule
## before it matters most. He has no fan; he keeps away and calls.


func _init() -> void:
	super._init()
	kind = "clever"
	boss_name = "Clever Devil"
	radius = 0.55
	max_hp = 110.0
	speed = 5.5
	fans = false
	CALL_TIME = 1.9          # longer: easier to read the first time
	CALL_COOLDOWN = 5.5
	CALL_COOLDOWN_ENRAGED = 3.5
	TRAP_TIME = 2.0
	TRAP_DPS = 5.0
	SHAKE_LOOSE = 20.0
	FLUSTERED = 1.8
	KEEP_MIN = 4.0
	KEEP_MAX = 7.0
	_base_color = Color(0.55, 0.62, 0.72)


func _build_body() -> void:
	var cm := CapsuleMesh.new()
	cm.radius = radius
	cm.height = radius * 3.0
	_part(cm, Vector3(0, radius * 1.5, 0), _mat)
	_horns(radius * 3.05, Color(0.85, 0.85, 0.8))
	# He carries the Purple-Gold Gourd.
	for part: Array in [[0.0, 0.2], [0.3, 0.14]]:
		var sm := SphereMesh.new()
		sm.radius = part[1]
		sm.height = part[1] * 2.0
		_part(sm, Vector3(-radius - 0.1, 1.0 + part[0], -0.1), Fx.mat(Color(0.72, 0.35, 0.12)))
	var vm := CylinderMesh.new()   # stands in for the vase node the call animation raises
	vm.top_radius = 0.01
	vm.bottom_radius = 0.01
	vm.height = 0.01
	_vase = _part(vm, Vector3(-radius, 1.25, 0), _mat)
	_fan = MeshInstance3D.new()
	_vis.add_child(_fan)
