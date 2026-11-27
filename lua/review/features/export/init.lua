local commands = require("review.features.export.commands")

local M = {}

--- Entrypoint of the export feature. Registers commands and keymaps.
--- @param core table core table (git, store, state, ns, events, registry)
--- @param opts table feature options (leader, etc.)
function M.setup(core, opts)
  commands.setup(core, opts or {})
end

require("review.core").registry.register({ name = "export", setup = M.setup })

return M
