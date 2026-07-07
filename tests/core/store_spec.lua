local store = require("review.core.store")

describe("core.store", function()
  local tmp
  before_each(function()
    tmp = vim.fn.tempname(); vim.fn.mkdir(tmp, "p")
    store.root_fn = function() return tmp end
  end)

  it("vacío si no hay archivo", function()
    assert.are.same({}, store.load().comments)
  end)

  it("round-trip", function()
    assert.is_true(store.save({ version = 1, comments = { { id = "a", path = "x", lnum = 2, text = "h" } } }))
    local d = store.load()
    assert.are.equal(1, #d.comments)
    assert.are.equal("h", d.comments[1].text)
  end)

  it("path dentro de .git/review.nvim", function()
    assert.is_truthy(store.path():match("%.git/review%.nvim/comments%.json$"))
  end)
end)
