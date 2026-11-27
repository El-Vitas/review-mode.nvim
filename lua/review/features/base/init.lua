-- Review comparison BASE picker: HEAD, index (staged) or a commit.
-- Centered modal with SECTIONS: special (HEAD/index), "this branch" (commits
-- of the current branch itself = base..HEAD) and "history" (global, scrollable;
-- `+` loads more). Merges are marked with ⇄. Each commit shows hash + name.
-- On selection, the base is used in the views and gitsigns is synced.
local M = {}

local ns = vim.api.nvim_create_namespace("review_base")
local HIST_STEP = 60

--- Cleans a commit `info` for use as the statusline label: removes the multibyte
--- markers we add (◂ branch-point, ⇄ merge). Careful: Lua patterns work per BYTE;
--- a char class [◂⇄] splits multibyte characters and corrupts the text
--- (mojibake). That is why they are removed as whole literals.
--- @param info string|nil
--- @return string|nil
function M.clean_label(info)
  if not info or info == "" then return nil end
  local s = info:gsub("^◂%s*", ""):gsub("^⇄%s*", "")
  if s == "" then return nil end
  return s
end

-- Base branch used to separate "this branch" from the history: origin/HEAD → main/master…
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

-- List of commits {ref, text, info(subject), merge}. `range` is optional (e.g.
-- "main..HEAD"); `n` limits the count.
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

-- Builds the options according to the active filter: "branch" (commits of the
-- current branch itself, base..HEAD) or "global" (full history, paginated with `+`).
-- The "special" section (HEAD/index) always goes on top.
local function build_options(core, hist_n, filter)
  local out = {
    { header = "special" },
    { ref = "HEAD", text = "HEAD", info = "last commit" },
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
    -- ONE extra commit: the one JUST BEFORE the branch (the parent of the first
    -- own commit = merge-base with the base branch). Choosing it as the base shows
    -- ALL the branch's changes, including the first commit (which `base..HEAD`
    -- would exclude). It is separated and labeled so it is clear it is not on your branch.
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
  -- Cursor on the current base (if visible under this filter), or on the first
  -- selectable option (skipping headers/notes).
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
    if not o or o.header or o.note or not o.ref then return end -- ignore headers/notes
    close()
    core.git.set_base(o.ref)
    -- Readable label for the statusline (commit subject). For HEAD/index
    -- there is no subject → nil (the statusline shows "index" or nothing).
    local label = (o.ref ~= "HEAD" and o.ref ~= ":") and M.clean_label(o.info) or nil
    if label == "" then label = nil end
    core.git.base_label = label
    pcall(core.store.save_base, o.ref, label) -- persist for the next session
    M.apply_gitsigns(o.ref)
    core.events.emit("base:changed", { ref = o.ref })
    local extra = (o.info ~= "" and o.text ~= o.info) and ("  (" .. o.info .. ")") or ""
    vim.notify("review: comparison base → " .. o.text .. extra, vim.log.levels.INFO)
  end

  local km = { buffer = buf, nowait = true, silent = true }
  vim.keymap.set("n", "<CR>", pick, km)
  vim.keymap.set("n", "q", close, km)
  vim.keymap.set("n", "<Esc>", close, km)
  -- Toggle the this-branch ↔ global filter (reopens under the other filter).
  vim.keymap.set("n", "f", function()
    close()
    M.open(core, HIST_STEP, filter == "branch" and "global" or "branch")
  end, km)
  -- Load more history (global only; reopens with +HIST_STEP).
  vim.keymap.set("n", "+", function()
    if filter ~= "global" then return end
    close()
    M.open(core, hist_n + HIST_STEP, "global")
  end, km)
end

--- Points gitsigns at the review base:
---   • commit     → change_base(commit, global)  → diff vs that commit
---   • HEAD / ":" → change_base(nil, global)      → NATIVE gitsigns (index base)
---
--- Note: we do NOT force base="HEAD" in the default case. With an explicit base
--- gitsigns diffs untracked files against that ref and paints them as "added" (solid
--- sign), losing the dotted `untracked` sign (`┆`) that marks new
--- files. Leaving the native default preserves that indicator.
--- @param ref string  the review base (HEAD | ":" | <commit>)
function M.apply_gitsigns(ref)
  pcall(function()
    local gs = require("gitsigns")
    if not ref or ref == "HEAD" or ref == ":" then
      gs.change_base(nil, true) -- native: index; keeps the untracked `┆`
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

  -- Restore the base persisted from the previous session (per repo). Done on
  -- VeryLazy so gitsigns/neo-tree are already available, and only if it is NOT
  -- HEAD (the default does not need restoring).
  local function restore()
    local ok, ref, label = pcall(core.store.load_base)
    if not ok or not ref or ref == "HEAD" then return end
    -- Validate that the ref still exists (avoids bases broken by rebase/gc).
    if ref ~= ":" then
      local root = core.git.root() or core.store.root_fn()
      if root then
        vim.fn.systemlist({ "git", "-C", root, "rev-parse", "--verify", "--quiet", ref .. "^{commit}" })
        if vim.v.shell_error ~= 0 then return end
      end
    end
    core.git.set_base(ref)
    core.git.base_label = label -- recover the label for the statusline
    -- We do NOT emit "base:changed" at startup: it would be a cascade (views +
    -- scrollbar + sidebar refresh). The view mode starts in "normal" (no
    -- diff), and scrollbar/sidebar read the base lazily when rendering. We only
    -- align gitsigns (which does need the explicit change_base).
    M.apply_gitsigns(ref)
  end
  vim.api.nvim_create_autocmd("User", {
    pattern = "VeryLazy",
    once = true,
    callback = function()
      vim.schedule(function()
        restore()
        -- With the base already set (restored or HEAD), compute its renames in
        -- the background: the first new file opened does not wait for them.
        core.git.prefetch_renames()
      end)
    end,
  })
end

require("review.core").registry.register({ name = "base", setup = M.setup })

return M
