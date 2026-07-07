local render = require("review.features.comments.render")
local commands = require("review.features.comments.commands")

local M = {}

-- Define los highlight groups, con `default = true` para que el usuario pueda
-- sobreescribirlos. Se usan COLORES PROPIOS (azul, no `Visual` ni café) para no
-- confundir un comentario con una selección. Tonos para temas oscuros
-- (p. ej. catppuccin macchiato).
local function ensure_hl()
  -- Resaltado del rango: fondo azul tenue + barra lateral azul.
  vim.api.nvim_set_hl(0, "ReviewCommentLine", { bg = "#2c3a52", default = true })
  vim.api.nvim_set_hl(0, "ReviewCommentLine2", { bg = "#26436b", default = true }) -- tono alterno
  vim.api.nvim_set_hl(0, "ReviewCommentLineResolved", { bg = "#2a2b38", default = true })
  vim.api.nvim_set_hl(0, "ReviewCommentSign", { fg = "#8aadf4", bold = true, default = true })
  vim.api.nvim_set_hl(0, "ReviewCommentSignResolved", { fg = "#6e738d", default = true })
  -- Paleta cíclica del corchete (un color por comentario).
  local palette = { "#8aadf4", "#a6da95", "#c6a0f6", "#f5a97f", "#8bd5ca", "#eed49f" }
  for i, hex in ipairs(palette) do
    vim.api.nvim_set_hl(0, "ReviewCommentSign" .. i, { fg = hex, bold = true, default = true })
  end
  -- Badge al final de la línea: chip con fondo azul y bordecito (edge).
  vim.api.nvim_set_hl(0, "ReviewCommentBadge", { bg = "#3b4b71", fg = "#cad3f5", default = true })
  vim.api.nvim_set_hl(0, "ReviewCommentBadgeEdge", { bg = "#3b4b71", fg = "#8aadf4", default = true })
  vim.api.nvim_set_hl(0, "ReviewCommentBadgeResolved", { bg = "#33343f", fg = "#8087a2", default = true })
  vim.api.nvim_set_hl(0, "ReviewCommentBadgeEdgeResolved", { bg = "#33343f", fg = "#6e738d", default = true })
  -- Flotante del peek: fondo OPACO propio (para que no se vea transparente si
  -- el tema tiene NormalFloat sin fondo), borde y título azul.
  vim.api.nvim_set_hl(0, "ReviewPeekNormal", { bg = "#1e2030", fg = "#cad3f5", default = true })
  vim.api.nvim_set_hl(0, "ReviewPeekBorder", { bg = "#1e2030", fg = "#8aadf4", default = true })
  vim.api.nvim_set_hl(0, "ReviewPeekTitle", { bg = "#1e2030", fg = "#8aadf4", bold = true, default = true })
  vim.api.nvim_set_hl(0, "ReviewPeekHeader", { bg = "#2c3a52", fg = "#8aadf4", bold = true, default = true })
  vim.api.nvim_set_hl(0, "ReviewPeekSep", { bg = "#1e2030", fg = "#5b6078", default = true })
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
