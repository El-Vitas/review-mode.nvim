local M = {}

M._subscribed = false
M._core = nil

--- Helper PURO: set de relpaths con ≥1 comentario. No toca neo-tree, no tiene
--- efectos secundarios. Reutilizable por quien quiera marcar el árbol.
--- @param core table  el core de review.nvim (usa core.state.all())
--- @return table<string, boolean>
function M.files_with_comments(core)
  local set = {}
  for _, c in ipairs(core.state.all()) do
    if c.path then
      set[c.path] = true
    end
  end
  return set
end

--- Verdadero si hay una ventana neo-tree visible en el tab actual.
local function neotree_window_open()
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local buf = vim.api.nvim_win_get_buf(win)
    if vim.bo[buf].filetype == "neo-tree" then
      return true
    end
  end
  return false
end

--- Refresca el indicador/redibujado del árbol si está abierto. No fuerza apertura.
--- Fase actual: recalcula el set puro; el marcado visual fino queda documentado
--- como fase secundaria (ver Task 4).
function M._refresh()
  if not M._core then return end
  if not neotree_window_open() then return end
  local ok, command = pcall(require, "neo-tree.command")
  if not ok then return end
  M._files_with_comments_cache = M.files_with_comments(M._core)
  pcall(command.execute, { action = "refresh" })
end

--- Abre/enfoca el árbol de neo-tree en el source pedido.
--- @param kind "changed"|"all"
local function open_sidebar(kind)
  local ok, command = pcall(require, "neo-tree.command")
  if not ok then
    vim.notify("review.nvim: neo-tree.nvim is not installed, sidebar disabled", vim.log.levels.WARN)
    return
  end
  -- Recalcular el cache de archivos-con-comentarios al abrir, para que el
  -- marcador no quede obsoleto si se agregaron/borraron comentarios con el
  -- árbol cerrado (M._refresh se saltea cuando la ventana no está abierta).
  if M._core then M._files_with_comments_cache = M.files_with_comments(M._core) end
  local source = kind == "all" and "filesystem" or "git_status"
  command.execute({ source = source, action = "show", position = "right" })

  -- Abrir con las carpetas CERRADAS (por defecto neo-tree las deja expandidas y
  -- es un caos). Colapsamos todo tras renderizar, usando el comando nativo de
  -- neo-tree sobre el estado del árbol.
  vim.schedule(function()
    local ok_mgr, mgr = pcall(require, "neo-tree.sources.manager")
    local ok_cmd, cmds = pcall(require, "neo-tree.sources.common.commands")
    if not (ok_mgr and ok_cmd) then return end
    local st = mgr.get_state(source)
    if st and st.tree then pcall(cmds.close_all_nodes, st) end
  end)
end

function M.setup(core, opts)
  opts = opts or {}
  M._core = core

  local ok = pcall(require, "neo-tree.command")
  if not ok then
    vim.notify("review.nvim: neo-tree.nvim is not installed, sidebar disabled", vim.log.levels.WARN)
    return
  end

  vim.api.nvim_create_user_command("ReviewSidebar", function(cmd_opts)
    local kind = cmd_opts.args ~= "" and cmd_opts.args or "changed"
    if kind ~= "changed" and kind ~= "all" then
      vim.notify("review.nvim: :ReviewSidebar expects 'changed' or 'all'", vim.log.levels.ERROR)
      return
    end
    open_sidebar(kind)
  end, {
    nargs = "?",
    complete = function() return { "changed", "all" } end,
  })

  -- Alias corto como comando REAL (la minúscula `rs` la resuelve plugin/review.lua).
  vim.api.nvim_create_user_command("Rs", function(cmd_opts)
    local kind = cmd_opts.args ~= "" and cmd_opts.args or "changed"
    if kind ~= "changed" and kind ~= "all" then
      vim.notify("review.nvim: :Rs expects 'changed' or 'all'", vim.log.levels.ERROR)
      return
    end
    open_sidebar(kind)
  end, { nargs = "?", complete = function() return { "changed", "all" } end })

  -- Toggle changed <-> all en el keymap.
  M._mode = "all" -- así el primer toggle abre "changed"
  local function toggle()
    M._mode = (M._mode == "changed") and "all" or "changed"
    open_sidebar(M._mode)
    vim.notify("review.nvim: sidebar " .. (M._mode == "all" and "all files" or "changed files"), vim.log.levels.INFO)
  end
  -- Sidebar de review en <leader>s (top-level): <leader>rs quedó para "split".
  -- Override-able con opts.sidebar_key.
  local keymap_lhs = opts.sidebar_key or "<leader>s"
  vim.keymap.set("n", keymap_lhs, toggle, { desc = "Review: sidebar toggle changed/all" })

  if not M._subscribed then
    core.events.on("comments:changed", function()
      M._refresh()
    end)
    M._subscribed = true
  end
end

--- Marcador textual para un relpath, pensado para enganchar en un renderer
--- custom de neo-tree (ver docs/plans/04-sidebar.md Task 4). Se basa en el
--- último cache calculado por M._refresh(); si nunca corrió, lo calcula ahora.
--- @param relpath string
--- @return string|nil
function M.comment_marker(relpath)
  if not M._core then return nil end
  M._files_with_comments_cache = M._files_with_comments_cache or M.files_with_comments(M._core)
  if M._files_with_comments_cache[relpath] then
    return "💬"
  end
  return nil
end

require("review.core").registry.register({ name = "sidebar", setup = M.setup })

return M
