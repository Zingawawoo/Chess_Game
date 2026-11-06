# Stockfish

The game's "Play vs Stockfish" option runs the Stockfish chess engine as a
child process. The binary is not committed to git (it is ~100 MB).

The game looks for it in this order:

1. the `STOCKFISH_PATH` environment variable
2. `engine/stockfish` (`engine/stockfish.exe` on Windows) in this folder
3. `engine/` or the same folder as the exported game executable
4. anywhere on your `PATH`

## Getting it

- Arch / Omarchy: `sudo pacman -S stockfish` (then nothing else to do), or
- download a build from https://stockfishchess.org/download/ (or the
  [GitHub releases](https://github.com/official-stockfish/Stockfish/releases)),
  and save the executable here as `engine/stockfish` (`chmod +x` on Linux/macOS).
