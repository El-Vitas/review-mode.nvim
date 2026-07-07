local commands = require("review.features.export.commands")

local M = {}

--- Entrypoint de la feature export. Registra comandos y keymaps.
--- @param core table tabla core (git, store, state, ns, events, registry)
--- @param opts table opciones de la feature (leader, etc.)
function M.setup(core, opts)
  commands.setup(core, opts or {})
end

require("review.core").registry.register({ name = "export", setup = M.setup })

return M
