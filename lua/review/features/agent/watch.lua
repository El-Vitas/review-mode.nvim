local reconcile = require("review.features.agent.reconcile")

local uv = vim.uv or vim.loop

-- _watchers[bufnr] = { fs = <fs_event>, timer = <uv_timer>, path = <string> }
local M = { _watchers = {}, _debounce_ms = 150, _rearm_tries = 3, _rearm_ms = 200 }

function M._has(bufnr)
  return M._watchers[bufnr] ~= nil
end

--- Corre reconcile.patch en el hilo principal (las APIs de buffer NO son seguras
--- dentro del callback de libuv). Un conflicto (cambios sin guardar mientras el
--- archivo cambió en disco) se avisa una vez por buffer: el humano tiene que
--- saber que su buffer quedó desfasado del disco.
local function run_patch(core, bufnr)
  vim.schedule(function()
    if not vim.api.nvim_buf_is_valid(bufnr) then return end
    local res = reconcile.patch(core, bufnr)
    if res == "conflict" and not vim.b[bufnr].review_conflict_notified then
      vim.b[bufnr].review_conflict_notified = true
      vim.notify(("review.nvim: %s changed on disk; your unsaved edits were kept (:ReviewReload to take the disk version)")
        :format(vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ":~:.")), vim.log.levels.WARN)
    elseif res == "applied" or res == "identical" then
      vim.b[bufnr].review_conflict_notified = nil
    end
  end)
end

local function start_fs(entry, on_event)
  local ok, res = pcall(entry.fs.start, entry.fs, entry.path, {}, on_event)
  return ok and res == 0
end

function M.attach(core, bufnr)
  if M._watchers[bufnr] then return end
  if not vim.api.nvim_buf_is_valid(bufnr) then return end
  local rel = core.git.rel_path(bufnr)
  if not rel then return end
  local path = vim.api.nvim_buf_get_name(bufnr)
  if path == "" then return end

  local fs, timer = uv.new_fs_event(), uv.new_timer()
  if not (fs and timer) then
    if fs then fs:close() end
    if timer then timer:close() end
    return
  end
  local entry = { fs = fs, timer = timer, path = path }
  M._watchers[bufnr] = entry

  local on_event
  -- Algunos editores y git reemplazan el archivo (borrar + crear, o rename): hay
  -- que re-armar el watch. Si el archivo todavía no reapareció, se reintenta; si
  -- no vuelve, se suelta el watcher para que el próximo attach lo cree de nuevo.
  local function rearm(tries_left)
    pcall(entry.fs.stop, entry.fs)
    if start_fs(entry, on_event) then
      run_patch(core, bufnr)
    elseif tries_left > 0 then
      entry.timer:start(M._rearm_ms, 0, function() rearm(tries_left - 1) end)
    else
      vim.schedule(function() M.detach(bufnr) end)
    end
  end

  on_event = function(err)
    if err then return end
    -- Debounce: agrupar ráfagas de escritura del agente en un solo patch.
    entry.timer:stop()
    entry.timer:start(M._debounce_ms, 0, function() rearm(M._rearm_tries) end)
  end

  if not start_fs(entry, on_event) then
    M.detach(bufnr)
  end
end

function M.detach(bufnr)
  local entry = M._watchers[bufnr]
  if not entry then return end
  pcall(function() entry.timer:stop(); entry.timer:close() end)
  pcall(function() entry.fs:stop(); entry.fs:close() end)
  M._watchers[bufnr] = nil
end

function M.detach_all()
  for bufnr in pairs(M._watchers) do
    M.detach(bufnr)
  end
end

return M
