-- Vista SPLIT side-by-side usando el MODO DIFF NATIVO de Neovim (`:diffthis`).
-- No es diffview (el plugin): es el diff incorporado, que alinea ambos lados con
-- líneas de relleno (como VSCode/GitHub), resalta add/change/delete, sincroniza
-- scroll y mouse por hunks, y re-diffea en vivo al editar — todo nativo.
--
-- Estado POR BUFFER: `_panels[bufnr] = { win = <left_win>, buf = <scratch>, main = <right_win> }`.
local M = { _panels = {} }

--- Devuelve el bufnr real dueño de un buffer scratch de panel HEAD (o nil).
--- Permite que los comandos ejecutados DESDE el panel izquierdo actúen sobre
--- el archivo real, no sobre el scratch.
--- @param scratch_bufnr integer
--- @return integer|nil
function M.owner_of(scratch_bufnr)
  for real, p in pairs(M._panels) do
    if p.buf == scratch_bufnr then return real end
  end
  return nil
end

--- Abre el panel izquierdo con el contenido HEAD del archivo del buffer actual,
--- en modo diff nativo contra el buffer real (derecha, editable).
--- Avisa y no abre nada si el archivo no tiene HEAD (nuevo / fuera de git).
function M.open(core, bufnr)
  local relpath = core.git.rel_path(bufnr)
  if not relpath then
    vim.notify("review.nvim: buffer fuera del repo, no se puede abrir split", vim.log.levels.WARN)
    return
  end

  -- Raíz resuelta desde el buffer (no desde el cwd) para que HEAD salga del
  -- repo correcto aunque el cwd de nvim esté en otro lado.
  local root = core.git.root(bufnr)
  local head_lines = core.git.head_content(relpath, root)
  if not head_lines then
    vim.notify(
      "review.nvim: '" .. relpath .. "' no tiene versión en HEAD (archivo nuevo)",
      vim.log.levels.WARN
    )
    return
  end

  M.close(core, bufnr) -- cierra un panel previo de ESTE buffer, si lo hubiera

  local ft = vim.bo[bufnr].filetype
  local target_win = vim.api.nvim_get_current_win()

  -- Panel HEAD a la izquierda.
  vim.cmd("leftabove vsplit")
  local left_win = vim.api.nvim_get_current_win()

  local scratch = vim.api.nvim_create_buf(false, true)
  vim.bo[scratch].buftype = "nofile"
  vim.bo[scratch].bufhidden = "wipe"
  vim.bo[scratch].modifiable = true
  vim.api.nvim_buf_set_lines(scratch, 0, -1, false, head_lines)
  vim.bo[scratch].modifiable = false
  vim.bo[scratch].readonly = true
  if ft and ft ~= "" then vim.bo[scratch].filetype = ft end -- syntax highlighting
  pcall(vim.api.nvim_buf_set_name, scratch, "review://head/" .. relpath)
  vim.api.nvim_win_set_buf(left_win, scratch)

  -- Modo diff nativo en ambas ventanas: alinea con relleno, resalta y
  -- sincroniza scroll/mouse. Re-diffea solo al editar el buffer real.
  vim.api.nvim_win_call(left_win, function() vim.cmd("diffthis") end)
  vim.api.nvim_win_call(target_win, function() vim.cmd("diffthis") end)
  -- Mostrar TODAS las líneas (sin plegar los tramos sin cambios, estilo VSCode).
  vim.wo[left_win].foldenable = false
  vim.wo[target_win].foldenable = false

  M._panels[bufnr] = { win = left_win, buf = scratch, main = target_win }

  -- Volver el foco al archivo real; su posición de cursor se preserva.
  vim.api.nvim_set_current_win(target_win)
end

--- Cierra el panel izquierdo de HEAD del buffer `bufnr` si está abierto y
--- saca el modo diff del buffer real. Idempotente.
function M.close(core, bufnr)
  local p = M._panels[bufnr]
  if p then
    if p.main and vim.api.nvim_win_is_valid(p.main) then
      vim.api.nvim_win_call(p.main, function() vim.cmd("diffoff") end)
      vim.wo[p.main].foldenable = true
    end
    if p.win and vim.api.nvim_win_is_valid(p.win) then
      pcall(vim.api.nvim_win_close, p.win, true)
    end
  end
  M._panels[bufnr] = nil
end

return M
