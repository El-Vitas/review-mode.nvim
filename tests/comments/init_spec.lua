local store = require("review.core.store")
local state = require("review.core.state")
local git = require("review.core.git")
local ns = require("review.core.ns")
local events = require("review.core.events")

package.loaded["review.features.comments.init"] = nil
local comments = require("review.features.comments.init")

local core = { state = state, git = git, ns = ns, events = events }

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

  it("se auto-registra en review.core.registry con name=comments", function()
    local core_mod = require("review.core")
    local feats = core_mod.registry.features()
    assert.is_not_nil(feats.comments)
    assert.are.equal(comments.setup, feats.comments.setup)
  end)

  it("setup registra comandos y autocmds sin errores", function()
    assert.has_no.errors(function() comments.setup(core, { leader = "<leader>r" }) end)
    assert.is_not_nil(vim.api.nvim_get_commands({})["ReviewCommentMode"])
  end)

  it("BufWritePost sincroniza posiciones y persiste", function()
    comments.setup(core, { leader = "<leader>r" })
    local c = state.add({ path = "foo.ts", lnum = 2, text = "x" })
    require("review.features.comments.render").render(core, bufnr)
    vim.api.nvim_set_current_buf(bufnr)
    vim.api.nvim_buf_set_lines(bufnr, 0, 0, false, { "nueva" })
    vim.cmd("silent! write! " .. vim.fn.fnameescape(vim.api.nvim_buf_get_name(bufnr)))
    vim.wait(50)
    assert.are.equal(3, state.by_id(c.id).lnum)
  end)

  it("buffer:reconciled dispara render.reconcile y re-sincroniza posiciones", function()
    comments.setup(core, { leader = "<leader>r" })
    local events = require("review.core.events")
    local c = state.add({ path = "foo.ts", lnum = 2, text = "x", anchor_text = "l2" })
    require("review.features.comments.render").render(core, bufnr)
    vim.api.nvim_set_current_buf(bufnr)
    -- simulamos que reconcile ya aplicó un patch: se insertó una línea arriba
    vim.api.nvim_buf_set_lines(bufnr, 0, 0, false, { "nueva" })
    events.emit("buffer:reconciled", { bufnr = bufnr })
    vim.wait(50)
    assert.are.equal(3, state.by_id(c.id).lnum)  -- 2 -> 3
  end)
end)
