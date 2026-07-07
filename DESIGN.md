# review.nvim — Diseño (arquitectura vertical-slice)

**Fecha:** 2026-07-07
**Ubicación:** `~/Dev/nvim/review.nvim`
**Autor:** El-Vitas

## Objetivo

Traer el flujo de code-review de [tuicr](https://github.com/agavra/tuicr) **dentro de Neovim**, sin
salir del editor: seguís escribiendo, con tu LSP, treesitter y keymaps, y encima tenés una capa de
review (comentarios sobre líneas + vistas de diff) y un puente bidireccional con un agente de IA.

**Principio rector:** la "vista" es solo *cómo se pinta el código*. Todo lo visual son
**decoraciones (extmarks / virtual lines / virtual text)** sobre el buffer real — nada de tabs
nuevas, el buffer sigue siendo el archivo real y editable, y el modo comentario está disponible en
cualquier vista y en cualquier momento.

## Arquitectura: core + vertical slices

Dos capas:

1. **`core/`** — un kernel compartido y estable. Es la ÚNICA dependencia de las features. No
   contiene lógica de negocio de review; solo infraestructura: persistencia, estado, git, extmark
   namespaces, eventos y el registro de features.
2. **`features/<nombre>/`** — cada feature es un **vertical slice**: su propia lógica, UI, comandos,
   keymaps y tests, dentro de su carpeta. **Depende solo del contrato de `core`**, nunca de otra
   feature. Se comunican por eventos (pub/sub del core), nunca por require directo entre features.

Esto hace cada slice **independiente y testeable solo** → una vez construido el `core`, las features
se pueden implementar **en paralelo** (un agente por feature).

### Estructura de carpetas

```
lua/review/
  init.lua                 -- setup(opts): arranca core + features registradas
  core/
    init.lua               -- expone la tabla `core` (git, store, state, ns, events, registry)
    git.lua                -- root(), rel_path(bufnr), head_content(relpath), changed_files()
    store.lua              -- root_fn, path(), load(), save(data)  (ÚNICA puerta al filesystem)
    state.lua              -- all/for_path/by_id/add/remove/update/load/persist  (+ emite eventos)
    ns.lua                 -- namespaces de extmarks: comments, views
    events.lua             -- on(name, cb), emit(name, payload)  (pub/sub in-process)
    registry.lua           -- register(feature), setup(opts) itera features
  features/
    comments/              -- crear/editar/borrar/resolver comentarios + render extmark + modo
      init.lua  render.lua  mode.lua  commands.lua
    export/                -- markdown agent-ready + comandos yank
      init.lua  markdown.lua  commands.lua
    views/                 -- vistas normal / inline / split
      init.lua  inline.lua  split.lua  commands.lua
    sidebar/               -- integración neo-tree (cambiados/todos + indicador de comentarios)
      init.lua
    agent/                 -- puente RPC bidireccional para el agente
      init.lua  rpc.lua
tests/
  minimal_init.lua
  core/    comments/    export/    views/    agent/
docs/
  plans/                   -- un plan por slice (core + 5 features)
```

## Contrato del `core` (API estable — todas las features dependen SOLO de esto)

### `core.git`
- `git.root()` → `string|nil` — raíz del repo (cacheada por cwd).
- `git.rel_path(bufnr)` → `string|nil` — path del buffer relativo a la raíz.
- `git.head_content(relpath)` → `string[]|nil` — líneas del archivo en HEAD (para vista split).
- `git.changed_files()` → `string[]` — relpaths cambiados vs HEAD (para sidebar/views).

### `core.store`
- `store.root_fn` — función reemplazable (tests) que devuelve la raíz o `nil`.
- `store.path()` → `string|nil` — `<root>/.git/review.nvim/comments.json`.
- `store.load()` → `{ version=1, comments={...} }` (nunca falla).
- `store.save(data)` → `boolean`.

### `core.state` (fuente de verdad de los comentarios en memoria)
- `state.all()` → `comment[]`.
- `state.for_path(relpath)` → `comment[]`.
- `state.by_id(id)` → `comment|nil`.
- `state.add(comment)` → `comment` — asigna `id`, `created_at`, `resolved=false`, `author="user"` si faltan; **emite `comments:changed`**.
- `state.remove(id)` → `boolean` — **emite `comments:changed`**.
- `state.update(id, fields)` → `boolean` — **emite `comments:changed`**.
- `state.load()` — puebla desde store. `state.persist()` — vuelca a store.
- **comment**: `{ id, path, lnum, end_lnum, text, resolved, author, created_at, _extmark_id? }`
  (`_extmark_id` es runtime, NO se persiste).

### `core.ns`
- `ns.comments` → namespace id de extmarks de comentarios.
- `ns.views` → namespace id de extmarks de vistas (inline diff).

### `core.events` (pub/sub in-process — desacopla features)
- `events.on(name, cb)` — suscribe.
- `events.emit(name, payload)` — dispara (protegido con pcall + `vim.schedule`).
- Eventos definidos: `comments:changed` (payload `{ bufnr? }`), `view:changed` (payload `{ bufnr, mode }`).

### `core.registry`
- `registry.register({ name, setup })` — una feature se registra (típicamente al hacer `require`).
- `registry.setup(opts)` — `state.load()`, luego por cada feature registrada llama `feature.setup(core, opts.features[name] or {})`.

### `review.init`
- `setup(opts)` — `require` de todas las features (se auto-registran) y `core.registry.setup(opts)`.
- `opts = { leader = "<leader>r", features = { comments={enabled=true}, export={...}, ... } }`.

## Reglas de dependencia (para el paralelismo)

- Una feature **NUNCA** hace `require("review.features.otra")`. Solo `require("review.core")`.
- Coordinación entre features = **eventos** (`core.events`). Ej: `sidebar` escucha `comments:changed`
  para refrescar su indicador; `comments` no sabe que `sidebar` existe.
- Cada feature registra sus propios comandos/keymaps/autocmds dentro de su `setup(core, opts)`.

## Features (un slice = un plan = potencialmente un agente)

| Slice | Depende de (core) | Escucha eventos | Entrega |
|---|---|---|---|
| **core** | — | — | git, store, state, ns, events, registry + `review.init` + harness de tests |
| **comments** | git.rel_path, state.*, ns.comments, events | — | CRUD, render extmark (anclaje), modo comentario (popup nui), comandos/keymaps |
| **export** | state.all/for_path, git.rel_path | — | markdown agent-ready, `:ReviewYankFile`/`:Ryf`, `:ReviewYankAll`/`:Rya` |
| **views** | git.head_content/rel_path, ns.views | — | vistas normal/inline/split, `:ReviewView`/`:Rv` |
| **sidebar** | state.all, neo-tree (changed/all lo resuelve neo-tree nativamente) | `comments:changed` | toggle cambiados/todos + indicador 💬, `:ReviewSidebar`/`:Rs` |
| **agent** | state.add/remove/update/all/persist | — | funciones RPC (nvim `--server`) read/add/resolve/delete + doc del protocolo |

## Comandos y alias cortos

| Comando | Alias | Feature |
|---|---|---|
| `:ReviewCommentMode` | `:Rcm` / `rcm` | comments |
| `:ReviewView {normal\|inline\|split}` | `:Rv` / `rv` | views |
| `:ReviewYankFile` | `:Ryf` / `ryf` | export |
| `:ReviewYankAll` | `:Rya` / `rya` | export |
| `:ReviewList` | `:Rl` / `rl` | comments |
| `:ReviewSidebar {changed\|all}` | `:Rs` / `rs` | sidebar |

(Los user-commands nativos van capitalizados; las versiones en minúscula se logran con
`cnoreabbrev` en `plugin/review.lua`.)

## Modelo de datos (comentario)

```lua
{ id="uuid", path="src/foo.ts", lnum=42, end_lnum=42, text="…",
  resolved=false, author="user", created_at="RFC3339" }
```
Anclaje: en runtime cada comentario tiene un `_extmark_id` (no persistido) → sigue la línea al
editar. Al guardar, `lnum` se toma de la posición actual del extmark.

## Storage

`<repo>/.git/review.nvim/comments.json` — fuera del código, nunca commiteado, por-repo, persistente.
Todo el I/O pasa por `core.store`.

## Testing

`plenary`/busted, un subdirectorio por slice bajo `tests/`. Correr:
`nvim --headless -c "PlenaryBustedDirectory tests/ {minimal_init='tests/minimal_init.lua'}"`.
La UI (extmarks, popups, split) se verifica manual; la lógica pura (state, git parse, export,
markdown, protocolo agent) se testea.

## Orden de construcción

1. **core** (bloquea a todos).
2. En paralelo (dependen solo del core): **comments**, **export**, **views**, **agent**.
3. **sidebar** (conviene después de comments, porque muestra su indicador — aunque solo depende del
   contrato, es más fácil verificarlo con comments andando).
