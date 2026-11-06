extends Node2D
## Solo Match: the sandbox. Two players on one machine, or you against the computer, with
## jokers to bend the game.
##
## Jokers (see Utilities/Jokers/jokers.gd) rearrange the starting pieces of one colour's half
## (layout jokers) or reshape the board (shape jokers: pits, walls, bastions). You add, re-roll
## and remove them freely in the Jokers panel; they take effect when a game starts.
##
## The rules live in BoardModel, which can play boards with holes, walls and bumps.
## Stockfish only understands the standard board, so it plays (and evaluates) those, and the
## built-in AI plays everything else.

const BoardModel := preload("res://Utilities/Jokers/board_model.gd")
const AiEngine := preload("res://Utilities/Jokers/ai_engine.gd")
const Jokers := preload("res://Utilities/Jokers/jokers.gd")
const UciEngine := preload("res://uci_engine.gd")
const Strength := preload("res://Utilities/Engine/strength.gd")

const MENU_SCENE := "res://Scenes/Board/Main.tscn"
const ASSET := "res://Assets/pixel chess_v1.2/"

const SQ := 16          # square size in board pixels
const OFF := 7          # frame thickness around the squares
const BORDER_COL := Color8(89, 96, 112)
const LIGHT_COL := Color8(234, 240, 216)
const BAR_BLACK := Color8(36, 40, 52)
const PIT_COL := Color8(20, 22, 30)
const WALL_LIGHT := Color8(160, 168, 188)
const NOTE_COL := Color8(255, 190, 110)
const KIND_COL := {Jokers.LAYOUT: Color8(120, 190, 255), Jokers.SHAPE: Color8(255, 170, 90)}

const SHEET_IDX := [0, 0, 1, 3, 2, 4, 5]    # sprite-sheet column by piece type (sheet is P N R B Q K)
const PIECE_VALUE := [0, 1, 3, 3, 5, 9, 0]  # by piece type
const PROMO_FROM_LETTER := {"n": 2, "b": 3, "r": 4, "q": 5}

# Evaluation bar, in board pixels (to the left of the board, which starts at x = 0).
const BAR_X := -14
const BAR_W := 8

# Captured pieces: a row above and below the board at half piece size. Half size only stays
# crisp at an even board scale, so _layout() keeps the scale even.
const CAP_H := 8
const CAP_GAP := 2

const PANEL_W := 380.0        # screen space the Jokers panel takes from the right edge

const SF_EVAL_DEPTH := 14     # Stockfish depth when it only evaluates
const SF_EVAL_MIN_DEPTH := 8  # shallower Stockfish scores are too noisy for the bar
const AI_EVAL_DEPTH := 3
const AI_EVAL_MIN_DEPTH := 2
const AI_MAX_DEPTH := 6
const AI_MOVE_MS := 2500      # the AI also stops thinking after this long
const AI_EVAL_MS := 900

var tex_board: Texture2D
var tex_white: Texture2D
var tex_black: Texture2D
var cursor_imgs: Array[Image] = []
var cursor_state := -1

# Game state
var pos                                # BoardModel
var standard                           # the standard setup, to recognise a standard game
var uses_stockfish := false            # this game starts from the standard setup
var game_over := false
var last_move: Array = []
var captured := [[], []]               # captured[c] = pieces colour c has taken, sorted pawn -> queen
var move_list := PackedStringArray()   # UCI moves, for Stockfish
var pos_version := 0
var analyzed_version := -1
var jokers: Array = []                 # active jokers, applied when a game starts
var jokers_dirty := false              # jokers changed after the current game started

# View: the box around the squares that exist (grid coordinates), and its size in board pixels.
var flipped := false
var bx0 := 0
var bx1 := 7
var by0 := 0
var by1 := 7
var cols := 8
var rows := 8
var board_w := 142
var board_h := 142

# UI state
var selected := -1
var selected_moves: Array = []
var dragging := false
var drag_pos := Vector2.ZERO
var promo_pending: Dictionary = {}

# Computer opponent. While enabled, the human plays human_color and the computer the other side.
var engine: UciEngine
var ai: AiEngine
var engine_enabled := false
var human_color := BoardModel.WHITE
var engine_depth := 4
var skill_level := 20     # Stockfish "Skill Level" for its moves (the eval bar always uses 20)
var mistake_rate := 0.0   # chance a move is replaced by a random legal one (see Strength)
var sf_failed := false
var search_for_move := false
var search_stockfish := false
var search_turn := BoardModel.WHITE

# Evaluation bar. eval_target / eval_display are White's share of the bar, 0..1.
var eval_enabled := true
var eval_target := 0.5
var eval_display := 0.5
var eval_text := ""
var eval_white_ahead := true

var status_label: Label
var engine_toggle: CheckButton
var eval_toggle: CheckButton
var level_option: OptionButton
var depth_box: SpinBox
var eval_label: Label
var cap_labels: Array = []
var jokers_button: Button
var joker_panel: PanelContainer
var joker_type: OptionButton
var joker_side: OptionButton
var joker_note: Label
var joker_list: VBoxContainer


func _ready() -> void:
	tex_board = load(ASSET + "boards/board_plain_01.png")
	tex_white = load(ASSET + "16x16 pieces/WhitePieces.png")
	tex_black = load(ASSET + "16x16 pieces/BlackPieces.png")
	standard = BoardModel.new()
	standard.setup_standard()
	_load_cursors()
	_build_ui()
	get_viewport().size_changed.connect(_layout)
	new_game()


# ---------------------------------------------------------------- UI

func _add_button(parent: Node, text: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	b.pressed.connect(cb)
	parent.add_child(b)
	return b


func _panel_style(border: Color) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = BAR_BLACK
	style.border_color = border
	style.set_border_width_all(3)
	style.set_corner_radius_all(4)
	return style


func _heading(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", 22)
	l.add_theme_color_override("font_color", LIGHT_COL)
	return l


func _wrapped(text: String, size: int, min_width: float) -> Label:
	var l := Label.new()
	l.text = text
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.custom_minimum_size = Vector2(min_width, 0)
	l.add_theme_font_size_override("font_size", size)
	return l


func _build_ui() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	var bar := HBoxContainer.new()
	bar.position = Vector2(12, 12)
	bar.add_theme_constant_override("separation", 12)
	layer.add_child(bar)

	_add_button(bar, "Menu", _go_menu)
	_add_button(bar, "Swap Colors", _swap_colors)
	_add_button(bar, "New Game", new_game)

	engine_toggle = CheckButton.new()
	engine_toggle.text = "Play vs Computer"
	engine_toggle.focus_mode = Control.FOCUS_NONE
	engine_toggle.tooltip_text = "Stockfish plays the normal board; the built-in AI plays boards changed by jokers."
	engine_toggle.toggled.connect(_set_engine_enabled)
	bar.add_child(engine_toggle)

	var level_label := Label.new()
	level_label.text = "Level"
	bar.add_child(level_label)
	level_option = OptionButton.new()
	level_option.focus_mode = Control.FOCUS_NONE
	for n in Strength.names():
		level_option.add_item(n)
	level_option.tooltip_text = Strength.tooltip()
	level_option.item_selected.connect(_apply_level)
	bar.add_child(level_option)

	var depth_label := Label.new()
	depth_label.text = "Depth"
	bar.add_child(depth_label)
	depth_box = SpinBox.new()
	depth_box.min_value = 1
	depth_box.max_value = 20
	depth_box.step = 1
	depth_box.rounded = true
	depth_box.value = engine_depth
	depth_box.tooltip_text = "How many plies the computer looks ahead. Editing it switches Level to Custom."
	depth_box.value_changed.connect(_on_depth_changed)
	bar.add_child(depth_box)
	_apply_level(Strength.DEFAULT)

	eval_toggle = CheckButton.new()
	eval_toggle.text = "Eval bar"
	eval_toggle.focus_mode = Control.FOCUS_NONE
	eval_toggle.set_pressed_no_signal(true)
	eval_toggle.toggled.connect(_set_eval_enabled)
	bar.add_child(eval_toggle)

	jokers_button = _add_button(bar, "Jokers", _toggle_joker_panel)

	status_label = Label.new()
	status_label.add_theme_font_size_override("font_size", 20)
	bar.add_child(status_label)

	# Score readout on the eval bar, and "+N" material leads. Screen-space Labels keep text sharp.
	eval_label = Label.new()
	eval_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	eval_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	eval_label.visible = false
	layer.add_child(eval_label)
	for c in 2:
		var lead := Label.new()
		lead.add_theme_color_override("font_color", LIGHT_COL)
		lead.mouse_filter = Control.MOUSE_FILTER_IGNORE
		lead.visible = false
		layer.add_child(lead)
		cap_labels.append(lead)

	_build_joker_panel(layer)


func _build_joker_panel(layer: CanvasLayer) -> void:
	joker_panel = PanelContainer.new()
	joker_panel.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	joker_panel.offset_left = -(PANEL_W - 16.0)
	joker_panel.offset_right = -16
	joker_panel.offset_top = 72
	joker_panel.add_theme_stylebox_override("panel", _panel_style(BORDER_COL))
	joker_panel.visible = false
	layer.add_child(joker_panel)

	var margin := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 12)
	joker_panel.add_child(margin)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	margin.add_child(box)

	box.add_child(_heading("Jokers"))
	box.add_child(_wrapped("Jokers change how a game starts. Layout jokers rearrange one colour's " \
			+ "half of the board; shape jokers reshape the board for both sides.", 13, 320))

	var pick := HBoxContainer.new()
	pick.add_theme_constant_override("separation", 6)
	joker_type = OptionButton.new()
	joker_type.focus_mode = Control.FOCUS_NONE
	for id in Jokers.ALL_IDS:
		joker_type.add_item("%s  (%s)" % [Jokers.INFO[id]["name"], Jokers.INFO[id]["kind"]])
	joker_type.item_selected.connect(_on_joker_type_selected)
	pick.add_child(joker_type)
	joker_side = OptionButton.new()
	joker_side.focus_mode = Control.FOCUS_NONE
	joker_side.add_item("White's half")
	joker_side.add_item("Black's half")
	joker_side.tooltip_text = "Which colour a layout joker rearranges."
	pick.add_child(joker_side)
	box.add_child(pick)

	var actions := HBoxContainer.new()
	actions.add_theme_constant_override("separation", 6)
	_add_button(actions, "Add", _add_selected_joker)
	_add_button(actions, "Random", func(): _add_joker(Jokers.random_joker()))
	_add_button(actions, "Clear all", _clear_jokers)
	box.add_child(actions)

	joker_note = _wrapped("Jokers changed - press New Game to use them.", 14, 320)
	joker_note.add_theme_color_override("font_color", NOTE_COL)
	joker_note.visible = false
	box.add_child(joker_note)

	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(330, 430)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	box.add_child(scroll)
	joker_list = VBoxContainer.new()
	joker_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	joker_list.add_theme_constant_override("separation", 8)
	scroll.add_child(joker_list)
	_refresh_joker_list()


# ---------------------------------------------------------------- jokers

func _go_menu() -> void:
	get_tree().change_scene_to_file(MENU_SCENE)


func _toggle_joker_panel() -> void:
	joker_panel.visible = not joker_panel.visible
	_layout()


func _on_joker_type_selected(i: int) -> void:
	joker_side.disabled = Jokers.INFO[Jokers.ALL_IDS[i]]["kind"] == Jokers.SHAPE


func _add_selected_joker() -> void:
	_add_joker(Jokers.create(Jokers.ALL_IDS[joker_type.selected], joker_side.selected))


func _add_joker(j: Dictionary) -> void:
	jokers.append(j)
	_jokers_changed()


func _remove_joker(i: int) -> void:
	jokers.remove_at(i)
	_jokers_changed()


func _reroll_joker(i: int) -> void:
	jokers[i] = Jokers.reroll(jokers[i])
	_jokers_changed()


func _clear_jokers() -> void:
	jokers.clear()
	_jokers_changed()


## A fresh game shows the new setup straight away; a game in progress keeps going until New Game.
func _jokers_changed() -> void:
	_refresh_joker_list()
	if move_list.is_empty():
		new_game()
	else:
		jokers_dirty = true
		_update_joker_note()


func _update_joker_note() -> void:
	if joker_note != null:
		joker_note.visible = jokers_dirty


func _refresh_joker_list() -> void:
	jokers_button.text = "Jokers" if jokers.is_empty() else "Jokers (%d)" % jokers.size()
	for c in joker_list.get_children():
		joker_list.remove_child(c)
		c.queue_free()
	if jokers.is_empty():
		joker_list.add_child(_wrapped("No jokers: this is a normal game of chess.", 14, 300))
	for i in jokers.size():
		joker_list.add_child(_joker_entry(i))


func _joker_entry(i: int) -> Control:
	var j: Dictionary = jokers[i]
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", _panel_style(KIND_COL[j["kind"]]))
	var margin := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 8)
	panel.add_child(margin)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 3)
	margin.add_child(box)
	var name_label := Label.new()
	name_label.text = j["name"]
	name_label.add_theme_font_size_override("font_size", 17)
	name_label.add_theme_color_override("font_color", LIGHT_COL)
	box.add_child(name_label)
	var tag := Label.new()
	tag.text = ("LAYOUT - %s's half" % Jokers.side_name(j["color"])) if j["kind"] == Jokers.LAYOUT \
			else "SHAPE - whole board"
	tag.add_theme_font_size_override("font_size", 12)
	tag.add_theme_color_override("font_color", KIND_COL[j["kind"]])
	box.add_child(tag)
	box.add_child(_wrapped(j["desc"], 13, 290))
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	_add_button(row, "Re-roll", _reroll_joker.bind(i)).tooltip_text = "Same kind of joker with new random details."
	_add_button(row, "Remove", _remove_joker.bind(i))
	box.add_child(row)
	return panel


# ---------------------------------------------------------------- game setup

## Starts a game from the current jokers (none = standard chess).
func new_game() -> void:
	jokers_dirty = false
	_update_joker_note()
	_setup_game(Jokers.build(jokers))


func _setup_game(m) -> void:
	pos = m
	uses_stockfish = m.same_setup(standard)
	captured = [[], []]
	last_move = []
	move_list.clear()
	game_over = false
	_clear_selection()
	pos_version += 1
	_cancel_search()
	if engine != null:
		engine.new_game()
	eval_target = 0.5
	eval_display = 0.5
	eval_text = ""
	eval_white_ahead = true
	_recalc_shape()
	_layout()
	_update_status()
	queue_redraw()


## Swap Colors: flips the board, and against the computer also trades sides with it.
func _swap_colors() -> void:
	flipped = not flipped
	if engine_enabled:
		human_color = 1 - human_color
		_cancel_search()
		_clear_selection()
		_update_status()
	_update_eval_label()
	_update_captured_ui()
	queue_redraw()


func _set_engine_enabled(on: bool) -> void:
	engine_enabled = on
	if on:
		human_color = BoardModel.BLACK if flipped else BoardModel.WHITE  # you play the side facing you
	else:
		_cancel_search()
	_clear_selection()
	_update_status()
	queue_redraw()


func _human_turn() -> bool:
	return not engine_enabled or pos.turn == human_color


func _update_status() -> void:
	var check: bool = pos.in_check()
	if not pos.has_legal_move():
		game_over = true
		if check:
			var loser: int = pos.turn
			status_label.text = "Checkmate! %s wins" % ("Black" if loser == BoardModel.WHITE else "White")
			_show_eval(1.0 if loser == BoardModel.BLACK else 0.0,
					"1-0" if loser == BoardModel.BLACK else "0-1", loser == BoardModel.BLACK)
		else:
			status_label.text = "Stalemate - draw"
			_show_eval(0.5, "1/2", true)
		return
	var text := ("White" if pos.turn == BoardModel.WHITE else "Black") + " to move"
	if check:
		text += "  (check!)"
	if engine_enabled and pos.turn != human_color:
		text += "  -  %s thinking (depth %d)..." % [_opponent_name(), _opponent_depth()]
	if sf_failed and uses_stockfish:
		text += "  [Stockfish unavailable - using the built-in AI]"
	status_label.text = text


## Stockfish plays a standard game unless it couldn't be started (or died); the AI plays the rest.
func _stockfish_planned() -> bool:
	return uses_stockfish and not sf_failed


func _opponent_name() -> String:
	return "Stockfish" if _stockfish_planned() else "AI"


func _opponent_depth() -> int:
	return engine_depth if _stockfish_planned() else mini(engine_depth, AI_MAX_DEPTH)


# ---------------------------------------------------------------- geometry and layout

## Works out the box around the squares that exist and how big the board image must be.
func _recalc_shape() -> void:
	bx0 = BoardModel.GW
	bx1 = -1
	by0 = BoardModel.GH
	by1 = -1
	for s in pos.valid:
		var x: int = s % BoardModel.GW
		var y: int = s / BoardModel.GW
		bx0 = mini(bx0, x)
		bx1 = maxi(bx1, x)
		by0 = mini(by0, y)
		by1 = maxi(by1, y)
	cols = bx1 - bx0 + 1
	rows = by1 - by0 + 1
	board_w = cols * SQ + 2 * OFF
	board_h = rows * SQ + 2 * OFF


func _layout() -> void:
	if pos == null:
		return
	var vs := get_viewport_rect().size
	var top := 56.0
	# The Jokers panel takes room on the right while it is open; the board centres in what is left.
	var avail_w := vs.x - (PANEL_W if joker_panel != null and joker_panel.visible else 0.0)
	var width_px := board_w - 2 * BAR_X   # room for the eval bar on both sides keeps the board centred
	var extra := CAP_H + CAP_GAP          # captured rows above and below
	var height_px := board_h + 2 * extra
	var fit := minf(avail_w / width_px, (vs.y - top - 8.0) / height_px)
	var s := maxf(2.0, floorf(fit / 2.0) * 2.0)
	scale = Vector2(s, s)
	position = Vector2(floorf((avail_w - board_w * s) / 2.0),
			top + floorf((vs.y - top - height_px * s) / 2.0) + extra * s)
	_update_eval_label()
	_update_captured_ui()
	queue_redraw()


func _sq_to_disp(s: int) -> Vector2i:
	var x: int = s % BoardModel.GW
	var y: int = s / BoardModel.GW
	return Vector2i(bx1 - x, y - by0) if flipped else Vector2i(x - bx0, by1 - y)


## The square under display cell `d`, or -1 if there is none (off the board, or a pit).
func _disp_to_sq(d: Vector2i) -> int:
	if d.x < 0 or d.x >= cols or d.y < 0 or d.y >= rows:
		return -1
	var x: int = (bx1 - d.x) if flipped else (bx0 + d.x)
	var y: int = (by0 + d.y) if flipped else (by1 - d.y)
	var s: int = y * BoardModel.GW + x
	return s if pos.cell[s] != 0 else -1


func _disp_rect(d: Vector2i) -> Rect2:
	return Rect2(OFF + d.x * SQ, OFF + d.y * SQ, SQ, SQ)


func _mouse_disp() -> Vector2i:
	var m := get_local_mouse_position() - Vector2(OFF, OFF)
	var d := Vector2i(floori(m.x / SQ), floori(m.y / SQ))
	if d.x < 0 or d.x >= cols or d.y < 0 or d.y >= rows:
		return Vector2i(-1, -1)
	return d


# ---------------------------------------------------------------- cursor

func _load_cursors() -> void:
	var tex: Texture2D = load(ASSET + "cursor.png")
	var img := tex.get_image()
	if img == null:
		return
	if img.is_compressed():
		img.decompress()
	for i in 3:
		var c := img.get_region(Rect2i(i * 16, 0, 16, 16))
		c.resize(48, 48, Image.INTERPOLE_NEAREST if false else Image.INTERPOLATE_NEAREST)
		cursor_imgs.append(c)


func _update_cursor() -> void:
	if cursor_imgs.size() < 3:
		return
	var state := 0
	if dragging:
		state = 2
	elif promo_pending.is_empty() and not game_over and _human_turn():
		var s := _disp_to_sq(_mouse_disp())
		if s >= 0:
			var p: int = pos.sq[s]
			if p != 0 and (p >> 3) == pos.turn:
				state = 1
	if state == cursor_state:
		return
	cursor_state = state
	var hotspot := Vector2(18, 6) if state == 0 else Vector2(24, 24)
	Input.set_custom_mouse_cursor(cursor_imgs[state], Input.CURSOR_ARROW, hotspot)


# ---------------------------------------------------------------- moves

func _legal_from(s: int) -> Array:
	var res := []
	for m in pos.legal_moves():
		if BoardModel.mfrom(m) == s:
			res.append(m)
	return res


func _clear_selection() -> void:
	selected = -1
	selected_moves = []
	dragging = false
	promo_pending = {}


func _do_move(m: int) -> void:
	var fr := BoardModel.mfrom(m)
	var to := BoardModel.mto(m)
	var mover: int = pos.turn
	# En passant takes the pawn beside the mover, not the one on the destination square.
	var victim: int = pos.sq[to]
	if (BoardModel.mflags(m) & BoardModel.F_EP) != 0:
		victim = pos.sq[to - BoardModel.GW if mover == BoardModel.WHITE else to + BoardModel.GW]
	if victim != 0:
		captured[mover].append(victim)
		captured[mover].sort_custom(func(a: int, b: int): return (a & 7) < (b & 7))
	move_list.append(BoardModel.uci(m))
	pos_version += 1
	_cancel_engines()  # drop a search of the position we just left
	pos.commit(m)
	last_move = [fr, to]
	_clear_selection()
	_update_captured_ui()
	_update_status()
	queue_redraw()


func _try_move(to: int) -> bool:
	var matches := []
	for m in selected_moves:
		if BoardModel.mto(m) == to:
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
	var step := 1 if d.y < rows / 2 else -1
	var cells := []
	for i in 4:
		cells.append(Vector2i(d.x, d.y + i * step))
	return cells


# ---------------------------------------------------------------- input

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			_on_press(_mouse_disp())
		else:
			_on_release(_mouse_disp())
		_update_cursor()
	elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
		_clear_selection()
		queue_redraw()
	elif event is InputEventMouseMotion:
		drag_pos = get_local_mouse_position()
		_update_cursor()
		if dragging:
			queue_redraw()


func _on_press(d: Vector2i) -> void:
	if not promo_pending.is_empty():
		var i := _promo_cells().find(d)
		if i != -1:
			for m in promo_pending["moves"]:
				if BoardModel.mpromo(m) == BoardModel.PROMO_ORDER[i]:
					_do_move(m)
					break
		promo_pending = {}
		queue_redraw()
		return
	if game_over or not _human_turn():
		return
	var s := _disp_to_sq(d)
	if s < 0:
		selected = -1
		selected_moves = []
		queue_redraw()
		return
	if selected != -1 and _try_move(s):
		queue_redraw()
		return
	var p: int = pos.sq[s]
	if p != 0 and (p >> 3) == pos.turn:
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
	var s := _disp_to_sq(d)
	if s >= 0 and s != selected:
		_try_move(s)
	queue_redraw()


# ---------------------------------------------------------------- engines

func _use_stockfish() -> bool:
	return uses_stockfish and engine != null and engine.running


## Starts Stockfish the first time it is needed. Returns "" on success.
func _ensure_stockfish() -> String:
	if engine == null:
		engine = UciEngine.new()
		engine.bestmove.connect(_on_stockfish_bestmove)
		engine.evaluation.connect(_on_engine_eval)
		engine.failed.connect(_on_stockfish_failed)
		add_child(engine)
	return engine.start()


func _on_stockfish_failed(reason: String) -> void:
	sf_failed = true
	_cancel_search()
	status_label.text = reason + " - switching to the built-in AI"


func _ensure_ai() -> void:
	if ai == null:
		ai = AiEngine.new()
		ai.bestmove.connect(_on_ai_bestmove)
		ai.evaluation.connect(_on_engine_eval)
		add_child(ai)


func _busy() -> bool:
	return (engine != null and engine.thinking) or (ai != null and ai.thinking)


## Abandons the running search without changing the position, so it will be searched again.
func _cancel_search() -> void:
	_cancel_engines()
	analyzed_version = -1


func _cancel_engines() -> void:
	if engine != null:
		engine.cancel()
	if ai != null:
		ai.cancel()


func _set_eval_enabled(on: bool) -> void:
	eval_enabled = on
	if on:
		analyzed_version = -1
	elif not search_for_move:
		_cancel_search()  # only stop an evaluation, never the computer's move
	_update_eval_label()
	queue_redraw()


func _process(delta: float) -> void:
	_animate_eval(delta)
	if pos == null or game_over or _busy():
		return
	if engine_enabled and pos.turn != human_color:
		_start_search(true)
	elif eval_enabled and analyzed_version != pos_version:
		_start_search(false)


func _start_search(for_move: bool) -> void:
	if uses_stockfish and engine == null and not sf_failed:
		if _ensure_stockfish() != "":
			sf_failed = true
	search_for_move = for_move
	search_turn = pos.turn
	analyzed_version = pos_version
	search_stockfish = _use_stockfish()
	if search_stockfish:
		# Only the computer's own moves are weakened; the eval bar always sees full-strength Stockfish.
		engine.think(move_list, engine_depth if for_move else SF_EVAL_DEPTH, skill_level if for_move else 20)
	else:
		_ensure_ai()
		if for_move:
			ai.think(pos, mini(engine_depth, AI_MAX_DEPTH), AI_MOVE_MS)
		else:
			ai.think(pos, AI_EVAL_DEPTH, AI_EVAL_MS)


## Picks a preset from the Level dropdown (see Strength): sets depth, skill and mistake rate.
func _apply_level(i: int) -> void:
	level_option.select(i)
	if i < Strength.CUSTOM:
		var lv: Dictionary = Strength.LEVELS[i]
		engine_depth = lv["depth"]
		skill_level = lv["skill"]
		mistake_rate = lv["mistakes"]
		depth_box.set_value_no_signal(engine_depth)
	else:
		skill_level = 20
		mistake_rate = 0.0


## Editing the Depth box by hand means "Custom": that depth at full strength, no mistakes.
func _on_depth_changed(v: float) -> void:
	engine_depth = int(v)
	if level_option.selected != Strength.CUSTOM:
		_apply_level(Strength.CUSTOM)


## A beginner-style blunder: any legal move for the side to move.
func _random_legal_move() -> int:
	var legal: PackedInt32Array = pos.legal_moves()
	return legal[randi() % legal.size()]


func _computer_to_move() -> bool:
	return search_for_move and engine_enabled and not game_over and pos.turn != human_color


func _on_stockfish_bestmove(uci: String) -> void:
	if not _computer_to_move():
		return
	if randf() < mistake_rate:
		_do_move(_random_legal_move())
		_update_cursor()
		return
	var fr := BoardModel.name_to_sq(uci.substr(0, 2))
	var to := BoardModel.name_to_sq(uci.substr(2, 2))
	var promo: int = PROMO_FROM_LETTER.get(uci.substr(4, 1), 0)
	for m in pos.legal_moves():
		if BoardModel.mfrom(m) == fr and BoardModel.mto(m) == to and BoardModel.mpromo(m) == promo:
			_do_move(m)
			_update_cursor()
			return
	push_warning("Stockfish suggested a move the game considers illegal: " + uci)
	status_label.text = "Stockfish returned an unplayable move (%s)" % uci


func _on_ai_bestmove(m: int) -> void:
	if not _computer_to_move():
		return
	_do_move(_random_legal_move() if randf() < mistake_rate else m)
	_update_cursor()


# ---------------------------------------------------------------- evaluation bar

## Engine scores are from the side to move's point of view; the bar wants White's.
func _on_engine_eval(depth: int, cp: int, mate: int) -> void:
	var min_depth := SF_EVAL_MIN_DEPTH if search_stockfish else AI_EVAL_MIN_DEPTH
	if not eval_enabled or game_over or depth < min_depth:
		return
	var pov := 1 if search_turn == BoardModel.WHITE else -1
	if mate != 0:
		_show_eval(1.0 if mate * pov > 0 else 0.0, "M%d" % absi(mate), mate * pov > 0)
	else:
		# The curve Lichess uses to turn centipawns into a win chance.
		var win := 0.5 + 0.5 * (2.0 / (1.0 + exp(-0.00368208 * cp * pov)) - 1.0)
		_show_eval(win, "%.1f" % (absf(cp) / 100.0), cp * pov >= 0)


## target: White's share of the bar (0..1); text: readout at the leading side's end.
func _show_eval(target: float, text: String, white_ahead: bool) -> void:
	eval_target = target
	eval_text = text
	eval_white_ahead = white_ahead
	_update_eval_label()


func _animate_eval(delta: float) -> void:
	if eval_display == eval_target:
		return
	var h := rows * SQ
	var before := roundi(eval_display * h)
	eval_display = lerpf(eval_display, eval_target, 1.0 - exp(-delta * 10.0))
	if absf(eval_display - eval_target) < 0.0005:
		eval_display = eval_target
	if roundi(eval_display * h) != before:
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
	var y := (OFF + rows * SQ) * s - eval_label.size.y - 4.0 if at_bottom else OFF * s + 4.0
	eval_label.position = Vector2(position.x + (BAR_X + 1) * s, position.y + y)


# ---------------------------------------------------------------- captured pieces

func _material(c: int) -> int:
	var total := 0
	for s in pos.valid:
		var p: int = pos.sq[s]
		if p != 0 and (p >> 3) == c:
			total += PIECE_VALUE[p & 7]
	return total


## x of each piece in colour c's captured row. Same kinds overlap, kinds are spaced apart.
func _captured_xs(c: int) -> Array:
	var xs := []
	var x := float(OFF)
	var prev := 0
	for p in captured[c]:
		if prev != 0:
			x += 4.0 if p == prev else CAP_H + 1.0
		xs.append(x)
		prev = p
	return xs


## The player at the bottom has their captures under the board, the other player's are above it.
func _captured_row_y(c: int) -> float:
	var bottom := BoardModel.BLACK if flipped else BoardModel.WHITE
	return board_h + CAP_GAP if c == bottom else -(CAP_H + CAP_GAP)


func _update_captured_ui() -> void:
	if cap_labels.is_empty() or pos == null:
		return
	var s := scale.x
	for c in 2:
		var lead := _material(c) - _material(1 - c)
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


# ---------------------------------------------------------------- drawing

func _draw_piece(p: int, rect: Rect2) -> void:
	var tex := tex_white if (p >> 3) == 0 else tex_black
	draw_texture_rect_region(tex, rect, Rect2(SHEET_IDX[p & 7] * 16, 0, 16, 16))


func _draw_captured() -> void:
	for c in 2:
		var y := _captured_row_y(c)
		var xs := _captured_xs(c)
		for i in xs.size():
			_draw_piece(captured[c][i], Rect2(xs[i], y, CAP_H, CAP_H))


func _draw_eval_bar() -> void:
	var h := rows * SQ
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


## The frame, tiles, pits, labels and walls. Light and dark squares are cut from the board art.
func _draw_board() -> void:
	for s in pos.valid:
		draw_rect(_disp_rect(_sq_to_disp(s)).grow(OFF), BORDER_COL)
	# Core squares that have collapsed into pits.
	for r in 8:
		for f in 8:
			var s: int = (BoardModel.CY + r) * BoardModel.GW + BoardModel.CX + f
			if pos.cell[s] == 0:
				draw_rect(_disp_rect(_sq_to_disp(s)), PIT_COL)
	for s in pos.valid:
		var x: int = s % BoardModel.GW
		var y: int = s / BoardModel.GW
		var light := ((x + y) & 1) == 1   # a1 is dark, as on the board art
		var src := Rect2(OFF + (0 if light else SQ), OFF, SQ, SQ)
		draw_texture_rect_region(tex_board, _disp_rect(_sq_to_disp(s)), src)
	# Rank and file labels, copied from the board art and placed on the frame edge.
	for r in 8:
		var row := _sq_to_disp((BoardModel.CY + r) * BoardModel.GW + bx0).y
		var dst := Rect2(0, OFF + row * SQ, 6, SQ)
		draw_rect(dst, BORDER_COL)
		draw_texture_rect_region(tex_board, dst, Rect2(0, OFF + (7 - r) * SQ, 6, SQ))
	for f in 8:
		var col := _sq_to_disp(by0 * BoardModel.GW + BoardModel.CX + f).x
		var dst := Rect2(OFF + col * SQ, OFF + rows * SQ + 1, SQ, 6)
		draw_rect(dst, BORDER_COL)
		draw_texture_rect_region(tex_board, dst, Rect2(OFF + f * SQ, OFF + 8 * SQ + 1, SQ, 6))
	# Walls sit on the edge between two squares.
	for s in pos.valid:
		if pos.wall_e[s] != 0 and pos.cell[s + 1] != 0:
			_draw_wall(s, s + 1)
		if pos.wall_n[s] != 0 and pos.cell[s + BoardModel.GW] != 0:
			_draw_wall(s, s + BoardModel.GW)


func _draw_wall(a: int, b: int) -> void:
	var ra := _disp_rect(_sq_to_disp(a))
	var rb := _disp_rect(_sq_to_disp(b))
	if a / BoardModel.GW == b / BoardModel.GW:
		var x := maxf(ra.position.x, rb.position.x)
		draw_rect(Rect2(x - 2, ra.position.y, 4, SQ), BAR_BLACK)
		draw_rect(Rect2(x - 1, ra.position.y, 2, SQ), WALL_LIGHT)
	else:
		var y := maxf(ra.position.y, rb.position.y)
		draw_rect(Rect2(ra.position.x, y - 2, SQ, 4), BAR_BLACK)
		draw_rect(Rect2(ra.position.x, y - 1, SQ, 2), WALL_LIGHT)


func _draw() -> void:
	if pos == null:
		return
	_draw_board()
	if eval_enabled:
		_draw_eval_bar()
	_draw_captured()

	for s in last_move:
		draw_rect(_disp_rect(_sq_to_disp(s)), Color(1.0, 0.85, 0.2, 0.4))
	if pos.in_check():
		draw_rect(_disp_rect(_sq_to_disp(pos.ksq[pos.turn])), Color(0.9, 0.15, 0.15, 0.55))
	if selected != -1:
		draw_rect(_disp_rect(_sq_to_disp(selected)), Color(0.35, 0.8, 0.45, 0.5))

	for s in pos.valid:
		var p: int = pos.sq[s]
		if p == 0 or (dragging and s == selected):
			continue
		_draw_piece(p, _disp_rect(_sq_to_disp(s)))

	# Move hints: a dot for a quiet move, an outline for a capture.
	var hint := Color(0.1, 0.12, 0.18, 0.45)
	for m in selected_moves:
		var to := BoardModel.mto(m)
		var r := _disp_rect(_sq_to_disp(to))
		if pos.sq[to] != 0 or (BoardModel.mflags(m) & BoardModel.F_EP) != 0:
			draw_rect(r.grow(-0.5), hint, false, 1.0)
		else:
			draw_rect(Rect2(r.position + Vector2(6, 6), Vector2(4, 4)), hint)

	if dragging and selected != -1:
		_draw_piece(pos.sq[selected], Rect2(drag_pos - Vector2(8, 8), Vector2(16, 16)))

	if not promo_pending.is_empty():
		draw_rect(Rect2(OFF, OFF, cols * SQ, rows * SQ), Color(0, 0, 0, 0.55))
		var cells := _promo_cells()
		for i in 4:
			var r := _disp_rect(cells[i])
			draw_rect(r, LIGHT_COL)
			draw_rect(r.grow(-0.5), BORDER_COL, false, 1.0)
			_draw_piece(BoardModel.piece(BoardModel.PROMO_ORDER[i], pos.turn), r)
