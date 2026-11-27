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

  it("when the file changes on disk, reconciles the buffer (debounced)", function()
    watch.attach(core, bufnr)
    local reconciled = false
    events.on("buffer:reconciled", function() reconciled = true end)
    vim.fn.writefile({ "l1", "l2", "l3", "l4" }, path)
    vim.wait(1000, function() return reconciled end)
    assert.is_true(reconciled)
    assert.are.same({ "l1", "l2", "l3", "l4" }, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
  end)

  it("survives the file being deleted and recreated a while later", function()
    watch.attach(core, bufnr)
    os.remove(path)
    vim.wait(300, function() return false end)
    vim.fn.writefile({ "new" }, path)
    vim.wait(1500, function() return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)[1] == "new" end)
    assert.are.same({ "new" }, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
    -- and keeps watching afterwards
    vim.fn.writefile({ "once more" }, path)
    vim.wait(1500, function() return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)[1] == "once more" end)
    assert.are.same({ "once more" }, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
  end)

  it("with unsaved changes it does not overwrite the buffer and notifies once", function()
    watch.attach(core, bufnr)
    vim.api.nvim_buf_set_lines(bufnr, 0, 1, false, { "mine" })
    local notified = 0
    local orig = vim.notify
    vim.notify = function(msg) if msg:find("changed on disk") then notified = notified + 1 end end
    vim.fn.writefile({ "from agent" }, path)
    vim.wait(800, function() return notified > 0 end)
    vim.fn.writefile({ "from agent 2" }, path)
    vim.wait(400, function() return false end)
    vim.notify = orig
    assert.are.equal("mine", vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1])
    assert.are.equal(1, notified)
  end)
end)
