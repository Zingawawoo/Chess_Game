extends Node
## Downloads a pinned Stockfish release the first time the game needs it, for Windows and
## Linux, and keeps it in the game's user data folder. Every player ends up on the same
## engine version, with no setup.
##
## To change the version, edit VERSION (a release tag from
## https://github.com/official-stockfish/Stockfish/releases) - it re-downloads on next launch.

signal progress(fraction: float)
signal finished(ok: bool, message: String)

const VERSION := "sf_17.1"
const BASE_URL := "https://github.com/official-stockfish/Stockfish/releases/download/"
const DIR := "user://engine"

var busy := false
var _http: HTTPRequest
var _variant := ""
var _archive := ""


static func is_supported() -> bool:
	return OS.get_name() in ["Windows", "Linux"]


static func exe_path() -> String:
	var name := "stockfish.exe" if OS.get_name() == "Windows" else "stockfish"
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


## Which build is installed: "avx2" (fast, needs a CPU from ~2015 on) or "generic".
static func installed_variant() -> String:
	if not FileAccess.file_exists(_version_file()):
		return ""
	var parts := FileAccess.get_file_as_string(_version_file()).strip_edges().split(" ")
	return parts[1] if parts.size() > 1 else ""


## Starts downloading. variant: "avx2" or "generic" (for CPUs that can't run the avx2 build).
func install(variant := "avx2") -> void:
	if busy or not is_supported():
		return
	busy = true
	_variant = variant
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(DIR))
	var asset := _asset_name()
	_archive = DIR.path_join(asset)
	_http = HTTPRequest.new()
	_http.download_file = _archive
	_http.use_threads = true
	_http.request_completed.connect(_on_downloaded)
	add_child(_http)
	_use_system_proxy(_http)
	var err := _http.request(BASE_URL + VERSION + "/" + asset)
	if err != OK:
		_finish(false, "Couldn't start the Stockfish download (error %d)" % err)


func _asset_name() -> String:
	var suffix := "-avx2" if _variant == "avx2" else ""
	if OS.get_name() == "Windows":
		return "stockfish-windows-x86-64%s.zip" % suffix
	return "stockfish-ubuntu-x86-64%s.tar" % suffix


## Name of the engine binary inside the archive.
func _binary_name() -> String:
	var suffix := "-avx2" if _variant == "avx2" else ""
	if OS.get_name() == "Windows":
		return "stockfish-windows-x86-64%s.exe" % suffix
	return "stockfish-ubuntu-x86-64%s" % suffix


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
		_finish(false, "Stockfish download failed (result %d, HTTP %d) - check your internet connection" % [result, code])
		return
	var err := _extract()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(_archive))
	if err != "":
		_finish(false, err)
		return
	var f := FileAccess.open(_version_file(), FileAccess.WRITE)
	f.store_string("%s %s\n" % [VERSION, _variant])
	f.close()
	_finish(true, "Stockfish %s installed" % VERSION.trim_prefix("sf_"))


## Pulls the engine binary (and its licence) out of the downloaded archive.
func _extract() -> String:
	var want := _binary_name()
	var files := {}
	if _archive.ends_with(".zip"):
		var zip := ZIPReader.new()
		if zip.open(_archive) != OK:
			return "The Stockfish download is not a valid zip"
		for name in zip.get_files():
			if name.get_file() == want:
				files["bin"] = zip.read_file(name)
			elif name.get_file() == "Copying.txt":
				files["licence"] = zip.read_file(name)
		zip.close()
	else:
		files = _read_tar(ProjectSettings.globalize_path(_archive), want)
	if not files.has("bin"):
		return "Couldn't find %s in the Stockfish download" % want
	var out := FileAccess.open(exe_path(), FileAccess.WRITE)
	if out == null:
		return "Couldn't save Stockfish to " + exe_path()
	out.store_buffer(files["bin"])
	out.close()
	if files.has("licence"):
		var lic := FileAccess.open(ProjectSettings.globalize_path(DIR.path_join("Copying.txt")), FileAccess.WRITE)
		lic.store_buffer(files["licence"])
		lic.close()
	if OS.get_name() != "Windows":
		OS.execute("chmod", ["+x", exe_path()])
	return ""


## Minimal reader for an uncompressed .tar: returns {"bin": ..., "licence": ...} when found.
static func _read_tar(path: String, want: String) -> Dictionary:
	var res := {}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return res
	var total := f.get_length()
	var pos := 0
	while pos + 512 <= total:
		f.seek(pos)
		var hdr := f.get_buffer(512)
		if hdr[0] == 0:
			break
		var name := hdr.slice(0, 100).get_string_from_ascii()
		if hdr.slice(257, 262).get_string_from_ascii() == "ustar":
			var prefix := hdr.slice(345, 500).get_string_from_ascii()
			if prefix != "":
				name = prefix + "/" + name
		var size := 0
		for ch in hdr.slice(124, 136).get_string_from_ascii():
			if ch >= "0" and ch <= "7":
				size = size * 8 + int(ch)
		var kind := hdr[156]
		var data_pos := pos + 512
		if kind == 0 or kind == 48:  # regular file ('\0' or '0')
			if name.get_file() == want:
				f.seek(data_pos)
				res["bin"] = f.get_buffer(size)
			elif name.get_file() == "Copying.txt":
				f.seek(data_pos)
				res["licence"] = f.get_buffer(size)
		pos = data_pos + ((size + 511) / 512) * 512
	f.close()
	return res


func _finish(ok: bool, message: String) -> void:
	busy = false
	if _http != null:
		_http.queue_free()
		_http = null
	finished.emit(ok, message)
