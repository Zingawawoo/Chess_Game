# Stockfish

The game downloads its own pinned copy of Stockfish (currently **17.1**) the first
time it runs, on Windows and Linux. Nothing to install by hand.

- Version: `VERSION` in `Utilities/Engine/stockfish_installer.gd` (a release tag from
  https://github.com/official-stockfish/Stockfish/releases). Change it and the new
  version downloads on the next launch.
- It is saved in the game's user data folder (`user://engine/`):
  - Windows: `%APPDATA%\Godot\app_userdata\Chess\engine\` (exported game: `%APPDATA%\Chess\engine\`)
  - Linux: `~/.local/share/godot/app_userdata/Chess/engine/`
- It gets the fast AVX2 build first; if that crashes on an older CPU it switches to
  the generic build automatically.
- Stockfish is GPL-3.0. Its licence (`Copying.txt`) is saved next to the engine.

Overrides (for development): set `STOCKFISH_PATH` to use a specific binary, or put
`stockfish` / `stockfish.exe` in this folder (the pinned download is used first).
