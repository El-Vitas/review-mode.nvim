local store = require("review.core.store")
local state = require("review.core.state")
local git = require("review.core.git")
local commands = require("review.features.export.commands")

describe("features.export.commands", function()
  local core, tmp

  before_each(function()
    tmp = vim.fn.tempname(); vim.fn.mkdir(tmp, "p")
    store.root_fn = function() return tmp end
    state._reset()
    core = { state = state, git = git }
    vim.fn.setreg("+", "")
    pcall(vim.api.nvim_del_user_command, "ReviewYankFile")
    pcall(vim.api.nvim_del_user_command, "ReviewYankAll")
    pcall(vim.api.nvim_del_user_command, "Ryf")
    pcall(vim.api.nvim_del_user_command, "Rya")
  end)

  it("registers commands and aliases", function()
    commands.setup(core, {})
    local cmds = vim.api.nvim_get_commands({})
    assert.is_truthy(cmds["ReviewYankFile"])
    assert.is_truthy(cmds["ReviewYankAll"])
    assert.is_truthy(cmds["Ryf"])
    assert.is_truthy(cmds["Rya"])
  end)

  it(":ReviewYankFile copies only the current file's comments to the + register", function()
    commands.setup(core, {})
    state.add({ path = "a.ts", lnum = 1, text = "from a" })
    state.add({ path = "b.ts", lnum = 1, text = "from b" })

    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(buf, tmp .. "/a.ts")
    vim.api.nvim_set_current_buf(buf)

    vim.cmd("ReviewYankFile")
    local reg = vim.fn.getreg("+")
    assert.is_truthy(reg:match("from a"))
    assert.is_falsy(reg:match("from b"))
  end)

  it(":ReviewYankAll copies all comments to the + register", function()
    commands.setup(core, {})
    state.add({ path = "a.ts", lnum = 1, text = "from a" })
    state.add({ path = "b.ts", lnum = 1, text = "from b" })

    vim.cmd("ReviewYankAll")
    local reg = vim.fn.getreg("+")
    assert.is_truthy(reg:match("from a"))
    assert.is_truthy(reg:match("from b"))
  end)

  it(":ReviewYankFile with a buffer outside the repo does not break and leaves the register alone", function()
    commands.setup(core, {})
    state.add({ path = "a.ts", lnum = 1, text = "from a" })

    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(buf, "/some/other/x.ts")
    vim.api.nvim_set_current_buf(buf)

    vim.fn.setreg("+", "untouched")
    assert.has_no.errors(function() vim.cmd("ReviewYankFile") end)
    assert.are.equal("untouched", vim.fn.getreg("+"))
  end)

  it(":ReviewYankAll with an empty list notifies and does not break", function()
    commands.setup(core, {})
    vim.fn.setreg("+", "untouched")
    assert.has_no.errors(function() vim.cmd("ReviewYankAll") end)
    assert.are.equal("untouched", vim.fn.getreg("+"))
  end)

  it("respects opts.leader in the keymaps", function()
    commands.setup(core, { leader = "<leader>z" })
    -- Neovim expands "<leader>" to the value of g:mapleader (default "\\") when
    -- registering the mapping, so nvim_get_keymap returns the already-expanded lhs, not the literal.
    local mapleader = vim.g.mapleader or "\\"
    local expected_f = mapleader .. "zyf"
    local expected_a = mapleader .. "zya"
    local found = {}
    for _, m in ipairs(vim.api.nvim_get_keymap("n")) do
      if m.lhs == expected_f then found.f = true end
      if m.lhs == expected_a then found.a = true end
    end
    assert.is_true(found.f)
    assert.is_true(found.a)
  end)
end)
