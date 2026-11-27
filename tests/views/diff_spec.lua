local diff = require("review.features.views.diff")

describe("views.diff.parse_unified_diff", function()
  it("parses a simple replacement hunk", function()
    local text = table.concat({
      "diff --git a/foo.lua b/foo.lua",
      "index 111..222 100644",
      "--- a/foo.lua",
      "+++ b/foo.lua",
      "@@ -2,2 +2,3 @@",
      "-local a = 1",
      "-local b = 2",
      "+local a = 10",
      "+local b = 20",
      "+local c = 30",
    }, "\n")
    local hunks = diff.parse_unified_diff(text)
    assert.are.equal(1, #hunks)
    local h = hunks[1]
    assert.are.equal(2, h.old_start)
    assert.are.equal(2, h.old_count)
    assert.are.equal(2, h.new_start)
    assert.are.equal(3, h.new_count)
    assert.are.same({ "local a = 1", "local b = 2" }, h.del_lines)
    assert.are.same({ "local a = 10", "local b = 20", "local c = 30" }, h.add_lines)
    assert.are.same({ 2, 3, 4 }, h.add_lnums)
  end)

  it("parses multiple hunks", function()
    local text = table.concat({
      "@@ -1 +1 @@",
      "-x",
      "+y",
      "@@ -10,0 +11,2 @@",
      "+z1",
      "+z2",
    }, "\n")
    local hunks = diff.parse_unified_diff(text)
    assert.are.equal(2, #hunks)
    assert.are.equal(1, hunks[1].old_start)
    assert.are.same({ 11, 12 }, hunks[2].add_lnums)
  end)

  it("empty text or text without hunks returns an empty list", function()
    assert.are.same({}, diff.parse_unified_diff(""))
    assert.are.same({}, diff.parse_unified_diff("diff --git a/x b/x\nindex 1..2 100644\n"))
  end)

  it("add-only hunk (old_count defaults to 1 when missing)", function()
    local text = "@@ -5 +5,2 @@\n+added1\n+added2\n"
    local hunks = diff.parse_unified_diff(text)
    assert.are.equal(1, hunks[1].old_count)
    assert.are.equal(2, hunks[1].new_count)
    assert.are.same({}, hunks[1].del_lines)
    assert.are.same({ "added1", "added2" }, hunks[1].add_lines)
  end)
end)

describe("views.diff.hunks_for", function()
  it("nil when there is no git_root", function()
    assert.is_nil(diff.hunks_for("foo.lua", nil))
  end)
end)
