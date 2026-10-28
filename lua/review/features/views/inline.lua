local diff = require("review.features.views.diff")

local M = {}

-- Cache del contenido HEAD por buffer: `git show HEAD` es un subproceso caro y
-- render() se llama en CADA tecla (TextChangedI). El HEAD no cambia mientras
-- editás, así que lo corremos una sola vez por buffer. Se invalida al recargar
-- el archivo (BufReadPost, ver init.lua) o con M.invalidate(bufnr).
M._head_cache = {}

function M.invalidate(bufnr)
  if bufnr then M._head_cache[bufnr] = nil else M._head_cache = {} end
end

local function head_for(core, bufnr, relpath, root)
  local c = M._head_cache[bufnr]
  if c ~= nil then
    if c == false then return nil end
    return c
  end
  local head = core.git.head_content(relpath, root)
  M._head_cache[bufnr] = head or false
  return head
end

function M.clear(core, bufnr)
  vim.api.nvim_buf_clear_namespace(bufnr, core.ns.views, 0, -1)
end

-- Ancho para rellenar la barra de líneas borradas (fondo rojo de punta a punta,
-- como GitHub). Usa el ancho de la ventana que muestra el buffer; 0 si no hay.
local function win_width(bufnr)
  local winid = vim.fn.bufwinid(bufnr)
  if winid == -1 then return 0 end
  return vim.api.nvim_win_get_width(winid)
end

--- Pinta decoraciones inline de diff sobre bufnr, comparando el contenido HEAD
--- contra el contenido ACTUAL del buffer (en memoria, refleja cambios sin
--- guardar). Muestra las líneas borradas como líneas virtuales rojas encima de
--- su posición y las agregadas resaltadas en verde (vista unificada, estilo
--- GitHub "inline"). No-op si el archivo no pertenece al repo o no tiene HEAD.
function M.render(core, bufnr)
  M.clear(core, bufnr)

  local relpath = core.git.rel_path(bufnr)
  local root = core.git.root(bufnr)
  if not relpath or not root then return end

  local head_lines = head_for(core, bufnr, relpath, root)
  if not head_lines then return end

  local buf_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local hunks = diff.hunks_between(head_lines, buf_lines)
  if #hunks == 0 then return end

  local ns = core.ns.views
  local width = win_width(bufnr)
  local last = vim.api.nvim_buf_line_count(bufnr)

  for _, h in ipairs(hunks) do
    -- Líneas borradas: líneas virtuales rojas ancladas encima de la posición
    -- donde estaban (la primera línea nueva del hunk). Un borrado puro al final
    -- del archivo no tiene línea nueva debajo: va DEBAJO de la última línea.
    if #h.del_lines > 0 then
      local past_end = h.new_start > last
      local anchor = past_end and math.max(last - 1, 0) or math.max(h.new_start - 1, 0)
      local virt = {}
      for _, dl in ipairs(h.del_lines) do
        local text = dl
        if width > 0 and vim.fn.strdisplaywidth(text) < width then
          text = text .. string.rep(" ", width - vim.fn.strdisplaywidth(text))
        end
        virt[#virt + 1] = { { text, "DiffDelete" } }
      end
      pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, anchor, 0, {
        virt_lines = virt,
        virt_lines_above = not past_end,
      })
    end

    -- Líneas agregadas: resaltar toda la línea real en verde.
    for _, lnum in ipairs(h.add_lnums) do
      local row = lnum - 1
      if row >= 0 and row < last then
        pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, row, 0, {
          line_hl_group = "DiffAdd",
        })
      end
    end
  end
end

return M
