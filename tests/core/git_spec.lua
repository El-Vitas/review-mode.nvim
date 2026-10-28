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

  it("los renames sobreviven a recuperar el foco y se recalculan si git cambió", function()
    local root, g = make_repo()
    vim.fn.writefile(lines, root .. "/a.ts")
    vim.fn.writefile(lines, root .. "/b.ts")
    g("add", "."); g("commit", "-qm", "base")
    local base = vim.trim(vim.fn.system({ "git", "-C", root, "rev-parse", "HEAD" }))
    g("mv", "a.ts", "a2.ts"); g("commit", "-qm", "rename a")
    git.set_base(base)
    assert.are.equal("a.ts", git.rename_source("a2.ts", root))

    -- Recuperar el foco sin cambios en git: no se vuelve a correr git diff.
    local orig, diffs = vim.system, 0
    vim.system = function(args, ...)
      if type(args) == "table" and args[4] == "diff" then diffs = diffs + 1 end
      return orig(args, ...)
    end
    git.clear_cache()
    git.prefetch_renames(root)
    assert.are.equal("a.ts", git.rename_source("a2.ts", root))
    vim.system = orig
    assert.are.equal(0, diffs)

    -- Un `git mv` hecho afuera (cambia el index): el mapa se recalcula.
    g("mv", "b.ts", "b2.ts")
    git.clear_cache()
    assert.are.equal("b.ts", git.rename_source("b2.ts", root))
    -- Un commit hecho afuera, sin nada nuevo en el index, también cambia la huella.
    local before = git.repo_stamp(root)
    g("commit", "-qm", "rename b")
    git.clear_cache()
    assert.are_not.equal(before, git.repo_stamp(root))
    assert.are.equal("b.ts", git.rename_source("b2.ts", root))
  end)

  it("prefetch_renames calcula en segundo plano y rename_source reusa ese cálculo", function()
    local root, g = make_repo()
    vim.fn.writefile(lines, root .. "/a.ts")
    g("add", "."); g("commit", "-qm", "base")
    local base = vim.trim(vim.fn.system({ "git", "-C", root, "rev-parse", "HEAD" }))
    g("mv", "a.ts", "a2.ts"); g("commit", "-qm", "rename a")
    git.set_base(base)

    local orig, diffs = vim.system, 0
    vim.system = function(args, ...)
      if type(args) == "table" and args[4] == "diff" then diffs = diffs + 1 end
      return orig(args, ...)
    end
    git.prefetch_renames(root) -- lanza los dos diffs y vuelve sin esperar
    git.prefetch_renames(root) -- ya en curso: no lanza otros
    assert.are.equal(2, diffs)
    -- Antes de que terminen: espera a esos mismos procesos.
    assert.are.equal("a.ts", git.rename_source("a2.ts", root))
    vim.system = orig
    assert.are.equal(2, diffs)
    assert.is_nil(git.rename_source("no-existe.ts", root))
  end)

  it("head_content devuelve nil para un archivo nuevo y normaliza CRLF", function()
    local root, g = make_repo()
    vim.fn.writefile({ "a\r", "b\r" }, root .. "/crlf.txt", "b")
    g("add", "."); g("commit", "-qm", "base")
    assert.are.same({ "a", "b" }, git.head_content("crlf.txt", root))
    assert.is_nil(git.head_content("nuevo.txt", root))
  end)

  it("base_lines: {} para un archivo nuevo respecto de la base, nil si está ignorado", function()
    local root, g = make_repo()
    vim.fn.writefile({ "dist/" }, root .. "/.gitignore")
    vim.fn.writefile({ "x" }, root .. "/viejo.ts")
    g("add", "."); g("commit", "-qm", "base")
    local base = vim.trim(vim.fn.system({ "git", "-C", root, "rev-parse", "HEAD" }))
    vim.fn.writefile({ "y" }, root .. "/commiteado.ts") -- nuevo, pero ya commiteado
    g("add", "."); g("commit", "-qm", "nuevo")
    vim.fn.mkdir(root .. "/dist", "p")
    vim.fn.writefile({ "z" }, root .. "/dist/out.js")
    git.set_base(base)
    assert.are.same({ "x" }, git.base_lines("viejo.ts", root))
    assert.are.same({}, git.base_lines("commiteado.ts", root))
    assert.are.same({}, git.base_lines("sin-trackear.ts", root))
    assert.is_nil(git.base_lines("dist/out.js", root))
    git.set_base("HEAD")
  end)
end)
