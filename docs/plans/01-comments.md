# review.nvim — Plan 01: Comments (vertical slice)

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development. Steps use checkboxes (`- [ ]`).
> **Master plan:** `~/Dev/nvim/review.nvim/DESIGN.md` — this plan implements the `comments` slice of the "Features" table. Every core signature cited here (`core.git`, `core.store`, `core.state`, `core.ns`, `core.events`, `core.registry`) **must** match `docs/plans/00-core.md`.

**Goal:** CRUD of comments anchored to a line via extmarks, comment mode (toggle + nui popup to add/edit), commands and keymaps, with re-anchoring on write. Depends **only** on `require("review.core")`.

**Architecture:** `lua/review/features/comments/{render,mode,commands,init}.lua`. `render.lua` is pure extmark + `core.state`; `mode.lua` holds the UI logic (guicursor/nui) plus a UI-free testable core (`_add`, `_delete_at`, `_resolve_at`); `commands.lua` registers `:ReviewCommentMode`/`:Rcm`, `:ReviewList`/`:Rl` and keymaps; `init.lua` wires autocmds and self-registers in `core.registry`.

**Tech Stack:** Lua, Neovim ≥ 0.10, plenary.nvim (busted tests), nui.nvim (popup, only in `mode.add_here`, not in the testable core).

## Global Constraints

- Never `require("review.features.<other>")` — only `require("review.core")`.
- Comment `path` is always relative to the git root (`core.git.rel_path`). If `rel_path` returns `nil` (buffer outside the repo or without a name), every comments operation is a silent no-op.
- `_extmark_id` is runtime-only: it is set in `render.lua`, it is never sent to `core.state.persist` as a persisted field (`state.persist` already filters it), and it is never used to decide whether a comment exists.
- `lnum`/`end_lnum` are always clamped to `[1, nvim_buf_line_count(bufnr)]` before creating an extmark or saving.
- If `core.state.for_path(rel)` returns `{}`, `render.render` must not fail or create anything.
- Tests: `nvim --headless -c "PlenaryBustedFile tests/comments/<spec>.lua" -c "qa"`. Full suite: `nvim --headless -c "PlenaryBustedDirectory tests/ {minimal_init='tests/minimal_init.lua'}" -c "qa"`.

---

### Task 1: `render.lua` — extmarks + anchoring + sync_positions

**Files:**
- Create: `lua/review/features/comments/render.lua`, `tests/comments/render_spec.lua`

**Interfaces:**
- Consumes: `core.state.for_path(relpath)` → `comment[]`, `core.state.update(id, fields)`, `core.state.by_id(id)`, `core.git.rel_path(bufnr)`, `core.ns.comments`.
- Produces:
  - `render.render(core, bufnr)` — clears the extmarks of the `core.ns.comments` namespace in `bufnr` and creates one for each comment in `core.state.for_path(rel)`. The extmark anchors the start (`row`) **and the end** (`end_row = end_lnum-1`) to preserve multi-line ranges. `sign_text="💬"`, eol `virt_text` with the truncated `text`; open ones with the prefix `💬 ` and hl `DiagnosticInfo`, resolved ones with `✓ ` and hl `Comment`. Stores the id in `c._extmark_id`. No-op if `core.git.rel_path(bufnr)` is `nil`.
  - `render.sync_positions(core, bufnr)` — for each comment with an `_extmark_id`, re-reads the extmark with `{ details = true }` and updates **both `lnum` (pos[1]+1) and `end_lnum` (details.end_row+1)** via `core.state.update`, preserving the range. No-op if `rel_path` is `nil` or if the comment has no `_extmark_id`.

- [ ] **Step 1: Failing test — `tests/comments/render_spec.lua`**

```lua
local store = require("review.core.store")
local state = require("review.core.state")
local git = require("review.core.git")
local ns = require("review.core.ns")
local render = require("review.features.comments.render")

local core = { state = state, git = git, ns = ns }

describe("comments.render", function()
  local root, bufnr

  before_each(function()
    root = vim.fn.tempname()
    vim.fn.mkdir(root, "p")
    store.root_fn = function() return root end
    state._reset()
    bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(bufnr, root .. "/foo.ts")
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "l1", "l2", "l3", "l4", "l5" })
  end)

  it("no-op if the buffer is outside the repo", function()
    local other = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(other, "/outside/x.ts")
    state.add({ path = "x.ts", lnum = 1, text = "hello" })
    assert.has_no.errors(function() render.render(core, other) end)
    assert.are.equal(0, #vim.api.nvim_buf_get_extmarks(other, ns.comments, 0, -1, {}))
  end)

  it("creates nothing if there are no comments for the path", function()
    assert.has_no.errors(function() render.render(core, bufnr) end)
    assert.are.equal(0, #vim.api.nvim_buf_get_extmarks(bufnr, ns.comments, 0, -1, {}))
  end)

  it("creates one extmark per comment and sets _extmark_id", function()
    local c = state.add({ path = "foo.ts", lnum = 2, text = "heads up" })
    render.render(core, bufnr)
    assert.is_number(c._extmark_id)
    assert.are.equal(1, #vim.api.nvim_buf_get_extmarks(bufnr, ns.comments, 0, -1, {}))
  end)

  it("anchoring: inserting a line above raises the lnum after sync_positions", function()
    local c = state.add({ path = "foo.ts", lnum = 3, text = "heads up" })
    render.render(core, bufnr)
    vim.api.nvim_buf_set_lines(bufnr, 0, 0, false, { "new" })
    render.sync_positions(core, bufnr)
    assert.are.equal(4, state.by_id(c.id).lnum)
  end)

  it("sync_positions does not break if the comment has no _extmark_id", function()
    state.add({ path = "foo.ts", lnum = 1, text = "no render" })
    assert.has_no.errors(function() render.sync_positions(core, bufnr) end)
  end)

  it("preserves the multi-line range after inserting above", function()
    local c = state.add({ path = "foo.ts", lnum = 2, end_lnum = 4, text = "range" })
    render.render(core, bufnr)
    vim.api.nvim_buf_set_lines(bufnr, 0, 0, false, { "new" })
    render.sync_positions(core, bufnr)
    local got = state.by_id(c.id)
    assert.are.equal(3, got.lnum)      -- 2 -> 3
    assert.are.equal(5, got.end_lnum)  -- 4 -> 5 (range kept, not collapsed)
  end)
end)
```

- [ ] **Step 2: Run and watch it fail**

Run: `cd ~/Dev/nvim/review.nvim && nvim --headless -c "PlenaryBustedFile tests/comments/render_spec.lua" -c "qa"`
Expected: FAIL ("module 'review.features.comments.render' not found").

- [ ] **Step 3: Implement `lua/review/features/comments/render.lua`**

```lua
local M = {}

local function clamp(bufnr, lnum)
  local last = vim.api.nvim_buf_line_count(bufnr)
  if last < 1 then return 1 end
  if lnum < 1 then return 1 end
  if lnum > last then return last end
  return lnum
end

function M.render(core, bufnr)
  local rel = core.git.rel_path(bufnr)
  if not rel then return end

  vim.api.nvim_buf_clear_namespace(bufnr, core.ns.comments, 0, -1)

  local comments = core.state.for_path(rel)
  for _, c in ipairs(comments) do
    local lnum = clamp(bufnr, c.lnum or 1)
    local end_lnum = clamp(bufnr, c.end_lnum or lnum)
    if end_lnum < lnum then lnum, end_lnum = end_lnum, lnum end
    local row = lnum - 1
    local text = c.text or ""
    if #text > 60 then text = text:sub(1, 57) .. "..." end

    -- Different hl depending on state: resolved ones dimmed (Comment), open ones DiagnosticInfo.
    local prefix = c.resolved and "✓ " or "💬 "
    local hl = c.resolved and "Comment" or "DiagnosticInfo"

    -- `end_row` anchors the END of the range as well as the start, so that
    -- multi-line comments keep their range when the code moves.
    local id = vim.api.nvim_buf_set_extmark(bufnr, core.ns.comments, row, 0, {
      end_row = end_lnum - 1,
      sign_text = "💬",
      sign_hl_group = hl,
      virt_text = { { prefix .. text, hl } },
      virt_text_pos = "eol",
    })
    c._extmark_id = id
  end
end

function M.sync_positions(core, bufnr)
  local rel = core.git.rel_path(bufnr)
  if not rel then return end

  local comments = core.state.for_path(rel)
  for _, c in ipairs(comments) do
    if c._extmark_id then
      -- `details=true` to recover `end_row` and preserve the range.
      local ok, pos = pcall(vim.api.nvim_buf_get_extmark_by_id, bufnr, core.ns.comments, c._extmark_id, { details = true })
      if ok and pos and pos[1] then
        local new_lnum = clamp(bufnr, pos[1] + 1)
        local details = pos[3]
        local new_end = new_lnum
        if details and details.end_row then
          new_end = clamp(bufnr, details.end_row + 1)
        end
        if new_end < new_lnum then new_lnum, new_end = new_end, new_lnum end
        if new_lnum ~= c.lnum or new_end ~= c.end_lnum then
          core.state.update(c.id, { lnum = new_lnum, end_lnum = new_end })
        end
      end
    end
  end
end

return M
```

- [ ] **Step 4: Run and watch it pass**

Run: `cd ~/Dev/nvim/review.nvim && nvim --headless -c "PlenaryBustedFile tests/comments/render_spec.lua" -c "qa"`
Expected: PASS (6).

- [ ] **Step 5: Commit**

```bash
cd ~/Dev/nvim/review.nvim && git add -A
git commit -q -m "feat(comments): render extmarks with anchoring and sync_positions"
```

---

### Task 2: `mode.lua` — comment mode, testable core (`_add`/`_delete_at`/`_resolve_at`) + toggle/popup

**Files:**
- Create: `lua/review/features/comments/mode.lua`, `tests/comments/mode_spec.lua`

**Interfaces:**
- Consumes: `core.git.rel_path(bufnr)`, `core.state.add`, `core.state.remove`, `core.state.update`, `core.state.for_path`, `core.state.persist`, `render.render` (Task 1).
- Produces:
  - `mode._add(core, bufnr, lnum, end_lnum, text)` → `comment|nil` — UI-free testable core. Resolves `rel = core.git.rel_path(bufnr)`; if `nil`, no-op and returns `nil`. Clamps `lnum`/`end_lnum` to `[1, line_count]` and sorts them (`lnum <= end_lnum`). If `text` is `nil` or an empty string after `vim.trim`, no-op and returns `nil`. Calls `core.state.add({ path=rel, lnum=lnum, end_lnum=end_lnum, text=text })`, then `require("review.features.comments.render").render(core, bufnr)` and `core.state.persist()`. Returns the created comment.
  - `mode._delete_at(core, bufnr, lnum)` → `boolean` — looks in `core.state.for_path(rel)` for the first comment whose range `[lnum, end_lnum]` covers `lnum` (clamped), removes it with `core.state.remove(id)`, re-renders and persists. `false` if there is no `rel` or no comment on that line.
  - `mode._resolve_at(core, bufnr, lnum)` → `boolean` — same search criterion; toggles `resolved` via `core.state.update(id, { resolved = not c.resolved })`, re-renders and persists. `false` if there is no `rel` or no comment on that line.
  - `mode.toggle(core)` — toggles `_G.review_mode_active` (boolean, starts as `false`) and adjusts `vim.o.guicursor` (saves the previous value in a module upvalue so it can be restored on deactivation).
  - `mode.add_here(core, opts)` — uses `require("nui.popup")` to ask for text over the line (normal) or visual range (`vim.fn.line("v")`/`vim.fn.line(".")`) of the current buffer; on confirm (`<CR>` in normal mode inside the popup, or a keymap configurable in `opts`) it calls `mode._add(core, bufnr, lnum, end_lnum, texto_del_popup)` and closes the popup.
  - `mode.delete_here(core)` — `mode._delete_at(core, vim.api.nvim_get_current_buf(), vim.fn.line("."))`.
  - `mode.resolve_here(core)` — `mode._resolve_at(core, vim.api.nvim_get_current_buf(), vim.fn.line("."))`.

- [ ] **Step 1: Failing test — `tests/comments/mode_spec.lua`** (only the testable core, without nui)

```lua
local store = require("review.core.store")
local state = require("review.core.state")
local git = require("review.core.git")
local ns = require("review.core.ns")
local mode = require("review.features.comments.mode")

local core = { state = state, git = git, ns = ns }

describe("comments.mode core", function()
  local root, bufnr

  before_each(function()
    root = vim.fn.tempname()
    vim.fn.mkdir(root, "p")
    store.root_fn = function() return root end
    state._reset()
    bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(bufnr, root .. "/foo.ts")
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "l1", "l2", "l3", "l4", "l5" })
  end)

  it("_add adds, renders and persists", function()
    local c = mode._add(core, bufnr, 2, 2, "review this")
    assert.is_truthy(c)
    assert.are.equal(1, #state.for_path("foo.ts"))
    state._reset(); state.load()
    assert.are.equal(1, #state.for_path("foo.ts"))
  end)

  it("_add is a no-op if the buffer is outside the repo", function()
    local other = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(other, "/outside/x.ts")
    local c = mode._add(core, other, 1, 1, "something")
    assert.is_nil(c)
  end)

  it("_add is a no-op if the text is empty", function()
    local c = mode._add(core, bufnr, 1, 1, "   ")
    assert.is_nil(c)
    assert.are.equal(0, #state.for_path("foo.ts"))
  end)

  it("_add clamps an out-of-range lnum", function()
    local c = mode._add(core, bufnr, 999, 999, "out of range")
    assert.are.equal(5, c.lnum)
    assert.are.equal(5, c.end_lnum)
  end)

  it("_delete_at deletes the comment that covers the line", function()
    local c = mode._add(core, bufnr, 3, 3, "delete")
    assert.is_true(mode._delete_at(core, bufnr, 3))
    assert.is_nil(state.by_id(c.id))
  end)

  it("_delete_at returns false if there is no comment on the line", function()
    assert.is_false(mode._delete_at(core, bufnr, 1))
  end)

  it("_resolve_at toggles resolved", function()
    local c = mode._add(core, bufnr, 4, 4, "resolve")
    assert.is_true(mode._resolve_at(core, bufnr, 4))
    assert.is_true(state.by_id(c.id).resolved)
    assert.is_true(mode._resolve_at(core, bufnr, 4))
    assert.is_false(state.by_id(c.id).resolved)
  end)
end)
```

- [ ] **Step 2: Run and watch it fail**

Run: `cd ~/Dev/nvim/review.nvim && nvim --headless -c "PlenaryBustedFile tests/comments/mode_spec.lua" -c "qa"`
Expected: FAIL ("module 'review.features.comments.mode' not found").

- [ ] **Step 3: Implement `lua/review/features/comments/mode.lua`**

```lua
local render = require("review.features.comments.render")

local M = {}
local saved_guicursor = nil

local function clamp(bufnr, lnum)
  local last = vim.api.nvim_buf_line_count(bufnr)
  if last < 1 then return 1 end
  if lnum < 1 then return 1 end
  if lnum > last then return last end
  return lnum
end

local function find_at(core, rel, lnum)
  for _, c in ipairs(core.state.for_path(rel)) do
    local lo = math.min(c.lnum, c.end_lnum or c.lnum)
    local hi = math.max(c.lnum, c.end_lnum or c.lnum)
    if lnum >= lo and lnum <= hi then return c end
  end
  return nil
end

function M._add(core, bufnr, lnum, end_lnum, text)
  local rel = core.git.rel_path(bufnr)
  if not rel then return nil end

  if text == nil or vim.trim(text) == "" then return nil end

  lnum = clamp(bufnr, lnum or 1)
  end_lnum = clamp(bufnr, end_lnum or lnum)
  if end_lnum < lnum then
    lnum, end_lnum = end_lnum, lnum
  end

  local c = core.state.add({ path = rel, lnum = lnum, end_lnum = end_lnum, text = text })
  render.render(core, bufnr)
  core.state.persist()
  return c
end

function M._delete_at(core, bufnr, lnum)
  local rel = core.git.rel_path(bufnr)
  if not rel then return false end

  lnum = clamp(bufnr, lnum)
  local c = find_at(core, rel, lnum)
  if not c then return false end

  local ok = core.state.remove(c.id)
  render.render(core, bufnr)
  core.state.persist()
  return ok
end

function M._resolve_at(core, bufnr, lnum)
  local rel = core.git.rel_path(bufnr)
  if not rel then return false end

  lnum = clamp(bufnr, lnum)
  local c = find_at(core, rel, lnum)
  if not c then return false end

  local ok = core.state.update(c.id, { resolved = not c.resolved })
  render.render(core, bufnr)
  core.state.persist()
  return ok
end

function M.toggle(core)
  _G.review_mode_active = not _G.review_mode_active
  if _G.review_mode_active then
    saved_guicursor = vim.o.guicursor
    vim.o.guicursor = "a:blinkon0-Cursor/lCursor"
  else
    vim.o.guicursor = saved_guicursor or vim.o.guicursor
  end
end

function M.add_here(core, opts)
  opts = opts or {}
  local Popup = require("nui.popup")
  local bufnr = vim.api.nvim_get_current_buf()

  local mode_v = vim.fn.mode()
  local lnum, end_lnum
  if mode_v == "v" or mode_v == "V" or mode_v == "\22" then
    lnum = vim.fn.line("v")
    end_lnum = vim.fn.line(".")
    vim.cmd("normal! \27")
  else
    lnum = vim.fn.line(".")
    end_lnum = lnum
  end

  local popup = Popup({
    enter = true,
    focusable = true,
    border = { style = "rounded", text = { top = " Comment " } },
    position = "50%",
    size = { width = 60, height = 5 },
    buf_options = { filetype = "markdown" },
  })

  popup:mount()

  local function confirm()
    local lines = vim.api.nvim_buf_get_lines(popup.bufnr, 0, -1, false)
    local text = table.concat(lines, "\n")
    popup:unmount()
    M._add(core, bufnr, lnum, end_lnum, text)
  end

  local function cancel()
    popup:unmount()
  end

  popup:map("n", opts.confirm_key or "<CR>", confirm, { noremap = true })
  popup:map("n", opts.cancel_key or "<Esc>", cancel, { noremap = true })
end

function M.delete_here(core)
  return M._delete_at(core, vim.api.nvim_get_current_buf(), vim.fn.line("."))
end

function M.resolve_here(core)
  return M._resolve_at(core, vim.api.nvim_get_current_buf(), vim.fn.line("."))
end

return M
```

- [ ] **Step 4: Run and watch it pass**

Run: `cd ~/Dev/nvim/review.nvim && nvim --headless -c "PlenaryBustedFile tests/comments/mode_spec.lua" -c "qa"`
Expected: PASS (7).

- [ ] **Step 5: Commit**

```bash
cd ~/Dev/nvim/review.nvim && git add -A
git commit -q -m "feat(comments): mode with testable core _add/_delete_at/_resolve_at + nui popup"
```

---

### Task 3: `commands.lua` — commands, aliases and keymaps

**Files:**
- Create: `lua/review/features/comments/commands.lua`, `tests/comments/commands_spec.lua`

**Interfaces:**
- Consumes: `mode.toggle`, `mode.add_here`, `mode.delete_here`, `mode.resolve_here` (Task 2), `core.state.all` and `core.git.root` (for `:ReviewList`).
- Produces: `commands.setup(core, opts)` — registers:
  - `:ReviewCommentMode` and alias `:Rcm` (both real commands) → `mode.toggle(core)`.
  - `:ReviewList` and alias `:Rl` (both real commands) → opens quickfix with `core.state.all()` (one entry per comment: `filename` = **absolute path** `core.git.root().."/"..path`, `lnum`, `text` with the prefix `[✓] ` if `resolved`).
  - Keymaps with prefix `opts.leader or "<leader>r"`: `<leader>rr` (toggle, normal), `<leader>rc` (add_here, normal and visual), `<leader>rd` (delete_here, normal), `<leader>rx` (resolve_here, normal).

- [ ] **Step 1: Failing test — `tests/comments/commands_spec.lua`**

```lua
local store = require("review.core.store")
local state = require("review.core.state")
local git = require("review.core.git")
local ns = require("review.core.ns")
local commands = require("review.features.comments.commands")

local core = { state = state, git = git, ns = ns }

describe("comments.commands", function()
  before_each(function()
    local tmp = vim.fn.tempname(); vim.fn.mkdir(tmp, "p")
    store.root_fn = function() return tmp end
    state._reset()
  end)

  it("registers :ReviewCommentMode and :Rcm", function()
    commands.setup(core, { leader = "<leader>r" })
    assert.is_not_nil(vim.api.nvim_get_commands({})["ReviewCommentMode"])
    assert.is_true(vim.fn.exists(":Rcm") == 2)
  end)

  it("registers :ReviewList and :Rl", function()
    commands.setup(core, { leader = "<leader>r" })
    assert.is_not_nil(vim.api.nvim_get_commands({})["ReviewList"])
    assert.is_true(vim.fn.exists(":Rl") == 2)
  end)

  it(":ReviewList fills the quickfix with the comments", function()
    state.add({ path = "a.ts", lnum = 3, text = "review" })
    commands.setup(core, { leader = "<leader>r" })
    vim.cmd("ReviewList")
    local qf = vim.fn.getqflist()
    assert.are.equal(1, #qf)
    assert.are.equal(3, qf[1].lnum)
  end)

  it("maps <leader>rr in normal mode", function()
    commands.setup(core, { leader = "<leader>r" })
    local maps = vim.api.nvim_get_keymap("n")
    local found = false
    for _, m in ipairs(maps) do
      if m.lhs == "<leader>rr" then found = true end
    end
    assert.is_true(found)
  end)
end)
```

- [ ] **Step 2: Run and watch it fail**

Run: `cd ~/Dev/nvim/review.nvim && nvim --headless -c "PlenaryBustedFile tests/comments/commands_spec.lua" -c "qa"`
Expected: FAIL ("module 'review.features.comments.commands' not found").

- [ ] **Step 3: Implement `lua/review/features/comments/commands.lua`**

```lua
local mode = require("review.features.comments.mode")

local M = {}

local function open_quickfix(core)
  -- Absolute path: quickfix resolves `filename` against the cwd, but
  -- `c.path` is relative to the repo root. Without this, opening nvim from a
  -- subdirectory would open the wrong file.
  local root = core.git.root() or ""
  local base = (root ~= "") and (root .. "/") or ""
  local items = {}
  for _, c in ipairs(core.state.all()) do
    local prefix = c.resolved and "[✓] " or ""
    table.insert(items, {
      filename = base .. c.path,
      lnum = c.lnum,
      text = prefix .. (c.text or ""),
    })
  end
  vim.fn.setqflist(items)
  vim.cmd("copen")
end

function M.setup(core, opts)
  opts = opts or {}
  local leader = opts.leader or "<leader>r"

  local function toggle() mode.toggle(core) end
  local function list() open_quickfix(core) end

  -- Long command + short alias (both real commands). The lowercase version
  -- (`rcm`/`rl`) is resolved by `plugin/review.lua` (core Task 7)
  -- via cnoreabbrev pointing to these real commands.
  vim.api.nvim_create_user_command("ReviewCommentMode", toggle, {})
  vim.api.nvim_create_user_command("Rcm", toggle, {})
  vim.api.nvim_create_user_command("ReviewList", list, {})
  vim.api.nvim_create_user_command("Rl", list, {})

  vim.keymap.set("n", leader .. "r", function() mode.toggle(core) end, { desc = "Review: toggle comment mode" })
  vim.keymap.set("n", leader .. "c", function() mode.add_here(core, {}) end, { desc = "Review: add comment" })
  vim.keymap.set("v", leader .. "c", function() mode.add_here(core, {}) end, { desc = "Review: add comment (range)" })
  vim.keymap.set("n", leader .. "d", function() mode.delete_here(core) end, { desc = "Review: delete comment here" })
  vim.keymap.set("n", leader .. "x", function() mode.resolve_here(core) end, { desc = "Review: resolve comment here" })
end

return M
```

- [ ] **Step 4: Run and watch it pass**

Run: `cd ~/Dev/nvim/review.nvim && nvim --headless -c "PlenaryBustedFile tests/comments/commands_spec.lua" -c "qa"`
Expected: PASS (4).

- [ ] **Step 5: Commit**

```bash
cd ~/Dev/nvim/review.nvim && git add -A
git commit -q -m "feat(comments): ReviewCommentMode/ReviewList commands + keymaps"
```

---

### Task 4: `init.lua` — autocmds + registration in `core.registry`

**Files:**
- Create: `lua/review/features/comments/init.lua`, `tests/comments/init_spec.lua`

**Interfaces:**
- Consumes: `render.render`, `render.sync_positions` (Task 1), `commands.setup` (Task 3), `core.registry.register` (core contract, `00-core.md` Task 1/6).
- Produces: `M.setup(core, opts)` — registers autocmds `BufReadPost`/`BufEnter` → `render.render(core, bufnr)`; `BufWritePost` → `render.sync_positions(core, bufnr)` followed by `core.state.persist()`. Calls `commands.setup(core, opts)`. At the end of the file (outside `setup`, at module level): `require("review.core").registry.register({ name = "comments", setup = M.setup })`.

- [ ] **Step 1: Failing test — `tests/comments/init_spec.lua`**

```lua
local store = require("review.core.store")
local state = require("review.core.state")
local git = require("review.core.git")
local ns = require("review.core.ns")

package.loaded["review.features.comments.init"] = nil
local comments = require("review.features.comments.init")

local core = { state = state, git = git, ns = ns }

describe("comments.init", function()
  local root, bufnr

  before_each(function()
    root = vim.fn.tempname()
    vim.fn.mkdir(root, "p")
    store.root_fn = function() return root end
    state._reset()
    bufnr = vim.api.nvim_create_buf(false, false)
    vim.api.nvim_buf_set_name(bufnr, root .. "/foo.ts")
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "l1", "l2", "l3" })
  end)

  it("self-registers in review.core.registry with name=comments", function()
    local core_mod = require("review.core")
    local feats = core_mod.registry.features()
    assert.is_not_nil(feats.comments)
    assert.are.equal(comments.setup, feats.comments.setup)
  end)

  it("setup registers commands and autocmds without errors", function()
    assert.has_no.errors(function() comments.setup(core, { leader = "<leader>r" }) end)
    assert.is_not_nil(vim.api.nvim_get_commands({})["ReviewCommentMode"])
  end)

  it("BufWritePost syncs positions and persists", function()
    comments.setup(core, { leader = "<leader>r" })
    local c = state.add({ path = "foo.ts", lnum = 2, text = "x" })
    require("review.features.comments.render").render(core, bufnr)
    vim.api.nvim_set_current_buf(bufnr)
    vim.api.nvim_buf_set_lines(bufnr, 0, 0, false, { "new" })
    vim.cmd("silent! write! " .. vim.fn.fnameescape(vim.api.nvim_buf_get_name(bufnr)))
    vim.wait(50)
    assert.are.equal(3, state.by_id(c.id).lnum)
  end)
end)
```

- [ ] **Step 2: Run and watch it fail**

Run: `cd ~/Dev/nvim/review.nvim && nvim --headless -c "PlenaryBustedFile tests/comments/init_spec.lua" -c "qa"`
Expected: FAIL ("module 'review.features.comments.init' not found").

- [ ] **Step 3: Implement `lua/review/features/comments/init.lua`**

```lua
local render = require("review.features.comments.render")
local commands = require("review.features.comments.commands")

local M = {}

function M.setup(core, opts)
  opts = opts or {}

  local group = vim.api.nvim_create_augroup("ReviewComments", { clear = true })

  vim.api.nvim_create_autocmd({ "BufReadPost", "BufEnter" }, {
    group = group,
    callback = function(args)
      render.render(core, args.buf)
    end,
  })

  vim.api.nvim_create_autocmd("BufWritePost", {
    group = group,
    callback = function(args)
      render.sync_positions(core, args.buf)
      core.state.persist()
    end,
  })

  commands.setup(core, opts)
end

require("review.core").registry.register({ name = "comments", setup = M.setup })

return M
```

- [ ] **Step 4: Run and watch it pass**

Run: `cd ~/Dev/nvim/review.nvim && nvim --headless -c "PlenaryBustedFile tests/comments/init_spec.lua" -c "qa"`
Expected: PASS (3).

- [ ] **Step 5: Full comments suite**

Run: `cd ~/Dev/nvim/review.nvim && nvim --headless -c "PlenaryBustedDirectory tests/comments {minimal_init='tests/minimal_init.lua'}" -c "qa"`
Expected: PASS (render 6, mode 7, commands 4, init 3 = 20).

- [ ] **Step 6: Commit**

```bash
cd ~/Dev/nvim/review.nvim && git add -A
git commit -q -m "feat(comments): render/sync autocmds + self-registration in core.registry"
```

---

## Self-Review

- **Coverage of the requested scope:** `render.lua` (render + sync_positions + `_extmark_id`) ✅ T1; `mode.lua` (`toggle`, `add_here` with nui, `delete_here`, `resolve_here`, testable core `_add`/`_delete_at`/`_resolve_at`) ✅ T2; `commands.lua` (`:ReviewCommentMode`/`:Rcm`, `:ReviewList`/`:Rl`, keymaps `<leader>rr/rc/rd/rx`, configurable prefix) ✅ T3; `init.lua` (`setup(core, opts)`, autocmds `BufReadPost`/`BufEnter`/`BufWritePost`, `registry.register`) ✅ T4.
- **Edge cases covered:** buffer outside the repo (`rel_path` nil → no-op) in `render.render`, `render.sync_positions`, `mode._add/_delete_at/_resolve_at` (dedicated tests in T1 and T2); `lnum`/`end_lnum` clamped to `[1, line_count]` via the local `clamp()` in `render.lua` and `mode.lua` (test "clamps an out-of-range lnum" in T2); `_extmark_id` is never persisted (delegated to `state.persist`, already filtered in `00-core.md` Task 5, and indirectly verified by the round-trip in T2 Step 1); no comments → `render.render` and `mode._delete_at/_resolve_at` do not break (tests "creates nothing..." in T1 and "returns false if there is no comment..." in T2).
- **Placeholders:** none — all the Lua code in each implementation step is complete and executable.
- **Signature consistency with the core contract (`00-core.md`):** `core.git.rel_path(bufnr)`, `core.state.for_path(relpath)`, `core.state.add(comment)`, `core.state.remove(id)`, `core.state.update(id, fields)`, `core.state.by_id(id)`, `core.state.all()`, `core.state.persist()`, `core.ns.comments`, `core.registry.register({ name, setup })` are used exactly with those signatures, without inventing new parameters. `mode.lua` and `render.lua` always receive `core` as the first argument (they never do `require("review.core")` directly except `init.lua`, which may because it is the feature's entry point and only uses it for `registry.register`).
- **Dependency between features:** no file in this plan does `require("review.features.<other>")`; any future coordination (e.g. `sidebar`) would go through `core.events` (`comments:changed`, already emitted by `core.state` according to the contract), not implemented here because it is not this slice's responsibility.
