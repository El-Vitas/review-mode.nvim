-- El core se ensambla acá. Cada submódulo se agrega en su Task.
local M = {
  registry = require("review.core.registry"),
  store = require("review.core.store"),
  git = require("review.core.git"),
  events = require("review.core.events"),
  ns = require("review.core.ns"),
}
return M
