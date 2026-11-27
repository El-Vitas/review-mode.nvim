local store = require("review.core.store")
local git = require("review.core.git")

describe("core.git.rel_path", function()
  it("returns a path relative to the root", function()
    local root = vim.fn.tempname(); vim.fn.mkdir(root .. "/src", "p")
    store.root_fn = function() return root end
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(buf, root .. "/src/foo.ts")
    assert.are.equal("src/foo.ts", git.rel_path(buf))
  end)

  it("nil when the buffer is outside the root", function()
    store.root_fn = function() return vim.fn.tempname() end
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(buf, "/some/other/x.ts")
    assert.is_nil(git.rel_path(buf))
  end)
end)

-- Real git repo in a temporary directory.
local function make_repo()
  local root = vim.fn.tempname(); vim.fn.mkdir(root, "p")
  local function g(...) vim.fn.system(vim.list_extend({ "git", "-C", root }, { ... })) end
  g("init", "-q", "-b", "main")
  g("config", "user.email", "t@t"); g("config", "user.name", "t")
  return root, g
end

describe("core.git against a real repo", function()
  local lines = {}
  for i = 1, 20 do lines[i] = "export const v" .. i .. " = " .. i end

  after_each(function() git.set_base("HEAD") end)

  it("rename_source finds the origin of a committed rename and of an uncommitted one", function()
    local root, g = make_repo()
    vim.fn.writefile(lines, root .. "/old.ts")
    vim.fn.writefile(lines, root .. "/another.ts")
    g("add", "."); g("commit", "-qm", "base")
    local base = vim.trim(vim.fn.system({ "git", "-C", root, "rev-parse", "HEAD" }))
    g("mv", "old.ts", "new.ts"); g("commit", "-qm", "rename")
    g("mv", "another.ts", "moved.ts") -- staged, uncommitted
    git.set_base(base)
    assert.are.equal("old.ts", git.rename_source("new.ts", root))
    assert.are.equal("another.ts", git.rename_source("moved.ts", root))
    assert.is_nil(git.rename_source("missing.ts", root))
  end)

  it("renames survive regaining focus and are recomputed if git changed", function()
    local root, g = make_repo()
    vim.fn.writefile(lines, root .. "/a.ts")
    vim.fn.writefile(lines, root .. "/b.ts")
    g("add", "."); g("commit", "-qm", "base")
    local base = vim.trim(vim.fn.system({ "git", "-C", root, "rev-parse", "HEAD" }))
    g("mv", "a.ts", "a2.ts"); g("commit", "-qm", "rename a")
    git.set_base(base)
    assert.are.equal("a.ts", git.rename_source("a2.ts", root))

    -- Regaining focus with no git changes: git diff is not run again.
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

    -- A `git mv` done externally (changes the index): the map is recomputed.
    g("mv", "b.ts", "b2.ts")
    git.clear_cache()
    assert.are.equal("b.ts", git.rename_source("b2.ts", root))
    -- A commit done externally, with nothing new in the index, also changes the stamp.
    local before = git.repo_stamp(root)
    g("commit", "-qm", "rename b")
    git.clear_cache()
    assert.are_not.equal(before, git.repo_stamp(root))
    assert.are.equal("b.ts", git.rename_source("b2.ts", root))
  end)

  it("prefetch_renames computes in the background and rename_source reuses that computation", function()
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
    git.prefetch_renames(root) -- launches the two diffs and returns without waiting
    git.prefetch_renames(root) -- already in progress: launches no others
    assert.are.equal(2, diffs)
    -- Before they finish: waits on those same processes.
    assert.are.equal("a.ts", git.rename_source("a2.ts", root))
    vim.system = orig
    assert.are.equal(2, diffs)
    assert.is_nil(git.rename_source("missing.ts", root))
  end)

  it("head_content returns nil for a new file and normalizes CRLF", function()
    local root, g = make_repo()
    vim.fn.writefile({ "a\r", "b\r" }, root .. "/crlf.txt", "b")
    g("add", "."); g("commit", "-qm", "base")
    assert.are.same({ "a", "b" }, git.head_content("crlf.txt", root))
    assert.is_nil(git.head_content("new.txt", root))
  end)

  it("base_lines: {} for a file new relative to the base, nil if ignored", function()
    local root, g = make_repo()
    vim.fn.writefile({ "dist/" }, root .. "/.gitignore")
    vim.fn.writefile({ "x" }, root .. "/old.ts")
    g("add", "."); g("commit", "-qm", "base")
    local base = vim.trim(vim.fn.system({ "git", "-C", root, "rev-parse", "HEAD" }))
    vim.fn.writefile({ "y" }, root .. "/committed.ts") -- new, but already committed
    g("add", "."); g("commit", "-qm", "new")
    vim.fn.mkdir(root .. "/dist", "p")
    vim.fn.writefile({ "z" }, root .. "/dist/out.js")
    git.set_base(base)
    assert.are.same({ "x" }, git.base_lines("old.ts", root))
    assert.are.same({}, git.base_lines("committed.ts", root))
    assert.are.same({}, git.base_lines("untracked.ts", root))
    assert.is_nil(git.base_lines("dist/out.js", root))
    git.set_base("HEAD")
  end)
end)
