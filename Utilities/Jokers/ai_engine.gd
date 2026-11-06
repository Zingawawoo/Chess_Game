extends Node
## Built-in chess AI for boards Stockfish can't play (holes, walls, bumps, rearranged armies).
##
## Iterative-deepening alpha-beta with a capture-only quiescence search, run on a worker thread
## so the game never stalls. It offers the same surface as UciEngine (think / cancel / signals),
## but works on a BoardModel instead of a UCI move list.

## Emitted when the search is done. `move` is a BoardModel move int.
signal bestmove(move: int)
## Emitted after each finished depth. Score is for the side to move; `mate` is moves to mate
## (negative = being mated), 0 if unused.
signal evaluation(depth: int, cp: int, mate: int)

const BoardModel := preload("res://Utilities/Jokers/board_model.gd")

const MATE := 100000
const INF_SCORE := 1000000
const QS_MAX := 4
const VALUE := [0, 100, 320, 330, 500, 900, 0]  # indexed by piece type

var running := true    ## always true: there is no process to lose
var thinking := false  ## a search is in flight (even one whose result will be discarded)

var _thread: Thread
var _mutex := Mutex.new()
var _out: Array = []
var _discard := false
var _cancel := false   # read by the worker thread
var _aborted := false
var _deadline := 0
var _nodes := 0
var _rng := RandomNumberGenerator.new()
var _cen := PackedInt32Array()


func _init() -> void:
	_rng.randomize()
	# How central each square is, for placing knights and bishops (core centre is (5.5, 5.5)).
	_cen.resize(BoardModel.CELLS)
	for s in BoardModel.CELLS:
		var d := maxf(absf(s % BoardModel.GW - 5.5), absf(s / BoardModel.GW - 5.5))
		_cen[s] = clampi(int(8.0 - 2.0 * d), 0, 7)


## Starts a search of `model` (copied, so the caller keeps using theirs).
func think(model, depth: int, ms: int) -> void:
	if thinking:
		return
	thinking = true
	_discard = false
	_cancel = false
	if _thread != null:
		_thread.wait_to_finish()
	_thread = Thread.new()
	_thread.start(_run.bind(model.dup(), depth, ms))


## Abandons the current search; its result will not be emitted.
func cancel() -> void:
	if thinking and not _discard:
		_discard = true
		_cancel = true


func new_game() -> void:
	pass


func shutdown() -> void:
	_cancel = true
	if _thread != null:
		_thread.wait_to_finish()
		_thread = null
	thinking = false


func _exit_tree() -> void:
	shutdown()


func _process(_delta: float) -> void:
	_mutex.lock()
	var batch := _out.duplicate()
	_out.clear()
	_mutex.unlock()
	for item in batch:
		if item[0] == "eval":
			if not _discard:
				evaluation.emit(item[1], item[2], item[3])
		else:
			thinking = false
			if _thread != null:
				_thread.wait_to_finish()
				_thread = null
			if _discard:
				_discard = false
			elif item[1] != 0:
				bestmove.emit(item[1])


func _push(item: Array) -> void:
	_mutex.lock()
	_out.append(item)
	_mutex.unlock()


# ---------------------------------------------------------------- search (worker thread)

func _run(root, max_depth: int, ms: int) -> void:
	_aborted = false
	_nodes = 0
	_deadline = Time.get_ticks_msec() + ms
	var moves: PackedInt32Array = root.legal_moves()
	if moves.is_empty():
		_push(["best", 0])
		return
	var ordered := _order(root, moves, 0, true)
	var best := ordered[0]
	for depth in range(1, max_depth + 1):
		var alpha := -INF_SCORE
		var iter_best := 0
		var iter_score := -INF_SCORE
		for m in ordered:
			root.make(m)
			var sc := -_negamax(root, depth - 1, -INF_SCORE, -alpha, 1)
			root.unmake()
			if _aborted:
				break
			if sc > iter_score:
				iter_score = sc
				iter_best = m
			if sc > alpha:
				alpha = sc
		if _aborted:
			break
		best = iter_best
		ordered = _order(root, moves, best, false)
		var mate := 0
		var cp := iter_score
		if absi(iter_score) > MATE - 500:
			mate = (MATE - absi(iter_score) + 1) / 2 * (1 if iter_score > 0 else -1)
			cp = 0
		_push(["eval", depth, cp, mate])
		if mate != 0 and mate > 0:
			break  # found a forced mate; deeper search can't improve on it
	_push(["best", best])


func _negamax(pos, depth: int, alpha: int, beta: int, ply: int) -> int:
	_nodes += 1
	if (_nodes & 255) == 0 and (_cancel or Time.get_ticks_msec() > _deadline):
		_aborted = true
	if _aborted:
		return 0
	if depth <= 0:
		if ply < 14 and pos.in_check():
			depth = 1  # don't stop the search in the middle of a check
		else:
			return _qsearch(pos, alpha, beta, 0)
	var moves := _order(pos, pos.gen_pseudo(), 0, false)
	var legal := 0
	var best := -INF_SCORE
	for m in moves:
		pos.make(m)
		if is_attacked_king(pos):
			pos.unmake()
			continue
		legal += 1
		var sc := -_negamax(pos, depth - 1, -beta, -alpha, ply + 1)
		pos.unmake()
		if _aborted:
			return 0
		if sc > best:
			best = sc
			if sc > alpha:
				alpha = sc
				if alpha >= beta:
					break
	if legal == 0:
		return -(MATE - ply) if pos.in_check() else 0
	return best


func _qsearch(pos, alpha: int, beta: int, qd: int) -> int:
	_nodes += 1
	if (_nodes & 255) == 0 and (_cancel or Time.get_ticks_msec() > _deadline):
		_aborted = true
	if _aborted:
		return 0
	var stand := _eval(pos)
	if stand >= beta or qd >= QS_MAX:
		return stand
	if stand > alpha:
		alpha = stand
	for m in _order(pos, pos.gen_pseudo(true), 0, false):
		pos.make(m)
		if is_attacked_king(pos):
			pos.unmake()
			continue
		var sc := -_qsearch(pos, -beta, -alpha, qd + 1)
		pos.unmake()
		if _aborted:
			return 0
		if sc >= beta:
			return sc
		if sc > alpha:
			alpha = sc
	return alpha


## After make(): is the king of the side that just moved attacked?
func is_attacked_king(pos) -> bool:
	return pos.is_attacked(pos.ksq[pos.turn ^ 1], pos.turn)


## Best-first move order: previous best, then captures by value, then promotions.
func _order(pos, moves: PackedInt32Array, first: int, noise: bool) -> PackedInt32Array:
	var keys := PackedInt64Array()
	keys.resize(moves.size())
	for i in moves.size():
		var m := moves[i]
		var score := 0
		var cap: int = pos.sq[(m >> 8) & 255]
		if cap != 0:
			var mover: int = pos.sq[m & 255]
			score = int(VALUE[cap & 7]) * 10 - int(VALUE[mover & 7]) / 10
		elif ((m >> 20) & 1) != 0:
			score = 1000
		var promo := (m >> 16) & 7
		if promo != 0:
			score += int(VALUE[promo]) * 8
		if m == first:
			score = 1000000
		var jitter := (_rng.randi() & 7) if noise else 0
		keys[i] = ((2000000 - score) << 36) | (jitter << 32) | m
	keys.sort()
	var out := PackedInt32Array()
	out.resize(moves.size())
	for i in moves.size():
		out[i] = keys[i] & 0xFFFFFFFF
	return out


## Static evaluation from the side to move's point of view, in centipawns.
func _eval(pos) -> int:
	var score := 0
	var npm := 0
	for s in pos.valid:
		var p: int = pos.sq[s]
		if p == 0:
			continue
		var t := p & 7
		var c := p >> 3
		var v: int = VALUE[t]
		var cen := _cen[s]
		if t == BoardModel.PAWN:
			var adv: int = s / BoardModel.GW - (BoardModel.CY + 1) if c == 0 else (BoardModel.CY + 6) - s / BoardModel.GW
			v += mini(maxi(adv, 0), 6) * 7 + cen
		elif t == BoardModel.KNIGHT:
			v += cen * 4
			npm += 320
		elif t == BoardModel.BISHOP:
			v += cen * 2
			npm += 330
		elif t == BoardModel.QUEEN:
			v += cen
			npm += 900
		elif t == BoardModel.ROOK:
			npm += 500
		score += v if c == 0 else -v
	# Kings hide in the middlegame and come out in the endgame.
	var endgame := npm < 2400
	for c in 2:
		var ks: int = pos.ksq[c]
		if ks == -1:
			continue
		var kb := _cen[ks] * (5 if endgame else -3)
		score += kb if c == 0 else -kb
	return score if pos.turn == 0 else -score
