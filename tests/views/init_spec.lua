local views = require("review.features.views")

local function fake_core()
  local emitted = {}
  return {
    ns = { views = vim.api.nvim_create_namespace("review.test.views") },
    git = {
      rel_path = function() return nil end, -- fuera de git: inline/split no-op seguro
      root = function() return nil end,
      head_content = function() return nil end,
    },
    events = {
      emit = function(name, payload) table.insert(emitted, { name = name, payload = payload }) end,
    },
    _emitted = emitted,
  }
end

describe("views.set (modo global)", function()
  local core

  before_each(function()
    core = fake_core()
    views.mode = "normal"
  end)

  it("normal por defecto", function()
    assert.are.equal("normal", views.mode)
  end)

  it("set aplica y guarda el modo global, emite view:changed", function()
    views.set(core, "inline")
    assert.are.equal("inline", views.mode)
    assert.are.equal(1, #core._emitted)
    assert.are.equal("view:changed", core._emitted[1].name)
    assert.are.same({ mode = "inline" }, core._emitted[1].payload)
  end)

  it("setear el mismo modo es idempotente (no reemite)", function()
    views.set(core, "inline")
    views.set(core, "inline")
    assert.are.equal(1, #core._emitted)
  end)

  it("cambiar de inline a split cambia el modo y reemite", function()
    views.set(core, "inline")
    views.set(core, "split")
    assert.are.equal("split", views.mode)
    assert.are.equal(2, #core._emitted)
  end)

  it("modo inválido no cambia el estado", function()
    views.set(core, "inline")
    views.set(core, "bogus")
    assert.are.equal("inline", views.mode)
    assert.are.equal(1, #core._emitted)
  end)

  it("volver a normal", function()
    views.set(core, "inline")
    views.set(core, "normal")
    assert.are.equal("normal", views.mode)
  end)
end)
