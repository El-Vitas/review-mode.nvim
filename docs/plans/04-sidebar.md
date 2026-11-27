# review.nvim — Plan 04: Sidebar (neo-tree integration)

> **Master plan:** `~/Dev/nvim/review.nvim/DESIGN.md` — this plan implements the **sidebar** slice of
> the features table (depends on `core.git.changed_files`, `core.state.for_path`, neo-tree; listens to
> `comments:changed`). Every signature here **must** match the "`core` contract".
> REQUIRED SUB-SKILL: superpowers:subagent-driven-development

**Goal:** Integrate `nvim-neo-tree/neo-tree.nvim` (v3.x) to toggle between viewing **only** the changed
files (`source = "git_status"`) and **all** files (`source = "filesystem"`), with a command
`:ReviewSidebar {changed|all}` / `:Rs`, a keymap `<leader>rs`, and a pure helper
`files_with_comments()` that computes which files have ≥1 comment so they can be marked
visually in the tree.

**Architecture:** A single slice under `lua/review/features/sidebar/`. `init.lua` holds everything:
`M.setup(core, opts)`, the command/keymap, the subscription to `comments:changed`, and the pure helper
`files_with_comments(core)`. The integration with neo-tree is done exclusively through its public API
(`require("neo-tree.command").execute({...})`), never touching its internals. If neo-tree is not
installed, the feature degrades gracefully (pcall + `vim.notify`, does not break `review.setup`).

**Tech Stack:** Lua, Neovim ≥ 0.10, plenary.nvim (busted tests), `nvim-neo-tree/neo-tree.nvim` v3.x
(optional runtime dependency, **not** in `lua/review/*`).

## Global Constraints

- The feature **never** does `require("review.features.other")`. Only `require("review.core")`.
- Coordination with `comments` (or any other feature) = **only** through `core.events`
  (`comments:changed`). Zero direct coupling.
- `require("neo-tree.command")` / `require("neo-tree.setup...")` are **always** behind a `pcall`. If it
  fails, `vim.notify("review.nvim: neo-tree.nvim is not installed, sidebar disabled", vim.log.levels.WARN)`
  and `M.setup` returns without registering a command, keymap or subscription.
- Do not subscribe twice to `comments:changed` if `M.setup` runs more than once (keep a
  module-local flag `_subscribed`).
- The `comments:changed` event must **not** force the tree open if it is closed — it only refreshes
  if a neo-tree window is already visible.
- Repo without changes → empty `changed_files()` → an empty `git_status` tree is a valid state, not an
  error.
- `files_with_comments()` is **pure**: it receives `core` (or directly uses `core.state.all()`), returns a
  `set` (`{ [relpath] = true }`), with no side effects and no dependency on neo-tree. It is the only
  part of this slice with automated tests.
- Tests: `nvim --headless -c "PlenaryBustedFile tests/sidebar/<spec>.lua" -c "qa"`.

---

### Task 1: `files_with_comments()` — pure helper

**Files:**
- Create: `lua/review/features/sidebar/init.lua`, `tests/sidebar/files_with_comments_spec.lua`

**Interfaces:**
- Consumes: `core.state.all()` (contract already built in `00-core.md` Task 5).
- Produces: `M.files_with_comments(core)` → `table<string, boolean>` (set of relpaths with ≥1
  unresolved or resolved comment — counts any comment that exists on `path`).

- [ ] **Step 1: Failing test — `tests/sidebar/files_with_comments_spec.lua`**

```lua
local store = require("review.core.store")
local state = require("review.core.state")
local sidebar = require("review.features.sidebar")

describe("sidebar.files_with_comments", function()
  local core

  before_each(function()
    local tmp = vim.fn.tempname()
    vim.fn.mkdir(tmp, "p")
    store.root_fn = function() return tmp end
    state._reset()
    core = { state = state }
  end)

  it("empty if there are no comments", function()
    local set = sidebar.files_with_comments(core)
    assert.are.same({}, set)
  end)

  it("includes each relpath with ≥1 comment, without duplicates", function()
    state.add({ path = "a.ts", lnum = 1, text = "x" })
    state.add({ path = "a.ts", lnum = 2, text = "y" })
    state.add({ path = "b/c.ts", lnum = 1, text = "z" })

    local set = sidebar.files_with_comments(core)

    assert.is_true(set["a.ts"])
    assert.is_true(set["b/c.ts"])
    local count = 0
    for _ in pairs(set) do count = count + 1 end
    assert.are.equal(2, count)
  end)

  it("includes resolved comments too", function()
    state.add({ path = "a.ts", lnum = 1, text = "x", resolved = true })
    local set = sidebar.files_with_comments(core)
    assert.is_true(set["a.ts"])
  end)
end)
```

- [ ] **Step 2: Run and watch it fail**

Run: `cd ~/Dev/nvim/review.nvim && nvim --headless -c "PlenaryBustedFile tests/sidebar/files_with_comments_spec.lua" -c "qa"`
Expected: FAIL ("module 'review.features.sidebar' not found").

- [ ] **Step 3: Implement `lua/review/features/sidebar/init.lua` (pure part first)**

```lua
local M = {}

M._subscribed = false

--- Pure helper: set of relpaths with ≥1 comment. It does not touch neo-tree and has no
--- side effects. Reusable by anyone who wants to mark the tree.
--- @param core table  the review.nvim core (uses core.state.all())
--- @return table<string, boolean>
function M.files_with_comments(core)
  local set = {}
  for _, c in ipairs(core.state.all()) do
    if c.path then
      set[c.path] = true
    end
  end
  return set
end

return M
```

- [ ] **Step 4: Run and watch it pass**

Run: `cd ~/Dev/nvim/review.nvim && nvim --headless -c "PlenaryBustedFile tests/sidebar/files_with_comments_spec.lua" -c "qa"`
Expected: PASS (3).

- [ ] **Step 5: Commit**

```bash
cd ~/Dev/nvim/review.nvim && git add -A
git commit -q -m "feat(sidebar): pure files_with_comments helper"
```

---

### Task 2: neo-tree detection + `M.setup` with degradation

**Files:**
- Modify: `lua/review/features/sidebar/init.lua`
- Create: `tests/sidebar/setup_spec.lua`

**Interfaces:**
- Consumes: `core` (full contract table), `opts` (feature config).
- Produces: `M.setup(core, opts)` — registers command/keymap/subscription only if neo-tree is
  available; otherwise `vim.notify` + returns without breaking anything. Idempotent (no double subscription).

- [ ] **Step 1: Failing test — `tests/sidebar/setup_spec.lua`**

```lua
local events = require("review.core.events")
local state = require("review.core.state")
local store = require("review.core.store")
local sidebar = require("review.features.sidebar")

describe("sidebar.setup", function()
  before_each(function()
    local tmp = vim.fn.tempname()
    vim.fn.mkdir(tmp, "p")
    store.root_fn = function() return tmp end
    state._reset()
    events._reset()          -- avoids subscriber leaks between tests (otherwise the count gives a false positive)
    sidebar._subscribed = false
  end)

  it("does not blow up if neo-tree is not installed", function()
    local core = { state = state, events = events, git = { changed_files = function() return {} end } }
    assert.has_no.errors(function()
      sidebar.setup(core, {})
    end)
  end)

  it("does not subscribe twice to comments:changed after two setup() calls", function()
    local core = { state = state, events = events, git = { changed_files = function() return {} end } }
    sidebar.setup(core, {})
    sidebar.setup(core, {})

    local calls = 0
    -- We count how many comments:changed handlers there are by firing an event
    -- and checking that M._refresh is not invoked more than once per emit.
    local orig = sidebar._refresh
    sidebar._refresh = function(...)
      calls = calls + 1
      if orig then orig(...) end
    end

    events.emit("comments:changed", {})
    vim.wait(50)

    sidebar._refresh = orig
    assert.are.equal(1, calls)
  end)
end)
```

- [ ] **Step 2: Run and watch it fail**

Run: `cd ~/Dev/nvim/review.nvim && nvim --headless -c "PlenaryBustedFile tests/sidebar/setup_spec.lua" -c "qa"`
Expected: FAIL (`sidebar.setup` does not exist yet).

- [ ] **Step 3: Implement `M.setup` in `lua/review/features/sidebar/init.lua`**

```lua
local M = {}

M._subscribed = false
M._core = nil

--- Pure helper: set of relpaths with ≥1 comment. It does not touch neo-tree and has no
--- side effects. Reusable by anyone who wants to mark the tree.
--- @param core table  the review.nvim core (uses core.state.all())
--- @return table<string, boolean>
function M.files_with_comments(core)
  local set = {}
  for _, c in ipairs(core.state.all()) do
    if c.path then
      set[c.path] = true
    end
  end
  return set
end

--- True if there is a visible neo-tree window in the current tab.
local function neotree_window_open()
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local buf = vim.api.nvim_win_get_buf(win)
    if vim.bo[buf].filetype == "neo-tree" then
      return true
    end
  end
  return false
end

--- Refreshes the tree indicator/redraw if it is open. It does not force opening.
--- Current phase: recomputes the pure set; the fine-grained visual marking is documented
--- as a secondary phase (see Task 4).
function M._refresh()
  if not M._core then return end
  if not neotree_window_open() then return end
  local ok, command = pcall(require, "neo-tree.command")
  if not ok then return end
  M._files_with_comments_cache = M.files_with_comments(M._core)
  pcall(command.execute, { action = "refresh" })
end

--- Opens/focuses the neo-tree tree on the requested source.
--- @param kind "changed"|"all"
local function open_sidebar(kind)
  local ok, command = pcall(require, "neo-tree.command")
  if not ok then
    vim.notify("review.nvim: neo-tree.nvim is not installed, sidebar disabled", vim.log.levels.WARN)
    return
  end
  -- Recompute the files-with-comments cache on open, so the marker does not go
  -- stale if comments were added/deleted while the tree was closed
  -- (M._refresh skips when the window is not open).
  if M._core then M._files_with_comments_cache = M.files_with_comments(M._core) end
  local source = kind == "all" and "filesystem" or "git_status"
  command.execute({ source = source, action = "show", position = "right" })
end

function M.setup(core, opts)
  opts = opts or {}
  M._core = core

  local ok = pcall(require, "neo-tree.command")
  if not ok then
    vim.notify("review.nvim: neo-tree.nvim is not installed, sidebar disabled", vim.log.levels.WARN)
    return
  end

  vim.api.nvim_create_user_command("ReviewSidebar", function(cmd_opts)
    local kind = cmd_opts.args ~= "" and cmd_opts.args or "changed"
    if kind ~= "changed" and kind ~= "all" then
      vim.notify("review.nvim: :ReviewSidebar expects 'changed' or 'all'", vim.log.levels.ERROR)
      return
    end
    open_sidebar(kind)
  end, {
    nargs = "?",
    complete = function() return { "changed", "all" } end,
  })

  -- Short alias as a real command (the lowercase `rs` is resolved by plugin/review.lua).
  vim.api.nvim_create_user_command("Rs", function(cmd_opts)
    local kind = cmd_opts.args ~= "" and cmd_opts.args or "changed"
    if kind ~= "changed" and kind ~= "all" then
      vim.notify("review.nvim: :Rs expects 'changed' or 'all'", vim.log.levels.ERROR)
      return
    end
    open_sidebar(kind)
  end, { nargs = "?", complete = function() return { "changed", "all" } end })

  local keymap_lhs = (opts.leader or "<leader>r") .. "s"
  vim.keymap.set("n", keymap_lhs, function() open_sidebar("changed") end, { desc = "Review: sidebar (changed)" })

  if not M._subscribed then
    core.events.on("comments:changed", function()
      M._refresh()
    end)
    M._subscribed = true
  end
end

return M
```

- [ ] **Step 4: Run and watch it pass**

Run: `cd ~/Dev/nvim/review.nvim && nvim --headless -c "PlenaryBustedFile tests/sidebar/setup_spec.lua" -c "qa"`
Expected: PASS (2). (Note: in the test environment there is no `neo-tree.nvim` in the `runtimepath` unless
`minimal_init.lua` adds it — that is why the first test precisely checks the degradation path
without blowing up. If your `minimal_init.lua` **does** load neo-tree, the command is registered anyway and the test
still passes.)

- [ ] **Step 5: Commit**

```bash
cd ~/Dev/nvim/review.nvim && git add -A
git commit -q -m "feat(sidebar): setup with command/keymap/subscription and degradation without neo-tree"
```

---

### Task 3: Registration in `review.core.registry` + final command/alias

**Files:**
- Modify: `lua/review/features/sidebar/init.lua` (add self-registration at the end of the file)

**Interfaces:**
- Consumes: `require("review.core").registry.register`.
- Produces: the feature becomes available to `core.registry.setup(core, opts)` under the name
  `"sidebar"`, in line with `comments`, `export`, `views`, `agent`.

- [ ] **Step 1: Add self-registration at the end of `lua/review/features/sidebar/init.lua`**

```lua
require("review.core").registry.register({ name = "sidebar", setup = M.setup })
```

- [ ] **Step 2: Manual verification — end-to-end load**

1. Open a git repo with at least one modified file and another without changes.
2. `nvim -c "lua require('review').setup()"`.
3. Verify there are no errors in `:messages` (if neo-tree is installed; if not, verify that the
   WARN `vim.notify` appears and Neovim remains usable).
4. `:ReviewSidebar changed` → the neo-tree tree opens on the right showing only the files
   with a diff vs HEAD (`git_status` source).
5. `:ReviewSidebar all` (or `:Rs all`) → the same panel switches to showing the full tree (source
   `filesystem`).
6. `<leader>rs` → opens/focuses the tree in `changed` mode (quick shortcut).
7. Repeat `require('review').setup()` a second time in the same session (`:lua require('review').setup()`)
   and confirm that **no** duplicated keymaps/commands appear with an error, and that `:messages` does not show
   a double notification of a broken subscription.

- [ ] **Step 3: Manual verification — repo without changes**

1. In a repo with a clean `git status`, run `:ReviewSidebar changed`.
2. Expected: the tree opens empty (or only with folders without marked files), with no error or traceback.

- [ ] **Step 4: Commit**

```bash
cd ~/Dev/nvim/review.nvim && git add -A
git commit -q -m "feat(sidebar): self-registration in review.core.registry"
```

---

### Task 4: Visual comment indicator (secondary phase, documented)

**Files:**
- Modify: `lua/review/features/sidebar/init.lua` (add an exposed utility function, without forcing
  deep integration with neo-tree's internal components)

**Interfaces:**
- Produces: `M.comment_marker(relpath)` → `string|nil` (the string `"💬"` if `relpath` is in the
  last computed `files_with_comments()`, `nil` otherwise) — a utility that the user can hook
  manually into their own neo-tree config (`default_component_configs` / custom `name` component)
  if they want to see the marker in the tree. Integrating a custom neo-tree component that replaces the
  `name` renderer is invasive (it requires overriding `renderers.file` in the user's global neo-tree
  config, out of scope for this plugin) — that is why it is documented as the minimal route instead of
  forcing it.

- [ ] **Step 1: Implement `M.comment_marker` in `lua/review/features/sidebar/init.lua`**

```lua
--- Text marker for a relpath, meant to be hooked into a custom neo-tree
--- renderer (see docs/plans/04-sidebar.md Task 4). It is based on the
--- last cache computed by M._refresh(); if it never ran, it computes it now.
--- @param relpath string
--- @return string|nil
function M.comment_marker(relpath)
  if not M._core then return nil end
  M._files_with_comments_cache = M._files_with_comments_cache or M.files_with_comments(M._core)
  if M._files_with_comments_cache[relpath] then
    return "💬"
  end
  return nil
end
```

- [ ] **Step 2: Manual verification — minimal integration route**

1. In the user's neo-tree config (e.g. `~/.config/nvim/lua/plugins/neotree.lua`), add a
   custom component that calls `require("review.features.sidebar").comment_marker(node:get_id())` and
   concatenates it to the file name in `renderers.file` — documented here as optional, **not** forced by
   this plugin.
2. Visually confirm that files with comments show `💬` next to the name after adding
   that snippet to the user's config.
3. If the user does not hook the renderer, the tree keeps working normally (Tasks 1–3), just without the
   emoji — an acceptable degraded behavior for this phase.

- [ ] **Step 3: Commit**

```bash
cd ~/Dev/nvim/review.nvim && git add -A
git commit -q -m "feat(sidebar): comment_marker as the minimal route for a visual indicator"
```

---

## Self-Review

- **Contract coverage (DESIGN.md):** `core.git.changed_files` ✅ (used indirectly by
  neo-tree's `git_status` source, which does its own `git status` — we do not need to call it
  directly because neo-tree resolves the changed files natively; documented as a decision).
  `core.state.for_path`/`state.all()` ✅ (Task 1, `files_with_comments`). `comments:changed` event
  ✅ (Task 2, single subscription). `:ReviewSidebar {changed|all}` / `:Rs` ✅ (Task 2/3).
  `<leader>rs` ✅ (Task 2).
- **Placeholders:** none; all the Lua code is complete and executable.
- **Degradation without neo-tree:** `M.setup` first does `pcall(require, "neo-tree.command")` and
  `vim.notify` + `return` if it fails, without registering a command/keymap/subscription — it does not break
  `core.registry.setup` or the rest of the plugin.
- **No double subscription:** module-local flag `M._subscribed`, verified in `setup_spec.lua`.
- **No coupling between features:** the module only does `require("review.core")` (via the `core`
  received in `setup`) and `require("neo-tree.*")`; never `require("review.features.comments")`.
- **Repo without changes / event with the tree closed:** both covered explicitly (the `neotree_window_open()`
  guard in `M._refresh`, Task 3 Step 3 for the clean repo).
- **Automated vs manual tests:** only the pure part (`files_with_comments`, `setup` without invoking
  the real neo-tree UI) has specs under `tests/sidebar/`; every visual interaction with neo-tree
  (panel opening, source toggling, 💬 marker) is left as an explicit manual verification
  with concrete steps (Tasks 3 and 4).
