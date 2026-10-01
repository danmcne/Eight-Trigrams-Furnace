extends Node3D
## The session (milestone 4): pick a level, then play solo, host or join.
## Levels: "reed_marsh" (the first dungeon) or "arena" (waves of toads, for
## tuning combat).
##
## The host (solo counts as a host with nobody connected) simulates everything.
## Each tick it sends one snapshot to the clients; each client sends back one
## intent packet for its own player. Clients simulate nothing: they place what
## the snapshot describes and draw it.
##
## Command line (after `--`): --host | --join ADDRESS, --level NAME, --class NAME,
## --selftest, --frames N.

const PlayerScript := preload("res://player.gd")
const ToadScript := preload("res://toad.gd")
const BOSSES := {"golden": preload("res://bosses/golden_king.gd"), "silver": preload("res://bosses/silver_king.gd"),
	"clever": preload("res://bosses/clever_devil.gd"), "wily": preload("res://bosses/wily_worm.gd")}
const Intent := preload("res://intent.gd")
const LocalInput := preload("res://local_input.gd")
const RemoteInput := preload("res://remote_input.gd")
const Bot := preload("res://bot.gd")
const Fx := preload("res://fx.gd")
const Arena := preload("res://arena.gd")
const Dungeon := preload("res://dungeon.gd")
const Hud := preload("res://hud.gd")

const PORT := 24565
const MAX_PLAYERS := 4
const CAMERA_OFFSET := Vector3(0, 15, 11)
const WAVES := [
	{"small": 3, "big": 0},
	{"small": 5, "big": 0},
	{"small": 4, "big": 1},
	{"small": 7, "big": 2},
]
const EXTRA_TOADS_PER_PLAYER := 0.6   # each extra player adds 60% more small toads...
const EXTRA_HP_PER_PLAYER := 0.5      # ...and 50% more big-toad health
const REVIVE_RANGE := 1.8
const REVIVE_TIME := 3.0
const PLAYER_COLORS := [Color(0.55, 0.16, 0.12), Color(0.16, 0.3, 0.6), Color(0.2, 0.45, 0.2), Color(0.55, 0.42, 0.1)]
const SNAP_CHANNEL := 1   # unreliable traffic kept off the reliable channel

var players := {}          # peer id -> player
var toads := {}            # net id -> enemy (toads and bosses)
var local_player: CharacterBody3D
var camera: Camera3D
var hud: Hud
var level: Node3D
var level_name := ""
var dungeon: Dungeon        # set when the level is a dungeon
var wave := 0
var kills := 0
var message := ""

var _started := false
var _chosen_class := "glaive"
var _wards := []           # host: {owner, pos, r, until, heal}
var _time := 0.0
var _is_host := true
var _input_source          # this machine's source: LocalInput or Bot
var _local: LocalInput     # set when the source is the keyboard (for F2)
var _press_counts := [0, 0, 0, 0, 0]   # client: light, heavy, dodge, block, item
var _next_toad_id := 1
var _between_waves := false
var _gen := 0              # bumped by a reset, so a pending wave timer knows it is stale
var _host_note := ""

var _selftest := false
var _frames_limit := 3600
var _frames := 0
var _snapshots := 0
var _toads_seen := 0
var _toads_died_seen := 0
var _largest_snapshot := 0


func _ready() -> void:
	Engine.time_scale = 1.0
	var args := OS.get_cmdline_user_args()
	_selftest = "--selftest" in args
	var fi := args.find("--frames")
	if fi >= 0 and fi + 1 < args.size():
		_frames_limit = int(args[fi + 1])
	_setup_input()
	var ci := args.find("--class")
	if ci >= 0 and ci + 1 < args.size() and args[ci + 1] in PlayerScript.CLASSES:
		_chosen_class = args[ci + 1]
	var li := args.find("--level")
	var chosen := args[li + 1] if li >= 0 and li + 1 < args.size() else ("arena" if _selftest else "reed_marsh")
	camera = Camera3D.new()
	camera.fov = 40.0
	add_child(camera)
	camera.look_at_from_position(CAMERA_OFFSET, Vector3.ZERO)
	hud = Hud.new()
	add_child(hud)

	var ji := args.find("--join")
	if "--host" in args:
		_start_host(chosen)
	elif ji >= 0 and ji + 1 < args.size():
		_start_client(args[ji + 1])
	elif _selftest:
		_start_solo(chosen)
	else:
		hud.show_menu([
			["Play solo — Reed Marsh cave", _start_solo.bind("reed_marsh")],
			["Play solo — toad arena", _start_solo.bind("arena")],
			["Host a LAN game — Reed Marsh cave (port %d)" % PORT, _start_host.bind("reed_marsh")],
			["Host a LAN game — toad arena", _start_host.bind("arena")],
		], _start_client, PlayerScript.CLASSES, _chosen_class, func(c: String) -> void: _chosen_class = c)


# ---------------- Sessions ----------------

func _make_input_source() -> Object:
	if _selftest:
		return Bot.new()
	_local = LocalInput.new()
	_local.camera = camera
	return _local


func _start_solo(name: String) -> void:
	hud.hide_menu()
	_is_host = true
	_input_source = _make_input_source()
	_build_level(name)
	_spawn_player(multiplayer.get_unique_id(), _chosen_class)
	_started = true
	_populate_level()


func _start_host(name: String) -> void:
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_server(PORT, MAX_PLAYERS - 1)
	if err != OK:
		hud.set_status("Could not host on port %d (error %d)" % [PORT, err])
		if _selftest:
			get_tree().quit(1)
		return
	multiplayer.multiplayer_peer = peer
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	Fx.relay = _relay_fx
	var addrs := []
	for a in IP.get_local_addresses():
		if a.count(".") == 3 and not a.begins_with("127.") and not a.begins_with("169.254."):
			addrs.append(a)
	_host_note = "Hosting on %s, port %d" % [", ".join(addrs) if addrs else "this machine", PORT]
	_start_solo(name)


func _start_client(address: String) -> void:
	if address.is_empty():
		hud.set_status("Enter the host's address first.")
		return
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_client(address, PORT)
	if err != OK:
		hud.set_status("Could not start a connection (error %d)" % err)
		return
	multiplayer.multiplayer_peer = peer
	_is_host = false
	_input_source = _make_input_source()
	multiplayer.connected_to_server.connect(_on_connected)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_gone)
	hud.set_status("Connecting to %s…" % address)


func _on_connected() -> void:
	hud.hide_menu()
	_started = true
	_rpc_hello.rpc_id(1, _chosen_class)


func _on_connection_failed() -> void:
	multiplayer.multiplayer_peer = null
	hud.set_status("Could not reach the host.")
	if _selftest:
		print("CLIENT could not connect")
		get_tree().quit(1)


func _on_server_gone() -> void:
	if _selftest:
		_finish_selftest()
		return
	multiplayer.multiplayer_peer = null
	get_tree().reload_current_scene()


func _networked() -> bool:
	return not multiplayer.get_peers().is_empty()


# ---------------- Levels ----------------

func _build_level(name: String) -> void:
	if level:
		remove_child(level)
		level.queue_free()
	level = null
	dungeon = null
	level_name = name
	if name == "arena":
		level = Node3D.new()
		add_child(level)
		Arena.build(level)
	else:
		dungeon = Dungeon.new()
		dungeon.host = self
		add_child(dungeon)
		dungeon.load_map(FileAccess.get_file_as_string("res://levels/%s.txt" % name))
		level = dungeon


## Host: first enemies of a fresh level.
func _populate_level() -> void:
	if dungeon:
		var n := maxi(players.size(), 1)
		var extra := 1.0 + EXTRA_HP_PER_PLAYER * (n - 1)
		var bosses_by_link := {}
		for sp: Dictionary in dungeon.enemy_spawns:
			var kind: String = sp["kind"]
			var e := _make_enemy(kind, sp["pos"], sp["link"], 1.0 if kind == "toad" else extra)
			if BOSSES.has(kind):
				if not bosses_by_link.has(sp["link"]):
					bosses_by_link[sp["link"]] = []
				bosses_by_link[sp["link"]].append(e)
		# Bosses sharing a link are siblings: when one falls, the others rage.
		for group: Array in bosses_by_link.values():
			for a in group:
				for b in group:
					if a != b:
						a.sibling = b
	else:
		_next_wave()


func _make_toad(pos: Vector3, big: bool, link: int, hp_scale: float) -> CharacterBody3D:
	return _make_enemy("big_toad" if big else "toad", pos, link, hp_scale)


## Any enemy by kind: toad, big_toad, golden, silver.
static func new_enemy(kind: String, seed_value: int, hp_scale: float) -> CharacterBody3D:
	if BOSSES.has(kind):
		var b: CharacterBody3D = BOSSES[kind].new()
		b.setup(seed_value, hp_scale)
		return b
	var t: CharacterBody3D = ToadScript.new()
	t.setup(kind == "big_toad", seed_value, hp_scale)
	return t


static func kind_of(e: Node) -> String:
	if "boss_name" in e:
		return e.kind
	return "big_toad" if e.big else "toad"


func _make_enemy(kind: String, pos: Vector3, link: int, hp_scale: float) -> CharacterBody3D:
	var t := new_enemy(kind, _next_toad_id, hp_scale)
	t.net_id = _next_toad_id
	_next_toad_id += 1
	t.died.connect(_on_toad_died)
	if dungeon:
		t.sight = dungeon.can_see
		t.clear_line = dungeon.clear_line
		t.step_toward = dungeon.step_toward
		t.home_rooms = dungeon.rooms_at(pos)
		t.rooms_at = dungeon.rooms_at
		dungeon.register_toad(t.net_id, link)
	t.position = pos
	add_child(t)   # enters the world already at its spawn point
	toads[t.net_id] = t
	if _networked():
		_rpc_spawn_enemy.rpc(t.net_id, kind, t.position, t.max_hp)
	return t


## Called by the dungeon when a toad is flung from the gourd.
func spawn_toad(pos: Vector3, dazed: bool) -> void:
	var t := _make_toad(Vector3(pos.x, 0.1, pos.z), false, -1, 1.0)
	if dazed:
		t.daze(1.5)


func _on_item_used(p: Node3D, dir: Vector3) -> void:
	if dungeon:
		dungeon.gourd_use(p, dir)


# ---------------- Host: peers ----------------

func _on_peer_connected(id: int) -> void:
	# Tell the newcomer the level and everything in it, then add its player.
	_rpc_level.rpc_id(id, level_name)
	for pid: int in players:
		var p: CharacterBody3D = players[pid]
		_rpc_spawn_player.rpc_id(id, pid, p.global_position, PLAYER_COLORS.find(p.color), PlayerScript.CLASSES.find(p.kit_name))
	for tid: int in toads:
		var t: CharacterBody3D = toads[tid]
		_rpc_spawn_enemy.rpc_id(id, tid, kind_of(t), t.global_position, t.max_hp)
	_update_hitstop()
	# The newcomer's own character is spawned when it says which class it plays (_rpc_hello).


func _on_peer_disconnected(id: int) -> void:
	if _selftest and players.has(id):
		print("SELFTEST player %d (remote, %s) left: hp=%.0f paths=%s" % [id, players[id].kit_name, players[id].hp, players[id].stats])
	if players.has(id):
		players[id].queue_free()
		players.erase(id)
		_rpc_despawn_player.rpc(id)
	_update_hitstop()


func _update_hitstop() -> void:
	var solo := not _networked()
	for p: CharacterBody3D in players.values():
		p.allow_hitstop = solo
	if not solo:
		Engine.time_scale = 1.0


func _relay_fx(kind: String, args: Array) -> void:
	if _networked():
		_rpc_fx.rpc(kind, args)


# ---------------- Host: spawning ----------------

func _spawn_player(pid: int, class_name_: String, at := Vector3.INF, color_index := -1) -> CharacterBody3D:
	var p: CharacterBody3D = PlayerScript.new()
	p.peer_id = pid
	p.kit_name = class_name_ if class_name_ in PlayerScript.CLASSES else "glaive"
	p.world = self
	p.color = PLAYER_COLORS[(color_index if color_index >= 0 else players.size()) % PLAYER_COLORS.size()]
	p.position = _spawn_point_near_players() if at == Vector3.INF else at
	if pid == multiplayer.get_unique_id():
		p.input_source = _input_source
		_adopt_local(p)
	else:
		p.input_source = RemoteInput.new()
	p.item_used.connect(_on_item_used)
	add_child(p)
	players[pid] = p
	return p


func _spawn_point_near_players() -> Vector3:
	var anchor := dungeon.start if dungeon else Vector3.ZERO
	for p: CharacterBody3D in players.values():
		if not p.is_dead():
			anchor = p.global_position
			break
	return Vector3(anchor.x + 1.2 * players.size(), 0.1, anchor.z)


func _adopt_local(p: CharacterBody3D) -> void:
	local_player = p
	p.health_changed.connect(func(_h: float, _m: float) -> void: _refresh_bars())
	p.qi_changed.connect(func(_q: float, _m: float) -> void: _refresh_bars())
	p.qi_denied.connect(hud.flash_qi)
	_refresh_bars.call_deferred()


func _refresh_bars() -> void:
	if local_player:
		hud.set_bars(local_player.hp, local_player.max_hp, local_player.qi, local_player.max_qi)


func _next_wave() -> void:
	wave += 1
	message = ""
	var spec: Dictionary = WAVES[mini(wave - 1, WAVES.size() - 1)]
	var n := maxi(players.size(), 1)
	var small: int = ceili(int(spec["small"]) * (1.0 + EXTRA_TOADS_PER_PLAYER * (n - 1)))
	var big_count: int = spec["big"]
	var big_hp := 1.0 + EXTRA_HP_PER_PLAYER * (n - 1)
	var center := _players_center()
	var rng := RandomNumberGenerator.new()
	rng.seed = wave * 101
	for i in small + big_count:
		var is_big := i >= small
		var a := rng.randf() * TAU
		var r := rng.randf_range(10.0, 15.0)
		var p := center + Vector3(cos(a), 0, sin(a)) * r
		var lim := Arena.HALF - 2.0
		_make_toad(Vector3(clampf(p.x, -lim, lim), 0.1, clampf(p.z, -lim, lim)), is_big, -1, big_hp if is_big else 1.0)


func _players_center() -> Vector3:
	var sum := Vector3.ZERO
	var n := 0
	for p: CharacterBody3D in players.values():
		if not p.is_dead():
			sum += p.global_position
			n += 1
	return sum / n if n > 0 else Vector3.ZERO


func _on_toad_died(t: Node) -> void:
	kills += 1
	toads.erase(t.net_id)
	if dungeon:
		dungeon.toad_gone(t.net_id)
	if _networked():
		_rpc_toad_died.rpc(t.net_id)


func _all_down() -> bool:
	if players.is_empty():
		return false
	for p: CharacterBody3D in players.values():
		if not p.is_dead():
			return false
	return true


## Host: start the level over for everyone.
func _reset_level() -> void:
	_gen += 1
	_between_waves = false
	for t: CharacterBody3D in toads.values():
		if _networked():
			_rpc_toad_died.rpc(t.net_id)
		t.despawn()
	toads.clear()
	_build_level(level_name)
	if _networked():
		_rpc_level.rpc(level_name)
	var i := 0
	var anchor := dungeon.start if dungeon else Vector3.ZERO
	for p: CharacterBody3D in players.values():
		p.global_position = anchor + Vector3(1.2 * i, 0.1, 0)
		p.revive(1.0)
		p.has_gourd = false
		p.gourd = 0
		i += 1
	wave = 0
	kills = 0
	message = ""
	_wards.clear()
	_populate_level()


# ---------------- Host: per-tick ----------------

func _physics_process(delta: float) -> void:
	if not _started:
		return
	_frames += 1
	_time += delta
	if _is_host:
		_revive_tick(delta)
		_ward_tick(delta)
		if dungeon:
			_dungeon_tick(delta)
		else:
			_wave_tick()
		_broadcast_snapshot()
	else:
		_send_intent()
	if _selftest and (_frames >= _frames_limit or (_is_host and not _networked() and _all_down())):
		_finish_selftest()


## Wards heal standing players inside them; one ward per owner.
func add_ward(owner: Node3D, pos: Vector3, r: float, seconds: float, heal_per_s: float) -> void:
	_wards = _wards.filter(func(w: Dictionary) -> bool: return w["owner"] != owner)
	_wards.append({"owner": owner, "pos": pos, "r": r, "until": _time + seconds, "heal": heal_per_s})
	Fx.play(self, "ward", [pos, r, seconds])


func _ward_tick(delta: float) -> void:
	_wards = _wards.filter(func(w: Dictionary) -> bool: return w["until"] > _time)
	for w: Dictionary in _wards:
		var c: Vector3 = w["pos"]
		for p: CharacterBody3D in players.values():
			if Vector2(p.global_position.x - c.x, p.global_position.z - c.z).length() <= w["r"]:
				p.heal(w["heal"] * delta)


## How far a straight shot from `from` along `dir` travels before a wall.
func ray_length(from: Vector3, dir: Vector3, max_length: float) -> float:
	var s := 0.5
	while s < max_length:
		var q := from + dir * s
		if dungeon:
			if dungeon._solid_at(q):
				return maxf(s - 0.25, 0.0)
		elif absf(q.x) > Arena.HALF or absf(q.z) > Arena.HALF:
			return maxf(s - 0.25, 0.0)
		s += 0.25
	return max_length


## Cheat: play another class on the spot, keeping health (as a fraction), qi,
## the gourd and its contents, the vase and peaches.
func _switch_class(c: String) -> String:
	if not c in PlayerScript.CLASSES:
		return "classes: " + ", ".join(PlayerScript.CLASSES)
	if local_player == null or local_player.kit_name == c:
		return "already " + c
	var old := local_player
	var keep := {"pos": old.global_position, "frac": old.hp / old.max_hp, "qi": old.qi, "gourd": old.has_gourd,
		"slots": old.gourd_slots, "held": old.held(), "peaches": old.peaches, "god": old.god, "color": PLAYER_COLORS.find(old.color)}
	players.erase(old.peer_id)
	old.queue_free()
	local_player = null
	_chosen_class = c
	var p := _spawn_player(multiplayer.get_unique_id(), c, keep["pos"], keep["color"])
	p.set_peaches(keep["peaches"])
	p.has_gourd = keep["gourd"]
	p.gourd_slots = keep["slots"]
	p.set_held(keep["held"])
	p.god = keep["god"]
	p.hp = p.max_hp * keep["frac"]
	p.qi = keep["qi"]
	p.health_changed.emit(p.hp, p.max_hp)
	p.qi_changed.emit(p.qi, p.max_qi)
	if _networked():
		_rpc_spawn_player.rpc(p.peer_id, keep["pos"], keep["color"], PlayerScript.CLASSES.find(c))
	return "now playing " + c


# ---------------- Cheats (solo or host) ----------------

const CHEAT_HELP := "god · heal · class NAME · give gourd|vase|peach · kill · open · warp start|demons|kings|exit|X Y · help"


func _cheat(text: String) -> String:
	var w := text.strip_edges().to_lower().split(" ", false)
	if w.is_empty() or local_player == null:
		return ""
	var p := local_player
	match w[0]:
		"help":
			return CHEAT_HELP
		"god":
			p.god = not p.god
			return "god mode " + ("on" if p.god else "off")
		"heal":
			if p.is_dead():
				p.revive(1.0)
			p.hp = p.max_hp
			p.qi = p.max_qi
			p.health_changed.emit(p.hp, p.max_hp)
			p.qi_changed.emit(p.qi, p.max_qi)
			return "healed"
		"class":
			return _switch_class(w[1] if w.size() > 1 else "")
		"give":
			match w[1] if w.size() > 1 else "":
				"gourd":
					p.has_gourd = true
					return "gourd given"
				"vase":
					p.has_gourd = true
					p.gourd_slots = 2
					return "vase given: two chambers"
				"peach":
					p.add_peach()
					return "peach eaten: max health %.0f" % p.max_hp
			return "give gourd|vase|peach"
		"kill":
			var n := 0
			for e in toads.values():
				if not e.is_dead() and (dungeon == null or dungeon.share_room(e.global_position, p.global_position)):
					e.take_hit(1.0e6, Vector3.ZERO)
					n += 1
			return "killed %d" % n
		"open":
			if dungeon == null:
				return "no doors here"
			for pr in dungeon.props:
				if pr.kind == "door":
					pr.set_state(1)
			return "all doors open"
		"warp":
			return _warp(w.slice(1))
	return "unknown: " + text + "   (" + CHEAT_HELP + ")"


func _warp(args: PackedStringArray) -> String:
	if dungeon == null or args.is_empty():
		return "warp start|demons|kings|exit|X Y (dungeon only)"
	var to := Vector3.INF
	match args[0]:
		"start":
			to = dungeon.start
		"demons", "gourd":
			for pr in dungeon.props:
				if pr.kind == "pickup" and pr.item == "gourd":
					to = pr.point_near(Vector3.ZERO) + Vector3(-2.0, 0, 0)
		"kings", "boss":
			for sp: Dictionary in dungeon.enemy_spawns:
				if sp["kind"] == "golden":
					to = sp["pos"] + Vector3(-8.0, 0, 0)
		"exit":
			for pr in dungeon.props:
				if pr.kind == "exit":
					to = pr.point_near(Vector3.ZERO) + Vector3(-2.0, 0, 0)
		_:
			if args.size() >= 2 and args[0].is_valid_int() and args[1].is_valid_int():
				to = Vector3(int(args[0]) * 2.0 + 1.0, 0, int(args[1]) * 2.0 + 1.0)
	if to == Vector3.INF:
		return "unknown place"
	local_player.global_position = Vector3(to.x, 0.1, to.z)
	local_player.velocity = Vector3.ZERO
	return "warped"


## A downed player stands up after an ally has stayed beside them for REVIVE_TIME.
func _revive_tick(delta: float) -> void:
	for p: CharacterBody3D in players.values():
		if not p.is_dead():
			continue
		var helped := false
		for q: CharacterBody3D in players.values():
			if q != p and not q.is_dead() and q.global_position.distance_to(p.global_position) <= REVIVE_RANGE:
				helped = true
		var rate := delta / REVIVE_TIME
		p.revive_progress = clampf(p.revive_progress + (rate if helped else -rate), 0.0, 1.0)
		if p.revive_progress >= 1.0:
			p.revive(0.5)


func _dungeon_tick(delta: float) -> void:
	var standing := []
	for p: CharacterBody3D in players.values():
		if not p.is_dead():
			standing.append(p)
	dungeon.tick(standing, delta)
	if _all_down():
		message = "All fallen — host presses R to restart" if _networked() else "Fallen in the cave — press R to restart"
	elif dungeon.cleared:
		message = "The Horned Kings are defeated. The Reed Marsh cave is cleared."
	else:
		message = ""


func _wave_tick() -> void:
	if _between_waves:
		return
	if _all_down():
		message = "All fallen — host presses R to restart" if _networked() else "Fallen in the marsh — press R to restart"
		return
	if toads.is_empty():
		_between_waves = true
		message = "Wave %d cleared" % wave
		var gen := _gen
		await get_tree().create_timer(1.5).timeout
		if gen != _gen:
			return
		_between_waves = false
		if not _all_down():
			_next_wave()


func _broadcast_snapshot() -> void:
	if not _networked():
		return
	var b := StreamPeerBuffer.new()
	b.put_u16(wave)
	b.put_u32(kills)
	b.put_utf8_string(message)
	b.put_u8(players.size())
	for p: CharacterBody3D in players.values():
		p.write_net(b)
	b.put_u16(toads.size())
	for t: CharacterBody3D in toads.values():
		# Each entry: id, then a length byte, so a reader can skip what it doesn't know.
		b.put_u32(t.net_id)
		var at := b.get_position()
		b.put_u8(0)
		var body := StreamPeerBuffer.new()
		t.write_net(body)
		var bytes := body.data_array.slice(4)   # write_net starts with the id
		b.seek(at)
		b.put_u8(bytes.size())
		b.put_data(bytes)
	if dungeon:
		dungeon.write_net(b)
	else:
		b.put_u16(0)
	_rpc_snapshot.rpc(b.data_array)
	_largest_snapshot = maxi(_largest_snapshot, b.data_array.size())


# ---------------- Client: per-tick ----------------

func _send_intent() -> void:
	if local_player == null or _input_source == null:
		return
	var i: Intent = _input_source.poll(local_player)
	if i.light:
		_press_counts[0] += 1
	if i.heavy:
		_press_counts[1] += 1
	if i.dodge:
		_press_counts[2] += 1
	if i.block:
		_press_counts[3] += 1
	if i.item:
		_press_counts[4] += 1
	_rpc_intent.rpc_id(1, [i.move, i.aim, _press_counts[0], _press_counts[1], _press_counts[2], _press_counts[3], _press_counts[4], i.heavy_held, i.block_held])


# ---------------- RPCs ----------------

@rpc("any_peer", "call_remote", "unreliable_ordered", SNAP_CHANNEL)
func _rpc_intent(packet: Array) -> void:
	var pid := multiplayer.get_remote_sender_id()
	if players.has(pid) and RemoteInput.valid(packet):
		players[pid].input_source.latest = packet


@rpc("authority", "call_remote", "unreliable_ordered", SNAP_CHANNEL)
func _rpc_snapshot(data: PackedByteArray) -> void:
	_snapshots += 1
	var b := StreamPeerBuffer.new()
	b.data_array = data
	wave = b.get_u16()
	kills = b.get_u32()
	message = b.get_utf8_string()
	for k in b.get_u8():
		var pid := b.get_u32()
		if players.has(pid):
			players[pid].read_net(b)
		else:
			b.seek(b.get_position() + PlayerScript.BYTES_AFTER_ID)
	for k in b.get_u16():
		var tid := b.get_u32()
		var length := b.get_u8()
		var start := b.get_position()
		if toads.has(tid):
			toads[tid].read_net(b)
		b.seek(start + length)
	if dungeon:
		dungeon.read_net(b)


@rpc("authority", "call_remote", "reliable")
func _rpc_level(name: String) -> void:
	for t: CharacterBody3D in toads.values():
		t.queue_free()
	toads.clear()
	_build_level(name)


@rpc("any_peer", "call_remote", "reliable")
func _rpc_hello(class_name_: String) -> void:
	var pid := multiplayer.get_remote_sender_id()
	if not _is_host or players.has(pid):
		return
	var np := _spawn_player(pid, class_name_)
	_rpc_spawn_player.rpc(pid, np.global_position, PLAYER_COLORS.find(np.color), PlayerScript.CLASSES.find(np.kit_name))


@rpc("authority", "call_remote", "reliable")
func _rpc_spawn_player(pid: int, pos: Vector3, color_index: int, class_index: int) -> void:
	if players.has(pid):
		players[pid].queue_free()
		players.erase(pid)
	var p: CharacterBody3D = PlayerScript.new()
	p.authority = false
	p.kit_name = PlayerScript.CLASSES[clampi(class_index, 0, PlayerScript.CLASSES.size() - 1)]
	p.peer_id = pid
	p.color = PLAYER_COLORS[maxi(color_index, 0) % PLAYER_COLORS.size()]
	p.position = pos
	add_child(p)
	players[pid] = p
	if pid == multiplayer.get_unique_id():
		_adopt_local(p)


@rpc("authority", "call_remote", "reliable")
func _rpc_despawn_player(pid: int) -> void:
	if players.has(pid):
		players[pid].queue_free()
		players.erase(pid)


@rpc("authority", "call_remote", "reliable")
func _rpc_spawn_enemy(tid: int, kind: String, pos: Vector3, max_hp: float) -> void:
	if toads.has(tid):
		return
	var t := new_enemy(kind, tid, 1.0)
	t.max_hp = max_hp
	t.authority = false
	t.net_id = tid
	t.position = pos
	add_child(t)
	toads[tid] = t
	_toads_seen += 1


@rpc("authority", "call_remote", "reliable")
func _rpc_toad_died(tid: int) -> void:
	if toads.has(tid):
		toads[tid].net_die()
		toads.erase(tid)
		_toads_died_seen += 1


@rpc("authority", "call_remote", "unreliable")
func _rpc_fx(kind: String, args: Array) -> void:
	Fx.play(self, kind, args)


# ---------------- Frame: camera, HUD, keys ----------------

func _process(delta: float) -> void:
	if not _started:
		return
	if Input.is_action_just_pressed("restart") and _is_host and not hud.console_open():
		_reset_level()
	if _local and not _local.blocked and Input.is_action_just_pressed("toggle_aim"):
		_local.cursor_aim = not _local.cursor_aim
	if Input.is_action_just_pressed("console") and _is_host:
		hud.toggle_console(_cheat)
	if _local:
		_local.blocked = hud.console_open()
	if local_player:
		var target := local_player.global_position + CAMERA_OFFSET
		camera.global_position = camera.global_position.lerp(target, 1.0 - exp(-6.0 * delta))
	var aim := "cursor" if _local and _local.cursor_aim else "facing + assist"
	var line := ""
	if dungeon:
		line = "Reed Marsh cave · toads defeated %d · players %d · aim: %s" % [kills, players.size(), aim]
		if local_player and local_player.has_gourd:
			line += "\nGourd: %s  (I/E to use)" % ["empty", "water", "fire", "a toad"][clampi(local_player.gourd, 0, 3)]
	else:
		line = "Wave %d · toads left %d · kills %d · players %d · aim: %s" % [wave, toads.size(), kills, players.size(), aim]
	if local_player:
		line += "\n" + hud.class_hint(local_player.kit_name)
	if _host_note:
		line += "\n" + _host_note
	hud.info.text = line
	var shown := message
	var bars := []
	var called := false

	for e in toads.values():
		if not ("boss_name" in e) or e.is_dead():
			continue
		if dungeon and local_player and not dungeon.share_room(e.global_position, local_player.global_position):
			continue
		bars.append([e.boss_name + ("  (enraged)" if e.enraged else ""), e.hp / e.max_hp])
		if local_player and e.aux == local_player.peer_id and e.aux != 0:
			called = true
	hud.set_boss_bars(bars)
	if local_player and local_player.is_trapped():
		shown = "Inside the jade vase! An ally can shake you loose by striking the Silver King."
	elif called:
		shown = "The Silver King calls your name. Don't answer: no attacks, special or gourd. Moving is fine."
	elif local_player and local_player.is_dead() and players.size() > 1 and not _all_down():
		shown = "Downed — an ally standing beside you revives you (%d%%)" % int(local_player.revive_progress * 100.0)
	hud.msg.text = shown


# ---------------- Input map ----------------

func _setup_input() -> void:
	var keys := {
		"move_up": [KEY_W, KEY_UP], "move_down": [KEY_S, KEY_DOWN],
		"move_left": [KEY_A, KEY_LEFT], "move_right": [KEY_D, KEY_RIGHT],
		"light": [KEY_J], "heavy": [KEY_K], "block": [KEY_L, KEY_SHIFT],
		"dodge": [KEY_SPACE], "restart": [KEY_R], "toggle_aim": [KEY_F2], "item": [KEY_I, KEY_E],
		"console": [KEY_QUOTELEFT],
	}
	for action: String in keys:
		if not InputMap.has_action(action):
			InputMap.add_action(action, 0.25)
		for k: Key in keys[action]:
			var ev := InputEventKey.new()
			ev.physical_keycode = k
			InputMap.action_add_event(action, ev)
	_mouse("light", MOUSE_BUTTON_LEFT)
	_mouse("heavy", MOUSE_BUTTON_RIGHT)
	_joy_button("light", JOY_BUTTON_X)
	_joy_button("heavy", JOY_BUTTON_Y)
	_joy_button("dodge", JOY_BUTTON_A)
	_joy_button("block", JOY_BUTTON_RIGHT_SHOULDER)
	_joy_button("item", JOY_BUTTON_LEFT_SHOULDER)
	_joy_button("restart", JOY_BUTTON_START)
	_joy_axis("move_left", JOY_AXIS_LEFT_X, -1.0)
	_joy_axis("move_right", JOY_AXIS_LEFT_X, 1.0)
	_joy_axis("move_up", JOY_AXIS_LEFT_Y, -1.0)
	_joy_axis("move_down", JOY_AXIS_LEFT_Y, 1.0)


func _mouse(action: String, button: MouseButton) -> void:
	var ev := InputEventMouseButton.new()
	ev.button_index = button
	InputMap.action_add_event(action, ev)


func _joy_button(action: String, button: JoyButton) -> void:
	var ev := InputEventJoypadButton.new()
	ev.button_index = button
	InputMap.action_add_event(action, ev)


func _joy_axis(action: String, axis: JoyAxis, sign_value: float) -> void:
	var ev := InputEventJoypadMotion.new()
	ev.axis = axis
	ev.axis_value = sign_value
	InputMap.action_add_event(action, ev)


# ---------------- --selftest ----------------

func prop_states() -> String:
	if not dungeon:
		return ""
	var out := ""
	for pr in dungeon.props:
		out += str(pr.state)
	return out


func _finish_selftest() -> void:
	if _is_host:
		var mode := "host" if multiplayer.multiplayer_peer is ENetMultiplayerPeer else "solo"
		print("SELFTEST %s done: frames=%d wave=%d kills=%d players=%d largest_snapshot=%d bytes" % [mode, _frames, wave, kills, players.size(), _largest_snapshot])
		for pid: int in players:
			var p: CharacterBody3D = players[pid]
			var who := "local" if pid == multiplayer.get_unique_id() else "remote"
			print("SELFTEST player %d (%s, %s): hp=%.0f downed=%s paths=%s" % [pid, who, p.kit_name, p.hp, p.is_dead(), p.stats])
	else:
		print("CLIENT done: frames=%d snapshots=%d players_seen=%d toads_spawned=%d toads_died=%d own_hp=%s wave=%d kills=%d" % [
			_frames, _snapshots, players.size(), _toads_seen, _toads_died_seen,
			("%.0f" % local_player.hp) if local_player else "none", wave, kills])
		if dungeon:
			print("CLIENT props=%s" % prop_states())
	get_tree().quit(0)
