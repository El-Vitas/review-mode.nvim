local M = {}

-- Visibilidad global de los comentarios (toggle shown/hidden). Cuando está en
-- true, `render` limpia y no pinta nada.
M.hidden = false

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
  if M.hidden then return end

  local comments = core.state.for_path(rel)
  for _, c in ipairs(comments) do
    local lnum = clamp(bufnr, c.lnum or 1)
    local end_lnum = clamp(bufnr, c.end_lnum or lnum)
    if end_lnum < lnum then lnum, end_lnum = end_lnum, lnum end
    local row = lnum - 1
    local text = c.text or ""
    -- Badge compacto de una línea (colapsa saltos). Corto a propósito: el texto
    -- completo se lee en el peek flotante (<leader>rp), no arrastrando una tira
    -- larga al final de la línea.
    text = text:gsub("[\r\n]+", " ")
    if #text > 28 then text = text:sub(1, 25) .. "…" end

    local resolved = c.resolved
    local line_hl = resolved and "ReviewCommentLineResolved" or "ReviewCommentLine"
    local sign_hl = resolved and "ReviewCommentSignResolved" or "ReviewCommentSign"
    local badge_hl = resolved and "ReviewCommentBadgeResolved" or "ReviewCommentBadge"
    local edge_hl = resolved and "ReviewCommentBadgeEdgeResolved" or "ReviewCommentBadgeEdge"
    local icon = resolved and "✓" or "💬"

    -- Extmark ANCLA (primera línea): lleva end_row para rastrear el rango al
    -- editar, la barra lateral (borde), el resaltado de línea y un BADGE con
    -- fondo y bordecito al final. Es el que usa sync_positions; para 1 línea,
    -- es el único.
    local id = vim.api.nvim_buf_set_extmark(bufnr, core.ns.comments, row, 0, {
      end_row = end_lnum - 1,
      sign_text = "▌",
      sign_hl_group = sign_hl,
      line_hl_group = line_hl,
      virt_text = {
        { "  ", "None" },
        { "▏", edge_hl },
        { " " .. icon .. " " .. text .. " ", badge_hl },
        { "▕", edge_hl },
      },
      virt_text_pos = "eol",
    })
    c._extmark_id = id

    -- Líneas de continuación del rango: misma barra lateral + fondo, para que
    -- el bloque completo se vea "encerrado" por el borde.
    for r = row + 1, end_lnum - 1 do
      vim.api.nvim_buf_set_extmark(bufnr, core.ns.comments, r, 0, {
        sign_text = "▌",
        sign_hl_group = sign_hl,
        line_hl_group = line_hl,
      })
    end
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
