local M = {}
M.config = { leader = "<leader>r" }

-- Features conocidas. Cada una se auto-registra en core.registry al requerirse.
local FEATURES = { "comments", "export", "views", "sidebar", "agent" }

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

return M
