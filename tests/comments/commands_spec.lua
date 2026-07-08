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

  it("mapea <leader>re (edit) en modo normal", function()
    commands.setup(core, { leader = "<leader>r" })
    assert.is_true(vim.fn.maparg("<leader>re", "n") ~= "")
  end)

  it("_filter selecciona por modo (mine/agent/answered/unanswered)", function()
    local p = { id = "p", author = "user", resolved = false }
    local a = { id = "a", author = "agent", resolved = false }
    local list = { p, a }
    local replies_fn = function(id) return id == "p" and { {} } or {} end  -- p tiene 1 respuesta

    local mine = commands._filter(list, replies_fn, "mine")
    assert.are.equal(1, #mine); assert.are.equal("p", mine[1].id)

    local ag = commands._filter(list, replies_fn, "agent")
    assert.are.equal(1, #ag); assert.are.equal("a", ag[1].id)

    local answered = commands._filter(list, replies_fn, "answered")
    assert.are.equal(1, #answered); assert.are.equal("p", answered[1].id)

    local unanswered = commands._filter(list, replies_fn, "unanswered")
    assert.are.equal(1, #unanswered); assert.are.equal("a", unanswered[1].id)

    assert.are.equal(2, #commands._filter(list, replies_fn, "all"))
  end)
end)
