local store = require("review.core.store")

describe("core.store", function()
  local tmp
  before_each(function()
    tmp = vim.fn.tempname(); vim.fn.mkdir(tmp, "p")
    store.root_fn = function() return tmp end
  end)

  it("empty when there is no file", function()
    assert.are.same({}, store.load().comments)
  end)

  it("round-trip", function()
    assert.is_true(store.save({ version = 1, comments = { { id = "a", path = "x", lnum = 2, text = "h" } } }))
    local d = store.load()
    assert.are.equal(1, #d.comments)
    assert.are.equal("h", d.comments[1].text)
  end)

  it("path inside .git/review.nvim", function()
    assert.is_truthy(store.path():match("%.git/review%.nvim/comments%.json$"))
  end)

  it("corrupt JSON: sets it aside instead of letting the next save overwrite it", function()
    local p = store.path()
    vim.fn.mkdir(vim.fn.fnamemodify(p, ":h"), "p")
    vim.fn.writefile({ '{"comments": [ {"id": "a"' }, p)
    assert.are.same({}, store.load().comments)
    assert.are.equal(0, vim.fn.filereadable(p))
    local aside = vim.fn.glob(p .. ".corrupt-*", false, true)
    assert.are.equal(1, #aside)
  end)

  it("comments: null is read as an empty list", function()
    local p = store.path()
    vim.fn.mkdir(vim.fn.fnamemodify(p, ":h"), "p")
    vim.fn.writefile({ '{"version": 1, "comments": null}' }, p)
    assert.are.same({}, store.load().comments)
  end)

  it("saving does not leave the .tmp of the atomic write behind", function()
    assert.is_true(store.save({ version = 1, comments = {} }))
    assert.are.equal(0, vim.fn.filereadable(store.path() .. ".tmp"))
  end)
end)
