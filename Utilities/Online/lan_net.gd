extends Node
## LAN multiplayer: an ENet connection for the game, plus UDP broadcasts so
## hosted games show up in other players' lobby lists on the same network.

signal lobbies_changed(lobbies: Array)  # [{name, ip, port}]
signal opponent_joined(peer_id: int)    # host side: someone joined our game
signal joined_host                      # client side: connected to a host
signal join_failed
signal opponent_left

const GAME_PORT := 7777
const DISCOVERY_PORT := 7778
const GAME_ID := "pixel-chess-lan-1"   # ignore broadcasts from other games
const BROADCAST_EVERY := 1.0           # seconds between "I'm hosting" packets
const LOBBY_TIMEOUT := 3.5             # forget a lobby we haven't heard from in this long

var hosting := false
var connected := false
var browsing := false
var lobby_name := ""

var _bcast: PacketPeerUDP
var _bcast_timer := 0.0
var _listen: PacketPeerUDP
var _lobbies := {}  # "ip:port" -> {name, ip, port, seen}


func _ready() -> void:
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)


## Starts hosting. Returns "" on success, otherwise an error message.
func host(game_name: String) -> String:
	leave()
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_server(GAME_PORT, 1)
	if err != OK:
		return "Couldn't host on port %d (is another game already hosting?)" % GAME_PORT
	multiplayer.multiplayer_peer = peer
	hosting = true
	lobby_name = game_name
	_bcast = PacketPeerUDP.new()
	_bcast.set_broadcast_enabled(true)
	_bcast.set_dest_address("255.255.255.255", DISCOVERY_PORT)
	_bcast_timer = 0.0
	return ""


## Connects to a host. Returns "" if the attempt started, otherwise an error message.
func join(ip: String) -> String:
	leave()
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_client(ip, GAME_PORT)
	if err != OK:
		return "Couldn't connect to %s" % ip
	multiplayer.multiplayer_peer = peer
	return ""


## Closes any connection and stops advertising.
func leave() -> void:
	if not is_inside_tree():
		return
	var peer := multiplayer.multiplayer_peer
	if peer != null and not peer is OfflineMultiplayerPeer:
		peer.close()
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	hosting = false
	connected = false
	_stop_broadcast()


## Starts listening for hosts on the network. Returns "" on success.
func start_browsing() -> String:
	if browsing:
		return ""
	_listen = PacketPeerUDP.new()
	if _listen.bind(DISCOVERY_PORT) != OK:
		_listen = null
		return "Can't scan for games (port %d busy) - use Join IP instead" % DISCOVERY_PORT
	browsing = true
	_lobbies.clear()
	lobbies_changed.emit([])
	return ""


func stop_browsing() -> void:
	browsing = false
	if _listen != null:
		_listen.close()
		_listen = null
	_lobbies.clear()


## This machine's LAN address, to show the host so others can type it in.
static func local_ip() -> String:
	var fallback := ""
	for a in IP.get_local_addresses():
		if a.contains(":") or a.begins_with("127.") or a.begins_with("169.254."):
			continue
		if a.begins_with("192.168.") or a.begins_with("10.") or a.begins_with("172."):
			return a
		fallback = a
	return fallback if fallback != "" else "127.0.0.1"


func _stop_broadcast() -> void:
	if _bcast != null:
		_bcast.close()
		_bcast = null


func _process(delta: float) -> void:
	# Advertise our game until someone joins.
	if _bcast != null and hosting and not connected:
		_bcast_timer -= delta
		if _bcast_timer <= 0.0:
			_bcast_timer = BROADCAST_EVERY
			var msg := {"game": GAME_ID, "name": lobby_name, "port": GAME_PORT}
			_bcast.put_packet(JSON.stringify(msg).to_utf8_buffer())

	if not browsing or _listen == null:
		return
	var now := Time.get_ticks_msec() / 1000.0
	var changed := false
	while _listen.get_available_packet_count() > 0:
		var pkt := _listen.get_packet()
		var ip := _listen.get_packet_ip()
		var data = JSON.parse_string(pkt.get_string_from_utf8())
		if typeof(data) != TYPE_DICTIONARY or data.get("game", "") != GAME_ID:
			continue
		var port := int(data.get("port", GAME_PORT))
		var key := "%s:%d" % [ip, port]
		if not _lobbies.has(key):
			changed = true
		_lobbies[key] = {"name": str(data.get("name", "Game")), "ip": ip, "port": port, "seen": now}
	for key in _lobbies.keys():
		if now - _lobbies[key]["seen"] > LOBBY_TIMEOUT:
			_lobbies.erase(key)
			changed = true
	if changed:
		var list: Array = []
		for key in _lobbies:
			list.append(_lobbies[key])
		list.sort_custom(func(a, b): return a["name"] < b["name"])
		lobbies_changed.emit(list)


func _exit_tree() -> void:
	leave()
	stop_browsing()


## Notice a vanished opponent (crash, cable pulled) within ~8s instead of ENet's default ~30s.
func _shorten_timeout(id: int) -> void:
	var peer := multiplayer.multiplayer_peer as ENetMultiplayerPeer
	if peer != null and peer.get_peer(id) != null:
		peer.get_peer(id).set_timeout(32, 3000, 8000)


func _on_peer_connected(id: int) -> void:
	_shorten_timeout(id)
	if hosting:
		connected = true
		_stop_broadcast()  # lobby is full
		opponent_joined.emit(id)


func _on_peer_disconnected(_id: int) -> void:
	if hosting and connected:
		leave()
		opponent_left.emit()


func _on_connected_to_server() -> void:
	_shorten_timeout(1)
	connected = true
	joined_host.emit()


func _on_connection_failed() -> void:
	leave()
	join_failed.emit()


func _on_server_disconnected() -> void:
	leave()
	opponent_left.emit()
