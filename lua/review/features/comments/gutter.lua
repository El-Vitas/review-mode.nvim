-- Gutter con corchetes ANIDADOS: reemplaza el statuscolumn de las ventanas que
-- muestran archivos del repo para dibujar, línea por línea, un corchete por CADA
-- comentario que la cubre — apilados según anidación y coloreados por comentario
-- (┌ arriba, │ medio, └ abajo, ▌ una línea). Preserva signos (gitsigns) y número.
--
-- La columna de signos solo admite 1 signo por línea, por eso el anidado y la
-- continuidad del │ (cuando hay comentarios solapados) solo se logran así.
local M = {}

local PALETTE_N = 6

M._core = nil
M._prev = {}   -- win -> statuscolumn previo (para restaurar)
M._gen = 0     -- generación; sube al cambiar comentarios (invalida cache)
M._cache = {}  -- buf -> { gen, color = {id->idx}, ranked = comment[] }

-- Ranking estable por línea (para asignar color) + mapa id->color. Cacheado por
-- (buf, generación).
local function ranked_for(buf)
  local cached = M._cache[buf]
  if cached and cached.gen == M._gen then return cached end

  local core = M._core
  local rel = core and core.git.rel_path(buf)
  local ranked, color = {}, {}
  if rel then
    for _, c in ipairs(core.state.for_path(rel)) do ranked[#ranked + 1] = c end
    table.sort(ranked, function(a, b) return (a.lnum or 0) < (b.lnum or 0) end)
    for i, c in ipairs(ranked) do color[c.id] = ((i - 1) % PALETTE_N) + 1 end
  end
  local entry = { gen = M._gen, ranked = ranked, color = color }
  M._cache[buf] = entry
  return entry
end

--- String de statusline con los corchetes de la línea `lnum` del buffer `buf`.
function M.brackets(buf, lnum)
  local entry = ranked_for(buf)
  if #entry.ranked == 0 then return "" end

  -- Comentarios que cubren la línea, ordenados outer-first (lo asc, span desc)
  -- para que el anidado quede de afuera hacia adentro (izq -> der).
  local cov = {}
  for _, c in ipairs(entry.ranked) do
    local lo = math.min(c.lnum, c.end_lnum or c.lnum)
    local hi = math.max(c.lnum, c.end_lnum or c.lnum)
    if lnum >= lo and lnum <= hi then
      cov[#cov + 1] = { c = c, lo = lo, hi = hi }
    end
  end
  if #cov == 0 then return "" end
  table.sort(cov, function(a, b)
    if a.lo ~= b.lo then return a.lo < b.lo end
    return (a.hi - a.lo) > (b.hi - b.lo)
  end)

  local parts = {}
  for _, e in ipairs(cov) do
    local ch
    if e.lo == e.hi then
      ch = "▌"
    elseif lnum == e.lo then
      ch = "┌"
    elseif lnum == e.hi then
      ch = "└"
    else
      ch = "│"
    end
    local hl = e.c.resolved and "ReviewCommentSignResolved" or ("ReviewCommentSign" .. entry.color[e.c.id])
    parts[#parts + 1] = "%#" .. hl .. "#" .. ch
  end
  return table.concat(parts) .. "%*"
end

--- statuscolumn: fold + signos (gitsigns) + corchetes + número (derecha).
function M.render()
  local win = vim.g.statusline_winid
  local ok, buf = pcall(vim.api.nvim_win_get_buf, win)
  if not ok then return "" end

  local brackets = M.brackets(buf, vim.v.lnum)

  local numcol = ""
  local wo = vim.wo[win]
  if wo.number or wo.relativenumber then
    local n = vim.v.lnum
    if wo.relativenumber and vim.v.relnum ~= 0 then n = vim.v.relnum end
    numcol = tostring(n)
  end

  return "%C%s" .. brackets .. " %=" .. numcol .. " "
end

_G.ReviewStatusCol = M.render

local function enable(win)
  if not vim.api.nvim_win_is_valid(win) then return end
  if M._prev[win] == nil then M._prev[win] = vim.wo[win].statuscolumn end
  vim.wo[win].statuscolumn = "%!v:lua.ReviewStatusCol()"
end

local function disable(win)
  if M._prev[win] ~= nil and vim.api.nvim_win_is_valid(win) then
    vim.wo[win].statuscolumn = M._prev[win]
    M._prev[win] = nil
  end
end

function M.setup(core)
  M._core = core

  local grp = vim.api.nvim_create_augroup("ReviewGutter", { clear = true })
  -- Activa el gutter propio en ventanas que muestran archivos del repo; lo
  -- restaura en las demás (neo-tree, terminales, etc.).
  vim.api.nvim_create_autocmd({ "BufWinEnter", "BufEnter", "WinEnter" }, {
    group = grp,
    callback = function(a)
      local win = vim.api.nvim_get_current_win()
      if core.git.rel_path(a.buf) then
        enable(win)
      else
        disable(win)
      end
    end,
  })

  -- Al cambiar comentarios, invalidar cache y redibujar.
  if core.events then
    core.events.on("comments:changed", function()
      M._gen = M._gen + 1
      M._cache = {}
      vim.schedule(function() pcall(vim.cmd, "redrawstatus!") end)
    end)
  end
end

return M
