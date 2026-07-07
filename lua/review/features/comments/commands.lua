local mode = require("review.features.comments.mode")

local M = {}

local function open_quickfix(core)
  -- Ruta ABSOLUTA: la quickfix resuelve `filename` contra el cwd, pero
  -- `c.path` es relativo a la raíz del repo. Sin esto, abrir nvim desde un
  -- subdirectorio abriría el archivo equivocado.
  local root = core.git.root() or ""
  local base = (root ~= "") and (root .. "/") or ""
  local items = {}
  for _, c in ipairs(core.state.all()) do
    local prefix = c.resolved and "[✓] " or ""
    table.insert(items, {
      filename = base .. c.path,
      lnum = c.lnum,
      text = prefix .. (c.text or ""),
    })
  end
  vim.fn.setqflist(items)
  vim.cmd("copen")
end

function M.setup(core, opts)
  opts = opts or {}
  local leader = opts.leader or "<leader>r"

  local function toggle() mode.toggle(core) end
  local function list() open_quickfix(core) end

  -- Comando largo + alias corto (ambos comandos REALES). La versión en
  -- minúscula (`rcm`/`rl`) la resuelve `plugin/review.lua` (core Task 7)
  -- vía cnoreabbrev apuntando a estos comandos reales.
  vim.api.nvim_create_user_command("ReviewCommentMode", toggle, {})
  vim.api.nvim_create_user_command("Rcm", toggle, {})
  vim.api.nvim_create_user_command("ReviewList", list, {})
  vim.api.nvim_create_user_command("Rl", list, {})

  vim.keymap.set("n", leader .. "r", function() mode.toggle(core) end, { desc = "Review: toggle comment mode" })
  vim.keymap.set("n", leader .. "c", function() mode.add_here(core, {}) end, { desc = "Review: add comment" })
  vim.keymap.set("v", leader .. "c", function() mode.add_here(core, {}) end, { desc = "Review: add comment (range)" })
  vim.keymap.set("n", leader .. "d", function() mode.delete_here(core) end, { desc = "Review: delete comment here" })
  vim.keymap.set("n", leader .. "x", function() mode.resolve_here(core) end, { desc = "Review: resolve comment here" })
end

return M
