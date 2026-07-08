local store = require("review.core.store")
local events = require("review.core.events")

local M = {}
local list = {}

-- Id robusto: seed una vez con hrtime (evita colisiones cuando se agregan
-- muchos comentarios en el mismo segundo, ej. el agente en lote) + contador
-- monotónico + aleatorio.
local _seeded = false
local _counter = 0
local function uuid()
  if not _seeded then
    math.randomseed((os.time() + (vim.loop.hrtime() % 0x7fffffff)))
    _seeded = true
  end
  _counter = _counter + 1
  return string.format("%x-%x-%x", os.time(), _counter, math.random(0, 0xffffff))
end

function M._reset() list = {} end
function M.all() return list end

function M.for_path(path)
  local out = {}
  for _, c in ipairs(list) do if c.path == path then out[#out+1] = c end end
  return out
end

function M.by_id(id)
  for _, c in ipairs(list) do if c.id == id then return c end end
  return nil
end

function M.add(c)
  c.id = c.id or uuid()
  c.end_lnum = c.end_lnum or c.lnum
  if c.resolved == nil then c.resolved = false end
  c.author = c.author or "user"
  c.created_at = c.created_at or os.date("!%Y-%m-%dT%H:%M:%SZ")
  table.insert(list, c)
  events.emit("comments:changed", {})
  return c
end

function M.remove(id)
  -- Borra el comentario y, EN CASCADA, sus respuestas (reply_to == id), para no
  -- dejar respuestas huérfanas apuntando a un padre inexistente.
  local removed = false
  for i = #list, 1, -1 do
    local c = list[i]
    if c.id == id or c.reply_to == id then
      table.remove(list, i)
      removed = true
    end
  end
  if removed then events.emit("comments:changed", {}) end
  return removed
end

function M.update(id, fields)
  local c = M.by_id(id)
  if not c then return false end
  for k, v in pairs(fields) do c[k] = v end
  events.emit("comments:changed", {})
  return true
end

--- Comentarios que responden a `id` (reply_to == id), en orden de inserción.
function M.replies(id)
  local out = {}
  for _, c in ipairs(list) do
    if c.reply_to == id then out[#out + 1] = c end
  end
  return out
end

--- Hilo completo de un comentario: el padre primero, luego sus respuestas.
--- Lista vacía si `id` no existe.
function M.thread(id)
  local parent = M.by_id(id)
  if not parent then return {} end
  local out = { parent }
  for _, c in ipairs(M.replies(id)) do out[#out + 1] = c end
  return out
end

function M.load()
  list = store.load().comments or {}
  return list
end

function M.persist()
  -- No persistir el campo runtime _extmark_id.
  local clean = {}
  for _, c in ipairs(list) do
    local copy = {}
    for k, v in pairs(c) do if k ~= "_extmark_id" then copy[k] = v end end
    clean[#clean+1] = copy
  end
  return store.save({ version = 1, comments = clean })
end

return M
