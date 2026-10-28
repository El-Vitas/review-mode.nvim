local rpc = require("review.features.agent.rpc")
local watch = require("review.features.agent.watch")

local M = {}
M._on = false -- estado runtime (encendido/apagado)

-- Bridge RPC expuesto al agente (se setea al encender, se limpia al apagar).
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

  -- El watcher re-ancla comentarios cuando el agente edita el archivo en disco.
  -- Eso SOLO tiene sentido en archivos con comentarios: vigilar cada buffer sería
  -- caro e inútil. Vigilamos únicamente buffers cuyo archivo tiene ≥1 comentario.
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

  -- Autocmds SIEMPRE registrados; sus callbacks son no-op cuando el agente está
  -- apagado (solo chequean el booleano M._on). Así prender/apagar no recrea nada.
  local group = vim.api.nvim_create_augroup("ReviewAgentWatch", { clear = true })
  vim.api.nvim_create_autocmd({ "BufReadPost", "BufWinEnter" }, {
    group = group,
    callback = function(a) refresh_one(a.buf) end,
  })
  vim.api.nvim_create_autocmd({ "BufWipeout", "BufDelete" }, {
    group = group,
    callback = function(a) watch.detach(a.buf) end,
  })
  -- Al cambiar comentarios: re-armar watchers (archivo con comentarios nuevos se
  -- empieza a vigilar; sin comentarios se deja de vigilar). Guardado por M._on.
  core.events.on("comments:changed", vim.schedule_wrap(sync_all))

  -- ── Encender / apagar en caliente (sin reiniciar) ─────────────────────────
  function M.enable()
    local was_on = M._on
    M._on = true
    _G.ReviewAgent = build_bridge(core) -- siempre (re)establecer el bridge RPC
    if not was_on then
      vim.schedule(sync_all) -- engancha watchers de los archivos-con-comentarios
      vim.notify("review: agent ON (RPC socket " .. tostring(vim.v.servername) .. ")", vim.log.levels.INFO)
    end
  end

  function M.disable()
    if not M._on then return end
    M._on = false
    watch.detach_all() -- cierra todos los fs_event + timers
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

  -- Fallback manual: fuerza el patch del buffer actual (caso raro de conflicto
  -- por cambios sin guardar). Útil solo con el agente encendido.
  vim.api.nvim_create_user_command("ReviewReload", function()
    local b = vim.api.nvim_get_current_buf()
    if vim.bo[b].modified then vim.bo[b].modified = false end
    require("review.features.agent.reconcile").patch(core, b)
  end, {})

  -- Estado inicial: apagado por defecto. Auto-enciende solo si se pide
  -- explícitamente (autostart, o enabled=true para compat con tests/otros setups).
  if opts.autostart or opts.enabled then M.enable() end
end

require("review.core").registry.register({ name = "agent", setup = M.setup })

return M
