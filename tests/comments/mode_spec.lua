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

  it("_add is a no-op when the buffer is outside the repo", function()
    local other = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(other, "/outside/x.ts")
    local c = mode._add(core, other, 1, 1, "something")
    assert.is_nil(c)
  end)

  it("_add is a no-op when the text is empty", function()
    local c = mode._add(core, bufnr, 1, 1, "   ")
    assert.is_nil(c)
    assert.are.equal(0, #state.for_path("foo.ts"))
  end)

  it("_add clamps an out-of-range lnum", function()
    local c = mode._add(core, bufnr, 999, 999, "out of range")
    assert.are.equal(5, c.lnum)
    assert.are.equal(5, c.end_lnum)
  end)

  it("_delete_at deletes the comment covering the line", function()
    local c = mode._add(core, bufnr, 3, 3, "delete me")
    assert.is_true(mode._delete_at(core, bufnr, 3))
    assert.is_nil(state.by_id(c.id))
  end)

  it("_delete_at returns false when there is no comment on the line", function()
    assert.is_false(mode._delete_at(core, bufnr, 1))
  end)

  it("_resolve_at toggles resolved", function()
    local c = mode._add(core, bufnr, 4, 4, "resolve me")
    assert.is_true(mode._resolve_at(core, bufnr, 4))
    assert.is_true(state.by_id(c.id).resolved)
    assert.is_true(mode._resolve_at(core, bufnr, 4))
    assert.is_false(state.by_id(c.id).resolved)
  end)

  it("_update_at changes the text of the line's comment", function()
    local c = mode._add(core, bufnr, 2, 2, "old")
    assert.is_true(mode._update_at(core, bufnr, 2, "new text"))
    assert.are.equal("new text", state.by_id(c.id).text)
  end)

  it("_update_at returns false when there is no comment or the text is empty", function()
    assert.is_false(mode._update_at(core, bufnr, 1, "something"))
    mode._add(core, bufnr, 3, 3, "x")
    assert.is_false(mode._update_at(core, bufnr, 3, "   "))
  end)

  it("_add captures anchor_text from the commented line", function()
    local c = mode._add(core, bufnr, 3, 3, "watch out for l3")
    assert.are.equal("l3", c.anchor_text)
  end)

  it("with overlapping comments it acts on the most specific one", function()
    local outer = mode._add(core, bufnr, 1, 5, "OUTER")
    local inner = mode._add(core, bufnr, 3, 3, "INNER")
    assert.is_true(mode._update_at(core, bufnr, 3, "EDITED"))
    assert.are.equal("OUTER", state.by_id(outer.id).text)
    assert.are.equal("EDITED", state.by_id(inner.id).text)
    assert.is_true(mode._resolve_at(core, bufnr, 3))
    assert.is_false(state.by_id(outer.id).resolved)
    assert.is_true(state.by_id(inner.id).resolved)
  end)

  it("_update_by_id edits that comment even if another is on the line", function()
    local outer = mode._add(core, bufnr, 1, 5, "OUTER")
    mode._add(core, bufnr, 3, 3, "INNER")
    assert.is_true(mode._update_by_id(core, bufnr, outer.id, "new"))
    assert.are.equal("new", state.by_id(outer.id).text)
    assert.is_false(mode._update_by_id(core, bufnr, "does-not-exist", "x"))
  end)

  it("add_here anchors the range: if lines change while typing, it lands on the right one", function()
    vim.api.nvim_set_current_buf(bufnr)
    vim.api.nvim_win_set_cursor(0, { 3, 0 }) -- "l3"
    -- The (nui) popup takes focus: text is typed into it and confirmed with <CR>.
    mode.add_here(core)
    vim.api.nvim_buf_set_lines(bufnr, 0, 0, false, { "new1", "new2" }) -- the agent inserts above
    local popup_buf = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_lines(popup_buf, 0, -1, false, { "about l3" })
    vim.cmd("stopinsert")
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "x", false)
    local c = state.for_path("foo.ts")[1]
    assert.is_truthy(c)
    assert.are.equal(5, c.lnum) -- l3 moved down two lines
    assert.are.equal("l3", c.anchor_text)
  end)

  it("peek of a file-level comment opens the card without error", function()
    state.add({ path = "foo.ts", file_level = true, text = "whole file" })
    vim.api.nvim_set_current_buf(bufnr)
    vim.api.nvim_win_set_cursor(0, { 5, 0 }) -- last line: target = file-level comment
    assert.has_no.errors(function() mode.peek_here(core) end)
    assert.is_true(#mode._peek_wins > 0)
    mode.close_peek_float()
  end)
end)
