local store = require("review.core.store")
local git = require("review.core.git")

describe("core.git.rel_path", function()
  it("devuelve path relativo a la raíz", function()
    local root = vim.fn.tempname(); vim.fn.mkdir(root .. "/src", "p")
    store.root_fn = function() return root end
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(buf, root .. "/src/foo.ts")
    assert.are.equal("src/foo.ts", git.rel_path(buf))
  end)

  it("nil si el buffer está fuera de la raíz", function()
    store.root_fn = function() return vim.fn.tempname() end
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(buf, "/otro/lugar/x.ts")
    assert.is_nil(git.rel_path(buf))
  end)
end)
