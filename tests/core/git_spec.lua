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

-- Repo git real en un directorio temporal.
local function make_repo()
  local root = vim.fn.tempname(); vim.fn.mkdir(root, "p")
  local function g(...) vim.fn.system(vim.list_extend({ "git", "-C", root }, { ... })) end
  g("init", "-q", "-b", "main")
  g("config", "user.email", "t@t"); g("config", "user.name", "t")
  return root, g
end

describe("core.git contra un repo real", function()
  local lines = {}
  for i = 1, 20 do lines[i] = "export const v" .. i .. " = " .. i end

  after_each(function() git.set_base("HEAD") end)

  it("rename_source encuentra el origen de un rename commiteado y de uno sin commitear", function()
    local root, g = make_repo()
    vim.fn.writefile(lines, root .. "/viejo.ts")
    vim.fn.writefile(lines, root .. "/otro.ts")
    g("add", "."); g("commit", "-qm", "base")
    local base = vim.trim(vim.fn.system({ "git", "-C", root, "rev-parse", "HEAD" }))
    g("mv", "viejo.ts", "nuevo.ts"); g("commit", "-qm", "rename")
    g("mv", "otro.ts", "movido.ts") -- staged, sin commitear
    git.set_base(base)
    assert.are.equal("viejo.ts", git.rename_source("nuevo.ts", root))
    assert.are.equal("otro.ts", git.rename_source("movido.ts", root))
    assert.is_nil(git.rename_source("no-existe.ts", root))
  end)

  it("head_content devuelve nil para un archivo nuevo y normaliza CRLF", function()
    local root, g = make_repo()
    vim.fn.writefile({ "a\r", "b\r" }, root .. "/crlf.txt", "b")
    g("add", "."); g("commit", "-qm", "base")
    assert.are.same({ "a", "b" }, git.head_content("crlf.txt", root))
    assert.is_nil(git.head_content("nuevo.txt", root))
  end)
end)
