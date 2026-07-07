local core = require("review.core")

describe("core.registry.setup", function()
  before_each(function() core.registry._reset() end)

  it("llama setup de features habilitadas y saltea deshabilitadas", function()
    local called = {}
    core.registry.register({ name = "featA", setup = function() called.a = true end })
    core.registry.register({ name = "featB", setup = function() called.b = true end })
    core.registry.setup(core, { features = { featB = { enabled = false } } })
    vim.wait(50)
    assert.is_true(called.a)
    assert.is_nil(called.b)
  end)
end)
