-- Make sure neo-tree.nvim (if installed on the system via lazy.nvim) is on the
-- runtimepath of the headless test process, so the real subscription path of
-- M.setup can be exercised (not just the degradation path).
-- If it is not installed, require("neo-tree.command") keeps failing and the
-- first test (degradation) remains the only one covered.
local neotree_path = vim.fn.stdpath("data") .. "/lazy/neo-tree.nvim"
if vim.fn.isdirectory(neotree_path) == 1 then
  vim.opt.runtimepath:append(neotree_path)
end
local nui_path = vim.fn.stdpath("data") .. "/lazy/nui.nvim"
if vim.fn.isdirectory(nui_path) == 1 then
  vim.opt.runtimepath:append(nui_path)
end

local events = require("review.core.events")
local state = require("review.core.state")
local store = require("review.core.store")
local sidebar = require("review.features.sidebar")

describe("sidebar.setup", function()
  before_each(function()
    local tmp = vim.fn.tempname()
    vim.fn.mkdir(tmp, "p")
    store.root_fn = function() return tmp end
    state._reset()
    events._reset()          -- avoids subscribers leaking between tests (otherwise the count gives a false positive)
    sidebar._subscribed = false
  end)

  it("does not blow up when neo-tree is not installed", function()
    local core = { state = state, events = events, git = { changed_files = function() return {} end } }
    assert.has_no.errors(function()
      sidebar.setup(core, {})
    end)
  end)

  it("does not subscribe twice to comments:changed after two setup() calls", function()
    local core = { state = state, events = events, git = { changed_files = function() return {} end } }
    sidebar.setup(core, {})
    sidebar.setup(core, {})

    local calls = 0
    -- Count how many comments:changed handlers exist by firing an event
    -- and checking that M._refresh is not invoked more than once per emit.
    local orig = sidebar._refresh
    sidebar._refresh = function(...)
      calls = calls + 1
      if orig then orig(...) end
    end

    events.emit("comments:changed", {})
    vim.wait(50)

    sidebar._refresh = orig
    assert.are.equal(1, calls)
  end)
end)
