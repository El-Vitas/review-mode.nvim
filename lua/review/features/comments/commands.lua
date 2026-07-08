local mode = require("review.features.comments.mode")
local render = require("review.features.comments.render")

local M = {}

-- Arma los items de quickfix a partir de una lista de comentarios.
-- `filename` va ABSOLUTO (root .. path): la quickfix resuelve contra el cwd,
-- pero c.path es relativo a la raíz del repo.
local function to_qf_items(core, comments)
  local root = core.git.root() or ""
  local base = (root ~= "") and (root .. "/") or ""
  local items = {}
  for _, c in ipairs(comments) do
    local prefix = c.resolved and "[✓] " or ""
    local text = (c.text or ""):gsub("[\r\n]+", " ")
    table.insert(items, {
      filename = base .. c.path,
      lnum = c.lnum,
      col = 1,
      text = prefix .. text,
    })
  end
  return items
end

-- Ordena por archivo y luego por línea, para una lista prolija.
local function sorted(comments)
  local list = vim.deepcopy(comments)
  table.sort(list, function(a, b)
    if a.path ~= b.path then return a.path < b.path end
    return (a.lnum or 0) < (b.lnum or 0)
  end)
  return list
end

-- Re-renderiza los extmarks del archivo de `c` si está abierto en un buffer.
local function rerender_file(core, c)
  local root = core.git.root() or ""
  local bnr = vim.fn.bufnr((root ~= "" and (root .. "/") or "") .. c.path)
  if bnr ~= -1 and vim.api.nvim_buf_is_loaded(bnr) then
    pcall(render.render, core, bnr)
  end
end

-- Abre la quickfix con la lista de comentarios que devuelve `provider()`.
-- Sobre una entrada: <CR> ir (y cerrar), d borrar, x resolver/des-resolver,
-- q cerrar. Una winbar arriba muestra los atajos. `provider` se re-consulta
-- para refrescar la lista tras d/x.
local FILTER_CYCLE = { "all", "open", "resolved", "mine", "agent", "answered", "unanswered" }

--- Filtra una lista de comentarios según `mode`. `replies_fn(id)` devuelve las
--- respuestas de un comentario (para answered/unanswered). Función pura/testeable.
function M._filter(list, replies_fn, mode)
  local function answered(c) return #(replies_fn(c.id) or {}) > 0 end
  local pred = {
    all = function() return true end,
    open = function(c) return not c.resolved end,
    resolved = function(c) return c.resolved end,
    mine = function(c) return (c.author or "user") == "user" end,
    agent = function(c) return (c.author or "user") ~= "user" end,
    answered = function(c) return answered(c) end,
    unanswered = function(c) return not answered(c) end,
  }
  local f = pred[mode] or pred.all
  local out = {}
  for _, c in ipairs(list) do if f(c) then out[#out + 1] = c end end
  return out
end

local function open_list(core, provider, title)
  local ctx = { filter = "all", raw = 0 }
  local ftitle = "review.nvim" .. (title and (": " .. title) or "")

  local function apply_filter(list)
    -- La lista muestra solo comentarios top-level (las respuestas viven en el
    -- hilo del padre, visible en el peek).
    local top = {}
    for _, c in ipairs(list) do if not c.reply_to then top[#top + 1] = c end end
    return M._filter(top, function(id) return core.state.replies(id) end, ctx.filter)
  end
  local function items_now()
    local raw = provider()
    ctx.raw = #raw
    ctx.comments = sorted(apply_filter(raw))
    return to_qf_items(core, ctx.comments)
  end

  local items = items_now()
  if ctx.raw == 0 then
    vim.notify("review.nvim: no comments" .. (title and (" in " .. title) or ""), vim.log.levels.INFO)
    return
  end
  vim.fn.setqflist({}, " ", { title = ftitle, items = items })
  vim.cmd("copen")

  local qwin = vim.api.nvim_get_current_win()
  local qbuf = vim.api.nvim_win_get_buf(qwin)

  local function update_winbar()
    vim.wo[qwin].winbar = "%#Title# review.nvim %* ‹Enter› go · ‹d› delete · ‹x› resolve · ‹f› filter:"
      .. ctx.filter .. " · ‹q› close"
  end
  update_winbar()

  local function comment_at_cursor()
    return ctx.comments[vim.fn.line(".")]
  end
  -- Refresca la lista in situ. Solo cierra si NO queda ningún comentario en
  -- total (el filtro puede dejar la vista vacía y eso es válido).
  local function refresh()
    local its = items_now()
    if ctx.raw == 0 then
      vim.cmd("cclose")
      return
    end
    local line = vim.fn.line(".")
    vim.fn.setqflist({}, "r", { title = ftitle, items = its })
    if #its > 0 then pcall(vim.api.nvim_win_set_cursor, qwin, { math.min(line, #its), 0 }) end
  end

  vim.keymap.set("n", "f", function()
    local i = 1
    for k, v in ipairs(FILTER_CYCLE) do if v == ctx.filter then i = k end end
    ctx.filter = FILTER_CYCLE[i % #FILTER_CYCLE + 1]
    refresh()
    update_winbar()
  end, { buffer = qbuf, nowait = true, desc = "review.nvim: cycle filter" })

  vim.keymap.set("n", "<CR>", function()
    local idx = vim.fn.line(".")
    vim.cmd("cclose")
    pcall(vim.cmd, idx .. "cc")
  end, { buffer = qbuf, nowait = true, desc = "review.nvim: go to comment and close" })
  vim.keymap.set("n", "q", "<Cmd>cclose<CR>", { buffer = qbuf, nowait = true, desc = "review.nvim: close list" })
  vim.keymap.set("n", "d", function()
    local c = comment_at_cursor()
    if not c then return end
    core.state.remove(c.id)
    core.state.persist()
    rerender_file(core, c)
    refresh()
  end, { buffer = qbuf, nowait = true, desc = "review.nvim: delete comment" })
  vim.keymap.set("n", "x", function()
    local c = comment_at_cursor()
    if not c then return end
    core.state.update(c.id, { resolved = not c.resolved })
    core.state.persist()
    rerender_file(core, c)
    refresh()
  end, { buffer = qbuf, nowait = true, desc = "review.nvim: resolve/unresolve" })
end

-- Re-renderiza los comentarios en todos los buffers cargados (tras un toggle).
local function rerender_all(core)
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(b) then
      pcall(render.render, core, b)
    end
  end
end

function M.setup(core, opts)
  opts = opts or {}
  local leader = opts.leader or "<leader>r"

  local function edit() mode.edit_here(core) end
  local function list_all() open_list(core, function() return core.state.all() end, nil) end
  local function list_file()
    local rel = core.git.rel_path(0)
    if not rel then
      vim.notify("review.nvim: current buffer is not in the repo", vim.log.levels.WARN)
      return
    end
    open_list(core, function() return core.state.for_path(rel) end, rel)
  end
  local function toggle_hidden()
    render.hidden = not render.hidden
    rerender_all(core)
    pcall(vim.cmd, "redrawstatus!") -- refrescar el gutter (corchetes) también
    vim.notify("review.nvim: comments " .. (render.hidden and "hidden" or "visible"), vim.log.levels.INFO)
  end
  local function peek() mode.peek_here(core) end

  -- Comandos largos + alias cortos (todos comandos REALES; las minúsculas las
  -- resuelve plugin/review.lua vía cnoreabbrev).
  vim.api.nvim_create_user_command("ReviewCommentMode", edit, {})   -- editar comentario de la línea
  vim.api.nvim_create_user_command("Rcm", edit, {})
  vim.api.nvim_create_user_command("ReviewList", list_all, {})      -- listar todos (global)
  vim.api.nvim_create_user_command("Rl", list_all, {})
  vim.api.nvim_create_user_command("ReviewListFile", list_file, {}) -- listar del archivo actual
  vim.api.nvim_create_user_command("Rlf", list_file, {})
  vim.api.nvim_create_user_command("ReviewToggle", toggle_hidden, {}) -- ocultar/mostrar
  vim.api.nvim_create_user_command("Rt", toggle_hidden, {})
  vim.api.nvim_create_user_command("ReviewPeek", peek, {})           -- ver comentario (tarjeta flotante)
  vim.api.nvim_create_user_command("Rp", peek, {})

  vim.keymap.set("n", leader .. "e", function() mode.edit_here(core) end, { desc = "Review: edit comment on line" })
  vim.keymap.set("n", leader .. "c", function() mode.add_here(core, {}) end, { desc = "Review: comment line" })
  vim.keymap.set("v", leader .. "c", function() mode.add_here(core, {}) end, { desc = "Review: comment range" })
  vim.keymap.set("n", leader .. "d", function() mode.delete_here(core) end, { desc = "Review: delete comment" })
  vim.keymap.set("n", leader .. "x", function() mode.resolve_here(core) end, { desc = "Review: resolve comment" })
  vim.keymap.set("n", leader .. "l", list_all, { desc = "Review: list comments (global)" })
  vim.keymap.set("n", leader .. "L", list_file, { desc = "Review: list comments (file)" })
  vim.keymap.set("n", leader .. "h", toggle_hidden, { desc = "Review: hide/show comments" })
  vim.keymap.set("n", leader .. "p", peek, { desc = "Review: peek comment" })
end

return M
