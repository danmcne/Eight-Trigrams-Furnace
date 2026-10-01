extends CanvasLayer
## Health and qi bars, status lines, and the start menu.

var hp_bar: ProgressBar
var qi_bar: ProgressBar
var info: Label
var msg: Label
var _menu: Control
var _boss_box: VBoxContainer
var _console: LineEdit
var _console_out: Label
var _console_cb: Callable
var _boss_rows := []
var _ip: LineEdit
var _status: Label


func _ready() -> void:
	var box := VBoxContainer.new()
	box.position = Vector2(20, 20)
	add_child(box)
	hp_bar = ProgressBar.new()
	hp_bar.custom_minimum_size = Vector2(320, 22)
	hp_bar.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	hp_bar.show_percentage = false
	var hp_fill := StyleBoxFlat.new()
	hp_fill.bg_color = Color(0.72, 0.2, 0.16)
	hp_bar.add_theme_stylebox_override("fill", hp_fill)
	box.add_child(hp_bar)
	qi_bar = ProgressBar.new()
	qi_bar.custom_minimum_size = Vector2(320, 12)
	qi_bar.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	qi_bar.show_percentage = false
	var fill := StyleBoxFlat.new()
	fill.bg_color = Color(0.25, 0.6, 0.65)
	qi_bar.add_theme_stylebox_override("fill", fill)
	box.add_child(qi_bar)
	info = Label.new()
	box.add_child(info)
	var controls := Label.new()
	controls.text = "WASD move · J/LMB light · K/RMB heavy · L/Shift special · Space dodge · I/E gourd · F2 cursor aim · R restart · ` console (solo/host)"
	box.add_child(controls)
	_boss_box = VBoxContainer.new()   # bottom centre, clear of the text at top left
	_boss_box.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	_boss_box.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_boss_box.offset_left = -260
	_boss_box.offset_right = 260
	_boss_box.offset_bottom = -24
	add_child(_boss_box)
	msg = Label.new()
	msg.set_anchors_preset(Control.PRESET_FULL_RECT)
	msg.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	msg.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	msg.add_theme_font_size_override("font_size", 32)
	add_child(msg)


func set_bars(hp: float, max_hp: float, qi: float, max_qi: float) -> void:
	hp_bar.max_value = max_hp
	hp_bar.value = hp
	qi_bar.max_value = max_qi
	qi_bar.value = qi


## [[name, fraction], ...] for the bosses in the player's room.
func set_boss_bars(bars: Array) -> void:
	while _boss_rows.size() < bars.size():
		var name := Label.new()
		name.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		var bar := ProgressBar.new()
		bar.custom_minimum_size = Vector2(520, 14)
		bar.show_percentage = false
		bar.max_value = 1.0
		var fill := StyleBoxFlat.new()
		fill.bg_color = Color(0.8, 0.6, 0.2)
		bar.add_theme_stylebox_override("fill", fill)
		_boss_box.add_child(name)
		_boss_box.add_child(bar)
		_boss_rows.append([name, bar])
	for i in _boss_rows.size():
		var row: Array = _boss_rows[i]
		var show := i < bars.size()
		row[0].visible = show
		row[1].visible = show
		if show:
			row[0].text = bars[i][0]
			row[1].value = bars[i][1]


# ---------------- Cheat console ----------------

func console_open() -> bool:
	return _console != null and _console.visible


func toggle_console(run: Callable) -> void:
	if _console == null:
		var box := VBoxContainer.new()
		box.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
		box.grow_vertical = Control.GROW_DIRECTION_BEGIN
		box.offset_left = 20
		box.offset_bottom = -20
		add_child(box)
		_console_out = Label.new()
		box.add_child(_console_out)
		_console = LineEdit.new()
		_console.custom_minimum_size = Vector2(560, 0)
		_console.placeholder_text = "cheat (help for the list; Enter to run, ` to close)"
		_console.text_submitted.connect(func(t: String) -> void:
			_console_out.text = _console_cb.call(t)
			_console.clear())
		box.add_child(_console)
	_console_cb = run
	_console.visible = not _console.visible
	_console_out.visible = _console.visible
	if _console.visible:
		_console.clear()
		_console.grab_focus.call_deferred()
	else:
		_console.release_focus()


func flash_qi() -> void:
	qi_bar.modulate = Color(1.6, 0.4, 0.4)
	create_tween().tween_property(qi_bar, "modulate", Color.WHITE, 0.4)


const CLASS_HINTS := {
	"glaive": "Glaive — J sweeping combo · K tap thrust / hold sweep · L hold to block, press just before a hit to parry",
	"bow": "Bow — J snap shot · K hold to draw (slowed; a full draw pierces and staggers) · L kick to make room",
	"dao": "Dao — J fast combo (dodge cuts it off anytime) · K dash through enemies · L counter stance · perfect dodges pay qi",
	"scholar": "Scholar — J fan cuts, third one gusts · K tap talisman seals a toad / hold gale · L ward that heals",
}


func class_hint(c: String) -> String:
	return CLASS_HINTS.get(c, c)


## options: [[label, Callable], ...]; join is called with the typed address.
## Class buttons call pick_class with the chosen class.
func show_menu(options: Array, join: Callable, classes: Array = [], chosen := "", pick_class := Callable()) -> void:
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(center)
	_menu = center
	var panel := PanelContainer.new()
	center.add_child(panel)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 10)
	panel.add_child(v)
	var title := Label.new()
	title.text = "Furnace — prototype"
	title.add_theme_font_size_override("font_size", 28)
	v.add_child(title)
	if not classes.is_empty():
		var hint := Label.new()
		hint.custom_minimum_size.x = 620
		hint.autowrap_mode = TextServer.AUTOWRAP_WORD
		var row_c := HBoxContainer.new()
		var group := ButtonGroup.new()
		for c: String in classes:
			var cb := Button.new()
			cb.text = c.capitalize()
			cb.toggle_mode = true
			cb.button_group = group
			cb.button_pressed = c == chosen
			cb.pressed.connect(func() -> void:
				pick_class.call(c)
				hint.text = class_hint(c))
			row_c.add_child(cb)
		v.add_child(row_c)
		hint.text = class_hint(chosen)
		v.add_child(hint)
	var first: Button = null
	for opt: Array in options:
		var b := Button.new()
		b.text = opt[0]
		b.pressed.connect(opt[1])
		v.add_child(b)
		if first == null:
			first = b
	var row := HBoxContainer.new()
	_ip = LineEdit.new()
	_ip.placeholder_text = "host's address, e.g. 192.168.1.20"
	_ip.custom_minimum_size.x = 280
	row.add_child(_ip)
	var b_join := Button.new()
	b_join.text = "Join"
	b_join.pressed.connect(func() -> void: join.call(_ip.text.strip_edges()))
	row.add_child(b_join)
	v.add_child(row)
	_status = Label.new()
	v.add_child(_status)
	if first:
		first.grab_focus()


func hide_menu() -> void:
	if _menu:
		_menu.queue_free()
	_menu = null
	_status = null


func set_status(text: String) -> void:
	if _status:
		_status.text = text
	else:
		msg.text = text
