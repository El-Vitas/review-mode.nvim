local M = {}

--- Applies the disk content to the buffer as a minimal PATCH (not `:edit!`), so
--- that extmarks (and therefore anchored comments) re-anchor themselves
--- by gravity. Never overwrites the human's unsaved changes.
--- @return "applied"|"identical"|"conflict"|"skipped"
function M.patch(core, bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then return "skipped" end
  local rel = core.git.rel_path(bufnr)
  if not rel then return "skipped" end

  local name = vim.api.nvim_buf_get_name(bufnr)
  if name == "" then return "skipped" end

  -- Conflict: there are unsaved edits → do NOT overwrite (see roadmap §1.3.3).
  if vim.bo[bufnr].modified then return "conflict" end

  -- `readfile()` returns the disk bytes unconverted, but the buffer is already
  -- in UTF-8: patching a latin1 file put invalid bytes into the buffer
  -- and the next :w wrote garbage. Those files are not reconciled automatically.
  local fenc = vim.bo[bufnr].fileencoding
  if fenc ~= "" and fenc ~= "utf-8" then return "skipped" end

  local ok, disk = pcall(vim.fn.readfile, name)
  if not ok or type(disk) ~= "table" then return "skipped" end

  local buf_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local a = table.concat(buf_lines, "\n")
  local b = table.concat(disk, "\n")
  if a == b then return "identical" end

  local hunks = (vim.text.diff or vim.diff)(a, b, { result_type = "indices" })
  if not hunks or #hunks == 0 then return "identical" end

  -- Apply from BOTTOM to TOP so the indices of the upper hunks are not
  -- invalidated. Each hunk = { start_a, count_a, start_b, count_b } (1-based in a
  -- and b; count==0 marks a pure insertion/deletion with start = previous line).
  for i = #hunks, 1, -1 do
    local h = hunks[i]
    local start_a, count_a, start_b, count_b = h[1], h[2], h[3], h[4]

    local repl = {}
    for j = start_b, start_b + count_b - 1 do
      repl[#repl + 1] = disk[j]
    end

    local s, e
    if count_a == 0 then
      -- insertion: `start_a` is the (1-based) line AFTER which to insert;
      -- in 0-based that is index `start_a` (set_lines(start_a, start_a, ...)).
      s = start_a
      e = start_a
    else
      s = start_a - 1
      e = start_a - 1 + count_a
    end
    vim.api.nvim_buf_set_lines(bufnr, s, e, false, repl)
  end

  vim.bo[bufnr].modified = false
  core.events.emit("buffer:reconciled", { bufnr = bufnr })
  return "applied"
end

return M
