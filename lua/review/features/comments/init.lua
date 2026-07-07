local render = require("review.features.comments.render")
local commands = require("review.features.comments.commands")

local M = {}

-- Define los highlight groups del resaltado de rango, con `default = true` para
-- que el usuario pueda sobreescribirlos en su config. Se usan COLORES PROPIOS
-- (no `Visual`) para que un comentario no se confunda con una selección: fondo
-- ámbar tenue + barra lateral peach para abiertos, y gris tenue para resueltos.
-- Tonos pensados para temas oscuros (p. ej. catppuccin macchiato).
local function ensure_hl()
  vim.api.nvim_set_hl(0, "ReviewCommentLine", { bg = "#3a3320", default = true })
  vim.api.nvim_set_hl(0, "ReviewCommentLineResolved", { bg = "#2a2b33", default = true })
  vim.api.nvim_set_hl(0, "ReviewCommentSign", { fg = "#f5a97f", bold = true, default = true })
  vim.api.nvim_set_hl(0, "ReviewCommentSignResolved", { fg = "#6e738d", default = true })
  -- Flotante del peek: fondo OPACO propio (para que no se vea transparente si
  -- el tema tiene NormalFloat sin fondo), borde y título peach.
  vim.api.nvim_set_hl(0, "ReviewPeekNormal", { bg = "#2a2d3d", fg = "#cad3f5", default = true })
  vim.api.nvim_set_hl(0, "ReviewPeekBorder", { bg = "#2a2d3d", fg = "#f5a97f", default = true })
  vim.api.nvim_set_hl(0, "ReviewPeekTitle", { bg = "#2a2d3d", fg = "#f5a97f", bold = true, default = true })
end

function M.setup(core, opts)
  opts = opts or {}

  local group = vim.api.nvim_create_augroup("ReviewComments", { clear = true })

  ensure_hl()
  -- `:colorscheme` limpia los highlights; re-definirlos al cambiar de tema.
  vim.api.nvim_create_autocmd("ColorScheme", { group = group, callback = ensure_hl })

  vim.api.nvim_create_autocmd({ "BufReadPost", "BufEnter" }, {
    group = group,
    callback = function(args)
      render.render(core, args.buf)
    end,
  })

  vim.api.nvim_create_autocmd("BufWritePost", {
    group = group,
    callback = function(args)
      render.sync_positions(core, args.buf)
      core.state.persist()
    end,
  })

  commands.setup(core, opts)
end

require("review.core").registry.register({ name = "comments", setup = M.setup })

return M
