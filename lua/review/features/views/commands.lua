local M = {}

local ORDER = { "normal", "inline", "split" }

local function next_mode(current)
  for i, m in ipairs(ORDER) do
    if m == current then
      return ORDER[i % #ORDER + 1]
    end
  end
  return ORDER[1]
end

function M.setup(core, opts, views_mod)
  opts = opts or {}
  local leader = opts.leader or "<leader>r"

  local function run(cmd_opts)
    local mode = cmd_opts.args
    if mode == "" then
      vim.notify("usage: :ReviewView {normal|inline|split}", vim.log.levels.ERROR)
      return
    end
    views_mod.set(core, mode)
  end

  local ucmd_opts = { nargs = 1, complete = function() return ORDER end }
  -- Long command + short alias (both real). The lowercase `rv` is resolved by
  -- plugin/review.lua via cnoreabbrev → Rv.
  vim.api.nvim_create_user_command("ReviewView", run, ucmd_opts)
  vim.api.nvim_create_user_command("Rv", run, vim.deepcopy(ucmd_opts))

  -- Direct commands per mode (global), more convenient than `:Rv split`.
  local function set_mode(mode)
    return function() views_mod.set(core, mode) end
  end
  local direct = { normal = "Normal", inline = "Inline", split = "Split" }
  for mode, suffix in pairs(direct) do
    vim.api.nvim_create_user_command("Review" .. suffix, set_mode(mode), {})
    vim.api.nvim_create_user_command("Rv" .. suffix:sub(1, 1):lower(), set_mode(mode), {})
  end

  -- Cycle the global mode.
  vim.keymap.set("n", leader .. "v", function()
    views_mod.set(core, next_mode(views_mod.mode))
  end, { desc = "review: cycle view" })

  -- Direct views: <leader>rn normal · <leader>ri inline · <leader>rs split.
  vim.keymap.set("n", leader .. "n", function() views_mod.set(core, "normal") end, { desc = "review: normal view" })
  vim.keymap.set("n", leader .. "i", function() views_mod.set(core, "inline") end, { desc = "review: inline view" })
  vim.keymap.set("n", leader .. "s", function() views_mod.set(core, "split") end, { desc = "review: split view" })

  -- ── CHANGES navigation (vs HEAD) ──────────────────────────────────────────
  -- To locate and quickly jump to changes (besides the scrollbar marks).
  -- The ranges come from the same diff that feeds the scrollbar.
  local scrollbar = require("review.features.views.scrollbar")

  local function goto_change(dir)
    local bufnr = vim.api.nvim_get_current_buf()
    local hunks = scrollbar.hunks(core, bufnr)
    if #hunks == 0 then
      vim.notify("review.nvim: no changes vs HEAD", vim.log.levels.INFO)
      return
    end
    local cur = vim.fn.line(".")
    local target
    if dir > 0 then
      for _, h in ipairs(hunks) do
        if h.sl > cur then target = h.sl; break end
      end
      target = target or hunks[1].sl -- wrap to the first
    else
      for i = #hunks, 1, -1 do
        if hunks[i].sl < cur then target = hunks[i].sl; break end
      end
      target = target or hunks[#hunks].sl -- wrap to the last
    end
    vim.api.nvim_win_set_cursor(0, { target, 0 })
    vim.cmd("normal! zz")
  end

  vim.api.nvim_create_user_command("ReviewNextChange", function() goto_change(1) end, {})
  vim.api.nvim_create_user_command("ReviewPrevChange", function() goto_change(-1) end, {})
  vim.keymap.set("n", "]r", function() goto_change(1) end, { desc = "review.nvim: next change" })
  vim.keymap.set("n", "[r", function() goto_change(-1) end, { desc = "review.nvim: prev change" })

  -- List of change ranges (quickfix): "L4-8 changed" → Enter jumps.
  local function list_changes()
    local bufnr = vim.api.nvim_get_current_buf()
    local hunks = scrollbar.hunks(core, bufnr)
    if #hunks == 0 then
      vim.notify("review.nvim: no changes vs HEAD", vim.log.levels.INFO)
      return
    end
    local fname = vim.api.nvim_buf_get_name(bufnr)
    local items = {}
    local label = { add = "added", change = "changed", delete = "deleted" }
    for _, h in ipairs(hunks) do
      local rng = (h.el > h.sl) and ("L" .. h.sl .. "-" .. h.el) or ("L" .. h.sl)
      items[#items + 1] = { filename = fname, lnum = h.sl, col = 1, text = rng .. "  " .. (label[h.kind] or h.kind) }
    end
    vim.fn.setqflist({}, " ", { title = "review.nvim: changes", items = items })
    vim.cmd("copen")
    -- Same behavior as the comments list: q closes, Enter jumps and closes.
    local qbuf = vim.api.nvim_get_current_buf()
    vim.wo.winbar = "%#Title# review.nvim %* changes · ‹Enter› go · ‹q› close"
    vim.keymap.set("n", "q", "<cmd>cclose<CR>", { buffer = qbuf, nowait = true, desc = "close" })
    vim.keymap.set("n", "<CR>", function()
      local idx = vim.fn.line(".")
      vim.cmd("cclose")
      pcall(vim.cmd, idx .. "cc")
    end, { buffer = qbuf, nowait = true, desc = "go to change and close" })
  end
  vim.api.nvim_create_user_command("ReviewChanges", list_changes, {})
  vim.api.nvim_create_user_command("Rch", list_changes, {})
  vim.keymap.set("n", leader .. "g", list_changes, { desc = "review.nvim: list changes (go)" })
end

return M
