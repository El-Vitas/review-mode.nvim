# Architecture

## Guiding principle

The "view" is only **how the code is painted**. Everything visual is
**decorations** (extmarks / virtual lines / virtual text / statuscolumn) on top of
the real buffer. New tabs are never opened and the file content is never
modified; the buffer remains the real, editable file, and comment mode
is always available.

## Core + vertical slices

Two layers:

1. **`core/`** — shared, stable kernel. It is the ONLY dependency of the
   features. It has no business logic: only infrastructure (git, store,
   state, ns, events, registry).
2. **`features/<name>/`** — each feature is a **vertical slice**: its logic,
   UI, commands, keymaps and tests live inside its folder. It **depends only on the
   `core` contract**, never on another feature. Features coordinate through events (pub/sub),
   never through a direct `require` between features.

This makes each slice independent and testable on its own → once the
core is built, the features can be implemented in parallel.

```
lua/review/
  init.lua                 -- setup(opts): loads core + registered features
  core/
    init.lua               -- `core` table = { git, store, state, ns, events, registry }
    git.lua                -- root(bufnr), rel_path, head_content, changed_files (+ root cache)
    store.lua              -- root_fn, path(), load(), save()  (the ONLY door to the filesystem)
    state.lua              -- all/for_path/by_id/add/remove/update/load/persist  (+ emits events)
    ns.lua                 -- extmark namespaces: comments, views
    events.lua             -- on(name, cb), emit(name, payload)  (pub/sub)
    registry.lua           -- register(feature), setup(core, opts)
  features/
    comments/              -- CRUD + extmark render + mode (nui popup) + gutter + peek + commands
      init.lua render.lua mode.lua commands.lua gutter.lua
    views/                 -- normal / inline / split views (native diff)
      init.lua inline.lua split.lua diff.lua commands.lua
    sidebar/               -- neo-tree integration (changed/all + comment indicator)
      init.lua
    export/                -- agent-ready markdown + yank commands
      init.lua markdown.lua commands.lua
    agent/                 -- (PENDING) native RPC bridge
plugin/review.lua          -- lowercase aliases (cnoreabbrev), always loaded
tests/                     -- plenary/busted, one subdirectory per slice
docs/                      -- this documentation
```

## Core contract (stable API)

### `core.git`
- `git.root(bufnr?)` → `string|nil`. With `bufnr`, it resolves the root from the
  FILE'S DIRECTORY (`git -C <dir> rev-parse`), so it works even if the cwd
  is somewhere else. **Cached per directory** (see performance.md). Without
  `bufnr` it falls back to `store.root_fn()` (by cwd, and the override point in tests).
- `git.rel_path(bufnr)` → `string|nil` — buffer path relative to the root
  (resolves symlinks so that it matches).
- `git.head_content(relpath, root?)` → `string[]|nil` — lines of the file at
  HEAD (`git show HEAD:relpath`). **Normalizes CRLF** (strips `\r`).
- `git.changed_files()` → `string[]` — relpaths changed vs HEAD ∪ untracked.

### `core.store`
- `store.root_fn` — replaceable function (tests) that returns the root or `nil`.
- `store.path()` → `<root>/.git/review.nvim/comments.json`.
- `store.load()` → `{ version=1, comments={...} }` (never fails).
- `store.save(data)` → `boolean`. It is the ONLY door to the filesystem.

### `core.state` (in-memory source of truth)
- `state.all()`, `state.for_path(relpath)`, `state.by_id(id)`.
- `state.add(c)` → assigns `id/created_at/resolved=false/author`, emits `comments:changed`.
- `state.remove(id)`, `state.update(id, fields)` → emit `comments:changed`.
- `state.load()` / `state.persist()` (persist filters out `_extmark_id`, a runtime field).
- **comment**: `{ id, path, lnum, end_lnum, text, resolved, author, created_at, _extmark_id? }`.

### `core.ns`
- `ns.comments`, `ns.views` — extmark namespaces.

### `core.events` (in-process pub/sub)
- `events.on(name, cb)`, `events.emit(name, payload)` (protected, `vim.schedule`).
- Events: `comments:changed` (`{bufnr?}`), `view:changed` (`{mode}`).

### `core.registry`
- `registry.register({ name, setup })` — a feature registers itself when it is required.
- `registry.setup(core, opts)` — `state.load()` + `feature.setup(core, cfg)` per feature.
  Propagates `cfg.leader` (global or its own) to each feature.

### `review.init`
- `setup(opts)` — `require` of all the features (self-registration) + `registry.setup`.
- `opts = { leader = "<leader>r", features = { comments={enabled=true}, ... } }`.

## Dependency rules

- A feature **never** does `require("review.features.<other>")`. Only `require("review.core")`.
- Coordination between features = **events**. E.g.: `sidebar` and `gutter` listen to
  `comments:changed`; `comments` does not know they exist.
- Each feature registers its commands/keymaps/autocmds inside its `setup(core, opts)`.

## Storage

`<repo>/.git/review.nvim/comments.json` — outside the code, never committed,
per-repo, persistent. All disk I/O goes through `core.store`.