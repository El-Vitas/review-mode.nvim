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

  it("registra comandos y alias", function()
    commands.setup(core, {})
    local cmds = vim.api.nvim_get_commands({})
    assert.is_truthy(cmds["ReviewYankFile"])
    assert.is_truthy(cmds["ReviewYankAll"])
    assert.is_truthy(cmds["Ryf"])
    assert.is_truthy(cmds["Rya"])
  end)

  it(":ReviewYankFile copia solo los comentarios del archivo actual al registro +", function()
    commands.setup(core, {})
    state.add({ path = "a.ts", lnum = 1, text = "de a" })
    state.add({ path = "b.ts", lnum = 1, text = "de b" })

    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(buf, tmp .. "/a.ts")
    vim.api.nvim_set_current_buf(buf)

    vim.cmd("ReviewYankFile")
    local reg = vim.fn.getreg("+")
    assert.is_truthy(reg:match("de a"))
    assert.is_falsy(reg:match("de b"))
  end)

  it(":ReviewYankAll copia todos los comentarios al registro +", function()
    commands.setup(core, {})
    state.add({ path = "a.ts", lnum = 1, text = "de a" })
    state.add({ path = "b.ts", lnum = 1, text = "de b" })

    vim.cmd("ReviewYankAll")
    local reg = vim.fn.getreg("+")
    assert.is_truthy(reg:match("de a"))
    assert.is_truthy(reg:match("de b"))
  end)

  it(":ReviewYankFile con buffer fuera del repo no rompe y no toca el registro", function()
    commands.setup(core, {})
    state.add({ path = "a.ts", lnum = 1, text = "de a" })

    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(buf, "/otro/lugar/x.ts")
    vim.api.nvim_set_current_buf(buf)

    vim.fn.setreg("+", "sin-tocar")
    assert.has_no.errors(function() vim.cmd("ReviewYankFile") end)
    assert.are.equal("sin-tocar", vim.fn.getreg("+"))
  end)

  it(":ReviewYankAll con lista vacía notifica y no rompe", function()
    commands.setup(core, {})
    vim.fn.setreg("+", "sin-tocar")
    assert.has_no.errors(function() vim.cmd("ReviewYankAll") end)
    assert.are.equal("sin-tocar", vim.fn.getreg("+"))
  end)

  it("respeta opts.leader en los keymaps", function()
    commands.setup(core, { leader = "<leader>z" })
    -- Neovim expande "<leader>" al valor de g:mapleader (default "\\") al registrar
    -- el mapeo, así que nvim_get_keymap devuelve el lhs ya expandido, no el literal.
    local mapleader = vim.g.mapleader or "\\"
    local expected_f = mapleader .. "zf"
    local expected_a = mapleader .. "za"
    local found = {}
    for _, m in ipairs(vim.api.nvim_get_keymap("n")) do
      if m.lhs == expected_f then found.f = true end
      if m.lhs == expected_a then found.a = true end
    end
    assert.is_true(found.f)
    assert.is_true(found.a)
  end)
end)
