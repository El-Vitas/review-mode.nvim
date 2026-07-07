local M = {}

--- Aplica el contenido de disco al buffer como PATCH mínimo (no `:edit!`), para
--- que los extmarks (y por lo tanto los comentarios anclados) se re-anclen solos
--- por gravity. Nunca pisa cambios sin guardar del humano.
--- @return "applied"|"identical"|"conflict"|"skipped"
function M.patch(core, bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then return "skipped" end
  local rel = core.git.rel_path(bufnr)
  if not rel then return "skipped" end

  local name = vim.api.nvim_buf_get_name(bufnr)
  if name == "" then return "skipped" end

  -- Conflicto: hay ediciones sin guardar → NO pisar (ver roadmap §1.3.3).
  if vim.bo[bufnr].modified then return "conflict" end

  local ok, disk = pcall(vim.fn.readfile, name)
  if not ok or type(disk) ~= "table" then return "skipped" end

  local buf_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local a = table.concat(buf_lines, "\n")
  local b = table.concat(disk, "\n")
  if a == b then return "identical" end

  local hunks = vim.diff(a, b, { result_type = "indices" })
  if not hunks or #hunks == 0 then return "identical" end

  -- Aplicar de ABAJO hacia arriba para no invalidar los índices de los hunks
  -- superiores. Cada hunk = { start_a, count_a, start_b, count_b } (1-based en a
  -- y b; count==0 marca inserción/borrado puro con start = línea previa).
  for i = #hunks, 1, -1 do
    local h = hunks[i]
    local start_a, count_a, start_b, count_b = h[1], h[2], h[3], h[4]

    local repl = {}
    for j = start_b, start_b + count_b - 1 do
      repl[#repl + 1] = disk[j]
    end

    local s, e
    if count_a == 0 then
      -- inserción: `start_a` es la línea (1-based) DESPUÉS de la cual insertar;
      -- en 0-based eso es el índice `start_a` (set_lines(start_a, start_a, ...)).
      s = start_a
      e = start_a
    else
      s = start_a - 1
      e = start_a - 1 + count_a
    end
    vim.api.nvim_buf_set_lines(bufnr, s, e, false, repl)
  end

  vim.bo[bufnr].modified = false
  core.events.emit("buffer:reconciled", { bufnr = bufnr })
  return "applied"
end

return M
