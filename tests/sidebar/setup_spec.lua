-- Aseguramos que neo-tree.nvim (si está instalado en el sistema, vía lazy.nvim)
-- esté en el runtimepath del proceso headless de tests, para poder ejercitar
-- el camino de suscripción real de M.setup (no solo el de degradación).
-- Si no está instalado, require("neo-tree.command") sigue fallando y el
-- primer test (degradación) sigue siendo el único cubierto.
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
    events._reset()          -- evita fuga de suscriptores entre tests (si no, el conteo da falso-positivo)
    sidebar._subscribed = false
  end)

  it("no explota si neo-tree no está instalado", function()
    local core = { state = state, events = events, git = { changed_files = function() return {} end } }
    assert.has_no.errors(function()
      sidebar.setup(core, {})
    end)
  end)

  it("no se suscribe dos veces a comments:changed tras dos setup()", function()
    local core = { state = state, events = events, git = { changed_files = function() return {} end } }
    sidebar.setup(core, {})
    sidebar.setup(core, {})

    local calls = 0
    -- Contamos cuántos handlers de comments:changed hay disparando un evento
    -- y viendo que M._refresh no se invoque más de una vez por emit.
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
