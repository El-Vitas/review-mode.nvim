local store = require("review.core.store")
local events = require("review.core.events")

local M = {}
local list = {}
-- Repo that `list` belongs to: set on load and where it gets saved. The cwd
-- can change (`:cd`) and saving to the cwd's repo mixed up projects.
local root

-- Unique id: seconds + monotonic counter + 3 random bytes from the system.
-- `vim.uv.random` does not touch the global `math.random` generator, which is
-- shared by all plugins in the session.
local _counter = 0
local function uuid()
  _counter = _counter + 1
  local rnd = vim.uv.random(3) or ""
  local r = 0
  for i = 1, #rnd do r = r * 256 + rnd:byte(i) end
  return string.format("%x-%x-%x", os.time(), _counter, r)
end

function M._reset() list = {}; root = nil end
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
  -- Deletes the comment and, in CASCADE, its replies (reply_to == id), so no
  -- orphan replies are left pointing to a nonexistent parent.
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

--- Comments that reply to `id` (reply_to == id), in insertion order.
function M.replies(id)
  local out = {}
  for _, c in ipairs(list) do
    if c.reply_to == id then out[#out + 1] = c end
  end
  return out
end

--- Full thread of a comment: the parent first, then its replies.
--- Empty list if `id` does not exist.
function M.thread(id)
  local parent = M.by_id(id)
  if not parent then return {} end
  local out = { parent }
  for _, c in ipairs(M.replies(id)) do out[#out + 1] = c end
  return out
end

function M.load()
  root = store.root_fn()
  list = store.load(root).comments
  return list
end

function M.persist()
  -- Do not persist the runtime field _extmark_id.
  local clean = {}
  for _, c in ipairs(list) do
    local copy = {}
    for k, v in pairs(c) do if k ~= "_extmark_id" then copy[k] = v end end
    clean[#clean+1] = copy
  end
  local ok = store.save({ version = 1, comments = clean }, root or store.root_fn())
  if not ok then
    vim.notify_once("review.nvim: comments could not be saved (is the cwd inside a git repo?)",
      vim.log.levels.WARN)
  end
  return ok
end

--- Switches to the current cwd's repo if it is a different one (`:cd`): saves the
--- previous repo's comments and loads the new one's. No-op if the repo did not change.
--- @return boolean switched
function M.switch_root()
  store.clear_root_cache()
  local new_root = store.root_fn()
  if new_root == root then return false end
  if root then M.persist() end
  root = new_root
  list = store.load(root).comments
  events.emit("comments:changed", {})
  return true
end

return M
