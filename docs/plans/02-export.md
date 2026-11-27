# review.nvim — Plan 02: Export (agent-ready markdown + yank)

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development. Steps use checkboxes (`- [ ]`).
> **Master plan:** `~/Dev/nvim/review.nvim/DESIGN.md` — this plan implements the `export` slice of the "Features" table. Every signature here **must** match the "`core` contract" (see `docs/plans/00-core.md`).

**Goal:** Build the `export` vertical slice: formatting comments as agent-ready markdown (with `path:lnum` anchors) and yank commands to the `+` register (`:ReviewYankFile`/`:Ryf`, `:ReviewYankAll`/`:Rya`). Depends **only** on `core.state` (and `core.git.rel_path` to resolve the current file in `commands.lua`).

**Architecture:** Lua modules under `lua/review/features/export/`. `markdown.lua` is pure logic (no I/O, no `vim.fn.setreg`) — testable with plenary without register mocks. `commands.lua` is the edge with Neovim: it registers `:ReviewYankFile`/`:ReviewYankAll`, resolves the current buffer via `core.git.rel_path(0)`, calls `markdown.lua` and copies with `vim.fn.setreg("+", ...)`. `init.lua` is the feature's entry point: `M.setup(core, opts)` registers commands/keymaps, and at the end of the file it self-registers in `core.registry`.

**Tech Stack:** Lua, Neovim ≥ 0.10, plenary.nvim (busted tests).

## Global Constraints

- The feature **never** does `require("review.features.other")`. Only `require("review.core")`.
- `markdown.lua` is pure logic: it receives lists of `comment` already resolved by the caller (`state.for_path`/`state.all`), and does not call `core.state` directly except in `file()`/`all()` (thin helpers that delegate to `core.state.for_path`/`core.state.all`).
- **Resolved** comments (`resolved == true`) are always excluded from the markdown.
- Anchor: `` `path:lnum` `` if `lnum == end_lnum`, `` `path:lnum-end_lnum` `` if `end_lnum > lnum`.
- Empty list (or everything resolved) → `markdown()` returns `""` (empty string, no stray header).
- `commands.lua` never raises an error if `core.git.rel_path(0)` returns `nil` (buffer without a file or outside the repo): it notifies with `vim.notify` and does not run the yank.
- Capitalized commands (`:ReviewYankFile`, `:ReviewYankAll`); the short aliases (`:Ryf`, `:Rya`) are declared as additional `vim.api.nvim_create_user_command` calls (they do not depend on `cnoreabbrev`, which is the responsibility of `plugin/review.lua` for the lowercase versions `ryf`/`rya` — out of scope for this plan).
- Keymaps `<leader>rf` (yank file) and `<leader>ra` (yank all), with a prefix configurable via `opts.leader` (default `M.config.leader` from plan 00, typically `<leader>r`).
- Tests: `nvim --headless -c "PlenaryBustedFile tests/export/<spec>.lua" -c "qa"`. Busted pattern identical to `00-core.md`: `store.root_fn` override + `state._reset()` + `state.add(...)`.

---

### Task 1: `features/export/markdown.lua` — pure markdown formatting

**Files:**
- Create: `lua/review/features/export/markdown.lua`, `tests/export/markdown_spec.lua`

**Interfaces:**
- Consumes: `core.state.for_path(relpath)`, `core.state.all()` (Task 5 of `00-core.md`).
- Produces:
  - `markdown.markdown(list)` → `string` — receives a `comment[]`, filters out resolved ones, returns numbered markdown with an anchor. `""` if nothing is left.
  - `markdown.file(core, relpath)` → `string` — `markdown.markdown(core.state.for_path(relpath))`.
  - `markdown.all(core)` → `string` — `markdown.markdown(core.state.all())`.

- [ ] **Step 1: Failing test — `tests/export/markdown_spec.lua`**

```lua
local md = require("review.features.export.markdown")

describe("features.export.markdown", function()
  describe("markdown(list)", function()
    it("empty list returns an empty string", function()
      assert.are.equal("", md.markdown({}))
    end)

    it("single line: path:lnum anchor without a range", function()
      local list = {
        { id = "1", path = "src/a.ts", lnum = 10, end_lnum = 10, text = "watch out for this", resolved = false },
      }
      local out = md.markdown(list)
      assert.is_truthy(out:match("^1%. "))
      assert.is_truthy(out:match("`src/a%.ts:10`"))
      assert.is_falsy(out:match("`src/a%.ts:10-10`"))
      assert.is_truthy(out:match("watch out for this"))
    end)

    it("range: path:lnum-end_lnum anchor when end_lnum > lnum", function()
      local list = {
        { id = "1", path = "src/b.ts", lnum = 5, end_lnum = 8, text = "review block", resolved = false },
      }
      local out = md.markdown(list)
      assert.is_truthy(out:match("`src/b%.ts:5-8`"))
    end)

    it("excludes resolved comments", function()
      local list = {
        { id = "1", path = "a.ts", lnum = 1, end_lnum = 1, text = "visible", resolved = false },
        { id = "2", path = "a.ts", lnum = 2, end_lnum = 2, text = "resolved", resolved = true },
      }
      local out = md.markdown(list)
      assert.is_truthy(out:match("visible"))
      assert.is_falsy(out:match("resolved"))
    end)

    it("everything resolved returns an empty string (no stray header)", function()
      local list = {
        { id = "1", path = "a.ts", lnum = 1, end_lnum = 1, text = "resolved", resolved = true },
      }
      assert.are.equal("", md.markdown(list))
    end)

    it("numbers several unresolved comments correctly", function()
      local list = {
        { id = "1", path = "a.ts", lnum = 1, end_lnum = 1, text = "one", resolved = false },
        { id = "2", path = "a.ts", lnum = 2, end_lnum = 2, text = "two", resolved = true },
        { id = "3", path = "a.ts", lnum = 3, end_lnum = 3, text = "three", resolved = false },
      }
      local out = md.markdown(list)
      assert.is_truthy(out:match("1%. .*one"))
      assert.is_truthy(out:match("2%. .*three"))
      assert.is_falsy(out:match("3%. "))
    end)

    it("collapses line breaks in the text (does not break the numbering)", function()
      local list = {
        { id = "1", path = "a.ts", lnum = 1, end_lnum = 1, text = "line1\nline2", resolved = false },
        { id = "2", path = "a.ts", lnum = 2, end_lnum = 2, text = "another", resolved = false },
      }
      local out = md.markdown(list)
      local n = select(2, out:gsub("\n", "\n")) + 1  -- number of lines
      assert.are.equal(2, n)                          -- exactly 2 numbered lines
      assert.is_truthy(out:match("1%. .*line1 line2"))
    end)
  end)

  describe("file/all", function()
    local store, state
    before_each(function()
      store = require("review.core.store")
      state = require("review.core.state")
      local tmp = vim.fn.tempname(); vim.fn.mkdir(tmp, "p")
      store.root_fn = function() return tmp end
      state._reset()
    end)

    it("file(core, relpath) delegates to state.for_path", function()
      local core = { state = state }
      state.add({ path = "a.ts", lnum = 1, text = "only a" })
      state.add({ path = "b.ts", lnum = 1, text = "only b" })
      local out = md.file(core, "a.ts")
      assert.is_truthy(out:match("only a"))
      assert.is_falsy(out:match("only b"))
    end)

    it("all(core) delegates to state.all", function()
      local core = { state = state }
      state.add({ path = "a.ts", lnum = 1, text = "only a" })
      state.add({ path = "b.ts", lnum = 1, text = "only b" })
      local out = md.all(core)
      assert.is_truthy(out:match("only a"))
      assert.is_truthy(out:match("only b"))
    end)

    it("all(core) without comments returns an empty string", function()
      local core = { state = state }
      assert.are.equal("", md.all(core))
    end)
  end)
end)
```

- [ ] **Step 2: Run and watch it fail**

Run: `cd ~/Dev/nvim/review.nvim && nvim --headless -c "PlenaryBustedFile tests/export/markdown_spec.lua" -c "qa"`
Expected: FAIL ("module 'review.features.export.markdown' not found").

- [ ] **Step 3: Implement `lua/review/features/export/markdown.lua`**

```lua
local M = {}

local function anchor(c)
  if c.end_lnum and c.end_lnum > c.lnum then
    return string.format("`%s:%d-%d`", c.path, c.lnum, c.end_lnum)
  end
  return string.format("`%s:%d`", c.path, c.lnum)
end

-- Collapses line breaks in the comment text into a space: each comment
-- must take exactly one numbered line, or `table.concat("\n")` would break the
-- numbering of the agent-ready markdown.
local function oneline(text)
  return ((text or ""):gsub("[\r\n]+", " "))
end

--- Formats a list of comments as agent-ready numbered markdown.
--- Excludes resolved comments. Returns "" if none are left.
--- @param list table[] list of comment (id, path, lnum, end_lnum, text, resolved, ...)
--- @return string
function M.markdown(list)
  list = list or {}
  local lines = {}
  local n = 0
  for _, c in ipairs(list) do
    if not c.resolved then
      n = n + 1
      table.insert(lines, string.format("%d. %s %s", n, anchor(c), oneline(c.text)))
    end
  end
  if n == 0 then return "" end
  return table.concat(lines, "\n")
end

--- Markdown of the comments of a single file.
--- @param core table core table (uses core.state.for_path)
--- @param relpath string path relative to the git root
--- @return string
function M.file(core, relpath)
  return M.markdown(core.state.for_path(relpath))
end

--- Markdown of all the comments in the repo.
--- @param core table core table (uses core.state.all)
--- @return string
function M.all(core)
  return M.markdown(core.state.all())
end

return M
```

- [ ] **Step 4: Run and watch it pass**

Run: `cd ~/Dev/nvim/review.nvim && nvim --headless -c "PlenaryBustedFile tests/export/markdown_spec.lua" -c "qa"`
Expected: PASS (10).

- [ ] **Step 5: Commit**

```bash
cd ~/Dev/nvim/review.nvim && git add -A
git commit -q -m "feat(export/markdown): agent-ready formatting with path:lnum anchors"
```

---

### Task 2: `features/export/commands.lua` — yank commands

**Files:**
- Create: `lua/review/features/export/commands.lua`, `tests/export/commands_spec.lua`

**Interfaces:**
- Consumes: `core.git.rel_path(bufnr)`, `core.state.*` (via `markdown.lua`, Task 1).
- Produces: `commands.setup(core, opts)` — registers `:ReviewYankFile`/`:Ryf`, `:ReviewYankAll`/`:Rya` and the keymaps `<leader>rf`/`<leader>ra` (prefix `opts.leader or "<leader>r"`).

- [ ] **Step 1: Failing test — `tests/export/commands_spec.lua`**

```lua
local store = require("review.core.store")
local state = require("review.core.state")
local git = require("review.core.git")
local commands = require("review.features.export.commands")

describe("features.export.commands", function()
  local core, tmp

  before_each(function()
    tmp = vim.fn.tempname(); vim.fn.mkdir(tmp, "p")
    store.root_fn = function() return tmp end
    state._reset()
    core = { state = state, git = git }
    vim.fn.setreg("+", "")
    pcall(vim.api.nvim_del_user_command, "ReviewYankFile")
    pcall(vim.api.nvim_del_user_command, "ReviewYankAll")
    pcall(vim.api.nvim_del_user_command, "Ryf")
    pcall(vim.api.nvim_del_user_command, "Rya")
  end)

  it("registers commands and aliases", function()
    commands.setup(core, {})
    local cmds = vim.api.nvim_get_commands({})
    assert.is_truthy(cmds["ReviewYankFile"])
    assert.is_truthy(cmds["ReviewYankAll"])
    assert.is_truthy(cmds["Ryf"])
    assert.is_truthy(cmds["Rya"])
  end)

  it(":ReviewYankFile copies only the comments of the current file to the + register", function()
    commands.setup(core, {})
    state.add({ path = "a.ts", lnum = 1, text = "from a" })
    state.add({ path = "b.ts", lnum = 1, text = "from b" })

    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(buf, tmp .. "/a.ts")
    vim.api.nvim_set_current_buf(buf)

    vim.cmd("ReviewYankFile")
    local reg = vim.fn.getreg("+")
    assert.is_truthy(reg:match("from a"))
    assert.is_falsy(reg:match("from b"))
  end)

  it(":ReviewYankAll copies all the comments to the + register", function()
    commands.setup(core, {})
    state.add({ path = "a.ts", lnum = 1, text = "from a" })
    state.add({ path = "b.ts", lnum = 1, text = "from b" })

    vim.cmd("ReviewYankAll")
    local reg = vim.fn.getreg("+")
    assert.is_truthy(reg:match("from a"))
    assert.is_truthy(reg:match("from b"))
  end)

  it(":ReviewYankFile with a buffer outside the repo does not break and does not touch the register", function()
    commands.setup(core, {})
    state.add({ path = "a.ts", lnum = 1, text = "from a" })

    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(buf, "/other/place/x.ts")
    vim.api.nvim_set_current_buf(buf)

    vim.fn.setreg("+", "untouched")
    assert.has_no.errors(function() vim.cmd("ReviewYankFile") end)
    assert.are.equal("untouched", vim.fn.getreg("+"))
  end)

  it(":ReviewYankAll with an empty list notifies and does not break", function()
    commands.setup(core, {})
    vim.fn.setreg("+", "untouched")
    assert.has_no.errors(function() vim.cmd("ReviewYankAll") end)
    assert.are.equal("untouched", vim.fn.getreg("+"))
  end)

  it("respects opts.leader in the keymaps", function()
    commands.setup(core, { leader = "<leader>z" })
    local found = {}
    for _, m in ipairs(vim.api.nvim_get_keymap("n")) do
      if m.lhs == "<leader>zf" then found.f = true end
      if m.lhs == "<leader>za" then found.a = true end
    end
    assert.is_true(found.f)
    assert.is_true(found.a)
  end)
end)
```

- [ ] **Step 2: Run and watch it fail**

Run: `cd ~/Dev/nvim/review.nvim && nvim --headless -c "PlenaryBustedFile tests/export/commands_spec.lua" -c "qa"`
Expected: FAIL ("module 'review.features.export.commands' not found").

- [ ] **Step 3: Implement `lua/review/features/export/commands.lua`**

```lua
local markdown = require("review.features.export.markdown")

local M = {}

local function yank(text)
  if not text or text == "" then
    vim.notify("review.nvim: no comments", vim.log.levels.INFO)
    return
  end
  vim.fn.setreg("+", text)
  vim.notify("review.nvim: comments copied to the + register", vim.log.levels.INFO)
end

local function yank_file(core)
  local relpath = core.git.rel_path(0)
  if not relpath then
    vim.notify("review.nvim: the current buffer does not belong to the repo", vim.log.levels.WARN)
    return
  end
  yank(markdown.file(core, relpath))
end

local function yank_all(core)
  yank(markdown.all(core))
end

function M.setup(core, opts)
  opts = opts or {}
  local leader = opts.leader or "<leader>r"

  vim.api.nvim_create_user_command("ReviewYankFile", function() yank_file(core) end, {})
  vim.api.nvim_create_user_command("ReviewYankAll", function() yank_all(core) end, {})
  vim.api.nvim_create_user_command("Ryf", function() yank_file(core) end, {})
  vim.api.nvim_create_user_command("Rya", function() yank_all(core) end, {})

  vim.keymap.set("n", leader .. "f", function() yank_file(core) end, { desc = "Review: yank comments of current file" })
  vim.keymap.set("n", leader .. "a", function() yank_all(core) end, { desc = "Review: yank all comments" })
end

return M
```

- [ ] **Step 4: Run and watch it pass**

Run: `cd ~/Dev/nvim/review.nvim && nvim --headless -c "PlenaryBustedFile tests/export/commands_spec.lua" -c "qa"`
Expected: PASS (6).

- [ ] **Step 5: Commit**

```bash
cd ~/Dev/nvim/review.nvim && git add -A
git commit -q -m "feat(export/commands): ReviewYankFile/ReviewYankAll + keymaps"
```

---

### Task 3: `features/export/init.lua` — entry point + self-registration

**Files:**
- Create: `lua/review/features/export/init.lua`, `tests/export/init_spec.lua`

**Interfaces:**
- Consumes: `commands` (Task 2), `core.registry.register` (`00-core.md` Task 1).
- Produces: `M.setup(core, opts)` (delegates to `commands.setup`); on `require`, the feature self-registers in `core.registry` as `{ name = "export", setup = M.setup }`.

- [ ] **Step 1: Failing test — `tests/export/init_spec.lua`**

```lua
describe("features.export.init", function()
  it("self-registers in core.registry when required", function()
    local core = require("review.core")
    require("review.features.export")
    local features = core.registry.features()
    assert.is_truthy(features["export"])
    assert.is_function(features["export"].setup)
  end)

  it("M.setup delegates to commands.setup and does not break without opts", function()
    local export = require("review.features.export")
    local store = require("review.core.store")
    local tmp = vim.fn.tempname(); vim.fn.mkdir(tmp, "p")
    store.root_fn = function() return tmp end
    local core = require("review.core")
    pcall(vim.api.nvim_del_user_command, "ReviewYankFile")
    pcall(vim.api.nvim_del_user_command, "ReviewYankAll")
    assert.has_no.errors(function() export.setup(core, {}) end)
    local cmds = vim.api.nvim_get_commands({})
    assert.is_truthy(cmds["ReviewYankFile"])
  end)
end)
```

- [ ] **Step 2: Run and watch it fail**

Run: `cd ~/Dev/nvim/review.nvim && nvim --headless -c "PlenaryBustedFile tests/export/init_spec.lua" -c "qa"`
Expected: FAIL ("module 'review.features.export' not found").

- [ ] **Step 3: Implement `lua/review/features/export/init.lua`**

```lua
local commands = require("review.features.export.commands")

local M = {}

--- Entry point of the export feature. Registers commands and keymaps.
--- @param core table core table (git, store, state, ns, events, registry)
--- @param opts table feature options (leader, etc.)
function M.setup(core, opts)
  commands.setup(core, opts or {})
end

require("review.core").registry.register({ name = "export", setup = M.setup })

return M
```

- [ ] **Step 4: Run and watch it pass**

Run: `cd ~/Dev/nvim/review.nvim && nvim --headless -c "PlenaryBustedFile tests/export/init_spec.lua" -c "qa"`
Expected: PASS (2).

- [ ] **Step 5: Full export suite**

Run: `cd ~/Dev/nvim/review.nvim && nvim --headless -c "PlenaryBustedDirectory tests/export/ {minimal_init='tests/minimal_init.lua'}" -c "qa"`
Expected: PASS (markdown 10, commands 6, init 2).

- [ ] **Step 6: Commit**

```bash
cd ~/Dev/nvim/review.nvim && git add -A
git commit -q -m "feat(export): init.lua entrypoint + self-registration in core.registry"
```

---

## Self-Review

- **Contract coverage (DESIGN.md Features table → export):** agent-ready `markdown` ✅ (T1), `:ReviewYankFile`/`:Ryf` ✅ (T2), `:ReviewYankAll`/`:Rya` ✅ (T2). Declared dependency `state.*` ✅ (T1 via `for_path`/`all`), plus `git.rel_path` used only inside `commands.lua` to resolve the current file — this does not violate "depends only on the core contract", since `git` is also part of the core contract.
- **No-cross-dependency rule:** no `require("review.features.<other>")` in the whole slice; only `require("review.core")` and internal `export` submodules.
- **Edge cases covered:** empty list → `""` without a stray header (T1, tests "empty list" and "everything resolved"); resolved ones excluded (T1); range with `end_lnum == lnum` is shown without the `-end_lnum` suffix (T1, test "single line"); real range `end_lnum > lnum` (T1, test "range"); buffer outside the repo (`rel_path` nil) → `vim.notify` + no-op, without touching the register (T2, test "buffer outside the repo"); empty list in commands → notifies "no comments" and does not break (T2, test "empty list notifies").
- **Placeholders:** none; all the Lua code is complete and is meant to be run as is.
- **Signature consistency:** `markdown.markdown(list)`, `markdown.file(core, relpath)`, `markdown.all(core)` (they use `core.state.for_path`/`core.state.all` exactly as in the contract); `commands.setup(core, opts)`; `M.setup(core, opts)` in `init.lua` with self-registration `core.registry.register({ name = "export", setup = M.setup })`, same as the pattern in `00-core.md`.
- **Storage:** this feature does not touch `core.store` directly (correct: export is only a read of `state` + formatting + a Neovim register, with no disk I/O of its own).
