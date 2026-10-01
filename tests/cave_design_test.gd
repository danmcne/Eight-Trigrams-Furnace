extends SceneTree
## Design checks on the Reed Marsh map: it can be finished, and no state a
## player can reach makes it unfinishable.
## Run: godot --headless --path . -s tests/cave_design_test.gd

const Solver := preload("res://tests/cave_solver.gd")


func _initialize() -> void:
	var s := Solver.new()
	s.load_map(FileAccess.get_file_as_string("res://levels/reed_marsh.txt"))
	var r := s.solve()
	print("states explored: %d, winning states: %d" % [r["states"], r["goal_count"]])
	var failures := 0
	if r["goal_count"] == 0:
		print("FAIL  the exit cannot be reached")
		failures += 1
	else:
		print("PASS  the exit can be reached (shortest plan: %d actions)" % r["plan"].size())
	if r["stuck"].is_empty():
		print("PASS  no soft-locks: the exit stays reachable from every reachable state")
	else:
		print("FAIL  %d reachable states can no longer reach the exit, e.g. %s" % [r["stuck"].size(), s.key(r["all"][r["stuck"][0]])])
		failures += 1
	for a: Dictionary in r["plan"]:
		var what := ""
		if a.has("prop"):
			var pr: Dictionary = s.props[a["prop"]]
			what = "%s at %s" % [pr["kind"], pr["tiles"][0]]
		elif a.has("group"):
			what = "toads in room %d" % s.groups[a["group"]]["room"]
		print("   ", a["do"], " ", what, (" (%s)" % ["", "water", "fire", "toad"][a["what"]]) if a.has("what") else "")
	print("%d failure(s)" % failures)
	quit(1 if failures else 0)
