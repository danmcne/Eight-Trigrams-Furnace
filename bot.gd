extends RefCounted
## Scripted player used only by --selftest. Produces Intents like any other
## input source. Its purpose is to exercise every combat path; how well it
## plays says nothing about balance.

const Intent := preload("res://intent.gd")

var _frame := 0
var _heavy_hold := 0


func poll(player: Node3D) -> Intent:
	_frame += 1
	var i := Intent.new()
	if _heavy_hold > 0:
		_heavy_hold -= 1
		i.heavy_held = true
	var pos := player.global_position
	var pr: float = player.radius
	var enemies := player.get_tree().get_nodes_in_group("enemies")

	for e in enemies:
		var th: Dictionary = e.threat_to(pos, pr)
		if th.is_empty():
			continue
		var eta: float = th["eta"]
		if th["kind"] == "red" and eta < 0.35:
			var from: Vector3 = th["from"]
			var away := pos - from
			away.y = 0.0
			if away.length() < 0.1:
				away = Vector3.RIGHT
			away = away.normalized()
			i.move = Vector2(away.x, away.z)
			i.dodge = true
			return i
		if th["kind"] == "gold" and eta < 0.15:
			i.block = true
			i.block_held = true
			return i

	var near: Node3D = null
	var best := INF
	var close := 0
	for e: Node3D in enemies:
		var dd := e.global_position.distance_to(pos)
		if dd < best:
			best = dd
			near = e
		if dd < 3.3:
			close += 1
	if near == null:
		return i
	var d := near.global_position - pos
	d.y = 0.0
	var dn := d.normalized()
	var qi: float = player.qi
	if best > 2.3:
		i.move = Vector2(dn.x, dn.z)
		if best < 4.5 and qi >= 30.0 and _frame % 15 == 0:
			i.heavy = true          # tap: thrust
	else:
		i.move = Vector2(dn.x, dn.z) * 0.3   # turn toward the target without closing in
		if close >= 3 and qi >= 40.0 and _frame % 12 == 0:
			i.heavy = true          # hold: sweep
			i.heavy_held = true
			_heavy_hold = 25
		elif _frame % 9 == 0:
			i.light = true
	return i
