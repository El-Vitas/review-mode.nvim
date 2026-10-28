local M = {}
M.config = { leader = "<leader>r" }

-- Features conocidas. Cada una se auto-registra en core.registry al requerirse.
local FEATURES = { "comments", "export", "views", "sidebar", "agent", "base" }

function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})
  local core = require("review.core")
  core.state.load()
  -- Cargar features (auto-registro vía require). Una feature que falla al
  -- cargar no tumba las demás, pero se avisa: si no, solo "faltaban comandos".
  for _, name in ipairs(FEATURES) do
    local ok, err = pcall(require, "review.features." .. name)
    if not ok then
      vim.notify("review.nvim: feature '" .. name .. "' failed to load: " .. tostring(err), vim.log.levels.ERROR)
    end
  end
  core.registry.setup(core, M.config)
  -- Los comentarios son por repo: al cambiar de directorio con `:cd`, guardar
  -- los del repo anterior y cargar los del nuevo.
  local group = vim.api.nvim_create_augroup("ReviewState", { clear = true })
  vim.api.nvim_create_autocmd("DirChanged", {
    group = group,
    callback = function() core.state.switch_root() end,
  })
  -- Al volver a Neovim, git pudo cambiar afuera (commit, `git mv`, `git init`):
  -- los caches de raíz y de renames se recalculan en el próximo uso.
  vim.api.nvim_create_autocmd("FocusGained", {
    group = group,
    callback = function() core.git.clear_cache() end,
  })
end

--- Base efectiva para comparar (nil si HEAD/index, o el commit). Fuente única.
function M.effective_base()
  return require("review.core").git.effective_base()
end

--- ÚNICA vía pública para abrir/revelar/mostrar el árbol neo-tree respetando la
--- base de review. Inyecta git_base cuando el source es git_status. El config
--- del usuario debe usar ESTO para cualquier open/reveal/toggle del sidebar de
--- cambios (así nunca se abre ignorando la base).
--- @param exec table  args de neo-tree.command.execute (source/action/position/reveal_file/…)
--- @return boolean ok
function M.neotree_exec(exec)
  local ok, sidebar = pcall(require, "review.features.sidebar")
  if not ok or type(sidebar.neotree_exec) ~= "function" then return false end
  return sidebar.neotree_exec(exec)
end

return M
