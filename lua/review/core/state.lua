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
  for i, c in ipairs(list) do
    if c.id == id then table.remove(list, i); events.emit("comments:changed", {}); return true end
  end
  return false
end

function M.update(id, fields)
  local c = M.by_id(id)
  if not c then return false end
  for k, v in pairs(fields) do c[k] = v end
  events.emit("comments:changed", {})
  return true
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
