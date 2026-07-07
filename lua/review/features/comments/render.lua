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

  -- Orden estable por línea para poder ALTERNAR el tono de fondo entre
  -- comentarios consecutivos (así dos comentarios pegados no se ven como uno).
  local comments = {}
  for _, c in ipairs(core.state.for_path(rel)) do comments[#comments + 1] = c end
  table.sort(comments, function(a, b) return (a.lnum or 0) < (b.lnum or 0) end)

  for idx, c in ipairs(comments) do
    local lnum = clamp(bufnr, c.lnum or 1)
    local end_lnum = clamp(bufnr, c.end_lnum or lnum)
    if end_lnum < lnum then lnum, end_lnum = end_lnum, lnum end
    local row = lnum - 1
    local text = c.text or ""
    -- Badge compacto de una línea (colapsa saltos). Corto a propósito: el texto
    -- completo se lee en el peek flotante (<leader>rp), no arrastrando una tira
    -- larga al final de la línea.
    text = text:gsub("[\r\n]+", " ")
    if #text > 46 then text = text:sub(1, 44) .. "…" end

    local resolved = c.resolved
    local alt = (idx % 2 == 0) -- tono de fondo alternado para separar consecutivos
    local line_hl = resolved and "ReviewCommentLineResolved"
        or (alt and "ReviewCommentLine2" or "ReviewCommentLine")
    local badge_hl = resolved and "ReviewCommentBadgeResolved" or "ReviewCommentBadge"
    local edge_hl = resolved and "ReviewCommentBadgeEdgeResolved" or "ReviewCommentBadgeEdge"
    local icon = resolved and "✓" or "💬"

    -- Extmark ANCLA (primera línea): lleva end_row para rastrear el rango al
    -- editar, el resaltado de línea y un BADGE con fondo y bordecito al final.
    -- Es el que usa sync_positions; para 1 línea, el único.
    -- (Los corchetes anidados de la izquierda los dibuja el statuscolumn — ver
    -- gutter.lua — porque la columna de signos solo admite 1 signo por línea.)
    local id = vim.api.nvim_buf_set_extmark(bufnr, core.ns.comments, row, 0, {
      end_row = end_lnum - 1,
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

    -- Líneas de continuación: mismo fondo (el borde/corchete lo pinta el gutter).
    for r = row + 1, end_lnum - 1 do
      vim.api.nvim_buf_set_extmark(bufnr, core.ns.comments, r, 0, {
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

--- Re-sincroniza posiciones desde los extmarks y marca `stale` los comentarios
--- cuya línea anclada dejó de coincidir con su `anchor_text` (malla de seguridad
--- tras un cambio de código en disco). Des-marca los que volvieron a coincidir.
--- No-op si el buffer está fuera del repo.
function M.reconcile(core, bufnr)
  local rel = core.git.rel_path(bufnr)
  if not rel then return end

  M.sync_positions(core, bufnr)

  local last = vim.api.nvim_buf_line_count(bufnr)
  for _, c in ipairs(core.state.for_path(rel)) do
    if c.anchor_text and c.anchor_text ~= "" then
      local row = (c.lnum or 1) - 1
      local now = ""
      if row >= 0 and row < last then
        now = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ""
      end
      -- coincide si la línea actual iguala el texto ancla (tolerante a
      -- reindentación/espacios: comparamos trims).
      local matches = vim.trim(now) == vim.trim(c.anchor_text)
      if matches and c.stale then
        core.state.update(c.id, { stale = false })
      elseif not matches and not c.stale then
        core.state.update(c.id, { stale = true })
      end
    end
  end

  M.render(core, bufnr)
end

return M
