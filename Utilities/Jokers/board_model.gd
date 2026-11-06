extends RefCounted
## A chess position on a 12x12 grid whose squares can be missing (holes), have walls between
## them, or stick out past the usual 8x8 "core". All of the rules live here, in a compact
## integer form shared by the game UI and the AI.
##
## Squares are indices y * GW + x. y grows from White's side toward Black's: rank 1 is y = CY.
## Pieces are ints: type | (colour << 3), 0 = empty.
## Moves are ints: from | to << 8 | promotion type << 16 | flags << 20.
##
## Rules for the odd geometry:
##  - A missing square can't be entered, and sliders can't cross it. Knights jump over it.
##  - A wall sits on the edge between two squares. Nothing steps or slides across it, and a
##    diagonal step can't cut a corner a wall touches. Knights jump over walls.
##  - A pawn promotes on the last square of its file (so on the tip of a bump, if there is one).
##  - A pawn double-steps from its home rank, wherever the board's shape leaves room.

const GW := 12
const GH := 12
const CELLS := GW * GH
const CX := 2   # the standard 8x8 board sits at (CX, CY)
const CY := 2

const WHITE := 0
const BLACK := 1

const PAWN := 1
const KNIGHT := 2
const BISHOP := 3
const ROOK := 4
const QUEEN := 5
const KING := 6

const F_EP := 1
const F_CASTLE_K := 2
const F_CASTLE_Q := 4
const F_DOUBLE := 8

## Step directions: E, W, N, S, NE, NW, SE, SW (north = toward Black).
const DX := [1, -1, 0, 0, 1, -1, 1, -1]
const DY := [0, 0, 1, -1, 1, 1, -1, -1]
const KNIGHT_JUMPS := [[1, 2], [2, 1], [-1, 2], [-2, 1], [1, -2], [2, -1], [-1, -2], [-2, -1]]
const PROMO_ORDER := [QUEEN, ROOK, BISHOP, KNIGHT]
const BACK_RANK := [ROOK, KNIGHT, BISHOP, QUEEN, KING, BISHOP, KNIGHT, ROOK]
const PROMO_LETTER := {KNIGHT: "n", BISHOP: "b", ROOK: "r", QUEEN: "q"}

var cell := PackedByteArray()     # 1 = square exists
var wall_e := PackedByteArray()   # 1 = wall between (x, y) and (x + 1, y)
var wall_n := PackedByteArray()   # 1 = wall between (x, y) and (x, y + 1)
var sq := PackedInt32Array()      # piece on each square
var turn := WHITE
var ep := -1                      # square a pawn just skipped over, else -1
var rights := 0                   # castling rights: bit 0 WK, 1 WQ, 2 BK, 3 BQ
var ksq := PackedInt32Array([-1, -1])

# Tables derived from cell / wall_*, rebuilt by build_tables().
var nbr := PackedInt32Array()     # nbr[s * 8 + dir] = square reached by one step, or -1
var knight_t: Array = []          # knight destinations per square
var valid := PackedInt32Array()   # every square that exists
var promo_y := PackedInt32Array() # promo_y[colour * GW + x] = row where a pawn on file x promotes
var rmask := PackedInt32Array()   # castling rights lost when this square is touched

var _undo := PackedInt32Array()


func _init() -> void:
	cell.resize(CELLS)
	wall_e.resize(CELLS)
	wall_n.resize(CELLS)
	sq.resize(CELLS)


# ---------------------------------------------------------------- helpers

static func piece(type: int, color: int) -> int:
	return type | (color << 3)


static func mfrom(m: int) -> int:
	return m & 255


static func mto(m: int) -> int:
	return (m >> 8) & 255


static func mpromo(m: int) -> int:
	return (m >> 16) & 7


static func mflags(m: int) -> int:
	return (m >> 20) & 15


static func mk(fr: int, to: int, promo := 0, flags := 0) -> int:
	return fr | (to << 8) | (promo << 16) | (flags << 20)


static func sq_name(s: int) -> String:
	return char(97 + s % GW - CX) + str(s / GW - CY + 1)


static func name_to_sq(n: String) -> int:
	return (n.unicode_at(1) - 49 + CY) * GW + (n.unicode_at(0) - 97 + CX)


## Long algebraic as Stockfish writes it: "e2e4", "e7e8q". Only meaningful on the standard board.
static func uci(m: int) -> String:
	return sq_name(mfrom(m)) + sq_name(mto(m)) + PROMO_LETTER.get(mpromo(m), "")


# ---------------------------------------------------------------- setup

func setup_standard() -> void:
	cell.fill(0)
	wall_e.fill(0)
	wall_n.fill(0)
	sq.fill(0)
	for r in 8:
		for f in 8:
			cell[(CY + r) * GW + CX + f] = 1
	for f in 8:
		sq[CY * GW + CX + f] = piece(BACK_RANK[f], WHITE)
		sq[(CY + 1) * GW + CX + f] = piece(PAWN, WHITE)
		sq[(CY + 6) * GW + CX + f] = piece(PAWN, BLACK)
		sq[(CY + 7) * GW + CX + f] = piece(BACK_RANK[f], BLACK)
	turn = WHITE
	ep = -1
	finish_setup()


## Call after editing cell / wall_* / sq directly.
func finish_setup() -> void:
	build_tables()
	refresh_kings()
	rights = compute_rights()
	_undo.clear()


func refresh_kings() -> void:
	ksq[0] = -1
	ksq[1] = -1
	for s in valid:
		var p := sq[s]
		if (p & 7) == KING:
			ksq[p >> 3] = s


## Castling needs the king and rook on their classic squares; shuffled layouts lose it.
func compute_rights() -> int:
	var r := 0
	for c in 2:
		var ks := (CY + 7 * c) * GW + CX + 4
		if sq[ks] != piece(KING, c):
			continue
		if sq[ks + 3] == piece(ROOK, c):
			r |= 1 << (2 * c)
		if sq[ks - 4] == piece(ROOK, c):
			r |= 2 << (2 * c)
	return r


func dup():
	var m = get_script().new()
	m.cell = cell
	m.wall_e = wall_e
	m.wall_n = wall_n
	m.sq = sq.duplicate()
	m.turn = turn
	m.ep = ep
	m.rights = rights
	m.ksq = ksq.duplicate()
	m.nbr = nbr
	m.knight_t = knight_t
	m.valid = valid
	m.promo_y = promo_y
	m.rmask = rmask
	return m


## True if the board shape and piece layout match `other` (used to spot the standard setup).
func same_setup(other) -> bool:
	return cell == other.cell and wall_e == other.wall_e and wall_n == other.wall_n \
			and sq == other.sq


func build_tables() -> void:
	valid = PackedInt32Array()
	for s in CELLS:
		if cell[s] != 0:
			valid.append(s)
	nbr.resize(CELLS * 8)
	knight_t = []
	knight_t.resize(CELLS)
	for s in CELLS:
		var x := s % GW
		var y := s / GW
		for d in 8:
			nbr[s * 8 + d] = _step(s, x, y, d)
		var t := PackedInt32Array()
		if cell[s] != 0:
			for j in KNIGHT_JUMPS:
				var nx: int = x + j[0]
				var ny: int = y + j[1]
				if nx >= 0 and nx < GW and ny >= 0 and ny < GH and cell[ny * GW + nx] != 0:
					t.append(ny * GW + nx)
		knight_t[s] = t
	promo_y.resize(2 * GW)
	for x in GW:
		var lo := -1
		var hi := -1
		for y in GH:
			if cell[y * GW + x] != 0:
				if lo == -1:
					lo = y
				hi = y
		promo_y[x] = hi            # White promotes on the highest square of the file
		promo_y[GW + x] = lo       # Black on the lowest
	rmask.resize(CELLS)
	rmask.fill(0)
	for c in 2:
		var ks := (CY + 7 * c) * GW + CX + 4
		rmask[ks] |= 3 << (2 * c)
		rmask[ks + 3] |= 1 << (2 * c)
		rmask[ks - 4] |= 2 << (2 * c)


func _wall_between(x1: int, y1: int, x2: int, y2: int) -> bool:
	if y1 == y2:
		return wall_e[y1 * GW + mini(x1, x2)] != 0
	return wall_n[mini(y1, y2) * GW + x1] != 0


func _step(s: int, x: int, y: int, d: int) -> int:
	if cell[s] == 0:
		return -1
	var nx: int = x + DX[d]
	var ny: int = y + DY[d]
	if nx < 0 or nx >= GW or ny < 0 or ny >= GH or cell[ny * GW + nx] == 0:
		return -1
	if d < 4:
		return -1 if _wall_between(x, y, nx, ny) else ny * GW + nx
	# Diagonal: no cutting a corner that a wall touches.
	if _wall_between(x, y, nx, y) or _wall_between(x, y, x, ny) \
			or _wall_between(nx, ny, x, ny) or _wall_between(nx, ny, nx, y):
		return -1
	return ny * GW + nx


# ---------------------------------------------------------------- attacks

func is_attacked(s: int, by: int) -> bool:
	var bp := by << 3
	for d in 4:
		var n := nbr[s * 8 + d]
		while n != -1:
			var p := sq[n]
			if p != 0:
				if p == (bp | ROOK) or p == (bp | QUEEN):
					return true
				break
			n = nbr[n * 8 + d]
	for d in range(4, 8):
		var n := nbr[s * 8 + d]
		while n != -1:
			var p := sq[n]
			if p != 0:
				if p == (bp | BISHOP) or p == (bp | QUEEN):
					return true
				break
			n = nbr[n * 8 + d]
	for t in knight_t[s]:
		if sq[t] == (bp | KNIGHT):
			return true
	for d in 8:
		var n := nbr[s * 8 + d]
		if n != -1 and sq[n] == (bp | KING):
			return true
	# A pawn attacks diagonally forward, so it sits diagonally behind the target.
	var back := 6 if by == WHITE else 4
	for k in 2:
		var n := nbr[s * 8 + back + k]
		if n != -1 and sq[n] == (bp | PAWN):
			return true
	return false


func in_check() -> bool:
	return ksq[turn] != -1 and is_attacked(ksq[turn], 1 - turn)


# ---------------------------------------------------------------- move generation

func gen_pseudo(captures_only := false) -> PackedInt32Array:
	var out := PackedInt32Array()
	var us := turn
	var up := 2 if us == WHITE else 3
	var cd := 4 if us == WHITE else 6   # first of the two forward-diagonal directions
	var home_y := CY + 1 + 5 * us
	for s in valid:
		var p := sq[s]
		if p == 0 or (p >> 3) != us:
			continue
		var t := p & 7
		if t == PAWN:
			var n1 := nbr[s * 8 + up]
			if n1 != -1 and sq[n1] == 0:
				if promo_y[us * GW + n1 % GW] == n1 / GW:
					for pt in PROMO_ORDER:
						out.append(s | (n1 << 8) | (pt << 16))
				elif not captures_only:
					out.append(s | (n1 << 8))
					if s / GW == home_y:
						var n2 := nbr[n1 * 8 + up]
						if n2 != -1 and sq[n2] == 0:
							out.append(s | (n2 << 8) | (F_DOUBLE << 20))
			for k in 2:
				var n := nbr[s * 8 + cd + k]
				if n == -1:
					continue
				var tp := sq[n]
				if tp != 0:
					if (tp >> 3) != us:
						if promo_y[us * GW + n % GW] == n / GW:
							for pt in PROMO_ORDER:
								out.append(s | (n << 8) | (pt << 16))
						else:
							out.append(s | (n << 8))
				elif n == ep:
					out.append(s | (n << 8) | (F_EP << 20))
		elif t == KNIGHT:
			for n in knight_t[s]:
				var tp := sq[n]
				if tp == 0:
					if not captures_only:
						out.append(s | (n << 8))
				elif (tp >> 3) != us:
					out.append(s | (n << 8))
		else:
			var d0 := 0
			var d1 := 8
			if t == BISHOP:
				d0 = 4
			elif t == ROOK:
				d1 = 4
			for d in range(d0, d1):
				var n := nbr[s * 8 + d]
				while n != -1:
					var tp := sq[n]
					if tp == 0:
						if not captures_only:
							out.append(s | (n << 8))
					else:
						if (tp >> 3) != us:
							out.append(s | (n << 8))
						break
					if t == KING:
						break
					n = nbr[n * 8 + d]
			if t == KING and not captures_only:
				_gen_castles(s, out)
	return out


func _gen_castles(ks: int, out: PackedInt32Array) -> void:
	var us := turn
	if ks != (CY + 7 * us) * GW + CX + 4 or ((rights >> (2 * us)) & 3) == 0:
		return
	var them := 1 - us
	if is_attacked(ks, them):
		return
	if (rights & (1 << (2 * us))) != 0:
		var f := ks + 1
		var g := ks + 2
		var r := ks + 3
		if sq[f] == 0 and sq[g] == 0 and sq[r] == piece(ROOK, us) \
				and nbr[ks * 8] == f and nbr[f * 8] == g and nbr[g * 8] == r \
				and not is_attacked(f, them) and not is_attacked(g, them):
			out.append(ks | (g << 8) | (F_CASTLE_K << 20))
	if (rights & (2 << (2 * us))) != 0:
		var d := ks - 1
		var c := ks - 2
		var b := ks - 3
		var r := ks - 4
		if sq[d] == 0 and sq[c] == 0 and sq[b] == 0 and sq[r] == piece(ROOK, us) \
				and nbr[ks * 8 + 1] == d and nbr[d * 8 + 1] == c and nbr[c * 8 + 1] == b \
				and nbr[b * 8 + 1] == r \
				and not is_attacked(d, them) and not is_attacked(c, them):
			out.append(ks | (c << 8) | (F_CASTLE_Q << 20))


func legal_moves() -> PackedInt32Array:
	var res := PackedInt32Array()
	for m in gen_pseudo():
		make(m)
		if not is_attacked(ksq[turn ^ 1], turn):
			res.append(m)
		unmake()
	return res


func has_legal_move() -> bool:
	for m in gen_pseudo():
		make(m)
		var ok := not is_attacked(ksq[turn ^ 1], turn)
		unmake()
		if ok:
			return true
	return false


# ---------------------------------------------------------------- make / unmake

func make(m: int) -> void:
	var fr := m & 255
	var to := (m >> 8) & 255
	var promo := (m >> 16) & 7
	var fl := (m >> 20) & 15
	var p := sq[fr]
	var cap := sq[to]
	if (fl & F_EP) != 0:
		var victim := to - GW if turn == WHITE else to + GW
		cap = sq[victim]
		sq[victim] = 0
	_undo.append(m)
	_undo.append(p)
	_undo.append(cap)
	_undo.append(rights)
	_undo.append(ep)
	sq[to] = p
	sq[fr] = 0
	if promo != 0:
		sq[to] = promo | (turn << 3)
	if (fl & F_CASTLE_K) != 0:
		sq[fr + 1] = sq[fr + 3]
		sq[fr + 3] = 0
	elif (fl & F_CASTLE_Q) != 0:
		sq[fr - 1] = sq[fr - 4]
		sq[fr - 4] = 0
	if (p & 7) == KING:
		ksq[turn] = to
	rights &= ~(rmask[fr] | rmask[to])
	ep = (fr + to) / 2 if (fl & F_DOUBLE) != 0 else -1
	turn ^= 1


func unmake() -> void:
	var n := _undo.size()
	var m := _undo[n - 5]
	var p := _undo[n - 4]
	var cap := _undo[n - 3]
	rights = _undo[n - 2]
	ep = _undo[n - 1]
	_undo.resize(n - 5)
	turn ^= 1
	var fr := m & 255
	var to := (m >> 8) & 255
	var fl := (m >> 20) & 15
	sq[fr] = p
	if (fl & F_EP) != 0:
		sq[to] = 0
		sq[to - GW if turn == WHITE else to + GW] = cap
	else:
		sq[to] = cap
	if (fl & F_CASTLE_K) != 0:
		sq[fr + 3] = sq[fr + 1]
		sq[fr + 1] = 0
	elif (fl & F_CASTLE_Q) != 0:
		sq[fr - 4] = sq[fr - 1]
		sq[fr - 1] = 0
	if (p & 7) == KING:
		ksq[turn] = fr


## Makes a move for good: forgets the undo history so a long game doesn't pile it up.
func commit(m: int) -> void:
	make(m)
	_undo.clear()


## Number of leaf positions `depth` plies ahead (for testing the rules).
func perft(depth: int) -> int:
	if depth == 0:
		return 1
	var total := 0
	for m in gen_pseudo():
		make(m)
		if not is_attacked(ksq[turn ^ 1], turn):
			total += 1 if depth == 1 else perft(depth - 1)
		unmake()
	return total
