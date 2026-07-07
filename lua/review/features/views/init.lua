local inline = require("review.features.views.inline")
local split = require("review.features.views.split")

local M = {}
M.mode = {}

local VALID_MODES = { normal = true, inline = true, split = true }

local function clear_current(core, bufnr, current)
  if current == "inline" then
    inline.clear(core, bufnr)
  elseif current == "split" then
    split.close(core, bufnr)
  end
end

local function apply(core, bufnr, mode)
  if mode == "inline" then
    inline.render(core, bufnr)
  elseif mode == "split" then
    split.open(core, bufnr)
  end
  -- "normal": nada que aplicar, el buffer se ve como siempre.
end

--- Cambia el modo de vista de bufnr. Limpia la vista previa antes de aplicar
--- la nueva. Idempotente si mode == modo actual. No-op si mode es inválido.
function M.set(core, bufnr, mode)
  if not VALID_MODES[mode] then return end
  local current = M.mode[bufnr] or "normal"
  if current == mode then return end

  clear_current(core, bufnr, current)
  apply(core, bufnr, mode)
  M.mode[bufnr] = mode

  core.events.emit("view:changed", { bufnr = bufnr, mode = mode })
end

function M.setup(core, opts)
  M.mode = {}
  -- Limpiar el estado por-buffer cuando el buffer se destruye, para que
  -- Neovim no recicle su bufnr con un modo heredado (bug de estado obsoleto).
  vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
    group = vim.api.nvim_create_augroup("ReviewViews", { clear = true }),
    callback = function(a)
      M.mode[a.buf] = nil
      split.close(core, a.buf)
    end,
  })
  local commands = require("review.features.views.commands")
  commands.setup(core, opts, M)
end

require("review.core").registry.register({ name = "views", setup = M.setup })

return M
