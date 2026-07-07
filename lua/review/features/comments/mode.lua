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

-- Comentarios cuyo rango cubre `lnum`.
local function all_at(core, rel, lnum)
  local out = {}
  for _, c in ipairs(core.state.for_path(rel)) do
    local lo = math.min(c.lnum, c.end_lnum or c.lnum)
    local hi = math.max(c.lnum, c.end_lnum or c.lnum)
    if lnum >= lo and lnum <= hi then out[#out + 1] = c end
  end
  return out
end

-- Ventana flotante persistente del peek (una sola a la vez).
M._peek_win = nil
M._peek_buf = nil

--- Cierra el flotante del peek si está abierto.
function M.close_peek()
  if M._peek_win and vim.api.nvim_win_is_valid(M._peek_win) then
    pcall(vim.api.nvim_win_close, M._peek_win, true)
  end
  M._peek_win = nil
  M._peek_buf = nil
end

--- Muestra en un flotante FIJO (bordeado, con fondo) el/los comentario(s)
--- completos de la línea actual. Queda anclado cerca del bloque y NO sigue al
--- cursor ni se mueve con el scroll: permanece abierto hasta que lo cierres.
--- Es un toggle: si ya hay uno abierto, lo cierra.
function M.peek_here(core)
  if M._peek_win and vim.api.nvim_win_is_valid(M._peek_win) then
    M.close_peek()
    return
  end

  local bufnr = vim.api.nvim_get_current_buf()
  local rel = core.git.rel_path(bufnr)
  if not rel then return end
  local matches = all_at(core, rel, clamp(bufnr, vim.fn.line(".")))
  if #matches == 0 then
    vim.notify("review.nvim: no hay comentario en esta línea", vim.log.levels.INFO)
    return
  end

  local lines = {}
  for i, c in ipairs(matches) do
    if i > 1 then lines[#lines + 1] = "───────────────" end
    local range = (c.end_lnum and c.end_lnum ~= c.lnum)
        and string.format("L%d-%d", c.lnum, c.end_lnum)
        or ("L" .. c.lnum)
    local status = c.resolved and "✓ resuelto" or "💬 abierto"
    lines[#lines + 1] = string.format("%s · `%s` · _%s_", status, range, c.author or "user")
    lines[#lines + 1] = ""
    for _, tl in ipairs(vim.split(c.text or "", "\n", { plain = true })) do
      lines[#lines + 1] = tl
    end
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].filetype = "markdown"
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = "wipe"

  local width = 20
  for _, l in ipairs(lines) do width = math.max(width, vim.fn.strdisplaywidth(l)) end
  width = math.min(width + 1, 80)
  local height = math.min(#lines, 15)

  -- Posición FIJA en pantalla, cerca del bloque: tomamos la posición de pantalla
  -- de la primera línea del comentario en el momento de abrir. relative="editor"
  -- => no se mueve con el scroll ni sigue al cursor.
  local first = math.min(matches[1].lnum, matches[1].end_lnum or matches[1].lnum)
  local sp = vim.fn.screenpos(vim.api.nvim_get_current_win(), first, 1)
  local row = (sp.row and sp.row > 0) and sp.row or math.floor((vim.o.lines - height) / 2)
  local col = (sp.col and sp.col > 0) and (sp.col - 1) or 4
  if row + height + 2 > vim.o.lines then row = math.max(sp.row - height - 2, 0) end
  if col + width + 2 > vim.o.columns then col = math.max(vim.o.columns - width - 2, 0) end

  local win = vim.api.nvim_open_win(buf, false, {
    relative = "editor",
    row = row,
    col = col,
    width = width,
    height = height,
    style = "minimal",
    border = "rounded",
    title = " Comentario ",
    title_pos = "left",
    noautocmd = true,
  })
  -- Fondo OPACO propio: si el tema tiene NormalFloat transparente, el flotante
  -- se ve "hueco". Forzamos un fondo sólido y sin blend.
  vim.wo[win].winhighlight = "Normal:ReviewPeekNormal,FloatBorder:ReviewPeekBorder,FloatTitle:ReviewPeekTitle"
  vim.wo[win].winblend = 0
  M._peek_win = win
  M._peek_buf = buf

  -- Si el usuario entra al flotante, q/Esc lo cierran.
  vim.keymap.set("n", "q", M.close_peek, { buffer = buf, nowait = true })
  vim.keymap.set("n", "<Esc>", M.close_peek, { buffer = buf, nowait = true })
end

function M.delete_here(core)
  return M._delete_at(core, vim.api.nvim_get_current_buf(), vim.fn.line("."))
end

function M.resolve_here(core)
  return M._resolve_at(core, vim.api.nvim_get_current_buf(), vim.fn.line("."))
end

return M
