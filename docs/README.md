# review-mode — Documentation

Native code review inside Neovim: comments on lines + diff views
(inline / VSCode-style split) + agent-ready export + neo-tree integration.
The "view" is only **how the code is painted**: everything is decorations (extmarks,
virtual lines, statuscolumn) on top of the real buffer. No new tabs; the buffer
remains the real, editable file.

## Index

- [architecture.md](./architecture.md) — architecture: core + vertical slices, contract, storage, events.
- [features.md](./features.md) — what each feature does (comments, views, sidebar, export, agent).
- [commands.md](./commands.md) — all commands, aliases and keymaps.
- [highlights.md](./highlights.md) — overridable highlight groups (colors).
- [performance.md](./performance.md) — caches and optimizations (RAM/speed).
- [decisions.md](./decisions.md) — record of ALL decisions made and the reasoning behind them.
- [roadmap.md](./roadmap.md) — next steps: agent design (live editing, conflicts, threading) and nvim cleanup.
- [plans/](./plans/) — original implementation plans (one per slice).

## Installation (lazy.nvim)

```lua
{
  "El-Vitas/review-mode.nvim",
  dependencies = {
    "nvim-lua/plenary.nvim",
    "MunifTanjim/nui.nvim",
    "nvim-neo-tree/neo-tree.nvim",
  },
  config = function()
    require("review").setup()
  end,
}
```

## Tests

```
nvim --headless -c "PlenaryBustedDirectory tests/ {minimal_init='tests/minimal_init.lua'}" -c "qa"
```

## Status

- **Implemented and stable:** core, comments, views (inline/split), sidebar, export,
  `agent` (native RPC + AUTO reconciliation via patch-diff, disabled by default).
