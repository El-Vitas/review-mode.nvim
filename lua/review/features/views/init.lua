local inline = require("review.features.views.inline")
local split = require("review.features.views.split")

-- Modo de vista GLOBAL (estilo VSCode): el modo (normal/inline/split) aplica a
-- TODOS los archivos. Al entrar a un archivo se re-aplica el modo actual; en
-- split, ambas columnas siguen al archivo activo.
local M = {}
-- Review es un modo PERMANENTE: normal/inline/split son sus 3 vistas, no hay
-- "salir de review". Por eso review siempre está activo y "normal" es la vista
-- por defecto.
M.mode = "normal"

local VALID_MODES = { normal = true, inline = true, split = true }
local applying = false

-- Colores del split. Distingue:
--  * línea MODIFICADA (DiffChange): tinte NARANJA suave en ambas columnas.
--  * texto exacto que cambió dentro de la línea (DiffText): ROJO a la izq
--    (lo quitado), VERDE a la der (lo agregado) -> se ve QUÉ cambió.
--  * línea BORRADA entera (única de la izq) / AGREGADA entera (única de la der):
--    ROJA / VERDE completa.
-- Override-ables.
local function ensure_diff_hl()
  -- Solo FONDO (sin fg ni bold, para no saturar).
  vim.api.nvim_set_hl(0, "ReviewDiffChange", { bg = "#44401d", default = true }) -- modificada: amarillo suave
  vim.api.nvim_set_hl(0, "ReviewDiffDelLine", { bg = "#37202a", default = true }) -- línea borrada entera (rojo oscuro)
  vim.api.nvim_set_hl(0, "ReviewDiffDelText", { bg = "#54232f", default = true }) -- texto quitado (rojo)
  vim.api.nvim_set_hl(0, "ReviewDiffAddLine", { bg = "#21331f", default = true }) -- línea agregada entera (verde oscuro)
  vim.api.nvim_set_hl(0, "ReviewDiffAddText", { bg = "#2c4a30", default = true }) -- texto agregado (verde)
  vim.api.nvim_set_hl(0, "ReviewDiffFiller", { bg = "#2a2b38", default = true }) -- relleno
end

-- Aplica el modo global a la ventana/buffer ACTUAL (la de edición).
local function apply_current(core)
  if applying then return end
  applying = true
  local ok, err = pcall(function()
    local win = vim.api.nvim_get_current_win()
    local buf = vim.api.nvim_get_current_buf()
    if split.is_scratch(buf) then return end -- ignorar el panel HEAD
    if M.mode == "inline" then
      split.teardown()
      if vim.bo[buf].buftype == "" then inline.render(core, buf) end
    elseif M.mode == "split" then
      inline.clear(core, buf)
      split.sync(core)
    else -- normal
      inline.clear(core, buf)
      split.teardown()
    end
    -- Review NUNCA debe compactar líneas: abrir los folds en la ventana del
    -- archivo del repo (en los 3 modos). Sin esto, un plugin de folds del
    -- usuario (treesitter/ufo) mostraría "+-- N lines" tapando lo que se revisa.
    if vim.bo[buf].buftype == "" and core.git.rel_path(buf) then
      pcall(function()
        vim.wo[win].foldenable = false
        vim.wo[win].foldlevel = 99
      end)
    end
  end)
  applying = false
  if not ok then vim.notify("review.nvim views: " .. tostring(err), vim.log.levels.DEBUG) end
end

--- Cambia el modo de vista GLOBAL y lo aplica al archivo actual. No-op si el
--- modo es inválido o ya es el actual.
function M.set(core, mode)
  if not VALID_MODES[mode] then return end
  if M.mode == mode then return end
  M.mode = mode
  apply_current(core)
  core.events.emit("view:changed", { mode = mode })
end

function M.setup(core, opts)
  M.mode = "normal"
  local group = vim.api.nvim_create_augroup("ReviewViews", { clear = true })

  ensure_diff_hl()
  vim.api.nvim_create_autocmd("ColorScheme", { group = group, callback = ensure_diff_hl })

  -- Invalidar el cache del HEAD de inline al recargar el archivo, y LIBERARLO al
  -- cerrar/eliminar el buffer (si no, el cache crece con cada archivo abierto).
  vim.api.nvim_create_autocmd({ "BufReadPost", "BufDelete", "BufWipeout" }, {
    group = group,
    callback = function(a) inline.invalidate(a.buf) end,
  })

  -- Review es permanente: al entrar a cualquier archivo del repo se aplica la
  -- vista actual (global, estilo VSCode) y se abren los folds.
  vim.api.nvim_create_autocmd({ "BufWinEnter", "BufEnter" }, {
    group = group,
    callback = function(a)
      if vim.bo[a.buf].buftype ~= "" or split.is_scratch(a.buf) then return end
      vim.schedule(function() apply_current(core) end)
    end,
  })

  -- Cierre manual de una columna del split: limpiar la sesión.
  vim.api.nvim_create_autocmd("WinClosed", {
    group = group,
    callback = function(a)
      local win = tonumber(a.match)
      if win then pcall(split.on_win_closed, win) end
    end,
  })

  -- Re-render en vivo al editar. Inline: repinta. Split: re-sincroniza para
  -- abrir/cerrar las 2 columnas según aparezcan/desaparezcan cambios vs HEAD.
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    group = group,
    callback = function(a)
      if vim.bo[a.buf].buftype ~= "" then return end
      if M.mode == "inline" then
        pcall(inline.render, core, a.buf)
      elseif M.mode == "split" and a.event == "TextChanged" then
        -- Solo al TERMINAR un cambio (no por cada tecla en insert): el diff
        -- nativo ya se actualiza live; esto solo detecta si volvió a HEAD.
        pcall(apply_current, core)
      end
    end,
  })

  local commands = require("review.features.views.commands")
  commands.setup(core, opts, M)
end

require("review.core").registry.register({ name = "views", setup = M.setup })

return M
