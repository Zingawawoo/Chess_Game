extends Node2D
## Top-down 2D chess using the "Pixel Chess" asset pack by Dani Maccari.
## Two players on one machine. Click or drag to move.

const ASSET := "res://Assets/pixel chess_v1.2/"
const SQ := 16          # square size in board pixels
const OFF := 7          # where the squares start inside the board image
const BOARD_PX := 142   # board image size
const BORDER_COL := Color8(89, 96, 112)
const LIGHT_COL := Color8(234, 240, 216)
const SHEET_ORDER := ["P", "N", "R", "B", "Q", "K"]  # order in the sprite sheets
const PROMO_CHOICES := ["Q", "R", "B", "N"]

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

var status_label: Label


func _ready() -> void:
	tex_board = load(ASSET + "boards/board_plain_01.png")
	tex_white = load(ASSET + "16x16 pieces/WhitePieces.png")
	tex_black = load(ASSET + "16x16 pieces/BlackPieces.png")
	_load_cursors()
	_build_ui()
	get_viewport().size_changed.connect(_layout)
	_layout()
	new_game()


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
	swap.pressed.connect(func():
		flipped = not flipped
		queue_redraw())
	bar.add_child(swap)

	var reset := Button.new()
	reset.text = "New Game"
	reset.focus_mode = Control.FOCUS_NONE
	reset.pressed.connect(new_game)
	bar.add_child(reset)

	status_label = Label.new()
	status_label.add_theme_font_size_override("font_size", 20)
	bar.add_child(status_label)


func _layout() -> void:
	var vs := get_viewport_rect().size
	var top := 56.0
	var s := maxf(1.0, floorf(minf(vs.x, vs.y - top - 8.0) / BOARD_PX))
	scale = Vector2(s, s)
	position = Vector2(floorf((vs.x - BOARD_PX * s) / 2.0), top + floorf((vs.y - top - BOARD_PX * s) / 2.0))


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
	elif promo_pending.is_empty() and not game_over:
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
	game_over = false
	selected = -1
	selected_moves = []
	dragging = false
	promo_pending = {}
	_update_status()
	queue_redraw()


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
	_update_status()


func _update_status() -> void:
	var side := "White" if turn == "w" else "Black"
	var check := _in_check(board, turn)
	if not _has_any_legal(turn):
		game_over = true
		if check:
			status_label.text = "Checkmate! %s wins" % ("Black" if turn == "w" else "White")
		else:
			status_label.text = "Stalemate - draw"
	else:
		status_label.text = side + " to move" + ("  (check!)" if check else "")


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
	if game_over:
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


func _draw() -> void:
	draw_texture(tex_board, Vector2.ZERO)

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
