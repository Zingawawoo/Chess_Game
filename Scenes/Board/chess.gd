extends Node2D
## Top-down 2D chess using the "Pixel Chess" asset pack by Dani Maccari.
## Two players on one machine, over LAN, or against Stockfish. Click or drag to move.
## Powerups: a random one each turn (card, piece ability or square pickup); hover to read them.

const UciEngine := preload("res://uci_engine.gd")
const LanNet := preload("res://Utilities/Online/lan_net.gd")
const Powerups := preload("res://Utilities/Powerups/powerups.gd")

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
const FONT_PATH := "res://Assets/UI/Fonts/GenericMobileSystem.ttf"
var EMPTY64: Array = []  # 64 empty dicts, for plain-chess checks

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

# Powerups (see Utilities/Powerups/powerups.gd). fx[sq]: effects that travel with the piece on sq -
# "ab" (attached ability {id, v}), "frozen" (turns), "bounty" (points), "decoy". sqfx[sq]: effects
# on the square - "wall" {turns, owner}, "hole", "portal" {pair, turns, owner, id}, "mine" {owner},
# "pickup" {owner, id, v}.
var fx: Array = []
var sqfx: Array = []
var cards := {"w": [], "b": []}       # each {"id", "v"}
var score := {"w": 0, "b": 0}
var double_next := {"w": false, "b": false}
var lost := {"w": [], "b": []}        # own pieces lost, oldest first (Revive)
var extra: Dictionary = {}            # pending extra move: {"sq": only this piece (-1 any), "cap": captures only}
var powerups_on := true
var targeting: Dictionary = {}        # card being aimed: {"slot", "id", "v", "picks"}
var hint_move: Array = []             # Best Move card result: [from, to]
var hint_pending := false
var search_hint := false              # the running search answers a Best Move card
var event_text := ""
var portal_count := 0
var rng := RandomNumberGenerator.new()

var pu_toggle: CheckButton
var end_turn_btn: Button
var score_label: Label
var event_label: Label
var card_boxes := {}                  # colour -> VBoxContainer of card buttons
var hover_panel: PanelContainer
var hover_label: Label

# LAN multiplayer. While online, this player only moves my_color and moves go to the opponent.
var lan: LanNet
var online := false
var my_color := "w"
var mp_button: Button
var mp_panel: PanelContainer
var mp_name_edit: LineEdit
var mp_host_btn: Button
var mp_lobby_list: ItemList
var mp_lobbies: Array = []
var mp_join_btn: Button
var mp_ip_edit: LineEdit
var mp_status: Label
var mp_from_menu := false  # lobby panel was opened from the start menu; closing it goes back there

# Start menu shown over the board.
var menu: Control
var top_bar: HBoxContainer
var top_bar2: HBoxContainer

var status_label: Label
var engine_toggle: CheckButton
var eval_toggle: CheckButton
var eval_label: Label


func _ready() -> void:
	rng.randomize()
	for i in 64:
		EMPTY64.append({})
	tex_board = load(ASSET + "boards/board_plain_01.png")
	tex_white = load(ASSET + "16x16 pieces/WhitePieces.png")
	tex_black = load(ASSET + "16x16 pieces/BlackPieces.png")
	_load_cursors()
	lan = LanNet.new()
	lan.name = "Lan"
	add_child(lan)
	lan.lobbies_changed.connect(_on_lobbies_changed)
	lan.opponent_joined.connect(_on_opponent_joined)
	lan.joined_host.connect(func(): mp_status.text = "Connected - starting game...")
	lan.join_failed.connect(_on_join_failed)
	lan.opponent_left.connect(func(): _go_offline("Opponent left the game"))
	_build_ui()
	get_viewport().size_changed.connect(_layout)
	_layout()
	new_game()
	eval_toggle.button_pressed = true  # on by default; reports an error if Stockfish is missing


func _build_ui() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	var bar := HBoxContainer.new()
	top_bar = bar
	bar.position = Vector2(12, 12)
	bar.add_theme_constant_override("separation", 12)
	layer.add_child(bar)

	var menu_btn := Button.new()
	menu_btn.text = "Menu"
	menu_btn.focus_mode = Control.FOCUS_NONE
	menu_btn.pressed.connect(_show_menu)
	bar.add_child(menu_btn)

	var swap := Button.new()
	swap.text = "Swap Colors"
	swap.focus_mode = Control.FOCUS_NONE
	swap.pressed.connect(_swap_colors)
	bar.add_child(swap)

	var reset := Button.new()
	reset.text = "New Game"
	reset.focus_mode = Control.FOCUS_NONE
	reset.pressed.connect(_on_new_game_pressed)
	bar.add_child(reset)

	mp_button = Button.new()
	mp_button.text = "Multiplayer"
	mp_button.focus_mode = Control.FOCUS_NONE
	mp_button.pressed.connect(_on_mp_button)
	bar.add_child(mp_button)

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

	pu_toggle = CheckButton.new()
	pu_toggle.text = "Powerups"
	pu_toggle.focus_mode = Control.FOCUS_NONE
	pu_toggle.button_pressed = true
	pu_toggle.toggled.connect(func(on: bool):
		powerups_on = on
		_update_cards_ui())
	bar.add_child(pu_toggle)

	end_turn_btn = Button.new()
	end_turn_btn.text = "End Turn"
	end_turn_btn.focus_mode = Control.FOCUS_NONE
	end_turn_btn.visible = false
	end_turn_btn.pressed.connect(func(): _exec({"t": "end_extra"}, true))
	bar.add_child(end_turn_btn)

	status_label = Label.new()
	status_label.add_theme_font_size_override("font_size", 32)
	bar.add_child(status_label)

	# Second row: score and the latest powerup event.
	var bar2 := HBoxContainer.new()
	bar2.position = Vector2(12, 56)
	bar2.add_theme_constant_override("separation", 32)
	layer.add_child(bar2)
	top_bar2 = bar2
	score_label = Label.new()
	bar2.add_child(score_label)
	event_label = Label.new()
	event_label.add_theme_color_override("font_color", Color8(250, 210, 120))
	bar2.add_child(event_label)

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

	_build_powerup_ui(layer)
	_build_mp_panel(layer)
	_build_menu(layer)


func _layout() -> void:
	var vs := get_viewport_rect().size
	var top := 96.0
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
	_update_cards_ui()


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
	elif promo_pending.is_empty() and targeting.is_empty() and not game_over and _human_turn():
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
	fx = []
	sqfx = []
	for i in 64:
		fx.append({})
		sqfx.append({})
	cards = {"w": [], "b": []}
	score = {"w": 0, "b": 0}
	double_next = {"w": false, "b": false}
	lost = {"w": [], "b": []}
	extra = {}
	targeting = {}
	hint_move = []
	hint_pending = false
	portal_count = 0
	_event("")
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
	_turn_started()
	_update_cards_ui()
	queue_redraw()


# ---------------------------------------------------------------- captured pieces

func _material(c: String) -> int:
	if board.size() < 64 or fx.size() < 64:
		return 0
	var total := 0
	for p in board:
		if p != "" and p[0] == c:
			total += PIECE_VALUE[p[1]]
	for q in 64:
		if board[q] != "" and board[q][0] == c and fx[q].get("decoy", false) and _viewer_sees(c):
			total -= PIECE_VALUE[board[q][1]]
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
	if online:
		return turn == my_color
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
	targeting = {}
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
	if on and online:
		engine_toggle.set_pressed_no_signal(false)
		return
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


## purpose: "move" (Stockfish plays), "hint" (Best Move card) or "eval" (eval bar).
func _start_search(depth: int, purpose: String) -> void:
	search_for_move = purpose == "move"
	search_hint = purpose == "hint"
	search_turn = turn
	analyzed_version = pos_version
	if not _fen_ok():
		# Stockfish can't read this position (e.g. a missing king): play/answer without it.
		if purpose == "move":
			var m := _fallback_move()
			if not m.is_empty():
				_play(m)
		elif purpose == "hint":
			_event("Stockfish can't read this position - no hint")
		else:
			_show_eval(eval_target, "?", eval_white_ahead)
		return
	var moves := _uci_moves() if purpose != "eval" else PackedStringArray()
	engine.think_fen(_fen(), depth, moves)


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
	var fr := _name_to_sq(uci.substr(0, 2))
	var to := _name_to_sq(uci.substr(2, 2))
	var promo := uci.substr(4, 1).to_upper()
	if search_hint:
		search_hint = false
		if fr >= 0 and fr < 64 and to >= 0 and to < 64:
			hint_move = [fr, to]
			_event("Best move: %s" % uci)
			queue_redraw()
		return
	if not search_for_move or not engine_enabled or game_over or turn == human_color:
		return
	var pick: Dictionary = {}
	for m in _moves_for_ui(fr):
		if m["to"] == to and m.get("promo", "") == promo and not m.get("ranged", false) and not m.get("bounce", false):
			pick = m
			break
	if pick.is_empty():
		pick = _fallback_move()  # Stockfish wanted a move these rules don't allow
	if not pick.is_empty():
		_play(pick)


func _process(delta: float) -> void:
	_animate_eval(delta)
	if engine == null or not engine.running or engine.thinking or game_over:
		return
	if engine_enabled and turn != human_color:
		_start_search(engine_depth, "move")
	elif hint_pending:
		hint_pending = false
		_start_search(EVAL_DEPTH, "hint")
	elif eval_enabled and analyzed_version != pos_version:
		_start_search(EVAL_DEPTH, "eval")


static func _sq_name(s: int) -> String:
	return char(97 + (s & 7)) + str((s >> 3) + 1)


static func _name_to_sq(n: String) -> int:
	return (n.unicode_at(0) - 97) + (n.unicode_at(1) - 49) * 8


static func _uci(m: Dictionary) -> String:
	return _sq_name(m["fr"]) + _sq_name(m["to"]) + String(m.get("promo", "")).to_lower()


# ---------------------------------------------------------------- rules
#
# A position is a Dictionary {"b": board, "f": fx, "s": sqfx} so legality checks can run on copies.
# board[sq]: "" or a piece like "wN". fx[sq]: effects that travel with that piece. sqfx[sq]: effects
# on the square itself. Kings can never be captured; checkmate still ends the game.

static func _opp(c: String) -> String:
	return "b" if c == "w" else "w"


static func _in_bounds(f: int, r: int) -> bool:
	return f >= 0 and f < 8 and r >= 0 and r < 8


func _st() -> Dictionary:
	return {"b": board, "f": fx, "s": sqfx}


## Walls and holes can't be entered or passed through.
static func _blocked(sf: Array, q: int) -> bool:
	var e: Dictionary = sf[q]
	return e.has("wall") or e.has("hole")


## Frozen pieces and decoys don't threaten anything.
static func _can_attack(f: Array, q: int) -> bool:
	var e: Dictionary = f[q]
	return not e.has("frozen") and not e.get("decoy", false)


static func _without(d: Dictionary, key: String) -> Dictionary:
	var nd := d.duplicate(true)
	nd.erase(key)
	return nd


## Pawns never stand on the first or last rank.
static func _pawn_ok(piece: String, q: int) -> bool:
	return piece[1] != "P" or ((q >> 3) != 0 and (q >> 3) != 7)


func _is_attacked(st: Dictionary, s: int, by: String) -> bool:
	var b: Array = st["b"]
	var f: Array = st["f"]
	var sf: Array = st["s"]
	var fl := s & 7
	var r := s >> 3
	var pr := r - 1 if by == "w" else r + 1
	for df in [-1, 1]:
		if _in_bounds(fl + df, pr):
			var q: int = pr * 8 + fl + df
			if b[q] == by + "P" and _can_attack(f, q):
				return true
	for o in KNIGHT_OFFS:
		if _in_bounds(fl + o.x, r + o.y):
			var q: int = (r + o.y) * 8 + fl + o.x
			if b[q] == by + "N" and _can_attack(f, q):
				return true
	for o in KING_OFFS:
		if _in_bounds(fl + o.x, r + o.y) and b[(r + o.y) * 8 + fl + o.x] == by + "K":
			return true
	for dirs in [ROOK_DIRS, BISHOP_DIRS]:
		var slider := "R" if dirs == ROOK_DIRS else "B"
		for d in dirs:
			var nf: int = fl + d.x
			var nr: int = r + d.y
			while _in_bounds(nf, nr):
				var q: int = nr * 8 + nf
				if _blocked(sf, q):
					break
				var p: String = b[q]
				if p != "":
					if (p == by + slider or p == by + "Q") and _can_attack(f, q):
						return true
					break
				nf += d.x
				nr += d.y
	# Pieces whose abilities give them extra attacks.
	for q in 64:
		var p: String = b[q]
		if p == "" or p[0] != by or not _can_attack(f, q):
			continue
		var ab: Dictionary = f[q].get("ab", {})
		if ab.is_empty():
			continue
		var dx := fl - (q & 7)
		var dy := r - (q >> 3)
		var knightish := (absi(dx) == 1 and absi(dy) == 2) or (absi(dx) == 2 and absi(dy) == 1)
		match ab["id"]:
			"knight_hop":
				if knightish:
					return true
			"copy_move":
				if knightish or _ray_clear(st, q, s, 0):
					return true
			"jump":
				var straight := dx == 0 or dy == 0
				var diag := absi(dx) == absi(dy)
				var ok := (straight and p[1] != "B") or (diag and p[1] != "R")
				if ok and _ray_clear(st, q, s, ab["v"]["over"]):
					return true
	return false


## True if a queen-line runs from a to b with at most `jumps` pieces in between and no walls.
func _ray_clear(st: Dictionary, a: int, b: int, jumps: int) -> bool:
	var dx := (b & 7) - (a & 7)
	var dy := (b >> 3) - (a >> 3)
	if a == b or not (dx == 0 or dy == 0 or absi(dx) == absi(dy)):
		return false
	var sx := signi(dx)
	var sy := signi(dy)
	var x := (a & 7) + sx
	var y := (a >> 3) + sy
	var between := 0
	while x != (b & 7) or y != (b >> 3):
		var q := y * 8 + x
		if _blocked(st["s"], q):
			return false
		if st["b"][q] != "":
			between += 1
			if between > jumps:
				return false
		x += sx
		y += sy
	return true


func _in_check(st: Dictionary, c: String) -> bool:
	var k: int = st["b"].find(c + "K")
	return k != -1 and _is_attacked(st, k, _opp(c))


func _add_pawn_move(res: Array, from: int, to: int, promotes: bool, extra := {}) -> void:
	if promotes:
		for pc in PROMO_CHOICES:
			var m := {"fr": from, "to": to, "promo": pc}
			m.merge(extra)
			res.append(m)
	else:
		var m := {"fr": from, "to": to}
		m.merge(extra)
		res.append(m)


## A capture of `to` by the piece on `fr`, shaped by shields and ranged attacks.
func _add_capture(res: Array, st: Dictionary, fr: int, to: int, promotes: bool, extra := {}) -> void:
	var target: String = st["b"][to]
	if target[1] == "K":
		return  # kings are never captured
	var shield: Dictionary = st["f"][to].get("ab", {})
	if shield.get("id", "") == "shield":
		if shield["v"]["mode"] == "turns":
			return
		var bm := {"fr": fr, "to": to, "bounce": true}
		res.append(bm)
		return
	if st["f"][fr].get("ab", {}).get("id", "") == "ranged":
		res.append({"fr": fr, "to": to, "ranged": true, "ab": "ranged"})
		return
	_add_pawn_move(res, fr, to, promotes, extra)


## One step onto (nf, nr): a quiet move or a capture.
func _step(res: Array, st: Dictionary, s: int, nf: int, nr: int, extra := {}) -> void:
	if not _in_bounds(nf, nr):
		return
	var q := nr * 8 + nf
	if _blocked(st["s"], q):
		return
	var p: String = st["b"][s]
	var target: String = st["b"][q]
	if p[1] == "P" and (nr == 0 or nr == 7) and nr != _last_rank(p[0]):
		return
	var promotes: bool = p[1] == "P" and nr == _last_rank(p[0])
	if target == "":
		_add_pawn_move(res, s, q, promotes, extra)
	elif target[0] != p[0] and not st["f"][s].get("decoy", false):
		_add_capture(res, st, s, q, promotes, extra)


## Slides from s in direction d. With jumps > 0 it may pass over that many pieces;
## only_beyond keeps just the squares that needed a jump.
func _slide(res: Array, st: Dictionary, s: int, d: Vector2i, jumps: int, only_beyond: bool, extra := {}) -> void:
	var p: String = st["b"][s]
	var nf: int = (s & 7) + d.x
	var nr: int = (s >> 3) + d.y
	var jumped := 0
	while _in_bounds(nf, nr):
		var q := nr * 8 + nf
		if _blocked(st["s"], q):
			break
		var target: String = st["b"][q]
		if target == "":
			if not only_beyond or jumped > 0:
				_step(res, st, s, nf, nr, extra)
		else:
			if target[0] != p[0] and (not only_beyond or jumped > 0):
				_step(res, st, s, nf, nr, extra)
			if jumped >= jumps:
				break
			jumped += 1
		nf += d.x
		nr += d.y


static func _last_rank(c: String) -> int:
	return 7 if c == "w" else 0


func _pseudo_moves(st: Dictionary, s: int) -> Array:
	var b: Array = st["b"]
	var f: Array = st["f"]
	var sf: Array = st["s"]
	var res: Array = []
	var p: String = b[s]
	if p == "":
		return res
	var pf: Dictionary = f[s]
	if pf.has("frozen"):
		return res
	var c := p[0]
	var t := p[1]
	var fl := s & 7
	var r := s >> 3
	var ab: Dictionary = pf.get("ab", {})
	var abid: String = ab.get("id", "")
	var decoy: bool = pf.get("decoy", false)
	match t:
		"P":
			var dir := 1 if c == "w" else -1
			var start := 1 if c == "w" else 6
			var promo_r := _last_rank(c)
			if abid == "promote_early":
				var rel: int = int(ab["v"]["rank"]) - 1
				promo_r = rel if c == "w" else 7 - rel
			var r1 := r + dir
			if _in_bounds(fl, r1) and b[r1 * 8 + fl] == "" and not _blocked(sf, r1 * 8 + fl):
				_add_pawn_move(res, s, r1 * 8 + fl, _reaches(c, r1, promo_r))
				var r2 := r + 2 * dir
				if r == start and b[r2 * 8 + fl] == "" and not _blocked(sf, r2 * 8 + fl):
					_add_pawn_move(res, s, r2 * 8 + fl, _reaches(c, r2, promo_r))
			if not decoy:
				for df in [-1, 1]:
					if not _in_bounds(fl + df, r1):
						continue
					var t2: int = r1 * 8 + fl + df
					var target: String = b[t2]
					if target != "" and target[0] != c:
						_add_capture(res, st, s, t2, _reaches(c, r1, promo_r))
					elif t2 == ep_square and target == "" and not _blocked(sf, t2):
						res.append({"fr": s, "to": t2, "ep": true})
			if abid == "backstep":
				var v: Dictionary = ab["v"]
				for k in range(1, int(v["back"]) + 1):
					var rr := r - dir * k
					if rr <= 0 or rr >= 7:
						break
					var q := rr * 8 + fl
					if b[q] != "" or _blocked(sf, q):
						break
					res.append({"fr": s, "to": q, "ab": "backstep"})
				for k in range(1, int(v["fwd"]) + 1):
					var rr := r + dir * k
					if not _in_bounds(fl, rr):
						break
					var q := rr * 8 + fl
					if b[q] != "" or _blocked(sf, q):
						break
					if k >= 2:
						_add_pawn_move(res, s, q, rr == _last_rank(c), {"ab": "backstep"})
					if rr == _last_rank(c):
						break
		"N", "K":
			var offs := KNIGHT_OFFS if t == "N" else KING_OFFS
			for o in offs:
				_step(res, st, s, fl + o.x, r + o.y)
			if t == "K":
				_add_castling(st, s, c, res)
		"B", "R", "Q":
			for d in _dirs(t):
				_slide(res, st, s, d, 0, false)
	match abid:
		"knight_hop":
			for o in KNIGHT_OFFS:
				_step(res, st, s, fl + o.x, r + o.y, {"ab": "knight_hop"})
		"copy_move":
			for o in KNIGHT_OFFS:
				_step(res, st, s, fl + o.x, r + o.y, {"ab": "copy_move"})
			for d in _dirs("Q"):
				_slide(res, st, s, d, 0, false, {"ab": "copy_move"})
		"jump":
			for d in _dirs(t):
				_slide(res, st, s, d, int(ab["v"]["over"]), true, {"ab": "jump"})
	# Drop duplicates (a normal move wins over the same move through an ability).
	var seen := {}
	var out: Array = []
	for m in res:
		var key := "%d|%s|%s|%s" % [m["to"], m.get("promo", ""), m.get("ranged", false), m.get("bounce", false)]
		if seen.has(key):
			continue
		seen[key] = true
		out.append(m)
	# Abilities that trigger on any move (or any capture) of this piece.
	for m in out:
		if m.get("bounce", false) or m.has("castle"):
			continue
		match abid:
			"move_twice":
				m["ab"] = "move_twice"
			"duplicate":
				if not m.get("ranged", false):
					m["ab"] = "duplicate"
					m["dup"] = true
			"chain":
				if b[m["to"]] != "" or m.get("ep", false):
					m["ab"] = "chain"
	return out


static func _dirs(t: String) -> Array:
	var dirs: Array = []
	if t != "B":
		dirs.append_array(ROOK_DIRS)
	if t != "R":
		dirs.append_array(BISHOP_DIRS)
	return dirs


static func _reaches(c: String, r: int, promo_r: int) -> bool:
	return r >= promo_r if c == "w" else r <= promo_r


func _add_castling(st: Dictionary, s: int, c: String, res: Array) -> void:
	var b: Array = st["b"]
	var sf: Array = st["s"]
	var h := 0 if c == "w" else 56
	var opp := _opp(c)
	if s != h + 4 or _is_attacked(st, s, opp):
		return
	if castling[c + "K"] and b[h + 5] == "" and b[h + 6] == "" and b[h + 7] == c + "R" \
			and not _blocked(sf, h + 5) and not _blocked(sf, h + 6) \
			and not _is_attacked(st, h + 5, opp) and not _is_attacked(st, h + 6, opp):
		res.append({"fr": s, "to": h + 6, "castle": "K"})
	if castling[c + "Q"] and b[h + 3] == "" and b[h + 2] == "" and b[h + 1] == "" and b[h] == c + "R" \
			and not _blocked(sf, h + 3) and not _blocked(sf, h + 2) and not _blocked(sf, h + 1) \
			and not _is_attacked(st, h + 3, opp) and not _is_attacked(st, h + 2, opp):
		res.append({"fr": s, "to": h + 2, "castle": "Q"})


## Plays m on a copy of st. Returns the new {"b", "f", "s"} plus "taken" (pieces removed:
## [{"p", "fx", "sq"}]), "cur" (where the moving piece ended, -1 if it was destroyed) and "notes".
func _apply(st: Dictionary, m: Dictionary) -> Dictionary:
	var b: Array = st["b"].duplicate()
	var f: Array = st["f"].duplicate()
	var sf: Array = st["s"].duplicate()
	var taken: Array = []
	var notes: Array = []
	var fr: int = m["fr"]
	var to: int = m["to"]
	var p: String = b[fr]
	var c := p[0]
	var cur := fr
	if m.get("bounce", false):
		var tf: Dictionary = f[to].duplicate(true)
		tf["ab"]["v"]["n"] = int(tf["ab"]["v"]["n"]) - 1
		if tf["ab"]["v"]["n"] <= 0:
			tf.erase("ab")
			notes.append("broke a shield")
		else:
			notes.append("bounced off a shield")
		f[to] = tf
	elif m.get("ranged", false):
		taken.append({"p": b[to], "fx": f[to], "sq": to})
		b[to] = ""
		f[to] = {}
	else:
		var vs: int = (fr >> 3) * 8 + (to & 7) if m.get("ep", false) else to
		if b[vs] != "":
			taken.append({"p": b[vs], "fx": f[vs], "sq": vs})
			b[vs] = ""
			f[vs] = {}
		b[to] = p
		f[to] = f[fr]
		b[fr] = ""
		f[fr] = {}
		cur = to
		if m.get("dup", false):
			b[fr] = p  # the copy carries no powerups
		var h := fr & ~7
		match m.get("castle", ""):
			"K":
				b[h + 5] = b[h + 7]
				f[h + 5] = f[h + 7]
				b[h + 7] = ""
				f[h + 7] = {}
			"Q":
				b[h + 3] = b[h]
				f[h + 3] = f[h]
				b[h] = ""
				f[h] = {}
		if m.get("promo", "") != "":
			b[to] = c + m["promo"]
			if f[to].get("ab", {}).get("id", "") == "promote_early":
				f[to] = _without(f[to], "ab")
		# Landing on a special square.
		if sf[to].has("mine"):
			sf[to] = _without(sf[to], "mine")
			if p[1] != "K":
				taken.append({"p": b[to], "fx": f[to], "sq": to})
				b[to] = ""
				f[to] = {}
				cur = -1
				notes.append("hit a mine")
		if cur != -1 and sf[cur].has("portal"):
			var dest: int = sf[cur]["portal"]["pair"]
			if b[dest] == "" and _pawn_ok(b[cur], dest):
				b[dest] = b[cur]
				f[dest] = f[cur]
				b[cur] = ""
				f[cur] = {}
				cur = dest
				notes.append("went through a portal")
		if cur != -1 and sf[cur].has("pickup"):
			var pk: Dictionary = sf[cur]["pickup"]
			if pk["owner"] != c:
				sf[cur] = _without(sf[cur], "pickup")
				notes.append("destroyed a pickup")
			elif not f[cur].has("ab") and b[cur][1] in String(Powerups.DEFS[pk["id"]]["types"]):
				sf[cur] = _without(sf[cur], "pickup")
				var nf: Dictionary = f[cur].duplicate(true)
				nf["ab"] = {"id": pk["id"], "v": pk["v"].duplicate(true)}
				f[cur] = nf
				notes.append("picked up " + Powerups.pu_name(pk["id"]))
	# Explosions (they can set off more explosions).
	var i := 0
	while i < taken.size():
		var t: Dictionary = taken[i]
		var tab: Dictionary = t["fx"].get("ab", {})
		if tab.get("id", "") == "explode":
			var rad: int = tab["v"]["radius"]
			var cf: int = t["sq"] & 7
			var cr: int = t["sq"] >> 3
			for q in 64:
				if b[q] != "" and b[q][1] != "K" and maxi(absi((q & 7) - cf), absi((q >> 3) - cr)) <= rad:
					taken.append({"p": b[q], "fx": f[q], "sq": q})
					if q == cur:
						cur = -1
					b[q] = ""
					f[q] = {}
			notes.append("set off an explosion")
		i += 1
	# Use up the ability.
	var used: String = m.get("ab", "")
	if used != "" and cur != -1:
		var e: Dictionary = f[cur].get("ab", {})
		if e.get("id", "") == used:
			var nf: Dictionary = f[cur].duplicate(true)
			var v: Dictionary = nf["ab"]["v"]
			v["uses"] = int(v.get("uses", 1)) - 1
			if v["uses"] <= 0:
				nf.erase("ab")
			f[cur] = nf
	return {"b": b, "f": f, "s": sf, "taken": taken, "cur": cur, "notes": notes}


func _legal_from(s: int) -> Array:
	var res: Array = []
	var p: String = board[s]
	if p == "":
		return res
	var st := _st()
	for m in _pseudo_moves(st, s):
		if not _in_check(_apply(st, m), p[0]):
			res.append(m)
	return res


## Legal moves the player may actually pick right now (respects a pending extra move).
func _moves_for_ui(s: int) -> Array:
	if not extra.is_empty() and extra["sq"] != -1 and s != extra["sq"]:
		return []
	var res: Array = []
	for m in _legal_from(s):
		if extra.get("cap", false) and not _is_capture(m):
			continue
		res.append(m)
	return res


func _is_capture(m: Dictionary) -> bool:
	return board[m["to"]] != "" or m.get("ep", false)


func _has_any_legal(c: String) -> bool:
	for s in 64:
		var p: String = board[s]
		if p != "" and p[0] == c and not _moves_for_ui(s).is_empty():
			return true
	return false


## Makes a move for real. Network/local entry point is _play().
func _do_move(m: Dictionary) -> void:
	var side := turn
	var fr: int = m["fr"]
	var to: int = m["to"]
	var p: String = board[fr]
	var ab_before: Dictionary = fx[fr].get("ab", {})
	move_list.append(_uci(m))
	pos_version += 1
	hint_move = []
	if engine != null:
		engine.cancel()
	var res := _apply(_st(), m)
	board = res["b"]
	fx = res["f"]
	sqfx = res["s"]
	_record_taken(res["taken"], side)
	if p[1] == "K":
		castling[side + "K"] = false
		castling[side + "Q"] = false
	_fix_castling()
	var cur: int = res["cur"]
	ep_square = (fr + to) / 2 if p[1] == "P" and absi(to - fr) == 16 and cur == to else -1
	last_move = [fr, to]
	selected = -1
	selected_moves = []
	promo_pending = {}
	if not res["notes"].is_empty():
		_event("%s's %s %s" % [_side_name(side), Powerups.PIECE_NAMES[p[1]], ", ".join(res["notes"])])
	extra = {}
	match m.get("ab", ""):
		"move_twice":
			if cur != -1:
				extra = {"sq": cur if ab_before.get("v", {}).get("same", false) else -1, "cap": false}
		"chain":
			if cur != -1:
				extra = {"sq": cur, "cap": true}
	if not extra.is_empty() and not _has_any_legal(side):
		extra = {}
	if extra.is_empty():
		_end_turn()
	else:
		_event("%s gets an extra %s" % [_side_name(side), "capture" if extra["cap"] else "move"])
		_update_status()


## Scores and stores pieces that left the board.
func _record_taken(taken: Array, side: String) -> void:
	for t in taken:
		var pc: String = t["p"]
		var tf: Dictionary = t["fx"]
		if tf.get("decoy", false):
			_event("The %s was a decoy!" % Powerups.PIECE_NAMES[pc[1]])
			continue
		var col := pc[0]
		var taker := _opp(col)
		captured[taker].append(pc)
		captured[taker].sort_custom(func(a: String, b: String): return CAP_ORDER.find(a[1]) < CAP_ORDER.find(b[1]))
		lost[col].append(pc)
		var pts: int = PIECE_VALUE[pc[1]] + int(tf.get("bounty", 0))
		if double_next[taker] and taker == side:
			pts *= 2
			double_next[taker] = false
		score[taker] += pts


## Castling rights only survive while the king and that rook are on their home squares.
func _fix_castling() -> void:
	for c in ["w", "b"]:
		var h := 0 if c == "w" else 56
		if board[h + 4] != c + "K":
			castling[c + "K"] = false
			castling[c + "Q"] = false
		if board[h + 7] != c + "R":
			castling[c + "K"] = false
		if board[h] != c + "R":
			castling[c + "Q"] = false


## The side to move has finished: tick timers, then hand the turn over.
func _end_turn() -> void:
	var side := turn
	extra = {}
	for q in 64:
		if board[q] == "" or fx[q].is_empty():
			continue
		var col: String = board[q][0]
		if fx[q].has("frozen") and col == side:
			var nf: Dictionary = fx[q].duplicate(true)
			nf["frozen"] = int(nf["frozen"]) - 1
			if nf["frozen"] <= 0:
				nf.erase("frozen")
			fx[q] = nf
		var ab: Dictionary = fx[q].get("ab", {})
		if ab.get("id", "") == "shield" and ab["v"]["mode"] == "turns" and col != side:
			var nf: Dictionary = fx[q].duplicate(true)
			nf["ab"]["v"]["n"] = int(nf["ab"]["v"]["n"]) - 1
			if nf["ab"]["v"]["n"] <= 0:
				nf.erase("ab")
			fx[q] = nf
	for q in 64:
		for key in ["wall", "portal"]:
			if sqfx[q].has(key) and sqfx[q][key]["owner"] != side:
				var ns: Dictionary = sqfx[q].duplicate(true)
				ns[key]["turns"] = int(ns[key]["turns"]) - 1
				if ns[key]["turns"] <= 0:
					ns.erase(key)
				sqfx[q] = ns
	turn = _opp(side)
	_turn_started()


func _turn_started() -> void:
	targeting = {}
	_update_status()
	if not game_over and _gets_powerups(turn):
		var g := _roll_grant(turn)
		if not g.is_empty():
			_exec(g, true)
	queue_redraw()


func _update_status() -> void:
	var side := _side_name(turn)
	var check := _in_check(_st(), turn)
	end_turn_btn.visible = not extra.is_empty() and _human_turn() and not game_over
	if not _has_any_legal(turn):
		if not extra.is_empty():
			extra = {}
			_end_turn()
			return
		game_over = true
		if check:
			status_label.text = "Checkmate! %s wins" % _side_name(_opp(turn))
			_show_eval(0.0 if turn == "w" else 1.0, "0-1" if turn == "w" else "1-0", turn == "b")
		else:
			status_label.text = "Stalemate - draw"
			_show_eval(0.5, "1/2", true)
		end_turn_btn.visible = false
	else:
		game_over = false
		status_label.text = side + " to move" + ("  (check!)" if check else "")
		if not extra.is_empty():
			status_label.text += "  - extra %s" % ("capture" if extra["cap"] else "move")
		if engine_enabled and turn != human_color:
			status_label.text += "  - Stockfish thinking (depth %d)..." % engine_depth
		elif online:
			status_label.text += "  - your move" if turn == my_color else "  - opponent's move"
	if online:
		status_label.text = "[Online: you are %s]  " % _side_name(my_color) + status_label.text
	score_label.text = "Score   White %d  |  Black %d" % [score["w"], score["b"]]


static func _side_name(c: String) -> String:
	return "White" if c == "w" else "Black"


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
		if not targeting.is_empty():
			_event("")
		targeting = {}
		_update_cards_ui()
		selected = -1
		selected_moves = []
		dragging = false
		promo_pending = {}
		queue_redraw()
	elif event is InputEventMouseMotion:
		drag_pos = get_local_mouse_position()
		_update_cursor()
		_update_board_hover()
		if dragging:
			queue_redraw()


func _on_press(d: Vector2i) -> void:
	if not promo_pending.is_empty():
		var cells := _promo_cells()
		var i := cells.find(d)
		if i != -1:
			for m in promo_pending["moves"]:
				if m["promo"] == PROMO_CHOICES[i]:
					_play(m)
					break
		promo_pending = {}
		queue_redraw()
		return
	if not targeting.is_empty():
		_on_target_click(d)
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
		selected_moves = _moves_for_ui(s)
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
	_play(matches[0])
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

	_draw_powerup_squares()

	for s in last_move:
		draw_rect(_disp_rect(_sq_to_disp(s)), Color(1.0, 0.85, 0.2, 0.4))

	if _in_check(_st(), turn):
		draw_rect(_disp_rect(_sq_to_disp(board.find(turn + "K"))), Color(0.9, 0.15, 0.15, 0.55))

	if selected != -1:
		draw_rect(_disp_rect(_sq_to_disp(selected)), Color(0.35, 0.8, 0.45, 0.5))

	for s in 64:
		var p: String = board[s]
		if p == "" or (dragging and s == selected):
			continue
		_draw_piece(p, _disp_rect(_sq_to_disp(s)))

	_draw_powerup_pieces()
	_draw_targeting()

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


# ---------------------------------------------------------------- LAN multiplayer

func _build_mp_panel(layer: CanvasLayer) -> void:
	mp_panel = PanelContainer.new()
	mp_panel.visible = false
	mp_panel.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	var style := StyleBoxFlat.new()
	style.bg_color = BAR_BLACK
	style.border_color = BORDER_COL
	style.set_border_width_all(3)
	style.set_corner_radius_all(4)
	mp_panel.add_theme_stylebox_override("panel", style)
	layer.add_child(mp_panel)

	var margin := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 16)
	mp_panel.add_child(margin)
	var box := VBoxContainer.new()
	box.custom_minimum_size = Vector2(520, 0)
	box.add_theme_constant_override("separation", 10)
	margin.add_child(box)

	var title := Label.new()
	title.text = "LAN Multiplayer"
	title.add_theme_font_size_override("font_size", 32)
	box.add_child(title)

	var host_row := HBoxContainer.new()
	box.add_child(host_row)
	mp_name_edit = LineEdit.new()
	mp_name_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var user := OS.get_environment("USERNAME")
	if user == "":
		user = OS.get_environment("USER")
	mp_name_edit.text = (user + "'s game") if user != "" else "Chess game"
	mp_name_edit.placeholder_text = "Game name"
	host_row.add_child(mp_name_edit)
	mp_host_btn = Button.new()
	mp_host_btn.text = "Host"
	mp_host_btn.pressed.connect(_on_host_pressed)
	host_row.add_child(mp_host_btn)

	var found := Label.new()
	found.text = "Games on your network:"
	box.add_child(found)
	mp_lobby_list = ItemList.new()
	mp_lobby_list.custom_minimum_size = Vector2(0, 180)
	mp_lobby_list.item_activated.connect(func(_i: int): _on_join_selected())
	mp_lobby_list.item_selected.connect(func(_i: int): mp_join_btn.disabled = false)
	box.add_child(mp_lobby_list)

	var join_row := HBoxContainer.new()
	box.add_child(join_row)
	mp_join_btn = Button.new()
	mp_join_btn.text = "Join selected"
	mp_join_btn.disabled = true
	mp_join_btn.pressed.connect(_on_join_selected)
	join_row.add_child(mp_join_btn)
	mp_ip_edit = LineEdit.new()
	mp_ip_edit.placeholder_text = "or type an IP address"
	mp_ip_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	mp_ip_edit.text_submitted.connect(func(_t: String): _on_join_ip())
	join_row.add_child(mp_ip_edit)
	var join_ip := Button.new()
	join_ip.text = "Join IP"
	join_ip.pressed.connect(_on_join_ip)
	join_row.add_child(join_ip)

	mp_status = Label.new()
	mp_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(mp_status)

	var bottom := HBoxContainer.new()
	bottom.alignment = BoxContainer.ALIGNMENT_END
	box.add_child(bottom)
	var close := Button.new()
	close.text = "Close"
	close.pressed.connect(_close_mp_panel)
	bottom.add_child(close)


## Multiplayer button: opens the lobby panel, or leaves the online game.
func _on_mp_button() -> void:
	if online:
		_go_offline("You left the online game")
		return
	if mp_panel.visible:
		_close_mp_panel()
		return
	mp_panel.visible = true
	mp_panel.reset_size()
	mp_panel.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	if not lan.hosting:
		mp_status.text = ""
		var err := lan.start_browsing()
		if err != "":
			mp_status.text = err
	_refresh_lobby_list()


## Closing the panel while hosting cancels the hosted game.
func _close_mp_panel() -> void:
	mp_panel.visible = false
	if mp_from_menu and not online:
		mp_from_menu = false
		_show_menu()
	lan.stop_browsing()
	if lan.hosting and not online:
		lan.leave()
	mp_host_btn.disabled = false
	mp_host_btn.text = "Host"


func _on_host_pressed() -> void:
	if lan.hosting:  # button reads "Cancel" while waiting
		lan.leave()
		mp_host_btn.text = "Host"
		mp_status.text = "Stopped hosting"
		lan.start_browsing()
		return
	lan.stop_browsing()
	var err := lan.host(mp_name_edit.text.strip_edges())
	if err != "":
		mp_status.text = err
		lan.start_browsing()
		return
	mp_host_btn.text = "Cancel"
	mp_lobby_list.clear()
	mp_join_btn.disabled = true
	mp_status.text = "Hosting \"%s\" - waiting for an opponent...\nOthers can also join with your IP: %s" \
			% [mp_name_edit.text.strip_edges(), "  or  ".join(LanNet.local_ips())]


func _on_lobbies_changed(lobbies: Array) -> void:
	mp_lobbies = lobbies
	_refresh_lobby_list()


func _refresh_lobby_list() -> void:
	if mp_lobby_list == null:
		return
	mp_lobby_list.clear()
	for l in mp_lobbies:
		mp_lobby_list.add_item("%s   (%s)" % [l["name"], l["ip"]])
	mp_join_btn.disabled = mp_lobby_list.get_selected_items().is_empty()
	if mp_lobbies.is_empty() and lan.browsing:
		mp_lobby_list.add_item("Searching...", null, false)


func _on_join_selected() -> void:
	var sel := mp_lobby_list.get_selected_items()
	if sel.is_empty() or sel[0] >= mp_lobbies.size():
		return
	_join(mp_lobbies[sel[0]]["ip"])


func _on_join_ip() -> void:
	var ip := mp_ip_edit.text.strip_edges()
	if ip.is_valid_ip_address():
		_join(ip)
	else:
		mp_status.text = "That isn't a valid IP address"


func _join(ip: String) -> void:
	lan.stop_browsing()
	var err := lan.join(ip)
	if err != "":
		mp_status.text = err
		lan.start_browsing()
		return
	mp_host_btn.disabled = true
	mp_status.text = "Connecting to %s..." % ip


func _on_join_failed() -> void:
	mp_host_btn.disabled = false
	mp_status.text = "Couldn't connect. Check the IP and that the host's firewall allows the game."
	lan.start_browsing()


## Host side: the host keeps the side currently at the bottom of their board.
func _on_opponent_joined(peer_id: int) -> void:
	var host_color := "b" if flipped else "w"
	_go_online(host_color)
	_net_start.rpc_id(peer_id, _opp(host_color), powerups_on)


@rpc("authority", "call_remote", "reliable")
func _net_start(color: String, pu_on: bool) -> void:
	powerups_on = pu_on
	pu_toggle.set_pressed_no_signal(pu_on)
	_go_online(color)


func _go_online(color: String) -> void:
	online = true
	mp_from_menu = false
	my_color = color
	if engine_enabled:
		engine_enabled = false
		_cancel_search()
	engine_toggle.set_pressed_no_signal(false)
	engine_toggle.disabled = true
	pu_toggle.disabled = true
	flipped = color == "b"
	mp_panel.visible = false
	lan.stop_browsing()
	mp_host_btn.disabled = false
	mp_host_btn.text = "Host"
	mp_button.text = "Leave Online"
	new_game()


func _go_offline(reason: String) -> void:
	var was_online := online
	online = false
	lan.leave()
	engine_toggle.disabled = false
	pu_toggle.disabled = false
	mp_button.text = "Multiplayer"
	mp_host_btn.disabled = false
	mp_host_btn.text = "Host"
	if mp_panel.visible:
		mp_status.text = reason
		lan.start_browsing()
	_clear_selection()
	_update_status()
	if was_online:
		status_label.text = reason + "  -  " + status_label.text
	queue_redraw()
	_update_cursor()





func _on_new_game_pressed() -> void:
	if online:
		_net_new_game.rpc()
	new_game()


@rpc("any_peer", "call_remote", "reliable")
func _net_new_game() -> void:
	if online:
		new_game()


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		if lan != null and lan.is_inside_tree():
			lan.leave()


# ---------------------------------------------------------------- start menu

func _build_menu(layer: CanvasLayer) -> void:
	menu = ColorRect.new()
	(menu as ColorRect).color = Color8(36, 40, 52)
	menu.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	menu.mouse_filter = Control.MOUSE_FILTER_STOP
	layer.add_child(menu)

	var box := VBoxContainer.new()
	box.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	box.grow_horizontal = Control.GROW_DIRECTION_BOTH
	box.grow_vertical = Control.GROW_DIRECTION_BOTH
	box.custom_minimum_size = Vector2(360, 0)
	box.add_theme_constant_override("separation", 16)
	menu.add_child(box)

	var title := Label.new()
	title.text = "Pixel Chess"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 96)
	title.add_theme_color_override("font_color", LIGHT_COL)
	box.add_child(title)

	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(0, 24)
	box.add_child(spacer)

	for item in [["Solo Match", _on_menu_solo], ["Online Match (LAN)", _on_menu_online], ["Quit", _on_menu_quit]]:
		var b := Button.new()
		b.text = item[0]
		b.custom_minimum_size = Vector2(0, 56)
		b.add_theme_font_size_override("font_size", 32)
		b.pressed.connect(item[1])
		box.add_child(b)

	_show_menu()


func _show_menu() -> void:
	if online:
		_go_offline("You left the online game")
	if mp_panel != null and mp_panel.visible:
		mp_from_menu = false
		_close_mp_panel()
	_clear_selection()
	menu.visible = true
	top_bar.visible = false
	top_bar2.visible = false
	for c in card_boxes:
		card_boxes[c].visible = false
	_hide_hover()


func _hide_menu() -> void:
	menu.visible = false
	top_bar.visible = true
	top_bar2.visible = true
	_update_cards_ui()


## Solo: local two-player on this machine; Stockfish can be switched on from the top bar.
func _on_menu_solo() -> void:
	_hide_menu()
	new_game()


func _on_menu_online() -> void:
	_hide_menu()
	new_game()
	mp_from_menu = true
	if not mp_panel.visible:
		_on_mp_button()


func _on_menu_quit() -> void:
	if lan != null:
		lan.leave()
	get_tree().quit()


# ---------------------------------------------------------------- powerups

## Every change to the game goes through here so online games stay in sync.
## local = this player did it (send it to the opponent); false = it came from the opponent.
func _exec(a: Dictionary, local: bool) -> void:
	if local and online:
		_net_action.rpc(a)
	match a["t"]:
		"move":
			_do_move(a["m"])
		"grant":
			_apply_grant(a)
		"card":
			_apply_card(a, local)
		"end_extra":
			if not extra.is_empty():
				_end_turn()
	_update_captured_ui()
	_update_cards_ui()
	_update_status_only()
	queue_redraw()
	_update_cursor()


## Refreshes the score/status text without re-checking for the end of the game.
func _update_status_only() -> void:
	if score_label != null:
		score_label.text = "Score   White %d  |  Black %d" % [score["w"], score["b"]]
	if end_turn_btn != null:
		end_turn_btn.visible = not extra.is_empty() and _human_turn() and not game_over


## A move picked by this player (or by Stockfish on this machine).
func _play(m: Dictionary) -> void:
	_exec({"t": "move", "m": m}, true)


@rpc("any_peer", "call_remote", "reliable")
func _net_action(a: Dictionary) -> void:
	if online:
		_exec(a, false)


func _gets_powerups(side: String) -> bool:
	if not powerups_on:
		return false
	if online:
		return side == my_color
	return not engine_enabled or side == human_color


## The player that is looking at this screen can see hidden things (mines, decoys) of `owner`.
func _viewer_sees(owner: String) -> bool:
	if online:
		return owner == my_color
	if engine_enabled:
		return owner == human_color
	return true


func _event(text: String) -> void:
	event_text = text
	if event_label != null:
		event_label.text = text


func _roll_grant(side: String) -> Dictionary:
	var all: Array = Powerups.ids()
	for attempt in 16:
		var id: String = all[rng.randi_range(0, all.size() - 1)]
		var v := Powerups.roll(id, rng)
		if Powerups.is_card(id):
			if cards[side].size() >= Powerups.MAX_CARDS:
				continue
			return {"t": "grant", "side": side, "id": id, "v": v, "holder": "card"}
		var types: String = Powerups.DEFS[id]["types"]
		var pieces: Array = []
		for q in 64:
			var p: String = board[q]
			if p != "" and p[0] == side and p[1] in types and not fx[q].has("ab") and not fx[q].get("decoy", false):
				pieces.append(q)
		var spots: Array = []
		for q in 64:
			if board[q] == "" and sqfx[q].is_empty() and (q >> 3) >= 2 and (q >> 3) <= 5:
				spots.append(q)
		if not pieces.is_empty() and (spots.is_empty() or rng.randf() < 0.65):
			return {"t": "grant", "side": side, "id": id, "v": v, "holder": "piece",
					"sq": pieces[rng.randi_range(0, pieces.size() - 1)]}
		if not spots.is_empty():
			return {"t": "grant", "side": side, "id": id, "v": v, "holder": "square",
					"sq": spots[rng.randi_range(0, spots.size() - 1)]}
	return {}


func _apply_grant(a: Dictionary) -> void:
	var side: String = a["side"]
	var id: String = a["id"]
	var where := ""
	match a["holder"]:
		"card":
			cards[side].append({"id": id, "v": a["v"]})
			where = "a card"
		"piece":
			var q: int = a["sq"]
			var nf: Dictionary = fx[q].duplicate(true)
			nf["ab"] = {"id": id, "v": a["v"]}
			fx[q] = nf
			where = "on their %s (%s)" % [Powerups.PIECE_NAMES[board[q][1]], _sq_name(q)]
		"square":
			var q: int = a["sq"]
			var ns: Dictionary = sqfx[q].duplicate(true)
			ns["pickup"] = {"owner": side, "id": id, "v": a["v"]}
			sqfx[q] = ns
			where = "as a pickup on %s" % _sq_name(q)
	pos_version += 1
	_event("%s got %s %s" % [_side_name(side), Powerups.pu_name(id), where])


# ---------------------------------------------------------------- cards

## "" if `side` can use card `idx` right now, otherwise why not.
func _card_block_reason(side: String) -> String:
	if game_over:
		return "The game is over"
	if side != turn:
		return "Not your turn"
	if online and side != my_color:
		return "Not your card"
	if engine_enabled and side != human_color:
		return "Stockfish's card"
	if not promo_pending.is_empty():
		return "Pick a promotion first"
	return ""


func _on_card_pressed(side: String, idx: int) -> void:
	if _card_block_reason(side) != "" or idx >= cards[side].size():
		return
	if targeting.get("slot", -1) == idx:
		targeting = {}
		_event("")
		queue_redraw()
		_update_cards_ui()
		return
	_clear_selection()
	var c: Dictionary = cards[side][idx]
	var id: String = c["id"]
	var v: Dictionary = c["v"]
	var a := {"t": "card", "side": side, "slot": idx, "id": id, "v": v, "picks": [], "res": null}
	match id:
		"revive":
			var r := _revive_target(side)
			if r.is_empty():
				_event("Nothing to revive (no lost pieces, or their starting squares are taken)")
				return
			a["res"] = r
			_exec(a, true)
		"board_change":
			a["res"] = _roll_holes(v)
			_exec(a, true)
		"double_score":
			_exec(a, true)
		"best_move":
			var err := _ensure_engine()
			if err != "":
				_event("Best Move needs Stockfish: " + err)
				return
			_exec(a, true)
		"gain_taken":
			if _gain_choices(side).is_empty():
				_event("You haven't captured anything you can place yet")
				return
			targeting = {"slot": idx, "id": id, "v": v, "picks": []}
		_:
			targeting = {"slot": idx, "id": id, "v": v, "picks": []}
	if not targeting.is_empty():
		_event(_target_prompt())
	queue_redraw()
	_update_cards_ui()


func _picks_needed(id: String) -> int:
	return 2 if id in ["teleport", "gain_taken", "swap", "castle_any", "portal"] else 1


func _target_prompt() -> String:
	var id: String = targeting["id"]
	var step: int = targeting["picks"].size()
	var prompts := {
		"teleport": ["Choose a piece to teleport", "Choose an empty square"],
		"gain_taken": ["Choose which captured piece to place", "Choose an empty square"],
		"swap": ["Choose a piece to swap", "Choose the piece to swap it with"],
		"castle_any": ["Choose a piece to castle", "Choose a piece it meets on a rank or file"],
		"decoy": ["Choose an empty square in your half for the decoy"],
		"freeze": ["Choose an enemy piece to freeze"],
		"convert": ["Choose an enemy piece to convert"],
		"wall": ["Choose an empty square for the wall"],
		"portal": ["Choose the first portal square", "Choose the second portal square"],
		"mine": ["Choose an empty square for the mine"],
		"bounty": ["Choose an enemy piece to put a bounty on"],
		"spin": ["Choose one of your pieces to spin"],
	}
	return "%s: %s  (right-click to cancel)" % [Powerups.pu_name(id), prompts[id][step]]


## Enemy piece types you've captured that can be placed back as yours (Gain Taken Piece).
func _gain_choices(side: String) -> Array:
	var types: Array = []
	for pc in captured[side]:
		if pc[1] != "K" and not types.has(pc[1]):
			types.append(pc[1])
	return types


func _gain_cells() -> Array:
	var n := _gain_choices(turn).size()
	var cells: Array = []
	var start := (8 - n) / 2
	for i in n:
		cells.append(Vector2i(start + i, 3))
	return cells


## Can square q be picked for the current targeting step?
func _target_valid(q: int) -> bool:
	var side := turn
	var id: String = targeting["id"]
	var v: Dictionary = targeting["v"]
	var picks: Array = targeting["picks"]
	var step := picks.size()
	var p: String = board[q]
	var own := p != "" and p[0] == side
	var enemy := p != "" and p[0] != side and not _hidden_decoy_matters(q)
	var plain: bool = p == "" and sqfx[q].is_empty()
	match id:
		"teleport":
			if step == 0:
				return own and p[1] != "K"
			var fr: int = picks[0]
			if p != "" or _blocked(sqfx, q) or not _pawn_ok(board[fr], q):
				return false
			if v.get("range", 0) > 0 and maxi(absi((q & 7) - (fr & 7)), absi((q >> 3) - (fr >> 3))) > v["range"]:
				return false
			return _safe_after_moves([[fr, q]])
		"gain_taken":
			return p == "" and not _blocked(sqfx, q) and _pawn_ok(side + String(picks[0]), q)
		"swap":
			if step == 0:
				return own
			return own and q != picks[0] and _pawn_ok(p, picks[0]) and _pawn_ok(board[picks[0]], q) \
					and _safe_after_swap(picks[0], q)
		"castle_any":
			if step == 0:
				if not own:
					return false
				for o in 64:
					if o != q and board[o] != "" and board[o][0] == side and _meets(q, o) \
							and _pawn_ok(p, o) and _pawn_ok(board[o], q):
						return true
				return false
			return own and q != picks[0] and _meets(picks[0], q) and _pawn_ok(p, picks[0]) \
					and _pawn_ok(board[picks[0]], q) and _safe_after_swap(picks[0], q)
		"decoy":
			var rank := q >> 3
			var mine_half := rank <= 3 if side == "w" else rank >= 4
			return plain and mine_half and _pawn_ok(side + String(v.get("type", "N")), q)
		"freeze":
			return enemy and p[1] != "K" and not fx[q].has("frozen")
		"convert":
			return enemy and p[1] != "K" and (v.get("any", false) or p[1] == "P")
		"wall", "mine":
			return plain
		"portal":
			return plain and (step == 0 or q != picks[0])
		"bounty":
			return enemy and p[1] != "K" and not fx[q].has("bounty")
		"spin":
			return own and p[1] != "K"
	return false


## Decoys look real to the other player, so they can still be targeted by them.
func _hidden_decoy_matters(_q: int) -> bool:
	return false


## Two pieces "meet" when they share a rank or file with nothing between them.
func _meets(a: int, b: int) -> bool:
	var dx := (b & 7) - (a & 7)
	var dy := (b >> 3) - (a >> 3)
	if dx != 0 and dy != 0:
		return false
	return _ray_clear(_st(), a, b, 0)


## Would our king be safe after moving these pieces around? relocations: [[from, to], ...]
func _safe_after_moves(relocations: Array) -> bool:
	var b: Array = board.duplicate()
	var f: Array = fx.duplicate()
	for r in relocations:
		b[r[1]] = board[r[0]]
		f[r[1]] = fx[r[0]]
		b[r[0]] = ""
		f[r[0]] = {}
	return not _in_check({"b": b, "f": f, "s": sqfx}, turn)


func _safe_after_swap(a: int, b2: int) -> bool:
	var b: Array = board.duplicate()
	var f: Array = fx.duplicate()
	b[a] = board[b2]
	b[b2] = board[a]
	f[a] = fx[b2]
	f[b2] = fx[a]
	return not _in_check({"b": b, "f": f, "s": sqfx}, turn)


func _on_target_click(d: Vector2i) -> void:
	var id: String = targeting["id"]
	var picks: Array = targeting["picks"]
	if id == "gain_taken" and picks.is_empty():
		var i := _gain_cells().find(d)
		if i == -1:
			return
		picks.append(_gain_choices(turn)[i])
	else:
		if d.x < 0:
			return
		var q := _disp_to_sq(d)
		if not _target_valid(q):
			return
		picks.append(q)
	if picks.size() < _picks_needed(id):
		_event(_target_prompt())
		queue_redraw()
		return
	var a := {"t": "card", "side": turn, "slot": targeting["slot"], "id": id, "v": targeting["v"],
			"picks": picks, "res": null}
	match id:
		"wall":
			a["res"] = _wall_squares(picks[0], targeting["v"])
		"spin":
			a["res"] = _roll_spin(picks[0])
	targeting = {}
	_exec(a, true)


func _wall_squares(q: int, v: Dictionary) -> Array:
	var res: Array = [q]
	if v.get("len", 1) == 3:
		for dx in [-1, 1]:
			var nf: int = (q & 7) + dx
			if nf >= 0 and nf < 8:
				var n: int = (q >> 3) * 8 + nf
				if board[n] == "" and sqfx[n].is_empty():
					res.append(n)
	return res


func _roll_spin(q: int) -> String:
	var outcomes: Array = []
	for col in ["w", "b"]:
		for t in ["P", "N", "B", "R", "Q"]:
			if _pawn_ok(col + t, q):
				outcomes.append(col + t)
	return outcomes[rng.randi_range(0, outcomes.size() - 1)]


func _roll_holes(v: Dictionary) -> Array:
	var res: Array = []
	if v.get("mode", "") == "edge":
		var file := 0 if rng.randf() < 0.5 else 7
		for r in 8:
			var q := r * 8 + file
			if board[q] == "" and sqfx[q].is_empty():
				res.append(q)
	else:
		var spots: Array = []
		for q in 64:
			if board[q] == "" and sqfx[q].is_empty() and (q >> 3) >= 2 and (q >> 3) <= 5:
				spots.append(q)
		for i in mini(3, spots.size()):
			res.append(spots.pop_at(rng.randi_range(0, spots.size() - 1)))
	return res


## Revive: your most recently lost piece and a free starting square for it. {} if impossible.
func _revive_target(side: String) -> Dictionary:
	var lostp: Array = lost[side]
	for i in range(lostp.size() - 1, -1, -1):
		var pc: String = lostp[i]
		var home := 0 if side == "w" else 7
		var files: Array = []
		match pc[1]:
			"P":
				home = 1 if side == "w" else 6
				files = [0, 1, 2, 3, 4, 5, 6, 7]
			"N":
				files = [1, 6]
			"B":
				files = [2, 5]
			"R":
				files = [0, 7]
			"Q":
				files = [3]
		for fl in files:
			var q: int = home * 8 + fl
			if board[q] == "" and not _blocked(sqfx, q):
				return {"p": pc, "sq": q, "i": i}
		return {}
	return {}


func _apply_card(a: Dictionary, local: bool) -> void:
	var side: String = a["side"]
	var id: String = a["id"]
	var v: Dictionary = a["v"]
	var picks: Array = a["picks"]
	if int(a["slot"]) < cards[side].size():
		cards[side].remove_at(int(a["slot"]))
	var msg := "%s used %s" % [_side_name(side), Powerups.pu_name(id)]
	match id:
		"teleport":
			_relocate(picks[0], picks[1])
		"gain_taken":
			var t: String = picks[0]
			for i in captured[side].size():
				if captured[side][i][1] == t:
					captured[side].remove_at(i)
					break
			board[picks[1]] = side + t
			fx[picks[1]] = {}
		"swap", "castle_any":
			var x: int = picks[0]
			var y: int = picks[1]
			var tp: String = board[x]
			var tf: Dictionary = fx[x]
			board[x] = board[y]
			fx[x] = fx[y]
			board[y] = tp
			fx[y] = tf
		"revive":
			var r: Dictionary = a["res"]
			board[r["sq"]] = r["p"]
			fx[r["sq"]] = {}
			lost[side].remove_at(int(r["i"]))
			var opp_row: Array = captured[_opp(side)]
			var k := opp_row.find(r["p"])
			if k != -1:
				opp_row.remove_at(k)
			msg += " - %s is back" % Powerups.PIECE_NAMES[String(r["p"])[1]]
		"decoy":
			board[picks[0]] = side + String(v.get("type", "N"))
			fx[picks[0]] = {"decoy": true}
			if not _viewer_sees(side):
				msg = "%s placed a new %s" % [_side_name(side), Powerups.PIECE_NAMES[String(v.get("type", "N"))]]
		"freeze":
			var nf: Dictionary = fx[picks[0]].duplicate(true)
			nf["frozen"] = v["turns"]
			fx[picks[0]] = nf
		"convert":
			board[picks[0]] = side + board[picks[0]][1]
			fx[picks[0]] = {}
		"wall":
			for q in a["res"]:
				var ns: Dictionary = sqfx[q].duplicate(true)
				ns["wall"] = {"turns": v["turns"], "owner": side}
				sqfx[q] = ns
		"portal":
			portal_count += 1
			for i in 2:
				var ns: Dictionary = sqfx[picks[i]].duplicate(true)
				ns["portal"] = {"pair": picks[1 - i], "turns": v["turns"], "owner": side, "id": portal_count}
				sqfx[picks[i]] = ns
		"mine":
			var ns: Dictionary = sqfx[picks[0]].duplicate(true)
			ns["mine"] = {"owner": side}
			sqfx[picks[0]] = ns
			if not _viewer_sees(side):
				msg = "%s hid a mine somewhere..." % _side_name(side)
		"board_change":
			for q in a["res"]:
				sqfx[q] = {"hole": true}
		"double_score":
			double_next[side] = true
		"bounty":
			var nf: Dictionary = fx[picks[0]].duplicate(true)
			nf["bounty"] = v.get("bonus", 5)
			fx[picks[0]] = nf
		"spin":
			var res: String = a["res"]
			board[picks[0]] = res
			fx[picks[0]] = {}
			msg += " - it landed on %s %s%s" % [_side_name(res[0]).to_lower(), Powerups.PIECE_NAMES[res[1]],
					"!" if res[0] == side else " - an enemy piece!"]
		"best_move":
			if local:
				hint_pending = true
				msg += " - asking Stockfish..."
	targeting = {}
	_fix_castling()
	pos_version += 1
	analyzed_version = -1
	if engine != null:
		engine.cancel()
	_event(msg)
	_update_status()


## Moves a piece (with its powerups) without it counting as a move.
func _relocate(fr: int, to: int) -> void:
	board[to] = board[fr]
	fx[to] = fx[fr]
	board[fr] = ""
	fx[fr] = {}


# ---------------------------------------------------------------- powerup UI

func _build_powerup_ui(layer: CanvasLayer) -> void:
	for c in ["w", "b"]:
		var box := VBoxContainer.new()
		box.add_theme_constant_override("separation", 6)
		box.custom_minimum_size = Vector2(230, 0)
		layer.add_child(box)
		card_boxes[c] = box

	hover_panel = PanelContainer.new()
	hover_panel.visible = false
	hover_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var style := StyleBoxFlat.new()
	style.bg_color = Color(BAR_BLACK, 0.95)
	style.border_color = BORDER_COL
	style.set_border_width_all(2)
	style.set_content_margin_all(10)
	hover_panel.add_theme_stylebox_override("panel", style)
	hover_label = Label.new()
	hover_label.custom_minimum_size = Vector2(320, 0)
	hover_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hover_label.add_theme_color_override("font_color", LIGHT_COL)
	hover_panel.add_child(hover_label)
	layer.add_child(hover_panel)


func _update_cards_ui() -> void:
	if card_boxes.is_empty():
		return
	var s := scale.x
	for c in ["w", "b"]:
		var box: VBoxContainer = card_boxes[c]
		for child in box.get_children():
			box.remove_child(child)
			child.queue_free()
		box.visible = powerups_on or not cards[c].is_empty()
		var title := Label.new()
		title.text = "%s's cards" % _side_name(c)
		title.add_theme_color_override("font_color", LIGHT_COL)
		box.add_child(title)
		var blocked := _card_block_reason(c)
		for i in Powerups.MAX_CARDS:
			var btn := Button.new()
			btn.custom_minimum_size = Vector2(230, 44)
			btn.focus_mode = Control.FOCUS_NONE
			var st := StyleBoxFlat.new()
			st.bg_color = BAR_BLACK
			st.set_border_width_all(3)
			st.set_corner_radius_all(3)
			if i < cards[c].size():
				var card: Dictionary = cards[c][i]
				btn.text = Powerups.pu_name(card["id"])
				st.border_color = Powerups.color(card["id"])
				if targeting.get("slot", -1) == i and c == turn:
					st.bg_color = Color(Powerups.color(card["id"]), 0.45)
				btn.disabled = blocked != ""
				var tip := Powerups.describe(card["id"], card["v"])
				if blocked != "":
					tip += "\n(" + blocked + ")"
				btn.mouse_entered.connect(_show_hover_text.bind(tip))
				btn.mouse_exited.connect(_hide_hover)
				btn.pressed.connect(_on_card_pressed.bind(c, i))
			else:
				btn.text = "-"
				btn.disabled = true
				st.border_color = BORDER_COL
			for k in ["normal", "hover", "pressed", "disabled"]:
				btn.add_theme_stylebox_override(k, st)
			btn.add_theme_color_override("font_disabled_color", Color(LIGHT_COL, 0.55))
			btn.add_theme_color_override("font_color", LIGHT_COL)
			btn.add_theme_color_override("font_hover_color", Color.WHITE)
			box.add_child(btn)
		box.reset_size()
		var x := position.x + (BOARD_PX + 6) * s
		var bottom := "b" if flipped else "w"
		if c == bottom:
			box.position = Vector2(x, position.y + (OFF + 8 * SQ) * s - box.get_combined_minimum_size().y)
		else:
			box.position = Vector2(x, position.y + OFF * s)


func _show_hover_text(text: String) -> void:
	hover_label.text = text
	hover_panel.visible = true
	hover_panel.reset_size()
	_place_hover()


func _hide_hover() -> void:
	hover_panel.visible = false


func _place_hover() -> void:
	var mp := get_viewport().get_mouse_position()
	var vs := get_viewport_rect().size
	var sz := hover_panel.get_combined_minimum_size()
	var pos := mp + Vector2(20, 20)
	if pos.x + sz.x > vs.x:
		pos.x = mp.x - sz.x - 12
	if pos.y + sz.y > vs.y:
		pos.y = mp.y - sz.y - 12
	hover_panel.position = pos


## Hover info for the board square under the mouse.
func _update_board_hover() -> void:
	if hover_panel == null or menu.visible or mp_panel.visible:
		return
	var d := _mouse_disp()
	if d.x < 0 or dragging:
		if hover_panel.visible and hover_label.get_meta("board", false):
			_hide_hover()
		return
	var q := _disp_to_sq(d)
	var lines: Array = []
	var p: String = board[q]
	if p != "":
		var e: Dictionary = fx[q]
		var pname := "%s %s" % [_side_name(p[0]), Powerups.PIECE_NAMES[p[1]]]
		if e.get("decoy", false) and _viewer_sees(p[0]):
			pname += " (DECOY - fake)"
		if e.has("ab"):
			lines.append(pname)
			lines.append(Powerups.describe(e["ab"]["id"], e["ab"]["v"]))
		if e.has("frozen"):
			lines.append("Frozen for %d more turn%s" % [e["frozen"], "" if e["frozen"] == 1 else "s"])
		if e.has("bounty"):
			lines.append("Bounty: +%d points if captured" % e["bounty"])
		if e.get("decoy", false) and _viewer_sees(p[0]) and not e.has("ab"):
			lines.push_front(pname)
		if not lines.is_empty() and lines[0] != pname:
			lines.push_front(pname)
	var sq: Dictionary = sqfx[q]
	if sq.has("wall"):
		lines.append("Wall - blocked for %d more turn%s" % [sq["wall"]["turns"], "" if sq["wall"]["turns"] == 1 else "s"])
	if sq.has("hole"):
		lines.append("Hole - this square is gone")
	if sq.has("portal"):
		lines.append("Portal to %s (%d turn%s left)" % [_sq_name(sq["portal"]["pair"]), sq["portal"]["turns"],
				"" if sq["portal"]["turns"] == 1 else "s"])
	if sq.has("mine") and _viewer_sees(sq["mine"]["owner"]):
		lines.append("%s's hidden mine" % _side_name(sq["mine"]["owner"]))
	if sq.has("pickup"):
		var pk: Dictionary = sq["pickup"]
		lines.append("Pickup for %s - land a %s here to get:" % [_side_name(pk["owner"]),
				"/".join(_type_names(Powerups.DEFS[pk["id"]]["types"]))])
		lines.append(Powerups.describe(pk["id"], pk["v"]))
	if lines.is_empty():
		if hover_panel.visible and hover_label.get_meta("board", false):
			_hide_hover()
		return
	_show_hover_text("\n".join(lines))
	hover_label.set_meta("board", true)


static func _type_names(types: String) -> Array:
	var res: Array = []
	for t in types:
		res.append(Powerups.PIECE_NAMES[t])
	return res


func _draw_powerup_squares() -> void:
	for q in 64:
		var sq: Dictionary = sqfx[q]
		if sq.is_empty():
			continue
		var r := _disp_rect(_sq_to_disp(q))
		if sq.has("hole"):
			draw_rect(r, Color8(14, 15, 20))
		if sq.has("wall"):
			draw_rect(r, Color8(120, 86, 66))
			for row in 4:
				draw_rect(Rect2(r.position.x, r.position.y + row * 4 + 3, 16, 1), Color8(70, 48, 38))
				var off := 4 if row % 2 == 0 else 10
				draw_rect(Rect2(r.position.x + off, r.position.y + row * 4, 1, 3), Color8(70, 48, 38))
		if sq.has("portal"):
			var col := Color8(170, 120, 220) if int(sq["portal"]["id"]) % 2 == 1 else Color8(80, 200, 200)
			draw_rect(r.grow(-1.5), col, false, 1.0)
			draw_rect(r.grow(-3.5), Color(col, 0.6), false, 1.0)
		if sq.has("mine") and _viewer_sees(sq["mine"]["owner"]):
			var c := Color8(220, 60, 60)
			for i in 5:
				draw_rect(Rect2(r.position.x + 1 + i, r.position.y + 1 + i, 1, 1), c)
				draw_rect(Rect2(r.position.x + 5 - i, r.position.y + 1 + i, 1, 1), c)
		if sq.has("pickup") and board[q] == "":
			var col: Color = Powerups.color(sq["pickup"]["id"])
			var cx := r.position.x + 6
			var cy := r.position.y + 6
			draw_rect(Rect2(cx - 1, cy - 1, 6, 6), BAR_BLACK)
			draw_rect(Rect2(cx, cy, 4, 4), col)


func _draw_powerup_pieces() -> void:
	for q in 64:
		if board[q] == "" or fx[q].is_empty() or (dragging and q == selected):
			continue
		var e: Dictionary = fx[q]
		var r := _disp_rect(_sq_to_disp(q))
		if e.has("frozen"):
			draw_rect(r, Color(0.6, 0.85, 1.0, 0.45))
		if e.has("ab"):
			var col: Color = Powerups.color(e["ab"]["id"])
			if e["ab"]["id"] == "shield":
				draw_rect(r.grow(-0.5), Color8(120, 220, 255), false, 1.0)
			draw_rect(Rect2(r.position.x + 11, r.position.y, 5, 5), BAR_BLACK)
			draw_rect(Rect2(r.position.x + 12, r.position.y + 1, 3, 3), col)
		if e.has("bounty"):
			draw_rect(Rect2(r.position.x, r.position.y, 5, 5), BAR_BLACK)
			draw_rect(Rect2(r.position.x + 1, r.position.y + 1, 3, 3), Powerups.CAT_COLOR["economy"])
		if e.get("decoy", false) and _viewer_sees(board[q][0]):
			draw_rect(Rect2(r.position.x, r.position.y + 11, 5, 5), BAR_BLACK)
			draw_rect(Rect2(r.position.x + 1, r.position.y + 12, 3, 3), Color8(235, 110, 180))


func _draw_targeting() -> void:
	if not hint_move.is_empty():
		for q in hint_move:
			draw_rect(_disp_rect(_sq_to_disp(q)), Color(0.3, 0.6, 1.0, 0.45))
	if targeting.is_empty():
		return
	for q in targeting["picks"]:
		if q is int:
			draw_rect(_disp_rect(_sq_to_disp(q)), Color(1.0, 0.85, 0.2, 0.5))
	if targeting["id"] == "gain_taken" and targeting["picks"].is_empty():
		draw_rect(Rect2(OFF, OFF, 8 * SQ, 8 * SQ), Color(0, 0, 0, 0.55))
		var cells := _gain_cells()
		var types := _gain_choices(turn)
		for i in cells.size():
			var r := _disp_rect(cells[i])
			draw_rect(r, LIGHT_COL)
			draw_rect(r.grow(-0.5), BORDER_COL, false, 1.0)
			_draw_piece(turn + String(types[i]), r)
		return
	for q in 64:
		if _target_valid(q):
			draw_rect(_disp_rect(_sq_to_disp(q)), Color(0.3, 0.9, 0.4, 0.35))


# ---------------------------------------------------------------- stockfish position

## The current position as FEN, so Stockfish can judge whatever the powerups have done.
func _fen() -> String:
	var rows: Array = []
	for r in range(7, -1, -1):
		var row := ""
		var empty := 0
		for fl in 8:
			var p: String = board[r * 8 + fl]
			if p == "":
				empty += 1
				continue
			if empty > 0:
				row += str(empty)
				empty = 0
			row += p[1] if p[0] == "w" else p[1].to_lower()
		if empty > 0:
			row += str(empty)
		rows.append(row)
	var cs := ""
	if castling["wK"]:
		cs += "K"
	if castling["wQ"]:
		cs += "Q"
	if castling["bK"]:
		cs += "k"
	if castling["bQ"]:
		cs += "q"
	var ep := "-"
	if ep_square != -1:
		ep = _sq_name(ep_square)
	return "%s %s %s %s 0 1" % ["/".join(rows), turn, cs if cs != "" else "-", ep]


## Stockfish refuses positions without exactly one king each, with pawns on the back ranks,
## or where the side that just moved is in check (by plain chess rules).
func _fen_ok() -> bool:
	if board.count("wK") != 1 or board.count("bK") != 1:
		return false
	for q in 64:
		if board[q] != "" and not _pawn_ok(board[q], q):
			return false
	var plain := {"b": board, "f": EMPTY64, "s": EMPTY64}
	return not _in_check(plain, _opp(turn))


## Legal moves of the side to move, in UCI, so Stockfish only picks moves this game allows.
func _uci_moves() -> PackedStringArray:
	var res := PackedStringArray()
	for s in 64:
		var p: String = board[s]
		if p == "" or p[0] != turn:
			continue
		for m in _moves_for_ui(s):
			if not m.get("bounce", false) and not m.get("ranged", false):
				res.append(_uci(m))
	return res


## When Stockfish can't read the position: take the most valuable capture, else a random move.
func _fallback_move() -> Dictionary:
	var best: Dictionary = {}
	var best_val := -1
	var all: Array = []
	for s in 64:
		var p: String = board[s]
		if p == "" or p[0] != turn:
			continue
		for m in _moves_for_ui(s):
			all.append(m)
			var v := -1
			if board[m["to"]] != "" and not m.get("bounce", false):
				v = PIECE_VALUE[board[m["to"]][1]]
			if v > best_val:
				best_val = v
				best = m
	if best_val < 0 and not all.is_empty():
		best = all[rng.randi_range(0, all.size() - 1)]
	return best
