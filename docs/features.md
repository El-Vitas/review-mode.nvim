# Features

## comments — comentarios de review

CRUD de comentarios anclados a línea (o rango) vía extmarks, con re-anclaje al
editar, popup multi-línea, gutter con corchetes anidados, peek inline y export.

- **Anclaje**: cada comentario tiene un extmark ancla (con `end_row`) que sigue
  la línea al editar. En `BufWritePost` se re-sincronizan `lnum`/`end_lnum`
  desde el extmark (`sync_positions`) y se persiste.
- **Render** (`render.lua`): por cada comentario del archivo pinta el fondo del
  rango (`ReviewCommentLine`, tono **alternado** entre comentarios consecutivos
  con `ReviewCommentLine2` para distinguirlos) + un **badge** al final de la
  primera línea (chip con borde `▏ 💬 texto ▕`, texto corto ~44 chars; el
  detalle completo va en el peek). Toggle global de visibilidad (`render.hidden`).
- **Gutter anidado** (`gutter.lua`): reemplaza el `statuscolumn` de las ventanas
  con archivos del repo para dibujar un **corchete por CADA comentario** que
  cubre la línea (`┌ │ └`, `▌` si es de una línea), apilados según anidación y
  con **color por comentario** (paleta cíclica de 6). Preserva signos (gitsigns)
  y número. La columna de signos solo admite 1 signo/línea, por eso el anidado
  se hace en el statuscolumn.
- **Modo / popup** (`mode.lua`): `add_here` abre un popup nui multi-línea
  (arranca en insert, Enter hace saltos de línea; se envía con **Enter en modo
  normal**, se cancela con `q`). `edit_here` reabre el popup con el texto
  existente. Núcleo testeable sin UI: `_add/_delete_at/_resolve_at/_update_at`.
- **Peek inline** (`mode.peek_here`): muestra el comentario como **virtual lines
  insertadas debajo del bloque** (estilo GitHub inline). NO es un flotante: es
  parte del flujo del código, se mueve con el scroll y no sigue al cursor.
  Toggle por comentario; varios a la vez; `close_all_peeks`.
- **Lista** (`commands.lua`): quickfix con todos (`:Rl`) o del archivo (`:Rlf`),
  ordenada por archivo+línea. Dentro de la lista: `Enter` va y cierra, `d`
  borra, `x` resuelve/des-resuelve, `f` filtra (todos/abiertos/resueltos), `q`
  cierra. Winbar con los atajos.

## views — vistas de diff (modo GLOBAL, estilo VSCode)

El modo (normal / inline / split) es **global**: aplica a todos los archivos.
Review es un modo **permanente** (no hay "salir"); las 3 vistas son sus modos.
Al entrar a cualquier archivo del repo se re-aplica la vista actual y se **abren
los folds** (para no compactar líneas nunca).

- **Comparación**: siempre `buffer actual (en memoria) vs HEAD (último commit)`.
  Muestra todo lo no commiteado. No coincide con gitsigns si algo está staged
  (gitsigns compara contra el índice).
- **normal**: buffer plano (con folds abiertos).
- **inline** (`inline.lua`): vista unificada. Diffea HEAD vs buffer con
  `vim.diff` (en memoria, live). Líneas borradas como virtual lines rojas
  (barra completa) encima; agregadas resaltadas en verde. Cachea el HEAD por
  buffer.
- **split** (`split.lua`): 2 columnas con el **diff nativo de Neovim**
  (`:diffthis`), NO diffview. Panel HEAD readonly a la izquierda (con
  `winfixbuf`, no se le pueden abrir archivos), archivo editable a la derecha.
  Sesión única que **sigue al archivo activo**; si el archivo no tiene cambios o
  no tiene HEAD → una sola columna. `diffopt` con `linematch` + `histogram` +
  `inline:char` → alineación línea-a-línea estilo VSCode. Colores por columna
  (ver highlights.md). `foldlevel=99` para no plegar.
- `diff.lua`: parseo de `git diff -U0` (`parse_unified_diff`, `hunks_for`) y
  diff en memoria (`hunks_between` con `vim.diff`).

## sidebar — integración neo-tree

- `:ReviewSidebar {changed|all}` / `:Rs` — abre neo-tree en `git_status`
  (cambiados) o `filesystem` (todos), **con las carpetas cerradas**.
- `<leader>rs` — **toggle** entre changed ↔ all.
- Se suscribe a `comments:changed` para refrescar; `files_with_comments()` es un
  helper puro (set de relpaths con comentarios); `comment_marker()` opcional.
- Degrada con gracia si neo-tree no está instalado (pcall + notify).
- Expandir/cerrar carpetas y revelar archivo se hacen con neo-tree nativo
  (`z`/`Z`, `:Neotree reveal`) — review no los envuelve.

## export — markdown agent-ready

- `markdown.lua`: formatea los comentarios a markdown **agrupado por archivo**
  (`## <path>`), ordenado por archivo+línea, numeración continua, con ancla
  `` `path:lnum` `` (o `path:lnum-end`). Excluye resueltos. Colapsa saltos de
  línea del texto.
- `:ReviewYankFile` / `:Ryf` (archivo actual), `:ReviewYankAll` / `:Rya`
  (todos) → copian al registro `+`.

## agent — puente RPC nativo + reconciliación AUTO

Implementado. **Deshabilitado por defecto** (`features.agent = { enabled = true }`;
expone superficie de escritura remota). Ver el protocolo completo en
`plans/05-agent.md`.

- **Transporte**: RPC nativo de Neovim (`--remote-expr`), sin sockets propios ni
  dependencias. El agente usa el binario `nvim` como cliente contra `v:servername`.
- **Modelo**: el agente escribe **código en disco** con sus propias herramientas
  (FUERA de nvim); solo los **comentarios** pasan por nvim (`_G.ReviewAgent` sobre
  `core.state`, única fuente de verdad).
- **API `_G.ReviewAgent`**: `list(filter?)`, `get(id)`, `context(id)`, `add`,
  `reply(parent_id, text)`, `resolve`/`unresolve`, `update`, `delete`,
  `clean_resolved(path?)`, `is_modified(path)`, `notify_changed(path)`,
  `servername()`. Todo serializable (JSON/primitivos), sin `_extmark_id`.
- **Reconciliación AUTO** (`agent/reconcile.lua`): cuando el agente cambia un
  archivo en disco, un watcher (`agent/watch.lua`, `vim.uv.fs_event` + debounce)
  lo detecta y aplica el cambio al buffer como **patch mínimo por diff**
  (`vim.diff` indices → `nvim_buf_set_lines` de abajo hacia arriba). Los extmarks
  (y por lo tanto los comentarios) **se re-anclan solos por gravity**, sin
  `:edit!`. Emite `buffer:reconciled`; `comments` reacciona re-sincronizando
  posiciones y marcando `stale` los de anclaje incierto (por `anchor_text`).
- **Conflicto**: si el buffer tiene cambios sin guardar, NO se pisa (reporta
  `conflict`); el agente puede consultar `is_modified(path)` antes de editar.
  `:ReviewReload` fuerza el patch del buffer actual como fallback manual.
- **Autoría / threading**: comentarios con `author`, respuestas ligadas con
  `reply_to`. `comments` los distingue visualmente (🤖 / violeta), muestra el hilo
  en el peek y el sufijo `↩N`; la lista filtra por autor y respondido/sin responder.