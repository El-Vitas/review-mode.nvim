local store = require("review.core.store")
local state = require("review.core.state")
local git = require("review.core.git")
local ns = require("review.core.ns")
local commands = require("review.features.comments.commands")

local core = { state = state, git = git, ns = ns }

describe("comments.commands", function()
  before_each(function()
    local tmp = vim.fn.tempname(); vim.fn.mkdir(tmp, "p")
    store.root_fn = function() return tmp end
    state._reset()
  end)

  it("registra :ReviewCommentMode y :Rcm", function()
    commands.setup(core, { leader = "<leader>r" })
    assert.is_not_nil(vim.api.nvim_get_commands({})["ReviewCommentMode"])
    assert.is_true(vim.fn.exists(":Rcm") == 2)
  end)

  it("registra :ReviewList y :Rl", function()
    commands.setup(core, { leader = "<leader>r" })
    assert.is_not_nil(vim.api.nvim_get_commands({})["ReviewList"])
    assert.is_true(vim.fn.exists(":Rl") == 2)
  end)

  it(":ReviewList llena la quickfix con los comentarios", function()
    state.add({ path = "a.ts", lnum = 3, text = "revisar" })
    commands.setup(core, { leader = "<leader>r" })
    vim.cmd("ReviewList")
    local qf = vim.fn.getqflist()
    assert.are.equal(1, #qf)
    assert.are.equal(3, qf[1].lnum)
  end)

  it("mapea <leader>rr en modo normal", function()
    commands.setup(core, { leader = "<leader>r" })
    -- `maparg` resuelve `<leader>` contra `g:mapleader` igual que al setear el
    -- mapeo; comparar contra `nvim_get_keymap` a mano es frágil porque el
    -- lhs ahí queda ya expandido (depende del mapleader del entorno).
    assert.is_true(vim.fn.maparg("<leader>rr", "n") ~= "")
  end)
end)
