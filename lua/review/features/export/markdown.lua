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

--- Formatea una lista de comentarios a markdown numerado, agent-ready.
--- Excluye los comentarios resueltos. Devuelve "" si no queda ninguno.
--- @param list table[] lista de comment (id, path, lnum, end_lnum, text, resolved, ...)
--- @return string
function M.markdown(list)
  list = list or {}
  local lines = {}
  local n = 0
  for _, c in ipairs(list) do
    if not c.resolved then
      n = n + 1
      table.insert(lines, string.format("%d. %s %s", n, anchor(c), oneline(c.text)))
    end
  end
  if n == 0 then return "" end
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
