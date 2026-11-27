# review.nvim — Plan 05: Agent (RPC bridge + AUTO reconciliation)

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development or superpowers:executing-plans. Steps use checkboxes (`- [ ]`).
> **Master design:** `docs/roadmap.md` §1 (source of truth, supersedes the old plan 05) + "`core` contract" in `docs/plans/00-core.md`. Every core signature cited here **must** match `00-core.md`.

**Goal:** Let an external agent (Claude Code, a script, etc.) **read, comment, reply to,
resolve, update and clean up** review comments on the **same** Neovim instance that the
human uses, speaking Neovim's native RPC (`--remote-expr`), without custom sockets. And when the
agent **edits code on disk** (with its own tools, **outside** nvim), Neovim must **reload the
buffer and re-anchor the comments automatically**, without overwriting the human's unsaved changes.

**Architecture:** The agent writes the code **freely** to disk; review.nvim does not edit code.
Only the comments go through nvim (via `core.state`, the single source of truth). The problem is not
"editing without collisions" (the agent handles that on disk), but **finding out about the change on disk,
reloading the buffer with a minimal **patch** (not `:edit!`) and letting the extmarks re-anchor themselves by
gravity**. Two slices are touched:

- `features/comments/` — extended: capture `anchor_text` on creation, mark `stale`, distinguish
  authorship and threading in render/gutter/peek, list filters by author/answered, and a
  `render.reconcile` that re-syncs positions + marks stale (it reacts to an event, without knowing
  the agent).
- `features/agent/` — new: `reconcile.lua` (minimal diff patch, the heart), `watch.lua`
  (`vim.uv.fs_event` watcher + debounce), `rpc.lua` (serializable API over `core.state`),
  `init.lua` (`_G.ReviewAgent`, `opts.enabled`, wires up the watcher). Disabled by default.

**Coordination between slices = only events** (hard rule of the core): `agent/reconcile` emits
`buffer:reconciled {bufnr}`; `comments` subscribes and re-syncs. Neither does
`require("review.features.<other>")`.

**Tech Stack:** Lua, Neovim ≥ 0.10 (`vim.diff` result_type=indices, `vim.uv.new_fs_event`,
`vim.json`, `v:servername`, `--remote-expr`), plenary.nvim (busted tests).

## Global Constraints

- **The code is written by the agent on disk, never by review.nvim.** This plan never calls
  `nvim_buf_set_lines` to "apply agent changes" except inside `reconcile.patch`, which
  copies disk→buffer as a minimal patch to preserve extmarks (it is not editing, it is reloading).
- No feature does `require("review.features.<other>")`. Only `require("review.core")`.
  Coordination = `core.events`.
- Never overwrite unsaved changes: if `vim.bo[bufnr].modified`, `reconcile.patch` does **not** apply and warns.
- All functions exposed to the agent are **serializable**: they receive/return `string` (JSON) or
  primitives. `list()`/`get()` **never** include `_extmark_id` (runtime-only).
- Every mutation from the agent (`add/reply/resolve/unresolve/update/delete/clean_resolved`) persists
  immediately (`core.state.persist()`).
- Feature **disabled by default**: `_G.ReviewAgent` and the watcher are only mounted if
  `features.agent = { enabled = true }`.
- The `vim.uv.fs_event` watchers are closed on `BufWipeout`/`BufDelete` (no leaks, like the other
  caches — see `performance.md`).
- Model backwards compatibility: the new fields (`reply_to`, `anchor_text`, `stale`) are
  optional; `state.persist` already copies every field that is not `_extmark_id`, so they persist on their own.
  Old JSON without those fields still loads (defaults `nil`/`false`).
- Tests: `nvim --headless -c "PlenaryBustedFile tests/agent/<spec>.lua" -c "qa"`. Full suite:
  `nvim --headless -c "PlenaryBustedDirectory tests/ {minimal_init='tests/minimal_init.lua'}" -c "qa"`.

---

### Task 1: `core.state` — threading helpers (`replies`, `thread`) + round-trip of new fields

**Files:**
- Modify: `lua/review/core/state.lua`
- Modify: `tests/core/state_spec.lua`

**Interfaces:**
- Consumes: `state.all()`, `state.by_id(id)` (already exist).
- Produces:
  - `state.replies(id)` → `comment[]` — comments whose `reply_to == id`, in insertion order.
  - `state.thread(id)` → `comment[]` — `{ parent, ...replies }` (parent first); `{}` if `id` does not exist.
  - Confirmation (test) that `reply_to`/`anchor_text`/`stale` survive `persist()`/`load()`.

- [ ] **Step 1: Add tests at the end of `tests/core/state_spec.lua`** (inside the existing `describe`, or a new `describe`)

```lua
describe("core.state threading + new fields", function()
  before_each(function()
    local tmp = vim.fn.tempname(); vim.fn.mkdir(tmp, "p")
    store.root_fn = function() return tmp end
    state._reset()
  end)

  it("replies(id) returns only the children of that comment", function()
    local parent = state.add({ path = "a.ts", lnum = 1, text = "question" })
    state.add({ path = "a.ts", lnum = 1, text = "reply 1", reply_to = parent.id, author = "agent" })
    state.add({ path = "a.ts", lnum = 1, text = "reply 2", reply_to = parent.id, author = "agent" })
    state.add({ path = "a.ts", lnum = 2, text = "another top-level" })
    local r = state.replies(parent.id)
    assert.are.equal(2, #r)
    assert.are.equal("reply 1", r[1].text)
  end)

  it("thread(id) returns the parent followed by its replies", function()
    local parent = state.add({ path = "a.ts", lnum = 1, text = "question" })
    state.add({ path = "a.ts", lnum = 1, text = "reply", reply_to = parent.id })
    local t = state.thread(parent.id)
    assert.are.equal(2, #t)
    assert.are.equal(parent.id, t[1].id)
  end)

  it("thread(id) for a nonexistent id returns an empty list", function()
    assert.are.same({}, state.thread("does-not-exist"))
  end)

  it("reply_to/anchor_text/stale survive persist + load", function()
    local p = state.add({ path = "a.ts", lnum = 3, text = "x", anchor_text = "const foo = 1" })
    state.add({ path = "a.ts", lnum = 3, text = "y", reply_to = p.id, author = "agent" })
    state.update(p.id, { stale = true })
    state.persist(); state._reset(); state.load()
    local loaded = state.by_id(p.id)
    assert.are.equal("const foo = 1", loaded.anchor_text)
    assert.is_true(loaded.stale)
    assert.are.equal(1, #state.replies(p.id))
  end)
end)
```

- [ ] **Step 2: Run and watch it fail**

Run: `cd ~/Dev/nvim/review.nvim && nvim --headless -c "PlenaryBustedFile tests/core/state_spec.lua" -c "qa"`
Expected: FAIL (`attempt to call field 'replies' (a nil value)`).

- [ ] **Step 3: Implement `replies`/`thread` in `lua/review/core/state.lua`** (add before `return M`)

```lua
--- Comments that reply to `id` (reply_to == id), in insertion order.
function M.replies(id)
  local out = {}
  for _, c in ipairs(list) do
    if c.reply_to == id then out[#out + 1] = c end
  end
  return out
end

--- Full thread of a comment: the parent first, then its replies.
--- Empty list if `id` does not exist.
function M.thread(id)
  local parent = M.by_id(id)
  if not parent then return {} end
  local out = { parent }
  for _, c in ipairs(M.replies(id)) do out[#out + 1] = c end
  return out
end
```

- [ ] **Step 4: Run and watch it pass**

Run: `cd ~/Dev/nvim/review.nvim && nvim --headless -c "PlenaryBustedFile tests/core/state_spec.lua" -c "qa"`
Expected: PASS (the previous ones + 4 new).

- [ ] **Step 5: Commit**

```bash
cd ~/Dev/nvim/review.nvim && git add -A
git commit -q -m "feat(core/state): threading helpers (replies/thread) for agent comments"
```

---

### Task 2: `comments` — capture `anchor_text` on creation + `render.reconcile` (sync + stale)

**Files:**
- Modify: `lua/review/features/comments/mode.lua` (capture `anchor_text` in `_add`)
- Modify: `lua/review/features/comments/render.lua` (add `render.reconcile`)
- Modify: `tests/comments/mode_spec.lua`
- Modify: `tests/comments/render_spec.lua`

**Interfaces:**
- Consumes: `core.git.rel_path`, `core.state.for_path`, `core.state.update`, `core.ns.comments`.
- Produces:
  - `mode._add(...)` now stores `anchor_text` = text of line `lnum` of the buffer (or `""` if there
    is none). It is the safety net to detect uncertain re-anchoring (roadmap §1.3).
  - `render.reconcile(core, bufnr)` — runs `sync_positions` (already exists) and then, for each comment
    with `anchor_text`, marks `stale = true` if the extmark's current line NO longer contains that text
    (or un-marks it if it matches again). Re-renders. Meant to be called after a disk patch.

- [ ] **Step 1: Test in `tests/comments/mode_spec.lua`** (add inside the existing describe)

```lua
  it("_add captures anchor_text of the commented line", function()
    local c = mode._add(core, bufnr, 3, 3, "watch out for l3")
    assert.are.equal("l3", c.anchor_text)
  end)
```

- [ ] **Step 2: Test in `tests/comments/render_spec.lua`** (add inside the existing describe)

```lua
  it("reconcile marks stale when the anchored line no longer matches", function()
    local c = state.add({ path = "foo.ts", lnum = 2, text = "x", anchor_text = "l2" })
    render.render(core, bufnr)
    -- the agent rewrote that line on disk (we simulate the result in the buffer)
    vim.api.nvim_buf_set_lines(bufnr, 1, 2, false, { "COMPLETELY DIFFERENT" })
    render.reconcile(core, bufnr)
    assert.is_true(state.by_id(c.id).stale)
  end)

  it("reconcile un-marks stale if the line matches again", function()
    local c = state.add({ path = "foo.ts", lnum = 2, text = "x", anchor_text = "l2", stale = true })
    render.render(core, bufnr)
    render.reconcile(core, bufnr)  -- line 2 is still "l2"
    assert.is_false(state.by_id(c.id).stale)
  end)

  it("reconcile does not mark stale if the comment has no anchor_text", function()
    local c = state.add({ path = "foo.ts", lnum = 2, text = "x" })
    render.render(core, bufnr)
    render.reconcile(core, bufnr)
    assert.is_nil(state.by_id(c.id).stale)
  end)
```

- [ ] **Step 3: Capture `anchor_text` in `mode._add`** (`lua/review/features/comments/mode.lua`)

In `M._add`, right before `local c = core.state.add({ ... })`, compute the text of the anchor line
and pass it:

```lua
  local anchor_text = ""
  do
    local lines = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)
    anchor_text = lines[1] or ""
  end

  local c = core.state.add({ path = rel, lnum = lnum, end_lnum = end_lnum, text = text, anchor_text = anchor_text })
```

(it replaces the line `local c = core.state.add({ path = rel, lnum = lnum, end_lnum = end_lnum, text = text })`).

- [ ] **Step 4: Implement `render.reconcile`** (`lua/review/features/comments/render.lua`, before `return M`)

```lua
--- Re-syncs positions from the extmarks and marks as `stale` the comments
--- whose anchored line stopped matching its `anchor_text` (safety net
--- after a code change on disk). Un-marks those that match again.
--- No-op if the buffer is outside the repo.
function M.reconcile(core, bufnr)
  local rel = core.git.rel_path(bufnr)
  if not rel then return end

  M.sync_positions(core, bufnr)

  local last = vim.api.nvim_buf_line_count(bufnr)
  for _, c in ipairs(core.state.for_path(rel)) do
    if c.anchor_text and c.anchor_text ~= "" then
      local row = (c.lnum or 1) - 1
      local now = ""
      if row >= 0 and row < last then
        now = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ""
      end
      -- it matches if the current line contains the anchor text (tolerant of
      -- reindentation/whitespace: we compare trims).
      local matches = vim.trim(now) == vim.trim(c.anchor_text)
      if matches and c.stale then
        core.state.update(c.id, { stale = false })
      elseif not matches and not c.stale then
        core.state.update(c.id, { stale = true })
      end
    end
  end

  M.render(core, bufnr)
end
```

- [ ] **Step 5: Run and watch it pass**

Run: `cd ~/Dev/nvim/review.nvim && nvim --headless -c "PlenaryBustedFile tests/comments/mode_spec.lua" -c "qa" && nvim --headless -c "PlenaryBustedFile tests/comments/render_spec.lua" -c "qa"`
Expected: PASS (mode: previous + 1; render: previous + 3).

- [ ] **Step 6: Commit**

```bash
cd ~/Dev/nvim/review.nvim && git add -A
git commit -q -m "feat(comments): capture anchor_text on creation + render.reconcile (sync + stale mark)"
```

---

### Task 3: `agent/reconcile.lua` — minimal diff patch (the heart)

**Files:**
- Create: `lua/review/features/agent/reconcile.lua`, `tests/agent/reconcile_spec.lua`

**Interfaces:**
- Consumes: `core.git.rel_path`, `core.events.emit`.
- Produces:
  - `reconcile.patch(core, bufnr)` → `"applied"|"identical"|"conflict"|"skipped"` — reads the file from
    disk and applies only the hunks (`vim.diff` result_type=indices) to the buffer with `nvim_buf_set_lines`
    from bottom to top, preserving the extmarks (they re-anchor themselves by gravity). Leaves the buffer
    `nomodified`. If the buffer has unsaved changes (`modified`) → it does **not** apply, returns
    `"conflict"`. If disk == buffer → `"identical"`. Outside the repo / without a name / without an extmark →
    `"skipped"`. After applying, it emits `buffer:reconciled { bufnr = bufnr }`.

- [ ] **Step 1: Failing test — `tests/agent/reconcile_spec.lua`**

```lua
local store = require("review.core.store")
local state = require("review.core.state")
local git = require("review.core.git")
local ns = require("review.core.ns")
local events = require("review.core.events")
local reconcile = require("review.features.agent.reconcile")

local core = { state = state, git = git, ns = ns, events = events }

local function write_file(path, lines)
  vim.fn.writefile(lines, path)
end

describe("agent.reconcile.patch", function()
  local root, path, bufnr

  before_each(function()
    root = vim.fn.tempname(); vim.fn.mkdir(root, "p")
    store.root_fn = function() return root end
    state._reset()
    events._reset()
    path = root .. "/foo.ts"
    write_file(path, { "l1", "l2", "l3", "l4", "l5" })
    bufnr = vim.fn.bufadd(path)
    vim.fn.bufload(bufnr)
    vim.bo[bufnr].modified = false
  end)

  it("identical if disk == buffer", function()
    assert.are.equal("identical", reconcile.patch(core, bufnr))
  end)

  it("conflict if the buffer has unsaved changes", function()
    vim.api.nvim_buf_set_lines(bufnr, 0, 0, false, { "unsaved" })
    assert.is_true(vim.bo[bufnr].modified)
    write_file(path, { "l1", "l2", "l3", "l4", "l5", "l6" })
    assert.are.equal("conflict", reconcile.patch(core, bufnr))
  end)

  it("applied: insertion above shifts the extmark and the buffer ends up nomodified", function()
    -- comment extmark on line 3 (row 2)
    local id = vim.api.nvim_buf_set_extmark(bufnr, ns.comments, 2, 0, {})
    -- the agent inserted a line at the start on disk
    write_file(path, { "NEW", "l1", "l2", "l3", "l4", "l5" })
    assert.are.equal("applied", reconcile.patch(core, bufnr))
    -- the buffer reflects the disk
    assert.are.same(
      { "NEW", "l1", "l2", "l3", "l4", "l5" },
      vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    )
    -- the extmark moved down from row 2 to row 3 (gravity)
    local pos = vim.api.nvim_buf_get_extmark_by_id(bufnr, ns.comments, id, {})
    assert.are.equal(3, pos[1])
    assert.is_false(vim.bo[bufnr].modified)
  end)

  it("applied: a modification in the middle does not move earlier extmarks", function()
    local id = vim.api.nvim_buf_set_extmark(bufnr, ns.comments, 0, 0, {})
    write_file(path, { "l1", "l2", "l3-MOD", "l4", "l5" })
    assert.are.equal("applied", reconcile.patch(core, bufnr))
    local pos = vim.api.nvim_buf_get_extmark_by_id(bufnr, ns.comments, id, {})
    assert.are.equal(0, pos[1])
    assert.are.equal("l3-MOD", vim.api.nvim_buf_get_lines(bufnr, 2, 3, false)[1])
  end)

  it("emits buffer:reconciled when applying", function()
    local fired = nil
    events.on("buffer:reconciled", function(p) fired = p.bufnr end)
    write_file(path, { "l1", "l2", "l3", "l4", "l5", "l6" })
    reconcile.patch(core, bufnr)
    vim.wait(50, function() return fired ~= nil end)
    assert.are.equal(bufnr, fired)
  end)
end)
```

- [ ] **Step 2: Run and watch it fail**

Run: `cd ~/Dev/nvim/review.nvim && nvim --headless -c "PlenaryBustedFile tests/agent/reconcile_spec.lua" -c "qa"`
Expected: FAIL ("module 'review.features.agent.reconcile' not found").

- [ ] **Step 3: Implement `lua/review/features/agent/reconcile.lua`**

```lua
local M = {}

--- Applies the disk content to the buffer as a minimal patch (not `:edit!`), so
--- that the extmarks (and therefore the anchored comments) re-anchor themselves
--- by gravity. Never overwrites the human's unsaved changes.
--- @return "applied"|"identical"|"conflict"|"skipped"
function M.patch(core, bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then return "skipped" end
  local rel = core.git.rel_path(bufnr)
  if not rel then return "skipped" end

  local name = vim.api.nvim_buf_get_name(bufnr)
  if name == "" then return "skipped" end

  -- Conflict: there are unsaved edits → do not overwrite (see roadmap §1.3.3).
  if vim.bo[bufnr].modified then return "conflict" end

  local ok, disk = pcall(vim.fn.readfile, name)
  if not ok or type(disk) ~= "table" then return "skipped" end

  local buf_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local a = table.concat(buf_lines, "\n")
  local b = table.concat(disk, "\n")
  if a == b then return "identical" end

  local hunks = vim.diff(a, b, { result_type = "indices" })
  if not hunks or #hunks == 0 then return "identical" end

  -- Apply from bottom to top so as not to invalidate the indices of the upper
  -- hunks. Each hunk = { start_a, count_a, start_b, count_b } (1-based in a
  -- and b; count==0 marks a pure insertion/deletion with start = previous line).
  for i = #hunks, 1, -1 do
    local h = hunks[i]
    local start_a, count_a, start_b, count_b = h[1], h[2], h[3], h[4]

    local repl = {}
    for j = start_b, start_b + count_b - 1 do
      repl[#repl + 1] = disk[j]
    end

    local s, e
    if count_a == 0 then
      -- insertion: `start_a` is the line (1-based) after which to insert;
      -- in 0-based that is the index `start_a` (set_lines(start_a, start_a, ...)).
      s = start_a
      e = start_a
    else
      s = start_a - 1
      e = start_a - 1 + count_a
    end
    vim.api.nvim_buf_set_lines(bufnr, s, e, false, repl)
  end

  vim.bo[bufnr].modified = false
  core.events.emit("buffer:reconciled", { bufnr = bufnr })
  return "applied"
end

return M
```

- [ ] **Step 4: Run and watch it pass**

Run: `cd ~/Dev/nvim/review.nvim && nvim --headless -c "PlenaryBustedFile tests/agent/reconcile_spec.lua" -c "qa"`
Expected: PASS (5).

- [ ] **Step 5: Subscribe `comments` to `buffer:reconciled`** (`lua/review/features/comments/init.lua`, inside `M.setup`, after the existing autocmds)

```lua
  -- The agent (or anyone) edited the file on disk and reconcile applied the
  -- patch to the buffer; we re-sync positions and mark the doubtful ones as stale.
  core.events.on("buffer:reconciled", function(payload)
    if payload and payload.bufnr and vim.api.nvim_buf_is_valid(payload.bufnr) then
      render.reconcile(core, payload.bufnr)
    end
  end)
```

- [ ] **Step 6: Event integration test — add to `tests/comments/init_spec.lua`**

```lua
  it("buffer:reconciled triggers render.reconcile and re-syncs positions", function()
    comments.setup(core, { leader = "<leader>r" })
    local events = require("review.core.events")
    local c = state.add({ path = "foo.ts", lnum = 2, text = "x", anchor_text = "l2" })
    require("review.features.comments.render").render(core, bufnr)
    vim.api.nvim_set_current_buf(bufnr)
    -- we simulate that reconcile already applied a patch: a line was inserted above
    vim.api.nvim_buf_set_lines(bufnr, 0, 0, false, { "new" })
    events.emit("buffer:reconciled", { bufnr = bufnr })
    vim.wait(50)
    assert.are.equal(3, state.by_id(c.id).lnum)  -- 2 -> 3
  end)
```

- [ ] **Step 7: Run the comments + agent suite**

Run: `cd ~/Dev/nvim/review.nvim && nvim --headless -c "PlenaryBustedDirectory tests/comments {minimal_init='tests/minimal_init.lua'}" -c "qa" && nvim --headless -c "PlenaryBustedFile tests/agent/reconcile_spec.lua" -c "qa"`
Expected: PASS.

- [ ] **Step 8: Commit**

```bash
cd ~/Dev/nvim/review.nvim && git add -A
git commit -q -m "feat(agent): reconcile.patch (minimal diff patch) + comments reacts to buffer:reconciled"
```

---

### Task 4: `agent/watch.lua` — disk watcher with debounce + cleanup

**Files:**
- Create: `lua/review/features/agent/watch.lua`
- Create: `tests/agent/watch_spec.lua`

**Interfaces:**
- Consumes: `reconcile.patch` (Task 3), `core.git.rel_path`.
- Produces:
  - `watch.attach(core, bufnr)` — if the buffer is a file of the repo (`rel_path ~= nil`) and has no
    watcher, creates a `vim.uv.new_fs_event` on its file; on each event it debounces (~150 ms) and
    runs `reconcile.patch(core, bufnr)` inside `vim.schedule` (buffer APIs are not safe
    in the libuv callback). Idempotent.
  - `watch.detach(bufnr)` — closes and forgets the buffer's watcher. Idempotent.
  - `watch.detach_all()` — closes all of them (for tests / teardown).
  - `watch._debounce_ms` — overridable in tests.

- [ ] **Step 1: Failing test — `tests/agent/watch_spec.lua`**

```lua
local store = require("review.core.store")
local state = require("review.core.state")
local git = require("review.core.git")
local ns = require("review.core.ns")
local events = require("review.core.events")
local watch = require("review.features.agent.watch")

local core = { state = state, git = git, ns = ns, events = events }

describe("agent.watch", function()
  local root, path, bufnr

  before_each(function()
    root = vim.fn.tempname(); vim.fn.mkdir(root, "p")
    store.root_fn = function() return root end
    state._reset(); events._reset()
    watch.detach_all()
    watch._debounce_ms = 30
    path = root .. "/foo.ts"
    vim.fn.writefile({ "l1", "l2", "l3" }, path)
    bufnr = vim.fn.bufadd(path); vim.fn.bufload(bufnr)
    vim.bo[bufnr].modified = false
  end)

  after_each(function() watch.detach_all() end)

  it("attach is a no-op for buffers outside the repo", function()
    local other = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(other, "/outside/x.ts")
    assert.has_no.errors(function() watch.attach(core, other) end)
    assert.is_false(watch._has(other))
  end)

  it("attach creates a watcher and detach closes it", function()
    watch.attach(core, bufnr)
    assert.is_true(watch._has(bufnr))
    watch.detach(bufnr)
    assert.is_false(watch._has(bufnr))
  end)

  it("when the file changes on disk, it reconciles the buffer (debounced)", function()
    watch.attach(core, bufnr)
    local reconciled = false
    events.on("buffer:reconciled", function() reconciled = true end)
    -- the agent writes to disk
    vim.fn.writefile({ "l1", "l2", "l3", "l4" }, path)
    vim.wait(1000, function() return reconciled end)
    assert.is_true(reconciled)
    assert.are.same({ "l1", "l2", "l3", "l4" }, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
  end)
end)
```

- [ ] **Step 2: Run and watch it fail**

Run: `cd ~/Dev/nvim/review.nvim && nvim --headless -c "PlenaryBustedFile tests/agent/watch_spec.lua" -c "qa"`
Expected: FAIL ("module 'review.features.agent.watch' not found").

- [ ] **Step 3: Implement `lua/review/features/agent/watch.lua`**

```lua
local reconcile = require("review.features.agent.reconcile")

local uv = vim.uv or vim.loop

-- _watchers[bufnr] = { fs = <fs_event>, timer = <uv_timer|nil> }
local M = { _watchers = {}, _debounce_ms = 150 }

function M._has(bufnr)
  return M._watchers[bufnr] ~= nil
end

--- Runs reconcile.patch on the main thread (buffer APIs are not safe
--- inside the libuv callback).
local function run_patch(core, bufnr)
  vim.schedule(function()
    if vim.api.nvim_buf_is_valid(bufnr) then
      reconcile.patch(core, bufnr)
    end
  end)
end

function M.attach(core, bufnr)
  if M._watchers[bufnr] then return end
  if not vim.api.nvim_buf_is_valid(bufnr) then return end
  local rel = core.git.rel_path(bufnr)
  if not rel then return end
  local path = vim.api.nvim_buf_get_name(bufnr)
  if path == "" then return end

  local fs = uv.new_fs_event()
  if not fs then return end
  local entry = { fs = fs, timer = nil }
  M._watchers[bufnr] = entry

  local ok = pcall(function()
    fs:start(path, {}, function(err)
      if err then return end
      -- Debounce: group the agent's write bursts into a single patch.
      if entry.timer then
        entry.timer:stop()
        entry.timer:close()
        entry.timer = nil
      end
      local t = uv.new_timer()
      entry.timer = t
      t:start(M._debounce_ms, 0, function()
        t:stop(); t:close(); entry.timer = nil
        -- Some editors replace the inode (rename); re-arm the watch.
        pcall(function() fs:stop() end)
        pcall(function() fs:start(path, {}, function() end) end)
        run_patch(core, bufnr)
      end)
    end)
  end)
  if not ok then
    M.detach(bufnr)
  end
end

function M.detach(bufnr)
  local entry = M._watchers[bufnr]
  if not entry then return end
  if entry.timer then pcall(function() entry.timer:stop(); entry.timer:close() end) end
  if entry.fs then pcall(function() entry.fs:stop(); entry.fs:close() end) end
  M._watchers[bufnr] = nil
end

function M.detach_all()
  for bufnr in pairs(M._watchers) do
    M.detach(bufnr)
  end
end

return M
```

- [ ] **Step 4: Run and watch it pass**

Run: `cd ~/Dev/nvim/review.nvim && nvim --headless -c "PlenaryBustedFile tests/agent/watch_spec.lua" -c "qa"`
Expected: PASS (3). (The watcher uses the real filesystem; the test writes and waits up to 1 s.)

- [ ] **Step 5: Commit**

```bash
cd ~/Dev/nvim/review.nvim && git add -A
git commit -q -m "feat(agent/watch): fs_event watcher with debounce + leak-free cleanup"
```

---

### Task 5: `agent/rpc.lua` — complete serializable API

**Files:**
- Create: `lua/review/features/agent/rpc.lua`, `tests/agent/rpc_spec.lua`

**Interfaces:**
- Consumes: `core.state.*`, `core.git.rel_path`/`head_content`/`root`, `reconcile.patch` (for
  `notify_changed`).
- Produces (all serializable — they receive/return JSON strings or primitives):
  - `rpc.list(core, filter_json?)` → `string` (JSON array). Optional `filter`:
    `{ author?, path?, resolved?, answered? }`. `answered` filters by having/not having replies.
  - `rpc.get(core, id)` → `string` (JSON of the comment + `replies`), or `"null"`.
  - `rpc.context(core, id)` → `string` (JSON `{ comment, lines }` with the code lines it spans,
    read from HEAD or from disk), or `"null"`.
  - `rpc.add(core, json_or_table)` → `string` (id, or `""`). `author` defaults to `"agent"`.
  - `rpc.reply(core, parent_id, text)` → `string` (id of the reply, or `""` if the parent does not exist).
  - `rpc.resolve(core, id)` / `rpc.unresolve(core, id)` → `boolean`.
  - `rpc.update(core, id, text)` → `boolean`.
  - `rpc.delete(core, id)` → `boolean`.
  - `rpc.clean_resolved(core, path?)` → `number` (how many it deleted).
  - `rpc.is_modified(core, path)` → `boolean` (is there a buffer of that path with unsaved changes?).
  - `rpc.notify_changed(core, path)` → `boolean` (forces `reconcile.patch` of that path's buffer if
    it is open; `false` if it is not open or there was a conflict).

- [ ] **Step 1: Failing test — `tests/agent/rpc_spec.lua`**

```lua
local store = require("review.core.store")
local state = require("review.core.state")
local git = require("review.core.git")
local ns = require("review.core.ns")
local events = require("review.core.events")
local rpc = require("review.features.agent.rpc")

local core = { state = state, git = git, ns = ns, events = events }

describe("features.agent.rpc", function()
  local root
  before_each(function()
    root = vim.fn.tempname(); vim.fn.mkdir(root, "p")
    store.root_fn = function() return root end
    state._reset(); events._reset()
  end)

  it("list() without comments returns []", function()
    assert.are.equal("[]", rpc.list(core))
  end)

  it("list() excludes _extmark_id", function()
    local c = state.add({ path = "a.ts", lnum = 1, text = "x" }); c._extmark_id = 7
    local d = vim.json.decode(rpc.list(core))
    assert.is_nil(d[1]._extmark_id)
  end)

  it("list(filter) filters by author and by answered", function()
    local p = state.add({ path = "a.ts", lnum = 1, text = "mine", author = "user" })
    state.add({ path = "a.ts", lnum = 1, text = "reply", author = "agent", reply_to = p.id })
    state.add({ path = "a.ts", lnum = 2, text = "no reply", author = "user" })

    local mine = vim.json.decode(rpc.list(core, vim.json.encode({ author = "user" })))
    assert.are.equal(2, #mine)
    local answered = vim.json.decode(rpc.list(core, vim.json.encode({ answered = true })))
    assert.are.equal(1, #answered)
    assert.are.equal(p.id, answered[1].id)
    local unanswered = vim.json.decode(rpc.list(core, vim.json.encode({ author = "user", answered = false })))
    assert.are.equal(1, #unanswered)
  end)

  it("add() validates and returns an id; author defaults to agent", function()
    local id = rpc.add(core, { path = "b.ts", lnum = 3, text = "from agent" })
    assert.is_not.equal("", id)
    assert.are.equal("agent", state.by_id(id).author)
  end)

  it("add() with invalid JSON returns ''", function()
    assert.are.equal("", rpc.add(core, "{ broken"))
  end)

  it("reply() links to the parent and inherits its path/lnum", function()
    local p = state.add({ path = "a.ts", lnum = 5, text = "question" })
    local rid = rpc.reply(core, p.id, "because X")
    local r = state.by_id(rid)
    assert.are.equal(p.id, r.reply_to)
    assert.are.equal("a.ts", r.path)
    assert.are.equal(5, r.lnum)
    assert.are.equal("agent", r.author)
  end)

  it("reply() with a nonexistent parent returns ''", function()
    assert.are.equal("", rpc.reply(core, "does-not-exist", "x"))
  end)

  it("get() returns the comment with its replies", function()
    local p = state.add({ path = "a.ts", lnum = 1, text = "question" })
    rpc.reply(core, p.id, "reply")
    local g = vim.json.decode(rpc.get(core, p.id))
    assert.are.equal("question", g.text)
    assert.are.equal(1, #g.replies)
  end)

  it("resolve/unresolve/update/delete", function()
    local c = state.add({ path = "a.ts", lnum = 1, text = "x" })
    assert.is_true(rpc.resolve(core, c.id));   assert.is_true(state.by_id(c.id).resolved)
    assert.is_true(rpc.unresolve(core, c.id)); assert.is_false(state.by_id(c.id).resolved)
    assert.is_true(rpc.update(core, c.id, "new text")); assert.are.equal("new text", state.by_id(c.id).text)
    assert.is_true(rpc.delete(core, c.id));    assert.is_nil(state.by_id(c.id))
  end)

  it("clean_resolved deletes the resolved ones and returns the count", function()
    state.add({ path = "a.ts", lnum = 1, text = "open" })
    local r = state.add({ path = "a.ts", lnum = 2, text = "closed", resolved = true })
    assert.are.equal(1, rpc.clean_resolved(core))
    assert.is_nil(state.by_id(r.id))
    assert.are.equal(1, #state.all())
  end)

  it("is_modified reflects the buffer state", function()
    local path = root .. "/m.ts"
    vim.fn.writefile({ "a" }, path)
    local b = vim.fn.bufadd(path); vim.fn.bufload(b); vim.bo[b].modified = false
    assert.is_false(rpc.is_modified(core, "m.ts"))
    vim.api.nvim_buf_set_lines(b, 0, 0, false, { "x" })
    assert.is_true(rpc.is_modified(core, "m.ts"))
  end)
end)
```

- [ ] **Step 2: Run and watch it fail**

Run: `cd ~/Dev/nvim/review.nvim && nvim --headless -c "PlenaryBustedFile tests/agent/rpc_spec.lua" -c "qa"`
Expected: FAIL ("module 'review.features.agent.rpc' not found").

- [ ] **Step 3: Implement `lua/review/features/agent/rpc.lua`**

```lua
local reconcile = require("review.features.agent.reconcile")

local M = {}

local function clean(c)
  local copy = {}
  for k, v in pairs(c) do
    if k ~= "_extmark_id" then copy[k] = v end
  end
  return copy
end

local function decode_maybe(x)
  if type(x) == "string" then
    local ok, d = pcall(vim.json.decode, x)
    if not ok then return nil end
    return d
  end
  return x
end

--- Finds the open bufnr for a relpath (or nil).
local function buf_for_path(core, relpath)
  local root = core.git.root()
  if not root then return nil end
  local full = root:gsub("/$", "") .. "/" .. relpath
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(b) and vim.api.nvim_buf_get_name(b) == full then
      return b
    end
  end
  return nil
end

function M.list(core, filter_json)
  local filter = decode_maybe(filter_json) or {}
  local out = {}
  for _, c in ipairs(core.state.all()) do
    local ok = true
    if filter.author ~= nil and c.author ~= filter.author then ok = false end
    if filter.path ~= nil and c.path ~= filter.path then ok = false end
    if filter.resolved ~= nil and (not not c.resolved) ~= filter.resolved then ok = false end
    if filter.answered ~= nil then
      local answered = #core.state.replies(c.id) > 0
      if answered ~= filter.answered then ok = false end
    end
    if ok then out[#out + 1] = clean(c) end
  end
  if #out == 0 then return "[]" end
  return vim.json.encode(out)
end

function M.get(core, id)
  local c = core.state.by_id(id)
  if not c then return "null" end
  local obj = clean(c)
  obj.replies = {}
  for _, r in ipairs(core.state.replies(id)) do obj.replies[#obj.replies + 1] = clean(r) end
  return vim.json.encode(obj)
end

function M.context(core, id)
  local c = core.state.by_id(id)
  if not c then return "null" end
  local lines = {}
  -- We prefer the content of the open buffer; otherwise disk; otherwise HEAD.
  local b = buf_for_path(core, c.path)
  if b then
    lines = vim.api.nvim_buf_get_lines(b, (c.lnum or 1) - 1, (c.end_lnum or c.lnum), false)
  else
    local root = core.git.root()
    local full = root and (root:gsub("/$", "") .. "/" .. c.path) or nil
    local ok, disk = false, nil
    if full then ok, disk = pcall(vim.fn.readfile, full) end
    if ok and disk then
      for i = (c.lnum or 1), (c.end_lnum or c.lnum) do lines[#lines + 1] = disk[i] or "" end
    end
  end
  return vim.json.encode({ comment = clean(c), lines = lines })
end

function M.add(core, json_or_table)
  local data = decode_maybe(json_or_table)
  if type(data) ~= "table" or not data.path or not data.lnum or not data.text then return "" end
  data.author = data.author or "agent"
  local c = core.state.add(data)
  core.state.persist()
  return c.id
end

function M.reply(core, parent_id, text)
  local parent = core.state.by_id(parent_id)
  if not parent or not text or vim.trim(text) == "" then return "" end
  local c = core.state.add({
    path = parent.path,
    lnum = parent.lnum,
    end_lnum = parent.end_lnum,
    text = text,
    author = "agent",
    reply_to = parent_id,
  })
  core.state.persist()
  return c.id
end

local function set_resolved(core, id, value)
  local ok = core.state.update(id, { resolved = value })
  if ok then core.state.persist() end
  return ok
end

function M.resolve(core, id) return set_resolved(core, id, true) end
function M.unresolve(core, id) return set_resolved(core, id, false) end

function M.update(core, id, text)
  if not text then return false end
  local ok = core.state.update(id, { text = text })
  if ok then core.state.persist() end
  return ok
end

function M.delete(core, id)
  local ok = core.state.remove(id)
  if ok then core.state.persist() end
  return ok
end

function M.clean_resolved(core, path)
  local ids = {}
  for _, c in ipairs(core.state.all()) do
    if c.resolved and (path == nil or c.path == path) then ids[#ids + 1] = c.id end
  end
  for _, id in ipairs(ids) do core.state.remove(id) end
  if #ids > 0 then core.state.persist() end
  return #ids
end

function M.is_modified(core, path)
  local b = buf_for_path(core, path)
  if not b then return false end
  return vim.bo[b].modified
end

function M.notify_changed(core, path)
  local b = buf_for_path(core, path)
  if not b then return false end
  return reconcile.patch(core, b) == "applied"
end

return M
```

- [ ] **Step 4: Run and watch it pass**

Run: `cd ~/Dev/nvim/review.nvim && nvim --headless -c "PlenaryBustedFile tests/agent/rpc_spec.lua" -c "qa"`
Expected: PASS (11).

- [ ] **Step 5: Commit**

```bash
cd ~/Dev/nvim/review.nvim && git add -A
git commit -q -m "feat(agent/rpc): complete serializable API (list/get/context/add/reply/resolve/update/delete/clean/is_modified/notify_changed)"
```

---

### Task 6: `agent/init.lua` — `_G.ReviewAgent`, `opts.enabled`, wire up the watcher

**Files:**
- Create: `lua/review/features/agent/init.lua`, `tests/agent/init_spec.lua`

**Interfaces:**
- Consumes: `rpc` (Task 5), `watch` (Task 4), `core.registry.register`.
- Produces: `M.setup(core, opts)` — if `opts.enabled` is truthy: exposes `_G.ReviewAgent` (all the
  `rpc` functions closing over `core`, plus `servername()`), and creates autocmds to attach the
  watcher to the repo's file buffers (`BufReadPost`/`BufWinEnter`) and release it on
  `BufWipeout`/`BufDelete`. If `opts.enabled` is falsy → it does not touch `_G` or create watchers (inert).

- [ ] **Step 1: Failing test — `tests/agent/init_spec.lua`**

```lua
local store = require("review.core.store")
local state = require("review.core.state")
local git = require("review.core.git")
local ns = require("review.core.ns")
local events = require("review.core.events")
local agent = require("review.features.agent")

local core = { state = state, git = git, ns = ns, events = events }

describe("features.agent.setup", function()
  before_each(function()
    local tmp = vim.fn.tempname(); vim.fn.mkdir(tmp, "p")
    store.root_fn = function() return tmp end
    state._reset(); events._reset()
    _G.ReviewAgent = nil
  end)

  it("does not expose _G.ReviewAgent if enabled is not true", function()
    agent.setup(core, {})
    assert.is_nil(_G.ReviewAgent)
  end)

  it("exposes the full API when enabled=true", function()
    agent.setup(core, { enabled = true })
    assert.is_table(_G.ReviewAgent)
    for _, fn in ipairs({ "list", "get", "context", "add", "reply", "resolve",
                          "unresolve", "update", "delete", "clean_resolved",
                          "is_modified", "notify_changed", "servername" }) do
      assert.is_function(_G.ReviewAgent[fn], fn .. " must be a function")
    end
    local id = _G.ReviewAgent.add({ path = "x.ts", lnum = 1, text = "t" })
    assert.is_truthy(id)
    assert.are.equal(1, #vim.json.decode(_G.ReviewAgent.list()))
  end)

  it("servername() returns v:servername", function()
    agent.setup(core, { enabled = true })
    assert.are.equal(vim.v.servername, _G.ReviewAgent.servername())
  end)

  it("self-registers in core.registry", function()
    local feats = require("review.core").registry.features()
    assert.is_not_nil(feats.agent)
    assert.are.equal(agent.setup, feats.agent.setup)
  end)
end)
```

- [ ] **Step 2: Run and watch it fail**

Run: `cd ~/Dev/nvim/review.nvim && nvim --headless -c "PlenaryBustedFile tests/agent/init_spec.lua" -c "qa"`
Expected: FAIL ("module 'review.features.agent' not found").

- [ ] **Step 3: Implement `lua/review/features/agent/init.lua`**

```lua
local rpc = require("review.features.agent.rpc")
local watch = require("review.features.agent.watch")

local M = {}

function M.setup(core, opts)
  opts = opts or {}
  if not opts.enabled then return end

  _G.ReviewAgent = {
    list = function(filter_json) return rpc.list(core, filter_json) end,
    get = function(id) return rpc.get(core, id) end,
    context = function(id) return rpc.context(core, id) end,
    add = function(json_or_table) return rpc.add(core, json_or_table) end,
    reply = function(parent_id, text) return rpc.reply(core, parent_id, text) end,
    resolve = function(id) return rpc.resolve(core, id) end,
    unresolve = function(id) return rpc.unresolve(core, id) end,
    update = function(id, text) return rpc.update(core, id, text) end,
    delete = function(id) return rpc.delete(core, id) end,
    clean_resolved = function(path) return rpc.clean_resolved(core, path) end,
    is_modified = function(path) return rpc.is_modified(core, path) end,
    notify_changed = function(path) return rpc.notify_changed(core, path) end,
    servername = function() return vim.v.servername end,
  }

  local group = vim.api.nvim_create_augroup("ReviewAgentWatch", { clear = true })
  vim.api.nvim_create_autocmd({ "BufReadPost", "BufWinEnter" }, {
    group = group,
    callback = function(a) watch.attach(core, a.buf) end,
  })
  vim.api.nvim_create_autocmd({ "BufWipeout", "BufDelete" }, {
    group = group,
    callback = function(a) watch.detach(a.buf) end,
  })
  -- Attach to the buffers that are already open when enabling.
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(b) then watch.attach(core, b) end
  end

  vim.schedule(function()
    vim.notify(
      "review.nvim: agent RPC enabled on socket " .. tostring(vim.v.servername),
      vim.log.levels.INFO
    )
  end)
end

require("review.core").registry.register({ name = "agent", setup = M.setup })

return M
```

- [ ] **Step 4: Run and watch it pass**

Run: `cd ~/Dev/nvim/review.nvim && nvim --headless -c "PlenaryBustedFile tests/agent/init_spec.lua" -c "qa"`
Expected: PASS (4).

- [ ] **Step 5: Manual `:ReviewReload` as a fallback** (`lua/review/features/agent/init.lua`, inside `M.setup`, before the `vim.schedule`)

```lua
  -- Manual fallback for the only case that auto does not solve (buffer with unsaved
  -- changes in conflict with disk): forces the patch of the current buffer.
  vim.api.nvim_create_user_command("ReviewReload", function()
    local b = vim.api.nvim_get_current_buf()
    -- we force it even if it was modified: the human asked for it explicitly.
    if vim.bo[b].modified then vim.bo[b].modified = false end
    require("review.features.agent.reconcile").patch(core, b)
  end, {})
```

- [ ] **Step 6: Full plugin suite (do not break anything)**

Run: `cd ~/Dev/nvim/review.nvim && nvim --headless -c "PlenaryBustedDirectory tests/ {minimal_init='tests/minimal_init.lua'}" -c "qa"`
Expected: PASS (all slices green).

- [ ] **Step 7: Commit**

```bash
cd ~/Dev/nvim/review.nvim && git add -A
git commit -q -m "feat(agent): _G.ReviewAgent + wired watcher + :ReviewReload, disabled by default"
```

---

### Task 7: `comments` render/gutter/peek — distinguish authorship, threads and `stale` (UI)

**Files:**
- Modify: `lua/review/features/comments/render.lua` (badge/hl by author + stale mark)
- Modify: `lua/review/features/comments/gutter.lua` (color/icon by author + "answered")
- Modify: `lua/review/features/comments/mode.lua` (peek shows the full thread)
- Modify: `lua/review/features/views/init.lua` (define new highlights with `default=true`)
- Modify: `docs/highlights.md`

This layer is visual (real extmarks / floats), verified manually as in `03-views.md`. The
logic is already tested (authorship in `state`, threads in `state.thread`, stale in `render.reconcile`).

**Interfaces:**
- Consumes: `core.state.for_path`, `core.state.replies`, `core.state.thread`.
- Produces: painting that distinguishes `author == "user"` from `author ~= "user"` (agent), a visual mark for
  `stale`, and a peek that renders the thread (comment + replies below).

- [ ] **Step 1: Define new highlights** (`lua/review/features/views/init.lua`, in the function that
  defines the groups with `default=true`, next to the existing `ReviewComment*` ones)

```lua
  set("ReviewCommentAgent",   { bg = "#3a2c52" })  -- background of the agent's comment (violet)
  set("ReviewCommentStale",   { bg = "#4a3a1d" })  -- comment with uncertain anchoring (amber)
  set("ReviewCommentSignAgent", { fg = "#c6a0f6" }) -- the agent's bracket in the gutter
```

(use the same `set`/`nvim_set_hl(0, name, { ..., default = true })` helper that the file already uses).

- [ ] **Step 2: `render.lua` — badge/hl by author + stale mark**

In the `M.render` loop, when choosing the background highlight and the badge prefix, take author and
stale into account:

```lua
    local is_agent = c.author and c.author ~= "user"
    local icon = is_agent and "🤖" or "💬"
    if c.stale then icon = "⚠️ " .. icon end
    -- background hl: resolved > stale > agent > normal (alternating)
    local line_hl
    if c.resolved then
      line_hl = "ReviewCommentLineResolved"
    elseif c.stale then
      line_hl = "ReviewCommentStale"
    elseif is_agent then
      line_hl = "ReviewCommentAgent"
    else
      line_hl = (idx % 2 == 0) and "ReviewCommentLine" or "ReviewCommentLine2"
    end
```

(Adapt to the real variable names of the current loop — `idx`, badge, etc. Keep the
eol badge but with `icon` instead of the fixed `💬`, and add a suffix if it has replies:
`#core.state.replies(c.id) > 0` → ` ↩N`).

- [ ] **Step 3: `gutter.lua` — bracket color by author + "answered" mark**

In the `statuscolumn` computation, if the comment is the agent's use `ReviewCommentSignAgent` instead of
the cyclic color; if it has replies, add a small marker (`↩`) or change the character of the
top of the bracket. Respect `render.hidden` as it already does.

- [ ] **Step 4: `mode.lua` (peek) — render the full thread**

In `M.peek_here`/the builder of the peek's `virt_lines`, instead of showing only `c.text`, build
the lines with `core.state.thread(c.id)`: the parent comment and, below, each reply indented with
its author (`↳ 🤖 agent: ...`). Keep the fixed design (virt_lines, not floating) from decision D8.

- [ ] **Step 5: Manual verification**

1. `nvim` on a repo file with changes. Create a comment of your own (`<leader>rc`).
2. With the agent enabled (Task 8) or from another terminal:
   `nvim --server "$NVIM_LISTEN_ADDRESS" --remote-expr 'luaeval("ReviewAgent.reply(_A, \"because the type can be null\")", "<id>")'`
   (get the `<id>` with `ReviewAgent.list()`).
3. Confirm in the buffer: the agent's comment is painted with a violet background + 🤖; your comment
   shows the suffix `↩1` (it has 1 reply); the peek (`<leader>rp`) shows the thread (your comment
   on top, the agent's reply indented below).
4. Simulate uncertain re-anchoring: on disk (outside nvim) edit the commented line into something very
   different; on reconcile, the comment must be marked `⚠️` with an amber background (`stale`).
5. Confirm that hide/show (`<leader>rh`) still works and that the gutter does not leak into
   neo-tree (regression B of D13).

- [ ] **Step 6: Update `docs/highlights.md`** with the 3 new groups (`ReviewCommentAgent`,
  `ReviewCommentStale`, `ReviewCommentSignAgent`) and their defaults.

- [ ] **Step 7: Commit**

```bash
cd ~/Dev/nvim/review.nvim && git add -A
git commit -q -m "feat(comments): distinguish agent authorship, threads in the peek and stale mark (UI)"
```

---

### Task 8: `comments` list — filter by author and by answered/unanswered

**Files:**
- Modify: `lua/review/features/comments/commands.lua`
- Modify: `tests/comments/commands_spec.lua`

**Interfaces:**
- Consumes: `core.state.all`, `core.state.replies`.
- Produces: the quickfix's `f` filter (`:Rl`/`:Rlf`) cycles through more states; a testable
  pure helper `commands._filter(list, replies_fn, mode)` is added that returns the sublist according to the mode:
  `all | open | resolved | mine | agent | answered | unanswered`.

- [ ] **Step 1: Failing test — add to `tests/comments/commands_spec.lua`**

```lua
  it("_filter selects by mode (mine/agent/answered/unanswered)", function()
    local p = { id = "p", author = "user", resolved = false }
    local a = { id = "a", author = "agent", resolved = false }
    local list = { p, a }
    local replies_fn = function(id) return id == "p" and { {} } or {} end  -- p has 1 reply

    local mine = commands._filter(list, replies_fn, "mine")
    assert.are.equal(1, #mine); assert.are.equal("p", mine[1].id)

    local ag = commands._filter(list, replies_fn, "agent")
    assert.are.equal(1, #ag); assert.are.equal("a", ag[1].id)

    local answered = commands._filter(list, replies_fn, "answered")
    assert.are.equal(1, #answered); assert.are.equal("p", answered[1].id)

    local unanswered = commands._filter(list, replies_fn, "unanswered")
    assert.are.equal(1, #unanswered); assert.are.equal("a", unanswered[1].id)

    assert.are.equal(2, #commands._filter(list, replies_fn, "all"))
  end)
```

- [ ] **Step 2: Run and watch it fail**

Run: `cd ~/Dev/nvim/review.nvim && nvim --headless -c "PlenaryBustedFile tests/comments/commands_spec.lua" -c "qa"`
Expected: FAIL (`attempt to call field '_filter' (a nil value)`).

- [ ] **Step 3: Implement `commands._filter`** (`lua/review/features/comments/commands.lua`, before `return M`)

```lua
--- Filters a list of comments according to `mode`. `replies_fn(id)` returns the
--- replies of a comment (for answered/unanswered). Pure/testable function.
function M._filter(list, replies_fn, mode)
  local function answered(c) return #(replies_fn(c.id) or {}) > 0 end
  local pred = {
    all = function() return true end,
    open = function(c) return not c.resolved end,
    resolved = function(c) return c.resolved end,
    mine = function(c) return (c.author or "user") == "user" end,
    agent = function(c) return (c.author or "user") ~= "user" end,
    answered = function(c) return answered(c) end,
    unanswered = function(c) return not answered(c) end,
  }
  local f = pred[mode] or pred.all
  local out = {}
  for _, c in ipairs(list) do if f(c) then out[#out + 1] = c end end
  return out
end
```

- [ ] **Step 4: Wire the `f` cycle in the quickfix** to go through the new modes
  (`all → open → resolved → mine → agent → answered → unanswered → all`), using
  `M._filter(core.state.all(), function(id) return core.state.replies(id) end, mode)` and updating
  the winbar hint. (No automated test: it is quickfix interaction; the pure helper is already
  covered in Step 1.)

- [ ] **Step 5: Run and watch it pass**

Run: `cd ~/Dev/nvim/review.nvim && nvim --headless -c "PlenaryBustedFile tests/comments/commands_spec.lua" -c "qa"`
Expected: PASS (previous + 1).

- [ ] **Step 6: Commit**

```bash
cd ~/Dev/nvim/review.nvim && git add -A
git commit -q -m "feat(comments): list filter by author and by answered/unanswered"
```

---

### Task 9: Document the agent protocol + end-to-end verification

**Files:**
- Modify: `docs/features.md` (`agent` section: move from "PENDING" to implemented)
- Modify: `docs/commands.md` (add `:ReviewReload` and the new filter cycle)
- Modify: `docs/decisions.md` (D21 → implemented; add D22 AUTO reconciliation)
- Create/rewrite: "Agent protocol" section in this file (below)

- [ ] **Step 1: End-to-end verification of the RPC** (with Neovim listening)

```bash
cd ~/Dev/nvim/review.nvim
nvim --headless --listen /tmp/review-nvim.sock \
  -c "lua require('review').setup({ features = { agent = { enabled = true } } })" &
sleep 1
# add a comment from the outside
nvim --server /tmp/review-nvim.sock --remote-expr \
  'luaeval("ReviewAgent.add(_A)", "{\"path\":\"foo.ts\",\"lnum\":1,\"text\":\"testing\"}")'
# list
nvim --server /tmp/review-nvim.sock --remote-expr 'luaeval("ReviewAgent.list()")'
kill %1
```

Expected: the first `--remote-expr` prints an id; the second, a JSON array with the comment.

- [ ] **Step 2: Update docs** (features/commands/decisions) reflecting: AUTO reconciliation by
  diff patch, watcher, threading/authorship/stale, `:ReviewReload`, `_G.ReviewAgent` API.

- [ ] **Step 3: Commit**

```bash
cd ~/Dev/nvim/review.nvim && git add -A
git commit -q -m "docs(agent): RPC protocol, AUTO reconciliation and update of features/commands/decisions"
```

---

## Agent protocol

**There is no custom server.** The "server" is the same `nvim` process that the human has open (or
a headless one with `--listen`). The agent uses the `nvim` binary as an RPC client against that socket. The
socket is in `v:servername` (`:echo v:servername`) or in the `--listen <path>` it was started with.

### Mental model

- **The agent writes code to disk with its own tools** (Edit/Write/etc.), outside
  nvim. review.nvim does not edit code.
- **Comments go through nvim** via `_G.ReviewAgent` (RPC), which operates on `core.state` (the single
  source of truth for comments).
- When the agent changes a file on disk, the **watcher** (`vim.uv.fs_event`) detects it and
  `reconcile.patch` applies the change to the buffer as a **minimal diff patch** — the extmarks (and
  therefore the comments) **re-anchor themselves by gravity**, without `:edit!`. If the buffer has
  unsaved changes from the human, it is **not** overwritten: a conflict is reported and a manual `:ReviewReload` remains.
- Before editing a file, the agent can query `ReviewAgent.is_modified(path)` so as not to
  collide with something the human is editing without saving. After editing, it can call
  `ReviewAgent.notify_changed(path)` to force the patch right away (in addition to the watcher).

### Enable (disabled by default)

```lua
require("review").setup({ features = { agent = { enabled = true } } })
```

### `_G.ReviewAgent` API

| Function | Signature | Returns |
|---|---|---|
| `list(filter?)` | `(string JSON filter?)` | `string` JSON array. filter: `{author?,path?,resolved?,answered?}` |
| `get(id)` | `(string)` | `string` JSON of the comment + `replies`, or `"null"` |
| `context(id)` | `(string)` | `string` JSON `{comment, lines}` (the code it spans) |
| `add(c)` | `(table\|string JSON)` | `string` id, or `""` if invalid. `author` defaults to `"agent"` |
| `reply(parent_id, text)` | `(string, string)` | `string` id of the reply, or `""` |
| `resolve(id)` / `unresolve(id)` | `(string)` | `boolean` |
| `update(id, text)` | `(string, string)` | `boolean` |
| `delete(id)` | `(string)` | `boolean` |
| `clean_resolved(path?)` | `(string?)` | `number` (how many it deleted) |
| `is_modified(path)` | `(string)` | `boolean` — open buffer with unsaved changes |
| `notify_changed(path)` | `(string)` | `boolean` — it forced the patch of that buffer |
| `servername()` | `()` | `string` — the current socket |

### Examples (`--remote-expr`, with `_A` to pass arguments without painful escaping)

```bash
# list only mine that are unanswered
nvim --server "$NVIM_LISTEN_ADDRESS" --remote-expr \
  'luaeval("ReviewAgent.list(_A)", "{\"author\":\"user\",\"answered\":false}")'

# reply to a comment from the human
nvim --server "$NVIM_LISTEN_ADDRESS" --remote-expr \
  'luaeval("ReviewAgent.reply(_A[1], _A[2])", ["18f2a90b-3c1a", "because the type can be null"])'

# see the code that a comment spans (to understand what it refers to)
nvim --server "$NVIM_LISTEN_ADDRESS" --remote-expr 'luaeval("ReviewAgent.context(_A)", "18f2a90b-3c1a")'

# after editing on disk, force the reload + re-anchoring
nvim --server "$NVIM_LISTEN_ADDRESS" --remote-expr 'luaeval("ReviewAgent.notify_changed(_A)", "src/foo.ts")'
```

### Typical flow

1. The human leaves comments (questions, requests). `:Rya` copies the agent-ready markdown.
2. The agent reads (`list`/`get`/`context`), **edits the code on disk on its own**, and over RPC
   **replies linked** (`reply`) with the justification, optionally `resolve`, and calls
   `notify_changed(path)` for what it touched (or lets the watcher detect it).
3. Neovim reloads those files with a minimal patch and re-anchors the comments; the human sees live the
   🤖/`↩` badge and the peek with the thread. They accept (it stays resolved) or reopen.
4. `clean_resolved` to clean up what is closed.

## Self-Review

- **Aligned with `docs/roadmap.md` §1:** native RPC transport ✅ (T6/protocol); separation of
  code-on-disk vs comments-through-nvim ✅ (T3 reconcile + protocol); AUTO reconciliation by
  minimal diff patch with re-anchoring by gravity ✅ (T3, empirically validated in roadmap §1.3);
  detection by `fs_event` watcher + debounce + `notify_changed` ✅ (T4/T5); conflict if `modified`
  (do not overwrite) + `:ReviewReload` fallback ✅ (T3/T6); `anchor_text` + `stale` ✅ (T2); authorship +
  threading (`reply_to`) + filters ✅ (T1/T5/T8); complete `_G.ReviewAgent` API ✅ (T5/T6);
  disabled by default ✅ (T6). Implementation order matches roadmap §1.7.
- **No-dependency rule between features:** `agent` never does `require("review.features.comments")`
  nor vice versa; they coordinate through the `buffer:reconciled` event (T3). `agent` only requires `review.core`
  and its own submodules.
- **No leaks:** watchers are closed on `BufWipeout`/`BufDelete` (T4/T6), debounce timers are always
  closed (T4).
- **Edge cases:** `modified` buffer → `conflict`, does not overwrite (T3); invalid JSON → `""`/`null` (T5);
  nonexistent parent in `reply` → `""` (T5); nonexistent id → `false` (T5); inert feature if not
  `enabled` (T6); outside the repo → no-op (T2/T3/T4).
- **Placeholders:** the code of `state`, `reconcile`, `watch`, `rpc`, `agent/init` is complete and
  executable. Tasks 7 (UI render/gutter/peek) and 8 Step 4 (wiring of the quickfix cycle) are
  adapted to the real variables of the existing files and verified manually, following the
  criterion of `03-views.md` for visual layers; their pure logic does have tests.
- **Backwards compatibility:** new fields are optional; `state.persist` already keeps them; old JSON
  loads without them (defaults nil/false).
