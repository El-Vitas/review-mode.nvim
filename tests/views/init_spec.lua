local views = require("review.features.views")

local function fake_core()
  local emitted = {}
  return {
    ns = { views = 1 },
    git = {
      rel_path = function() return nil end, -- fuera de git: inline/split serán no-op seguro
      root = function() return nil end,
      head_content = function() return nil end,
    },
    events = {
      emit = function(name, payload) table.insert(emitted, { name = name, payload = payload }) end,
    },
    _emitted = emitted,
  }
end

describe("views.set", function()
  local core, bufnr

  before_each(function()
    core = fake_core()
    views.mode = {}
    bufnr = vim.api.nvim_create_buf(false, true)
  end)

  it("normal por defecto si nunca se seteó", function()
    assert.is_nil(views.mode[bufnr])
  end)

  it("set aplica y guarda el modo, emite view:changed", function()
    views.set(core, bufnr, "inline")
    assert.are.equal("inline", views.mode[bufnr])
    assert.are.equal(1, #core._emitted)
    assert.are.equal("view:changed", core._emitted[1].name)
    assert.are.same({ bufnr = bufnr, mode = "inline" }, core._emitted[1].payload)
  end)

  it("togglear al mismo modo es idempotente (no reemite)", function()
    views.set(core, bufnr, "inline")
    views.set(core, bufnr, "inline")
    assert.are.equal(1, #core._emitted)
  end)

  it("cambiar de inline a split limpia inline y aplica split", function()
    views.set(core, bufnr, "inline")
    views.set(core, bufnr, "split")
    assert.are.equal("split", views.mode[bufnr])
    assert.are.equal(2, #core._emitted)
  end)

  it("mode invalido no cambia el estado", function()
    views.set(core, bufnr, "inline")
    views.set(core, bufnr, "bogus")
    assert.are.equal("inline", views.mode[bufnr])
    assert.are.equal(1, #core._emitted)
  end)

  it("volver a normal limpia la vista previa", function()
    views.set(core, bufnr, "inline")
    views.set(core, bufnr, "normal")
    assert.are.equal("normal", views.mode[bufnr])
  end)
end)
