local M = {}

local function anchor(c)
  if c.end_lnum and c.end_lnum > c.lnum then
    return string.format("`%s:%d-%d`", c.path, c.lnum, c.end_lnum)
  end
  return string.format("`%s:%d`", c.path, c.lnum)
end

-- Colapsa saltos de línea del texto del comentario a un espacio: cada comentario
-- DEBE ocupar exactamente una línea numerada, o `table.concat("\n")` rompería la
-- numeración del markdown agent-ready.
local function oneline(text)
  return ((text or ""):gsub("[\r\n]+", " "))
end

--- Formatea una lista de comentarios a markdown agent-ready: AGRUPADO por
--- archivo (encabezado `## <path>`) y ORDENADO por archivo + línea, con
--- numeración CONTINUA. Excluye los resueltos. Devuelve "" si no queda ninguno.
--- @param list table[] lista de comment (id, path, lnum, end_lnum, text, resolved, ...)
--- @return string
function M.markdown(list)
  list = list or {}
  -- Filtrar resueltos.
  local items = {}
  for _, c in ipairs(list) do
    if not c.resolved then items[#items + 1] = c end
  end
  if #items == 0 then return "" end

  -- Ordenar por archivo, luego por línea.
  table.sort(items, function(a, b)
    if a.path ~= b.path then return a.path < b.path end
    return (a.lnum or 0) < (b.lnum or 0)
  end)

  local lines = {}
  local n = 0
  local cur_path = nil
  for _, c in ipairs(items) do
    if c.path ~= cur_path then
      cur_path = c.path
      if #lines > 0 then lines[#lines + 1] = "" end -- línea en blanco entre grupos
      lines[#lines + 1] = "## " .. cur_path
    end
    n = n + 1
    lines[#lines + 1] = string.format("%d. %s %s", n, anchor(c), oneline(c.text))
  end
  return table.concat(lines, "\n")
end

--- Markdown de los comentarios de un solo archivo.
--- @param core table tabla core (usa core.state.for_path)
--- @param relpath string path relativo a la raíz git
--- @return string
function M.file(core, relpath)
  return M.markdown(core.state.for_path(relpath))
end

--- Markdown de todos los comentarios del repo.
--- @param core table tabla core (usa core.state.all)
--- @return string
function M.all(core)
  return M.markdown(core.state.all())
end

return M
