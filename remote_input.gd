extends RefCounted
## Host-side input source for a remote player: turns the latest intent packet
## from that client into an Intent.
##
## Packets travel unreliably, so presses are sent as running counts rather than
## one-tick flags: a lost packet cannot swallow a press, because the next packet
## still carries the higher count.
## Packet: [move: Vector2, aim: Vector3, light_n, heavy_n, dodge_n, block_n, item_n, heavy_held, block_held]

const Intent := preload("res://intent.gd")
const SIZE := 9

var latest: Array = []
var _seen := [0, 0, 0, 0, 0]


static func valid(packet: Array) -> bool:
	return packet.size() == SIZE and typeof(packet[0]) == TYPE_VECTOR2 and typeof(packet[1]) == TYPE_VECTOR3


func poll(_player: Node3D) -> Intent:
	var i := Intent.new()
	if not valid(latest):
		return i
	var mv: Vector2 = latest[0]
	i.move = mv.limit_length(1.0)
	var aim: Vector3 = latest[1]
	i.aim = aim.normalized() if aim.length() > 0.01 else Vector3.ZERO
	var counts := [int(latest[2]), int(latest[3]), int(latest[4]), int(latest[5]), int(latest[6])]
	i.light = counts[0] > _seen[0]
	i.heavy = counts[1] > _seen[1]
	i.dodge = counts[2] > _seen[2]
	i.block = counts[3] > _seen[3]
	i.item = counts[4] > _seen[4]
	_seen = counts
	i.heavy_held = bool(latest[7])
	i.block_held = bool(latest[8])
	return i
