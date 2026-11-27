-- The core is assembled here. Each submodule is added in its own Task.
local M = {
  registry = require("review.core.registry"),
  store = require("review.core.store"),
  git = require("review.core.git"),
  events = require("review.core.events"),
  ns = require("review.core.ns"),
  state = require("review.core.state"),
}
return M
