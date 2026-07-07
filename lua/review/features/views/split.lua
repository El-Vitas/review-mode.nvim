-- Vista SPLIT global (2 columnas), estilo VSCode, usando el MODO DIFF NATIVO.
-- Hay UNA sola sesión de split: un panel HEAD a la izquierda (scratch readonly,
-- con `winfixbuf` para que NO se le puedan abrir archivos) y la ventana real de
-- edición a la derecha. Al cambiar de archivo en la ventana real, el panel HEAD
-- se actualiza al HEAD de ese archivo (o se cierra si el archivo no tiene HEAD).
local diff = require("review.features.views.diff")

local M = {}
M._session = nil -- { left_win, buf = <scratch>, main_win }

-- Alinea línea-a-línea estilo VSCode (linematch/histogram), preservando flags.
local function ensure_diffopt()
  local parts = vim.split(vim.o.diffopt, ",", { trimempty = true })
  local has = {}
  for _, p in ipairs(parts) do has[p:match("^([%w%-]+)") or p] = true end
  local add = {}
  if not has["internal"] then add[#add + 1] = "internal" end
  if not has["filler"] then add[#add + 1] = "filler" end
  if not has["linematch"] then add[#add + 1] = "linematch:60" end
  if not has["algorithm"] then add[#add + 1] = "algorithm:histogram" end
  if not has["indent-heuristic"] then add[#add + 1] = "indent-heuristic" end
  if #add > 0 then vim.o.diffopt = vim.o.diffopt .. "," .. table.concat(add, ",") end
end

--- ¿Es `bufnr` el scratch del panel HEAD?
function M.is_scratch(bufnr)
  return M._session ~= nil and M._session.buf == bufnr
end

-- Fuerza TODAS las líneas visibles (sin folds de diff que compactan lo que no
-- cambió) + relleno diagonal, en una ventana en modo diff.
local function open_all_folds(win)
  if win and vim.api.nvim_win_is_valid(win) then
    pcall(function()
      vim.wo[win].foldenable = false
      vim.wo[win].foldlevel = 99
      vim.wo[win].fillchars = "diff:╱"
    end)
  end
end

-- Saca el diff de la ventana real y restaura sus opciones de fold/fillchars.
local function restore_main(s)
  local w = s.main_win
  if w and vim.api.nvim_win_is_valid(w) then
    pcall(vim.api.nvim_win_call, w, function() vim.cmd("diffoff") end)
    pcall(function()
      local sv = s.saved or {}
      vim.wo[w].foldenable = sv.fe ~= nil and sv.fe or true
      vim.wo[w].foldlevel = sv.fl or 99
      vim.wo[w].foldmethod = sv.fm or "manual"
      vim.wo[w].fillchars = sv.fc or ""
    end)
  end
end

--- Cierra la sesión de split (saca el diff de la ventana real y cierra el HEAD).
function M.teardown()
  local s = M._session
  M._session = nil
  if not s then return end
  restore_main(s)
  if s.left_win and vim.api.nvim_win_is_valid(s.left_win) then
    pcall(vim.api.nvim_win_close, s.left_win, true) -- scratch: bufhidden=wipe
  end
end

-- Crea el panel HEAD (izquierda) para la ventana `main_win`.
local function create_pane(main_win)
  -- Guardar opciones de fold/fillchars de la ventana real para restaurarlas.
  local saved = {
    fe = vim.wo[main_win].foldenable,
    fl = vim.wo[main_win].foldlevel,
    fm = vim.wo[main_win].foldmethod,
    fc = vim.wo[main_win].fillchars,
  }
  vim.api.nvim_set_current_win(main_win)
  vim.cmd("leftabove vsplit")
  local left_win = vim.api.nvim_get_current_win()
  local scratch = vim.api.nvim_create_buf(false, true)
  vim.bo[scratch].buftype = "nofile"
  vim.bo[scratch].bufhidden = "wipe"
  vim.api.nvim_win_set_buf(left_win, scratch)
  pcall(function() vim.wo[left_win].winfixbuf = true end) -- no abrir archivos acá
  return { left_win = left_win, buf = scratch, main_win = main_win, saved = saved }
end

--- Maneja el cierre manual de una de las ventanas del split: si se cierra el
--- panel HEAD o la ventana de edición, saca el diff de la que quede y limpia la
--- sesión (así no queda una columna pegada en modo diff).
function M.on_win_closed(win)
  local s = M._session
  if not s then return end
  if win == s.left_win then
    M._session = nil
    restore_main(s)
  elseif win == s.main_win then
    M._session = nil
    if s.left_win and vim.api.nvim_win_is_valid(s.left_win) then
      pcall(vim.api.nvim_win_close, s.left_win, true)
    end
  end
end

--- Sincroniza el panel HEAD con el archivo de la ventana ACTUAL (la de edición).
--- Crea la sesión si hace falta; la cierra si el archivo no tiene HEAD o no está
--- en el repo (queda en una sola columna).
function M.sync(core)
  local cur = vim.api.nvim_get_current_win()
  local s = M._session
  if s and cur == s.left_win then return end -- no actuar desde el panel HEAD

  local buf = vim.api.nvim_win_get_buf(cur)
  if vim.bo[buf].buftype ~= "" then return end -- ventana especial

  local rel = core.git.rel_path(buf)
  if not rel then M.teardown(); return end
  local root = core.git.root(buf)
  local head = core.git.head_content(rel, root)
  if not head then M.teardown(); return end -- sin HEAD: una sola columna

  ensure_diffopt()

  if not (s and s.left_win and vim.api.nvim_win_is_valid(s.left_win)) then
    s = create_pane(cur)
    M._session = s
  else
    s.main_win = cur
  end

  -- Rellenar el scratch con el HEAD del archivo actual.
  local scratch = s.buf
  vim.bo[scratch].modifiable = true
  vim.api.nvim_buf_set_lines(scratch, 0, -1, false, head)
  vim.bo[scratch].modifiable = false
  vim.bo[scratch].readonly = true
  local ft = vim.bo[buf].filetype
  if ft and ft ~= "" then vim.bo[scratch].filetype = ft end
  pcall(vim.api.nvim_buf_set_name, scratch, "review://head/" .. rel)
  -- Mismo resaltado que la derecha: arrancar treesitter en el panel HEAD (sin
  -- esto se ve más apagado/con otros colores).
  pcall(vim.treesitter.start, scratch)

  -- Diff en ambas ventanas + forzar recálculo (evita que el diff quede con
  -- estado viejo al reusar el buffer HEAD entre archivos → "todo cambiado").
  pcall(vim.api.nvim_win_call, s.left_win, function() vim.cmd("diffthis") end)
  pcall(vim.api.nvim_win_call, cur, function() vim.cmd("diffthis") end)
  -- Sin folds: mostrar TODAS las líneas (no compactar lo que no cambió).
  open_all_folds(s.left_win)
  open_all_folds(cur)
  vim.api.nvim_set_current_win(cur)
  pcall(vim.cmd, "diffupdate")
end

return M
