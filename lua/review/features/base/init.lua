-- Selector de BASE de comparación de review: HEAD, index (staged) o un commit.
-- Modal centrado con SECCIONES: special (HEAD/index), "esta rama" (commits
-- propios de la rama actual = base..HEAD) e "historial" (globales, scrolleable;
-- `+` carga más). Los merges se marcan con ⇄. Cada commit muestra hash + nombre.
-- Al elegir, la base se usa en las vistas y se sincroniza gitsigns.
local M = {}

local ns = vim.api.nvim_create_namespace("review_base")
local HIST_STEP = 60

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

local function build_options(core, hist_n)
  local out = {
    { header = "special" },
    { ref = "HEAD", text = "HEAD", info = "último commit" },
    { ref = ":", text = "index", info = "staged" },
  }
  local root = core.git.root(vim.api.nvim_get_current_buf()) or core.git.root()
  if root then
    local bb = base_branch(root)
    if bb then
      local branch = commits(root, bb .. "..HEAD", nil)
      if #branch > 0 then
        out[#out + 1] = { header = "esta rama (" .. bb .. "..HEAD)" }
        for _, c in ipairs(branch) do out[#out + 1] = c end
      end
    end
    out[#out + 1] = { header = "historial (últimos " .. hist_n .. ")" }
    for _, c in ipairs(commits(root, nil, hist_n)) do out[#out + 1] = c end
  end
  return out
end

function M.open(core, hist_n)
  hist_n = hist_n or HIST_STEP
  local options = build_options(core, hist_n)
  local W = 76
  local cur = core.git.base_ref

  local lines = {}
  for i, o in ipairs(options) do
    if o.header then
      lines[i] = "── " .. o.header .. " " .. string.rep("─", math.max(0, W - #o.header - 5))
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
    if o.header then
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
    title = " Comparison base · Enter select · + more · q cancel ",
    title_pos = "center",
  })
  vim.wo[win].cursorline = true
  -- Cursor en la base actual, o en la primera opción seleccionable.
  local start = 2
  for i, o in ipairs(options) do
    if o.ref == cur then start = i; break end
  end
  pcall(vim.api.nvim_win_set_cursor, win, { start, 0 })

  local function close()
    if vim.api.nvim_win_is_valid(win) then pcall(vim.api.nvim_win_close, win, true) end
  end
  local function pick()
    local o = options[vim.fn.line(".")]
    if not o or o.header then return end -- ignorar encabezados
    close()
    core.git.set_base(o.ref)
    pcall(function()
      local gs = require("gitsigns")
      if o.ref == ":" then gs.change_base(nil, true) else gs.change_base(o.ref, true) end
    end)
    core.events.emit("base:changed", { ref = o.ref })
    local extra = (o.info ~= "" and o.text ~= o.info) and ("  (" .. o.info .. ")") or ""
    vim.notify("review: comparison base → " .. o.text .. extra, vim.log.levels.INFO)
  end

  local km = { buffer = buf, nowait = true, silent = true }
  vim.keymap.set("n", "<CR>", pick, km)
  vim.keymap.set("n", "q", close, km)
  vim.keymap.set("n", "<Esc>", close, km)
  -- Cargar más historial (reabre con +HIST_STEP).
  vim.keymap.set("n", "+", function()
    close()
    M.open(core, hist_n + HIST_STEP)
  end, km)
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
end

require("review.core").registry.register({ name = "base", setup = M.setup })

return M
