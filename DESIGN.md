# review.nvim — Design (vertical-slice architecture)

**Date:** 2026-07-07
**Location:** `~/Dev/nvim/review.nvim`
**Author:** El-Vitas

## Goal

Bring the code-review workflow of [tuicr](https://github.com/agavra/tuicr) **into Neovim**, without
leaving the editor: you keep writing, with your LSP, treesitter and keymaps, and on top of that you get a
review layer (comments on lines + diff views) and a bidirectional bridge with an AI agent.

**Guiding principle:** the "view" is only *how the code is painted*. Everything visual is a
**decoration (extmarks / virtual lines / virtual text)** over the real buffer — no new tabs,
the buffer stays the real, editable file, and comment mode is available in
any view and at any time.

## Architecture: core + vertical slices

Two layers:

1. **`core/`** — a shared, stable kernel. It is the **only** dependency of the features. It
   contains no review business logic; only infrastructure: persistence, state, git, extmark
   namespaces, events and the feature registry.
2. **`features/<name>/`** — each feature is a **vertical slice**: its own logic, UI, commands,
   keymaps and tests, inside its folder. It **depends only on the `core` contract**, never on another
   feature. Features communicate through events (the core's pub/sub), never through a direct require between features.

This makes each slice **independent and testable on its own** → once the `core` is built, the features
can be implemented **in parallel** (one agent per feature).

### Folder structure

```
lua/review/
  init.lua                 -- setup(opts): starts core + registered features
  core/
    init.lua               -- exposes the `core` table (git, store, state, ns, events, registry)
    git.lua                -- root(), rel_path(bufnr), head_content(relpath), changed_files()
    store.lua              -- root_fn, path(), load(), save(data)  (the only door to the filesystem)
    state.lua              -- all/for_path/by_id/add/remove/update/load/persist  (+ emits events)
    ns.lua                 -- extmark namespaces: comments, views
    events.lua             -- on(name, cb), emit(name, payload)  (in-process pub/sub)
    registry.lua           -- register(feature), setup(opts) iterates features
  features/
    comments/              -- create/edit/delete/resolve comments + extmark render + mode
      init.lua  render.lua  mode.lua  commands.lua
    export/                -- agent-ready markdown + yank commands
      init.lua  markdown.lua  commands.lua
    views/                 -- normal / inline / split views
      init.lua  inline.lua  split.lua  commands.lua
    sidebar/               -- neo-tree integration (changed/all + comment indicator)
      init.lua
    agent/                 -- bidirectional RPC bridge for the agent
      init.lua  rpc.lua
tests/
  minimal_init.lua
  core/    comments/    export/    views/    agent/
docs/
  plans/                   -- one plan per slice (core + 5 features)
```

## `core` contract (stable API — all features depend **only** on this)

### `core.git`
- `git.root()` → `string|nil` — repo root (cached per cwd).
- `git.rel_path(bufnr)` → `string|nil` — buffer path relative to the root.
- `git.head_content(relpath)` → `string[]|nil` — lines of the file at HEAD (for the split view).
- `git.changed_files()` → `string[]` — relpaths changed vs HEAD (for sidebar/views).

### `core.store`
- `store.root_fn` — replaceable function (tests) that returns the root or `nil`.
- `store.path()` → `string|nil` — `<root>/.git/review.nvim/comments.json`.
- `store.load()` → `{ version=1, comments={...} }` (never fails).
- `store.save(data)` → `boolean`.

### `core.state` (source of truth for the in-memory comments)
- `state.all()` → `comment[]`.
- `state.for_path(relpath)` → `comment[]`.
- `state.by_id(id)` → `comment|nil`.
- `state.add(comment)` → `comment` — assigns `id`, `created_at`, `resolved=false`, `author="user"` if missing; **emits `comments:changed`**.
- `state.remove(id)` → `boolean` — **emits `comments:changed`**.
- `state.update(id, fields)` → `boolean` — **emits `comments:changed`**.
- `state.load()` — populates from the store. `state.persist()` — dumps to the store.
- **comment**: `{ id, path, lnum, end_lnum, text, resolved, author, created_at, _extmark_id? }`
  (`_extmark_id` is runtime-only, it is **not** persisted).

### `core.ns`
- `ns.comments` → namespace id of the comment extmarks.
- `ns.views` → namespace id of the view extmarks (inline diff).

### `core.events` (in-process pub/sub — decouples features)
- `events.on(name, cb)` — subscribes.
- `events.emit(name, payload)` — fires (protected with pcall + `vim.schedule`).
- Defined events: `comments:changed` (payload `{ bufnr? }`), `view:changed` (payload `{ bufnr, mode }`).

### `core.registry`
- `registry.register({ name, setup })` — a feature registers itself (typically on `require`).
- `registry.setup(opts)` — `state.load()`, then for each registered feature calls `feature.setup(core, opts.features[name] or {})`.

### `review.init`
- `setup(opts)` — `require`s all the features (they self-register) and calls `core.registry.setup(opts)`.
- `opts = { leader = "<leader>r", features = { comments={enabled=true}, export={...}, ... } }`.

## Dependency rules (for parallelism)

- A feature **never** does `require("review.features.other")`. Only `require("review.core")`.
- Coordination between features = **events** (`core.events`). E.g. `sidebar` listens to `comments:changed`
  to refresh its indicator; `comments` does not know that `sidebar` exists.
- Each feature registers its own commands/keymaps/autocmds inside its `setup(core, opts)`.

## Features (one slice = one plan = potentially one agent)

| Slice | Depends on (core) | Listens to events | Delivers |
|---|---|---|---|
| **core** | — | — | git, store, state, ns, events, registry + `review.init` + test harness |
| **comments** | git.rel_path, state.*, ns.comments, events | — | CRUD, extmark render (anchoring), comment mode (nui popup), commands/keymaps |
| **export** | state.all/for_path, git.rel_path | — | agent-ready markdown, `:ReviewYankFile`/`:Ryf`, `:ReviewYankAll`/`:Rya` |
| **views** | git.head_content/rel_path, ns.views | — | normal/inline/split views, `:ReviewView`/`:Rv` |
| **sidebar** | state.all, neo-tree (changed/all is resolved natively by neo-tree) | `comments:changed` | changed/all toggle + 💬 indicator, `:ReviewSidebar`/`:Rs` |
| **agent** | state.add/remove/update/all/persist | — | RPC functions (nvim `--server`) read/add/resolve/delete + protocol doc |

## Commands and short aliases

| Command | Alias | Feature |
|---|---|---|
| `:ReviewCommentMode` | `:Rcm` / `rcm` | comments |
| `:ReviewView {normal\|inline\|split}` | `:Rv` / `rv` | views |
| `:ReviewYankFile` | `:Ryf` / `ryf` | export |
| `:ReviewYankAll` | `:Rya` / `rya` | export |
| `:ReviewList` | `:Rl` / `rl` | comments |
| `:ReviewSidebar {changed\|all}` | `:Rs` / `rs` | sidebar |

(Native user-commands are capitalized; the lowercase versions are achieved with
`cnoreabbrev` in `plugin/review.lua`.)

## Data model (comment)

```lua
{ id="uuid", path="src/foo.ts", lnum=42, end_lnum=42, text="…",
  resolved=false, author="user", created_at="RFC3339" }
```
Anchoring: at runtime each comment has an `_extmark_id` (not persisted) → it follows the line while
editing. On save, `lnum` is taken from the extmark's current position.

## Storage

`<repo>/.git/review.nvim/comments.json` — outside the code, never committed, per-repo, persistent.
All I/O goes through `core.store`.

## Testing

`plenary`/busted, one subdirectory per slice under `tests/`. Run:
`nvim --headless -c "PlenaryBustedDirectory tests/ {minimal_init='tests/minimal_init.lua'}"`.
The UI (extmarks, popups, split) is verified manually; pure logic (state, git parse, export,
markdown, agent protocol) is tested.

## Build order

1. **core** (blocks everything else).
2. In parallel (depend only on the core): **comments**, **export**, **views**, **agent**.
3. **sidebar** (best done after comments, because it shows its indicator — although it only depends on the
   contract, it is easier to verify with comments working).
