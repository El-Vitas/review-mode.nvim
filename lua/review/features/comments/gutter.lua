-- Gutter con corchetes ANIDADOS: reemplaza el statuscolumn de las ventanas que
-- muestran archivos del repo para dibujar, línea por línea, un corchete por CADA
-- comentario que la cubre — apilados según anidación y coloreados por comentario
-- (┌ arriba, │ medio, └ abajo, ▌ una línea). Preserva signos (gitsigns) y número.
--
-- La columna de signos solo admite 1 signo por línea, por eso el anidado y la
-- continuidad del │ (cuando hay comentarios solapados) solo se logran así.
local render = require("review.features.comments.render")

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
    -- Las respuestas (reply_to) no dibujan corchete propio: viven en el hilo.
    for _, c in ipairs(core.state.for_path(rel)) do
      if not c.reply_to then ranked[#ranked + 1] = c end
    end
    table.sort(ranked, function(a, b) return (a.lnum or 0) < (b.lnum or 0) end)
    for i, c in ipairs(ranked) do color[c.id] = ((i - 1) % PALETTE_N) + 1 end
  end
  local entry = { gen = M._gen, ranked = ranked, color = color }
  M._cache[buf] = entry
  return entry
end

--- String de statusline con los corchetes de la línea `lnum` del buffer `buf`.
--- `cont`=true fuerza el trazo de continuación `│` (para líneas envueltas/wrap),
--- para que el corchete quede CONTINUO y no repita `┌`/`└` en cada wrap.
function M.brackets(buf, lnum, cont)
  if render.hidden then return "" end -- respetar el toggle ocultar/mostrar
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
    if cont then
      ch = "│" -- líneas envueltas: trazo continuo, sin esquinas
    elseif e.lo == e.hi then
      ch = "▌"
    elseif lnum == e.lo then
      ch = "┌"
    elseif lnum == e.hi then
      ch = "└"
    else
      ch = "│"
    end
    local hl
    if e.c.resolved then
      hl = "ReviewCommentSignResolved"
    elseif e.c.author and e.c.author ~= "user" then
      hl = "ReviewCommentSignAgent"
    else
      hl = "ReviewCommentSign" .. entry.color[e.c.id]
    end
    parts[#parts + 1] = "%#" .. hl .. "#" .. ch
  end
  return table.concat(parts) .. "%*"
end

--- statuscolumn: fold + signos (gitsigns) + corchetes + número (derecha).
function M.render()
  local win = vim.g.statusline_winid
  local ok, buf = pcall(vim.api.nvim_win_get_buf, win)
  if not ok then return "" end

  -- v:virtnum: 0 = línea real; >0 = parte envuelta (wrap); <0 = línea virtual
  -- (nuestro badge/peek). En líneas virtuales NO dibujamos corchete (evita los
  -- fragmentos `┌`/`│` rotos sobre el badge/peek); en wraps, trazo continuo.
  local virt = vim.v.virtnum
  local brackets
  if virt < 0 then
    brackets = ""
  elseif virt > 0 then
    brackets = M.brackets(buf, vim.v.lnum, true)
  else
    brackets = M.brackets(buf, vim.v.lnum)
  end

  local numcol = ""
  if virt == 0 then
    local wo = vim.wo[win]
    if wo.number or wo.relativenumber then
      local n = vim.v.lnum
      if wo.relativenumber and vim.v.relnum ~= 0 then n = vim.v.relnum end
      numcol = tostring(n)
    end
  end

  return "%C%s" .. brackets .. " %=" .. numcol .. " "
end

_G.ReviewStatusCol = M.render

local OURS = "%!v:lua.ReviewStatusCol()"

local function enable(win)
  if not vim.api.nvim_win_is_valid(win) then return end
  if vim.wo[win].statuscolumn == OURS then return end -- ya activo (no guardar el nuestro como prev)
  if M._prev[win] == nil then M._prev[win] = vim.wo[win].statuscolumn end
  vim.wo[win].statuscolumn = OURS
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
  -- Activa el gutter propio SOLO en ventanas con archivos normales del repo.
  -- Los buffers especiales (neo-tree, terminal, quickfix, prompts…) se ignoran
  -- por completo: no se les toca el statuscolumn ni se corre git, para no
  -- interferir con esos plugins (p. ej. el toggle de neo-tree).
  vim.api.nvim_create_autocmd({ "BufWinEnter", "WinEnter" }, {
    group = grp,
    callback = function(a)
      local buf = a.buf
      local win = vim.api.nvim_get_current_win()
      local isfile = false
      if vim.bo[buf].buftype == "" then -- solo archivos reales (no neo-tree/term/qf)
        local ok, rel = pcall(core.git.rel_path, buf)
        isfile = ok and rel ~= nil
      end
      if isfile then
        pcall(enable, win)
      else
        pcall(disable, win)
        -- Los splits heredan window-locals: si esta ventana especial (neo-tree,
        -- etc.) quedó con NUESTRO statuscolumn heredado, limpiarlo para no
        -- correr nuestra función ahí ni interferir con ese plugin.
        if vim.api.nvim_win_is_valid(win) and vim.wo[win].statuscolumn == OURS then
          vim.wo[win].statuscolumn = ""
        end
      end
    end,
  })

  -- Liberar entradas de cache/estado al cerrar buffers/ventanas (evita que
  -- crezcan con cada archivo/split abierto).
  vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
    group = grp,
    callback = function(a) M._cache[a.buf] = nil end,
  })
  vim.api.nvim_create_autocmd("WinClosed", {
    group = grp,
    callback = function(a)
      local win = tonumber(a.match)
      if win then M._prev[win] = nil end
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
