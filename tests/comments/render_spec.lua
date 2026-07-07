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

  it("no-op si el buffer está fuera del repo", function()
    local other = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(other, "/fuera/x.ts")
    state.add({ path = "x.ts", lnum = 1, text = "hola" })
    assert.has_no.errors(function() render.render(core, other) end)
    assert.are.equal(0, #vim.api.nvim_buf_get_extmarks(other, ns.comments, 0, -1, {}))
  end)

  it("no crea nada si no hay comentarios para el path", function()
    assert.has_no.errors(function() render.render(core, bufnr) end)
    assert.are.equal(0, #vim.api.nvim_buf_get_extmarks(bufnr, ns.comments, 0, -1, {}))
  end)

  it("crea un extmark por comentario y setea _extmark_id", function()
    local c = state.add({ path = "foo.ts", lnum = 2, text = "ojo" })
    render.render(core, bufnr)
    assert.is_number(c._extmark_id)
    assert.are.equal(1, #vim.api.nvim_buf_get_extmarks(bufnr, ns.comments, 0, -1, {}))
  end)

  it("anclaje: insertar línea arriba sube el lnum tras sync_positions", function()
    local c = state.add({ path = "foo.ts", lnum = 3, text = "ojo" })
    render.render(core, bufnr)
    vim.api.nvim_buf_set_lines(bufnr, 0, 0, false, { "nueva" })
    render.sync_positions(core, bufnr)
    assert.are.equal(4, state.by_id(c.id).lnum)
  end)

  it("sync_positions no rompe si el comentario no tiene _extmark_id", function()
    state.add({ path = "foo.ts", lnum = 1, text = "sin render" })
    assert.has_no.errors(function() render.sync_positions(core, bufnr) end)
  end)

  it("preserva el rango multi-línea tras insertar arriba", function()
    local c = state.add({ path = "foo.ts", lnum = 2, end_lnum = 4, text = "rango" })
    render.render(core, bufnr)
    vim.api.nvim_buf_set_lines(bufnr, 0, 0, false, { "nueva" })
    render.sync_positions(core, bufnr)
    local got = state.by_id(c.id)
    assert.are.equal(3, got.lnum)      -- 2 -> 3
    assert.are.equal(5, got.end_lnum)  -- 4 -> 5 (rango conservado, no colapsado)
  end)
end)
