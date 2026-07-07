-- El core se ensambla acá. Cada submódulo se agrega en su Task.
local M = {
  registry = require("review.core.registry"),
  store = require("review.core.store"),
}
return M
