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

-- Activa/desactiva scroll + cursor sincronizados en una ventana. `scrollbind`
-- lo maneja Neovim a nivel nativo (sin loops ni tirones) y cubre el scroll por
-- teclado; combinado con el relleno del HEAD (ambos paneles del mismo largo) y
-- arrancando alineados en la línea 1, se mantiene pegado.
local function set_bind(win, on)
  if win and vim.api.nvim_win_is_valid(win) then
    vim.wo[win].scrollbind = on
    vim.wo[win].cursorbind = on
  end
end

-- ¿`win` es una de las ventanas de algún panel de split activo?
local function is_panel_win(win)
  for _, p in pairs(M._panels) do
    if p.win == win or p.main == win then return true end
  end
  return false
end

-- La rueda del mouse NO siempre dispara la propagación de `scrollbind`. Por eso,
-- ante un scroll de la ventana CON FOCO (WinScrolled cubre mouse Y teclado)
-- forzamos `syncbind` desde ella para que la otra la siga.
--
-- Clave anti-loop: solo actuamos si la ventana que scrolleó es la ventana
-- ACTUAL. Cuando nuestro `syncbind` mueve la OTRA ventana (que no tiene foco),
-- ese WinScrolled se ignora → es estructuralmente imposible que se
-- retroalimente y entre en el bucle infinito que bloqueaba el editor. El
-- efecto secundario aceptable: scrollear con el mouse una ventana SIN foco no
-- arrastra a la otra (hacelo con foco, o con teclado que ya sincroniza nativo).
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
      if not is_panel_win(win) then return end
      -- Solo la ventana con foco es "driver"; su pareja se sincroniza sola.
      if win ~= vim.api.nvim_get_current_win() then return end
      _syncing = true
      pcall(vim.cmd, "syncbind")
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

  -- Diff en memoria (HEAD vs buffer actual): refleja cambios sin guardar.
  local buf_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local hunks = diff.hunks_between(head_lines, buf_lines)
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

  -- Mismo filetype que el archivo real → syntax highlighting (treesitter/
  -- syntax se enganchan al FileType). Sin esto el panel HEAD se ve gris.
  local ft = vim.bo[bufnr].filetype
  if ft and ft ~= "" then
    vim.bo[scratch].filetype = ft
  end

  vim.api.nvim_win_set_buf(left_win, scratch)
  head_hl_deletes(core, scratch, head_count, hunks)   -- rojo en HEAD (izquierda)
  current_hl_adds(core, bufnr, hunks)                 -- verde en el archivo (derecha)

  M._panels[bufnr] = { win = left_win, buf = scratch, main = target_win, head = head_lines }

  -- Alinear el panel HEAD a la posición ACTUAL del archivo (no saltar a la
  -- línea 1): así `:rvs` recuerda dónde estabas parado. Ponemos el cursor del
  -- HEAD en la misma línea (clampeada) y luego `syncbind` desde la ventana real
  -- iguala el scroll de ambos a esa posición.
  local cur = vim.api.nvim_win_get_cursor(target_win)
  local lc = vim.api.nvim_buf_line_count(scratch)
  pcall(vim.api.nvim_win_set_cursor, left_win, { math.min(cur[1], lc), 0 })
  set_bind(left_win, true)
  set_bind(target_win, true)
  install_sync() -- fuerza el sync también con la rueda del mouse (ventana con foco)
  vim.api.nvim_set_current_win(target_win)
  pcall(vim.cmd, "syncbind")
end

--- Re-pinta los highlights (rojo en HEAD, verde en el archivo) recomputando el
--- diff HEAD vs buffer actual. Se llama al editar, para que el resaltado siga
--- los cambios sin guardar. No-op si este buffer no tiene panel abierto.
function M.refresh(core, bufnr)
  local p = M._panels[bufnr]
  if not p then return end
  pcall(vim.api.nvim_buf_clear_namespace, p.buf, core.ns.views, 0, -1)
  pcall(vim.api.nvim_buf_clear_namespace, bufnr, core.ns.views, 0, -1)
  local buf_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local hunks = diff.hunks_between(p.head, buf_lines)
  head_hl_deletes(core, p.buf, #(p.head or {}), hunks)
  current_hl_adds(core, bufnr, hunks)
end

--- Cierra el panel izquierdo de HEAD del buffer `bufnr` si está abierto y
--- limpia el resaltado de agregados en el buffer real. Idempotente.
function M.close(core, bufnr)
  local p = M._panels[bufnr]
  if p then
    -- Apagar el bind en la ventana real que sobrevive, si no seguiría
    -- moviéndose sola tras cerrar el panel.
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
