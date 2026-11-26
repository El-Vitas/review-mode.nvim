# review-mode — Documentación

Code-review nativo dentro de Neovim: comentarios sobre líneas + vistas de diff
(inline / split estilo VSCode) + export agent-ready + integración con neo-tree.
La "vista" es solo **cómo se pinta el código**: todo son decoraciones (extmarks,
virtual lines, statuscolumn) sobre el buffer real. Nada de tabs nuevas, el buffer
sigue siendo el archivo real y editable.

## Índice

- [architecture.md](./architecture.md) — arquitectura: core + vertical slices, contrato, storage, eventos.
- [features.md](./features.md) — qué hace cada feature (comments, views, sidebar, export, agent).
- [commands.md](./commands.md) — todos los comandos, alias y keymaps.
- [highlights.md](./highlights.md) — grupos de highlight (colores) override-ables.
- [performance.md](./performance.md) — caches y optimizaciones (RAM/velocidad).
- [decisions.md](./decisions.md) — registro de TODAS las decisiones tomadas y su porqué.
- [roadmap.md](./roadmap.md) — próximos pasos: diseño del agente (edición en vivo, conflictos, threading) y limpieza del nvim.
- [plans/](./plans/) — planes de implementación originales (uno por slice).

## Instalación (lazy.nvim)

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

## Estado

- **Implementado y estable:** core, comments, views (inline/split), sidebar, export,
  `agent` (RPC nativo + reconciliación AUTO por patch-diff, deshabilitado por defecto).