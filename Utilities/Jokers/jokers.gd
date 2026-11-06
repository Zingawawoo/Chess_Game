extends RefCounted
## Jokers: Balatro-style modifiers that change how a game of chess starts.
##
## Two kinds:
##  - LAYOUT jokers rearrange the starting pieces of one colour's half of the board.
##  - SHAPE jokers change the board itself (pits, walls, bastions), always symmetrically so
##    neither side gets an unfair geometry.
##
## Everything is deterministic: a joker rolls its parameters once from a seed when it is created
## and every later use re-derives the same effect from that seed, so a joker "always does the
## same thing" however many times a game is started with it.
##
## A joker is a Dictionary: {id, kind, name, seed, p (parameters), desc}, and layout jokers also
## carry "color" (BoardModel.WHITE or BLACK): the half they rearrange.

const BoardModel := preload("res://Utilities/Jokers/board_model.gd")

const GW := BoardModel.GW
const GH := BoardModel.GH
const CX := BoardModel.CX
const CY := BoardModel.CY

const LAYOUT := "layout"
const SHAPE := "shape"

const INFO := {
	"carousel": {"name": "Carousel", "kind": LAYOUT},
	"mirror": {"name": "Mirror Image", "kind": LAYOUT},
	"shuffle": {"name": "Shuffle", "kind": LAYOUT},
	"vanguard": {"name": "Vanguard", "kind": LAYOUT},
	"cavalry": {"name": "Cavalry", "kind": LAYOUT},
	"lift": {"name": "Rook Lift", "kind": LAYOUT},
	"sinkholes": {"name": "Sinkholes", "kind": SHAPE},
	"walls": {"name": "Great Walls", "kind": SHAPE},
	"bastions": {"name": "Bastions", "kind": SHAPE},
}
const LAYOUT_IDS := ["carousel", "mirror", "shuffle", "vanguard", "cavalry", "lift"]
const ALL_IDS := ["carousel", "mirror", "shuffle", "vanguard", "cavalry", "lift",
		"sinkholes", "walls", "bastions"]

## Pawn files advanced by Vanguard, and how the card describes them.
const VANGUARD_FILES := [[0, 7], [3, 4], [1, 2, 5, 6], [0, 2, 4, 6], [1, 3, 5, 7]]
const VANGUARD_NAMES := ["edge pawns", "centre pawns", "flank pawns", "even-file pawns", "odd-file pawns"]


# ---------------------------------------------------------------- creating jokers

static func _rng(sd: int) -> RandomNumberGenerator:
	var r := RandomNumberGenerator.new()
	r.seed = sd
	return r


## Rolls joker `id`'s parameters from seed `sd`. The same arguments always give the same joker.
static func roll(id: String, sd: int) -> Dictionary:
	var rng := _rng(sd)
	var p := {}
	match id:
		"carousel":
			p["k"] = rng.randi_range(1, 7)
		"vanguard":
			p["pat"] = rng.randi_range(0, VANGUARD_FILES.size() - 1)
		"sinkholes":
			p["n"] = rng.randi_range(1, 3)
		"walls":
			p["n"] = rng.randi_range(1, 2)
			p["len"] = rng.randi_range(2, 3)
		"bastions":
			p["vertical"] = rng.randi() % 2 == 0
			p["w"] = rng.randi_range(2, 4)
			p["d"] = rng.randi_range(1, 2)
	var j := {"id": id, "kind": INFO[id]["kind"], "name": INFO[id]["name"], "seed": sd, "p": p}
	j["desc"] = describe(j)
	return j


static func describe(j: Dictionary) -> String:
	var p: Dictionary = j["p"]
	match j["id"]:
		"carousel":
			return "The back rank rotates %d file%s toward the a-file." % [p["k"], "" if p["k"] == 1 else "s"]
		"mirror":
			return "The back rank is reversed: queen and king swap sides."
		"shuffle":
			return "The back rank is shuffled Chess960-style."
		"vanguard":
			return "The %s start one square forward." % VANGUARD_NAMES[p["pat"]]
		"cavalry":
			return "Both knights start on the third rank."
		"lift":
			return "Both rooks start on the third rank."
		"sinkholes":
			return "%d pair%s of squares in the middle collapse into pits." % [p["n"], "" if p["n"] == 1 else "s"]
		"walls":
			return "%d pair%s of walls, %d squares long, rise between squares in the middle. Nothing but knights crosses them." \
					% [p["n"], "" if p["n"] == 1 else "s", p["len"]]
		"bastions":
			return "A %dx%d bastion sticks out of %s of the board; pawns promote on its tip." \
					% [p["w"], p["d"], "both ends" if p["vertical"] else "both sides"]
	return ""


## A freshly rolled joker with a new random seed. Layout jokers also record which colour's half
## they rearrange.
static func create(id: String, color := BoardModel.WHITE) -> Dictionary:
	var j := roll(id, randi())
	if j["kind"] == LAYOUT:
		j["color"] = color
	return j


## The same kind of joker (and colour) rolled again with a new seed.
static func reroll(j: Dictionary) -> Dictionary:
	return create(j["id"], j.get("color", BoardModel.WHITE))


static func random_joker() -> Dictionary:
	return create(ALL_IDS[randi() % ALL_IDS.size()], randi() % 2)


static func side_name(color: int) -> String:
	return "White" if color == BoardModel.WHITE else "Black"


# ---------------------------------------------------------------- building a position

## The starting position for a list of jokers. Shape jokers reshape the board first, then each
## layout joker rearranges the half of the colour in its "color". If a combination ever produces
## an unplayable position, layout jokers are dropped (latest first) until it is playable, so a
## game can always be started.
static func build(list: Array):
	var shapes := []
	var layouts := []
	for j in list:
		if j["kind"] == SHAPE:
			shapes.append(j)
		else:
			layouts.append(j)
	while true:
		var m = BoardModel.new()
		m.setup_standard()
		for j in shapes:
			apply_shape(m, j)
		for j in layouts:
			apply_layout(m, j.get("color", BoardModel.WHITE), j)
		m.finish_setup()
		if layouts.is_empty() or is_playable(m):
			return m
		layouts.pop_back()
	return null


static func is_playable(m) -> bool:
	if m.ksq[0] == -1 or m.ksq[1] == -1:
		return false
	if m.is_attacked(m.ksq[0], 1) or m.is_attacked(m.ksq[1], 0):
		return false
	for s in BoardModel.CELLS:
		if m.sq[s] != 0 and m.cell[s] == 0:
			return false
	return m.has_legal_move()


# ---------------------------------------------------------------- layout jokers

static func apply_layout(m, color: int, j: Dictionary) -> void:
	var home := CY + 7 * color          # the colour's back rank row
	var pawns := CY + 1 + 5 * color     # its pawn row
	var third := CY + 2 + 3 * color     # the row in front of the pawns
	var p: Dictionary = j["p"]
	match j["id"]:
		"carousel":
			var row := _read_row(m, home)
			for f in 8:
				m.sq[home * GW + CX + f] = row[(f + p["k"]) % 8]
		"mirror":
			var row := _read_row(m, home)
			for f in 8:
				m.sq[home * GW + CX + f] = row[7 - f]
		"shuffle":
			var types := _chess960(_rng(j["seed"]))
			for f in 8:
				m.sq[home * GW + CX + f] = BoardModel.piece(types[f], color)
		"vanguard":
			for f in VANGUARD_FILES[p["pat"]]:
				_advance(m, pawns, third, f, BoardModel.PAWN)
		"cavalry":
			for f in 8:
				_advance(m, home, third, f, BoardModel.KNIGHT)
		"lift":
			for f in 8:
				_advance(m, home, third, f, BoardModel.ROOK)


static func _read_row(m, y: int) -> Array:
	var row := []
	for f in 8:
		row.append(m.sq[y * GW + CX + f])
	return row


## Moves the piece of `type` standing on file `f` of row `from_y` to row `to_y`, if there is
## room (the target square must exist and be empty).
static func _advance(m, from_y: int, to_y: int, f: int, type: int) -> void:
	var a := from_y * GW + CX + f
	var b := to_y * GW + CX + f
	if (m.sq[a] & 7) == type and m.sq[b] == 0 and m.cell[b] != 0:
		m.sq[b] = m.sq[a]
		m.sq[a] = 0


## A Chess960 back rank: bishops on opposite colours, king between the rooks.
static func _chess960(rng: RandomNumberGenerator) -> Array:
	var row := [0, 0, 0, 0, 0, 0, 0, 0]
	row[[0, 2, 4, 6][rng.randi_range(0, 3)]] = BoardModel.BISHOP
	row[[1, 3, 5, 7][rng.randi_range(0, 3)]] = BoardModel.BISHOP
	var free := []
	for f in 8:
		if row[f] == 0:
			free.append(f)
	var q := rng.randi_range(0, free.size() - 1)
	row[free[q]] = BoardModel.QUEEN
	free.remove_at(q)
	for k in 2:
		var n := rng.randi_range(0, free.size() - 1)
		row[free[n]] = BoardModel.KNIGHT
		free.remove_at(n)
	row[free[0]] = BoardModel.ROOK
	row[free[1]] = BoardModel.KING
	row[free[2]] = BoardModel.ROOK
	return row


# ---------------------------------------------------------------- shape jokers

## The square on the opposite side of the board's centre (180 degree rotation).
static func mirror_sq(s: int) -> int:
	return (GH - 1 - s / GW) * GW + (GW - 1 - s % GW)


static func apply_shape(m, j: Dictionary) -> void:
	var rng := _rng(j["seed"])
	var p: Dictionary = j["p"]
	match j["id"]:
		"sinkholes":
			_pits(m, rng, p["n"])
		"walls":
			_walls(m, rng, p["n"], p["len"])
		"bastions":
			_bastion(m, rng, p["vertical"], p["w"], p["d"])
	m.build_tables()


## Is every existing square still reachable from every other (walls respected)?
static func connected(m) -> bool:
	if m.valid.is_empty():
		return false
	var seen := PackedByteArray()
	seen.resize(BoardModel.CELLS)
	var stack := [m.valid[0]]
	seen[m.valid[0]] = 1
	var count := 1
	while not stack.is_empty():
		var s: int = stack.pop_back()
		for d in 4:
			var n: int = m.nbr[s * 8 + d]
			if n != -1 and seen[n] == 0:
				seen[n] = 1
				count += 1
				stack.append(n)
	return count == m.valid.size()


## Pits go in the middle four ranks only, so no starting piece ever stands on one.
static func _pits(m, rng: RandomNumberGenerator, n: int) -> void:
	var placed := 0
	var tries := 0
	while placed < n and tries < 80:
		tries += 1
		var s := (CY + rng.randi_range(2, 5)) * GW + CX + rng.randi_range(0, 7)
		var s2 := mirror_sq(s)
		if m.cell[s] == 0 or m.cell[s2] == 0:
			continue
		m.cell[s] = 0
		m.cell[s2] = 0
		m.build_tables()
		if connected(m):
			placed += 1
		else:
			m.cell[s] = 1
			m.cell[s2] = 1
			m.build_tables()


## Walls run along the middle edges: horizontal ones between ranks 3|4 .. 5|6, vertical ones
## between files, within ranks 3-6.
static func _walls(m, rng: RandomNumberGenerator, n: int, length: int) -> void:
	var placed := 0
	var tries := 0
	while placed < n and tries < 80:
		tries += 1
		var cells := []  # [array, index] pairs to set
		if rng.randi() % 2 == 0:
			var y := CY + rng.randi_range(2, 4)
			var x0 := CX + rng.randi_range(0, 8 - length)
			for i in length:
				cells.append([m.wall_n, y * GW + x0 + i])
				cells.append([m.wall_n, (y_mirror_edge(y)) * GW + (GW - 1 - (x0 + i))])
		else:
			var x := CX + rng.randi_range(0, 6)
			var y0 := CY + rng.randi_range(2, 5 - length + 1)
			for i in length:
				cells.append([m.wall_e, (y0 + i) * GW + x])
				cells.append([m.wall_e, (GH - 1 - (y0 + i)) * GW + (GW - 2 - x)])
		var before_n: PackedByteArray = m.wall_n.duplicate()
		var before_e: PackedByteArray = m.wall_e.duplicate()
		for c in cells:
			c[0][c[1]] = 1
		m.build_tables()
		if connected(m):
			placed += 1
		else:
			m.wall_n = before_n
			m.wall_e = before_e
			m.build_tables()


## A horizontal wall between rows y and y+1 turns into one between rows GH-2-y and GH-1-y.
static func y_mirror_edge(y: int) -> int:
	return GH - 2 - y


static func _bastion(m, rng: RandomNumberGenerator, vertical: bool, w: int, d: int) -> void:
	var start := rng.randi_range(0, 8 - w)
	for i in w:
		for k in d:
			var s: int
			if vertical:
				s = (CY + 8 + k) * GW + CX + start + i   # past rank 8
			else:
				s = (CY + start + i) * GW + CX - 1 - k   # left of the a-file
			m.cell[s] = 1
			m.cell[mirror_sq(s)] = 1
