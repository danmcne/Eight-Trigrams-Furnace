extends RefCounted
## Turns keyboard, mouse and gamepad state into an Intent each tick.

const Intent := preload("res://intent.gd")

var cursor_aim := false      # optional: attacks aim at the mouse cursor
var blocked := false         # the console is open: the keyboard is typing, not playing
var camera: Camera3D


func poll(player: Node3D) -> Intent:
	var i := Intent.new()
	if blocked:
		return i
	i.move = Input.get_vector("move_left", "move_right", "move_up", "move_down")
	i.light = Input.is_action_just_pressed("light")
	i.heavy = Input.is_action_just_pressed("heavy")
	i.heavy_held = Input.is_action_pressed("heavy")
	i.block = Input.is_action_just_pressed("block")
	i.block_held = Input.is_action_pressed("block")
	i.dodge = Input.is_action_just_pressed("dodge")
	i.item = Input.is_action_just_pressed("item")
	if cursor_aim and camera:
		var mp := camera.get_viewport().get_mouse_position()
		var from := camera.project_ray_origin(mp)
		var dir := camera.project_ray_normal(mp)
		if absf(dir.y) > 0.001:
			var d := from + dir * (-from.y / dir.y) - player.global_position
			d.y = 0.0
			if d.length() > 0.2:
				i.aim = d.normalized()
	return i
