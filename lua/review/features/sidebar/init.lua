local M = {}

M._subscribed = false

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

return M
