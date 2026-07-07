local diff = require("review.features.views.diff")

local M = {}

function M.clear(core, bufnr)
  vim.api.nvim_buf_clear_namespace(bufnr, core.ns.views, 0, -1)
end

--- Pinta decoraciones inline de diff sobre bufnr. No-op si el archivo no
--- pertenece al repo o no tiene cambios.
function M.render(core, bufnr)
  M.clear(core, bufnr)

  local relpath = core.git.rel_path(bufnr)
  local root = core.git.root()
  if not relpath or not root then return end

  local hunks = diff.hunks_for(relpath, root)
  if not hunks or #hunks == 0 then return end

  local ns = core.ns.views
  for _, h in ipairs(hunks) do
    -- Líneas borradas: virt_lines colgando encima de la primera línea nueva
    -- que corresponde a este hunk (o de la línea siguiente si el hunk es
    -- puramente delete al final del archivo).
    if #h.del_lines > 0 then
      local anchor_lnum = math.max(h.new_start - 1, 0)
      local virt_lines = {}
      for _, dl in ipairs(h.del_lines) do
        table.insert(virt_lines, { { dl, "DiffDelete" } })
      end
      local ok = pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, anchor_lnum, 0, {
        virt_lines = virt_lines,
        virt_lines_above = anchor_lnum > 0,
      })
      if not ok then
        -- anchor fuera de rango (archivo más corto de lo esperado): ignorar
      end
    end

    -- Líneas agregadas: resaltar toda la línea real.
    for _, lnum in ipairs(h.add_lnums) do
      local row = lnum - 1
      if row >= 0 and row < vim.api.nvim_buf_line_count(bufnr) then
        pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, row, 0, {
          line_hl_group = "DiffAdd",
        })
      end
    end
  end
end

return M
