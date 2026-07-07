local reconcile = require("review.features.agent.reconcile")

local M = {}

local function clean(c)
  local copy = {}
  for k, v in pairs(c) do
    if k ~= "_extmark_id" then copy[k] = v end
  end
  return copy
end

local function decode_maybe(x)
  if type(x) == "string" then
    local ok, d = pcall(vim.json.decode, x)
    if not ok then return nil end
    return d
  end
  return x
end

--- Busca el bufnr abierto para un relpath (o nil).
local function buf_for_path(core, relpath)
  local root = core.git.root()
  if not root then return nil end
  local full = root:gsub("/$", "") .. "/" .. relpath
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(b) and vim.api.nvim_buf_get_name(b) == full then
      return b
    end
  end
  return nil
end

function M.list(core, filter_json)
  local filter = decode_maybe(filter_json) or {}
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
  -- Preferimos el contenido del buffer abierto; si no, disco.
  local b = buf_for_path(core, c.path)
  if b then
    lines = vim.api.nvim_buf_get_lines(b, (c.lnum or 1) - 1, (c.end_lnum or c.lnum), false)
  else
    local root = core.git.root()
    local full = root and (root:gsub("/$", "") .. "/" .. c.path) or nil
    local ok, disk = false, nil
    if full then ok, disk = pcall(vim.fn.readfile, full) end
    if ok and disk then
      for i = (c.lnum or 1), (c.end_lnum or c.lnum) do lines[#lines + 1] = disk[i] or "" end
    end
  end
  return vim.json.encode({ comment = clean(c), lines = lines })
end

function M.add(core, json_or_table)
  local data = decode_maybe(json_or_table)
  if type(data) ~= "table" or not data.path or not data.lnum or not data.text then return "" end
  data.author = data.author or "agent"
  local c = core.state.add(data)
  core.state.persist()
  return c.id
end

function M.reply(core, parent_id, text)
  local parent = core.state.by_id(parent_id)
  if not parent or not text or vim.trim(text) == "" then return "" end
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
  if not text then return false end
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
