-- Selector de BASE de comparación de review: HEAD, index (staged) o un commit.
-- Modal centrado con SECCIONES: special (HEAD/index), "esta rama" (commits
-- propios de la rama actual = base..HEAD) e "historial" (globales, scrolleable;
-- `+` carga más). Los merges se marcan con ⇄. Cada commit muestra hash + nombre.
-- Al elegir, la base se usa en las vistas y se sincroniza gitsigns.
local M = {}

local ns = vim.api.nvim_create_namespace("review_base")
local HIST_STEP = 60

--- Limpia un `info` de commit para usarlo como label del statusline: quita los
--- marcadores multibyte que agregamos (◂ branch-point, ⇄ merge). OJO: los
--- patrones Lua son por BYTE; un char class [◂⇄] parte los multibyte y corrompe
--- el texto (mojibake). Por eso se quitan como literales enteros.
--- @param info string|nil
--- @return string|nil
function M.clean_label(info)
  if not info or info == "" then return nil end
  local s = info:gsub("^◂%s*", ""):gsub("^⇄%s*", "")
  if s == "" then return nil end
  return s
end

-- Rama base para separar "esta rama" del historial: origin/HEAD → main/master…
local function base_branch(root)
  local out = vim.fn.systemlist({ "git", "-C", root, "symbolic-ref", "--quiet", "refs/remotes/origin/HEAD" })
  if vim.v.shell_error == 0 and out[1] and out[1] ~= "" then
    return (out[1]:gsub("^refs/remotes/", ""))
  end
  for _, b in ipairs({ "main", "master", "develop" }) do
    vim.fn.systemlist({ "git", "-C", root, "rev-parse", "--verify", "--quiet", b })
    if vim.v.shell_error == 0 then return b end
  end
  return nil
end

-- Lista de commits {ref, text, info(subject), merge}. `range` opcional (ej.
-- "main..HEAD"); `n` limita cantidad.
local function commits(root, range, n)
  local args = { "git", "-C", root, "log", "--pretty=format:%h%x1f%p%x1f%s", "--no-color" }
  if n then args[#args + 1] = "-n"; args[#args + 1] = tostring(n) end
  if range then args[#args + 1] = range end
  local out = vim.fn.systemlist(args)
  if vim.v.shell_error ~= 0 then return {} end
  local list = {}
  for _, line in ipairs(out) do
    local hash, parents, subject = line:match("^([^\31]*)\31([^\31]*)\31(.*)$")
    if hash and hash ~= "" then
      list[#list + 1] = { ref = hash, text = hash, info = subject or "", merge = parents:find(" ") ~= nil }
    end
  end
  return list
end

-- Construye las opciones según el filtro activo: "branch" (commits propios de la
-- rama actual, base..HEAD) o "global" (historial completo, paginado con `+`).
-- La sección "special" (HEAD/index) va siempre arriba.
local function build_options(core, hist_n, filter)
  local out = {
    { header = "special" },
    { ref = "HEAD", text = "HEAD", info = "último commit" },
    { ref = ":", text = "index", info = "staged" },
  }
  local root = core.git.root(vim.api.nvim_get_current_buf()) or core.git.root()
  if not root then return out end

  if filter == "branch" then
    local bb = base_branch(root)
    local branch = bb and commits(root, bb .. "..HEAD", nil) or {}
    out[#out + 1] = { header = bb and ("this branch (" .. bb .. "..HEAD)") or "this branch" }
    if #branch > 0 then
      for _, c in ipairs(branch) do out[#out + 1] = c end
    else
      out[#out + 1] = { note = "no commits ahead of base branch — press f for global history" }
    end
    -- UN commit extra: el que está JUSTO ANTES de la rama (el padre del primer
    -- commit propio = merge-base con la rama base). Elegirlo como base muestra
    -- TODOS los cambios de la rama, incluido el primer commit (que `base..HEAD`
    -- excluiría). Va separado y etiquetado para saber que no es de tu rama.
    if bb then
      local mb = vim.fn.systemlist({ "git", "-C", root, "merge-base", bb, "HEAD" })
      if vim.v.shell_error == 0 and mb[1] and mb[1] ~= "" then
        local short = mb[1]:sub(1, 9)
        local subj = commits(root, nil, 1) -- fallback subject
        local one = vim.fn.systemlist({ "git", "-C", root, "log", "-1", "--pretty=format:%s", mb[1] })
        local s = (vim.v.shell_error == 0 and one[1]) or (subj[1] and subj[1].info) or ""
        out[#out + 1] = { header = "the commit before your branch" }
        out[#out + 1] = { ref = short, text = short, info = "◂ " .. s }
      end
    end
  else -- "global"
    out[#out + 1] = { header = "global history (last " .. hist_n .. ")" }
    for _, c in ipairs(commits(root, nil, hist_n)) do out[#out + 1] = c end
  end
  return out
end

function M.open(core, hist_n, filter)
  hist_n = hist_n or HIST_STEP
  filter = filter or "branch"
  local options = build_options(core, hist_n, filter)
  local W = 76
  local cur = core.git.base_ref

  local lines = {}
  for i, o in ipairs(options) do
    if o.header then
      lines[i] = "── " .. o.header .. " " .. string.rep("─", math.max(0, W - #o.header - 5))
    elseif o.note then
      lines[i] = "  " .. o.note
    else
      local mark = (o.ref == cur) and "● " or "  "
      local mm = o.merge and "⇄ " or ""
      local info = mm .. (o.info or "")
      if #info > W - 15 then info = info:sub(1, W - 18) .. "…" end
      lines[i] = string.format("%s%-8s %s", mark, o.text, info)
    end
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  for i, o in ipairs(options) do
    if o.header or o.note then
      pcall(vim.api.nvim_buf_set_extmark, buf, ns, i - 1, 0, { end_row = i - 1, hl_group = "ReviewBaseHeader" })
    elseif o.ref == cur then
      pcall(vim.api.nvim_buf_set_extmark, buf, ns, i - 1, 0, { end_row = i - 1, hl_group = "ReviewBaseCurrent" })
    elseif o.merge then
      pcall(vim.api.nvim_buf_set_extmark, buf, ns, i - 1, 0, { end_row = i - 1, hl_group = "ReviewBaseMerge" })
    end
  end
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = "wipe"

  local h = math.min(#lines, math.max(10, math.floor(vim.o.lines * 0.6)))
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = W,
    height = h,
    row = math.max(0, math.floor((vim.o.lines - h) / 2) - 1),
    col = math.max(0, math.floor((vim.o.columns - W) / 2)),
    style = "minimal",
    border = "rounded",
    title = string.format(
      " Comparison base · [%s] · f filter · Enter select%s · q cancel ",
      filter == "branch" and "this branch" or "global",
      filter == "global" and " · + more" or ""
    ),
    title_pos = "center",
  })
  vim.wo[win].cursorline = true
  -- Cursor en la base actual (si es visible en este filtro), o en la primera
  -- opción seleccionable (saltando headers/notas).
  local start
  for i, o in ipairs(options) do
    if o.ref == cur then start = i; break end
  end
  if not start then
    for i, o in ipairs(options) do
      if o.ref then start = i; break end
    end
  end
  pcall(vim.api.nvim_win_set_cursor, win, { start or 1, 0 })

  local function close()
    if vim.api.nvim_win_is_valid(win) then pcall(vim.api.nvim_win_close, win, true) end
  end
  local function pick()
    local o = options[vim.fn.line(".")]
    if not o or o.header or o.note or not o.ref then return end -- ignorar encabezados/notas
    close()
    core.git.set_base(o.ref)
    -- Etiqueta legible para el statusline (subject del commit). Para HEAD/index
    -- no hay subject → nil (el statusline muestra "index" o nada).
    local label = (o.ref ~= "HEAD" and o.ref ~= ":") and M.clean_label(o.info) or nil
    if label == "" then label = nil end
    core.git.base_label = label
    pcall(core.store.save_base, o.ref, label) -- persistir para la próxima sesión
    M.apply_gitsigns(o.ref)
    core.events.emit("base:changed", { ref = o.ref })
    local extra = (o.info ~= "" and o.text ~= o.info) and ("  (" .. o.info .. ")") or ""
    vim.notify("review: comparison base → " .. o.text .. extra, vim.log.levels.INFO)
  end

  local km = { buffer = buf, nowait = true, silent = true }
  vim.keymap.set("n", "<CR>", pick, km)
  vim.keymap.set("n", "q", close, km)
  vim.keymap.set("n", "<Esc>", close, km)
  -- Togglear el filtro this-branch ↔ global (reabre en el otro filtro).
  vim.keymap.set("n", "f", function()
    close()
    M.open(core, HIST_STEP, filter == "branch" and "global" or "branch")
  end, km)
  -- Cargar más historial (solo en global; reabre con +HIST_STEP).
  vim.keymap.set("n", "+", function()
    if filter ~= "global" then return end
    close()
    M.open(core, hist_n + HIST_STEP, "global")
  end, km)
end

--- Apunta gitsigns a la base de review:
---   • commit     → change_base(commit, global)  → diff vs ese commit
---   • HEAD / ":" → change_base(nil, global)      → gitsigns NATIVO (base index)
---
--- Ojo: NO forzamos base="HEAD" en el caso default. Con una base explícita
--- gitsigns diffea los untracked contra ese ref y los pinta como "added" (signo
--- sólido), perdiendo el signo `untracked` punteado (`┆`) que marca archivos
--- nuevos. Dejando el default nativo se conserva ese indicador.
--- @param ref string  la base de review (HEAD | ":" | <commit>)
function M.apply_gitsigns(ref)
  pcall(function()
    local gs = require("gitsigns")
    if not ref or ref == "HEAD" or ref == ":" then
      gs.change_base(nil, true) -- nativo: index; conserva el `┆` de untracked
    else
      gs.change_base(ref, true)
    end
  end)
end

function M.setup(core, opts)
  opts = opts or {}
  local leader = opts.leader or "<leader>r"
  vim.api.nvim_set_hl(0, "ReviewBaseCurrent", { fg = "#eed49f", bold = true, default = true })
  vim.api.nvim_set_hl(0, "ReviewBaseHeader", { fg = "#6e738d", italic = true, default = true })
  vim.api.nvim_set_hl(0, "ReviewBaseMerge", { fg = "#c6a0f6", default = true })
  vim.api.nvim_create_user_command("ReviewBase", function() M.open(core) end, {})
  vim.api.nvim_create_user_command("Rb", function() M.open(core) end, {})
  vim.keymap.set("n", leader .. "b", function() M.open(core) end, { desc = "Review: select comparison base" })

  -- Restaurar la base persistida de la sesión anterior (por repo). Se hace en
  -- VeryLazy para que gitsigns/neo-tree ya estén disponibles, y solo si NO es
  -- HEAD (el default no necesita restaurarse).
  local function restore()
    local ok, ref, label = pcall(core.store.load_base)
    if not ok or not ref or ref == "HEAD" then return end
    -- Validar que el ref siga existiendo (evita bases rotas por rebase/gc).
    if ref ~= ":" then
      local root = core.git.root() or core.store.root_fn()
      if root then
        vim.fn.systemlist({ "git", "-C", root, "rev-parse", "--verify", "--quiet", ref .. "^{commit}" })
        if vim.v.shell_error ~= 0 then return end
      end
    end
    core.git.set_base(ref)
    core.git.base_label = label -- recuperar la etiqueta para el statusline
    -- NO emitimos "base:changed" en el arranque: sería una cascada (views +
    -- scrollbar + refresh del sidebar). El modo de vista arranca en "normal" (sin
    -- diff), y scrollbar/sidebar leen la base perezosamente al renderizar. Solo
    -- alineamos gitsigns (que sí necesita el change_base explícito).
    M.apply_gitsigns(ref)
  end
  vim.api.nvim_create_autocmd("User", { pattern = "VeryLazy", once = true, callback = function() vim.schedule(restore) end })
end

require("review.core").registry.register({ name = "base", setup = M.setup })

return M
