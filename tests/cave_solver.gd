extends RefCounted
## Abstract model of a dungeon map, for design checks.
## Explores every state a player can reach (which props are changed, which
## toad groups are beaten, what the gourd holds) and answers two questions:
## can the exit be reached, and can it still be reached from every one of
## those states (no soft-locks)? It also returns a shortest plan, which the
## walkthrough test plays in the real game.

const Dungeon := preload("res://dungeon.gd")
const REACH := 2.25        # gourd reach in tiles (dungeon.GOURD_RANGE / tile size)
const CHEST_REACH := 1.15  # dungeon.CHEST_RANGE / tile size
const DIRS: Array[Vector2i] = [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]

var terrain: PackedStringArray
var links: PackedStringArray
var rooms := {}
var props: Array = []      # same order as Dungeon builds them
var groups: Array = []     # toads grouped by (room, link): {tiles, link, room}
var start := Vector2i.ZERO
var exit_tile := Vector2i.ZERO
var exit_link := -1


func load_map(text: String) -> void:
	var m := Dungeon.parse(text)
	terrain = m["terrain"]
	links = m["links"]
	rooms = Dungeon.compute_rooms(terrain)
	var seen := {}
	var group_of := {}
	for y in terrain.size():
		for x in terrain[y].length():
			var c := terrain[y][x]
			var p := Vector2i(x, y)
			if c == "S":
				start = p
			elif c == "X":
				exit_tile = p
				exit_link = _link(x, y)
			if Dungeon.ENEMIES.has(c):
				var key := "%d:%d" % [rooms[p], _link(x, y)]
				if not group_of.has(key):
					group_of[key] = groups.size()
					groups.append({"tiles": [], "link": _link(x, y), "room": rooms[p]})
				groups[group_of[key]]["tiles"].append(p)
			if not Dungeon.KINDS.has(c) or seen.has(p):
				continue
			var prop := {"kind": Dungeon.KINDS[c], "item": Dungeon.PICKUPS.get(c, ""), "tiles": [], "link": _link(x, y), "rooms": {}, "init": 1 if c == "B" else 0}
			if c in Dungeon.REGIONS:
				var stack := [p]
				seen[p] = true
				while not stack.is_empty():
					var q: Vector2i = stack.pop_back()
					prop["tiles"].append(q)
					for d in DIRS:
						var n := q + d
						if _in(n) and not seen.has(n) and terrain[n.y][n.x] == c:
							seen[n] = true
							stack.append(n)
			else:
				seen[p] = true
				prop["tiles"].append(p)
			for t: Vector2i in prop["tiles"]:
				if rooms.has(t):
					prop["rooms"][rooms[t]] = true
				for d in DIRS:
					if rooms.has(t + d):
						prop["rooms"][rooms[t + d]] = true
			props.append(prop)


func _link(x: int, y: int) -> int:
	return int(links[y][x]) if y < links.size() and x < links[y].length() and links[y][x].is_valid_int() else -1


func _in(p: Vector2i) -> bool:
	return p.y >= 0 and p.y < terrain.size() and p.x >= 0 and p.x < terrain[p.y].length()


# ---------------- State ----------------
# {"p": prop states, "g": groups beaten, "has": has the gourd, "slots": 1 or 2,
#  "hold": gourd contents, oldest first}

func initial() -> Dictionary:
	var ps := []
	for pr in props:
		ps.append(pr["init"])
	var gs := []
	for g in groups:
		gs.append(0)
	return {"p": ps, "g": gs, "has": 0, "slots": 1, "hold": []}


func key(s: Dictionary) -> String:
	return "%s|%s|%d|%d|%s" % [str(s["p"]), str(s["g"]), s["has"], s["slots"], str(s["hold"])]


func door_open(s: Dictionary, link: int, except := -1) -> bool:
	for i in props.size():
		if i == except:
			continue
		var pr: Dictionary = props[i]
		if pr["link"] == link and pr["kind"] in ["brazier", "basin", "chest"] and s["p"][i] != 1:
			return false
	for i in groups.size():
		if groups[i]["link"] == link and s["g"][i] == 0:
			return false
	return true


func passable(s: Dictionary, t: Vector2i) -> bool:
	if not _in(t):
		return false
	var c := terrain[t.y][t.x]
	if c == "#" or c in ["b", "B", "E", "U", "C"]:
		return false
	if c in ["D", "~", "F", "T"]:
		for i in props.size():
			if t in props[i]["tiles"]:
				if c == "D":
					return door_open(s, props[i]["link"])
				return s["p"][i] == 1
	return true


func reach(s: Dictionary) -> Dictionary:
	var seen := {start: true}
	var stack := [start]
	while not stack.is_empty():
		var q: Vector2i = stack.pop_back()
		for d in DIRS:
			var n := q + d
			if not seen.has(n) and passable(s, n):
				seen[n] = true
				stack.append(n)
	return seen


func usable_from(pr: Dictionary, r: Dictionary, dist: float) -> bool:
	for t: Vector2i in r:
		if not pr["rooms"].has(rooms.get(t, -1)):
			continue
		for pt: Vector2i in pr["tiles"]:
			if Vector2(t - pt).length() <= dist:
				return true
	return false


## What a prop offers the gourd, and what it becomes afterwards (game rules).
func _offer(k: String, st: int) -> Array:
	if k == "pool" and st == 0:
		return [Dungeon.WATER, 1]
	if k == "spring":
		return [Dungeon.WATER, st]
	if k == "brazier" and st == 1:
		return [Dungeon.FIRE, 0]
	if k == "eternal":
		return [Dungeon.FIRE, st]
	return [Dungeon.EMPTY, st]


func _accept(k: String, st: int, w: int) -> int:
	if w == Dungeon.FIRE and (k == "brazier" or k == "bramble") and st == 0:
		return 1
	if w == Dungeon.WATER and (k == "firewall" or k == "basin") and st == 0:
		return 1
	if w == Dungeon.WATER and k == "brazier" and st == 1:
		return 0
	return -1


## All (action, next state) pairs from a state.
func moves(s: Dictionary) -> Array:
	var out := []
	var r := reach(s)
	for i in groups.size():
		if s["g"][i] == 0:
			for t: Vector2i in groups[i]["tiles"]:
				if r.has(t):
					var n := s.duplicate(true)
					n["g"][i] = 1
					out.append([{"do": "toads", "group": i}, n])
					break
	var hold: Array = s["hold"]
	var room_left: bool = s["has"] == 1 and hold.size() < s["slots"]
	for i in props.size():
		var pr: Dictionary = props[i]
		var st: int = s["p"][i]
		var k: String = pr["kind"]
		if k == "pickup":
			var tile: Vector2i = pr["tiles"][0]
			if st != 2 and r.has(tile) and door_open(s, pr["link"], i):
				var n := s.duplicate(true)
				n["p"][i] = 2
				match pr["item"]:
					"gourd":
						n["has"] = 1
						n["hold"] = []
					"vase":
						n["has"] = 1
						n["slots"] = 2
				out.append([{"do": "pickup", "prop": i}, n])
			continue
		if k == "chest" and st == 0 and usable_from(pr, r, CHEST_REACH):
			var n := s.duplicate(true)
			n["p"][i] = 1
			n["has"] = 1
			n["hold"] = []
			out.append([{"do": "chest", "prop": i}, n])
		if s["has"] == 0 or not usable_from(pr, r, REACH):
			continue
		var offer := _offer(k, st)
		if room_left and offer[0] != Dungeon.EMPTY:
			# With room in the gourd, facing something that offers means drawing it in.
			var n := s.duplicate(true)
			n["p"][i] = offer[1]
			n["hold"].append(offer[0])
			out.append([{"do": "take", "prop": i, "what": offer[0], "hold": n["hold"]}, n])
			continue
		for w: int in hold:
			var after := _accept(k, st, w)
			if after >= 0:
				var n := s.duplicate(true)
				n["p"][i] = after
				n["hold"].erase(w)
				out.append([{"do": "give", "prop": i, "what": w, "hold": n["hold"]}, n])
				break
	if not hold.is_empty():
		var n := s.duplicate(true)
		n["hold"].pop_front()
		out.append([{"do": "splash", "hold": n["hold"]}, n])
	return out


func is_goal(s: Dictionary) -> bool:
	return reach(s).has(exit_tile) and (exit_link < 0 or door_open(s, exit_link))


## Explore everything. Returns {states, goal_count, stuck: [keys], plan: [actions]}.
func solve() -> Dictionary:
	var s0 := initial()
	var index := {key(s0): 0}
	var states := [s0]
	var parent := [-1]
	var via := [null]
	var edges := [[]]
	var goals := []
	var i := 0
	while i < states.size():
		var s: Dictionary = states[i]
		if is_goal(s):
			goals.append(i)
		else:
			for mv: Array in moves(s):
				var k := key(mv[1])
				if not index.has(k):
					index[k] = states.size()
					states.append(mv[1])
					parent.append(i)
					via.append(mv[0])
					edges.append([])
				edges[i].append(index[k])
		i += 1
	# States from which some goal is reachable: walk edges backwards from goals.
	var rev := []
	for j in states.size():
		rev.append([])
	for j in states.size():
		for k2: int in edges[j]:
			rev[k2].append(j)
	var ok := {}
	var stack := goals.duplicate()
	for g: int in goals:
		ok[g] = true
	while not stack.is_empty():
		var j: int = stack.pop_back()
		for p: int in rev[j]:
			if not ok.has(p):
				ok[p] = true
				stack.append(p)
	var stuck := []
	for j in states.size():
		if not ok.has(j):
			stuck.append(j)
	var plan := []
	if not goals.is_empty():
		var j: int = goals[0]
		while parent[j] >= 0:
			plan.push_front(via[j])
			j = parent[j]
	return {"states": states.size(), "goal_count": goals.size(), "stuck": stuck, "plan": plan, "all": states}
