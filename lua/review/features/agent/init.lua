local rpc = require("review.features.agent.rpc")
local watch = require("review.features.agent.watch")

local M = {}

function M.setup(core, opts)
  opts = opts or {}
  if not opts.enabled then return end

  _G.ReviewAgent = {
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

  local group = vim.api.nvim_create_augroup("ReviewAgentWatch", { clear = true })
  vim.api.nvim_create_autocmd({ "BufReadPost", "BufWinEnter" }, {
    group = group,
    callback = function(a) watch.attach(core, a.buf) end,
  })
  vim.api.nvim_create_autocmd({ "BufWipeout", "BufDelete" }, {
    group = group,
    callback = function(a) watch.detach(a.buf) end,
  })
  -- Adjuntar a los buffers ya abiertos al habilitar.
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(b) then watch.attach(core, b) end
  end

  -- Fallback manual para el único caso que auto no resuelve (buffer con cambios
  -- sin guardar en conflicto con disco): fuerza el patch del buffer actual.
  vim.api.nvim_create_user_command("ReviewReload", function()
    local b = vim.api.nvim_get_current_buf()
    -- forzamos aunque estuviera modified: el humano lo pidió explícitamente.
    if vim.bo[b].modified then vim.bo[b].modified = false end
    require("review.features.agent.reconcile").patch(core, b)
  end, {})

  vim.schedule(function()
    vim.notify(
      "review.nvim: agent RPC enabled on socket " .. tostring(vim.v.servername),
      vim.log.levels.INFO
    )
  end)
end

require("review.core").registry.register({ name = "agent", setup = M.setup })

return M
