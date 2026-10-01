extends RefCounted
## A class kit: everything that makes one class play differently.
## The player (player.gd) owns what all classes share: movement, dodge, health,
## qi, the gourd, networking. A kit owns its light attack, heavy attack, the
## special on the block button, and its weapon's look.
##
## While a kit's move runs, the player is in its ACTION state and calls tick()
## every physics tick; tick() returns false when the move is over.
## `p.pose` (three floats) is the only kit state sent to clients: show() must
## draw the weapon from it alone.

var p: CharacterBody3D

## True when the special is held (the glaive's block) rather than pressed; its
## press then leaves the input buffer alone instead of queuing "special".
var special_is_held := false


## Per-class numbers the player uses.
func stats() -> Dictionary:
	return {"hp": 100.0, "speed": 7.0, "dodge_cooldown": 0.35, "qi_regen": 6.0}


func build(_root: Node3D) -> void:
	pass


## From a free state. Look at p.buffer / p.intent; start a move and return true,
## or return false to let the player do something else.
func neutral() -> bool:
	return false


func tick(_delta: float) -> bool:
	return false


## Every simulation tick, whatever the state (timers).
func pre_tick(_delta: float) -> void:
	pass


## A hit is arriving. Return "" to let it land normally, or a result
## ("blocked", "parried", "countered") if the kit dealt with it.
func intercept(_damage: float, _push: Vector3, _source: Node3D, _blockable: bool) -> String:
	return ""


func on_perfect_dodge() -> void:
	pass


## Called on every peer each frame: draw the weapon from p.pose.
func show(_delta: float) -> void:
	pass
