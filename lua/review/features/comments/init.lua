local render = require("review.features.comments.render")
local commands = require("review.features.comments.commands")

local M = {}

function M.setup(core, opts)
  opts = opts or {}

  local group = vim.api.nvim_create_augroup("ReviewComments", { clear = true })

  vim.api.nvim_create_autocmd({ "BufReadPost", "BufEnter" }, {
    group = group,
    callback = function(args)
      render.render(core, args.buf)
    end,
  })

  vim.api.nvim_create_autocmd("BufWritePost", {
    group = group,
    callback = function(args)
      render.sync_positions(core, args.buf)
      core.state.persist()
    end,
  })

  commands.setup(core, opts)
end

require("review.core").registry.register({ name = "comments", setup = M.setup })

return M
