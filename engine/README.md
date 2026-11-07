# Engine (Fairy-Stockfish)

The game downloads its own pinned copy of **Fairy-Stockfish 14** (`fairy_sf_14`) the first
time it runs, on Windows and Linux. Nothing to install by hand.

Fairy-Stockfish plays normal chess, and also accepts custom rules. Before every search the
game writes the current powerup rules as a variant (`user://engine/powerchess.ini`):
- pieces with Knight Hop / Copy Move / Jump / Backstep become custom piece types
- frozen pieces become immobile
- walls and holes become squares nothing may move to

Mines, portals, shields, explosions, decoys, extra moves and ranged captures can't be
expressed in its rules format; the game still only lets it play moves that are legal here.

- Version: `VERSION` in `Utilities/Engine/stockfish_installer.gd`. Change it and the new
  version downloads on the next launch.
- Saved in the game's user data folder (`user://engine/`):
  - Windows: `%APPDATA%\Godot\app_userdata\Chess\engine\` (exported game: `%APPDATA%\Chess\engine\`)
  - Linux: `~/.local/share/godot/app_userdata/Chess/engine/`
- Gets the fast BMI2 build first; if that crashes on an older CPU it switches to the
  generic build automatically.
- Fairy-Stockfish is GPL-3.0: https://github.com/fairy-stockfish/Fairy-Stockfish

Override (for development): set `STOCKFISH_PATH` to use a specific binary.
