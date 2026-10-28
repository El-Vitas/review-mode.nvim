local M = {}

local function anchor(c)
  if c.file_level or not c.lnum then
    return string.format("`%s` (file)", c.path) -- comentario a nivel de archivo
  end
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
--- numeración CONTINUA. Excluye los resueltos. Las respuestas (`reply_to`) no
--- son ítems pendientes: van sangradas debajo de su comentario, para que el
--- agente no reciba sus propias respuestas como tareas. Devuelve "" si no queda
--- ninguno.
--- @param list table[] lista de comment (id, path, lnum, end_lnum, text, resolved, ...)
--- @return string
function M.markdown(list)
  list = list or {}
  -- Filtrar resueltos y separar las respuestas por padre.
  local items, replies, order = {}, {}, {}
  for i, c in ipairs(list) do
    order[c] = i
    if c.reply_to then
      replies[c.reply_to] = replies[c.reply_to] or {}
      table.insert(replies[c.reply_to], c)
    elseif not c.resolved then
      items[#items + 1] = c
    end
  end
  if #items == 0 then return "" end

  -- Ordenar por archivo y línea. `table.sort` no es estable: el desempate por
  -- orden de creación deja la numeración igual entre exportaciones.
  table.sort(items, function(a, b)
    if a.path ~= b.path then return a.path < b.path end
    if (a.lnum or 0) ~= (b.lnum or 0) then return (a.lnum or 0) < (b.lnum or 0) end
    return order[a] < order[b]
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
    -- Incluimos el id del comentario (token `id:<id>` al final) para que un
    -- agente pueda apuntar a él (reply/resolve/etc.) sin adivinar.
    local id = c.id and ("  `id:" .. c.id .. "`") or ""
    lines[#lines + 1] = string.format("%d. %s %s%s", n, anchor(c), oneline(c.text), id)
    for _, r in ipairs(replies[c.id] or {}) do
      local rid = r.id and ("  `id:" .. r.id .. "`") or ""
      lines[#lines + 1] = string.format("   ↳ %s: %s%s", r.author or "user", oneline(r.text), rid)
    end
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
