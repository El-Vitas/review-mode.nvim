local M = {}
M.config = { leader = "<leader>r" }

-- Features conocidas. Cada una se auto-registra en core.registry al requerirse.
local FEATURES = { "comments", "export", "views", "sidebar", "agent", "base" }

function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})
  local core = require("review.core")
  core.state.load()
  -- Cargar features (auto-registro vía require). pcall para no romper durante
  -- el build incremental cuando una feature todavía no existe.
  for _, name in ipairs(FEATURES) do
    pcall(require, "review.features." .. name)
  end
  core.registry.setup(core, M.config)
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
