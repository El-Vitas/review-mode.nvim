# review.nvim — Plan 03: Views (normal / inline / split)

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development or superpowers:executing-plans. Steps use checkboxes (`- [ ]`).
> **Master plan:** `~/Dev/nvim/review.nvim/DESIGN.md` — this plan implements the "views" slice of the Features table. Every signature here **must** match the "`core` contract" (see `docs/plans/00-core.md`).

**Goal:** Build the `views` feature: three per-buffer modes (`normal`, `inline`, `split`) that change **only** how the code is painted, via decorations (extmarks) over the real buffer. No new tabs, the buffer is always editable.

**Architecture:** `lua/review/features/views/` — `diff.lua` (pure parsing of `git diff -U0`), `inline.lua` (extmarks in `core.ns.views` over the current buffer), `split.lua` (vsplit with a readonly scratch buffer of the HEAD content), `init.lua` (per-buffer state `M.mode[bufnr]` + `set(bufnr, mode)`), `commands.lua` (`:ReviewView`/`:Rv`, keymap `<leader>rv`). Depends **only** on `require("review.core")` (`git.rel_path`, `git.head_content`, `ns.views`, `events.emit`). It never requires another feature.

**Tech Stack:** Lua, Neovim ≥ 0.10 (extmarks `virt_lines`, `line_hl_group`), plenary.nvim (busted tests).

## Global Constraints

- The view is **only** presentation: it never modifies the content of the real buffer, it only adds/clears extmarks in `core.ns.views`.
- No new tabs. `split` uses `:vsplit` with a scratch buffer (`buftype=nofile`, `readonly`) for the HEAD content; the right window remains the real, editable buffer.
- When changing mode (`set(bufnr, mode)`) the previous view is **always** cleared before applying the new one (never leave dangling extmarks/windows).
- Toggling to the same mode is idempotent (it does not duplicate decorations or windows).
- File without changes vs HEAD → `inline.render` is a no-op (paints nothing, raises no error).
- New file (no HEAD, `head_content` returns `nil`) → `split.open` warns with `vim.notify` and does not open a panel.
- Tests: `nvim --headless -c "PlenaryBustedFile tests/views/<spec>.lua" -c "qa"`.

---

### Task 1: `diff.lua` — pure parsing of `git diff -U0`

**Files:**
- Create: `lua/review/features/views/diff.lua`, `tests/views/diff_spec.lua`

**Interfaces:**
- Produces:
  - `diff.parse_unified_diff(text)` → `hunk[]`, `hunk = { old_start, old_count, new_start, new_count, del_lines={string...}, add_lines={string...}, add_lnums={int...} }` (`add_lnums` = 1-based line numbers in the new file that correspond to `add_lines`).
  - `diff.hunks_for(relpath, git_root)` → `hunk[]|nil` — runs `git -C git_root diff -U0 -- relpath` and parses the output with `parse_unified_diff`. `nil` if the command fails or there is no `git_root`.

- [ ] **Step 1: Failing test — `tests/views/diff_spec.lua`**

```lua
local diff = require("review.features.views.diff")

describe("views.diff.parse_unified_diff", function()
  it("parses a simple replacement hunk", function()
    local text = table.concat({
      "diff --git a/foo.lua b/foo.lua",
      "index 111..222 100644",
      "--- a/foo.lua",
      "+++ b/foo.lua",
      "@@ -2,2 +2,3 @@",
      "-local a = 1",
      "-local b = 2",
      "+local a = 10",
      "+local b = 20",
      "+local c = 30",
    }, "\n")
    local hunks = diff.parse_unified_diff(text)
    assert.are.equal(1, #hunks)
    local h = hunks[1]
    assert.are.equal(2, h.old_start)
    assert.are.equal(2, h.old_count)
    assert.are.equal(2, h.new_start)
    assert.are.equal(3, h.new_count)
    assert.are.same({ "local a = 1", "local b = 2" }, h.del_lines)
    assert.are.same({ "local a = 10", "local b = 20", "local c = 30" }, h.add_lines)
    assert.are.same({ 2, 3, 4 }, h.add_lnums)
  end)

  it("parses multiple hunks", function()
    local text = table.concat({
      "@@ -1 +1 @@",
      "-x",
      "+y",
      "@@ -10,0 +11,2 @@",
      "+z1",
      "+z2",
    }, "\n")
    local hunks = diff.parse_unified_diff(text)
    assert.are.equal(2, #hunks)
    assert.are.equal(1, hunks[1].old_start)
    assert.are.same({ 11, 12 }, hunks[2].add_lnums)
  end)

  it("empty text or text without hunks returns an empty list", function()
    assert.are.same({}, diff.parse_unified_diff(""))
    assert.are.same({}, diff.parse_unified_diff("diff --git a/x b/x\nindex 1..2 100644\n"))
  end)

  it("add-only hunk (old_count defaults to 1 if missing)", function()
    local text = "@@ -5 +5,2 @@\n+added1\n+added2\n"
    local hunks = diff.parse_unified_diff(text)
    assert.are.equal(1, hunks[1].old_count)
    assert.are.equal(2, hunks[1].new_count)
    assert.are.same({}, hunks[1].del_lines)
    assert.are.same({ "added1", "added2" }, hunks[1].add_lines)
  end)
end)

describe("views.diff.hunks_for", function()
  it("nil if there is no git_root", function()
    assert.is_nil(diff.hunks_for("foo.lua", nil))
  end)
end)
```

- [ ] **Step 2: Run and watch it fail**

Run: `cd ~/Dev/nvim/review.nvim && nvim --headless -c "PlenaryBustedFile tests/views/diff_spec.lua" -c "qa"`
Expected: FAIL (`module 'review.features.views.diff' not found`).

- [ ] **Step 3: Implement `lua/review/features/views/diff.lua`**

```lua
local M = {}

-- Parses the header of a unified hunk: @@ -old_start[,old_count] +new_start[,new_count] @@
local function parse_hunk_header(line)
  local old_start, old_count, new_start, new_count =
    line:match("^@@ %-(%d+),?(%d*) %+(%d+),?(%d*) @@")
  if not old_start then return nil end
  old_count = old_count ~= "" and tonumber(old_count) or 1
  new_count = new_count ~= "" and tonumber(new_count) or 1
  return {
    old_start = tonumber(old_start),
    old_count = old_count,
    new_start = tonumber(new_start),
    new_count = new_count,
    del_lines = {},
    add_lines = {},
    add_lnums = {},
  }
end

--- Parses the full text of `git diff -U0` into a list of hunks.
--- Ignores the diff header lines (diff --git / index / --- / +++).
function M.parse_unified_diff(text)
  local hunks = {}
  if not text or text == "" then return hunks end

  local current = nil
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    if line:match("^@@ ") then
      current = parse_hunk_header(line)
      if current then table.insert(hunks, current) end
    elseif current then
      if line:sub(1, 1) == "-" and line:sub(1, 3) ~= "---" then
        table.insert(current.del_lines, line:sub(2))
      elseif line:sub(1, 1) == "+" and line:sub(1, 3) ~= "+++" then
        table.insert(current.add_lines, line:sub(2))
        table.insert(current.add_lnums, current.new_start + #current.add_lnums)
      end
      -- other lines (---, +++, \ No newline at end of file) are ignored
    end
  end

  return hunks
end

--- Runs `git diff -U0 -- relpath` in git_root and returns the parsed hunks.
--- nil if there is no git_root or the command fails.
function M.hunks_for(relpath, git_root)
  if not git_root then return nil end
  local out = vim.fn.system({ "git", "-C", git_root, "diff", "-U0", "--", relpath })
  if vim.v.shell_error ~= 0 then return nil end
  return M.parse_unified_diff(out)
end

return M
```

- [ ] **Step 4: Run and watch it pass**

Run: `cd ~/Dev/nvim/review.nvim && nvim --headless -c "PlenaryBustedFile tests/views/diff_spec.lua" -c "qa"`
Expected: PASS (5).

- [ ] **Step 5: Commit**

```bash
cd ~/Dev/nvim/review.nvim && git add -A
git commit -q -m "feat(views/diff): pure parsing of git diff -U0"
```

---

### Task 2: `inline.lua` — inline decorations over the real buffer

**Files:**
- Create: `lua/review/features/views/inline.lua`

**Interfaces:**
- Consumes: `core.git.rel_path`, `core.git.root`, `core.ns.views`, `views.diff.hunks_for` (Task 1).
- Produces:
  - `inline.render(core, bufnr)` — clears `core.ns.views` in `bufnr` and paints hunks: deleted lines as `virt_lines` (hl `DiffDelete`) **before** the position where the deletion occurred; added lines with an extmark `line_hl_group = "DiffAdd"` over the real lines indicated by `add_lnums`. No-op if `rel_path` is `nil`, `root` is `nil`, or there are no hunks.
  - `inline.clear(core, bufnr)` — `vim.api.nvim_buf_clear_namespace(bufnr, core.ns.views, 0, -1)`.

This layer has NO unit test of its own (it uses real extmarks of a live buffer) — it is covered by manual verification in Task 4. The parsing logic is already tested in Task 1.

- [ ] **Step 1: Implement `lua/review/features/views/inline.lua`**

```lua
local diff = require("review.features.views.diff")

local M = {}

function M.clear(core, bufnr)
  vim.api.nvim_buf_clear_namespace(bufnr, core.ns.views, 0, -1)
end

--- Paints inline diff decorations over bufnr. No-op if the file does not
--- belong to the repo or has no changes.
function M.render(core, bufnr)
  M.clear(core, bufnr)

  local relpath = core.git.rel_path(bufnr)
  local root = core.git.root()
  if not relpath or not root then return end

  local hunks = diff.hunks_for(relpath, root)
  if not hunks or #hunks == 0 then return end

  local ns = core.ns.views
  for _, h in ipairs(hunks) do
    -- Deleted lines: virt_lines hanging above the first new line
    -- that corresponds to this hunk (or above the next line if the hunk is
    -- a pure delete at the end of the file).
    if #h.del_lines > 0 then
      local anchor_lnum = math.max(h.new_start - 1, 0)
      local virt_lines = {}
      for _, dl in ipairs(h.del_lines) do
        table.insert(virt_lines, { { dl, "DiffDelete" } })
      end
      local ok = pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, anchor_lnum, 0, {
        virt_lines = virt_lines,
        virt_lines_above = anchor_lnum > 0,
      })
      if not ok then
        -- anchor out of range (file shorter than expected): ignore
      end
    end

    -- Added lines: highlight the whole real line.
    for _, lnum in ipairs(h.add_lnums) do
      local row = lnum - 1
      if row >= 0 and row < vim.api.nvim_buf_line_count(bufnr) then
        pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, row, 0, {
          line_hl_group = "DiffAdd",
        })
      end
    end
  end
end

return M
```

- [ ] **Step 2: Commit**

```bash
cd ~/Dev/nvim/review.nvim && git add -A
git commit -q -m "feat(views/inline): render/clear of inline decorations"
```

---

### Task 3: `split.lua` — left panel with HEAD content

**Files:**
- Create: `lua/review/features/views/split.lua`

**Interfaces:**
- Consumes: `core.git.rel_path`, `core.git.head_content`, `core.ns.views`, `views.diff.hunks_for` (Task 1).
- Produces:
  - `split.open(core, bufnr)` — if `head_content(relpath)` is `nil` (new file/no HEAD or outside git), `vim.notify(..., WARN)` and returns without opening anything. Otherwise: `:vsplit` to the left of the current buffer, creates/reuses a scratch buffer (`buftype=nofile`, `bufhidden=wipe`, `readonly`, `modifiable=false`, name `review://head/<relpath>`) with the HEAD lines, paints red/green hl there with the same hunks (deleted = `DiffDelete` full line, unchanged context without hl), and leaves the focus on the right window (original buffer).
  - `split.close(core, bufnr)` — closes the HEAD scratch buffer window **of that buffer** if it is open and returns to 1 column. Idempotent (no-op if that buffer has no panel).
  - Internally stores `M._panels[bufnr] = { win, buf }` (per-buffer state, not a singleton) so the right panel can be closed.

No unit test of its own (real vsplit/windows) — manual verification in Task 4.

- [ ] **Step 1: Implement `lua/review/features/views/split.lua`**

```lua
local diff = require("review.features.views.diff")

-- Per-buffer state: `_panels[bufnr] = { win = <left_win>, buf = <scratch> }`.
-- (A global singleton would break if two buffers were in split mode at the same time.)
local M = { _panels = {} }

local function head_hl_lines(core, bufnr, head_lines, relpath)
  local root = core.git.root()
  local hunks = root and diff.hunks_for(relpath, root) or nil
  if not hunks then return end
  local ns = core.ns.views
  for _, h in ipairs(hunks) do
    for i = 1, #h.del_lines do
      local row = h.old_start - 1 + (i - 1)
      if row >= 0 and row < #head_lines then
        pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, row, 0, { line_hl_group = "DiffDelete" })
      end
    end
  end
end

--- Opens the left panel with the HEAD content of the current buffer's file.
--- Warns and opens nothing if the file has no HEAD (new / outside git).
function M.open(core, bufnr)
  local relpath = core.git.rel_path(bufnr)
  if not relpath then
    vim.notify("review.nvim: buffer outside the repo, cannot open split", vim.log.levels.WARN)
    return
  end

  local head_lines = core.git.head_content(relpath)
  if not head_lines then
    vim.notify(
      "review.nvim: '" .. relpath .. "' has no version in HEAD (new file)",
      vim.log.levels.WARN
    )
    return
  end

  M.close(core, bufnr) -- closes a previous panel of this buffer, if there was one

  local target_win = vim.api.nvim_get_current_win()
  vim.cmd("topleft vsplit")
  local left_win = vim.api.nvim_get_current_win()

  local scratch = vim.api.nvim_create_buf(false, true)
  vim.bo[scratch].buftype = "nofile"
  vim.bo[scratch].bufhidden = "wipe"
  vim.bo[scratch].modifiable = true
  vim.api.nvim_buf_set_lines(scratch, 0, -1, false, head_lines)
  vim.bo[scratch].modifiable = false
  vim.bo[scratch].readonly = true
  pcall(vim.api.nvim_buf_set_name, scratch, "review://head/" .. relpath)

  vim.api.nvim_win_set_buf(left_win, scratch)
  head_hl_lines(core, scratch, head_lines, relpath)

  M._panels[bufnr] = { win = left_win, buf = scratch }

  vim.api.nvim_set_current_win(target_win)
end

--- Closes the left HEAD panel of buffer `bufnr` if it is open.
--- Idempotent (no-op if that buffer has no panel).
function M.close(core, bufnr)
  local p = M._panels[bufnr]
  if p and p.win and vim.api.nvim_win_is_valid(p.win) then
    pcall(vim.api.nvim_win_close, p.win, true)
  end
  M._panels[bufnr] = nil
end

return M
```

- [ ] **Step 2: Commit**

```bash
cd ~/Dev/nvim/review.nvim && git add -A
git commit -q -m "feat(views/split): readonly left panel with HEAD content"
```

---

### Task 4: `init.lua` — per-buffer state + `set(bufnr, mode)`

**Files:**
- Create: `lua/review/features/views/init.lua`, `tests/views/init_spec.lua`

**Interfaces:**
- Consumes: `inline` (Task 2), `split` (Task 3), `core.events.emit`.
- Produces:
  - `M.mode` — table `{ [bufnr] = "normal"|"inline"|"split" }`.
  - `M.set(core, bufnr, mode)` — validates `mode` ∈ `{normal, inline, split}` (otherwise error/no-op); clears the previous view according to `M.mode[bufnr]` (`inline.clear` if it was `inline`, `split.close` if it was `split`); applies the new one (`inline.render` if `inline`, `split.open` if `split`, nothing if `normal`); updates `M.mode[bufnr]`; emits `view:changed` with `{ bufnr, mode }`. Idempotent: if `mode` == current `M.mode[bufnr]`, it does not reapply or re-emit (no-op).
  - `M.setup(core, opts)` — initializes `M.mode = {}`, requires `commands.lua` (Task 5) and invokes it with `commands.setup(core, opts, M)`. It self-registers: `require("review.core").registry.register({ name = "views", setup = M.setup })`.

- [ ] **Step 1: Failing test — `tests/views/init_spec.lua`**

```lua
local views = require("review.features.views")

local function fake_core()
  local emitted = {}
  return {
    ns = { views = 1 },
    git = {
      rel_path = function() return nil end, -- outside git: inline/split will be a safe no-op
      root = function() return nil end,
      head_content = function() return nil end,
    },
    events = {
      emit = function(name, payload) table.insert(emitted, { name = name, payload = payload }) end,
    },
    _emitted = emitted,
  }
end

describe("views.set", function()
  local core, bufnr

  before_each(function()
    core = fake_core()
    views.mode = {}
    bufnr = vim.api.nvim_create_buf(false, true)
  end)

  it("normal by default if it was never set", function()
    assert.is_nil(views.mode[bufnr])
  end)

  it("set applies and stores the mode, emits view:changed", function()
    views.set(core, bufnr, "inline")
    assert.are.equal("inline", views.mode[bufnr])
    assert.are.equal(1, #core._emitted)
    assert.are.equal("view:changed", core._emitted[1].name)
    assert.are.same({ bufnr = bufnr, mode = "inline" }, core._emitted[1].payload)
  end)

  it("toggling to the same mode is idempotent (does not re-emit)", function()
    views.set(core, bufnr, "inline")
    views.set(core, bufnr, "inline")
    assert.are.equal(1, #core._emitted)
  end)

  it("switching from inline to split clears inline and applies split", function()
    views.set(core, bufnr, "inline")
    views.set(core, bufnr, "split")
    assert.are.equal("split", views.mode[bufnr])
    assert.are.equal(2, #core._emitted)
  end)

  it("invalid mode does not change the state", function()
    views.set(core, bufnr, "inline")
    views.set(core, bufnr, "bogus")
    assert.are.equal("inline", views.mode[bufnr])
    assert.are.equal(1, #core._emitted)
  end)

  it("going back to normal clears the previous view", function()
    views.set(core, bufnr, "inline")
    views.set(core, bufnr, "normal")
    assert.are.equal("normal", views.mode[bufnr])
  end)
end)
```

- [ ] **Step 2: Run and watch it fail**

Run: `cd ~/Dev/nvim/review.nvim && nvim --headless -c "PlenaryBustedFile tests/views/init_spec.lua" -c "qa"`
Expected: FAIL (`module 'review.features.views' not found`).

- [ ] **Step 3: Implement `lua/review/features/views/init.lua`**

```lua
local inline = require("review.features.views.inline")
local split = require("review.features.views.split")

local M = {}
M.mode = {}

local VALID_MODES = { normal = true, inline = true, split = true }

local function clear_current(core, bufnr, current)
  if current == "inline" then
    inline.clear(core, bufnr)
  elseif current == "split" then
    split.close(core, bufnr)
  end
end

local function apply(core, bufnr, mode)
  if mode == "inline" then
    inline.render(core, bufnr)
  elseif mode == "split" then
    split.open(core, bufnr)
  end
  -- "normal": nothing to apply, the buffer looks as usual.
end

--- Changes the view mode of bufnr. Clears the previous view before applying
--- the new one. Idempotent if mode == current mode. No-op if mode is invalid.
function M.set(core, bufnr, mode)
  if not VALID_MODES[mode] then return end
  local current = M.mode[bufnr] or "normal"
  if current == mode then return end

  clear_current(core, bufnr, current)
  apply(core, bufnr, mode)
  M.mode[bufnr] = mode

  core.events.emit("view:changed", { bufnr = bufnr, mode = mode })
end

function M.setup(core, opts)
  M.mode = {}
  -- Clear the per-buffer state when the buffer is destroyed, so that
  -- Neovim does not recycle its bufnr with an inherited mode (stale-state bug).
  vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
    group = vim.api.nvim_create_augroup("ReviewViews", { clear = true }),
    callback = function(a)
      M.mode[a.buf] = nil
      split.close(core, a.buf)
    end,
  })
  local commands = require("review.features.views.commands")
  commands.setup(core, opts, M)
end

require("review.core").registry.register({ name = "views", setup = M.setup })

return M
```

- [ ] **Step 4: Run and watch it pass** (it would fail until Task 5 because `commands.setup` does not exist — the `require` is lazy inside `M.setup`, which is not called in the test, so it should already pass)

Run: `cd ~/Dev/nvim/review.nvim && nvim --headless -c "PlenaryBustedFile tests/views/init_spec.lua" -c "qa"`
Expected: PASS (6).

- [ ] **Step 5: Commit**

```bash
cd ~/Dev/nvim/review.nvim && git add -A
git commit -q -m "feat(views): per-buffer state, set(bufnr, mode) with cleanup and view:changed event"
```

---

### Task 5: `commands.lua` — `:ReviewView`/`:Rv` + cycling keymap

**Files:**
- Create: `lua/review/features/views/commands.lua`

**Interfaces:**
- Consumes: `M` (module from Task 4, passed as a parameter to avoid a circular require).
- Produces: `commands.setup(core, opts, views_mod)` — registers:
  - `:ReviewView {normal|inline|split}` and alias `:Rv` (both real commands, `nargs = 1` + `complete` over the 3 values); they call `views_mod.set(core, vim.api.nvim_get_current_buf(), arg)`. The lowercase `rv` is resolved by `plugin/review.lua`.
  - Keymap `(opts.leader or "<leader>r") .. "v"` in normal mode that cycles `normal → inline → split → normal` over the current buffer.

- [ ] **Step 1: Implement `lua/review/features/views/commands.lua`**

```lua
local M = {}

local ORDER = { "normal", "inline", "split" }

local function next_mode(current)
  for i, m in ipairs(ORDER) do
    if m == current then
      return ORDER[i % #ORDER + 1]
    end
  end
  return ORDER[1]
end

function M.setup(core, opts, views_mod)
  opts = opts or {}
  local leader = opts.leader or "<leader>r"

  local function run(cmd_opts)
    local mode = cmd_opts.args
    if mode == "" then
      vim.notify("usage: :ReviewView {normal|inline|split}", vim.log.levels.ERROR)
      return
    end
    views_mod.set(core, vim.api.nvim_get_current_buf(), mode)
  end

  local ucmd_opts = {
    nargs = 1,
    complete = function() return ORDER end,
  }
  -- Long command + short alias, both real commands. The lowercase `rv`
  -- is resolved by plugin/review.lua (core Task 7) via cnoreabbrev → Rv.
  vim.api.nvim_create_user_command("ReviewView", run, ucmd_opts)
  vim.api.nvim_create_user_command("Rv", run, vim.deepcopy(ucmd_opts))

  vim.keymap.set("n", leader .. "v", function()
    local bufnr = vim.api.nvim_get_current_buf()
    local current = views_mod.mode[bufnr] or "normal"
    views_mod.set(core, bufnr, next_mode(current))
  end, { desc = "review.nvim: cycle view normal/inline/split" })
end

return M
```

- [ ] **Step 2: Manual verification — commands and keymap**

1. `cd ~/Dev/nvim/review.nvim`, edit a file with uncommitted changes (or create a new one and modify a line).
2. `nvim --headless` is no use for this: open regular Neovim with `nvim -u NONE -c "set rtp+=." -c "lua require('review').setup()"` on the modified file.
3. `:ReviewView inline` → deleted lines should show as `virt_lines` with a red background above their position, and added lines highlighted with `DiffAdd` across the whole line. The buffer is still editable (type something and confirm that it enters insert mode normally).
4. `:ReviewView split` → a window opens on the left with the HEAD content (readonly, with deleted lines highlighted in red); the right window remains the real, editable buffer.
5. `:ReviewView normal` → the left panel closes and the inline decorations disappear; only 1 column is left, buffer intact.
6. Repeat `:ReviewView inline` twice in a row (same mode) → it must not duplicate extmarks or flicker.
7. Try `<leader>rv` repeatedly → it must cycle `normal → inline → split → normal → ...`.
8. Try a file **without** changes vs HEAD → `:ReviewView inline` must paint nothing and raise no error (no-op).
9. Try a new file (`git add` without commit, no HEAD) → `:ReviewView split` must show the warning `vim.notify` and **not** open a panel.
10. `:Rv inline` (alias) must behave the same as `:ReviewView inline`.
11. **Pure-delete hunk:** delete some lines (without adding) and `:ReviewView inline` → confirm that the red `virt_lines` appear in the right position (right where the deleted lines were, not shifted by one line). If they appear shifted, adjust `anchor_lnum`/`virt_lines_above` in `inline.lua` (the `git diff -U0` convention for `@@ -N,M +K,0 @@` is that `K` points to the context line before the deletion).
12. **New (untracked) file in inline:** `:ReviewView inline` on a file without HEAD → silent no-op (git diff does not compare it); confirm that it does not break (known limitation: it does not mark "everything new").
13. **Split in two different buffers:** open buffer A with changes → `:ReviewView split`; without closing, go to buffer B with changes → `:ReviewView split`; go back to A → `:ReviewView normal`. Confirm that each panel corresponds to its buffer and no windows are left dangling (validates the per-buffer state of `_panels`).

- [ ] **Step 3: Commit**

```bash
cd ~/Dev/nvim/review.nvim && git add -A
git commit -q -m "feat(views/commands): :ReviewView/:Rv + cycling <leader>rv keymap"
```

---

### Task 6: Full feature suite

**Files:**
- Creates no new files.

- [ ] **Step 1: Run the whole `views` suite**

Run: `cd ~/Dev/nvim/review.nvim && nvim --headless -c "PlenaryBustedDirectory tests/views/ {minimal_init='tests/minimal_init.lua'}" -c "qa"`
Expected: PASS (diff 5, init 6).

- [ ] **Step 2: Run the plugin's full suite (do not break core)**

Run: `cd ~/Dev/nvim/review.nvim && nvim --headless -c "PlenaryBustedDirectory tests/ {minimal_init='tests/minimal_init.lua'}" -c "qa"`
Expected: all `core` and `views` specs PASS.

- [ ] **Step 3: Final commit (if there were pending fixture/adjustment changes)**

```bash
cd ~/Dev/nvim/review.nvim && git add -A
git commit -q -m "test(views): full-suite verification of the slice"
```

---

## Self-Review

- **Contract coverage (DESIGN.md):** `git.head_content` ✅ (Task 3, `split.open`), `git.changed_files` — **not** consumed directly by `views` (used by `sidebar`; `views` only needs `rel_path`/`root`/`head_content` for the active file), `ns.views` ✅ (Task 2/3, the only namespace used, cleared on every `set`), `events.emit("view:changed", {bufnr, mode})` ✅ (Task 4). Modes `normal/inline/split` ✅ (Task 4). `:ReviewView`/`:Rv` ✅ (Task 5, matches the DESIGN command table).
- **Dependency rule:** no `views` module does `require("review.features.*")` of another feature; only `require("review.core")` (via `M.setup(core, opts)`) and internal submodules of the slice itself.
- **Placeholders:** none — all the Lua code is complete and executable.
- **Edge cases covered:**
  - File without changes → `inline.render` no-op (Task 2, an empty or `nil` `hunks` cuts out before painting).
  - New file without HEAD → `split.open` warns and does not open (Task 3, `head_content == nil` check).
  - Toggling to the same mode → idempotent no-op, does not re-emit the event (Task 4, test "toggling to the same mode is idempotent").
  - Mode change → the previous view is cleared before applying the new one, no decoration/window is ever left dangling (Task 4, `clear_current` before `apply`).
  - Editing the real buffer → `nvim_buf_set_lines` is never called on the user's buffer in `inline`/`split`; only extmarks and a window with a separate scratch buffer.
- **Testing:** pure part (`diff.parse_unified_diff`, `diff.hunks_for` with `git_root=nil`) and state transitions (`M.set`) covered with specs; real UI (virt_lines, visual vsplit, notify) delegated to explicit manual verification in Task 5 Step 2, with concrete and reproducible steps.
