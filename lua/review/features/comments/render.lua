local M = {}

-- Global visibility of comments (shown/hidden toggle). When it is
-- true, `render` clears and paints nothing.
M.hidden = false

local function clamp(bufnr, lnum)
  local last = vim.api.nvim_buf_line_count(bufnr)
  if last < 1 then return 1 end
  if lnum < 1 then return 1 end
  if lnum > last then return last end
  return lnum
end

function M.render(core, bufnr)
  local rel = core.git.rel_path(bufnr)
  if not rel then return end

  vim.api.nvim_buf_clear_namespace(bufnr, core.ns.comments, 0, -1)
  if M.hidden then return end

  -- Stable order by line so the background tone can ALTERNATE between
  -- consecutive comments (so two adjacent comments do not look like one).
  -- Replies (reply_to) are NOT painted as independent comments:
  -- they live inside their parent's thread (peek). Only the top-level is painted.
  local comments = {}
  for _, c in ipairs(core.state.for_path(rel)) do
    -- file_level comments are NOT attached to a line: they are painted separately, at the end.
    if not c.reply_to and not c.file_level then comments[#comments + 1] = c end
  end
  table.sort(comments, function(a, b) return (a.lnum or 0) < (b.lnum or 0) end)

  for idx, c in ipairs(comments) do
    local lnum = clamp(bufnr, c.lnum or 1)
    local end_lnum = clamp(bufnr, c.end_lnum or lnum)
    if end_lnum < lnum then lnum, end_lnum = end_lnum, lnum end
    local row = lnum - 1
    local text = c.text or ""
    -- Compact one-line badge (collapses line breaks). Short on purpose: the full
    -- text is read in the floating peek (<leader>rp), instead of dragging a long
    -- strip at the end of the line.
    text = text:gsub("[\r\n]+", " ")
    if #text > 100 then text = text:sub(1, 98) .. "…" end

    local resolved = c.resolved
    local is_agent = c.author and c.author ~= "user"
    local alt = (idx % 2 == 0) -- alternating background tone to separate consecutive ones
    -- Background priority: resolved > stale > agent > normal (alternating).
    local line_hl, badge_hl, edge_hl
    if resolved then
      line_hl = "ReviewCommentLineResolved"
      badge_hl = "ReviewCommentBadgeResolved"
      edge_hl = "ReviewCommentBadgeEdgeResolved"
    elseif c.stale then
      line_hl = "ReviewCommentStale"
      badge_hl = "ReviewCommentBadge"
      edge_hl = "ReviewCommentBadgeEdge"
    elseif is_agent then
      line_hl = "ReviewCommentAgent"
      badge_hl = "ReviewCommentBadgeAgent"
      edge_hl = "ReviewCommentBadgeEdgeAgent"
    else
      line_hl = alt and "ReviewCommentLine2" or "ReviewCommentLine"
      badge_hl = "ReviewCommentBadge"
      edge_hl = "ReviewCommentBadgeEdge"
    end

    local icon
    if resolved then icon = "✓"
    elseif is_agent then icon = "🤖"
    else icon = "💬" end
    if c.stale then icon = "⚠ " .. icon end
    -- Suffix with the number of replies (threading).
    local nrep = #core.state.replies(c.id)
    local suffix = nrep > 0 and (" ↩" .. nrep) or ""

    -- ANCHOR extmark (first line): carries end_row to track the range while
    -- editing, the line highlight and a BADGE with a background and a small edge at the end.
    -- It is the one sync_positions uses; for 1 line, the only one.
    -- (The nested brackets on the left are drawn by the statuscolumn — see
    -- gutter.lua — because the sign column only supports 1 sign per line.)
    -- The badge goes as its own VIRTUAL LINE ABOVE the block (not as virt_text
    -- stuck to the eol): that way it is a "header" that cannot be edited, the cursor
    -- skips it (it is virtual, not a real line) and it stays well associated with the
    -- code below. It allows showing more characters than the previous chip.
    -- LOW priority for the line background: so the `cursorline` (current line)
    -- wins over the comment background and you do NOT get lost inside a comment.
    -- (The default for line_hl_group is 4096, which covers the cursorline.)
    local id = vim.api.nvim_buf_set_extmark(bufnr, core.ns.comments, row, 0, {
      end_row = end_lnum - 1,
      line_hl_group = line_hl,
      priority = 100,
      virt_lines = {
        {
          { "▏ ", edge_hl },
          { icon .. " " .. text .. suffix .. " ", badge_hl },
          { "▕", edge_hl },
        },
      },
      virt_lines_above = true,
    })
    c._extmark_id = id

    -- Continuation lines: same background (the border/bracket is painted by the gutter).
    for r = row + 1, end_lnum - 1 do
      vim.api.nvim_buf_set_extmark(bufnr, core.ns.comments, r, 0, {
        line_hl_group = line_hl,
        priority = 100,
      })
    end
  end

  -- FILE comments (file_level): cards at the VERY BOTTOM (below the
  -- last line). They belong to no line → they carry no _extmark_id or
  -- anchor_text, so sync_positions/relocate/reconcile ignore them.
  M.render_file_comments(core, bufnr, rel)
end

--- Paints the file-comment cards as virtual lines
--- below the last line of the buffer. Idempotent (render() already cleared the ns).
function M.render_file_comments(core, bufnr, rel)
  rel = rel or core.git.rel_path(bufnr)
  if not rel then return end
  local files = {}
  for _, c in ipairs(core.state.for_path(rel)) do
    if c.file_level and not c.reply_to then files[#files + 1] = c end
  end
  if #files == 0 then return end
  table.sort(files, function(a, b) return (a.created_at or "") < (b.created_at or "") end)

  local vlines = {
    { { "▏ ", "ReviewCommentBadgeEdge" }, { "⧉ file comments ", "ReviewCommentBadge" }, { "▕", "ReviewCommentBadgeEdge" } },
  }
  for _, c in ipairs(files) do
    local text = (c.text or ""):gsub("[\r\n]+", " ")
    if #text > 100 then text = text:sub(1, 98) .. "…" end
    local resolved = c.resolved
    local is_agent = c.author and c.author ~= "user"
    local badge_hl, edge_hl, icon
    if resolved then
      badge_hl, edge_hl, icon = "ReviewCommentBadgeResolved", "ReviewCommentBadgeEdgeResolved", "✓"
    elseif is_agent then
      badge_hl, edge_hl, icon = "ReviewCommentBadgeAgent", "ReviewCommentBadgeEdgeAgent", "🤖"
    else
      badge_hl, edge_hl, icon = "ReviewCommentBadge", "ReviewCommentBadgeEdge", "💬"
    end
    local nrep = #core.state.replies(c.id)
    local suffix = nrep > 0 and (" ↩" .. nrep) or ""
    vlines[#vlines + 1] = {
      { "▏ ", edge_hl },
      { icon .. " " .. text .. suffix .. " ", badge_hl },
      { "▕", edge_hl },
    }
  end
  local last = vim.api.nvim_buf_line_count(bufnr)
  -- virt_lines go BELOW the anchor line by default → at the very bottom.
  vim.api.nvim_buf_set_extmark(bufnr, core.ns.comments, last - 1, 0, { virt_lines = vlines })
end

function M.sync_positions(core, bufnr)
  local rel = core.git.rel_path(bufnr)
  if not rel then return end

  local comments = core.state.for_path(rel)
  for _, c in ipairs(comments) do
    if c._extmark_id then
      -- `details=true` to recover `end_row` and preserve the range.
      local ok, pos = pcall(vim.api.nvim_buf_get_extmark_by_id, bufnr, core.ns.comments, c._extmark_id, { details = true })
      if ok and pos and pos[1] then
        local new_lnum = clamp(bufnr, pos[1] + 1)
        local details = pos[3]
        local new_end = new_lnum
        if details and details.end_row then
          new_end = clamp(bufnr, details.end_row + 1)
        end
        if new_end < new_lnum then new_lnum, new_end = new_end, new_lnum end
        if new_lnum ~= c.lnum or new_end ~= c.end_lnum then
          core.state.update(c.id, { lnum = new_lnum, end_lnum = new_end })
        end
      end
    end
  end
end

--- Re-locates comments by CONTENT (`anchor_text`) — meant to
--- run when OPENING a file that may have changed on disk while it was closed
--- (there were no extmarks to follow the movement). For each comment with
--- `anchor_text`: if the saved line no longer matches, it looks for the nearest
--- occurrence of that text in the buffer and relocates (shifting `end_lnum` by the same
--- delta); if it does not find it, it marks it `stale`. No-op outside the repo.
function M.relocate(core, bufnr)
  local rel = core.git.rel_path(bufnr)
  if not rel then return end
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local total = #lines
  for _, c in ipairs(core.state.for_path(rel)) do
    if c.anchor_text and c.anchor_text ~= "" then
      local target = vim.trim(c.anchor_text)
      local cur = c.lnum and lines[c.lnum] and vim.trim(lines[c.lnum]) or nil
      if cur ~= target then
        local best, bestdist
        for i = 1, total do
          if vim.trim(lines[i] or "") == target then
            local d = math.abs(i - (c.lnum or 1))
            if not best or d < bestdist then best, bestdist = i, d end
          end
        end
        if best then
          local delta = best - (c.lnum or best)
          local new_end = math.max(1, math.min(total, (c.end_lnum or c.lnum or best) + delta))
          core.state.update(c.id, { lnum = best, end_lnum = new_end, stale = false })
        elseif not c.stale then
          core.state.update(c.id, { stale = true })
        end
      elseif c.stale then
        core.state.update(c.id, { stale = false })
      end
    end
  end
end

--- Re-syncs positions from the extmarks and marks as `stale` the comments
--- whose anchored line stopped matching their `anchor_text` (safety net
--- after a code change on disk). Unmarks those that matched again.
--- No-op if the buffer is outside the repo.
function M.reconcile(core, bufnr)
  local rel = core.git.rel_path(bufnr)
  if not rel then return end

  M.sync_positions(core, bufnr)

  local last = vim.api.nvim_buf_line_count(bufnr)
  for _, c in ipairs(core.state.for_path(rel)) do
    if c.anchor_text and c.anchor_text ~= "" then
      local row = (c.lnum or 1) - 1
      local now = ""
      if row >= 0 and row < last then
        now = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ""
      end
      -- it matches if the current line equals the anchor text (tolerant of
      -- re-indentation/whitespace: we compare trims).
      local matches = vim.trim(now) == vim.trim(c.anchor_text)
      if matches and c.stale then
        core.state.update(c.id, { stale = false })
      elseif not matches and not c.stale then
        core.state.update(c.id, { stale = true })
      end
    end
  end

  M.render(core, bufnr)
end

return M
