-- Selector de BASE de comparación de review: HEAD, index (staged) o un commit.
-- Modal centrado (Enter selecciona, q/Esc cancela). Al elegir, se usa esa base
-- en las vistas (inline/split) y se sincroniza gitsigns. Los commits muestran
-- hash + nombre (subject).
local M = {}

local ns = vim.api.nvim_create_namespace("review_base")

local function build_options(core)
  local root = core.git.root(vim.api.nvim_get_current_buf()) or core.git.root()
  local opts = {
    { ref = "HEAD", text = "HEAD", info = "último commit" },
    { ref = ":", text = "index", info = "staged (área de preparación)" },
  }
  if root then
    local log = vim.fn.systemlist({ "git", "-C", root, "log", "--oneline", "-20", "--no-color" })
    if vim.v.shell_error == 0 then
      for _, line in ipairs(log) do
        local hash, subject = line:match("^(%S+)%s+(.*)$")
        if hash then
          opts[#opts + 1] = { ref = hash, text = hash, info = subject or "" }
        end
      end
    end
  end
  return opts
end

function M.open(core)
  local options = build_options(core)
  local W = 74
  local cur = core.git.base_ref

  local lines = {}
  for i, o in ipairs(options) do
    local mark = (o.ref == cur) and "● " or "  "
    local info = o.info or ""
    if #info > W - 16 then info = info:sub(1, W - 19) .. "…" end
    lines[i] = string.format("%s%-9s  %s", mark, o.text, info)
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  for i, o in ipairs(options) do
    if o.ref == cur then
      pcall(vim.api.nvim_buf_set_extmark, buf, ns, i - 1, 0,
        { end_row = i - 1, hl_group = "ReviewBaseCurrent" })
    end
  end
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = "wipe"

  local h = math.min(#lines, 18)
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = W,
    height = h,
    row = math.max(0, math.floor((vim.o.lines - h) / 2) - 1),
    col = math.max(0, math.floor((vim.o.columns - W) / 2)),
    style = "minimal",
    border = "rounded",
    title = " Comparison base · Enter select · q cancel ",
    title_pos = "center",
  })
  vim.wo[win].cursorline = true
  for i, o in ipairs(options) do
    if o.ref == cur then
      pcall(vim.api.nvim_win_set_cursor, win, { i, 0 })
      break
    end
  end

  local function close()
    if vim.api.nvim_win_is_valid(win) then pcall(vim.api.nvim_win_close, win, true) end
  end
  local function select()
    local o = options[vim.fn.line(".")]
    close()
    if not o then return end
    core.git.set_base(o.ref)
    -- Sincronizar gitsigns (si está instalado): mismos signos que la base.
    pcall(function()
      local gs = require("gitsigns")
      if o.ref == ":" then
        gs.change_base(nil, true)
      else
        gs.change_base(o.ref, true)
      end
    end)
    core.events.emit("base:changed", { ref = o.ref })
    local extra = (o.info ~= "" and o.text ~= o.info) and ("  (" .. o.info .. ")") or ""
    vim.notify("review: comparison base → " .. o.text .. extra, vim.log.levels.INFO)
  end

  local km = { buffer = buf, nowait = true, silent = true }
  vim.keymap.set("n", "<CR>", select, km)
  vim.keymap.set("n", "q", close, km)
  vim.keymap.set("n", "<Esc>", close, km)
end

function M.setup(core, opts)
  opts = opts or {}
  local leader = opts.leader or "<leader>r"
  vim.api.nvim_set_hl(0, "ReviewBaseCurrent", { fg = "#eed49f", bold = true, default = true })
  vim.api.nvim_create_user_command("ReviewBase", function() M.open(core) end, {})
  vim.api.nvim_create_user_command("Rb", function() M.open(core) end, {})
  vim.keymap.set("n", leader .. "b", function() M.open(core) end, { desc = "Review: select comparison base" })
end

require("review.core").registry.register({ name = "base", setup = M.setup })

return M
