local store = require("review.core.store")
local state = require("review.core.state")
local sidebar = require("review.features.sidebar")

describe("sidebar.files_with_comments", function()
  local core

  before_each(function()
    local tmp = vim.fn.tempname()
    vim.fn.mkdir(tmp, "p")
    store.root_fn = function() return tmp end
    state._reset()
    core = { state = state }
  end)

  it("vacío si no hay comentarios", function()
    local set = sidebar.files_with_comments(core)
    assert.are.same({}, set)
  end)

  it("incluye cada relpath con ≥1 comentario, sin duplicados", function()
    state.add({ path = "a.ts", lnum = 1, text = "x" })
    state.add({ path = "a.ts", lnum = 2, text = "y" })
    state.add({ path = "b/c.ts", lnum = 1, text = "z" })

    local set = sidebar.files_with_comments(core)

    assert.is_true(set["a.ts"])
    assert.is_true(set["b/c.ts"])
    local count = 0
    for _ in pairs(set) do count = count + 1 end
    assert.are.equal(2, count)
  end)

  it("incluye comentarios resueltos también", function()
    state.add({ path = "a.ts", lnum = 1, text = "x", resolved = true })
    local set = sidebar.files_with_comments(core)
    assert.is_true(set["a.ts"])
  end)
end)
