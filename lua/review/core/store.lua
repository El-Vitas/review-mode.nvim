local M = {}

-- Cache de la raíz por cwd (git rev-parse es subproceso; el cwd casi no cambia).
local _root_by_cwd = {}
function M.root_fn()
  local cwd = vim.uv and vim.uv.cwd() or vim.loop.cwd()
  local cached = _root_by_cwd[cwd]
  if cached ~= nil then return cached or nil end
  local out = vim.fn.systemlist({ "git", "-C", cwd, "rev-parse", "--show-toplevel" })
  local root = (vim.v.shell_error == 0 and out[1] and out[1] ~= "") and out[1] or false
  _root_by_cwd[cwd] = root
  return root or nil
end

--- Limpia el cache de raíces (por si cambia el layout del repo/worktree).
function M.clear_root_cache() _root_by_cwd = {} end

function M.path()
  local root = M.root_fn()
  if not root then return nil end
  return root .. "/.git/review.nvim/comments.json"
end

local function empty() return { version = 1, comments = {} } end

function M.load()
  local p = M.path()
  if not p then return empty() end
  local fd = io.open(p, "r")
  if not fd then return empty() end
  local content = fd:read("*a"); fd:close()
  local ok, data = pcall(vim.json.decode, content)
  if not ok or type(data) ~= "table" then return empty() end
  data.version = data.version or 1
  data.comments = data.comments or {}
  return data
end

function M.save(data)
  local p = M.path()
  if not p then return false end
  vim.fn.mkdir(vim.fn.fnamemodify(p, ":h"), "p")
  local fd = io.open(p, "w")
  if not fd then return false end
  fd:write(vim.json.encode(data)); fd:close()
  return true
end

-- Base de comparación persistida por repo (junto a comments.json).
local function base_path()
  local root = M.root_fn()
  if not root then return nil end
  return root .. "/.git/review.nvim/base"
end

function M.save_base(ref, label)
  local p = base_path()
  if not p then return false end
  vim.fn.mkdir(vim.fn.fnamemodify(p, ":h"), "p")
  local fd = io.open(p, "w")
  if not fd then return false end
  fd:write(vim.json.encode({ ref = ref or "HEAD", label = label })); fd:close()
  return true
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
  -- Compat: formato viejo era el ref pelado (texto plano, no JSON).
  local ok, data = pcall(vim.json.decode, raw)
  if ok and type(data) == "table" and data.ref then
    return data.ref, data.label
  end
  return raw, nil
end

return M
