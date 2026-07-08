local render = require("review.features.comments.render")
local commands = require("review.features.comments.commands")
local gutter = require("review.features.comments.gutter")
local mode = require("review.features.comments.mode")

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
  -- Comentarios del agente (violeta) y con anclaje incierto (ámbar).
  vim.api.nvim_set_hl(0, "ReviewCommentAgent", { bg = "#3a2c52", default = true })
  vim.api.nvim_set_hl(0, "ReviewCommentStale", { bg = "#4a3a1d", default = true })
  vim.api.nvim_set_hl(0, "ReviewCommentSignAgent", { fg = "#c6a0f6", bold = true, default = true })
  vim.api.nvim_set_hl(0, "ReviewCommentBadgeAgent", { bg = "#3a2c52", fg = "#d8c4f5", default = true })
  vim.api.nvim_set_hl(0, "ReviewCommentBadgeEdgeAgent", { bg = "#3a2c52", fg = "#c6a0f6", default = true })
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
  -- Tarjeta del peek flotante: cabecera de cada mensaje del hilo + footer.
  vim.api.nvim_set_hl(0, "ReviewPeekWho", { bg = "#1e2030", fg = "#8aadf4", bold = true, default = true })
  vim.api.nvim_set_hl(0, "ReviewPeekWhoAgent", { bg = "#1e2030", fg = "#c6a0f6", bold = true, default = true })
  vim.api.nvim_set_hl(0, "ReviewPeekFoot", { bg = "#1e2030", fg = "#6e738d", default = true })
end

function M.setup(core, opts)
  opts = opts or {}

  local group = vim.api.nvim_create_augroup("ReviewComments", { clear = true })

  ensure_hl()
  -- `:colorscheme` limpia los highlights; re-definirlos al cambiar de tema.
  vim.api.nvim_create_autocmd("ColorScheme", { group = group, callback = ensure_hl })

  -- Al ABRIR el archivo (recién leído del disco): re-localizar por contenido
  -- (`anchor_text`) por si el archivo cambió mientras el buffer estaba cerrado
  -- (p. ej. el agente lo editó), y persistir la corrección. Luego renderizar.
  vim.api.nvim_create_autocmd("BufReadPost", {
    group = group,
    callback = function(args)
      render.relocate(core, args.buf)
      core.state.persist()
      render.render(core, args.buf)
    end,
  })
  vim.api.nvim_create_autocmd("BufEnter", {
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

  -- Liberar peek marks de buffers cerrados/eliminados.
  vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
    group = group,
    callback = function(args) mode.cleanup_buffer(args.buf) end,
  })

  -- Al cambiar los comentarios (incluidos los que agrega/edita el agente por
  -- RPC), re-renderizar los buffers de archivos del repo que estén abiertos, así
  -- los comentarios nuevos obtienen su extmark ancla sin esperar a un BufEnter.
  -- Se SINCRONIZA primero (sync_positions) para capturar cualquier drift del
  -- extmark por ediciones sin guardar, y recién ahí se repinta: si no, render
  -- reubicaría el extmark en el `lnum` viejo y perdería el desplazamiento por
  -- gravity. sync_positions solo emite comments:changed si algo cambió → converge
  -- (sin loop); render.render no muta estado.
  core.events.on("comments:changed", function()
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_loaded(b) and vim.bo[b].buftype == "" then
        pcall(render.sync_positions, core, b)
        pcall(render.render, core, b)
      end
    end
  end)

  -- El agente (o cualquiera) editó el archivo en disco y reconcile aplicó el
  -- patch al buffer; re-sincronizamos posiciones y marcamos stale los dudosos.
  core.events.on("buffer:reconciled", function(payload)
    if payload and payload.bufnr and vim.api.nvim_buf_is_valid(payload.bufnr) then
      render.reconcile(core, payload.bufnr)
    end
  end)

  commands.setup(core, opts)
  gutter.setup(core)
end

require("review.core").registry.register({ name = "comments", setup = M.setup })

return M
