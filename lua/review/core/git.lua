local store = require("review.core.store")

local M = {}

function M.root()
  return store.root_fn()
end

function M.rel_path(bufnr)
  local root = M.root()
  local full = vim.api.nvim_buf_get_name(bufnr)
  if not root or full == "" then return nil end
  root = root:gsub("/$", "")
  if full:sub(1, #root + 1) == root .. "/" then
    return full:sub(#root + 2)
  end
  return nil
end

function M.head_content(relpath)
  local root = M.root()
  if not root then return nil end
  local out = vim.fn.systemlist({ "git", "-C", root, "show", "HEAD:" .. relpath })
  if vim.v.shell_error ~= 0 then return nil end
  return out
end

function M.changed_files()
  local root = M.root()
  if not root then return {} end
  local tracked = vim.fn.systemlist({ "git", "-C", root, "diff", "--name-only", "HEAD" })
  if vim.v.shell_error ~= 0 then tracked = {} end
  local untracked = vim.fn.systemlist({ "git", "-C", root, "ls-files", "--others", "--exclude-standard" })
  if vim.v.shell_error ~= 0 then untracked = {} end
  local seen, out = {}, {}
  for _, f in ipairs(tracked) do if f ~= "" and not seen[f] then seen[f] = true; out[#out+1] = f end end
  for _, f in ipairs(untracked) do if f ~= "" and not seen[f] then seen[f] = true; out[#out+1] = f end end
  return out
end

return M
