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

  it("identical when disk == buffer", function()
    assert.are.equal("identical", reconcile.patch(core, bufnr))
  end)

  it("conflict when the buffer has unsaved changes", function()
    vim.api.nvim_buf_set_lines(bufnr, 0, 0, false, { "unsaved" })
    assert.is_true(vim.bo[bufnr].modified)
    write_file(path, { "l1", "l2", "l3", "l4", "l5", "l6" })
    assert.are.equal("conflict", reconcile.patch(core, bufnr))
  end)

  it("applied: an insertion above shifts the extmark and leaves the buffer nomodified", function()
    local id = vim.api.nvim_buf_set_extmark(bufnr, ns.comments, 2, 0, {})
    write_file(path, { "NEW", "l1", "l2", "l3", "l4", "l5" })
    assert.are.equal("applied", reconcile.patch(core, bufnr))
    assert.are.same(
      { "NEW", "l1", "l2", "l3", "l4", "l5" },
      vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    )
    local pos = vim.api.nvim_buf_get_extmark_by_id(bufnr, ns.comments, id, {})
    assert.are.equal(3, pos[1])
    assert.is_false(vim.bo[bufnr].modified)
  end)

  it("applied: a change in the middle does not move earlier extmarks", function()
    local id = vim.api.nvim_buf_set_extmark(bufnr, ns.comments, 0, 0, {})
    write_file(path, { "l1", "l2", "l3-MOD", "l4", "l5" })
    assert.are.equal("applied", reconcile.patch(core, bufnr))
    local pos = vim.api.nvim_buf_get_extmark_by_id(bufnr, ns.comments, id, {})
    assert.are.equal(0, pos[1])
    assert.are.equal("l3-MOD", vim.api.nvim_buf_get_lines(bufnr, 2, 3, false)[1])
  end)

  it("emits buffer:reconciled when applied", function()
    local fired = nil
    events.on("buffer:reconciled", function(p) fired = p.bufnr end)
    write_file(path, { "l1", "l2", "l3", "l4", "l5", "l6" })
    reconcile.patch(core, bufnr)
    vim.wait(50, function() return fired ~= nil end)
    assert.are.equal(bufnr, fired)
  end)
end)
