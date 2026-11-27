local M = {}

local function anchor(c)
  if c.file_level or not c.lnum then
    return string.format("`%s` (file)", c.path) -- file-level comment
  end
  if c.end_lnum and c.end_lnum > c.lnum then
    return string.format("`%s:%d-%d`", c.path, c.lnum, c.end_lnum)
  end
  return string.format("`%s:%d`", c.path, c.lnum)
end

-- Collapses line breaks in the comment text into a space: each comment
-- MUST take exactly one numbered line, or `table.concat("\n")` would break the
-- numbering of the agent-ready markdown.
local function oneline(text)
  return ((text or ""):gsub("[\r\n]+", " "))
end

--- Formats a list of comments as agent-ready markdown: GROUPED by
--- file (heading `## <path>`) and SORTED by file + line, with
--- CONTINUOUS numbering. Excludes resolved ones. Replies (`reply_to`) are not
--- pending items: they are indented under their comment, so the
--- agent does not receive its own replies as tasks. Returns "" if none
--- remain.
--- @param list table[] list of comments (id, path, lnum, end_lnum, text, resolved, ...)
--- @return string
function M.markdown(list)
  list = list or {}
  -- Filter out resolved ones and group replies by parent.
  local items, replies, order = {}, {}, {}
  for i, c in ipairs(list) do
    order[c] = i
    if c.reply_to then
      replies[c.reply_to] = replies[c.reply_to] or {}
      table.insert(replies[c.reply_to], c)
    elseif not c.resolved then
      items[#items + 1] = c
    end
  end
  if #items == 0 then return "" end

  -- Sort by file and line. `table.sort` is not stable: the tiebreak by
  -- creation order keeps the numbering the same across exports.
  table.sort(items, function(a, b)
    if a.path ~= b.path then return a.path < b.path end
    if (a.lnum or 0) ~= (b.lnum or 0) then return (a.lnum or 0) < (b.lnum or 0) end
    return order[a] < order[b]
  end)

  local lines = {}
  local n = 0
  local cur_path = nil
  for _, c in ipairs(items) do
    if c.path ~= cur_path then
      cur_path = c.path
      if #lines > 0 then lines[#lines + 1] = "" end -- blank line between groups
      lines[#lines + 1] = "## " .. cur_path
    end
    n = n + 1
    -- We include the comment id (`id:<id>` token at the end) so an
    -- agent can target it (reply/resolve/etc.) without guessing.
    local id = c.id and ("  `id:" .. c.id .. "`") or ""
    lines[#lines + 1] = string.format("%d. %s %s%s", n, anchor(c), oneline(c.text), id)
    for _, r in ipairs(replies[c.id] or {}) do
      local rid = r.id and ("  `id:" .. r.id .. "`") or ""
      lines[#lines + 1] = string.format("   ↳ %s: %s%s", r.author or "user", oneline(r.text), rid)
    end
  end
  return table.concat(lines, "\n")
end

--- Markdown of the comments of a single file.
--- @param core table core table (uses core.state.for_path)
--- @param relpath string path relative to the git root
--- @return string
function M.file(core, relpath)
  return M.markdown(core.state.for_path(relpath))
end

--- Markdown of all the comments in the repo.
--- @param core table core table (uses core.state.all)
--- @return string
function M.all(core)
  return M.markdown(core.state.all())
end

return M
