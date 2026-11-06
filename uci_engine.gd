extends Node
## Minimal client for a UCI chess engine (Stockfish) running as a child process.
##
## A background thread blocks on the engine's stdout so the game never stalls;
## results come back on the main thread through signals.

## Emitted when the engine has picked a move, in UCI notation ("e2e4", "e7e8q").
signal bestmove(move: String)
## Emitted as the search deepens. The score is from the point of view of the side to
## move: `cp` is centipawns, `mate` is moves to mate (negative = being mated), 0 if unused.
signal evaluation(depth: int, cp: int, mate: int)
## Emitted when the engine process dies unexpectedly.
signal failed(reason: String)

const EOF_MARK := "<eof>"

var running := false   ## engine process is alive
var thinking := false  ## a search is in flight (even one whose result will be discarded)

var _io: FileAccess
var _pid := -1
var _thread: Thread
var _mutex := Mutex.new()
var _lines: Array[String] = []
var _discard := false  ## drop the result of the search that is currently stopping


## Looks for a Stockfish executable: $STOCKFISH_PATH, ./engine/, next to the game, then $PATH.
static func find_binary() -> String:
	var windows := OS.get_name() == "Windows"
	var exe := "stockfish.exe" if windows else "stockfish"
	var exe_dir := OS.get_executable_path().get_base_dir()
	var candidates: Array[String] = []
	var from_env := OS.get_environment("STOCKFISH_PATH")
	if from_env != "":
		candidates.append(from_env)
	candidates.append(ProjectSettings.globalize_path("res://engine/" + exe))
	candidates.append(exe_dir.path_join("engine").path_join(exe))
	candidates.append(exe_dir.path_join(exe))
	for dir in OS.get_environment("PATH").split(";" if windows else ":", false):
		candidates.append(dir.path_join(exe))
	for c in candidates:
		if FileAccess.file_exists(c):
			return c
	return ""


## Starts the engine if it is not already running. Returns "" on success, otherwise an error message.
func start() -> String:
	if running:
		return ""
	var path := find_binary()
	if path == "":
		return "Stockfish not found - put it in engine/ or install it (see engine/README.md)"
	var info := OS.execute_with_pipe(path, [])
	if info.is_empty():
		return "Could not launch " + path
	_io = info["stdio"]
	_pid = info["pid"]
	_mutex.lock()
	_lines.clear()
	_mutex.unlock()
	running = true
	thinking = false
	_discard = false
	_thread = Thread.new()
	_thread.start(_read_loop)
	_send("uci")
	_send("isready")
	return ""


## Asks the engine for a move in the position reached by `moves` (UCI strings) from the start.
func think(moves: PackedStringArray, depth: int) -> void:
	if not running or thinking:
		return
	thinking = true
	var cmd := "position startpos"
	if not moves.is_empty():
		cmd += " moves " + " ".join(moves)
	_send(cmd)
	_send("go depth %d" % depth)


## Abandons the current search; its result will not be emitted.
func cancel() -> void:
	if thinking and not _discard:
		_discard = true
		_send("stop")


func new_game() -> void:
	_send("ucinewgame")


func shutdown() -> void:
	if _thread == null:
		return
	_send("quit")
	if _pid > 0:
		OS.kill(_pid)  # closes the pipe so the reader thread is guaranteed to wake up
	_thread.wait_to_finish()
	_thread = null
	_io = null
	_pid = -1
	running = false
	thinking = false


func _exit_tree() -> void:
	shutdown()


func _process(_delta: float) -> void:
	_mutex.lock()
	var batch := _lines.duplicate()
	_lines.clear()
	_mutex.unlock()
	for line in batch:
		if line == EOF_MARK:
			if running:
				shutdown()
				failed.emit("Stockfish stopped unexpectedly")
		elif line.begins_with("eval "):
			if _discard:
				continue
			var f: PackedStringArray = line.split(" ", false)  # eval <depth> <cp|mate> <value>
			var value := int(f[3])
			evaluation.emit(int(f[1]), value if f[2] == "cp" else 0, value if f[2] == "mate" else 0)
		elif line.begins_with("bestmove"):
			thinking = false
			if _discard:
				_discard = false
				continue
			var parts: PackedStringArray = line.split(" ", false)
			if parts.size() >= 2 and parts[1] != "(none)":
				bestmove.emit(parts[1])


func _send(cmd: String) -> void:
	if running and _io != null:
		_io.store_line(cmd)
		_io.flush()


# Runs on the reader thread. Only the lines the game cares about are queued:
# "bestmove ..." as is, and "info depth ... score ..." boiled down to "eval <depth> <cp|mate> <n>".
func _read_loop() -> void:
	while true:
		var line := _io.get_line()
		if line == "" and _io.get_error() != OK:
			break
		line = line.strip_edges()
		var queued := ""
		if line.begins_with("bestmove"):
			queued = line
		elif line.begins_with("info depth ") and not (" lowerbound" in line or " upperbound" in line):
			var t: PackedStringArray = line.split(" ", false)
			var si := t.find("score")
			if si != -1 and si + 2 < t.size() and t.size() > 2:
				queued = "eval %s %s %s" % [t[2], t[si + 1], t[si + 2]]
		if queued != "":
			_mutex.lock()
			_lines.append(queued)
			_mutex.unlock()
	_mutex.lock()
	_lines.append(EOF_MARK)
	_mutex.unlock()
