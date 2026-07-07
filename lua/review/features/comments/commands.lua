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
local function open_list(core, provider, title)
  local ctx = {}
  local ftitle = "review.nvim" .. (title and (": " .. title) or "")
  local function items_now()
    ctx.comments = sorted(provider())
    return to_qf_items(core, ctx.comments)
  end

  local items = items_now()
  if #items == 0 then
    vim.notify("review.nvim: no hay comentarios" .. (title and (" en " .. title) or ""), vim.log.levels.INFO)
    return
  end
  vim.fn.setqflist({}, " ", { title = ftitle, items = items })
  vim.cmd("copen")

  local qwin = vim.api.nvim_get_current_win()
  local qbuf = vim.api.nvim_win_get_buf(qwin)
  -- Barra de atajos visible.
  vim.wo[qwin].winbar =
    "%#Title# review.nvim %* ‹CR› ir · ‹d› borrar · ‹x› resolver · ‹q› cerrar"

  local function comment_at_cursor()
    return ctx.comments[vim.fn.line(".")]
  end
  local function refresh()
    local its = items_now()
    if #its == 0 then
      vim.cmd("cclose")
      return
    end
    local line = vim.fn.line(".")
    vim.fn.setqflist({}, "r", { title = ftitle, items = its })
    pcall(vim.api.nvim_win_set_cursor, qwin, { math.min(line, #its), 0 })
  end

  vim.keymap.set("n", "<CR>", function()
    local idx = vim.fn.line(".")
    vim.cmd("cclose")
    pcall(vim.cmd, idx .. "cc")
  end, { buffer = qbuf, nowait = true, desc = "review.nvim: ir al comentario y cerrar" })
  vim.keymap.set("n", "q", "<Cmd>cclose<CR>", { buffer = qbuf, nowait = true, desc = "review.nvim: cerrar lista" })
  vim.keymap.set("n", "d", function()
    local c = comment_at_cursor()
    if not c then return end
    core.state.remove(c.id)
    core.state.persist()
    rerender_file(core, c)
    refresh()
  end, { buffer = qbuf, nowait = true, desc = "review.nvim: borrar comentario" })
  vim.keymap.set("n", "x", function()
    local c = comment_at_cursor()
    if not c then return end
    core.state.update(c.id, { resolved = not c.resolved })
    core.state.persist()
    rerender_file(core, c)
    refresh()
  end, { buffer = qbuf, nowait = true, desc = "review.nvim: resolver/des-resolver" })
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
      vim.notify("review.nvim: el buffer actual no pertenece al repo", vim.log.levels.WARN)
      return
    end
    open_list(core, function() return core.state.for_path(rel) end, rel)
  end
  local function toggle_hidden()
    render.hidden = not render.hidden
    rerender_all(core)
    pcall(vim.cmd, "redrawstatus!") -- refrescar el gutter (corchetes) también
    vim.notify("review.nvim: comentarios " .. (render.hidden and "ocultos" or "visibles"), vim.log.levels.INFO)
  end
  local function peek() mode.peek_here(core) end
  local function peek_all() mode.peek_all(core) end
  local function peek_close() mode.close_all_peeks() end

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
  vim.api.nvim_create_user_command("ReviewPeek", peek, {})           -- ver comentario (flotante)
  vim.api.nvim_create_user_command("Rp", peek, {})
  vim.api.nvim_create_user_command("ReviewPeekAll", peek_all, {})    -- abrir un peek por comentario
  vim.api.nvim_create_user_command("Rpa", peek_all, {})
  vim.api.nvim_create_user_command("ReviewPeekClose", peek_close, {}) -- cerrar todos los flotantes
  vim.api.nvim_create_user_command("Rpc", peek_close, {})

  vim.keymap.set("n", leader .. "r", function() mode.edit_here(core) end, { desc = "Review: editar comentario de la línea" })
  vim.keymap.set("n", leader .. "c", function() mode.add_here(core, {}) end, { desc = "Review: comentar línea" })
  vim.keymap.set("v", leader .. "c", function() mode.add_here(core, {}) end, { desc = "Review: comentar rango" })
  vim.keymap.set("n", leader .. "d", function() mode.delete_here(core) end, { desc = "Review: borrar comentario" })
  vim.keymap.set("n", leader .. "x", function() mode.resolve_here(core) end, { desc = "Review: resolver comentario" })
  vim.keymap.set("n", leader .. "l", list_all, { desc = "Review: listar comentarios (global)" })
  vim.keymap.set("n", leader .. "L", list_file, { desc = "Review: listar comentarios del archivo" })
  vim.keymap.set("n", leader .. "h", toggle_hidden, { desc = "Review: ocultar/mostrar comentarios" })
  vim.keymap.set("n", leader .. "p", peek, { desc = "Review: ver comentario (flotante)" })
  vim.keymap.set("n", leader .. "P", peek_close, { desc = "Review: cerrar todos los flotantes" })
  vim.keymap.set("n", leader .. "o", peek_all, { desc = "Review: abrir peek de todos los comentarios" })
end

return M
