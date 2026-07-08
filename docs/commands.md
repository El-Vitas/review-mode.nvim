# Comandos, alias y keymaps

Los comandos largos van capitalizados (`:ReviewX`); cada uno tiene un **alias
corto real** (`:Rx`) y una versión en **minúscula** (`rx`) resuelta por
`cnoreabbrev` en `plugin/review.lua` (podés escribir en minúscula y se expande
al confirmar). El prefijo de keymaps es `opts.leader` (default `<leader>r`).

## Comentarios

| Comando | Alias | Keymap | Acción |
|---|---|---|---|
| `:ReviewCommentMode` | `:Rcm` / `rcm` | `<leader>re` | editar el comentario de la línea |
| — | — | `<leader>rc` (n y v) | comentar la línea / la selección visual |
| — | — | `<leader>rd` | borrar el comentario de la línea |
| — | — | `<leader>rx` | resolver / des-resolver |
| `:ReviewList` | `:Rl` / `rl` | `<leader>rl` | listar todos (quickfix) |
| `:ReviewListFile` | `:Rlf` / `rlf` | `<leader>rL` | listar los del archivo actual |
| `:ReviewToggle` | `:Rt` / `rt` | `<leader>rh` | ocultar / mostrar todos |
| `:ReviewPeek` | `:Rp` / `rp` | `<leader>rp` | tarjeta flotante centrada del comentario (toggle; 1 sola a la vez) |

**Popup de comentario:** arranca escribiendo; Enter hace saltos de línea;
`Esc` y `Enter` (en normal) envía; `q` cancela.

**Dentro de la lista (quickfix):** `Enter` va al comentario y cierra · `d` borra
· `x` resuelve · `f` cicla el filtro (all → open → resolved → mine → agent →
answered → unanswered) · `q` cierra. La lista muestra solo comentarios top-level
(las respuestas viven en el hilo del padre, visible en el peek).

## Agente (solo con `features.agent = { enabled = true }`)

| Comando | Acción |
|---|---|
| `:ReviewReload` | recargar el buffer actual desde disco con patch mínimo (fallback manual del re-anclaje AUTO, p. ej. si había conflicto por cambios sin guardar) |

El resto del control del agente es por RPC (`_G.ReviewAgent`, ver `docs/features.md`
y `docs/plans/05-agent.md`), no por comandos de usuario.

**Dentro de la tarjeta del peek:** `x` resolver · `d` borrar · `e` editar · `q`/`Esc` cerrar. Es una sola tarjeta centrada (abrir otra cierra la anterior).

## Vistas (diff)

| Comando | Alias | Keymap | Acción |
|---|---|---|---|
| `:ReviewView {normal\|inline\|split}` | `:Rv` / `rv` | `<leader>rv` (cicla) | fijar/ciclar vista |
| `:ReviewNormal` | `:Rvn` / `rvn` | `<leader>rn` | vista normal |
| `:ReviewInline` | `:Rvi` / `rvi` | `<leader>ri` | vista inline (unificada) |
| `:ReviewSplit` | `:Rvs` / `rvs` | `<leader>rs` | vista split (2 columnas) |

El modo es global: se aplica a todos los archivos y sigue al archivo activo.

**Cambios (vs la base):** `<leader>rg` lista los rangos (quickfix; `Enter` salta y
cierra, `q` cierra) · `]r` / `[r` saltan al siguiente/anterior cambio.

**Base de comparación:** `:ReviewBase` / `:Rb` / `<leader>rb` abre un modal
centrado para elegir contra qué se compara todo review (inline, split, cambios):
`HEAD`, `index` (staged), o un commit reciente (hash + nombre). `Enter` selecciona,
`q`/`Esc` cancela. Al elegir, también sincroniza los signos de gitsigns
(`change_base`). Default: `HEAD`.

## Sidebar

| Comando | Alias | Keymap | Acción |
|---|---|---|---|
| `:ReviewSidebar {changed\|all}` | `:Rs` / `rs` | `<leader>s` (toggle) | abrir/alternar cambiados ↔ todos |

Dentro del árbol (neo-tree nativo): `z` cierra todas · `Z` expande todas ·
`<CR>`/`o` toggle carpeta · `C` cierra la actual · `:Neotree reveal` enfoca el
archivo actual.

## Export

| Comando | Alias | Keymap | Acción |
|---|---|---|---|
| `:ReviewYankFile` | `:Ryf` / `ryf` | `<leader>ryf` | copiar (markdown) los comentarios del archivo actual |
| `:ReviewYankAll` | `:Rya` / `rya` | `<leader>rya` | copiar todos los comentarios |

Con la feature `agent` habilitada, el yank antepone una cabecera con el socket RPC
y cada comentario lleva su token `` `id:<id>` `` (agent-ready).
</content>
