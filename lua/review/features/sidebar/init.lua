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

--- Base de review "efectiva" para neo-tree: un commit concreto o nil.
--- DELEGA en core.git.effective_base() (única fuente de verdad). HEAD/index/""
--- → nil (git status normal); un commit → ese ref.
local function effective_base()
  return M._core and M._core.git.effective_base() or nil
end

--- Worktree root para indexar `git_base_by_worktree`, tal como lo resuelve
--- neo-tree (git.find_worktree_info sobre el cwd/state.path).
local function worktree_root()
  local ok, git = pcall(require, "neo-tree.git")
  if not ok then return nil end
  local path = (M._core and M._core.git.root and M._core.git.root()) or vim.fn.getcwd()
  return (git.find_worktree_info(path))
end

--- Sincroniza el `git_base_by_worktree` del state de git_status con la base de
--- review: setea el commit efectivo, o LIMPIA la entrada si la base es HEAD/index
--- (neo-tree nunca limpia solo; hay que borrarla a mano para volver a `git status`).
local function sync_git_base(state)
  if not state then return end
  local base = effective_base()
  state.git_base_by_worktree = state.git_base_by_worktree or {}
  if base then
    local root = worktree_root()
    if root then state.git_base_by_worktree[root] = base end
  else
    -- Base = HEAD/index → limpiar TODAS las entradas para volver al git status
    -- normal (neo-tree nunca las borra solo; y así no queda clave stale por
    -- diferencias de normalización del worktree root entre nosotros y neo-tree).
    for k in pairs(state.git_base_by_worktree) do
      state.git_base_by_worktree[k] = nil
    end
  end
  -- Forzar renavegación: al volver a HEAD no pasamos git_base, así que
  -- git_base_changed sería false y neo-tree no recomputaría el árbol.
  state.dirty = true
end

--- ÚNICA vía para abrir/revelar/mostrar neo-tree RESPETANDO la base de review.
--- Si el source es git_status: sincroniza el git_base del state (set/clear según
--- la base) e inyecta `exec.git_base` = base efectiva. Cualquier call site (este
--- plugin O el config del usuario vía require("review").neotree_exec) debe pasar
--- por acá — así NUNCA se abre el árbol de cambios ignorando la base.
--- @param exec table  args para neo-tree.command.execute (source/action/position/reveal_file/…)
--- @return boolean ok
function M.neotree_exec(exec)
  local ok, command = pcall(require, "neo-tree.command")
  if not ok then
    vim.notify("review.nvim: neo-tree.nvim is not installed, sidebar disabled", vim.log.levels.WARN)
    return false
  end
  -- Reveal: neo-tree NO deja el cursor sobre el archivo de forma fiable (git_status
  -- queda en la raíz; filesystem a veces tampoco). Lo forzamos con focus_node tras
  -- renderizar, para AMBOS sources. En git_status el reveal se hace como show
  -- (el reveal nativo del git_status no posiciona); en filesystem se deja el reveal
  -- nativo (expande la ruta) + focus_node como red de seguridad.
  local focus_after, focus_source
  if exec.action == "reveal" and exec.reveal_file then
    focus_after = exec.reveal_file
    focus_source = exec.source
    if exec.source == "git_status" then
      -- git_status: el reveal nativo no posiciona → show + focus_node manual.
      exec.action = "show"
      exec.reveal_file = nil
    end
  end
  -- Los DOS modos del árbol comparan contra la base de review: el de cambios
  -- para decidir qué archivos lista, y el de archivos para las letras de estado
  -- (N, M, D…). Si el de archivos usara `git status` plano, un archivo nuevo
  -- respecto de la base pero ya commiteado aparecía sin letra, mientras gitsigns,
  -- la statusline y las vistas lo marcaban como nuevo.
  local source = exec.source or "filesystem"
  if source == "git_status" or source == "filesystem" then
    local ok_mgr, mgr = pcall(require, "neo-tree.sources.manager")
    if ok_mgr then sync_git_base(mgr.get_state(source)) end
    exec.git_base = effective_base() -- nil si HEAD/index → git status normal
  end
  if source == "filesystem" and focus_after and exec.action == "reveal" then
    -- filesystem reveal: command.execute({reveal_file=…}) NO expande la ruta;
    -- el comando string `Neotree reveal` sí (revela el archivo ACTUAL, que es el
    -- que <leader>E quiere revelar). La base ya quedó en el state (sync_git_base).
    -- Luego focus_node como red de seguridad.
    vim.cmd("Neotree reveal source=filesystem position=" .. (exec.position or "right"))
  else
    command.execute(exec)
  end
  if focus_after then
    -- Tras render (async), enfocar el nodo del archivo. Probamos el path tal cual
    -- y su versión resuelta (symlinks) porque el id del nodo es el path canónico.
    vim.defer_fn(function()
      local ok_mgr, mgr = pcall(require, "neo-tree.sources.manager")
      local ok_r, renderer = pcall(require, "neo-tree.ui.renderer")
      if not (ok_mgr and ok_r) then return end
      local st = mgr.get_state(focus_source)
      if not st then return end
      pcall(renderer.focus_node, st, focus_after)
      local resolved = vim.fn.resolve(focus_after)
      if resolved ~= focus_after then pcall(renderer.focus_node, st, resolved) end
    end, 200)
  end
  return true
end

--- Abre/enfoca el árbol de neo-tree en el source pedido.
--- @param kind "changed"|"all"
local function open_sidebar(kind)
  -- Recalcular el cache de archivos-con-comentarios al abrir, para que el
  -- marcador no quede obsoleto si se agregaron/borraron comentarios con el
  -- árbol cerrado (M._refresh se saltea cuando la ventana no está abierta).
  if M._core then M._files_with_comments_cache = M.files_with_comments(M._core) end
  local source = kind == "all" and "filesystem" or "git_status"
  if not M.neotree_exec({ source = source, action = "show", position = "right" }) then return end

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

  -- Toggle changed <-> all DERIVADO del source realmente abierto (no de un estado
  -- interno que se desincroniza cuando el árbol lo abrió el config/restore vía
  -- <leader>e). git_status(changed) → all ; filesystem(all) → changed ; cerrado → changed.
  local function open_source()
    for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      local b = vim.api.nvim_win_get_buf(w)
      if vim.bo[b].filetype == "neo-tree" then
        local ok, s = pcall(vim.api.nvim_buf_get_var, b, "neo_tree_source")
        return (ok and s) or nil
      end
    end
    return nil
  end
  local function toggle()
    local src = open_source()
    local kind = (src == "git_status") and "all" or "changed" -- filesystem/cerrado → changed
    open_sidebar(kind)
    vim.notify("review.nvim: sidebar " .. (kind == "all" and "all files" or "changed files"), vim.log.levels.INFO)
  end
  -- Sidebar de review en <leader>s (top-level): <leader>rs quedó para "split".
  -- Override-able con opts.sidebar_key.
  local keymap_lhs = opts.sidebar_key or "<leader>s"
  vim.keymap.set("n", keymap_lhs, toggle, { desc = "Review: sidebar toggle changed/all" })

  if not M._subscribed then
    core.events.on("comments:changed", function()
      M._refresh()
    end)
    -- Al cambiar la base de comparación, si el árbol "changed" (git_status) está
    -- visible, re-aplicar la base y renavegar (misma vía única que todo lo demás).
    core.events.on("base:changed", function()
      -- Re-aplicar la base al modo del árbol que esté a la vista (changed o all).
      local src = open_source()
      if src ~= "git_status" and src ~= "filesystem" then return end
      M.neotree_exec({ source = src, action = "show", position = "right" })
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
