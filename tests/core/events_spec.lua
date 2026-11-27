local events = require("review.core.events")

describe("core.events", function()
  before_each(function() events._reset() end)

  it("on/emit delivers the payload", function()
    local got
    events.on("x:test", function(p) got = p.v end)
    events.emit("x:test", { v = 42 })
    vim.wait(50, function() return got ~= nil end)
    assert.are.equal(42, got)
  end)

  it("_reset clears the subscriptions", function()
    local calls = 0
    events.on("x:test", function() calls = calls + 1 end)
    events._reset()
    events.emit("x:test", {})
    vim.wait(50)
    assert.are.equal(0, calls)
  end)
end)
