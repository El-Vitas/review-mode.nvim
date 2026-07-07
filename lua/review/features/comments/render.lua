local M = {}

local function clamp(bufnr, lnum)
  local last = vim.api.nvim_buf_line_count(bufnr)
  if last < 1 then return 1 end
  if lnum < 1 then return 1 end
  if lnum > last then return last end
  return lnum
end

function M.render(core, bufnr)
  local rel = core.git.rel_path(bufnr)
  if not rel then return end

  vim.api.nvim_buf_clear_namespace(bufnr, core.ns.comments, 0, -1)

  local comments = core.state.for_path(rel)
  for _, c in ipairs(comments) do
    local lnum = clamp(bufnr, c.lnum or 1)
    local end_lnum = clamp(bufnr, c.end_lnum or lnum)
    if end_lnum < lnum then lnum, end_lnum = end_lnum, lnum end
    local row = lnum - 1
    local text = c.text or ""
    if #text > 60 then text = text:sub(1, 57) .. "..." end

    -- hl distinto según estado: resueltos atenuados (Comment), abiertos DiagnosticInfo.
    local prefix = c.resolved and "✓ " or "💬 "
    local hl = c.resolved and "Comment" or "DiagnosticInfo"

    -- `end_row` ancla el FIN del rango además del inicio, para que los
    -- comentarios multi-línea conserven su rango cuando el código se mueve.
    local id = vim.api.nvim_buf_set_extmark(bufnr, core.ns.comments, row, 0, {
      end_row = end_lnum - 1,
      sign_text = "💬",
      sign_hl_group = hl,
      virt_text = { { prefix .. text, hl } },
      virt_text_pos = "eol",
    })
    c._extmark_id = id
  end
end

function M.sync_positions(core, bufnr)
  local rel = core.git.rel_path(bufnr)
  if not rel then return end

  local comments = core.state.for_path(rel)
  for _, c in ipairs(comments) do
    if c._extmark_id then
      -- `details=true` para recuperar `end_row` y preservar el rango.
      local ok, pos = pcall(vim.api.nvim_buf_get_extmark_by_id, bufnr, core.ns.comments, c._extmark_id, { details = true })
      if ok and pos and pos[1] then
        local new_lnum = clamp(bufnr, pos[1] + 1)
        local details = pos[3]
        local new_end = new_lnum
        if details and details.end_row then
          new_end = clamp(bufnr, details.end_row + 1)
        end
        if new_end < new_lnum then new_lnum, new_end = new_end, new_lnum end
        if new_lnum ~= c.lnum or new_end ~= c.end_lnum then
          core.state.update(c.id, { lnum = new_lnum, end_lnum = new_end })
        end
      end
    end
  end
end

return M
