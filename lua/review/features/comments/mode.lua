local render = require("review.features.comments.render")

local M = {}

-- Extmarks temporales del rango de un comentario que se está escribiendo.
local pending_ns = vim.api.nvim_create_namespace("review_pending_comment")

local function clamp(bufnr, lnum)
  local last = vim.api.nvim_buf_line_count(bufnr)
  if last < 1 then return 1 end
  if lnum < 1 then return 1 end
  if lnum > last then return last end
  return lnum
end

-- El comentario MÁS ESPECÍFICO que cubre `lnum`: el de rango más chico y, ante
-- empate, el que empieza más abajo. Es el mismo que muestra el peek, así que
-- editar, resolver o borrar actúa sobre el comentario que se está viendo aunque
-- haya otros solapados. Respuestas y comentarios de ARCHIVO no son objetivo
-- directo del cursor por línea (los file_level ni siquiera tienen lnum).
local function find_at(core, rel, lnum)
  local best, best_span
  for _, c in ipairs(core.state.for_path(rel)) do
    if not c.reply_to and not c.file_level then
      local lo = math.min(c.lnum, c.end_lnum or c.lnum)
      local hi = math.max(c.lnum, c.end_lnum or c.lnum)
      if lnum >= lo and lnum <= hi then
        local span = hi - lo
        if not best or span < best_span or (span == best_span and lo > best.lnum) then
          best, best_span = c, span
        end
      end
    end
  end
  return best
end

local function is_last_line(bufnr, lnum)
  return lnum >= vim.api.nvim_buf_line_count(bufnr)
end

-- Comentario de ARCHIVO sobre el que actuar: el último NO resuelto; si están
-- todos resueltos, el último. nil si no hay ninguno. (Para varios, usar la lista.)
local function file_target(core, rel)
  local last, last_open
  for _, c in ipairs(core.state.for_path(rel)) do
    if c.file_level and not c.reply_to then
      last = c
      if not c.resolved then last_open = c end
    end
  end
  return last_open or last
end

-- El comentario a accionar desde el cursor: el de LÍNEA si lo hay; si no, y
-- estás en la última línea, el de ARCHIVO. Así no "molesta" a los de línea.
local function target_at(core, rel, bufnr, lnum)
  local c = find_at(core, rel, lnum)
  if c then return c end
  if is_last_line(bufnr, lnum) then return file_target(core, rel) end
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

  -- Guardar el texto de la línea ancla: malla de seguridad para detectar
  -- re-anclaje incierto (stale) tras un cambio de código en disco (roadmap §1.3).
  local anchor_text = ""
  do
    local lines = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)
    anchor_text = lines[1] or ""
  end

  local c = core.state.add({ path = rel, lnum = lnum, end_lnum = end_lnum, text = text, anchor_text = anchor_text })
  render.render(core, bufnr)
  core.state.persist()
  return c
end

function M._delete_at(core, bufnr, lnum)
  local rel = core.git.rel_path(bufnr)
  if not rel then return false end

  lnum = clamp(bufnr, lnum)
  local c = target_at(core, rel, bufnr, lnum)
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
  local c = target_at(core, rel, bufnr, lnum)
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
  local c = target_at(core, rel, bufnr, lnum)
  if not c then return false end
  local ok = core.state.update(c.id, { text = text })
  render.render(core, bufnr)
  core.state.persist()
  return ok
end

--- Actualiza el texto del comentario `id`. Lo usan los popups de edición: el
--- comentario se elige al abrir el popup, y mientras se escribe pueden cambiar
--- las líneas (el agente edita el archivo) o aparecer otro comentario solapado.
--- @return boolean true si actualizó
function M._update_by_id(core, bufnr, id, text)
  if text == nil or vim.trim(text) == "" then return false end
  local ok = core.state.update(id, { text = text })
  if not ok then return false end
  if vim.api.nvim_buf_is_valid(bufnr) then render.render(core, bufnr) end
  core.state.persist()
  return true
end

-- Popup de edición de texto multi-línea, reutilizado por add/edit. Arranca en
-- insert; Enter hace saltos de línea (comentario multi-línea, estilo GitHub);
-- se guarda con <CR> (normal) o <C-s>, se cancela con q o <C-c>. NUNCA se mapea
-- <Esc> a cancelar (así salir de insert no borra lo escrito).
local function open_popup(o)
  local Popup = require("nui.popup")
  local title = o.title or " Comment "
  local popup = Popup({
    enter = true,
    focusable = true,
    border = {
      style = "rounded",
      text = {
        top = title,
        top_align = "left",
        bottom = " Esc then Enter to send · q to cancel ",
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
      and string.format(" Comment L%d-%d ", math.min(lnum, end_lnum), math.max(lnum, end_lnum))
      or string.format(" Comment L%d ", lnum)

  -- El rango se ancla con extmarks mientras se escribe: si el archivo cambia
  -- en el medio (el agente inserta líneas arriba), el comentario cae en la
  -- línea correcta y no en el número viejo.
  local lo, hi = math.min(lnum, end_lnum), math.max(lnum, end_lnum)
  vim.api.nvim_buf_clear_namespace(bufnr, pending_ns, 0, -1) -- restos de un popup cancelado
  local m_lo = vim.api.nvim_buf_set_extmark(bufnr, pending_ns, lo - 1, 0, {})
  local m_hi = vim.api.nvim_buf_set_extmark(bufnr, pending_ns, hi - 1, 0, {})
  open_popup({
    title = rango,
    on_save = function(text)
      if not vim.api.nvim_buf_is_valid(bufnr) then return end
      local p_lo = vim.api.nvim_buf_get_extmark_by_id(bufnr, pending_ns, m_lo, {})
      local p_hi = vim.api.nvim_buf_get_extmark_by_id(bufnr, pending_ns, m_hi, {})
      vim.api.nvim_buf_del_extmark(bufnr, pending_ns, m_lo)
      vim.api.nvim_buf_del_extmark(bufnr, pending_ns, m_hi)
      M._add(core, bufnr, (p_lo[1] or lo - 1) + 1, (p_hi[1] or hi - 1) + 1, text)
    end,
  })
end

--- Núcleo testeable: agrega un comentario de ARCHIVO (file_level, sin línea).
--- @return table|nil el comentario creado
function M._add_file(core, bufnr, text)
  local rel = core.git.rel_path(bufnr)
  if not rel then return nil end
  if text == nil or vim.trim(text) == "" then return nil end
  local c = core.state.add({ path = rel, file_level = true, text = text })
  render.render(core, bufnr)
  core.state.persist()
  return c
end

--- Abre el popup para dejar un comentario a nivel de ARCHIVO (aparece abajo del
--- todo). No depende de la línea del cursor.
function M.add_file_here(core)
  local bufnr = vim.api.nvim_get_current_buf()
  if not core.git.rel_path(bufnr) then
    vim.notify("review.nvim: file not in repo", vim.log.levels.INFO)
    return
  end
  open_popup({
    title = " File comment ",
    on_save = function(text) M._add_file(core, bufnr, text) end,
  })
end

--- Comentario sobre el que actuar desde el cursor del buffer actual, y el
--- buffer. Si no hay ninguno, avisa y devuelve nil.
--- @return integer|nil bufnr, table|nil comment
local function target_here(core)
  local bufnr = vim.api.nvim_get_current_buf()
  local rel = core.git.rel_path(bufnr)
  if not rel then return nil end
  local c = target_at(core, rel, bufnr, clamp(bufnr, vim.fn.line(".")))
  if not c then
    vim.notify("review.nvim: no comment on this line", vim.log.levels.INFO)
    return nil
  end
  return bufnr, c
end

--- Edita el comentario que cubre la línea actual: abre el popup pre-cargado con
--- su texto. Si no hay comentario en la línea, avisa y no hace nada.
function M.edit_here(core)
  local bufnr, c = target_here(core)
  if not c then return end
  open_popup({
    title = c.file_level and " Edit file comment " or " Edit comment ",
    initial = c.text or "",
    start_insert = false,
    on_save = function(text) M._update_by_id(core, bufnr, c.id, text) end,
  })
end

-- Namespace de los extmarks de highlight DENTRO de la tarjeta flotante del peek.
local peek_ns = vim.api.nvim_create_namespace("review_peek")

--- Compat: al cerrar/eliminar un buffer, cerrar la tarjeta del peek si estaba
--- abierta (no dejar el float colgado).
function M.cleanup_buffer(_)
  if M.close_peek_float then M.close_peek_float() end
end

-- Envuelve `text` por palabras a un ancho `w` (respeta saltos de línea propios).
local function wrap_text(text, w)
  local out = {}
  for _, para in ipairs(vim.split(text or "", "\n", { plain = true })) do
    if para == "" then
      out[#out + 1] = ""
    else
      local line = ""
      for word in para:gmatch("%S+") do
        if line == "" then
          line = word
        elseif vim.fn.strdisplaywidth(line .. " " .. word) <= w then
          line = line .. " " .. word
        else
          out[#out + 1] = line
          line = word
        end
      end
      out[#out + 1] = line
    end
  end
  if #out == 0 then out = { "" } end
  return out
end

-- ── Peek FLOTANTE estilo tarjeta GitHub, DOS paneles apilados ───────────────
-- Panel de arriba = lo que dijiste vos (author=user); panel de abajo = lo que
-- indicó claude (author≠user). Cada panel scrollea INDEPENDIENTE y muestra un
-- scrollbar SOLO si su contenido desborda. Anclado a la línea del comentario
-- (no persigue el cursor). Footer con acciones. Cierra con q/Esc o al salir.
M._peek_wins = {}
M._peek_id = nil

function M.close_peek_float()
  for _, w in ipairs(M._peek_wins) do
    if w and vim.api.nvim_win_is_valid(w) then pcall(vim.api.nvim_win_close, w, true) end
  end
  M._peek_wins = {}
  M._peek_id = nil
end

-- "2026-07-07T23:04:33Z" -> "2026-07-07 23:04"
local function short_time(iso)
  if type(iso) ~= "string" then return "" end
  local d, t = iso:match("^(%d%d%d%d%-%d%d%-%d%d)T(%d%d:%d%d)")
  if d then return d .. " " .. t end
  return iso
end

local PEEK_FW = 72      -- ancho de los paneles
local PEEK_PANE_MAX = 9 -- alto máximo por panel antes de scrollear

-- Líneas (+ highlight por línea) de un panel a partir de una lista de mensajes.
local function pane_content(msgs, empty_txt)
  local ls, sp = {}, {}
  local function add(t, h) ls[#ls + 1] = t; sp[#sp + 1] = h end
  for i, m in ipairs(msgs) do
    local is_agent = m.author and m.author ~= "user"
    add(" " .. (is_agent and "🤖 " or "● ") .. (m.author or "user") .. "  ·  " .. short_time(m.created_at),
      is_agent and "ReviewPeekWhoAgent" or "ReviewPeekWho")
    for _, tl in ipairs(wrap_text(m.text, PEEK_FW - 5)) do
      add("   " .. tl, "ReviewPeekNormal")
    end
    if i < #msgs then add("", nil) end
  end
  if #ls == 0 then add(" " .. (empty_txt or "(empty)"), "ReviewPeekFoot") end
  return ls, sp
end

-- Dibuja el "thumb" del scrollbar de `pane_win` en `sb_buf` (h filas).
local function draw_scrollbar(sb_buf, pane_win, total, h)
  if not vim.api.nvim_win_is_valid(pane_win) or not vim.api.nvim_buf_is_valid(sb_buf) then return end
  local info = vim.fn.getwininfo(pane_win)[1]
  local top = (info and info.topline or 1) - 1
  local size = math.min(h, math.max(1, math.floor(h * h / total + 0.5)))
  local denom = math.max(1, total - h)
  local pos = math.max(0, math.min(h - size, math.floor((h - size) * (top / denom) + 0.5)))
  local rows = {}
  for i = 1, h do rows[i] = (i - 1 >= pos and i - 1 < pos + size) and "█" or "│" end
  vim.bo[sb_buf].modifiable = true
  vim.api.nvim_buf_set_lines(sb_buf, 0, -1, false, rows)
  vim.bo[sb_buf].modifiable = false
end

local function open_peek_float(core, origin_buf, c)
  M.close_peek_float()
  local thread = core.state.thread(c.id)

  -- Separar: lo mío (user) vs lo de claude (agent/otros).
  local mine, theirs = {}, {}
  for _, m in ipairs(thread) do
    if m.author and m.author ~= "user" then theirs[#theirs + 1] = m else mine[#mine + 1] = m end
  end

  local range
  if c.file_level or not c.lnum then
    range = "file"
  elseif c.end_lnum and c.end_lnum ~= c.lnum then
    range = "L" .. c.lnum .. "–" .. c.end_lnum
  else
    range = "L" .. c.lnum
  end

  -- UNA sola tarjeta: sección "user" + divisor + sección "claude". Robusto
  -- (un solo flotante bien posicionado, sin apilar ventanas frágiles).
  local ls, sp = {}, {}
  local function add(t, h) ls[#ls + 1] = t; sp[#sp + 1] = h end
  local uls, usp = pane_content(mine, "(no user comment)")
  for i = 1, #uls do add(uls[i], usp[i]) end
  add(string.rep("─", PEEK_FW - 1), "ReviewPeekSep")
  local tls, tsp = pane_content(theirs, "(no reply from claude yet)")
  for i = 1, #tls do add(tls[i], tsp[i]) end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, ls)
  for i, hl in ipairs(sp) do
    if hl then
      pcall(vim.api.nvim_buf_set_extmark, buf, peek_ns, i - 1, 0,
        { end_row = i - 1, end_col = #ls[i], hl_group = hl })
    end
  end
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = "wipe"

  local total = #ls
  local height = math.min(total, 16)
  -- CENTRADO en la pantalla (como el popup de escribir comentario).
  local row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1)
  local col = math.max(0, math.floor((vim.o.columns - PEEK_FW) / 2))
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    row = row,
    col = col,
    width = PEEK_FW,
    height = height,
    style = "minimal",
    border = "rounded",
    title = " 💬 " .. c.path .. "  ·  " .. range .. "  ·  " .. (c.resolved and "resolved" or "open") .. " ",
    title_pos = "left",
    footer = " x resolve · d delete · e edit · q close ",
    footer_pos = "right",
  })
  vim.wo[win].winhighlight =
    "NormalFloat:ReviewPeekNormal,FloatBorder:ReviewPeekBorder,FloatTitle:ReviewPeekHeader,FloatFooter:ReviewPeekFoot"
  vim.wo[win].wrap = false
  vim.wo[win].cursorline = true
  M._peek_wins = { win }
  M._peek_id = c.id

  -- Scrollbar SOLO si el contenido total desborda el alto del float.
  if total > height then
    local sbb = vim.api.nvim_create_buf(false, true)
    vim.bo[sbb].bufhidden = "wipe"
    local sbw = vim.api.nvim_open_win(sbb, false, {
      relative = "win", win = win, anchor = "NW", row = 0, col = PEEK_FW - 1,
      width = 1, height = height, style = "minimal", focusable = false, zindex = 250,
    })
    vim.wo[sbw].winhighlight = "NormalFloat:ReviewPeekSep"
    M._peek_wins[#M._peek_wins + 1] = sbw
    draw_scrollbar(sbb, win, total, height)
    vim.api.nvim_create_autocmd({ "WinScrolled", "CursorMoved" }, {
      buffer = buf,
      callback = function() draw_scrollbar(sbb, win, total, height) end,
    })
  end

  local function close() M.close_peek_float() end
  local function rerender()
    if vim.api.nvim_buf_is_valid(origin_buf) then
      pcall(require("review.features.comments.render").render, core, origin_buf)
    end
  end
  local km = { buffer = buf, nowait = true, silent = true }
  vim.keymap.set("n", "q", close, km)
  vim.keymap.set("n", "<Esc>", close, km)
  vim.keymap.set("n", "x", function()
    core.state.update(c.id, { resolved = not c.resolved }); core.state.persist(); close(); rerender()
  end, km)
  vim.keymap.set("n", "d", function()
    core.state.remove(c.id); core.state.persist(); close(); rerender()
  end, km)
  vim.keymap.set("n", "e", function()
    close()
    open_popup({ title = " Edit comment ", initial = c.text or "", start_insert = false,
      on_save = function(text) M._update_by_id(core, origin_buf, c.id, text) end })
  end, km)

  -- Cerrar al salir de la ventana del float.
  vim.api.nvim_create_autocmd("WinLeave", {
    buffer = buf,
    once = true,
    callback = function() vim.schedule(close) end,
  })
end

--- TOGGLE del peek del comentario bajo el cursor. Abre UNA tarjeta FLOTANTE
--- centrada con el hilo. Solo puede haber un peek abierto: abrir otro cierra el
--- anterior (open_peek_float ya cierra el previo al inicio).
function M.peek_here(core)
  local bufnr, c = target_here(core)
  if not c then return end
  -- toggle: si ya está abierto para este comentario, cerrar.
  if M._peek_id == c.id and #M._peek_wins > 0 then
    M.close_peek_float()
    return
  end
  open_peek_float(core, bufnr, c)
end

function M.delete_here(core)
  return M._delete_at(core, vim.api.nvim_get_current_buf(), vim.fn.line("."))
end

function M.resolve_here(core)
  return M._resolve_at(core, vim.api.nvim_get_current_buf(), vim.fn.line("."))
end

return M
