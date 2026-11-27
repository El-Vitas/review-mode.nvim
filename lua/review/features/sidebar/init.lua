local M = {}

M._subscribed = false
M._core = nil

--- PURE helper: set of relpaths with ≥1 comment. Does not touch neo-tree, has no
--- side effects. Reusable by anyone who wants to mark the tree.
--- @param core table  the review.nvim core (uses core.state.all())
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

--- True if there is a neo-tree window visible in the current tab.
local function neotree_window_open()
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local buf = vim.api.nvim_win_get_buf(win)
    if vim.bo[buf].filetype == "neo-tree" then
      return true
    end
  end
  return false
end

--- Refreshes the tree indicator/redraw if it is open. Does not force opening.
--- Current phase: recomputes the pure set; the fine visual marking is documented
--- as a secondary phase (see Task 4).
function M._refresh()
  if not M._core then return end
  if not neotree_window_open() then return end
  local ok, command = pcall(require, "neo-tree.command")
  if not ok then return end
  M._files_with_comments_cache = M.files_with_comments(M._core)
  pcall(command.execute, { action = "refresh" })
end

--- "Effective" review base for neo-tree: a concrete commit or nil.
--- DELEGATES to core.git.effective_base() (single source of truth). HEAD/index/""
--- → nil (normal git status); a commit → that ref.
local function effective_base()
  return M._core and M._core.git.effective_base() or nil
end

--- Worktree root to index `git_base_by_worktree`, as neo-tree resolves it
--- (git.find_worktree_info on the cwd/state.path).
local function worktree_root()
  local ok, git = pcall(require, "neo-tree.git")
  if not ok then return nil end
  local path = (M._core and M._core.git.root and M._core.git.root()) or vim.fn.getcwd()
  return (git.find_worktree_info(path))
end

--- Syncs the git_status state's `git_base_by_worktree` with the review
--- base: sets the effective commit, or CLEARS the entry if the base is HEAD/index
--- (neo-tree never clears it on its own; it must be deleted by hand to go back to `git status`).
local function sync_git_base(state)
  if not state then return end
  local base = effective_base()
  state.git_base_by_worktree = state.git_base_by_worktree or {}
  if base then
    local root = worktree_root()
    if root then state.git_base_by_worktree[root] = base end
  else
    -- Base = HEAD/index → clear ALL entries to go back to the normal git
    -- status (neo-tree never deletes them on its own; and this way no stale key is left due to
    -- worktree root normalization differences between us and neo-tree).
    for k in pairs(state.git_base_by_worktree) do
      state.git_base_by_worktree[k] = nil
    end
  end
  -- Force re-navigation: when going back to HEAD we do not pass git_base, so
  -- git_base_changed would be false and neo-tree would not recompute the tree.
  state.dirty = true
end

--- The ONLY way to open/reveal/show neo-tree RESPECTING the review base.
--- If the source is git_status: syncs the state's git_base (set/clear depending on
--- the base) and injects `exec.git_base` = effective base. Any call site (this
--- plugin OR the user's config via require("review").neotree_exec) must go
--- through here — so the changes tree is NEVER opened ignoring the base.
--- @param exec table  args for neo-tree.command.execute (source/action/position/reveal_file/…)
--- @return boolean ok
function M.neotree_exec(exec)
  local ok, command = pcall(require, "neo-tree.command")
  if not ok then
    vim.notify("review.nvim: neo-tree.nvim is not installed, sidebar disabled", vim.log.levels.WARN)
    return false
  end
  -- Reveal: neo-tree does NOT reliably leave the cursor on the file (git_status
  -- stays at the root; filesystem sometimes does too). We force it with focus_node after
  -- rendering, for BOTH sources. In git_status the reveal is done as a show
  -- (git_status's native reveal does not position); in filesystem the native
  -- reveal is kept (expands the path) + focus_node as a safety net.
  local focus_after, focus_source
  if exec.action == "reveal" and exec.reveal_file then
    focus_after = exec.reveal_file
    focus_source = exec.source
    if exec.source == "git_status" then
      -- git_status: the native reveal does not position → show + manual focus_node.
      exec.action = "show"
      exec.reveal_file = nil
    end
  end
  -- BOTH tree modes compare against the review base: the changes one
  -- to decide which files it lists, and the files one for the status letters
  -- (N, M, D…). If the files one used plain `git status`, a file that is new
  -- relative to the base but already committed showed up without a letter, while gitsigns,
  -- the statusline and the views marked it as new.
  local source = exec.source or "filesystem"
  if source == "git_status" or source == "filesystem" then
    local ok_mgr, mgr = pcall(require, "neo-tree.sources.manager")
    if ok_mgr then sync_git_base(mgr.get_state(source)) end
    exec.git_base = effective_base() -- nil if HEAD/index → normal git status
  end
  if source == "filesystem" and focus_after and exec.action == "reveal" then
    -- filesystem reveal: command.execute({reveal_file=…}) does NOT expand the path;
    -- the string command `Neotree reveal` does (it reveals the CURRENT file, which is the
    -- one <leader>E wants to reveal). The base is already in the state (sync_git_base).
    -- Then focus_node as a safety net.
    vim.cmd("Neotree reveal source=filesystem position=" .. (exec.position or "right"))
  else
    command.execute(exec)
  end
  if focus_after then
    -- After render (async), focus the file's node. We try the path as is
    -- and its resolved version (symlinks) because the node id is the canonical path.
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

--- Opens/focuses the neo-tree tree on the requested source.
--- @param kind "changed"|"all"
local function open_sidebar(kind)
  -- Recompute the files-with-comments cache on open, so the
  -- marker does not go stale if comments were added/deleted while the
  -- tree was closed (M._refresh is skipped when the window is not open).
  if M._core then M._files_with_comments_cache = M.files_with_comments(M._core) end
  local source = kind == "all" and "filesystem" or "git_status"
  if not M.neotree_exec({ source = source, action = "show", position = "right" }) then return end

  -- Open with the folders CLOSED (by default neo-tree leaves them expanded and
  -- it is chaos). We collapse everything after rendering, using neo-tree's
  -- native command on the tree state.
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

  -- Short alias as a REAL command (the lowercase `rs` is resolved by plugin/review.lua).
  vim.api.nvim_create_user_command("Rs", function(cmd_opts)
    local kind = cmd_opts.args ~= "" and cmd_opts.args or "changed"
    if kind ~= "changed" and kind ~= "all" then
      vim.notify("review.nvim: :Rs expects 'changed' or 'all'", vim.log.levels.ERROR)
      return
    end
    open_sidebar(kind)
  end, { nargs = "?", complete = function() return { "changed", "all" } end })

  -- Toggle changed <-> all DERIVED from the source actually open (not from an
  -- internal state that goes out of sync when the tree was opened by the config/restore via
  -- <leader>e). git_status(changed) → all ; filesystem(all) → changed ; closed → changed.
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
    local kind = (src == "git_status") and "all" or "changed" -- filesystem/closed → changed
    open_sidebar(kind)
    vim.notify("review.nvim: sidebar " .. (kind == "all" and "all files" or "changed files"), vim.log.levels.INFO)
  end
  -- Review sidebar on <leader>s (top-level): <leader>rs was left for "split".
  -- Overridable with opts.sidebar_key.
  local keymap_lhs = opts.sidebar_key or "<leader>s"
  vim.keymap.set("n", keymap_lhs, toggle, { desc = "Review: sidebar toggle changed/all" })

  if not M._subscribed then
    core.events.on("comments:changed", function()
      M._refresh()
    end)
    -- When the comparison base changes, if the "changed" tree (git_status) is
    -- visible, re-apply the base and re-navigate (same single path as everything else).
    core.events.on("base:changed", function()
      -- Re-apply the base to whichever tree mode is in view (changed or all).
      local src = open_source()
      if src ~= "git_status" and src ~= "filesystem" then return end
      M.neotree_exec({ source = src, action = "show", position = "right" })
    end)
    M._subscribed = true
  end
end

--- Text marker for a relpath, meant to hook into a custom neo-tree
--- renderer (see docs/plans/04-sidebar.md Task 4). It relies on the
--- last cache computed by M._refresh(); if it never ran, it computes it now.
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
