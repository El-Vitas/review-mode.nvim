local diff = require("review.features.views.diff")

-- Estado POR BUFFER: `_panels[bufnr] = { win = <left_win>, buf = <scratch>, main = <right_win> }`.
-- (Singleton global rompería si dos buffers estuvieran en modo split a la vez.)
local M = { _panels = {} }

-- Pinta en el panel HEAD (scratch) las líneas borradas con fondo rojo.
local function head_hl_deletes(core, scratch, head_count, hunks)
  if not hunks then return end
  local ns = core.ns.views
  for _, h in ipairs(hunks) do
    for i = 1, #h.del_lines do
      local row = h.old_start - 1 + (i - 1)
      if row >= 0 and row < head_count then
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

-- Dada una ventana de un panel, devuelve la ventana pareja (o nil).
local function paired_win(win)
  for _, p in pairs(M._panels) do
    if p.win == win then return p.main end
    if p.main == win then return p.win end
  end
  return nil
end

-- Sincronización de scroll ABSOLUTA vía WinScrolled (a diferencia de
-- `scrollbind`, que es relativo y se desfasa cuando los paneles tienen distinto
-- largo, y que la rueda del mouse no siempre propaga). Copiamos `topline`/
-- `leftcol` de la ventana que scrolleó a su pareja, en cualquier dirección.
local _syncing = false
local function install_sync()
  if M._sync_installed then return end
  M._sync_installed = true
  vim.api.nvim_create_autocmd("WinScrolled", {
    group = vim.api.nvim_create_augroup("ReviewSplitSync", { clear = true }),
    callback = function(args)
      if _syncing then return end
      local win = tonumber(args.match)
      if not win or not vim.api.nvim_win_is_valid(win) then return end
      local other = paired_win(win)
      if not other or not vim.api.nvim_win_is_valid(other) then return end

      _syncing = true
      local ok, view = pcall(vim.api.nvim_win_call, win, function()
        return vim.fn.winsaveview()
      end)
      if ok and view then
        pcall(vim.api.nvim_win_call, other, function()
          local v = vim.fn.winsaveview()
          if v.topline ~= view.topline or v.leftcol ~= view.leftcol then
            v.topline = view.topline
            v.leftcol = view.leftcol
            vim.fn.winrestview(v)
          end
        end)
      end
      _syncing = false
    end,
  })
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
  local head_count = #head_lines

  -- Rellenar el HEAD con líneas en blanco hasta igualar el largo del archivo
  -- real, para que ambos paneles lleguen al fondo juntos (evita el "se queda
  -- corto" cuando el archivo tiene más líneas que HEAD).
  local display = head_lines
  local cur_count = vim.api.nvim_buf_line_count(bufnr)
  if cur_count > head_count then
    display = vim.list_extend({}, head_lines)
    for i = head_count + 1, cur_count do display[i] = "" end
  end

  local target_win = vim.api.nvim_get_current_win()
  vim.cmd("topleft vsplit")
  local left_win = vim.api.nvim_get_current_win()

  local scratch = vim.api.nvim_create_buf(false, true)
  vim.bo[scratch].buftype = "nofile"
  vim.bo[scratch].bufhidden = "wipe"
  vim.bo[scratch].modifiable = true
  vim.api.nvim_buf_set_lines(scratch, 0, -1, false, display)
  vim.bo[scratch].modifiable = false
  vim.bo[scratch].readonly = true
  pcall(vim.api.nvim_buf_set_name, scratch, "review://head/" .. relpath)

  vim.api.nvim_win_set_buf(left_win, scratch)
  head_hl_deletes(core, scratch, head_count, hunks)   -- rojo en HEAD (izquierda)
  current_hl_adds(core, bufnr, hunks)                 -- verde en el archivo (derecha)

  M._panels[bufnr] = { win = left_win, buf = scratch, main = target_win }

  -- Sync de scroll absoluto (mouse + teclado, ambas direcciones).
  install_sync()

  -- Arrancar ambos alineados arriba de todo.
  vim.api.nvim_set_current_win(target_win)
  pcall(vim.cmd, "normal! gg")
  pcall(vim.api.nvim_win_set_cursor, left_win, { 1, 0 })
end

--- Cierra el panel izquierdo de HEAD del buffer `bufnr` si está abierto y
--- limpia el resaltado de agregados en el buffer real. Idempotente.
function M.close(core, bufnr)
  local p = M._panels[bufnr]
  if p and p.win and vim.api.nvim_win_is_valid(p.win) then
    pcall(vim.api.nvim_win_close, p.win, true)
  end
  -- El verde de agregados vive en el buffer real (ns.views); hay que borrarlo.
  if core and core.ns then
    pcall(vim.api.nvim_buf_clear_namespace, bufnr, core.ns.views, 0, -1)
  end
  M._panels[bufnr] = nil
end

return M
