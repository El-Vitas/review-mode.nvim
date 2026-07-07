local render = require("review.features.comments.render")

local M = {}

local function clamp(bufnr, lnum)
  local last = vim.api.nvim_buf_line_count(bufnr)
  if last < 1 then return 1 end
  if lnum < 1 then return 1 end
  if lnum > last then return last end
  return lnum
end

local function find_at(core, rel, lnum)
  for _, c in ipairs(core.state.for_path(rel)) do
    local lo = math.min(c.lnum, c.end_lnum or c.lnum)
    local hi = math.max(c.lnum, c.end_lnum or c.lnum)
    if lnum >= lo and lnum <= hi then return c end
  end
  return nil
end

function M._add(core, bufnr, lnum, end_lnum, text)
  local rel = core.git.rel_path(bufnr)
  if not rel then return nil end

  if text == nil or vim.trim(text) == "" then return nil end

  lnum = clamp(bufnr, lnum or 1)
  end_lnum = clamp(bufnr, end_lnum or lnum)
  if end_lnum < lnum then
    lnum, end_lnum = end_lnum, lnum
  end

  local c = core.state.add({ path = rel, lnum = lnum, end_lnum = end_lnum, text = text })
  render.render(core, bufnr)
  core.state.persist()
  return c
end

function M._delete_at(core, bufnr, lnum)
  local rel = core.git.rel_path(bufnr)
  if not rel then return false end

  lnum = clamp(bufnr, lnum)
  local c = find_at(core, rel, lnum)
  if not c then return false end

  local ok = core.state.remove(c.id)
  render.render(core, bufnr)
  core.state.persist()
  return ok
end

function M._resolve_at(core, bufnr, lnum)
  local rel = core.git.rel_path(bufnr)
  if not rel then return false end

  lnum = clamp(bufnr, lnum)
  local c = find_at(core, rel, lnum)
  if not c then return false end

  local ok = core.state.update(c.id, { resolved = not c.resolved })
  render.render(core, bufnr)
  core.state.persist()
  return ok
end

--- Actualiza el texto del comentario que cubre `lnum` (núcleo testeable).
--- @return boolean true si actualizó
function M._update_at(core, bufnr, lnum, text)
  local rel = core.git.rel_path(bufnr)
  if not rel then return false end
  if text == nil or vim.trim(text) == "" then return false end
  lnum = clamp(bufnr, lnum)
  local c = find_at(core, rel, lnum)
  if not c then return false end
  local ok = core.state.update(c.id, { text = text })
  render.render(core, bufnr)
  core.state.persist()
  return ok
end

-- Popup de edición de texto multi-línea, reutilizado por add/edit. Arranca en
-- insert; Enter hace saltos de línea (comentario multi-línea, estilo GitHub);
-- se guarda con <CR> (normal) o <C-s>, se cancela con q o <C-c>. NUNCA se mapea
-- <Esc> a cancelar (así salir de insert no borra lo escrito).
local function open_popup(o)
  local Popup = require("nui.popup")
  local title = o.title or " Comentario "
  local popup = Popup({
    enter = true,
    focusable = true,
    border = {
      style = "rounded",
      text = {
        top = title,
        top_align = "left",
        bottom = " Esc y Enter para enviar · q para cancelar ",
        bottom_align = "right",
      },
    },
    position = "50%",
    size = { width = 74, height = 10 },
    buf_options = { filetype = "markdown" },
  })

  popup:mount()

  if o.initial and o.initial ~= "" then
    vim.api.nvim_buf_set_lines(popup.bufnr, 0, -1, false, vim.split(o.initial, "\n", { plain = true }))
  end

  local done = false
  local function confirm()
    if done then return end
    done = true
    local lines = vim.api.nvim_buf_get_lines(popup.bufnr, 0, -1, false)
    popup:unmount()
    o.on_save(table.concat(lines, "\n"))
  end
  local function cancel()
    if done then return end
    done = true
    popup:unmount()
  end

  -- Enter en modo NORMAL envía (en insert, Enter hace salto de línea para
  -- comentarios multi-línea). `q` en normal cancela.
  popup:map("n", "<CR>", confirm, { noremap = true })
  popup:map("n", "q", cancel, { noremap = true })

  -- Arrancar escribiendo (salvo edición, que conviene revisar antes).
  if o.start_insert ~= false then
    vim.schedule(function() vim.cmd("startinsert") end)
  end
end

function M.add_here(core, opts)
  opts = opts or {}
  local bufnr = vim.api.nvim_get_current_buf()

  local mode_v = vim.fn.mode()
  local lnum, end_lnum
  if mode_v == "v" or mode_v == "V" or mode_v == "\22" then
    lnum = vim.fn.line("v")
    end_lnum = vim.fn.line(".")
    vim.cmd("normal! \27")
  else
    lnum = vim.fn.line(".")
    end_lnum = lnum
  end

  local rango = (end_lnum ~= lnum)
      and string.format(" Comentario L%d-%d ", math.min(lnum, end_lnum), math.max(lnum, end_lnum))
      or string.format(" Comentario L%d ", lnum)

  open_popup({
    title = rango,
    on_save = function(text)
      M._add(core, bufnr, lnum, end_lnum, text)
    end,
  })
end

--- Edita el comentario que cubre la línea actual: abre el popup pre-cargado con
--- su texto. Si no hay comentario en la línea, avisa y no hace nada.
function M.edit_here(core)
  local bufnr = vim.api.nvim_get_current_buf()
  local rel = core.git.rel_path(bufnr)
  if not rel then return end
  local lnum = vim.fn.line(".")
  local c = find_at(core, rel, clamp(bufnr, lnum))
  if not c then
    vim.notify("review.nvim: no hay comentario en esta línea", vim.log.levels.INFO)
    return
  end
  open_popup({
    title = " Editar comentario ",
    initial = c.text or "",
    start_insert = false,
    on_save = function(text)
      M._update_at(core, bufnr, c.lnum, text)
    end,
  })
end

-- El comentario MÁS ESPECÍFICO que cubre `lnum` (el de rango más chico; ante
-- empate, el que empieza más abajo). Así el peek muestra UN comentario, no todos.
local function best_at(core, rel, lnum)
  local best, best_span
  for _, c in ipairs(core.state.for_path(rel)) do
    local lo = math.min(c.lnum, c.end_lnum or c.lnum)
    local hi = math.max(c.lnum, c.end_lnum or c.lnum)
    if lnum >= lo and lnum <= hi then
      local span = hi - lo
      if not best or span < best_span or (span == best_span and lo > best.lnum) then
        best, best_span = c, span
      end
    end
  end
  return best
end

-- Peeks abiertos: { win, buf, line, code_win }. Varios a la vez, independientes.
M._peek_wins = {}
local peek_ns = vim.api.nvim_create_namespace("review_peek")

--- Cierra TODOS los flotantes de peek abiertos.
function M.close_all_peeks()
  for _, e in ipairs(M._peek_wins) do
    if e.win and vim.api.nvim_win_is_valid(e.win) then pcall(vim.api.nvim_win_close, e.win, true) end
  end
  M._peek_wins = {}
end

-- Oculta cada peek cuya línea ancla NO esté visible en su ventana de código (en
-- vez de dejar que Neovim lo "clave" al borde al scrollear fuera de vista), y lo
-- reaparece al volver. Se instala una vez.
local function install_peek_visibility()
  if M._peek_vis_installed then return end
  M._peek_vis_installed = true
  vim.api.nvim_create_autocmd({ "WinScrolled", "CursorMoved", "CursorMovedI" }, {
    group = vim.api.nvim_create_augroup("ReviewPeekVis", { clear = true }),
    callback = function()
      local alive = {}
      for _, e in ipairs(M._peek_wins) do
        if e.win and vim.api.nvim_win_is_valid(e.win) then
          alive[#alive + 1] = e
          if e.code_win and vim.api.nvim_win_is_valid(e.code_win) then
            local top = vim.api.nvim_win_call(e.code_win, function() return vim.fn.line("w0") end)
            local bot = vim.api.nvim_win_call(e.code_win, function() return vim.fn.line("w$") end)
            local visible = e.line >= top and e.line <= bot
            pcall(vim.api.nvim_win_set_config, e.win, { hide = not visible })
          end
        end
      end
      M._peek_wins = alive
    end,
  })
end

-- Construye las líneas del cuerpo del peek (con padding) y su ancho.
local function peek_lines(c)
  local range = (c.end_lnum and c.end_lnum ~= c.lnum)
      and string.format("L%d–%d", c.lnum, c.end_lnum)
      or ("L" .. c.lnum)
  local status = c.resolved and "resuelto" or "abierto"
  local icon = c.resolved and "✓" or "💬"
  local header = string.format(" %s  %s   ·   %s   ·   %s", icon, status, range, c.author or "user")

  local body = {}
  for _, tl in ipairs(vim.split(c.text or "", "\n", { plain = true })) do
    body[#body + 1] = "  " .. tl
  end
  if #body == 0 then body = { "  (sin texto)" } end

  local width = vim.fn.strdisplaywidth(header)
  for _, l in ipairs(body) do width = math.max(width, vim.fn.strdisplaywidth(l)) end
  width = math.min(math.max(width + 2, 44), 90)

  local sep = " " .. string.rep("─", width - 2)
  local lines = { header, sep }
  for _, l in ipairs(body) do lines[#lines + 1] = l end
  return lines, width, range
end

-- Abre un flotante anclado al comentario `c` en `code_win`.
local function open_peek_float(c, code_win)
  local lines, width, range = peek_lines(c)
  local height = math.min(#lines, 22)

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = "wipe"
  -- Header y separador con su propio color.
  vim.api.nvim_buf_set_extmark(buf, peek_ns, 0, 0, { end_row = 1, hl_group = "ReviewPeekHeader", hl_eol = true })
  vim.api.nvim_buf_set_extmark(buf, peek_ns, 1, 0, { end_row = 2, hl_group = "ReviewPeekSep", hl_eol = true })

  local first = math.min(c.lnum, c.end_lnum or c.lnum)
  local win = vim.api.nvim_open_win(buf, false, {
    relative = "win",
    win = code_win,
    bufpos = { first - 1, 0 }, -- ancla a la 1ª línea del comentario en el buffer
    row = 1,
    col = 0,
    width = width,
    height = height,
    style = "minimal",
    border = "rounded",
    title = " Comentario " .. range .. " ",
    title_pos = "left",
    footer = " q cerrar · Q cerrar todos ",
    footer_pos = "right",
    noautocmd = true,
  })
  vim.wo[win].winhighlight = "Normal:ReviewPeekNormal,FloatBorder:ReviewPeekBorder,FloatTitle:ReviewPeekTitle,FloatFooter:ReviewPeekSep"
  vim.wo[win].winblend = 0
  table.insert(M._peek_wins, { win = win, buf = buf, line = first, code_win = code_win })
  install_peek_visibility()

  -- Botones: q = cerrar este; Q = cerrar todos.
  vim.keymap.set("n", "q", function() pcall(vim.api.nvim_win_close, win, true) end, { buffer = buf, nowait = true })
  vim.keymap.set("n", "<Esc>", function() pcall(vim.api.nvim_win_close, win, true) end, { buffer = buf, nowait = true })
  vim.keymap.set("n", "Q", M.close_all_peeks, { buffer = buf, nowait = true })
end

--- Abre un flotante anclado al comentario de la línea actual. Cada llamada abre
--- uno NUEVO e independiente; se mueve con el código al scrollear y se oculta si
--- te alejás. Se mantiene hasta cerrarlo (q este, Q/<leader>rP todos).
function M.peek_here(core)
  local bufnr = vim.api.nvim_get_current_buf()
  local rel = core.git.rel_path(bufnr)
  if not rel then return end
  local c = best_at(core, rel, clamp(bufnr, vim.fn.line(".")))
  if not c then
    vim.notify("review.nvim: no hay comentario en esta línea", vim.log.levels.INFO)
    return
  end
  open_peek_float(c, vim.api.nvim_get_current_win())
end

--- Abre un flotante por CADA comentario del archivo actual (uno anclado a cada
--- bloque). "Abrir todos".
function M.peek_all(core)
  local bufnr = vim.api.nvim_get_current_buf()
  local rel = core.git.rel_path(bufnr)
  if not rel then return end
  local win = vim.api.nvim_get_current_win()
  local list = core.state.for_path(rel)
  if #list == 0 then
    vim.notify("review.nvim: no hay comentarios en este archivo", vim.log.levels.INFO)
    return
  end
  for _, c in ipairs(list) do
    open_peek_float(c, win)
  end
end

function M.delete_here(core)
  return M._delete_at(core, vim.api.nvim_get_current_buf(), vim.fn.line("."))
end

function M.resolve_here(core)
  return M._resolve_at(core, vim.api.nvim_get_current_buf(), vim.fn.line("."))
end

return M
