local reconcile = require("review.features.agent.reconcile")

local uv = vim.uv or vim.loop

-- _watchers[bufnr] = { fs = <fs_event>, timer = <uv_timer|nil>, path = <string> }
local M = { _watchers = {}, _debounce_ms = 150 }

function M._has(bufnr)
  return M._watchers[bufnr] ~= nil
end

--- Corre reconcile.patch en el hilo principal (las APIs de buffer NO son seguras
--- dentro del callback de libuv).
local function run_patch(core, bufnr)
  vim.schedule(function()
    if vim.api.nvim_buf_is_valid(bufnr) then
      reconcile.patch(core, bufnr)
    end
  end)
end

function M.attach(core, bufnr)
  if M._watchers[bufnr] then return end
  if not vim.api.nvim_buf_is_valid(bufnr) then return end
  local rel = core.git.rel_path(bufnr)
  if not rel then return end
  local path = vim.api.nvim_buf_get_name(bufnr)
  if path == "" then return end

  local fs = uv.new_fs_event()
  if not fs then return end
  local entry = { fs = fs, timer = nil, path = path }
  M._watchers[bufnr] = entry

  local function on_event(err)
    if err then return end
    -- Debounce: agrupar ráfagas de escritura del agente en un solo patch.
    if entry.timer then
      pcall(function() entry.timer:stop(); entry.timer:close() end)
      entry.timer = nil
    end
    local t = uv.new_timer()
    entry.timer = t
    t:start(M._debounce_ms, 0, function()
      pcall(function() t:stop(); t:close() end)
      entry.timer = nil
      -- Algunos editores reemplazan el inode (rename); re-armar el watch.
      pcall(function() entry.fs:stop() end)
      pcall(function() entry.fs:start(entry.path, {}, on_event) end)
      run_patch(core, bufnr)
    end)
  end

  local ok = pcall(function() fs:start(path, {}, on_event) end)
  if not ok then
    M.detach(bufnr)
  end
end

function M.detach(bufnr)
  local entry = M._watchers[bufnr]
  if not entry then return end
  if entry.timer then pcall(function() entry.timer:stop(); entry.timer:close() end) end
  if entry.fs then pcall(function() entry.fs:stop(); entry.fs:close() end) end
  M._watchers[bufnr] = nil
end

function M.detach_all()
  for bufnr in pairs(M._watchers) do
    M.detach(bufnr)
  end
end

return M
