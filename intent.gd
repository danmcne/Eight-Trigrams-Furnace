extends RefCounted
## One tick of player intent. The player reads exactly one of these per physics
## tick, whatever produced it: keyboard/gamepad (local_input.gd), the self-test
## bot (bot.gd), or, from milestone 3, the network.

var move := Vector2.ZERO     # x = right, y = down the screen (toward camera)
var aim := Vector3.ZERO      # explicit aim (cursor mode); zero = facing + soft assist
var light := false           # pressed this tick
var heavy := false           # pressed this tick
var heavy_held := false
var block := false           # pressed this tick (starts the parry window)
var block_held := false
var dodge := false           # pressed this tick
var item := false            # pressed this tick (the gourd)
