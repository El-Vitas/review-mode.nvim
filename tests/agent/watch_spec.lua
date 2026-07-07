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

  it("attach es no-op para buffers fuera del repo", function()
    local other = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(other, "/fuera/x.ts")
    assert.has_no.errors(function() watch.attach(core, other) end)
    assert.is_false(watch._has(other))
  end)

  it("attach crea un watcher y detach lo cierra", function()
    watch.attach(core, bufnr)
    assert.is_true(watch._has(bufnr))
    watch.detach(bufnr)
    assert.is_false(watch._has(bufnr))
  end)

  it("al cambiar el archivo en disco, reconcilia el buffer (debounced)", function()
    watch.attach(core, bufnr)
    local reconciled = false
    events.on("buffer:reconciled", function() reconciled = true end)
    vim.fn.writefile({ "l1", "l2", "l3", "l4" }, path)
    vim.wait(1000, function() return reconciled end)
    assert.is_true(reconciled)
    assert.are.same({ "l1", "l2", "l3", "l4" }, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
  end)
end)
