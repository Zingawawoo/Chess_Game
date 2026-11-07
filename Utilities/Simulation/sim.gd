extends SceneTree
## Self-play harness: Fairy-Stockfish vs itself with powerups, using the game's own rules code.
## Usage: godot --headless --path <project> -s res://Utilities/Simulation/sim.gd -- <jobs.json> <out.jsonl> <worker> <workers>
## Test tool only - the game never loads this. Results feed the powerup balance analysis.
## Each job: {"id", "depth", "holder": "w"/"b"/"", "powerups": [{"id","v"}], "mode": "fixed"/"random", "seed"}

var g
var io: FileAccess
var pid := -1
var ini_path := ""
var var_count := 0
var engine_vars0 := 0
var last_body := ""
var last_name := "chess"
var cur_variant := "chess"
var rng := RandomNumberGenerator.new()
var specials_played := 0
const MAX_PLIES := 160
const OPENING_PLIES := 6
const CARD_DEPTH := 4


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var jobs: Array = JSON.parse_string(FileAccess.get_file_as_string(args[0]))
	# Resume: keep games already in the output file and skip those jobs.
	var skip := 0
	if FileAccess.file_exists(args[1]):
		for line in FileAccess.get_file_as_string(args[1]).split("\n", false):
			if line.strip_edges().ends_with("}"):
				skip += 1
	var out := FileAccess.open(args[1], FileAccess.READ_WRITE if skip > 0 else FileAccess.WRITE)
	if skip > 0:
		out.seek_end()
	var worker := int(args[2])
	var workers := int(args[3])
	ini_path = OS.get_user_data_dir().path_join("sim_rules_%d.ini" % worker)
	g = load("res://Scenes/Board/Main.tscn").instantiate()
	root.add_child(g)
	await process_frame
	g.eval_toggle.button_pressed = false
	g.set_process(false)
	# Headless: no frames are drawn, so freed UI nodes would pile up forever. Skip the card UI.
	for c in g.card_boxes:
		g.card_boxes[c].queue_free()
	g.card_boxes = {}
	g._on_menu_solo()
	_start_engine()
	var t0 := Time.get_ticks_msec()
	var done := 0
	for i in jobs.size():
		if i % workers != worker:
			continue
		if skip > 0:
			skip -= 1
			continue
		var job: Dictionary = jobs[i]
		var res := _play(job)
		res["job"] = job
		out.store_line(JSON.stringify(res))
		out.flush()
		done += 1
	print("worker %d done %d games in %.1fs" % [worker, done, (Time.get_ticks_msec() - t0) / 1000.0])
	_send("quit")
	OS.kill(pid)
	quit()


# ------------------------------------------------------------------ engine (blocking UCI)

func _start_engine() -> void:
	var info := OS.execute_with_pipe(g.StockfishInstaller.installed_path(), [])
	io = info["stdio"]
	pid = info["pid"]
	_send("uci")
	_send("setoption name Hash value 16")
	_send("isready")
	while true:
		if io.get_line().strip_edges() == "readyok":
			break


func _send(cmd: String) -> void:
	io.store_line(cmd)
	io.flush()


## Loads this position's powerup rules (like the game does) and returns the FEN.
func _prepare() -> String:
	var pos: Dictionary = g._fsf_position()
	var body: String = pos["body"]
	var name := "chess"
	if body != "":
		if body == last_body:
			name = last_name
		else:
			var_count += 1
			name = "simv%d" % var_count
			var f := FileAccess.open(ini_path, FileAccess.WRITE)
			f.store_string("[%s:chess]\n%s" % [name, body])
			f.close()
			_send("setoption name VariantPath value " + ini_path)
			last_body = body
			last_name = name
			cur_variant = ""
	if name != cur_variant:
		_send("setoption name UCI_Variant value " + name)
		cur_variant = name
	return pos["fen"]


## Searches the current position. Returns {"best": uci, "cp": score for side to move, "lines": [[uci, cp]...]}.
func _search(depth: int, moves: PackedStringArray, multipv := 1) -> Dictionary:
	# Positions plain chess can't contain (e.g. the side not to move in check after Convert) crash
	# or hang the engine - the game falls back to its own move choice there, so do the same.
	if not g._fen_ok():
		return _fallback_search()
	var fen := _prepare()
	_send("setoption name MultiPV value %d" % multipv)
	_send("position fen " + fen)
	var go := "go depth %d" % depth
	if not moves.is_empty():
		go += " searchmoves " + " ".join(moves)
	_send(go)
	var lines := {}
	var cp := 0
	var t0 := Time.get_ticks_msec()
	while true:
		if Time.get_ticks_msec() - t0 > 15000:
			# Engine stopped answering: restart it and carry on without its opinion.
			OS.kill(pid)
			_start_engine()
			last_body = ""
			cur_variant = "chess"
			return _fallback_search()
		var line := io.get_line().strip_edges()
		if line == "":
			continue
		if line.begins_with("info depth") and " score " in line and not ("bound" in line):
			var t := line.split(" ", false)
			var si := t.find("score")
			var v := int(t[si + 2])
			if t[si + 1] == "mate":
				v = 30000 - absi(v) * 100 if v > 0 else -30000 + absi(v) * 100
			var k := 1
			var mi := t.find("multipv")
			if mi != -1:
				k = int(t[mi + 1])
			var pi := t.find("pv")
			if pi != -1 and pi + 1 < t.size():
				lines[k] = [t[pi + 1], v]
		elif line.begins_with("bestmove"):
			var parts := line.split(" ", false)
			var best := parts[1] if parts.size() > 1 else "(none)"
			if lines.has(1):
				cp = lines[1][1]
			var arr: Array = []
			for k in lines:
				arr.append(lines[k])
			return {"best": best, "cp": cp, "lines": arr}
	return {}


## Engine-free answer: the game's own fallback move, scored by material.
func _fallback_search() -> Dictionary:
	var m: Dictionary = g._fallback_move()
	var side: String = g.turn
	var cp: int = (g._material(side) - g._material(g._opp(side))) * 100
	var uci: String = "(none)" if m.is_empty() else g._uci(m)
	return {"best": uci, "cp": cp, "lines": [[uci, cp]], "fallback": true}


# ------------------------------------------------------------------ game state snapshots

func _snap() -> Dictionary:
	return {
		"board": g.board.duplicate(), "fx": g.fx.duplicate(true), "sqfx": g.sqfx.duplicate(true),
		"cards": g.cards.duplicate(true), "score": g.score.duplicate(), "captured": g.captured.duplicate(true),
		"lost": g.lost.duplicate(true), "double_next": g.double_next.duplicate(), "castling": g.castling.duplicate(),
		"ep": g.ep_square, "turn": g.turn, "extra": g.extra.duplicate(true), "over": g.game_over,
		"portal": g.portal_count, "moves": g.move_list.duplicate(), "last": g.last_move.duplicate(),
	}


func _restore(s: Dictionary) -> void:
	g.board = s["board"].duplicate()
	g.fx = s["fx"].duplicate(true)
	g.sqfx = s["sqfx"].duplicate(true)
	g.cards = s["cards"].duplicate(true)
	g.score = s["score"].duplicate()
	g.captured = s["captured"].duplicate(true)
	g.lost = s["lost"].duplicate(true)
	g.double_next = s["double_next"].duplicate()
	g.castling = s["castling"].duplicate()
	g.ep_square = s["ep"]
	g.turn = s["turn"]
	g.extra = s["extra"].duplicate(true)
	g.game_over = s["over"]
	g.portal_count = s["portal"]
	g.move_list = s["moves"].duplicate()
	g.last_move = s["last"].duplicate()
	g.targeting = {}


# ------------------------------------------------------------------ powerups

## Gives a powerup to `side` the way the game would (card, or ability on a random eligible piece).
func _give(side: String, pu: Dictionary) -> bool:
	var id: String = pu["id"]
	if g.Powerups.is_card(id):
		if g.cards[side].size() >= g.Powerups.MAX_CARDS:
			return false
		g._exec({"t": "grant", "side": side, "id": id, "v": pu["v"].duplicate(true), "holder": "card"}, false)
		return true
	var types: String = g.Powerups.DEFS[id]["types"]
	var pieces: Array = []
	for q in 64:
		var p: String = g.board[q]
		if p != "" and p[0] == side and p[1] in types and not g.fx[q].has("ab"):
			pieces.append(q)
	if pieces.is_empty():
		return false
	var q: int = pieces[rng.randi_range(0, pieces.size() - 1)]
	g._exec({"t": "grant", "side": side, "id": id, "v": pu["v"].duplicate(true), "holder": "piece", "sq": q}, false)
	return true


## Every way to play card `slot` right now: [{"picks", "res"}], sampled down to `limit`.
func _card_options(slot: int, limit: int) -> Array:
	var side: String = g.turn
	var card: Dictionary = g.cards[side][slot]
	var id: String = card["id"]
	var v: Dictionary = card["v"]
	var opts: Array = []
	match id:
		"revive":
			var r: Dictionary = g._revive_target(side)
			if not r.is_empty():
				opts.append({"picks": [], "res": r})
		"board_change" when v.get("mode", "") not in ["choose", "pit"]:
			for i in 2:
				opts.append({"picks": [], "res": g._roll_holes(v), "random": true})
		"double_score":
			opts.append({"picks": [], "res": null})
		"best_move":
			pass  # a bot already plays the engine's best move
		_:
			g.targeting = {"slot": slot, "id": id, "v": v, "picks": []}
			var firsts: Array = []
			if id == "gain_taken":
				firsts = g._gain_choices(side)
			else:
				for q in 64:
					if g._target_valid(q):
						firsts.append(q)
			firsts.shuffle()
			var need: int = g._picks_needed(id, v)
			for a in firsts:
				if opts.size() >= limit:
					break
				if need == 1:
					var o := {"picks": [a], "res": null}
					if id == "wall":
						o["res"] = g._wall_squares(a, v)
					elif id == "freeze" and v.has("area"):
						o["res"] = g._freeze_area(a, v)
					opts.append(o)
				elif need > 2 or (need == 2 and id in ["freeze", "mine"]):
					# Several picks of the same kind: a random set of valid ones after this first.
					var seq: Array = [a]
					while seq.size() < need:
						g.targeting["picks"] = seq.duplicate()
						var nxt: Array = []
						for q in 64:
							if g._target_valid(q):
								nxt.append(q)
						if nxt.is_empty():
							break
						seq.append(nxt[randi() % nxt.size()])
					if seq.size() == need:
						opts.append({"picks": seq, "res": null})
				else:
					g.targeting["picks"] = [a]
					var seconds: Array = []
					for q in 64:
						if g._target_valid(q):
							seconds.append(q)
					seconds.shuffle()
					for b in seconds.slice(0, 3):
						opts.append({"picks": [a, b], "res": null})
			g.targeting = {}
	if id == "spin":
		# The outcome is random: score each target by the average of a few sampled outcomes.
		var spun: Array = []
		for o in opts.slice(0, 4):
			for k in 3:
				spun.append({"picks": o["picks"], "res": g._roll_spin(o["picks"][0]), "group": str(o["picks"][0])})
		opts = spun
	return opts


## Bot card policy: for each card, try its options, evaluate with the engine, and play the best one
## if it beats not playing it by a margin. Returns a list of uses for the log.
func _use_cards(depth: int, ply: int) -> Array:
	var uses: Array = []
	var side: String = g.turn
	var tries := 0
	while not g.cards[side].is_empty() and tries < 3 and not g.game_over:
		tries += 1
		var base_snap := _snap()
		var base := _search(mini(depth, CARD_DEPTH), _legal_uci())
		var base_cp: int = base["cp"]
		var best_gain := -999999.0
		var best_slot := -1
		var best_opt: Dictionary = {}
		var n_cards: int = g.cards[side].size()
		for slot in n_cards:
			_restore(base_snap)
			var card_here: Dictionary = g.cards[side][slot].duplicate(true)
			var opts := _card_options(slot, 10)
			var by_group := {}
			for o in opts:
				_restore(base_snap)
				var a := {"t": "card", "side": side, "slot": slot, "id": card_here["id"],
						"v": card_here["v"], "picks": o["picks"], "res": o["res"]}
				g._exec(a, false)
				var cp := -99999
				if not g.game_over and g.turn == side:
					cp = _search(mini(depth, CARD_DEPTH), _legal_uci())["cp"]
				elif g.game_over:
					cp = -30000 if g.turn == side else 30000
				var key: String = o.get("group", str(o["picks"]) + str(o["res"]))
				if not by_group.has(key):
					by_group[key] = {"sum": 0.0, "n": 0, "opt": o}
				by_group[key]["sum"] += cp
				by_group[key]["n"] += 1
			for key in by_group:
				var avg: float = by_group[key]["sum"] / by_group[key]["n"]
				if avg - base_cp > best_gain:
					best_gain = avg - base_cp
					best_slot = slot
					best_opt = by_group[key]["opt"]
		_restore(base_snap)
		if best_slot == -1 or best_gain < 40:
			break
		var card: Dictionary = g.cards[side][best_slot]
		var res = best_opt["res"]
		if card["id"] == "spin":
			res = g._roll_spin(best_opt["picks"][0])  # the real spin
		elif card["id"] == "board_change":
			res = g._roll_holes(card["v"])
		g._exec({"t": "card", "side": side, "slot": best_slot, "id": card["id"], "v": card["v"],
				"picks": best_opt["picks"], "res": res}, false)
		var after := 0
		if not g.game_over:
			after = _search(mini(depth, CARD_DEPTH), _legal_uci())["cp"]
		uses.append({"id": card["id"], "ply": ply, "side": side, "expected_gain": int(best_gain), "gain": after - base_cp})
	return uses


func _legal_uci() -> PackedStringArray:
	return g._uci_moves()


# ------------------------------------------------------------------ one game

func _play(job: Dictionary) -> Dictionary:
	# Fairy-Stockfish keeps every variant it has loaded, and each new one gets slower to load,
	# so start a fresh engine once it has collected a lot of them.
	if var_count - engine_vars0 > 150:
		_send("quit")
		OS.kill(pid)
		_start_engine()
		engine_vars0 = var_count
		cur_variant = "chess"
	rng.seed = int(job["seed"])
	g.rng.seed = int(job["seed"]) * 7 + 1
	var depth: int = job["depth"]
	var mode: String = job.get("mode", "fixed")
	g.powerups_on = false
	g.new_game()
	last_body = ""
	_send("ucinewgame")
	var holder: String = job.get("holder", "")
	var given: Array = []
	var given_side := {"w": [], "b": []}
	var uses: Array = []
	var ability_moves := {}
	specials_played = 0
	var t0 := Time.get_ticks_msec()
	var ply := 0
	var grants_done := false
	while not g.game_over and ply < MAX_PLIES:
		if ply == OPENING_PLIES and not grants_done:
			grants_done = true
			if mode == "random":
				g.powerups_on = true
			elif mode == "loadout":
				for side_c in ["w", "b"]:
					for pu in job["loadout_" + side_c]:
						if _give(side_c, pu):
							given_side[side_c].append(pu)
			elif holder != "":
				for pu in job["powerups"]:
					if _give(holder, pu):
						given.append(pu["id"])
		var side: String = g.turn
		if mode in ["random", "loadout"] and ply >= OPENING_PLIES and g.cards[side].size() > 0:
			uses.append_array(_use_cards(depth, ply))
		elif mode == "fixed" and side == holder and g.cards[side].size() > 0:
			uses.append_array(_use_cards(depth, ply))
		if g.game_over:
			break
		var moves := _legal_uci()
		var all_moves: Array = []
		for s in 64:
			var p: String = g.board[s]
			if p != "" and p[0] == g.turn:
				all_moves.append_array(g._moves_for_ui(s))
		if all_moves.is_empty():
			break
		var pick: Dictionary = {}
		if moves.is_empty():
			pick = all_moves[rng.randi_range(0, all_moves.size() - 1)]
		else:
			var r := _search(depth, moves, 3 if ply < OPENING_PLIES else 1)
			var uci: String = r["best"]
			if ply < OPENING_PLIES and r["lines"].size() > 1:
				# Opening variety: any of the top lines within 60 centipawns of the best.
				var ok: Array = []
				for l in r["lines"]:
					if l[1] >= r["cp"] - 60:
						ok.append(l[0])
				uci = ok[rng.randi_range(0, ok.size() - 1)]
			pick = _match(all_moves, uci)
			if pick.is_empty():
				pick = all_moves[rng.randi_range(0, all_moves.size() - 1)]
			elif ply >= OPENING_PLIES:
				var sp := _best_special(all_moves, depth, int(r["cp"]))
				if not sp.is_empty():
					pick = sp
					specials_played += 1
		if pick.has("ab"):
			ability_moves[pick["ab"]] = ability_moves.get(pick["ab"], 0) + 1
		var mover: String = g.turn
		g._exec({"t": "move", "m": pick}, false)
		if g.turn != mover or g.game_over:
			ply += 1
	# Result from White's point of view.
	var result := 0.5
	var how := "move limit"
	if g.game_over:
		if g._in_check(g._st(), g.turn):
			result = 0.0 if g.turn == "w" else 1.0
			how = "checkmate"
		else:
			how = "stalemate"
	else:
		var e := _search(8, _legal_uci())
		var cp: int = e["cp"] if g.turn == "w" else -int(e["cp"])
		if cp > 300:
			result = 1.0
		elif cp < -300:
			result = 0.0
		how = "adjudicated"
	return {
		"result_white": result, "how": how, "plies": ply, "given": given, "given_w": given_side["w"],
		"given_b": given_side["b"], "specials_played": specials_played, "uses": uses, "mem_mb": int(OS.get_static_memory_usage() / 1048576),
		"ability_moves": ability_moves, "score": g.score.duplicate(),
		"material": g._material("w") - g._material("b"), "secs": (Time.get_ticks_msec() - t0) / 1000.0,
	}


## Moves the engine can't see in its rules: ranged captures, shield attacks, and promotions before
## the last rank (Promote Early). Each is tried and scored; returns the best one if it beats the
## engine's own choice (best_cp, for the side to move), else {}.
func _best_special(moves: Array, depth: int, best_cp: int) -> Dictionary:
	var specials: Array = []
	for m in moves:
		var early_promo: bool = m.has("promo") and (int(m["to"]) >> 3) != (7 if g.turn == "w" else 0)
		if m.get("ranged", false) or m.get("bounce", false) or (early_promo and m["promo"] == "Q"):
			specials.append(m)
	if specials.is_empty():
		return {}
	var side: String = g.turn
	var snap := _snap()
	var best: Dictionary = {}
	var best_val := best_cp + 30
	for m in specials.slice(0, 6):
		_restore(snap)
		g._exec({"t": "move", "m": m}, false)
		var val := 0
		if g.game_over:
			val = 30000 if g._in_check(g._st(), g.turn) and g.turn != side else 0
		else:
			var e := _search(maxi(depth - 1, 1), _legal_uci())
			val = int(e["cp"]) if g.turn == side else -int(e["cp"])
		if val > best_val:
			best_val = val
			best = m
	_restore(snap)
	return best


static func _match(moves: Array, uci: String) -> Dictionary:
	if uci.length() < 4:
		return {}
	var fr := (uci.unicode_at(0) - 97) + (uci.unicode_at(1) - 49) * 8
	var to := (uci.unicode_at(2) - 97) + (uci.unicode_at(3) - 49) * 8
	var promo := uci.substr(4, 1).to_upper()
	for m in moves:
		if m["fr"] == fr and m["to"] == to and m.get("promo", "") == promo \
				and not m.get("ranged", false) and not m.get("bounce", false):
			return m
	for m in moves:
		if m["fr"] == fr and m["to"] == to:
			return m
	return {}
