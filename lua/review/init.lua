local M = {}
M.config = { leader = "<leader>r" }

function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})
  local core = require("review.core")
  -- Las features se auto-registran al requerirse (se agregan en sus planes).
  core.registry.setup(core, M.config)
end

return M
