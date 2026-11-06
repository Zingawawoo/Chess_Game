extends Node2D
## Top-down 2D chess using the "Pixel Chess" asset pack by Dani Maccari.
## Two players on one machine, or play against Stockfish. Click or drag to move.

const UciEngine := preload("res://uci_engine.gd")

const ASSET := "res://Assets/pixel chess_v1.2/"
const SQ := 16          # square size in board pixels
const OFF := 7          # where the squares start inside the board image
const BOARD_PX := 142   # board image size
const BORDER_COL := Color8(89, 96, 112)
const LIGHT_COL := Color8(234, 240, 216)
const SHEET_ORDER := ["P", "N", "R", "B", "Q", "K"]  # order in the sprite sheets
const PROMO_CHOICES := ["Q", "R", "B", "N"]

# Evaluation bar, in board pixels (the board image starts at x = 0, so the bar sits to its left).
const BAR_X := -14      # left edge of the bar's 1px frame
const BAR_W := 8        # width inside the frame; its height is the 8 squares
const BAR_BLACK := Color8(36, 40, 52)
const EVAL_DEPTH := 14      # search depth used to evaluate positions when Stockfish isn't the one moving
const EVAL_MIN_DEPTH := 8   # shallower scores are too noisy to show on the bar

# Captured pieces are shown in a row above and below the board, at half the size of board pieces.
# Half size only stays crisp at an even board scale, so _layout() keeps the scale even.
const CAP_H := 8        # row height (a captured piece is 8x8 board pixels)
const CAP_GAP := 2      # space between the board and a captured row
const CAP_ORDER := ["P", "N", "B", "R", "Q"]
const PIECE_VALUE := {"P": 1, "N": 3, "B": 3, "R": 5, "Q": 9, "K": 0}

const KNIGHT_OFFS := [Vector2i(1, 2), Vector2i(2, 1), Vector2i(-1, 2), Vector2i(-2, 1),
		Vector2i(1, -2), Vector2i(2, -1), Vector2i(-1, -2), Vector2i(-2, -1)]
const KING_OFFS := [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1),
		Vector2i(1, 1), Vector2i(1, -1), Vector2i(-1, 1), Vector2i(-1, -1)]
const ROOK_DIRS := [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]
const BISHOP_DIRS := [Vector2i(1, 1), Vector2i(1, -1), Vector2i(-1, 1), Vector2i(-1, -1)]

var tex_board: Texture2D
var tex_white: Texture2D
var tex_black: Texture2D
var cursor_imgs: Array[Image] = []
var cursor_state := -1

# Game state. board[rank * 8 + file], rank 0 = rank 1. "" or e.g. "wP", "bK".
var board: Array = []
var turn := "w"
var castling := {}
var ep_square := -1
var last_move: Array = []
var game_over := false

# UI state
var flipped := false
var selected := -1
var selected_moves: Array = []
var dragging := false
var drag_pos := Vector2.ZERO
var promo_pending: Dictionary = {}

# Stockfish opponent. While enabled, the human plays human_color and the engine the other side.
var engine: UciEngine
var engine_enabled := false
var engine_depth := 10
var human_color := "w"
var move_list := PackedStringArray()  # every move so far in UCI notation, sent to the engine
var pos_version := 0          # bumps whenever the position changes
var analyzed_version := -1    # position that has been (or is being) searched
var search_for_move := false  # the running search is Stockfish choosing a move, not just evaluating
var search_turn := "w"        # side to move in the running search (engine scores are relative to it)

# Evaluation bar. eval_target / eval_display are White's share of the bar, 0..1.
var eval_enabled := false
var eval_target := 0.5
var eval_display := 0.5
var eval_text := ""
var eval_white_ahead := true

# captured["w"] = the black pieces White has taken so far (e.g. "bP"), sorted pawn -> queen.
var captured := {"w": [], "b": []}
var cap_labels := {}  # colour -> Label showing that side's material lead ("+3")

var status_label: Label
var engine_toggle: CheckButton
var eval_toggle: CheckButton
var eval_label: Label


func _ready() -> void:
	tex_board = load(ASSET + "boards/board_plain_01.png")
	tex_white = load(ASSET + "16x16 pieces/WhitePieces.png")
	tex_black = load(ASSET + "16x16 pieces/BlackPieces.png")
	_load_cursors()
	_build_ui()
	get_viewport().size_changed.connect(_layout)
	_layout()
	new_game()
	eval_toggle.button_pressed = true  # on by default; reports an error if Stockfish is missing


func _build_ui() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	var bar := HBoxContainer.new()
	bar.position = Vector2(12, 12)
	bar.add_theme_constant_override("separation", 12)
	layer.add_child(bar)

	var swap := Button.new()
	swap.text = "Swap Colors"
	swap.focus_mode = Control.FOCUS_NONE
	swap.pressed.connect(_swap_colors)
	bar.add_child(swap)

	var reset := Button.new()
	reset.text = "New Game"
	reset.focus_mode = Control.FOCUS_NONE
	reset.pressed.connect(new_game)
	bar.add_child(reset)

	engine_toggle = CheckButton.new()
	engine_toggle.text = "Play vs Stockfish"
	engine_toggle.focus_mode = Control.FOCUS_NONE
	engine_toggle.toggled.connect(_set_engine_enabled)
	bar.add_child(engine_toggle)

	var depth_label := Label.new()
	depth_label.text = "Depth"
	bar.add_child(depth_label)

	var depth_box := SpinBox.new()
	depth_box.min_value = 1
	depth_box.max_value = 20
	depth_box.step = 1
	depth_box.rounded = true
	depth_box.value = engine_depth
	depth_box.tooltip_text = "How many plies Stockfish searches ahead. Higher is stronger but slower."
	depth_box.value_changed.connect(func(v: float): engine_depth = int(v))
	bar.add_child(depth_box)

	eval_toggle = CheckButton.new()
	eval_toggle.text = "Eval bar"
	eval_toggle.focus_mode = Control.FOCUS_NONE
	eval_toggle.toggled.connect(_set_eval_enabled)
	bar.add_child(eval_toggle)

	status_label = Label.new()
	status_label.add_theme_font_size_override("font_size", 20)
	bar.add_child(status_label)

	# The score readout sits on the bar at the leading side's end. It lives in screen space
	# (not in the pixel-art canvas) so the text stays sharp; _update_eval_label positions it.
	eval_label = Label.new()
	eval_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	eval_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	eval_label.visible = false
	layer.add_child(eval_label)

	# "+N" material lead, next to the captured pieces of whichever side is ahead.
	for c in ["w", "b"]:
		var lead := Label.new()
		lead.add_theme_color_override("font_color", LIGHT_COL)
		lead.mouse_filter = Control.MOUSE_FILTER_IGNORE
		lead.visible = false
		layer.add_child(lead)
		cap_labels[c] = lead


func _layout() -> void:
	var vs := get_viewport_rect().size
	var top := 56.0
	# Leave room on both sides for the eval bar so the board stays centred whether it is shown or not.
	var width_px := BOARD_PX - 2 * BAR_X
	var rows := CAP_H + CAP_GAP  # captured-piece rows above and below the board
	var height_px := BOARD_PX + 2 * rows
	var fit := minf(vs.x / width_px, (vs.y - top - 8.0) / height_px)
	var s := maxf(2.0, floorf(fit / 2.0) * 2.0)
	scale = Vector2(s, s)
	position = Vector2(floorf((vs.x - BOARD_PX * s) / 2.0),
			top + floorf((vs.y - top - height_px * s) / 2.0) + rows * s)
	_update_eval_label()
	_update_captured_ui()


func _load_cursors() -> void:
	var tex: Texture2D = load(ASSET + "cursor.png")
	var img := tex.get_image()
	if img == null:
		return
	if img.is_compressed():
		img.decompress()
	for i in 3:
		var c := img.get_region(Rect2i(i * 16, 0, 16, 16))
		c.resize(48, 48, Image.INTERPOLATE_NEAREST)
		cursor_imgs.append(c)


func _update_cursor() -> void:
	if cursor_imgs.size() < 3:
		return
	var state := 0
	if dragging:
		state = 2
	elif promo_pending.is_empty() and not game_over and _human_turn():
		var d := _mouse_disp()
		if d.x >= 0:
			var p: String = board[_disp_to_sq(d)]
			if p != "" and p[0] == turn:
				state = 1
	if state == cursor_state:
		return
	cursor_state = state
	var hotspot := Vector2(18, 6) if state == 0 else Vector2(24, 24)
	Input.set_custom_mouse_cursor(cursor_imgs[state], Input.CURSOR_ARROW, hotspot)


# ---------------------------------------------------------------- game setup

func new_game() -> void:
	board = []
	board.resize(64)
	board.fill("")
	var back := ["R", "N", "B", "Q", "K", "B", "N", "R"]
	for f in 8:
		board[f] = "w" + back[f]
		board[8 + f] = "wP"
		board[48 + f] = "bP"
		board[56 + f] = "b" + back[f]
	turn = "w"
	castling = {"wK": true, "wQ": true, "bK": true, "bQ": true}
	ep_square = -1
	last_move = []
	move_list.clear()
	captured = {"w": [], "b": []}
	game_over = false
	selected = -1
	selected_moves = []
	dragging = false
	promo_pending = {}
	pos_version += 1
	_cancel_search()
	if engine != null:
		engine.new_game()
	eval_target = 0.5
	eval_display = 0.5
	eval_text = ""
	eval_white_ahead = true
	_update_eval_label()
	_update_captured_ui()
	_update_status()
	queue_redraw()


# ---------------------------------------------------------------- captured pieces

func _material(c: String) -> int:
	var total := 0
	for p in board:
		if p != "" and p[0] == c:
			total += PIECE_VALUE[p[1]]
	return total


## x of each piece in c's captured row (board pixels). Same kinds overlap, kinds are spaced apart.
func _captured_xs(c: String) -> Array:
	var xs := []
	var x := float(OFF)
	var prev := ""
	for p in captured[c]:
		if prev != "":
			x += 4.0 if p == prev else CAP_H + 1.0
		xs.append(x)
		prev = p
	return xs


## Row y (board pixels): the bottom player's captures sit under the board, the top player's above it.
func _captured_row_y(c: String) -> float:
	var bottom := "b" if flipped else "w"
	return BOARD_PX + CAP_GAP if c == bottom else -(CAP_H + CAP_GAP)


## Positions the "+N" labels. They are screen-space Labels so the text stays sharp.
func _update_captured_ui() -> void:
	if cap_labels.is_empty():
		return
	var s := scale.x
	for c in ["w", "b"]:
		var lead := _material(c) - _material(_opp(c))
		var lbl: Label = cap_labels[c]
		lbl.visible = lead > 0
		if lead <= 0:
			continue
		lbl.text = "+%d" % lead
		lbl.add_theme_font_size_override("font_size", roundi(CAP_H * s * 0.4))
		lbl.reset_size()
		var xs := _captured_xs(c)
		var end_x: float = (xs.back() + CAP_H) if not xs.is_empty() else float(OFF)
		lbl.position = Vector2(position.x + (end_x + 3.0) * s,
				position.y + _captured_row_y(c) * s + (CAP_H * s - lbl.size.y) / 2.0)


func _draw_captured() -> void:
	for c in ["w", "b"]:
		var y := _captured_row_y(c)
		var xs := _captured_xs(c)
		for i in xs.size():
			_draw_piece(captured[c][i], Rect2(xs[i], y, CAP_H, CAP_H))


# ---------------------------------------------------------------- stockfish

func _human_turn() -> bool:
	return not engine_enabled or turn == human_color


## Swap Colors: flips the board, and against Stockfish also trades sides with it.
func _swap_colors() -> void:
	flipped = not flipped
	if engine_enabled:
		human_color = _opp(human_color)
		_cancel_search()
		_clear_selection()
		_update_status()
	_update_eval_label()
	_update_captured_ui()
	queue_redraw()


func _clear_selection() -> void:
	selected = -1
	selected_moves = []
	dragging = false
	promo_pending = {}


## Creates the engine on first use and makes sure its process is running.
## Returns "" on success, otherwise an error message.
func _ensure_engine() -> String:
	if engine == null:
		engine = UciEngine.new()
		engine.bestmove.connect(_on_engine_bestmove)
		engine.evaluation.connect(_on_engine_eval)
		engine.failed.connect(_on_engine_failed)
		add_child(engine)
	return engine.start()


## Abandons whatever the engine is searching; the position will be searched again if needed.
func _cancel_search() -> void:
	if engine != null:
		engine.cancel()
	analyzed_version = -1


func _set_engine_enabled(on: bool) -> void:
	if on:
		var err := _ensure_engine()
		if err != "":
			engine_toggle.set_pressed_no_signal(false)
			_update_status()
			status_label.text = err
			return
		# The human plays whichever side currently faces them.
		human_color = "b" if flipped else "w"
		engine_enabled = true
	else:
		engine_enabled = false
		_cancel_search()
	_clear_selection()
	_update_status()
	queue_redraw()


func _set_eval_enabled(on: bool) -> void:
	if on:
		var err := _ensure_engine()
		if err != "":
			eval_toggle.set_pressed_no_signal(false)
			_update_status()
			status_label.text = err
			return
		eval_enabled = true
		analyzed_version = -1
	else:
		eval_enabled = false
		if engine != null and not search_for_move:
			_cancel_search()  # only stop an evaluation, never Stockfish's move
	_update_eval_label()
	queue_redraw()


func _on_engine_failed(reason: String) -> void:
	engine_enabled = false
	eval_enabled = false
	engine_toggle.set_pressed_no_signal(false)
	eval_toggle.set_pressed_no_signal(false)
	_update_eval_label()
	_update_status()
	status_label.text = reason
	queue_redraw()


func _start_search(depth: int, for_move: bool) -> void:
	search_for_move = for_move
	search_turn = turn
	analyzed_version = pos_version
	engine.think(move_list, depth)


## Engine scores are from the side to move's point of view; the bar wants White's.
func _on_engine_eval(depth: int, cp: int, mate: int) -> void:
	if not eval_enabled or game_over or depth < EVAL_MIN_DEPTH:
		return
	var pov := 1 if search_turn == "w" else -1
	if mate != 0:
		_show_eval(1.0 if mate * pov > 0 else 0.0, "M%d" % absi(mate), mate * pov > 0)
	else:
		# Same curve Lichess uses to turn centipawns into a win chance.
		var win := 0.5 + 0.5 * (2.0 / (1.0 + exp(-0.00368208 * cp * pov)) - 1.0)
		_show_eval(win, "%.1f" % (absf(cp) / 100.0), cp * pov >= 0)


## target: White's share of the bar (0..1); text: readout shown at the leading side's end.
func _show_eval(target: float, text: String, white_ahead: bool) -> void:
	eval_target = target
	eval_text = text
	eval_white_ahead = white_ahead
	_update_eval_label()


func _animate_eval(delta: float) -> void:
	if eval_display == eval_target:
		return
	var before := roundi(eval_display * 8 * SQ)
	eval_display = lerpf(eval_display, eval_target, 1.0 - exp(-delta * 10.0))
	if absf(eval_display - eval_target) < 0.0005:
		eval_display = eval_target
	if roundi(eval_display * 8 * SQ) != before:
		queue_redraw()


func _update_eval_label() -> void:
	if eval_label == null:
		return
	eval_label.visible = eval_enabled and eval_text != ""
	if not eval_label.visible:
		return
	eval_label.text = eval_text
	eval_label.add_theme_color_override("font_color", BAR_BLACK if eval_white_ahead else LIGHT_COL)
	var s := scale.x
	eval_label.add_theme_font_size_override("font_size", roundi(clampf(BAR_W * s * 0.32, 14.0, 40.0)))
	eval_label.size = Vector2(BAR_W * s, 0)  # bar width; height shrinks to fit the text
	# White's end of the bar is the bottom unless the board is flipped.
	var at_bottom := eval_white_ahead != flipped
	var y := (OFF + 8 * SQ) * s - eval_label.size.y - 4.0 if at_bottom else OFF * s + 4.0
	eval_label.position = Vector2(position.x + (BAR_X + 1) * s, position.y + y)


func _on_engine_bestmove(uci: String) -> void:
	if not search_for_move or not engine_enabled or game_over or turn == human_color:
		return
	var fr := _name_to_sq(uci.substr(0, 2))
	var to := _name_to_sq(uci.substr(2, 2))
	var promo := uci.substr(4, 1).to_upper()
	for m in _legal_from(fr):
		if m["to"] == to and m.get("promo", "") == promo:
			_do_move(m)
			queue_redraw()
			_update_cursor()
			return
	push_warning("Stockfish suggested a move the game considers illegal: " + uci)
	status_label.text = "Stockfish returned an unplayable move (%s)" % uci


func _process(delta: float) -> void:
	_animate_eval(delta)
	if engine == null or not engine.running or engine.thinking or game_over:
		return
	if engine_enabled and turn != human_color:
		_start_search(engine_depth, true)
	elif eval_enabled and analyzed_version != pos_version:
		_start_search(EVAL_DEPTH, false)


static func _sq_name(s: int) -> String:
	return char(97 + (s & 7)) + str((s >> 3) + 1)


static func _name_to_sq(n: String) -> int:
	return (n.unicode_at(0) - 97) + (n.unicode_at(1) - 49) * 8


static func _uci(m: Dictionary) -> String:
	return _sq_name(m["fr"]) + _sq_name(m["to"]) + String(m.get("promo", "")).to_lower()


# ---------------------------------------------------------------- rules

static func _opp(c: String) -> String:
	return "b" if c == "w" else "w"


static func _in_bounds(f: int, r: int) -> bool:
	return f >= 0 and f < 8 and r >= 0 and r < 8


func _is_attacked(b: Array, s: int, by: String) -> bool:
	var f := s & 7
	var r := s >> 3
	# pawns
	var pr := r - 1 if by == "w" else r + 1
	for df in [-1, 1]:
		if _in_bounds(f + df, pr) and b[pr * 8 + f + df] == by + "P":
			return true
	for o in KNIGHT_OFFS:
		if _in_bounds(f + o.x, r + o.y) and b[(r + o.y) * 8 + f + o.x] == by + "N":
			return true
	for o in KING_OFFS:
		if _in_bounds(f + o.x, r + o.y) and b[(r + o.y) * 8 + f + o.x] == by + "K":
			return true
	for dirs in [ROOK_DIRS, BISHOP_DIRS]:
		var slider := "R" if dirs == ROOK_DIRS else "B"
		for d in dirs:
			var nf: int = f + d.x
			var nr: int = r + d.y
			while _in_bounds(nf, nr):
				var p: String = b[nr * 8 + nf]
				if p != "":
					if p == by + slider or p == by + "Q":
						return true
					break
				nf += d.x
				nr += d.y
	return false


func _in_check(b: Array, c: String) -> bool:
	var k := b.find(c + "K")
	return k != -1 and _is_attacked(b, k, _opp(c))


func _add_pawn_move(res: Array, from: int, to: int, promotes: bool, extra := {}) -> void:
	if promotes:
		for pc in PROMO_CHOICES:
			res.append({"fr": from, "to": to, "promo": pc})
	else:
		var m := {"fr": from, "to": to}
		m.merge(extra)
		res.append(m)


func _pseudo_moves(b: Array, s: int) -> Array:
	var res: Array = []
	var p: String = b[s]
	if p == "":
		return res
	var c := p[0]
	var t := p[1]
	var f := s & 7
	var r := s >> 3
	match t:
		"P":
			var dir := 1 if c == "w" else -1
			var start := 1 if c == "w" else 6
			var last := 7 if c == "w" else 0
			var r1 := r + dir
			if _in_bounds(f, r1) and b[r1 * 8 + f] == "":
				_add_pawn_move(res, s, r1 * 8 + f, r1 == last)
				var r2 := r + 2 * dir
				if r == start and b[r2 * 8 + f] == "":
					res.append({"fr": s, "to": r2 * 8 + f})
			for df in [-1, 1]:
				if not _in_bounds(f + df, r1):
					continue
				var t2: int = r1 * 8 + f + df
				var target: String = b[t2]
				if target != "" and target[0] != c:
					_add_pawn_move(res, s, t2, r1 == last)
				elif t2 == ep_square:
					res.append({"fr": s, "to": t2, "ep": true})
		"N", "K":
			var offs := KNIGHT_OFFS if t == "N" else KING_OFFS
			for o in offs:
				if _in_bounds(f + o.x, r + o.y):
					var t2: int = (r + o.y) * 8 + f + o.x
					var target: String = b[t2]
					if target == "" or target[0] != c:
						res.append({"fr": s, "to": t2})
			if t == "K":
				_add_castling(b, s, c, res)
		"B", "R", "Q":
			var dirs: Array = []
			if t != "B":
				dirs.append_array(ROOK_DIRS)
			if t != "R":
				dirs.append_array(BISHOP_DIRS)
			for d in dirs:
				var nf: int = f + d.x
				var nr: int = r + d.y
				while _in_bounds(nf, nr):
					var target: String = b[nr * 8 + nf]
					if target == "":
						res.append({"fr": s, "to": nr * 8 + nf})
					else:
						if target[0] != c:
							res.append({"fr": s, "to": nr * 8 + nf})
						break
					nf += d.x
					nr += d.y
	return res


func _add_castling(b: Array, s: int, c: String, res: Array) -> void:
	var h := 0 if c == "w" else 56
	var opp := _opp(c)
	if s != h + 4 or _is_attacked(b, s, opp):
		return
	if castling[c + "K"] and b[h + 5] == "" and b[h + 6] == "" and b[h + 7] == c + "R" \
			and not _is_attacked(b, h + 5, opp) and not _is_attacked(b, h + 6, opp):
		res.append({"fr": s, "to": h + 6, "castle": "K"})
	if castling[c + "Q"] and b[h + 3] == "" and b[h + 2] == "" and b[h + 1] == "" and b[h] == c + "R" \
			and not _is_attacked(b, h + 3, opp) and not _is_attacked(b, h + 2, opp):
		res.append({"fr": s, "to": h + 2, "castle": "Q"})


func _apply(b: Array, m: Dictionary) -> Array:
	var nb := b.duplicate()
	var fr: int = m["fr"]
	var to: int = m["to"]
	var p: String = nb[fr]
	nb[to] = p
	nb[fr] = ""
	if m.get("ep", false):
		nb[(fr >> 3) * 8 + (to & 7)] = ""
	var h := fr & ~7
	match m.get("castle", ""):
		"K":
			nb[h + 5] = nb[h + 7]
			nb[h + 7] = ""
		"Q":
			nb[h + 3] = nb[h]
			nb[h] = ""
	if m.get("promo", "") != "":
		nb[to] = p[0] + m["promo"]
	return nb


func _legal_from(s: int) -> Array:
	var res: Array = []
	var p: String = board[s]
	if p == "":
		return res
	for m in _pseudo_moves(board, s):
		if not _in_check(_apply(board, m), p[0]):
			res.append(m)
	return res


func _has_any_legal(c: String) -> bool:
	for s in 64:
		var p: String = board[s]
		if p != "" and p[0] == c and not _legal_from(s).is_empty():
			return true
	return false


func _do_move(m: Dictionary) -> void:
	var fr: int = m["fr"]
	var to: int = m["to"]
	var p: String = board[fr]
	move_list.append(_uci(m))
	pos_version += 1
	if engine != null:
		engine.cancel()  # a search of the old position (human moved during an evaluation)
	# En passant takes the pawn beside the mover, not the one on the destination square.
	var victim: String = board[(fr >> 3) * 8 + (to & 7)] if m.get("ep", false) else board[to]
	if victim != "":
		captured[p[0]].append(victim)
		captured[p[0]].sort_custom(func(a: String, b: String): return CAP_ORDER.find(a[1]) < CAP_ORDER.find(b[1]))
	board = _apply(board, m)
	if p[1] == "K":
		castling[turn + "K"] = false
		castling[turn + "Q"] = false
	var corners := {0: "wQ", 7: "wK", 56: "bQ", 63: "bK"}
	for corner in corners:
		if fr == corner or to == corner:
			castling[corners[corner]] = false
	ep_square = (fr + to) / 2 if p[1] == "P" and absi(to - fr) == 16 else -1
	last_move = [fr, to]
	turn = _opp(turn)
	selected = -1
	selected_moves = []
	promo_pending = {}
	_update_captured_ui()
	_update_status()


func _update_status() -> void:
	var side := "White" if turn == "w" else "Black"
	var check := _in_check(board, turn)
	if not _has_any_legal(turn):
		game_over = true
		if check:
			status_label.text = "Checkmate! %s wins" % ("Black" if turn == "w" else "White")
			_show_eval(0.0 if turn == "w" else 1.0, "0-1" if turn == "w" else "1-0", turn == "b")
		else:
			status_label.text = "Stalemate - draw"
			_show_eval(0.5, "1/2", true)
	else:
		status_label.text = side + " to move" + ("  (check!)" if check else "")
		if engine_enabled and turn != human_color:
			status_label.text += "  - Stockfish thinking (depth %d)..." % engine_depth


# ---------------------------------------------------------------- coordinates

func _sq_to_disp(s: int) -> Vector2i:
	var f := s & 7
	var r := s >> 3
	return Vector2i(7 - f, r) if flipped else Vector2i(f, 7 - r)


func _disp_to_sq(d: Vector2i) -> int:
	return (d.y * 8 + 7 - d.x) if flipped else ((7 - d.y) * 8 + d.x)


func _disp_rect(d: Vector2i) -> Rect2:
	return Rect2(OFF + d.x * SQ, OFF + d.y * SQ, SQ, SQ)


func _mouse_disp() -> Vector2i:
	var m := get_local_mouse_position() - Vector2(OFF, OFF)
	var d := Vector2i(floori(m.x / SQ), floori(m.y / SQ))
	if d.x < 0 or d.x > 7 or d.y < 0 or d.y > 7:
		return Vector2i(-1, -1)
	return d


# ---------------------------------------------------------------- input

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			_on_press(_mouse_disp())
		else:
			_on_release(_mouse_disp())
		_update_cursor()
	elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
		selected = -1
		selected_moves = []
		dragging = false
		promo_pending = {}
		queue_redraw()
	elif event is InputEventMouseMotion:
		drag_pos = get_local_mouse_position()
		_update_cursor()
		if dragging:
			queue_redraw()


func _on_press(d: Vector2i) -> void:
	if not promo_pending.is_empty():
		var cells := _promo_cells()
		var i := cells.find(d)
		if i != -1:
			for m in promo_pending["moves"]:
				if m["promo"] == PROMO_CHOICES[i]:
					_do_move(m)
					break
		promo_pending = {}
		queue_redraw()
		return
	if game_over or not _human_turn():
		return
	if d.x < 0:
		selected = -1
		selected_moves = []
		queue_redraw()
		return
	var s := _disp_to_sq(d)
	if selected != -1 and _try_move(s):
		queue_redraw()
		return
	var p: String = board[s]
	if p != "" and p[0] == turn:
		selected = s
		selected_moves = _legal_from(s)
		dragging = true
		drag_pos = get_local_mouse_position()
	else:
		selected = -1
		selected_moves = []
	queue_redraw()


func _on_release(d: Vector2i) -> void:
	if not dragging:
		return
	dragging = false
	if d.x >= 0:
		var s := _disp_to_sq(d)
		if s != selected:
			_try_move(s)
	queue_redraw()


func _try_move(to: int) -> bool:
	var matches: Array = []
	for m in selected_moves:
		if m["to"] == to:
			matches.append(m)
	if matches.is_empty():
		return false
	if matches.size() > 1:
		promo_pending = {"to": to, "moves": matches}
		return true
	_do_move(matches[0])
	return true


func _promo_cells() -> Array:
	var d := _sq_to_disp(promo_pending["to"])
	var step := 1 if d.y < 4 else -1
	var cells: Array = []
	for i in 4:
		cells.append(Vector2i(d.x, d.y + i * step))
	return cells


# ---------------------------------------------------------------- drawing

func _draw_piece(p: String, rect: Rect2) -> void:
	var tex := tex_white if p[0] == "w" else tex_black
	var idx := SHEET_ORDER.find(p[1])
	draw_texture_rect_region(tex, rect, Rect2(idx * 16, 0, 16, 16))


func _draw_eval_bar() -> void:
	var h := 8 * SQ
	var x := BAR_X + 1
	draw_rect(Rect2(BAR_X, OFF - 1, BAR_W + 2, h + 2), BORDER_COL)  # frame
	# Whole-pixel heights keep the edge between the colours on the pixel grid.
	var white_px := clampi(roundi(eval_display * h), 0, h)
	var black_px := h - white_px
	var white_top := OFF if flipped else OFF + black_px  # White's end is the bottom unless flipped
	var black_top := OFF + white_px if flipped else OFF
	draw_rect(Rect2(x, black_top, BAR_W, black_px), BAR_BLACK)
	draw_rect(Rect2(x, white_top, BAR_W, white_px), LIGHT_COL)
	# Centre line plus quarter notches, like a ruler.
	for i in range(1, 4):
		var y := OFF + i * h / 4
		if i == 2:
			draw_rect(Rect2(x, y, BAR_W, 1), BORDER_COL)
		else:
			draw_rect(Rect2(x, y, 2, 1), BORDER_COL)
			draw_rect(Rect2(x + BAR_W - 2, y, 2, 1), BORDER_COL)


func _draw() -> void:
	draw_texture(tex_board, Vector2.ZERO)
	if eval_enabled:
		_draw_eval_bar()
	_draw_captured()

	# The board image has rank/file labels baked in; reorder them when flipped.
	if flipped:
		draw_rect(Rect2(0, OFF, 6, 8 * SQ), BORDER_COL)
		draw_rect(Rect2(OFF, OFF + 8 * SQ + 1, 8 * SQ, 6), BORDER_COL)
		for i in 8:
			draw_texture_rect_region(tex_board, Rect2(0, OFF + i * SQ, 6, SQ),
					Rect2(0, OFF + (7 - i) * SQ, 6, SQ))
			draw_texture_rect_region(tex_board, Rect2(OFF + i * SQ, OFF + 8 * SQ + 1, SQ, 6),
					Rect2(OFF + (7 - i) * SQ, OFF + 8 * SQ + 1, SQ, 6))

	for s in last_move:
		draw_rect(_disp_rect(_sq_to_disp(s)), Color(1.0, 0.85, 0.2, 0.4))

	if _in_check(board, turn):
		draw_rect(_disp_rect(_sq_to_disp(board.find(turn + "K"))), Color(0.9, 0.15, 0.15, 0.55))

	if selected != -1:
		draw_rect(_disp_rect(_sq_to_disp(selected)), Color(0.35, 0.8, 0.45, 0.5))

	for s in 64:
		var p: String = board[s]
		if p == "" or (dragging and s == selected):
			continue
		_draw_piece(p, _disp_rect(_sq_to_disp(s)))

	# move hints
	var hint := Color(0.1, 0.12, 0.18, 0.45)
	for m in selected_moves:
		var r := _disp_rect(_sq_to_disp(m["to"]))
		if board[m["to"]] != "" or m.get("ep", false):
			draw_rect(r.grow(-0.5), hint, false, 1.0)
		else:
			draw_rect(Rect2(r.position + Vector2(6, 6), Vector2(4, 4)), hint)

	if dragging and selected != -1:
		_draw_piece(board[selected], Rect2(drag_pos - Vector2(8, 8), Vector2(16, 16)))

	if not promo_pending.is_empty():
		draw_rect(Rect2(OFF, OFF, 8 * SQ, 8 * SQ), Color(0, 0, 0, 0.55))
		var cells := _promo_cells()
		for i in 4:
			var r := _disp_rect(cells[i])
			draw_rect(r, LIGHT_COL)
			draw_rect(r.grow(-0.5), BORDER_COL, false, 1.0)
			_draw_piece(turn + PROMO_CHOICES[i], r)
