local M = {}

-- Parsea el header de un hunk unificado: @@ -old_start[,old_count] +new_start[,new_count] @@
local function parse_hunk_header(line)
  local old_start, old_count, new_start, new_count =
    line:match("^@@ %-(%d+),?(%d*) %+(%d+),?(%d*) @@")
  if not old_start then return nil end
  old_count = old_count ~= "" and tonumber(old_count) or 1
  new_count = new_count ~= "" and tonumber(new_count) or 1
  return {
    old_start = tonumber(old_start),
    old_count = old_count,
    new_start = tonumber(new_start),
    new_count = new_count,
    del_lines = {},
    add_lines = {},
    add_lnums = {},
  }
end

--- Parsea el texto completo de `git diff -U0` en una lista de hunks.
--- Ignora las líneas de header del diff (diff --git / index / --- / +++).
function M.parse_unified_diff(text)
  local hunks = {}
  if not text or text == "" then return hunks end

  local current = nil
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    if line:match("^@@ ") then
      current = parse_hunk_header(line)
      if current then table.insert(hunks, current) end
    elseif current then
      if line:sub(1, 1) == "-" and line:sub(1, 3) ~= "---" then
        table.insert(current.del_lines, line:sub(2))
      elseif line:sub(1, 1) == "+" and line:sub(1, 3) ~= "+++" then
        table.insert(current.add_lines, line:sub(2))
        table.insert(current.add_lnums, current.new_start + #current.add_lnums)
      end
      -- otras líneas (---, +++, \ No newline at end of file) se ignoran
    end
  end

  return hunks
end

--- Corre `git diff -U0 -- relpath` en git_root y devuelve los hunks parseados.
--- nil si no hay git_root o el comando falla.
function M.hunks_for(relpath, git_root)
  if not git_root then return nil end
  local out = vim.fn.system({ "git", "-C", git_root, "diff", "-U0", "--", relpath })
  if vim.v.shell_error ~= 0 then return nil end
  return M.parse_unified_diff(out)
end

return M
