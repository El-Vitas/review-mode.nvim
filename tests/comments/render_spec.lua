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

  it("no-op when the buffer is outside the repo", function()
    local other = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(other, "/outside/x.ts")
    state.add({ path = "x.ts", lnum = 1, text = "hello" })
    assert.has_no.errors(function() render.render(core, other) end)
    assert.are.equal(0, #vim.api.nvim_buf_get_extmarks(other, ns.comments, 0, -1, {}))
  end)

  it("creates nothing when there are no comments for the path", function()
    assert.has_no.errors(function() render.render(core, bufnr) end)
    assert.are.equal(0, #vim.api.nvim_buf_get_extmarks(bufnr, ns.comments, 0, -1, {}))
  end)

  it("creates one extmark per comment and sets _extmark_id", function()
    local c = state.add({ path = "foo.ts", lnum = 2, text = "watch out" })
    render.render(core, bufnr)
    assert.is_number(c._extmark_id)
    assert.are.equal(1, #vim.api.nvim_buf_get_extmarks(bufnr, ns.comments, 0, -1, {}))
  end)

  it("anchoring: inserting a line above raises lnum after sync_positions", function()
    local c = state.add({ path = "foo.ts", lnum = 3, text = "watch out" })
    render.render(core, bufnr)
    vim.api.nvim_buf_set_lines(bufnr, 0, 0, false, { "new" })
    render.sync_positions(core, bufnr)
    assert.are.equal(4, state.by_id(c.id).lnum)
  end)

  it("sync_positions does not break when the comment has no _extmark_id", function()
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
    assert.are.equal(5, got.end_lnum)  -- 4 -> 5 (range preserved, not collapsed)
  end)

  it("relocate re-locates the comment by anchor_text when the line changed", function()
    -- comment anchored to "l3" but saved at lnum 3; simulate the file having
    -- changed on disk while closed: "l3" is now on line 5.
    local c = state.add({ path = "foo.ts", lnum = 3, text = "x", anchor_text = "l3" })
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "n1", "n2", "l1", "l2", "l3" })
    render.relocate(core, bufnr)
    assert.are.equal(5, state.by_id(c.id).lnum)
    assert.is_false(state.by_id(c.id).stale)
  end)

  it("relocate marks stale when the anchor_text no longer exists", function()
    local c = state.add({ path = "foo.ts", lnum = 3, text = "x", anchor_text = "NO-LONGER-EXISTS" })
    render.relocate(core, bufnr)
    assert.is_true(state.by_id(c.id).stale)
  end)

  it("reconcile marks stale when the anchored line no longer matches", function()
    local c = state.add({ path = "foo.ts", lnum = 2, text = "x", anchor_text = "l2" })
    render.render(core, bufnr)
    vim.api.nvim_buf_set_lines(bufnr, 1, 2, false, { "COMPLETELY DIFFERENT" })
    render.reconcile(core, bufnr)
    assert.is_true(state.by_id(c.id).stale)
  end)

  it("reconcile clears stale when the line matches again", function()
    local c = state.add({ path = "foo.ts", lnum = 2, text = "x", anchor_text = "l2", stale = true })
    render.render(core, bufnr)
    render.reconcile(core, bufnr)  -- line 2 is still "l2"
    assert.is_false(state.by_id(c.id).stale)
  end)

  it("reconcile does not mark stale when the comment has no anchor_text", function()
    local c = state.add({ path = "foo.ts", lnum = 2, text = "x" })
    render.render(core, bufnr)
    render.reconcile(core, bufnr)
    assert.is_nil(state.by_id(c.id).stale)
  end)
end)
