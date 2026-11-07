extends Node
## Downloads a pinned Fairy-Stockfish release the first time the game needs it, on Windows and
## Linux, into the game's user data folder. Fairy-Stockfish plays normal chess and also accepts
## custom rules, which the game uses to describe powerups to it (see chess.gd "_fsf_position").
##
## To change the version, edit VERSION (a release tag from
## https://github.com/fairy-stockfish/Fairy-Stockfish/releases) - it re-downloads on next launch.

signal progress(fraction: float)
signal finished(ok: bool, message: String)

const VERSION := "fairy_sf_14"
const BASE_URL := "https://github.com/fairy-stockfish/Fairy-Stockfish/releases/download/"
const DIR := "user://engine"

var busy := false
var _http: HTTPRequest
var _variant := ""
var _tmp := ""


static func is_supported() -> bool:
	return OS.get_name() in ["Windows", "Linux"]


static func exe_path() -> String:
	var name := "fairy-stockfish.exe" if OS.get_name() == "Windows" else "fairy-stockfish"
	return ProjectSettings.globalize_path(DIR.path_join(name))


static func _version_file() -> String:
	return ProjectSettings.globalize_path(DIR.path_join("version.txt"))


## The pinned version's executable, or "" if it isn't installed (or a different version is).
static func installed_path() -> String:
	var exe := exe_path()
	if not FileAccess.file_exists(exe) or not FileAccess.file_exists(_version_file()):
		return ""
	var tag := FileAccess.get_file_as_string(_version_file()).strip_edges()
	return exe if tag.begins_with(VERSION + " ") else ""


## Which build is installed: "fast" (BMI2, CPUs from ~2013 on) or "generic".
static func installed_variant() -> String:
	if not FileAccess.file_exists(_version_file()):
		return ""
	var parts := FileAccess.get_file_as_string(_version_file()).strip_edges().split(" ")
	return parts[1] if parts.size() > 1 else ""


## Starts downloading. variant: "fast" or "generic" (for CPUs that can't run the fast build).
func install(variant := "fast") -> void:
	if busy or not is_supported():
		return
	busy = true
	_variant = variant
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(DIR))
	_tmp = exe_path() + ".download"
	_http = HTTPRequest.new()
	_http.download_file = _tmp
	_http.use_threads = true
	_http.request_completed.connect(_on_downloaded)
	add_child(_http)
	_use_system_proxy(_http)
	var err := _http.request(BASE_URL + VERSION + "/" + _asset_name())
	if err != OK:
		_finish(false, "Couldn't start the Fairy-Stockfish download (error %d)" % err)


func _asset_name() -> String:
	var suffix := "-bmi2" if _variant == "fast" else ""
	var ext := ".exe" if OS.get_name() == "Windows" else ""
	return "fairy-stockfish_x86-64%s%s" % [suffix, ext]


## Honour HTTPS_PROXY if the player has one set.
static func _use_system_proxy(http: HTTPRequest) -> void:
	var proxy := OS.get_environment("HTTPS_PROXY")
	if proxy == "":
		proxy = OS.get_environment("https_proxy")
	if proxy == "":
		return
	proxy = proxy.trim_prefix("http://").trim_prefix("https://").split("/")[0].split("@")[-1]
	var hp := proxy.split(":")
	if hp.size() == 2 and hp[1].is_valid_int():
		http.set_https_proxy(hp[0], int(hp[1]))
		http.set_http_proxy(hp[0], int(hp[1]))


func _process(_delta: float) -> void:
	if busy and _http != null:
		var total := _http.get_body_size()
		if total > 0:
			progress.emit(float(_http.get_downloaded_bytes()) / total)


func _on_downloaded(result: int, code: int, _headers: PackedStringArray, _body: PackedByteArray) -> void:
	if result != HTTPRequest.RESULT_SUCCESS or code != 200:
		DirAccess.remove_absolute(_tmp)
		_finish(false, "Fairy-Stockfish download failed (result %d, HTTP %d) - check your internet connection" % [result, code])
		return
	var exe := exe_path()
	if FileAccess.file_exists(exe):
		DirAccess.remove_absolute(exe)
	if DirAccess.rename_absolute(_tmp, exe) != OK:
		_finish(false, "Couldn't save Fairy-Stockfish to " + exe)
		return
	if OS.get_name() != "Windows":
		OS.execute("chmod", ["+x", exe])
	var f := FileAccess.open(_version_file(), FileAccess.WRITE)
	f.store_string("%s %s\n" % [VERSION, _variant])
	f.close()
	_finish(true, "Fairy-Stockfish %s installed" % VERSION.trim_prefix("fairy_sf_"))


func _finish(ok: bool, message: String) -> void:
	busy = false
	if _http != null:
		_http.queue_free()
		_http = null
	finished.emit(ok, message)
