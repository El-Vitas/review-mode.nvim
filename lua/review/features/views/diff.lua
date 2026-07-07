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

--- Diff EN MEMORIA entre el contenido HEAD y el contenido actual del buffer
--- (usando `vim.diff`, sin subprocess ni tocar el disco). A diferencia de
--- `hunks_for` (que compara HEAD vs archivo en disco), esto refleja los cambios
--- SIN GUARDAR, así las vistas se actualizan mientras editás. Devuelve la misma
--- forma de hunk que `parse_unified_diff`.
--- @param head_lines string[]|nil líneas de la versión HEAD
--- @param buf_lines string[] líneas actuales del buffer
--- @return table[] hunks
function M.hunks_between(head_lines, buf_lines)
  local out = {}
  if not head_lines then return out end
  local a = table.concat(head_lines, "\n")
  local b = table.concat(buf_lines, "\n")
  if #head_lines > 0 then a = a .. "\n" end
  if #buf_lines > 0 then b = b .. "\n" end

  local ok, res = pcall(vim.diff, a, b, { result_type = "indices", algorithm = "histogram" })
  if not ok or type(res) ~= "table" then return out end

  for _, h in ipairs(res) do
    local sa, ca, sb, cb = h[1], h[2], h[3], h[4]
    local del, add, add_lnums = {}, {}, {}
    for i = 0, ca - 1 do del[#del + 1] = head_lines[sa + i] or "" end
    for i = 0, cb - 1 do
      add[#add + 1] = buf_lines[sb + i] or ""
      add_lnums[#add_lnums + 1] = sb + i
    end
    -- Cuando count==0, `vim.diff` da el índice de la línea previa; para el
    -- render (anclaje de borrados) queremos la primera línea nueva del hunk,
    -- así que normalizamos new_start a sb+1 en las inserciones/borrados puros.
    local new_start = cb > 0 and sb or (sb + 1)
    out[#out + 1] = {
      old_start = ca > 0 and sa or (sa + 1),
      old_count = ca,
      new_start = new_start,
      new_count = cb,
      del_lines = del,
      add_lines = add,
      add_lnums = add_lnums,
    }
  end
  return out
end

return M
