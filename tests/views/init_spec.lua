local views = require("review.features.views")

local function fake_core()
  local emitted = {}
  return {
    ns = { views = vim.api.nvim_create_namespace("review.test.views") },
    git = {
      rel_path = function() return nil end, -- outside git: inline/split are a safe no-op
      root = function() return nil end,
      head_content = function() return nil end,
      base_lines = function() return nil end,
    },
    events = {
      emit = function(name, payload) table.insert(emitted, { name = name, payload = payload }) end,
    },
    _emitted = emitted,
  }
end

describe("views.set (global mode)", function()
  local core

  before_each(function()
    core = fake_core()
    views.mode = "normal"
  end)

  it("normal by default", function()
    assert.are.equal("normal", views.mode)
  end)

  it("set applies and stores the global mode, emits view:changed", function()
    views.set(core, "inline")
    assert.are.equal("inline", views.mode)
    assert.are.equal(1, #core._emitted)
    assert.are.equal("view:changed", core._emitted[1].name)
    assert.are.same({ mode = "inline" }, core._emitted[1].payload)
  end)

  it("setting the same mode is idempotent (does not re-emit)", function()
    views.set(core, "inline")
    views.set(core, "inline")
    assert.are.equal(1, #core._emitted)
  end)

  it("switching from inline to split changes the mode and re-emits", function()
    views.set(core, "inline")
    views.set(core, "split")
    assert.are.equal("split", views.mode)
    assert.are.equal(2, #core._emitted)
  end)

  it("an invalid mode does not change the state", function()
    views.set(core, "inline")
    views.set(core, "bogus")
    assert.are.equal("inline", views.mode)
    assert.are.equal(1, #core._emitted)
  end)

  it("going back to normal", function()
    views.set(core, "inline")
    views.set(core, "normal")
    assert.are.equal("normal", views.mode)
  end)
end)
