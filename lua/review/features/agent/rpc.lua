local reconcile = require("review.features.agent.reconcile")

local M = {}

local function clean(c)
  local copy = {}
  for k, v in pairs(c) do
    if k ~= "_extmark_id" then copy[k] = v end
  end
  return copy
end

-- Topes de lo que acepta la API. Lo que llega por RPC lo escribe un agente que
-- puede equivocarse: un valor de tipo incorrecto quedaba persistido y rompía el
-- render en cada arranque, y un rango enorme congelaba el editor.
local MAX_TEXT = 64 * 1024
local MAX_PATH = 4096
local MAX_LNUM = 10000000
local MAX_CONTEXT_LINES = 500

local function decode_maybe(x)
  if type(x) == "string" then
    -- luanil: un `null` del JSON llega como nil y no como vim.NIL (que es truthy).
    local ok, d = pcall(vim.json.decode, x, { luanil = { object = true, array = true } })
    if not ok then return nil end
    return d
  end
  return x
end

local function is_lnum(n)
  return type(n) == "number" and n == math.floor(n) and n >= 1 and n <= MAX_LNUM
end

local function is_text(s)
  return type(s) == "string" and #s <= MAX_TEXT and vim.trim(s) ~= ""
end

--- Path relativo al repo y sin salir de él: ni absoluto ni con segmentos `..`.
local function is_relpath(p)
  if type(p) ~= "string" or p == "" or #p > MAX_PATH or p:sub(1, 1) == "/" then return false end
  for seg in p:gmatch("[^/]+") do
    if seg == ".." then return false end
  end
  return true
end

--- Busca el bufnr abierto para un relpath (o nil). Compara por path relativo
--- resuelto desde la raíz del propio buffer (symlinks incluidos): comparar el
--- nombre del buffer contra `raíz del cwd .. relpath` fallaba si el cwd no era
--- la raíz o el archivo se abrió por un symlink, y entonces `is_modified`
--- respondía false con cambios sin guardar.
local function buf_for_path(core, relpath)
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(b) and vim.bo[b].buftype == "" and core.git.rel_path(b) == relpath then
      return b
    end
  end
  return nil
end

function M.list(core, filter_json)
  local filter = decode_maybe(filter_json)
  if filter_json ~= nil and type(filter) ~= "table" then return "[]" end -- filtro roto: nada
  filter = filter or {}
  local out = {}
  for _, c in ipairs(core.state.all()) do
    local ok = true
    if filter.author ~= nil and c.author ~= filter.author then ok = false end
    if filter.path ~= nil and c.path ~= filter.path then ok = false end
    if filter.resolved ~= nil and (not not c.resolved) ~= filter.resolved then ok = false end
    if filter.answered ~= nil then
      local answered = #core.state.replies(c.id) > 0
      if answered ~= filter.answered then ok = false end
    end
    if ok then out[#out + 1] = clean(c) end
  end
  if #out == 0 then return "[]" end
  return vim.json.encode(out)
end

function M.get(core, id)
  local c = core.state.by_id(id)
  if not c then return "null" end
  local obj = clean(c)
  obj.replies = {}
  for _, r in ipairs(core.state.replies(id)) do obj.replies[#obj.replies + 1] = clean(r) end
  return vim.json.encode(obj)
end

function M.context(core, id)
  local c = core.state.by_id(id)
  if not c then return "null" end
  local lines = {}
  -- Comentario de ARCHIVO: no hay líneas de contexto (aplica a todo el archivo).
  if c.file_level or not c.lnum then
    return vim.json.encode({ comment = clean(c), lines = lines })
  end
  if not is_relpath(c.path) then return vim.json.encode({ comment = clean(c), lines = lines }) end
  local first = c.lnum
  local last = math.min(c.end_lnum or c.lnum, first + MAX_CONTEXT_LINES - 1)
  -- Preferimos el contenido del buffer abierto; si no, disco.
  local b = buf_for_path(core, c.path)
  if b then
    lines = vim.api.nvim_buf_get_lines(b, first - 1, last, false)
  else
    local root = core.git.root()
    local full = root and (root:gsub("/$", "") .. "/" .. c.path) or nil
    -- Confinado al repo también después de resolver symlinks.
    local real, real_root = full and vim.uv.fs_realpath(full), root and vim.uv.fs_realpath(root)
    if real and real_root and vim.startswith(real, real_root .. "/") then
      local ok, disk = pcall(vim.fn.readfile, real, "", last)
      if ok then
        for i = first, math.min(last, #disk) do lines[#lines + 1] = disk[i] end
      end
    end
  end
  return vim.json.encode({ comment = clean(c), lines = lines })
end

function M.add(core, json_or_table)
  local data = decode_maybe(json_or_table)
  if type(data) ~= "table" or not is_relpath(data.path) or not is_text(data.text) then return "" end
  -- Comentario de ARCHIVO (file_level, sin línea) o de línea/rango.
  local file_level = data.file_level == true
  if not file_level then
    if not is_lnum(data.lnum) then return "" end
    if data.end_lnum ~= nil and not (is_lnum(data.end_lnum) and data.end_lnum >= data.lnum) then return "" end
  end
  -- Un agente puede firmar con su nombre, pero no como el humano.
  local author = data.author
  if author == nil then author = "agent" end
  if type(author) ~= "string" or author == "" or author == "user" or #author > 64 then return "" end
  -- Solo estos campos: el cliente no fija id, resolved, reply_to ni campos internos.
  local c = core.state.add({
    path = data.path,
    lnum = (not file_level) and data.lnum or nil,
    end_lnum = (not file_level) and data.end_lnum or nil,
    file_level = file_level or nil,
    text = data.text,
    author = author,
  })
  core.state.persist()
  return c.id
end

function M.reply(core, parent_id, text)
  local parent = core.state.by_id(parent_id)
  if not parent or not is_text(text) then return "" end
  local c = core.state.add({
    path = parent.path,
    lnum = parent.lnum,
    end_lnum = parent.end_lnum,
    text = text,
    author = "agent",
    reply_to = parent_id,
  })
  core.state.persist()
  return c.id
end

local function set_resolved(core, id, value)
  local ok = core.state.update(id, { resolved = value })
  if ok then core.state.persist() end
  return ok
end

function M.resolve(core, id) return set_resolved(core, id, true) end
function M.unresolve(core, id) return set_resolved(core, id, false) end

function M.update(core, id, text)
  if not is_text(text) then return false end
  local ok = core.state.update(id, { text = text })
  if ok then core.state.persist() end
  return ok
end

function M.delete(core, id)
  local ok = core.state.remove(id)
  if ok then core.state.persist() end
  return ok
end

function M.clean_resolved(core, path)
  local ids = {}
  for _, c in ipairs(core.state.all()) do
    if c.resolved and (path == nil or c.path == path) then ids[#ids + 1] = c.id end
  end
  for _, id in ipairs(ids) do core.state.remove(id) end
  if #ids > 0 then core.state.persist() end
  return #ids
end

function M.is_modified(core, path)
  local b = buf_for_path(core, path)
  if not b then return false end
  return vim.bo[b].modified
end

function M.notify_changed(core, path)
  local b = buf_for_path(core, path)
  if not b then return false end
  return reconcile.patch(core, b) == "applied"
end

return M
