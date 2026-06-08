# Ripple Effect

> **Status: stub — not yet implemented**

## Description

Each region of size N must contain exactly the digits 1–N. Identical digits in the same row/column must be separated by at least that many cells.

## Files to create

- `board.lua` — game logic, puzzle generator, serialize/load
- `board_widget.lua` — grid rendering and tap gestures
- `screen.lua` — full-screen layout (buttons + board)
- `main.lua` — PluginBase entry point

## Notes

Grid-based logic puzzle — use GridWidgetBase from game-common.
