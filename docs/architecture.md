# Arquitectura

## Principio rector

La "vista" es solo **cómo se pinta el código**. Todo lo visual son
**decoraciones** (extmarks / virtual lines / virtual text / statuscolumn) sobre
el buffer real. Nunca se abren tabs nuevas ni se modifica el contenido del
archivo; el buffer sigue siendo el archivo real y editable, y el modo comentario
está disponible siempre.

## Core + vertical slices

Dos capas:

1. **`core/`** — kernel compartido y estable. Es la ÚNICA dependencia de las
   features. No tiene lógica de negocio: solo infraestructura (git, store,
   state, ns, events, registry).
2. **`features/<nombre>/`** — cada feature es un **vertical slice**: su lógica,
   UI, comandos, keymaps y tests dentro de su carpeta. **Depende solo del
   contrato de `core`**, nunca de otra feature. Coordinan por eventos (pub/sub),
   nunca por `require` directo entre features.

Esto hace cada slice independiente y testeable solo → una vez construido el
core, las features se pueden implementar en paralelo.

```
lua/review/
  init.lua                 -- setup(opts): carga core + features registradas
  core/
    init.lua               -- tabla `core` = { git, store, state, ns, events, registry }
    git.lua                -- root(bufnr), rel_path, head_content, changed_files (+ cache de raíz)
    store.lua              -- root_fn, path(), load(), save()  (ÚNICA puerta al filesystem)
    state.lua              -- all/for_path/by_id/add/remove/update/load/persist  (+ emite eventos)
    ns.lua                 -- namespaces de extmarks: comments, views
    events.lua             -- on(name, cb), emit(name, payload)  (pub/sub)
    registry.lua           -- register(feature), setup(core, opts)
  features/
    comments/              -- CRUD + render extmark + modo (popup nui) + gutter + peek + comandos
      init.lua render.lua mode.lua commands.lua gutter.lua
    views/                 -- vistas normal / inline / split (diff nativo)
      init.lua inline.lua split.lua diff.lua commands.lua
    sidebar/               -- integración neo-tree (changed/all + indicador de comentarios)
      init.lua
    export/                -- markdown agent-ready + comandos yank
      init.lua markdown.lua commands.lua
    agent/                 -- (PENDIENTE) puente RPC nativo
plugin/review.lua          -- alias en minúscula (cnoreabbrev), se carga siempre
tests/                     -- plenary/busted, un subdirectorio por slice
docs/                      -- esta documentación
```

## Contrato del core (API estable)

### `core.git`
- `git.root(bufnr?)` → `string|nil`. Con `bufnr`, resuelve la raíz desde el
  DIRECTORIO DEL ARCHIVO (`git -C <dir> rev-parse`), así funciona aunque el cwd
  esté en otro lado. **Cacheada por directorio** (ver performance.md). Sin
  `bufnr` cae en `store.root_fn()` (por cwd, y punto de override en tests).
- `git.rel_path(bufnr)` → `string|nil` — path del buffer relativo a la raíz
  (resuelve symlinks para que matchee).
- `git.head_content(relpath, root?)` → `string[]|nil` — líneas del archivo en
  HEAD (`git show HEAD:relpath`). **Normaliza CRLF** (quita `\r`).
- `git.changed_files()` → `string[]` — relpaths cambiados vs HEAD ∪ untracked.

### `core.store`
- `store.root_fn` — función reemplazable (tests) que devuelve la raíz o `nil`.
- `store.path()` → `<root>/.git/review.nvim/comments.json`.
- `store.load()` → `{ version=1, comments={...} }` (nunca falla).
- `store.save(data)` → `boolean`. Es la ÚNICA puerta al filesystem.

### `core.state` (fuente de verdad en memoria)
- `state.all()`, `state.for_path(relpath)`, `state.by_id(id)`.
- `state.add(c)` → asigna `id/created_at/resolved=false/author`, emite `comments:changed`.
- `state.remove(id)`, `state.update(id, fields)` → emiten `comments:changed`.
- `state.load()` / `state.persist()` (persist filtra `_extmark_id`, campo runtime).
- **comment**: `{ id, path, lnum, end_lnum, text, resolved, author, created_at, _extmark_id? }`.

### `core.ns`
- `ns.comments`, `ns.views` — namespaces de extmarks.

### `core.events` (pub/sub in-process)
- `events.on(name, cb)`, `events.emit(name, payload)` (protegido, `vim.schedule`).
- Eventos: `comments:changed` (`{bufnr?}`), `view:changed` (`{mode}`).

### `core.registry`
- `registry.register({ name, setup })` — una feature se registra al requerirse.
- `registry.setup(core, opts)` — `state.load()` + `feature.setup(core, cfg)` por feature.
  Propaga `cfg.leader` (global o propio) a cada feature.

### `review.init`
- `setup(opts)` — `require` de todas las features (auto-registro) + `registry.setup`.
- `opts = { leader = "<leader>r", features = { comments={enabled=true}, ... } }`.

## Reglas de dependencia

- Una feature **NUNCA** hace `require("review.features.<otra>")`. Solo `require("review.core")`.
- Coordinación entre features = **eventos**. Ej: `sidebar` y `gutter` escuchan
  `comments:changed`; `comments` no sabe que existen.
- Cada feature registra sus comandos/keymaps/autocmds dentro de su `setup(core, opts)`.

## Storage

`<repo>/.git/review.nvim/comments.json` — fuera del código, nunca commiteado,
por-repo, persistente. Todo el I/O de disco pasa por `core.store`.