local M = {}
M.config = { leader = "<leader>r" }

-- Known features. Each one registers itself in core.registry when required.
local FEATURES = { "comments", "export", "views", "sidebar", "agent", "base" }

function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})
  local core = require("review.core")
  core.state.load()
  -- Load features (self-registration via require). A feature that fails to
  -- load does not take down the others, but it is reported: otherwise the
  -- only symptom would be "missing commands".
  for _, name in ipairs(FEATURES) do
    local ok, err = pcall(require, "review.features." .. name)
    if not ok then
      vim.notify("review.nvim: feature '" .. name .. "' failed to load: " .. tostring(err), vim.log.levels.ERROR)
    end
  end
  core.registry.setup(core, M.config)
  -- Comments are per repo: on `:cd`, save those of the previous repo and
  -- load those of the new one.
  local group = vim.api.nvim_create_augroup("ReviewState", { clear = true })
  vim.api.nvim_create_autocmd("DirChanged", {
    group = group,
    callback = function() core.state.switch_root() end,
  })
  -- When returning to Neovim, git may have changed outside (commit, `git mv`,
  -- `git init`): the root cache is recomputed on next use, and renames are
  -- recomputed in the background only if git changed.
  vim.api.nvim_create_autocmd("FocusGained", {
    group = group,
    callback = function()
      core.git.clear_cache()
      core.git.prefetch_renames()
    end,
  })
  -- The startup precomputation is launched by the base feature, after restoring.
  core.events.on("base:changed", function() core.git.prefetch_renames() end)
end

--- Effective base to compare against (nil for HEAD/index, or the commit). Single source.
function M.effective_base()
  return require("review.core").git.effective_base()
end

--- The ONLY public way to open/reveal/show the neo-tree tree while respecting
--- the review base. Injects git_base when the source is git_status. The user's
--- config must use THIS for any open/reveal/toggle of the changes sidebar
--- (so it is never opened ignoring the base).
--- @param exec table  args for neo-tree.command.execute (source/action/position/reveal_file/…)
--- @return boolean ok
function M.neotree_exec(exec)
  local ok, sidebar = pcall(require, "review.features.sidebar")
  if not ok or type(sidebar.neotree_exec) ~= "function" then return false end
  return sidebar.neotree_exec(exec)
end

return M
