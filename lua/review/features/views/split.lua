local diff = require("review.features.views.diff")

-- Estado POR BUFFER: `_panels[bufnr] = { win = <left_win>, buf = <scratch>, main = <right_win> }`.
-- (Singleton global rompería si dos buffers estuvieran en modo split a la vez.)
local M = { _panels = {} }

local function head_hl_lines(core, bufnr, head_lines, relpath, root)
  local hunks = root and diff.hunks_for(relpath, root) or nil
  if not hunks then return end
  local ns = core.ns.views
  for _, h in ipairs(hunks) do
    for i = 1, #h.del_lines do
      local row = h.old_start - 1 + (i - 1)
      if row >= 0 and row < #head_lines then
        pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, row, 0, { line_hl_group = "DiffDelete" })
      end
    end
  end
end

-- Activa/desactiva scroll y cursor sincronizados en una ventana.
local function set_bind(win, on)
  if win and vim.api.nvim_win_is_valid(win) then
    vim.wo[win].scrollbind = on
    vim.wo[win].cursorbind = on
  end
end

--- Abre el panel izquierdo con el contenido HEAD del archivo del buffer actual.
--- Avisa y no abre nada si el archivo no tiene HEAD (nuevo / fuera de git).
function M.open(core, bufnr)
  local relpath = core.git.rel_path(bufnr)
  if not relpath then
    vim.notify("review.nvim: buffer fuera del repo, no se puede abrir split", vim.log.levels.WARN)
    return
  end

  -- Raíz resuelta desde el buffer (no desde el cwd) para que HEAD y hunks
  -- salgan del repo correcto aunque el cwd de nvim esté en otro lado.
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

  local target_win = vim.api.nvim_get_current_win()
  vim.cmd("topleft vsplit")
  local left_win = vim.api.nvim_get_current_win()

  local scratch = vim.api.nvim_create_buf(false, true)
  vim.bo[scratch].buftype = "nofile"
  vim.bo[scratch].bufhidden = "wipe"
  vim.bo[scratch].modifiable = true
  vim.api.nvim_buf_set_lines(scratch, 0, -1, false, head_lines)
  vim.bo[scratch].modifiable = false
  vim.bo[scratch].readonly = true
  pcall(vim.api.nvim_buf_set_name, scratch, "review://head/" .. relpath)

  vim.api.nvim_win_set_buf(left_win, scratch)
  head_hl_lines(core, scratch, head_lines, relpath, root)

  M._panels[bufnr] = { win = left_win, buf = scratch, main = target_win }

  -- Scroll + cursor sincronizados: ambas ventanas se mueven juntas (como un
  -- diff side-by-side). syncbind alinea el punto de partida.
  set_bind(left_win, true)
  set_bind(target_win, true)
  vim.api.nvim_set_current_win(target_win)
  pcall(function()
    vim.cmd("normal! gg")
    vim.cmd("syncbind")
  end)
end

--- Cierra el panel izquierdo de HEAD del buffer `bufnr` si está abierto.
--- Idempotente (no-op si ese buffer no tiene panel).
function M.close(core, bufnr)
  local p = M._panels[bufnr]
  if p then
    -- Apagar el bind en la ventana real que sobrevive, si no volvería a
    -- moverse sola tras cerrar el panel.
    set_bind(p.main, false)
    if p.win and vim.api.nvim_win_is_valid(p.win) then
      pcall(vim.api.nvim_win_close, p.win, true)
    end
  end
  M._panels[bufnr] = nil
end

return M
