local diff = require("review.features.views.diff")

-- Estado POR BUFFER: `_panels[bufnr] = { win = <left_win>, buf = <scratch>, main = <right_win> }`.
-- (Singleton global rompería si dos buffers estuvieran en modo split a la vez.)
local M = { _panels = {} }

-- Pinta en el panel HEAD (scratch) las líneas borradas con fondo rojo.
local function head_hl_deletes(core, scratch, head_lines, hunks)
  if not hunks then return end
  local ns = core.ns.views
  for _, h in ipairs(hunks) do
    for i = 1, #h.del_lines do
      local row = h.old_start - 1 + (i - 1)
      if row >= 0 and row < #head_lines then
        pcall(vim.api.nvim_buf_set_extmark, scratch, ns, row, 0, { line_hl_group = "DiffDelete" })
      end
    end
  end
end

-- Pinta en el buffer real (derecha) las líneas agregadas con fondo verde.
local function current_hl_adds(core, bufnr, hunks)
  if not hunks then return end
  local ns = core.ns.views
  local last = vim.api.nvim_buf_line_count(bufnr)
  for _, h in ipairs(hunks) do
    for _, lnum in ipairs(h.add_lnums) do
      local row = lnum - 1
      if row >= 0 and row < last then
        pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, row, 0, { line_hl_group = "DiffAdd" })
      end
    end
  end
end

-- Activa/desactiva scroll y cursor sincronizados en una ventana.
local function set_bind(win, on)
  if win and vim.api.nvim_win_is_valid(win) then
    vim.wo[win].scrollbind = on
    vim.wo[win].cursorbind = on
  end
end

--- Devuelve el bufnr real dueño de un buffer scratch de panel HEAD (o nil).
--- Permite que los comandos ejecutados DESDE el panel izquierdo actúen sobre
--- el archivo real, no sobre el scratch.
--- @param scratch_bufnr integer
--- @return integer|nil
function M.owner_of(scratch_bufnr)
  for real, p in pairs(M._panels) do
    if p.buf == scratch_bufnr then return real end
  end
  return nil
end

--- Abre el panel izquierdo con el contenido HEAD del archivo del buffer actual.
--- Avisa y no abre nada si el archivo no tiene HEAD (nuevo / fuera de git).
function M.open(core, bufnr)
  local relpath = core.git.rel_path(bufnr)
  if not relpath then
    vim.notify("review.nvim: buffer fuera del repo, no se puede abrir split", vim.log.levels.WARN)
    return
  end

  -- Raíz resuelta desde el buffer (no desde el cwd) para que HEAD y hunks
  -- salgan del repo correcto aunque el cwd de nvim esté en otro lado.
  local root = core.git.root(bufnr)
  local head_lines = core.git.head_content(relpath, root)
  if not head_lines then
    vim.notify(
      "review.nvim: '" .. relpath .. "' no tiene versión en HEAD (archivo nuevo)",
      vim.log.levels.WARN
    )
    return
  end

  M.close(core, bufnr) -- cierra un panel previo de ESTE buffer, si lo hubiera

  local hunks = root and diff.hunks_for(relpath, root) or nil

  local target_win = vim.api.nvim_get_current_win()
  vim.cmd("topleft vsplit")
  local left_win = vim.api.nvim_get_current_win()

  local scratch = vim.api.nvim_create_buf(false, true)
  vim.bo[scratch].buftype = "nofile"
  vim.bo[scratch].bufhidden = "wipe"
  vim.bo[scratch].modifiable = true
  vim.api.nvim_buf_set_lines(scratch, 0, -1, false, head_lines)
  vim.bo[scratch].modifiable = false
  vim.bo[scratch].readonly = true
  pcall(vim.api.nvim_buf_set_name, scratch, "review://head/" .. relpath)

  vim.api.nvim_win_set_buf(left_win, scratch)
  head_hl_deletes(core, scratch, head_lines, hunks)   -- rojo en HEAD (izquierda)
  current_hl_adds(core, bufnr, hunks)                 -- verde en el archivo (derecha)

  M._panels[bufnr] = { win = left_win, buf = scratch, main = target_win }

  -- Scroll + cursor sincronizados: ambas ventanas se mueven juntas (como un
  -- diff side-by-side). syncbind alinea el punto de partida.
  set_bind(left_win, true)
  set_bind(target_win, true)
  vim.api.nvim_set_current_win(target_win)
  pcall(function()
    vim.cmd("normal! gg")
    vim.cmd("syncbind")
  end)
end

--- Cierra el panel izquierdo de HEAD del buffer `bufnr` si está abierto y
--- limpia el resaltado de agregados en el buffer real. Idempotente.
function M.close(core, bufnr)
  local p = M._panels[bufnr]
  if p then
    -- Apagar el bind en la ventana real que sobrevive, si no volvería a
    -- moverse sola tras cerrar el panel.
    set_bind(p.main, false)
    if p.win and vim.api.nvim_win_is_valid(p.win) then
      pcall(vim.api.nvim_win_close, p.win, true)
    end
  end
  -- El verde de agregados vive en el buffer real (ns.views); hay que borrarlo.
  if core and core.ns then
    pcall(vim.api.nvim_buf_clear_namespace, bufnr, core.ns.views, 0, -1)
  end
  M._panels[bufnr] = nil
end

return M
