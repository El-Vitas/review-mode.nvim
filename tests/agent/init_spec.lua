local store = require("review.core.store")
local state = require("review.core.state")
local git = require("review.core.git")
local ns = require("review.core.ns")
local events = require("review.core.events")
local agent = require("review.features.agent")

local core = { state = state, git = git, ns = ns, events = events }

describe("features.agent.setup", function()
  before_each(function()
    local tmp = vim.fn.tempname(); vim.fn.mkdir(tmp, "p")
    store.root_fn = function() return tmp end
    state._reset(); events._reset()
    _G.ReviewAgent = nil
  end)

  it("does not expose _G.ReviewAgent unless enabled is true", function()
    agent.setup(core, {})
    assert.is_nil(_G.ReviewAgent)
  end)

  it("exposes the full API when enabled=true", function()
    agent.setup(core, { enabled = true })
    assert.is_table(_G.ReviewAgent)
    for _, fn in ipairs({ "list", "get", "context", "add", "reply", "resolve",
                          "unresolve", "update", "delete", "clean_resolved",
                          "is_modified", "notify_changed", "servername" }) do
      assert.is_function(_G.ReviewAgent[fn], fn .. " must be a function")
    end
    local id = _G.ReviewAgent.add({ path = "x.ts", lnum = 1, text = "t" })
    assert.is_truthy(id)
    assert.are.equal(1, #vim.json.decode(_G.ReviewAgent.list()))
  end)

  it("servername() returns v:servername", function()
    agent.setup(core, { enabled = true })
    assert.are.equal(vim.v.servername, _G.ReviewAgent.servername())
  end)

  it("registers itself in core.registry", function()
    local feats = require("review.core").registry.features()
    assert.is_not_nil(feats.agent)
    assert.are.equal(agent.setup, feats.agent.setup)
  end)
end)
