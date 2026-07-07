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
    if not c.reply_to then -- las respuestas no son objetivo directo del cursor
      local lo = math.min(c.lnum, c.end_lnum or c.lnum)
      local hi = math.max(c.lnum, c.end_lnum or c.lnum)
      if lnum >= lo and lnum <= hi then return c end
    end
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
    vim.notify("review.nvim: no comment on this line", vim.log.levels.INFO)
    return
  end
  open_popup({
    title = " Edit comment ",
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
    if not c.reply_to then
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

-- El peek se renderiza como VIRTUAL LINES insertadas debajo del bloque (estilo
-- GitHub inline): es parte del flujo del código, ocupa espacio, se mueve con el
-- scroll y NO sigue al cursor (no es un flotante). Clave por id de comentario.
local peek_ns = vim.api.nvim_create_namespace("review_peek")
M._peek_marks = {} -- id -> { bufnr, extmark_id }

--- Libera los peek marks de un buffer que se cerró/eliminó (evita que la tabla
--- crezca con entradas de buffers muertos).
function M.cleanup_buffer(bufnr)
  for id, info in pairs(M._peek_marks) do
    if info.bufnr == bufnr then M._peek_marks[id] = nil end
  end
end

--- Cierra (quita) TODOS los peeks inline.
function M.close_all_peeks()
  for _, info in pairs(M._peek_marks) do
    if info.bufnr and vim.api.nvim_buf_is_valid(info.bufnr) then
      pcall(vim.api.nvim_buf_del_extmark, info.bufnr, peek_ns, info.id)
    end
  end
  M._peek_marks = {}
end

local function pad(s, w)
  local dw = vim.fn.strdisplaywidth(s)
  if dw < w then return s .. string.rep(" ", w - dw) end
  return s
end

-- Construye las virtual lines (una tabla de chunks por línea) del peek de `c`.
-- `replies` (opcional) es la lista de respuestas del hilo, que se muestran
-- sangradas debajo del comentario padre.
local function build_virt_lines(c, replies)
  local range = (c.end_lnum and c.end_lnum ~= c.lnum)
      and string.format("L%d–%d", c.lnum, c.end_lnum)
      or ("L" .. c.lnum)
  local status = c.resolved and "resolved" or "open"
  local is_agent = c.author and c.author ~= "user"
  local icon = c.resolved and "✓" or (is_agent and "🤖" or "💬")
  if c.stale then icon = "⚠ " .. icon end
  local header = string.format(" %s  %s   ·   %s   ·   %s ", icon, status, range, c.author or "user")

  local body = {}
  for _, tl in ipairs(vim.split(c.text or "", "\n", { plain = true })) do
    body[#body + 1] = " " .. tl .. " "
  end
  if #body == 0 then body = { " (no text) " } end

  -- Respuestas del hilo, sangradas y con su autor.
  for _, r in ipairs(replies or {}) do
    local rauthor = r.author or "agent"
    local ricon = (rauthor ~= "user") and "🤖" or "💬"
    local rlines = vim.split(r.text or "", "\n", { plain = true })
    body[#body + 1] = string.format("   ↳ %s %s: %s ", ricon, rauthor, rlines[1] or "")
    for i = 2, #rlines do body[#body + 1] = "        " .. rlines[i] .. " " end
  end

  local w = vim.fn.strdisplaywidth(header)
  for _, l in ipairs(body) do w = math.max(w, vim.fn.strdisplaywidth(l)) end
  w = math.min(math.max(w, 40), 100)

  local bar = { "▌", "ReviewPeekBorder" } -- barra izquierda = borde del box
  local vlines = {}
  vlines[#vlines + 1] = { { "   ", "None" }, bar, { pad(header, w), "ReviewPeekHeader" } }
  vlines[#vlines + 1] = { { "   ", "None" }, bar, { pad(" " .. string.rep("─", w - 1), w), "ReviewPeekSep" } }
  for _, l in ipairs(body) do
    vlines[#vlines + 1] = { { "   ", "None" }, bar, { pad(l, w), "ReviewPeekNormal" } }
  end
  return vlines
end

-- Inserta el peek de `c` debajo de su última línea, en `bufnr`.
local function open_peek_inline(core, bufnr, c)
  local last = math.max(c.lnum, c.end_lnum or c.lnum)
  local anchor = clamp(bufnr, last) - 1
  local replies = core.state.replies and core.state.replies(c.id) or {}
  local id = vim.api.nvim_buf_set_extmark(bufnr, peek_ns, anchor, 0, {
    virt_lines = build_virt_lines(c, replies),
    virt_lines_above = false,
  })
  M._peek_marks[c.id] = { bufnr = bufnr, id = id }
end

--- TOGGLE del peek del comentario bajo el cursor. El detalle se inserta como
--- líneas reales debajo del bloque (parte del código): ocupa espacio, se mueve
--- con el scroll y NO se mueve solo ni sigue al cursor.
function M.peek_here(core)
  local bufnr = vim.api.nvim_get_current_buf()
  local rel = core.git.rel_path(bufnr)
  if not rel then return end
  local c = best_at(core, rel, clamp(bufnr, vim.fn.line(".")))
  if not c then
    vim.notify("review.nvim: no comment on this line", vim.log.levels.INFO)
    return
  end
  local info = M._peek_marks[c.id]
  if info then -- toggle off
    if info.bufnr and vim.api.nvim_buf_is_valid(info.bufnr) then
      pcall(vim.api.nvim_buf_del_extmark, info.bufnr, peek_ns, info.id)
    end
    M._peek_marks[c.id] = nil
    return
  end
  open_peek_inline(core, bufnr, c)
end

--- Abre el peek inline de CADA comentario del archivo actual ("abrir todos").
function M.peek_all(core)
  local bufnr = vim.api.nvim_get_current_buf()
  local rel = core.git.rel_path(bufnr)
  if not rel then return end
  local list = core.state.for_path(rel)
  if #list == 0 then
    vim.notify("review.nvim: no comments in this file", vim.log.levels.INFO)
    return
  end
  for _, c in ipairs(list) do
    if not c.reply_to and not M._peek_marks[c.id] then open_peek_inline(core, bufnr, c) end
  end
end

function M.delete_here(core)
  return M._delete_at(core, vim.api.nvim_get_current_buf(), vim.fn.line("."))
end

function M.resolve_here(core)
  return M._resolve_at(core, vim.api.nvim_get_current_buf(), vim.fn.line("."))
end

return M
