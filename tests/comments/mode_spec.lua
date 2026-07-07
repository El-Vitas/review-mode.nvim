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

  it("_add agrega, renderiza y persiste", function()
    local c = mode._add(core, bufnr, 2, 2, "revisar esto")
    assert.is_truthy(c)
    assert.are.equal(1, #state.for_path("foo.ts"))
    state._reset(); state.load()
    assert.are.equal(1, #state.for_path("foo.ts"))
  end)

  it("_add es no-op si el buffer está fuera del repo", function()
    local other = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(other, "/fuera/x.ts")
    local c = mode._add(core, other, 1, 1, "algo")
    assert.is_nil(c)
  end)

  it("_add es no-op si el texto es vacío", function()
    local c = mode._add(core, bufnr, 1, 1, "   ")
    assert.is_nil(c)
    assert.are.equal(0, #state.for_path("foo.ts"))
  end)

  it("_add clampea lnum fuera de rango", function()
    local c = mode._add(core, bufnr, 999, 999, "fuera de rango")
    assert.are.equal(5, c.lnum)
    assert.are.equal(5, c.end_lnum)
  end)

  it("_delete_at borra el comentario que cubre la línea", function()
    local c = mode._add(core, bufnr, 3, 3, "borrar")
    assert.is_true(mode._delete_at(core, bufnr, 3))
    assert.is_nil(state.by_id(c.id))
  end)

  it("_delete_at devuelve false si no hay comentario en la línea", function()
    assert.is_false(mode._delete_at(core, bufnr, 1))
  end)

  it("_resolve_at togglea resolved", function()
    local c = mode._add(core, bufnr, 4, 4, "resolver")
    assert.is_true(mode._resolve_at(core, bufnr, 4))
    assert.is_true(state.by_id(c.id).resolved)
    assert.is_true(mode._resolve_at(core, bufnr, 4))
    assert.is_false(state.by_id(c.id).resolved)
  end)

  it("_update_at cambia el texto del comentario de la línea", function()
    local c = mode._add(core, bufnr, 2, 2, "viejo")
    assert.is_true(mode._update_at(core, bufnr, 2, "nuevo texto"))
    assert.are.equal("nuevo texto", state.by_id(c.id).text)
  end)

  it("_update_at devuelve false si no hay comentario o el texto es vacío", function()
    assert.is_false(mode._update_at(core, bufnr, 1, "algo"))
    mode._add(core, bufnr, 3, 3, "x")
    assert.is_false(mode._update_at(core, bufnr, 3, "   "))
  end)

  it("_add captura anchor_text de la línea comentada", function()
    local c = mode._add(core, bufnr, 3, 3, "ojo con l3")
    assert.are.equal("l3", c.anchor_text)
  end)
end)
