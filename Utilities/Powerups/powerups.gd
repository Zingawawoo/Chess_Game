extends RefCounted
## Powerup definitions: names, categories, where they can live, their random variations,
## and the hover text. The rules themselves live in chess.gd.
##
## kind "card":    sits beside the board (max 3), click it to use it.
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

const PIECE_NAMES := {"P": "pawn", "N": "knight", "B": "bishop", "R": "rook", "Q": "queen", "K": "king"}


static func ids() -> Array:
	return DEFS.keys()


static func pu_name(id: String) -> String:
	return DEFS[id]["name"]


static func color(id: String) -> Color:
	return CAT_COLOR[DEFS[id]["cat"]]


static func is_card(id: String) -> bool:
	return DEFS[id]["kind"] == "card"


## Rolls the random variation for a freshly granted powerup.
static func roll(id: String, rng: RandomNumberGenerator) -> Dictionary:
	match id:
		"move_twice":
			return {"same": rng.randf() < 0.5, "uses": 1}
		"teleport":
			return {"range": 0 if rng.randf() < 0.5 else 3}
		"duplicate":
			return {"uses": 1}
		"jump":
			return {"over": rng.randi_range(1, 2), "uses": rng.randi_range(1, 3)}
		"promote_early":
			return {"rank": rng.randi_range(6, 7)}
		"backstep":
			return {"back": rng.randi_range(1, 2), "fwd": rng.randi_range(2, 3), "uses": rng.randi_range(1, 3)}
		"knight_hop":
			return {"uses": rng.randi_range(1, 3)}
		"copy_move":
			return {"uses": rng.randi_range(1, 2)}
		"shield":
			return {"mode": "turns" if rng.randf() < 0.5 else "hits", "n": rng.randi_range(1, 3)}
		"decoy":
			return {"type": ["N", "B", "R"][rng.randi_range(0, 2)]}
		"chain":
			return {"uses": rng.randi_range(1, 2)}
		"ranged":
			return {"uses": rng.randi_range(1, 2)}
		"explode":
			return {"radius": rng.randi_range(1, 2)}
		"freeze":
			return {"turns": rng.randi_range(1, 3)}
		"convert":
			return {"any": rng.randf() < 0.4}
		"wall":
			return {"turns": rng.randi_range(1, 3), "len": 1 if rng.randf() < 0.6 else 3}
		"portal":
			return {"turns": rng.randi_range(2, 4)}
		"board_change":
			return {"mode": "edge" if rng.randf() < 0.5 else "random"}
		"bounty":
			return {"bonus": 5}
	return {}


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
			d = "Next time this piece moves, a copy of it stays on the square it left."
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
			d = "Swap two of your pieces that meet on a rank or file with nothing between them. Free action."
		"chain":
			d = "After this piece captures, it can capture again straight away."
		"ranged":
			d = "This piece captures without moving onto the square."
		"explode":
			d = "When this piece is captured, it also destroys every piece within %d square%s (kings are immune)." \
					% [v["radius"], _s(v["radius"])]
		"freeze":
			d = "An enemy piece can't move (or give check) for %d turn%s. Free action." % [v["turns"], _s(v["turns"])]
		"convert":
			d = ("Turn any enemy piece (not the king)" if v.get("any", false) else "Turn an enemy pawn") + " into yours. Free action."
		"wall":
			d = "Block %s for %d enemy turn%s. Free action." \
					% ["an empty square" if v["len"] == 1 else "a row of 3 empty squares", v["turns"], _s(v["turns"])]
		"portal":
			d = "Link two empty squares for %d enemy turns. A piece that lands on one comes out of the other. Free action." % v["turns"]
		"mine":
			d = "Hide a mine on an empty square. Whatever lands on it is destroyed (not kings). Free action."
		"board_change":
			d = ("The empty squares of an edge file disappear" if v.get("mode", "") == "edge" \
					else "3 random empty squares in the middle disappear") + " for good. Free action."
		"double_score":
			d = "Your next capture is worth double points. Free action."
		"bounty":
			d = "Mark an enemy piece. Capturing it gives +%d bonus points. Free action." % v.get("bonus", 5)
		"spin":
			d = "Spin one of your pieces into a random piece - any type, either colour. It might become an enemy! Free action."
	var extra := ""
	if v.has("uses") and id not in ["move_twice", "duplicate"]:
		extra = "  (%d use%s left)" % [v["uses"], _s(v["uses"])]
	return "%s\n%s%s" % [n, d, extra]
