local rpc = require("review.features.agent.rpc")
local watch = require("review.features.agent.watch")

local M = {}
M._on = false -- runtime state (on/off)

-- RPC bridge exposed to the agent (set when turned on, cleared when turned off).
local function build_bridge(core)
  return {
    list = function(filter_json) return rpc.list(core, filter_json) end,
    get = function(id) return rpc.get(core, id) end,
    context = function(id) return rpc.context(core, id) end,
    add = function(json_or_table) return rpc.add(core, json_or_table) end,
    reply = function(parent_id, text) return rpc.reply(core, parent_id, text) end,
    resolve = function(id) return rpc.resolve(core, id) end,
    unresolve = function(id) return rpc.unresolve(core, id) end,
    update = function(id, text) return rpc.update(core, id, text) end,
    delete = function(id) return rpc.delete(core, id) end,
    clean_resolved = function(path) return rpc.clean_resolved(core, path) end,
    is_modified = function(path) return rpc.is_modified(core, path) end,
    notify_changed = function(path) return rpc.notify_changed(core, path) end,
    servername = function() return vim.v.servername end,
  }
end

function M.setup(core, opts)
  opts = opts or {}
  local leader = opts.leader or "<leader>r"

  -- The watcher re-anchors comments when the agent edits the file on disk.
  -- That ONLY makes sense for files with comments: watching every buffer would be
  -- expensive and useless. We only watch buffers whose file has ≥1 comment.
  local function file_has_comments(bufnr)
    if not vim.api.nvim_buf_is_valid(bufnr) or vim.bo[bufnr].buftype ~= "" then return false end
    local rel = core.git.rel_path(bufnr)
    return rel ~= nil and #core.state.for_path(rel) > 0
  end

  local function refresh_one(bufnr)
    if not M._on then return end
    if file_has_comments(bufnr) then watch.attach(core, bufnr) else watch.detach(bufnr) end
  end

  local function sync_all()
    if not M._on then return end
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_loaded(b) then refresh_one(b) end
    end
  end

  -- Autocmds are ALWAYS registered; their callbacks are no-ops when the agent is
  -- off (they only check the M._on boolean). That way turning on/off recreates nothing.
  local group = vim.api.nvim_create_augroup("ReviewAgentWatch", { clear = true })
  vim.api.nvim_create_autocmd({ "BufReadPost", "BufWinEnter" }, {
    group = group,
    callback = function(a) refresh_one(a.buf) end,
  })
  vim.api.nvim_create_autocmd({ "BufWipeout", "BufDelete" }, {
    group = group,
    callback = function(a) watch.detach(a.buf) end,
  })
  -- When comments change: re-arm watchers (a file with new comments starts
  -- being watched; one without comments stops being watched). Guarded by M._on.
  core.events.on("comments:changed", vim.schedule_wrap(sync_all))

  -- ── Turn on / off live (without restarting) ───────────────────────────────
  function M.enable()
    local was_on = M._on
    M._on = true
    _G.ReviewAgent = build_bridge(core) -- always (re)establish the RPC bridge
    if not was_on then
      vim.schedule(sync_all) -- hook watchers onto the files-with-comments
      vim.notify("review: agent ON (RPC socket " .. tostring(vim.v.servername) .. ")", vim.log.levels.INFO)
    end
  end

  function M.disable()
    if not M._on then return end
    M._on = false
    watch.detach_all() -- closes all fs_events + timers
    _G.ReviewAgent = nil
    vim.notify("review: agent OFF", vim.log.levels.INFO)
  end

  function M.toggle()
    if M._on then M.disable() else M.enable() end
  end

  vim.api.nvim_create_user_command("ReviewAgent", function(a)
    local arg = (a.args ~= "" and a.args) or "toggle"
    if arg == "on" then M.enable()
    elseif arg == "off" then M.disable()
    else M.toggle() end
  end, { nargs = "?", complete = function() return { "on", "off", "toggle" } end })
  vim.api.nvim_create_user_command("Ra", function(a)
    local arg = (a.args ~= "" and a.args) or "toggle"
    if arg == "on" then M.enable() elseif arg == "off" then M.disable() else M.toggle() end
  end, { nargs = "?", complete = function() return { "on", "off", "toggle" } end })
  vim.keymap.set("n", leader .. "a", function() M.toggle() end, { desc = "Review: toggle agent (RPC + watchers)" })

  -- Manual fallback: forces the patch of the current buffer (rare case of a
  -- conflict due to unsaved changes). Only useful with the agent on.
  vim.api.nvim_create_user_command("ReviewReload", function()
    local b = vim.api.nvim_get_current_buf()
    if vim.bo[b].modified then vim.bo[b].modified = false end
    require("review.features.agent.reconcile").patch(core, b)
  end, {})

  -- Initial state: off by default. It only turns on automatically if explicitly
  -- requested (autostart, or enabled=true for compat with tests/other setups).
  if opts.autostart or opts.enabled then M.enable() end
end

require("review.core").registry.register({ name = "agent", setup = M.setup })

return M
