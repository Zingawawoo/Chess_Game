extends RefCounted
## Powerup definitions: names, categories, where they can live, every variant with its rarity
## tier, and the hover text. The rules themselves live in chess.gd.
##
## kind "card":    sits beside the board (max 3), click it to use it. "uses" > 1 = usable that many times.
## kind "ability": attached to one of your pieces, or left on a square for your piece to pick up.

const MAX_CARDS := 3

## Category colours (match the sections of the ideas doc).
const CAT_COLOR := {
	"original": Color8(230, 200, 90),
	"movement": Color8(110, 200, 120),
	"protection": Color8(100, 170, 230),
	"attack": Color8(225, 95, 85),
	"board": Color8(170, 120, 220),
	"economy": Color8(240, 170, 60),
	"gambling": Color8(235, 110, 180),
}

## Rarity: chance (%) that a granted powerup comes from each tier, and its colour.
const TIER_WEIGHTS := {"common": 70, "rare": 25, "legendary": 5}
const TIER_COLOR := {"common": Color8(234, 240, 216), "rare": Color8(110, 175, 245), "legendary": Color8(245, 185, 50)}
const TIER_NAME := {"common": "Common", "rare": "Rare", "legendary": "Legendary"}

## Random Spin Wheel odds (weights): your own pieces are likelier than enemy ones, weak pieces
## likelier than strong ones. Kings are never an outcome.
const SPIN_WEIGHTS := {
	"own": {"P": 22, "N": 12, "B": 12, "R": 10, "Q": 4},
	"enemy": {"P": 14, "N": 8, "B": 8, "R": 6, "Q": 4},
}

## types: piece letters an ability can be attached to.
const DEFS := {
	# Original list
	"move_twice": {"name": "Move Twice", "cat": "original", "kind": "ability", "types": "PNBRQ"},
	"teleport": {"name": "Teleport", "cat": "original", "kind": "card"},
	"best_move": {"name": "Best Move", "cat": "original", "kind": "card"},
	"duplicate": {"name": "Duplicate", "cat": "original", "kind": "ability", "types": "PNBRQ"},
	"gain_taken": {"name": "Gain Taken Piece", "cat": "original", "kind": "card"},
	# Movement
	"jump": {"name": "Jump", "cat": "movement", "kind": "ability", "types": "BRQ"},
	"swap": {"name": "Swap", "cat": "movement", "kind": "card"},
	"promote_early": {"name": "Promote Early", "cat": "movement", "kind": "ability", "types": "P"},
	"backstep": {"name": "Backstep", "cat": "movement", "kind": "ability", "types": "P"},
	"knight_hop": {"name": "Knight Hop", "cat": "movement", "kind": "ability", "types": "PBRQ"},
	"copy_move": {"name": "Copy Move", "cat": "movement", "kind": "ability", "types": "PNBR"},
	# Protection
	"shield": {"name": "Shield", "cat": "protection", "kind": "ability", "types": "PNBRQ"},
	"revive": {"name": "Revive", "cat": "protection", "kind": "card"},
	"decoy": {"name": "Decoy", "cat": "protection", "kind": "card"},
	"castle_any": {"name": "Castle Anytime", "cat": "protection", "kind": "card"},
	# Attack
	"chain": {"name": "Chain Capture", "cat": "attack", "kind": "ability", "types": "PNBRQ"},
	"ranged": {"name": "Ranged Capture", "cat": "attack", "kind": "ability", "types": "PNBRQ"},
	"explode": {"name": "Explode", "cat": "attack", "kind": "ability", "types": "PNBRQ"},
	"freeze": {"name": "Freeze", "cat": "attack", "kind": "card"},
	"convert": {"name": "Convert", "cat": "attack", "kind": "card"},
	# Board & squares
	"wall": {"name": "Wall", "cat": "board", "kind": "card"},
	"portal": {"name": "Portal", "cat": "board", "kind": "card"},
	"mine": {"name": "Mine", "cat": "board", "kind": "card"},
	"board_change": {"name": "Board Change", "cat": "board", "kind": "card"},
	# Info & economy
	"double_score": {"name": "Double Score", "cat": "economy", "kind": "card"},
	"bounty": {"name": "Bounty", "cat": "economy", "kind": "card"},
	# Gambling
	"spin": {"name": "Random Spin Wheel", "cat": "gambling", "kind": "card"},
}

## Every variant that can be granted, with its tier. Tiers come from the self-play balance tests
## (Utilities/Simulation, ~44,000 random-loadout games): Elo gain of at least +120 = legendary,
## +40 to +119 = rare, below +40 = common. "buff" marks variants trialled to make weak powerups
## useful. Freeze is probably stronger than its score: the bots treat frozen pieces as never moving.
const CATALOG := [
	{"id": "move_twice", "v": {"same": true, "uses": 1}, "tier": "common"},
	{"id": "move_twice", "v": {"same": false, "uses": 1}, "tier": "common"},
	{"id": "move_twice", "v": {"same": false, "uses": 2}, "tier": "rare"},
	{"id": "teleport", "v": {"range": 3}, "tier": "rare"},
	{"id": "teleport", "v": {"range": 0}, "tier": "legendary"},
	{"id": "teleport", "v": {"range": 3, "uses": 2}, "tier": "legendary"},
	{"id": "duplicate", "v": {"uses": 1}, "tier": "rare"},
	{"id": "duplicate", "v": {"uses": 2}, "tier": "rare"},
	{"id": "gain_taken", "v": {}, "tier": "rare"},
	{"id": "gain_taken", "v": {"uses": 2}, "tier": "legendary"},
	{"id": "jump", "v": {"over": 1, "uses": 1}, "tier": "common"},
	{"id": "jump", "v": {"over": 1, "uses": 3}, "tier": "rare"},
	{"id": "jump", "v": {"over": 2, "uses": 1}, "tier": "common"},
	{"id": "jump", "v": {"over": 2, "uses": 3}, "tier": "rare"},
	{"id": "swap", "v": {}, "tier": "rare"},
	{"id": "swap", "v": {"uses": 2}, "tier": "rare"},
	{"id": "promote_early", "v": {"rank": 7}, "tier": "common"},
	{"id": "promote_early", "v": {"rank": 6}, "tier": "common"},
	{"id": "backstep", "v": {"back": 1, "fwd": 2, "uses": 1}, "tier": "common"},
	{"id": "backstep", "v": {"back": 2, "fwd": 3, "uses": 3}, "tier": "common"},
	{"id": "knight_hop", "v": {"uses": 1}, "tier": "common"},
	{"id": "knight_hop", "v": {"uses": 3}, "tier": "rare"},
	{"id": "copy_move", "v": {"uses": 1}, "tier": "common"},
	{"id": "copy_move", "v": {"uses": 2}, "tier": "rare"},
	{"id": "shield", "v": {"mode": "turns", "n": 1}, "tier": "common"},
	{"id": "shield", "v": {"mode": "hits", "n": 1}, "tier": "rare"},
	{"id": "shield", "v": {"mode": "turns", "n": 3}, "tier": "common"},
	{"id": "shield", "v": {"mode": "hits", "n": 3}, "tier": "rare"},
	{"id": "revive", "v": {}, "tier": "rare"},
	{"id": "revive", "v": {"uses": 2}, "tier": "legendary"},
	{"id": "decoy", "v": {"type": "N"}, "tier": "rare"},
	{"id": "decoy", "v": {"type": "B"}, "tier": "rare"},
	{"id": "decoy", "v": {"type": "R"}, "tier": "rare"},
	{"id": "castle_any", "v": {}, "tier": "common"},
	{"id": "castle_any", "v": {"shield": 1}, "tier": "common", "buff": true},
	{"id": "castle_any", "v": {"enemy": true}, "tier": "rare", "buff": true},
	{"id": "chain", "v": {"uses": 1}, "tier": "common"},
	{"id": "chain", "v": {"uses": 2}, "tier": "common"},
	{"id": "ranged", "v": {"uses": 1}, "tier": "common"},
	{"id": "ranged", "v": {"uses": 2}, "tier": "common"},
	{"id": "explode", "v": {"radius": 1}, "tier": "rare"},
	{"id": "explode", "v": {"radius": 2}, "tier": "common"},
	{"id": "explode", "v": {"radius": 1, "survive": true}, "tier": "rare"},
	{"id": "explode", "v": {"radius": 1, "uses": 2}, "tier": "rare"},
	{"id": "freeze", "v": {"turns": 1}, "tier": "common"},
	{"id": "freeze", "v": {"turns": 3}, "tier": "common"},
	{"id": "freeze", "v": {"turns": 2, "count": 2}, "tier": "common", "buff": true},
	{"id": "freeze", "v": {"turns": 1, "area": 1}, "tier": "common", "buff": true},
	{"id": "convert", "v": {"any": false}, "tier": "rare"},
	{"id": "convert", "v": {"any": true}, "tier": "legendary"},
	{"id": "convert", "v": {"any": false, "uses": 2}, "tier": "legendary"},
	{"id": "wall", "v": {"turns": 1, "len": 1}, "tier": "common"},
	{"id": "wall", "v": {"turns": 3, "len": 1}, "tier": "common"},
	{"id": "wall", "v": {"turns": 1, "len": 3}, "tier": "common"},
	{"id": "wall", "v": {"turns": 3, "len": 3}, "tier": "common"},
	{"id": "portal", "v": {"turns": 2}, "tier": "common"},
	{"id": "portal", "v": {"turns": 4}, "tier": "common"},
	{"id": "mine", "v": {}, "tier": "common"},
	{"id": "mine", "v": {"count": 3}, "tier": "common", "buff": true},
	{"id": "mine", "v": {"blast": 1}, "tier": "common", "buff": true},
	{"id": "board_change", "v": {"mode": "edge"}, "tier": "common"},
	{"id": "board_change", "v": {"mode": "random"}, "tier": "common"},
	{"id": "board_change", "v": {"mode": "choose", "n": 3}, "tier": "common", "buff": true},
	{"id": "board_change", "v": {"mode": "pit"}, "tier": "rare", "buff": true},
	{"id": "double_score", "v": {}, "tier": "common"},
	{"id": "bounty", "v": {"bonus": 5}, "tier": "common"},
	{"id": "spin", "v": {}, "tier": "common"},
	{"id": "best_move", "v": {}, "tier": "common"},
]

const PIECE_NAMES := {"P": "pawn", "N": "knight", "B": "bishop", "R": "rook", "Q": "queen", "K": "king"}


static func ids() -> Array:
	return DEFS.keys()


static func pu_name(id: String) -> String:
	return DEFS[id]["name"]


static func color(id: String) -> Color:
	return CAT_COLOR[DEFS[id]["cat"]]


static func is_card(id: String) -> bool:
	return DEFS[id]["kind"] == "card"


## Picks a powerup to grant: first a tier by TIER_WEIGHTS, then any variant of that tier.
## allow_cards = false skips cards (the hand is full). Returns {"id", "v", "tier"}.
static func pick(rng: RandomNumberGenerator, allow_cards := true) -> Dictionary:
	var by_tier := {}
	for e in CATALOG:
		if not allow_cards and is_card(e["id"]):
			continue
		if not by_tier.has(e["tier"]):
			by_tier[e["tier"]] = []
		by_tier[e["tier"]].append(e)
	var total := 0
	for t in by_tier:
		total += int(TIER_WEIGHTS[t])
	if total == 0:
		return {}
	var roll := rng.randi_range(1, total)
	for t in ["common", "rare", "legendary"]:
		if not by_tier.has(t):
			continue
		roll -= int(TIER_WEIGHTS[t])
		if roll <= 0:
			var list: Array = by_tier[t]
			var e: Dictionary = list[rng.randi_range(0, list.size() - 1)]
			return {"id": e["id"], "v": e["v"].duplicate(true), "tier": t}
	return {}


## The tier of a variant (matched on its settings, ignoring how many uses are left).
static func tier_of(id: String, v: Dictionary) -> String:
	var best := "common"
	for e in CATALOG:
		if e["id"] != id:
			continue
		var same := true
		for k in e["v"]:
			if k == "uses":
				continue
			if not v.has(k) or str(v[k]) != str(e["v"][k]):
				same = false
				break
		for k in v:
			if k != "uses" and not e["v"].has(k):
				same = false
		if same:
			best = e["tier"]
			if int(e["v"].get("uses", 1)) == int(v.get("uses", 1)):
				return best
	return best


## Random Spin Wheel: a weighted random piece for the spinner (side), never a pawn on a back rank.
static func spin_result(rng: RandomNumberGenerator, side: String, pawn_ok: bool) -> String:
	var opts: Array = []
	var total := 0
	for who in ["own", "enemy"]:
		var col := side if who == "own" else ("b" if side == "w" else "w")
		for t in SPIN_WEIGHTS[who]:
			if t == "P" and not pawn_ok:
				continue
			var w: int = SPIN_WEIGHTS[who][t]
			opts.append([col + t, w])
			total += w
	var roll := rng.randi_range(1, total)
	for o in opts:
		roll -= int(o[1])
		if roll <= 0:
			return o[0]
	return opts[0][0]


static func _s(n: int) -> String:
	return "" if n == 1 else "s"


## Hover text for a powerup with its variation.
static func describe(id: String, v: Dictionary) -> String:
	var n := pu_name(id)
	var d := ""
	match id:
		"move_twice":
			d = "After this piece moves, you move again" + (" with the same piece." if v.get("same", false) else " with any piece.")
		"teleport":
			d = "Move one of your pieces to any empty square" if v.get("range", 0) == 0 \
					else "Move one of your pieces to an empty square up to %d squares away" % v["range"]
			d += ". Free action."
		"best_move":
			d = "Shows Stockfish's best move for you. Free action."
		"duplicate":
			var u: int = int(v.get("uses", 1))
			d = "Next time this piece moves, a copy of it stays on the square it left." if u == 1 \
					else "The next %d times this piece moves, a copy stays on the square it left." % u
		"gain_taken":
			d = "Take one of the enemy pieces you've captured and place it on any empty square as yours. Free action."
		"jump":
			d = "This piece can slide over up to %d piece%s in its way." % [v["over"], _s(v["over"])]
		"swap":
			d = "Trade places between two of your pieces. Free action."
		"promote_early":
			d = "This pawn promotes when it reaches rank %d instead of the last rank." % v["rank"]
		"backstep":
			d = "This pawn can move back up to %d square%s, or forward up to %d squares (no captures)." \
					% [v["back"], _s(v["back"]), v["fwd"]]
		"knight_hop":
			d = "This piece can also move like a knight."
		"copy_move":
			d = "This piece can also move like a queen or a knight (any other piece's move)."
		"shield":
			if v.get("mode", "") == "turns":
				d = "This piece can't be captured for %d enemy turn%s." % [v["n"], _s(v["n"])]
			else:
				d = "Blocks the next %d capture attempt%s against this piece (the attacker bounces off)." % [v["n"], _s(v["n"])]
		"revive":
			d = "Your most recently lost piece comes back on its starting square. Free action."
		"decoy":
			d = "Place a fake %s on an empty square in your half. It moves but can't capture or give check, and is worth nothing. Free action." \
					% PIECE_NAMES[v.get("type", "N")]
		"castle_any":
			if v.get("enemy", false):
				d = "Swap one of your pieces with a piece (yours or the enemy's) it meets on a rank or file with nothing between. Free action."
			else:
				d = "Swap two of your pieces that meet on a rank or file with nothing between them. Free action."
			if v.has("shield"):
				d += " Both swapped pieces get a 1-turn shield."
		"chain":
			d = "After this piece captures, it can capture again straight away."
		"ranged":
			d = "This piece captures without moving onto the square."
		"explode":
			var r: int = int(v.get("radius", 1))
			var u: int = int(v.get("uses", 1))
			if v.get("survive", false):
				d = "The first time this piece is captured, it explodes instead: the attacker and every piece within %d square%s are destroyed (not kings) and this piece survives." % [r, _s(r)]
			elif u > 1:
				d = "When captured, this piece explodes, destroying the attacker and every piece within %d square%s (not kings). It survives the first %d explosion%s." % [r, _s(r), u - 1, _s(u - 1)]
			else:
				d = "When this piece is captured, it also destroys every piece within %d square%s (kings are immune)." % [r, _s(r)]
		"freeze":
			var t: int = int(v.get("turns", 1))
			if v.has("area"):
				d = "Every enemy piece (not the king) in a 3x3 area can't move or give check for %d turn%s. Free action." % [t, _s(t)]
			elif int(v.get("count", 1)) > 1:
				d = "%d enemy pieces (not the king) can't move or give check for %d turn%s. Free action." % [v["count"], t, _s(t)]
			else:
				d = "An enemy piece can't move (or give check) for %d turn%s. Free action." % [t, _s(t)]
		"convert":
			d = ("Turn any enemy piece (not the king)" if v.get("any", false) else "Turn an enemy pawn") \
					+ " into yours. Pawns still on their starting rank can't be converted. Free action."
		"wall":
			d = "Block %s for %d enemy turn%s. Free action." \
					% ["an empty square" if v["len"] == 1 else "a row of 3 empty squares", v["turns"], _s(v["turns"])]
		"portal":
			d = "Link two empty squares for %d enemy turns. A piece that lands on one comes out of the other. Free action." % v["turns"]
		"mine":
			if int(v.get("count", 1)) > 1:
				d = "Hide %d mines on empty squares. Whatever lands on one is destroyed (not kings). Free action." % v["count"]
			elif v.has("blast"):
				d = "Hide a mine on an empty square. Whatever lands on it is destroyed, and so is every piece next to it (not kings). Free action."
			else:
				d = "Hide a mine on an empty square. Whatever lands on it is destroyed (not kings). Free action."
		"board_change":
			match v.get("mode", ""):
				"edge":
					d = "The empty squares of an edge file disappear for good. Free action."
				"choose":
					d = "Choose %d empty squares to remove from the board for good. Free action." % int(v.get("n", 3))
				"pit":
					d = "Pick an enemy pawn: it falls through the board and its square becomes a hole. Free action."
				_:
					d = "3 random empty squares in the middle disappear for good. Free action."
		"double_score":
			d = "Your next capture is worth double points. Free action."
		"bounty":
			d = "Mark an enemy piece. Capturing it gives +%d bonus points. Free action." % v.get("bonus", 5)
		"spin":
			d = "Spin one of your pieces into a random piece. 60% it stays yours, 40% it becomes the enemy's; weak pieces come up more than strong ones. Free action."
	var extra := ""
	if v.has("uses") and id not in ["move_twice", "duplicate", "explode"]:
		extra = "  (%d use%s left)" % [v["uses"], _s(v["uses"])]
	return "%s  [%s]\n%s%s" % [n, TIER_NAME[tier_of(id, v)], d, extra]
