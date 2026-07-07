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
      vim.notify("uso: :ReviewView {normal|inline|split}", vim.log.levels.ERROR)
      return
    end
    views_mod.set(core, vim.api.nvim_get_current_buf(), mode)
  end

  local ucmd_opts = {
    nargs = 1,
    complete = function() return ORDER end,
  }
  -- Comando largo + alias corto, ambos comandos REALES. La minúscula `rv`
  -- la resuelve plugin/review.lua (core Task 7) vía cnoreabbrev → Rv.
  vim.api.nvim_create_user_command("ReviewView", run, ucmd_opts)
  vim.api.nvim_create_user_command("Rv", run, vim.deepcopy(ucmd_opts))

  vim.keymap.set("n", leader .. "v", function()
    local bufnr = vim.api.nvim_get_current_buf()
    local current = views_mod.mode[bufnr] or "normal"
    views_mod.set(core, bufnr, next_mode(current))
  end, { desc = "review.nvim: ciclar vista normal/inline/split" })
end

return M
