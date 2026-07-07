local M = {}

function M.root_fn()
  local out = vim.fn.systemlist({ "git", "rev-parse", "--show-toplevel" })
  if vim.v.shell_error ~= 0 or not out[1] or out[1] == "" then return nil end
  return out[1]
end

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

return M
