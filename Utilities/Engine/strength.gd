extends RefCounted
## How strong the computer opponent plays. Shared by the normal board and the Joker Run.
##
## Searching less deep is not enough to make an engine feel beatable: even a shallow Stockfish
## never hangs a piece. So each level also sets
##  - Stockfish's own "Skill Level" (it deliberately picks weaker moves), and
##  - a mistake rate: that fraction of moves is replaced by a random legal move, the way a
##    beginner just blunders.
## The built-in AI (used on Joker Run boards Stockfish can't play) gets the same depth and
## mistake rate.

const LEVELS := [
	{"name": "Beginner", "depth": 1, "skill": 0, "mistakes": 0.35,
			"tip": "Looks 1 move ahead and plays a random move about 1 time in 3."},
	{"name": "Easy", "depth": 2, "skill": 3, "mistakes": 0.18,
			"tip": "Looks 2 moves ahead and plays a random move about 1 time in 5."},
	{"name": "Medium", "depth": 4, "skill": 8, "mistakes": 0.07,
			"tip": "Looks 4 moves ahead and now and then slips."},
	{"name": "Hard", "depth": 8, "skill": 20, "mistakes": 0.0,
			"tip": "Looks 8 moves ahead and never plays a deliberate mistake."},
]

## Index of the "Custom" entry: the Depth box is used as is, at full strength, with no mistakes.
const CUSTOM := 4
const DEFAULT := 0


static func names() -> Array:
	var res := []
	for lv in LEVELS:
		res.append(lv["name"])
	res.append("Custom")
	return res


static func tooltip() -> String:
	var lines := []
	for lv in LEVELS:
		lines.append("%s: %s" % [lv["name"], lv["tip"]])
	lines.append("Custom: set the Depth yourself, full strength.")
	return "\n".join(lines)
