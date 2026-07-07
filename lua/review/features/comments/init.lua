local render = require("review.features.comments.render")
local commands = require("review.features.comments.commands")

local M = {}

-- Define los highlight groups del resaltado de rango, con `default = true` para
-- que el usuario pueda sobreescribirlos en su config. Abiertos: fondo tipo
-- Visual + signo azul; resueltos: fondo tenue (CursorLine) + signo atenuado.
local function ensure_hl()
  vim.api.nvim_set_hl(0, "ReviewCommentLine", { link = "Visual", default = true })
  vim.api.nvim_set_hl(0, "ReviewCommentLineResolved", { link = "CursorLine", default = true })
  vim.api.nvim_set_hl(0, "ReviewCommentSign", { link = "DiagnosticInfo", default = true })
  vim.api.nvim_set_hl(0, "ReviewCommentSignResolved", { link = "Comment", default = true })
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
