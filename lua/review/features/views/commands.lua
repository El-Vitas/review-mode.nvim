local M = {}

local ORDER = { "normal", "inline", "split" }

local function next_mode(current)
  for i, m in ipairs(ORDER) do
    if m == current then
      return ORDER[i % #ORDER + 1]
    end
  end
  return ORDER[1]
end

function M.setup(core, opts, views_mod)
  opts = opts or {}
  local leader = opts.leader or "<leader>r"

  local function run(cmd_opts)
    local mode = cmd_opts.args
    if mode == "" then
      vim.notify("usage: :ReviewView {normal|inline|split}", vim.log.levels.ERROR)
      return
    end
    views_mod.set(core, mode)
  end

  local ucmd_opts = { nargs = 1, complete = function() return ORDER end }
  -- Comando largo + alias corto (ambos reales). La minúscula `rv` la resuelve
  -- plugin/review.lua vía cnoreabbrev → Rv.
  vim.api.nvim_create_user_command("ReviewView", run, ucmd_opts)
  vim.api.nvim_create_user_command("Rv", run, vim.deepcopy(ucmd_opts))

  -- Comandos directos por modo (globales), más cómodos que `:Rv split`.
  local function set_mode(mode)
    return function() views_mod.set(core, mode) end
  end
  local direct = { normal = "Normal", inline = "Inline", split = "Split" }
  for mode, suffix in pairs(direct) do
    vim.api.nvim_create_user_command("Review" .. suffix, set_mode(mode), {})
    vim.api.nvim_create_user_command("Rv" .. suffix:sub(1, 1):lower(), set_mode(mode), {})
  end

  -- Ciclar el modo global.
  vim.keymap.set("n", leader .. "v", function()
    views_mod.set(core, next_mode(views_mod.mode))
  end, { desc = "review.nvim: cycle view normal/inline/split" })

  -- ── Navegación de CAMBIOS (vs HEAD) ──────────────────────────────────────
  -- Para ubicar y saltar rápido a los cambios (además de las marcas del
  -- scrollbar). Los rangos salen del mismo diff que alimenta el scrollbar.
  local scrollbar = require("review.features.views.scrollbar")

  local function goto_change(dir)
    local bufnr = vim.api.nvim_get_current_buf()
    local hunks = scrollbar.hunks(core, bufnr)
    if #hunks == 0 then
      vim.notify("review.nvim: no changes vs HEAD", vim.log.levels.INFO)
      return
    end
    local cur = vim.fn.line(".")
    local target
    if dir > 0 then
      for _, h in ipairs(hunks) do
        if h.sl > cur then target = h.sl; break end
      end
      target = target or hunks[1].sl -- wrap al primero
    else
      for i = #hunks, 1, -1 do
        if hunks[i].sl < cur then target = hunks[i].sl; break end
      end
      target = target or hunks[#hunks].sl -- wrap al último
    end
    vim.api.nvim_win_set_cursor(0, { target, 0 })
    vim.cmd("normal! zz")
  end

  vim.api.nvim_create_user_command("ReviewNextChange", function() goto_change(1) end, {})
  vim.api.nvim_create_user_command("ReviewPrevChange", function() goto_change(-1) end, {})
  vim.keymap.set("n", "]r", function() goto_change(1) end, { desc = "review.nvim: next change" })
  vim.keymap.set("n", "[r", function() goto_change(-1) end, { desc = "review.nvim: prev change" })

  -- Lista de rangos de cambios (quickfix): "L4-8 changed" → Enter salta.
  local function list_changes()
    local bufnr = vim.api.nvim_get_current_buf()
    local hunks = scrollbar.hunks(core, bufnr)
    if #hunks == 0 then
      vim.notify("review.nvim: no changes vs HEAD", vim.log.levels.INFO)
      return
    end
    local fname = vim.api.nvim_buf_get_name(bufnr)
    local items = {}
    local label = { add = "added", change = "changed", delete = "deleted" }
    for _, h in ipairs(hunks) do
      local rng = (h.el > h.sl) and ("L" .. h.sl .. "-" .. h.el) or ("L" .. h.sl)
      items[#items + 1] = { filename = fname, lnum = h.sl, col = 1, text = rng .. "  " .. (label[h.kind] or h.kind) }
    end
    vim.fn.setqflist({}, " ", { title = "review.nvim: changes", items = items })
    vim.cmd("copen")
  end
  vim.api.nvim_create_user_command("ReviewChanges", list_changes, {})
  vim.api.nvim_create_user_command("Rch", list_changes, {})
  vim.keymap.set("n", leader .. "g", list_changes, { desc = "review.nvim: list changes (go)" })
end

return M
