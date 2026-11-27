# review.nvim — Plan 00: Core (foundation)

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development or superpowers:executing-plans. Steps use checkboxes (`- [ ]`).
> **Master plan:** `~/Dev/nvim/review.nvim/DESIGN.md` — this plan implements the "`core` contract" section. Every signature here **must** match that contract.

**Goal:** Build the shared kernel `review.core` (git, store, state, ns, events, registry) + `review.init` + test harness. It is the only dependency of the features and unblocks them to be worked on in parallel.

**Architecture:** Lua modules under `lua/review/core/`. `store` is the only door to the filesystem; `state` is the in-memory source of truth and emits events; `events` decouples features; `registry` mounts features via `setup(core, opts)`.

**Tech Stack:** Lua, Neovim ≥ 0.10, plenary.nvim (busted tests).

## Global Constraints

- Neovim ≥ 0.10 (`vim.uv`, `vim.json`, extmarks `virt_lines`).
- Pure Lua, no build step, loadable by lazy.nvim.
- Comments **only** in `<repo>/.git/review.nvim/comments.json`, never in the code.
- Comment `path` = relative to the git root.
- Namespaces: `review.nvim/comments`, `review.nvim/views`.
- **All** disk I/O goes through `core.store`.
- Features depend **only** on `require("review.core")`; never on another feature. Coordination through `core.events`.
- Tests: `nvim --headless -c "PlenaryBustedDirectory tests/ {minimal_init='tests/minimal_init.lua'}" -c "qa"`.

---

### Task 1: Skeleton + harness + registry/core stub

**Files:**
- Create: `.gitignore`, `tests/minimal_init.lua`
- Create: `lua/review/core/registry.lua`, `lua/review/core/init.lua`, `lua/review/init.lua`

**Interfaces:**
- Produces:
  - `core.registry.register({ name, setup })`, `core.registry.features()` → list, `core.registry.setup(core, opts)`.
  - `require("review.core")` → table `{ registry }` (it will be completed as we go).
  - `require("review").setup(opts)`.

- [ ] **Step 1: `.gitignore`**

```
/.luarc.json
```

- [ ] **Step 2: `tests/minimal_init.lua`**

```lua
local plenary = vim.fn.stdpath("data") .. "/lazy/plenary.nvim"
vim.opt.runtimepath:append(plenary)
vim.opt.runtimepath:append(vim.fn.getcwd())
vim.cmd("runtime plugin/plenary.vim")
```

- [ ] **Step 3: `lua/review/core/registry.lua`**

```lua
local M = {}
local _features = {}

function M.register(feature)
  assert(feature and feature.name and feature.setup, "invalid feature")
  _features[feature.name] = feature
end

function M.features()
  return _features
end

-- Clears the feature registry. For tests (prevents real features
-- auto-registered by other specs from contaminating a registry test).
function M._reset()
  _features = {}
end

-- Propagates the global `leader` to each feature (unless the feature has its
-- own). Without this, the features' keymaps would never see the global leader.
function M.setup(core, opts)
  opts = opts or {}
  local fopts = opts.features or {}
  local global_leader = opts.leader or "<leader>r"
  for name, feature in pairs(_features) do
    local cfg = fopts[name] or {}
    cfg.leader = cfg.leader or global_leader
    if cfg.enabled ~= false then
      feature.setup(core, cfg)
    end
  end
end

return M
```

> **Contract for features:** `feature.setup(core, cfg)` **always** receives `cfg.leader`
> (the global one or its own). Keymaps must use `cfg.leader .. "x"`, never the literal
> `"<leader>rx"`. The lowercase alias `cnoreabbrev`s do **not** go in the feature: they are centralized
> in `plugin/review.lua` (Task 7).

- [ ] **Step 4: `lua/review/core/init.lua`**

```lua
-- The core is assembled here. Each submodule is added in its Task.
local M = {
  registry = require("review.core.registry"),
}
return M
```

- [ ] **Step 5: `lua/review/init.lua`**

```lua
local M = {}
M.config = { leader = "<leader>r" }

function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})
  local core = require("review.core")
  -- Features self-register when required (they are added in their plans).
  core.registry.setup(core, M.config)
end

return M
```

- [ ] **Step 6: Verify loading**

Run: `cd ~/Dev/nvim/review.nvim && nvim --headless -c "lua require('review').setup()" -c "qa"`
Expected: exit 0, no errors.

- [ ] **Step 7: Commit**

```bash
cd ~/Dev/nvim/review.nvim && git init -q 2>/dev/null; git add -A
git commit -q -m "chore(core): skeleton, registry and test harness"
```

---

### Task 2: `core/store.lua` — JSON persistence

**Files:**
- Create: `lua/review/core/store.lua`, `tests/core/store_spec.lua`
- Modify: `lua/review/core/init.lua` (expose `store`)

**Interfaces:**
- Produces: `store.root_fn()` (override in tests), `store.path()`, `store.load()`, `store.save(data)`.

- [ ] **Step 1: Failing test — `tests/core/store_spec.lua`**

```lua
local store = require("review.core.store")

describe("core.store", function()
  local tmp
  before_each(function()
    tmp = vim.fn.tempname(); vim.fn.mkdir(tmp, "p")
    store.root_fn = function() return tmp end
  end)

  it("empty if there is no file", function()
    assert.are.same({}, store.load().comments)
  end)

  it("round-trip", function()
    assert.is_true(store.save({ version = 1, comments = { { id = "a", path = "x", lnum = 2, text = "h" } } }))
    local d = store.load()
    assert.are.equal(1, #d.comments)
    assert.are.equal("h", d.comments[1].text)
  end)

  it("path inside .git/review.nvim", function()
    assert.is_truthy(store.path():match("%.git/review%.nvim/comments%.json$"))
  end)
end)
```

- [ ] **Step 2: Run and watch it fail**

Run: `cd ~/Dev/nvim/review.nvim && nvim --headless -c "PlenaryBustedFile tests/core/store_spec.lua" -c "qa"`
Expected: FAIL ("module 'review.core.store' not found").

- [ ] **Step 3: Implement `lua/review/core/store.lua`**

```lua
local M = {}

function M.root_fn()
  local out = vim.fn.systemlist({ "git", "rev-parse", "--show-toplevel" })
  if vim.v.shell_error ~= 0 or not out[1] or out[1] == "" then return nil end
  return out[1]
end

function M.path()
  local root = M.root_fn()
  if not root then return nil end
  return root .. "/.git/review.nvim/comments.json"
end

local function empty() return { version = 1, comments = {} } end

function M.load()
  local p = M.path()
  if not p then return empty() end
  local fd = io.open(p, "r")
  if not fd then return empty() end
  local content = fd:read("*a"); fd:close()
  local ok, data = pcall(vim.json.decode, content)
  if not ok or type(data) ~= "table" then return empty() end
  data.version = data.version or 1
  data.comments = data.comments or {}
  return data
end

function M.save(data)
  local p = M.path()
  if not p then return false end
  vim.fn.mkdir(vim.fn.fnamemodify(p, ":h"), "p")
  local fd = io.open(p, "w")
  if not fd then return false end
  fd:write(vim.json.encode(data)); fd:close()
  return true
end

return M
```

- [ ] **Step 4: Expose in `core/init.lua`**

```lua
local M = {
  registry = require("review.core.registry"),
  store = require("review.core.store"),
}
return M
```

- [ ] **Step 5: Run and watch it pass**

Run: `cd ~/Dev/nvim/review.nvim && nvim --headless -c "PlenaryBustedFile tests/core/store_spec.lua" -c "qa"`
Expected: PASS (3).

- [ ] **Step 6: Commit**

```bash
cd ~/Dev/nvim/review.nvim && git add -A
git commit -q -m "feat(core/store): JSON persistence in .git/review.nvim"
```

---

### Task 3: `core/git.lua` — git utilities

**Files:**
- Create: `lua/review/core/git.lua`, `tests/core/git_spec.lua`
- Modify: `lua/review/core/init.lua`

**Interfaces:**
- Produces:
  - `git.root()` → `string|nil` (uses `store.root_fn` to be testable/consistent).
  - `git.rel_path(bufnr)` → `string|nil`.
  - `git.head_content(relpath)` → `string[]|nil` (`git show HEAD:relpath`).
  - `git.changed_files()` → `string[]` (`git diff --name-only HEAD` ∪ untracked).

- [ ] **Step 1: Failing test — `tests/core/git_spec.lua`** (pure part: `rel_path`)

```lua
local store = require("review.core.store")
local git = require("review.core.git")

describe("core.git.rel_path", function()
  it("returns a path relative to the root", function()
    local root = vim.fn.tempname(); vim.fn.mkdir(root .. "/src", "p")
    store.root_fn = function() return root end
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(buf, root .. "/src/foo.ts")
    assert.are.equal("src/foo.ts", git.rel_path(buf))
  end)

  it("nil if the buffer is outside the root", function()
    store.root_fn = function() return vim.fn.tempname() end
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(buf, "/other/place/x.ts")
    assert.is_nil(git.rel_path(buf))
  end)
end)
```

- [ ] **Step 2: Run and watch it fail**

Run: `cd ~/Dev/nvim/review.nvim && nvim --headless -c "PlenaryBustedFile tests/core/git_spec.lua" -c "qa"`
Expected: FAIL ("module 'review.core.git' not found").

- [ ] **Step 3: Implement `lua/review/core/git.lua`**

```lua
local store = require("review.core.store")

local M = {}

function M.root()
  return store.root_fn()
end

function M.rel_path(bufnr)
  local root = M.root()
  local full = vim.api.nvim_buf_get_name(bufnr)
  if not root or full == "" then return nil end
  root = root:gsub("/$", "")
  if full:sub(1, #root + 1) == root .. "/" then
    return full:sub(#root + 2)
  end
  return nil
end

function M.head_content(relpath)
  local root = M.root()
  if not root then return nil end
  local out = vim.fn.systemlist({ "git", "-C", root, "show", "HEAD:" .. relpath })
  if vim.v.shell_error ~= 0 then return nil end
  return out
end

function M.changed_files()
  local root = M.root()
  if not root then return {} end
  local tracked = vim.fn.systemlist({ "git", "-C", root, "diff", "--name-only", "HEAD" })
  if vim.v.shell_error ~= 0 then tracked = {} end
  local untracked = vim.fn.systemlist({ "git", "-C", root, "ls-files", "--others", "--exclude-standard" })
  if vim.v.shell_error ~= 0 then untracked = {} end
  local seen, out = {}, {}
  for _, f in ipairs(tracked) do if f ~= "" and not seen[f] then seen[f] = true; out[#out+1] = f end end
  for _, f in ipairs(untracked) do if f ~= "" and not seen[f] then seen[f] = true; out[#out+1] = f end end
  return out
end

return M
```

- [ ] **Step 4: Expose in `core/init.lua`** (add `git = require("review.core.git"),`)

- [ ] **Step 5: Run and watch it pass**

Run: `cd ~/Dev/nvim/review.nvim && nvim --headless -c "PlenaryBustedFile tests/core/git_spec.lua" -c "qa"`
Expected: PASS (2).

- [ ] **Step 6: Commit**

```bash
cd ~/Dev/nvim/review.nvim && git add -A
git commit -q -m "feat(core/git): root, rel_path, head_content, changed_files"
```

---

### Task 4: `core/events.lua` + `core/ns.lua`

**Files:**
- Create: `lua/review/core/events.lua`, `lua/review/core/ns.lua`, `tests/core/events_spec.lua`
- Modify: `lua/review/core/init.lua`

**Interfaces:**
- Produces:
  - `events.on(name, cb)`, `events.emit(name, payload)` (protected, `vim.schedule`).
  - `ns.comments`, `ns.views` (namespace ids).

- [ ] **Step 1: Failing test — `tests/core/events_spec.lua`**

```lua
local events = require("review.core.events")

describe("core.events", function()
  before_each(function() events._reset() end)

  it("on/emit delivers the payload", function()
    local got
    events.on("x:test", function(p) got = p.v end)
    events.emit("x:test", { v = 42 })
    vim.wait(50, function() return got ~= nil end)
    assert.are.equal(42, got)
  end)

  it("_reset clears the subscriptions", function()
    local calls = 0
    events.on("x:test", function() calls = calls + 1 end)
    events._reset()
    events.emit("x:test", {})
    vim.wait(50)
    assert.are.equal(0, calls)
  end)
end)
```

- [ ] **Step 2: Run and watch it fail**

Run: `cd ~/Dev/nvim/review.nvim && nvim --headless -c "PlenaryBustedFile tests/core/events_spec.lua" -c "qa"`
Expected: FAIL ("module 'review.core.events' not found").

- [ ] **Step 3: Implement `lua/review/core/events.lua`**

```lua
local M = {}
local subs = {}

function M.on(name, cb)
  subs[name] = subs[name] or {}
  table.insert(subs[name], cb)
end

function M.emit(name, payload)
  for _, cb in ipairs(subs[name] or {}) do
    vim.schedule(function()
      local ok, err = pcall(cb, payload or {})
      if not ok then vim.notify("review event " .. name .. ": " .. tostring(err), vim.log.levels.ERROR) end
    end)
  end
end

-- Clears all subscriptions. Needed in tests to avoid state leaking
-- between cases (`subs` is module-local and persists across `it` blocks).
function M._reset()
  subs = {}
end

return M
```

- [ ] **Step 4: Implement `lua/review/core/ns.lua`**

```lua
return {
  comments = vim.api.nvim_create_namespace("review.nvim/comments"),
  views = vim.api.nvim_create_namespace("review.nvim/views"),
}
```

- [ ] **Step 5: Expose in `core/init.lua`** (add `events = require("review.core.events"), ns = require("review.core.ns"),`)

- [ ] **Step 6: Run and watch it pass**

Run: `cd ~/Dev/nvim/review.nvim && nvim --headless -c "PlenaryBustedFile tests/core/events_spec.lua" -c "qa"`
Expected: PASS (1).

- [ ] **Step 7: Commit**

```bash
cd ~/Dev/nvim/review.nvim && git add -A
git commit -q -m "feat(core): events pub/sub + extmark namespaces"
```

---

### Task 5: `core/state.lua` — source of truth + events

**Files:**
- Create: `lua/review/core/state.lua`, `tests/core/state_spec.lua`
- Modify: `lua/review/core/init.lua`

**Interfaces:**
- Consumes: `store` (Task 2), `events` (Task 4).
- Produces: `state.all()`, `state.for_path(p)`, `state.by_id(id)`, `state.add(c)`, `state.remove(id)`, `state.update(id, fields)`, `state.load()`, `state.persist()`. `add/remove/update` emit `comments:changed`.

- [ ] **Step 1: Failing test — `tests/core/state_spec.lua`**

```lua
local store = require("review.core.store")
local events = require("review.core.events")
local state = require("review.core.state")

describe("core.state", function()
  before_each(function()
    local tmp = vim.fn.tempname(); vim.fn.mkdir(tmp, "p")
    store.root_fn = function() return tmp end
    state._reset()
  end)

  it("add assigns defaults and emits comments:changed", function()
    local fired = false
    events.on("comments:changed", function() fired = true end)
    local c = state.add({ path = "a.ts", lnum = 5, text = "x" })
    assert.is_truthy(c.id); assert.is_false(c.resolved); assert.are.equal("user", c.author)
    assert.are.equal(5, c.end_lnum)
    vim.wait(50, function() return fired end)
    assert.is_true(fired)
  end)

  it("persist + load round-trip", function()
    state.add({ path = "a.ts", lnum = 1, text = "x" })
    state.persist(); state._reset(); state.load()
    assert.are.equal(1, #state.all())
  end)

  it("remove and update by id", function()
    local c = state.add({ path = "a.ts", lnum = 1, text = "x" })
    assert.is_true(state.update(c.id, { resolved = true }))
    assert.is_true(state.by_id(c.id).resolved)
    assert.is_true(state.remove(c.id))
    assert.are.equal(0, #state.all())
  end)

  it("for_path filters", function()
    state.add({ path = "a.ts", lnum = 1, text = "x" })
    state.add({ path = "b.ts", lnum = 1, text = "y" })
    assert.are.equal(1, #state.for_path("a.ts"))
  end)
end)
```

- [ ] **Step 2: Run and watch it fail**

Run: `cd ~/Dev/nvim/review.nvim && nvim --headless -c "PlenaryBustedFile tests/core/state_spec.lua" -c "qa"`
Expected: FAIL ("module 'review.core.state' not found").

- [ ] **Step 3: Implement `lua/review/core/state.lua`**

```lua
local store = require("review.core.store")
local events = require("review.core.events")

local M = {}
local list = {}

-- Robust id: seed once with hrtime (avoids collisions when many comments are
-- added within the same second, e.g. the agent in a batch) + a monotonic
-- counter + a random value.
local _seeded = false
local _counter = 0
local function uuid()
  if not _seeded then
    math.randomseed((os.time() + (vim.loop.hrtime() % 0x7fffffff)))
    _seeded = true
  end
  _counter = _counter + 1
  return string.format("%x-%x-%x", os.time(), _counter, math.random(0, 0xffffff))
end

function M._reset() list = {} end
function M.all() return list end

function M.for_path(path)
  local out = {}
  for _, c in ipairs(list) do if c.path == path then out[#out+1] = c end end
  return out
end

function M.by_id(id)
  for _, c in ipairs(list) do if c.id == id then return c end end
  return nil
end

function M.add(c)
  c.id = c.id or uuid()
  c.end_lnum = c.end_lnum or c.lnum
  if c.resolved == nil then c.resolved = false end
  c.author = c.author or "user"
  c.created_at = c.created_at or os.date("!%Y-%m-%dT%H:%M:%SZ")
  table.insert(list, c)
  events.emit("comments:changed", {})
  return c
end

function M.remove(id)
  for i, c in ipairs(list) do
    if c.id == id then table.remove(list, i); events.emit("comments:changed", {}); return true end
  end
  return false
end

function M.update(id, fields)
  local c = M.by_id(id)
  if not c then return false end
  for k, v in pairs(fields) do c[k] = v end
  events.emit("comments:changed", {})
  return true
end

function M.load()
  list = store.load().comments or {}
  return list
end

function M.persist()
  -- Do not persist the runtime field _extmark_id.
  local clean = {}
  for _, c in ipairs(list) do
    local copy = {}
    for k, v in pairs(c) do if k ~= "_extmark_id" then copy[k] = v end end
    clean[#clean+1] = copy
  end
  return store.save({ version = 1, comments = clean })
end

return M
```

- [ ] **Step 4: Expose in `core/init.lua`** (add `state = require("review.core.state"),`)

- [ ] **Step 5: Run and watch it pass**

Run: `cd ~/Dev/nvim/review.nvim && nvim --headless -c "PlenaryBustedFile tests/core/state_spec.lua" -c "qa"`
Expected: PASS (4).

- [ ] **Step 6: Commit**

```bash
cd ~/Dev/nvim/review.nvim && git add -A
git commit -q -m "feat(core/state): source of truth for comments + events"
```

---

### Task 6: Wire `registry.setup` with `state.load` + end-to-end verification

**Files:**
- Modify: `lua/review/init.lua`
- Create: `tests/core/registry_spec.lua`

**Interfaces:**
- Consumes: `registry` (Task 1), `state` (Task 5).
- Produces: `review.setup(opts)` that loads state and mounts the registered features with `feature.setup(core, cfg)`.

- [ ] **Step 1: Failing test — `tests/core/registry_spec.lua`**

```lua
local core = require("review.core")

describe("core.registry.setup", function()
  before_each(function() core.registry._reset() end)

  it("calls setup of enabled features and skips disabled ones", function()
    local called = {}
    core.registry.register({ name = "featA", setup = function() called.a = true end })
    core.registry.register({ name = "featB", setup = function() called.b = true end })
    core.registry.setup(core, { features = { featB = { enabled = false } } })
    vim.wait(50)
    assert.is_true(called.a)
    assert.is_nil(called.b)
  end)
end)
```

- [ ] **Step 2: Run and watch it fail** (it fails if `registry.setup` does not respect `enabled=false`)

Run: `cd ~/Dev/nvim/review.nvim && nvim --headless -c "PlenaryBustedFile tests/core/registry_spec.lua" -c "qa"`
Expected: PASS already (the registry from Task 1 covers it). If it fails, review Task 1 Step 3.

- [ ] **Step 3: Ensure `state.load()` at startup — `lua/review/init.lua`**

```lua
local M = {}
M.config = { leader = "<leader>r" }

-- Known features. Each one self-registers in core.registry when required.
local FEATURES = { "comments", "export", "views", "sidebar", "agent" }

function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})
  local core = require("review.core")
  core.state.load()
  -- Load features (self-registration via require). pcall so as not to break during
  -- the incremental build when a feature does not exist yet.
  for _, name in ipairs(FEATURES) do
    pcall(require, "review.features." .. name)
  end
  core.registry.setup(core, M.config)
end

return M
```

- [ ] **Step 4: Full core suite**

Run: `cd ~/Dev/nvim/review.nvim && nvim --headless -c "PlenaryBustedDirectory tests/ {minimal_init='tests/minimal_init.lua'}" -c "qa"`
Expected: PASS (store 3, git 2, events 2, state 4, registry 1).

- [ ] **Step 5: Commit**

```bash
cd ~/Dev/nvim/review.nvim && git add -A
git commit -q -m "feat(core): wire setup with state loading + registry"
```

---

### Task 7: `plugin/review.lua` — centralized lowercase aliases

Native user-commands are capitalized (`:Rcm`, `:Ryf`, `:Rya`, `:Rv`, `:Rl`, `:Rs`). The
lowercase versions (`rcm`, `ryf`, ...) are achieved with `cnoreabbrev` **in a single place** — here,
**not** in each feature (avoids duplication and keeps the design). This file is always loaded (`plugin/`
dir), regardless of which features are enabled; abbrevs that point to a nonexistent
command simply do nothing.

**Files:**
- Create: `plugin/review.lua`

**Interfaces:**
- Produces: abbrevs `rcm→Rcm`, `rl→Rl`, `ryf→Ryf`, `rya→Rya`, `rv→Rv`, `rs→Rs`.

- [ ] **Step 1: Create `plugin/review.lua`**

```lua
-- Lowercase aliases for the review.nvim commands (centralized).
-- Each feature registers its capitalized command in its own setup.
vim.cmd([[
  cnoreabbrev rcm Rcm
  cnoreabbrev rl  Rl
  cnoreabbrev ryf Ryf
  cnoreabbrev rya Rya
  cnoreabbrev rv  Rv
  cnoreabbrev rs  Rs
]])
```

- [ ] **Step 2: Verify loading**

Run: `cd ~/Dev/nvim/review.nvim && nvim --headless -c "qa"`
Expected: exit 0, no errors.

- [ ] **Step 3: Commit**

```bash
cd ~/Dev/nvim/review.nvim && git add -A
git commit -q -m "feat(core): lowercase aliases centralized in plugin/review.lua"
```

---

## Self-Review

- **Contract coverage (DESIGN.md):** git ✅ (T3), store ✅ (T2), state ✅ (T5), ns ✅ (T4), events ✅ (T4), registry ✅ (T1/T6), `review.init` ✅ (T1/T6).
- **Placeholders:** none.
- **Consistency:** signatures identical to the DESIGN contract (`state.add/remove/update/all/for_path/by_id/load/persist`, `git.root/rel_path/head_content/changed_files`, `events.on/emit`, `ns.comments/views`, `registry.register/setup`).
- **Event contract:** `comments:changed` emitted by `state.add/remove/update` (T5) — features (sidebar) can subscribe.
