local markdown = require("review.features.export.markdown")

local M = {}

local function yank(text)
  if not text or text == "" then
    vim.notify("review.nvim: no comments", vim.log.levels.INFO)
    return
  end
  vim.fn.setreg("+", text)
  vim.notify("review.nvim: comments copied to the + register", vim.log.levels.INFO)
end

local function yank_file(core)
  local relpath = core.git.rel_path(0)
  if not relpath then
    vim.notify("review.nvim: current buffer is not in the repo", vim.log.levels.WARN)
    return
  end
  yank(markdown.file(core, relpath))
end

local function yank_all(core)
  yank(markdown.all(core))
end

function M.setup(core, opts)
  opts = opts or {}
  local leader = opts.leader or "<leader>r"

  vim.api.nvim_create_user_command("ReviewYankFile", function() yank_file(core) end, {})
  vim.api.nvim_create_user_command("ReviewYankAll", function() yank_all(core) end, {})
  vim.api.nvim_create_user_command("Ryf", function() yank_file(core) end, {})
  vim.api.nvim_create_user_command("Rya", function() yank_all(core) end, {})

  vim.keymap.set("n", leader .. "f", function() yank_file(core) end, { desc = "Review: yank comments of current file" })
  vim.keymap.set("n", leader .. "a", function() yank_all(core) end, { desc = "Review: yank all comments" })
end

return M
