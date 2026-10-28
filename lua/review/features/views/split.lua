-- Vista SPLIT global (2 columnas), estilo VSCode, usando el MODO DIFF NATIVO.
-- Hay UNA sola sesión de split: un panel HEAD a la izquierda (scratch readonly,
-- con `winfixbuf` para que NO se le puedan abrir archivos) y la ventana real de
-- edición a la derecha. Al cambiar de archivo en la ventana real, el panel HEAD
-- se actualiza al HEAD de ese archivo (o se cierra si el archivo no tiene HEAD).
local diff = require("review.features.views.diff")

local M = {}
M._session = nil -- { left_win, buf = <scratch>, main_win }

-- ── Alineación con WRAP ("padding virtual") ────────────────────────────────
-- El modo diff nativo alinea por NÚMERO DE LÍNEA (+filler para altas/bajas),
-- pero NO por filas de PANTALLA: una línea larga envuelve en más filas de un
-- lado que del otro → todo lo de abajo se desincroniza. Solución: para cada
-- bloque de diff, calculamos cuántas filas de pantalla ocupa a cada lado (alto
-- de wrap + filler nativo) y rellenamos el lado más corto con líneas VIRTUALES
-- (extmarks virt_lines) para que ambos bloques midan lo mismo. Así el contexto
-- que sigue vuelve a quedar alineado fila-a-fila. Se recalcula al entrar a
-- split, al editar y al cambiar el ancho (sidebar, resize).
local PAD_NS = vim.api.nvim_create_namespace("review_split_pad")

-- Columnas de TEXTO reales de una ventana (ancho menos number/sign/fold).
local function text_width(win)
  local info = vim.fn.getwininfo(win)[1]
  if not info then return 80 end
  return math.max(1, info.width - (info.textoff or 0))
end

-- Filas de pantalla que ocupa `text` envuelto en `tw` columnas.
local function wrap_rows(text, tw)
  local w = vim.fn.strdisplaywidth(text)
  if w <= 0 then return 1 end
  return math.max(1, math.ceil(w / tw))
end

local function clear_pad(buf)
  if buf and vim.api.nvim_buf_is_valid(buf) then
    vim.api.nvim_buf_clear_namespace(buf, PAD_NS, 0, -1)
  end
end

-- Añade `n` filas virtuales DEBAJO de la línea `lnum0` (0-based) de `buf`.
local function add_pad(buf, lnum0, n)
  if n <= 0 or not (buf and vim.api.nvim_buf_is_valid(buf)) then return end
  local last = vim.api.nvim_buf_line_count(buf) - 1
  if lnum0 < 0 then lnum0 = 0 elseif lnum0 > last then lnum0 = last end
  local vl = {}
  for _ = 1, n do vl[#vl + 1] = { { "", "ReviewDiffFiller" } } end
  pcall(vim.api.nvim_buf_set_extmark, buf, PAD_NS, lnum0, 0, { virt_lines = vl })
end

--- Recalcula el padding virtual de la sesión de split actual (idempotente).
function M.repad()
  local s = M._session
  if not s then return end
  local lw, rw = s.left_win, s.main_win
  if not (lw and rw and vim.api.nvim_win_is_valid(lw) and vim.api.nvim_win_is_valid(rw)) then return end
  local lbuf = s.buf
  local rbuf = vim.api.nvim_win_get_buf(rw)
  if not (vim.api.nvim_buf_is_valid(lbuf) and vim.api.nvim_buf_is_valid(rbuf)) then return end
  clear_pad(lbuf)
  clear_pad(rbuf)
  -- Sin wrap el padding no aplica (las líneas largas no envuelven): solo limpiar.
  if not (vim.wo[lw].wrap and vim.wo[rw].wrap) then return end

  local head = s.head or {}
  local edit = vim.api.nvim_buf_get_lines(rbuf, 0, -1, false)
  local twl, twr = text_width(lw), text_width(rw)

  local a = table.concat(head, "\n") .. "\n"
  local b = table.concat(edit, "\n") .. "\n"
  local ok, hunks = pcall(vim.text.diff or vim.diff, a, b, { result_type = "indices", algorithm = "histogram" })
  if not ok or type(hunks) ~= "table" then return end

  for _, h in ipairs(hunks) do
    local sa, ca, sb, cb = h[1], h[2], h[3], h[4]
    -- Filas de pantalla del bloque a cada lado (wrap real + filler nativo, que
    -- expande ambos lados a max(ca,cb) líneas de buffer, 1 fila por filler).
    local rowsL, rowsR = 0, 0
    for i = sa, sa + ca - 1 do rowsL = rowsL + wrap_rows(head[i] or "", twl) end
    for i = sb, sb + cb - 1 do rowsR = rowsR + wrap_rows(edit[i] or "", twr) end
    rowsL = rowsL + math.max(0, cb - ca) -- filler nativo en la IZQUIERDA
    rowsR = rowsR + math.max(0, ca - cb) -- filler nativo en la DERECHA
    local delta = rowsL - rowsR
    if delta > 0 then -- la derecha es más corta → rellenar derecha al final del bloque
      local anchor = (cb > 0) and (sb + cb - 2) or (sb - 1) -- 0-based, debajo de la última línea del bloque
      add_pad(rbuf, anchor, delta)
    elseif delta < 0 then
      local anchor = (ca > 0) and (sa + ca - 2) or (sa - 1)
      add_pad(lbuf, anchor, -delta)
    end
  end
end

-- Alinea línea-a-línea estilo VSCode (linematch/histogram), preservando flags.
local function ensure_diffopt()
  local parts = vim.split(vim.o.diffopt, ",", { trimempty = true })
  local has = {}
  for _, p in ipairs(parts) do has[p:match("^([%w%-]+)") or p] = true end
  local add = {}
  if not has["internal"] then add[#add + 1] = "internal" end
  if not has["filler"] then add[#add + 1] = "filler" end
  if not has["linematch"] then add[#add + 1] = "linematch:60" end
  if not has["algorithm"] then add[#add + 1] = "algorithm:histogram" end
  if not has["indent-heuristic"] then add[#add + 1] = "indent-heuristic" end
  if not has["inline"] then add[#add + 1] = "inline:char" end -- resaltar el texto exacto que cambió
  if #add > 0 then vim.o.diffopt = vim.o.diffopt .. "," .. table.concat(add, ",") end
end

-- ¿Dos listas de líneas son idénticas?
local function same_lines(a, b)
  if #a ~= #b then return false end
  for i = 1, #a do
    if a[i] ~= b[i] then return false end
  end
  return true
end

--- ¿Es `bufnr` el scratch del panel HEAD?
function M.is_scratch(bufnr)
  return M._session ~= nil and M._session.buf == bufnr
end

--- Ventana de EDICIÓN de la sesión de split (la real, no el panel HEAD), o nil.
function M.main_win()
  local s = M._session
  if s and s.main_win and vim.api.nvim_win_is_valid(s.main_win) then return s.main_win end
end

-- Fuerza TODAS las líneas visibles (sin folds de diff que compactan lo que no
-- cambió) + relleno diagonal, en una ventana en modo diff.
local function open_all_folds(win)
  if win and vim.api.nvim_win_is_valid(win) then
    -- `[0]` = local a la ventana (`:setlocal`): sin él también cambia el valor
    -- global y todas las ventanas nuevas heredan estos folds.
    pcall(function()
      vim.wo[win][0].foldenable = false
      vim.wo[win][0].foldlevel = 99
      vim.wo[win][0].fillchars = "diff:╱"
    end)
  end
end

-- Apaga el diff de la ventana `w` (para el buffer que muestra AHORA) y le
-- devuelve las opciones de fold/fillchars/resaltado guardadas al armar el par.
local function diffoff_restore(w, sv)
  pcall(vim.api.nvim_win_call, w, function() vim.cmd("diffoff") end)
  pcall(function()
    sv = sv or {}
    local wl = vim.wo[w][0]
    if sv.fe == nil then wl.foldenable = true else wl.foldenable = sv.fe end
    wl.foldlevel = sv.fl or 99
    wl.foldmethod = sv.fm or "manual"
    wl.fillchars = sv.fc or ""
    wl.winhighlight = sv.wh or ""
  end)
end

-- Diffs que quedaron puestos en un buffer que ya no se muestra en su ventana:
-- [win][buf] = opciones guardadas. 'diff' y las opciones de ventana se guardan
-- POR BUFFER: si el par se desarma porque la ventana pasó a mostrar otro
-- archivo, el `diffoff` apaga el diff del archivo nuevo, y el del anterior
-- vuelve encendido cuando ese archivo regresa a la ventana. Solo se anotan los
-- diffs que puso el split, para no tocar un `:diffthis` del usuario.
M._stale = {}

--- Si `buf` vuelve a `win` con un diff que dejó el split, lo apaga.
function M.clear_stale(win, buf)
  local per_win = M._stale[win]
  local sv = per_win and per_win[buf]
  if not sv then return end
  per_win[buf] = nil
  if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == buf then
    diffoff_restore(win, sv)
  end
end

--- Olvida lo anotado para una ventana que se cerró.
function M.forget_win(win) M._stale[win] = nil end

-- Saca el diff de la ventana real y restaura sus opciones de fold/fillchars.
local function restore_main(s)
  local w = s.main_win
  if not (w and vim.api.nvim_win_is_valid(w)) then return end
  -- Limpiar el padding virtual del buffer REAL (el scratch se wipea solo, pero
  -- el archivo verdadero conserva sus extmarks si no los borramos acá).
  local cur = vim.api.nvim_win_get_buf(w)
  clear_pad(cur)
  if s.main_buf and s.main_buf ~= cur then
    -- La ventana ya muestra otro archivo: el diff del archivo del par sigue
    -- guardado en esta ventana. Se apaga cuando ese archivo vuelva (clear_stale).
    if vim.api.nvim_buf_is_valid(s.main_buf) then clear_pad(s.main_buf) end
    M._stale[w] = M._stale[w] or {}
    M._stale[w][s.main_buf] = s.saved or {}
  end
  diffoff_restore(w, s.saved)
end

--- Cierra la columna HEAD sin que Neovim recalcule el diff EN MEDIO del cierre.
--- `:diffoff` deja el diff de la pestaña invalidado, y al cerrar una ventana
--- Neovim redimensiona la vecina, ve el diff invalidado y corre :diffupdate,
--- que dispara DiffUpdated mientras la lista de ventanas está a medio cambiar.
--- Un callback que consulta ventanas ahí (render-markdown llama a win_findbuf)
--- hacía caer a Neovim con SIGSEGV. Por eso: diff apagado también en esta
--- ventana, recálculo en un momento seguro, y DiffUpdated ignorado solo
--- durante el cierre. Ver docs/decisions.md (B19).
local function close_head_win(win)
  if not (win and vim.api.nvim_win_is_valid(win)) then return end
  pcall(vim.api.nvim_win_call, win, function() vim.cmd("diffoff") end)
  pcall(vim.cmd, "diffupdate")
  local ei = vim.go.eventignore
  vim.go.eventignore = (ei == "") and "DiffUpdated" or (ei .. ",DiffUpdated")
  pcall(vim.api.nvim_win_close, win, true) -- scratch: bufhidden=wipe
  vim.go.eventignore = ei
end

-- Guardia para un cierre que NO hace este plugin (`:q` del usuario sobre una
-- ventana en modo diff): Neovim invalida el diff al cerrarla y corre
-- :diffupdate en medio del cierre (mismo SIGSEGV que close_head_win). Se llama
-- desde WinClosed, que corre antes de sacar la ventana del layout; DiffUpdated
-- queda ignorado hasta el próximo tick y después se recalcula normal. Al
-- restaurar se saca solo la entrada propia de 'eventignore'.
local guarding = false
function M.guard_diff_close()
  if guarding then return end
  guarding = true
  local ei = vim.go.eventignore
  vim.go.eventignore = (ei == "") and "DiffUpdated" or (ei .. ",DiffUpdated")
  vim.schedule(function()
    local parts = vim.split(vim.go.eventignore, ",", { trimempty = true })
    for i, p in ipairs(parts) do
      if p == "DiffUpdated" then table.remove(parts, i); break end
    end
    vim.go.eventignore = table.concat(parts, ",")
    guarding = false
  end)
end

--- Cierra la sesión de split (saca el diff de la ventana real y cierra el HEAD).
function M.teardown()
  local s = M._session
  M._session = nil
  if not s then return end
  restore_main(s)
  close_head_win(s.left_win)
end

-- Crea el panel HEAD (izquierda) para la ventana `main_win`.
local function create_pane(main_win)
  -- Guardar opciones de fold/fillchars de la ventana real para restaurarlas.
  local saved = {
    fe = vim.wo[main_win].foldenable,
    fl = vim.wo[main_win].foldlevel,
    fm = vim.wo[main_win].foldmethod,
    fc = vim.wo[main_win].fillchars,
    wh = vim.wo[main_win].winhighlight,
  }
  vim.api.nvim_set_current_win(main_win)
  vim.cmd("leftabove vsplit")
  local left_win = vim.api.nvim_get_current_win()
  local scratch = vim.api.nvim_create_buf(false, true)
  vim.bo[scratch].buftype = "nofile"
  vim.bo[scratch].bufhidden = "wipe"
  vim.api.nvim_win_set_buf(left_win, scratch)
  pcall(function() vim.wo[left_win][0].winfixbuf = true end) -- no abrir archivos acá
  return { left_win = left_win, buf = scratch, main_win = main_win, saved = saved }
end

--- Maneja el cierre manual de una de las ventanas del split: si se cierra el
--- panel HEAD o la ventana de edición, saca el diff de la que quede y limpia la
--- sesión (así no queda una columna pegada en modo diff). Los cierres que hace
--- el propio plugin (teardown) no llegan acá: sueltan la sesión antes de cerrar.
--- @return boolean true si la ventana cerrada era del par
function M.on_win_closed(win)
  local s = M._session
  if not s then return false end
  if win ~= s.left_win and win ~= s.main_win then return false end
  M._session = nil
  local is_left = (win == s.left_win)
  -- Diferir: no se pueden cerrar/modificar ventanas DENTRO del autocmd WinClosed
  -- (Neovim aborta con E855). Lo hacemos en el próximo tick.
  vim.schedule(function()
    if is_left then
      restore_main(s)
    else
      close_head_win(s.left_win)
    end
  end)
  return true
end

--- Sincroniza el panel HEAD con el archivo de la ventana ACTUAL (la de edición).
--- Crea la sesión si hace falta; la cierra si el archivo no tiene HEAD o no está
--- en el repo (queda en una sola columna).
local WH_DEL = "DiffChange:ReviewDiffChange,DiffText:ReviewDiffDelText,DiffAdd:ReviewDiffDelLine,DiffDelete:ReviewDiffFiller"
local WH_ADD = "DiffChange:ReviewDiffChange,DiffText:ReviewDiffAddText,DiffAdd:ReviewDiffAddLine,DiffDelete:ReviewDiffFiller"

function M.sync(core)
  local cur = vim.api.nvim_get_current_win()
  local s = M._session
  if s and cur == s.left_win then return end -- no actuar desde el panel HEAD

  local buf = vim.api.nvim_win_get_buf(cur)
  if vim.bo[buf].buftype ~= "" then return end -- ventana especial

  local rel = core.git.rel_path(buf)
  if not rel then M.teardown(); return end

  -- REUSO del MISMO archivo: ya está diffeado. NO re-diffear (el diff nativo se
  -- actualiza solo al editar; re-diffear sobre las mismas ventanas lo corrompe
  -- —marca todo como cambiado— y además es lento). Solo cerramos si el archivo
  -- volvió a quedar idéntico a HEAD. Barato: sin git, sin re-diff.
  if s and s.rel == rel and s.head
      and s.left_win and vim.api.nvim_win_is_valid(s.left_win)
      and s.main_win and vim.api.nvim_win_is_valid(s.main_win) then
    -- Barato: si el buffer no cambió desde el último sync, no hacer nada.
    local tick = vim.api.nvim_buf_get_changedtick(buf)
    if tick ~= s.tick then
      s.tick = tick
      if same_lines(s.head, vim.api.nvim_buf_get_lines(buf, 0, -1, false)) then
        M.teardown()
      end
    end
    return
  end

  -- Archivo nuevo o sin sesión válida: preparar setup FRESCO.
  local head = core.git.head_content(rel, core.git.root(buf))
  if not head then M.teardown(); return end -- sin HEAD (archivo nuevo): una columna
  if same_lines(head, vim.api.nvim_buf_get_lines(buf, 0, -1, false)) then
    M.teardown(); return -- sin cambios: una columna
  end

  M.teardown() -- cerrar sesión previa (de otro archivo) si la hubiera
  ensure_diffopt()

  local sess = create_pane(cur)
  sess.rel = rel
  sess.head = head
  sess.tick = vim.api.nvim_buf_get_changedtick(buf)
  sess.main_buf = buf -- el archivo del par (la ventana puede pasar a mostrar otro)
  M._session = sess

  -- Scratch = contenido HEAD.
  local scratch = sess.buf
  vim.bo[scratch].modifiable = true
  vim.api.nvim_buf_set_lines(scratch, 0, -1, false, head)
  vim.bo[scratch].modifiable = false
  vim.bo[scratch].readonly = true
  local ft = vim.bo[buf].filetype
  if ft and ft ~= "" then vim.bo[scratch].filetype = ft end
  pcall(vim.api.nvim_buf_set_name, scratch, "review://head/" .. rel)
  pcall(vim.treesitter.start, scratch) -- mismo resaltado que la derecha

  -- Diff nativo (scratch fresco). diffoff! limpia CUALQUIER estado de diff
  -- residual del tab (si no, tras un switch el diff desalinea y marca todo).
  pcall(vim.api.nvim_win_call, cur, function() vim.cmd("diffoff!") end)
  pcall(vim.api.nvim_win_call, sess.left_win, function() vim.cmd("diffthis") end)
  pcall(vim.api.nvim_win_call, cur, function() vim.cmd("diffthis") end)
  open_all_folds(sess.left_win)
  open_all_folds(cur)
  -- El modo diff apaga `wrap`. Respetar la preferencia del usuario (<leader>w);
  -- por defecto wrapeado.
  local wrap = vim.g.review_wrap ~= false
  pcall(function() vim.wo[sess.left_win][0].wrap = wrap end)
  pcall(function() vim.wo[cur][0].wrap = wrap end)
  pcall(function() vim.wo[sess.left_win][0].winhighlight = WH_DEL end)
  pcall(function() vim.wo[cur][0].winhighlight = WH_ADD end)
  vim.api.nvim_set_current_win(cur)
  pcall(vim.cmd, "diffupdate")
  -- Alinear filas de pantalla (wrap) con padding virtual. Diferido: las alturas
  -- de wrap dependen del ancho ya asentado de las ventanas.
  if wrap then vim.schedule(M.repad) end
end

return M
