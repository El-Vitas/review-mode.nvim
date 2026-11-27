local M = {}

-- Per-cwd root cache (git rev-parse is a subprocess; the cwd rarely changes).
local _root_by_cwd = {}
function M.root_fn()
  local cwd = vim.uv.cwd()
  if not cwd then return nil end -- the cwd was deleted
  local cached = _root_by_cwd[cwd]
  if cached ~= nil then return cached or nil end
  local out = vim.fn.systemlist({ "git", "-C", cwd, "rev-parse", "--show-toplevel" })
  local root = (vim.v.shell_error == 0 and out[1] and out[1] ~= "") and out[1] or false
  _root_by_cwd[cwd] = root
  return root or nil
end

--- Clears the root cache (in case the repo/worktree layout changes).
function M.clear_root_cache() _root_by_cwd = {} end

--- Path of the comments.json of repo `root` (default: the cwd's).
--- @param root string|nil
function M.path(root)
  root = root or M.root_fn()
  if not root then return nil end
  return root .. "/.git/review.nvim/comments.json"
end

local function empty() return { version = 1, comments = {} } end

--- Writes `tbl` as JSON ATOMICALLY: to a `.tmp` and then rename.
--- `io.open(p, "w")` truncates before writing, so an interruption midway left
--- the file empty or cut off, and the next load took it for "no data".
local function write_json(p, tbl)
  vim.fn.mkdir(vim.fn.fnamemodify(p, ":h"), "p")
  local tmp = p .. ".tmp"
  local fd = io.open(tmp, "w")
  if not fd then return false end
  local ok_w = fd:write(vim.json.encode(tbl))
  local ok_c = fd:close()
  if not (ok_w and ok_c) then
    os.remove(tmp)
    return false
  end
  return vim.uv.fs_rename(tmp, p) == true
end

--- @param root string|nil  repo whose comments.json is read (default: the cwd's)
function M.load(root)
  local p = M.path(root)
  if not p then return empty() end
  local fd = io.open(p, "r")
  if not fd then return empty() end
  local content = fd:read("*a"); fd:close()
  local ok, data = pcall(vim.json.decode, content, { luanil = { object = true, array = true } })
  if not ok or type(data) ~= "table" then
    -- Corrupt: set it aside instead of treating it as empty. Otherwise the next
    -- save would overwrite it and the comments would be lost without a trace.
    local aside = p .. ".corrupt-" .. os.date("%Y%m%d-%H%M%S")
    vim.uv.fs_rename(p, aside)
    vim.notify("review.nvim: comments.json is unreadable, moved to " .. aside, vim.log.levels.ERROR)
    return empty()
  end
  data.version = data.version or 1
  if type(data.comments) ~= "table" then data.comments = {} end
  return data
end

--- @param root string|nil  repo where it is saved (default: the cwd's)
function M.save(data, root)
  local p = M.path(root)
  if not p then return false end
  return write_json(p, data)
end

-- Comparison base persisted per repo (next to comments.json).
local function base_path()
  local root = M.root_fn()
  if not root then return nil end
  return root .. "/.git/review.nvim/base"
end

function M.save_base(ref, label)
  local p = base_path()
  if not p then return false end
  return write_json(p, { ref = ref or "HEAD", label = label })
end

--- @return string|nil ref, string|nil label
function M.load_base()
  local p = base_path()
  if not p then return nil end
  local fd = io.open(p, "r")
  if not fd then return nil end
  local raw = (fd:read("*a") or ""):gsub("%s+$", "")
  fd:close()
  if raw == "" then return nil end
  -- Compat: the old format was the bare ref (plain text, not JSON).
  local ok, data = pcall(vim.json.decode, raw)
  if ok and type(data) == "table" and data.ref then
    return data.ref, data.label
  end
  return raw, nil
end

return M
