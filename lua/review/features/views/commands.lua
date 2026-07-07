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
end

return M
