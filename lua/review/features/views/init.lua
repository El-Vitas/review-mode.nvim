local inline = require("review.features.views.inline")
local split = require("review.features.views.split")

-- GLOBAL view mode (VSCode style): the mode (normal/inline/split) applies to
-- ALL files. When entering a file the current mode is re-applied; in
-- split, both columns follow the active file.
local M = {}
-- Review is a PERMANENT mode: normal/inline/split are its 3 views, there is no
-- "leaving review". That is why review is always active and "normal" is the
-- default view.
M.mode = "normal"

local VALID_MODES = { normal = true, inline = true, split = true }
local applying = false

-- Split colors. They distinguish:
--  * MODIFIED line (DiffChange): soft ORANGE tint in both columns.
--  * exact text that changed within the line (DiffText): RED on the left
--    (what was removed), GREEN on the right (what was added) -> you see WHAT changed.
--  * entirely DELETED line (only on the left) / entirely ADDED line (only on the right):
--    full RED / GREEN.
-- Overridable.
local function ensure_diff_hl()
  -- BACKGROUND only (no fg or bold, to avoid oversaturating).
  vim.api.nvim_set_hl(0, "ReviewDiffChange", { bg = "#44401d", default = true }) -- modified: soft yellow
  vim.api.nvim_set_hl(0, "ReviewDiffDelLine", { bg = "#37202a", default = true }) -- entirely deleted line (dark red)
  vim.api.nvim_set_hl(0, "ReviewDiffDelText", { bg = "#54232f", default = true }) -- removed text (red)
  vim.api.nvim_set_hl(0, "ReviewDiffAddLine", { bg = "#21331f", default = true }) -- entirely added line (dark green)
  vim.api.nvim_set_hl(0, "ReviewDiffAddText", { bg = "#2c4a30", default = true }) -- added text (green)
  vim.api.nvim_set_hl(0, "ReviewDiffFiller", { bg = "#2a2b38", default = true }) -- filler
end

-- Applies the global mode to the CURRENT window/buffer (the editing one).
local function apply_current(core)
  if applying then return end
  applying = true
  local ok, err = pcall(function()
    local win = vim.api.nvim_get_current_win()
    local buf = vim.api.nvim_get_current_buf()
    if split.is_scratch(buf) then
      -- DELIBERATE view change while standing on the HEAD panel: operate on the
      -- editing window, not on the scratch. Without this, leaving split from
      -- the left panel cleaned up nothing ("only one split changes").
      -- (The passive BufEnter path already discards the scratch before getting here.)
      local mw = split.main_win()
      if not mw then return end
      vim.api.nvim_set_current_win(mw)
      win = vim.api.nvim_get_current_win()
      buf = vim.api.nvim_get_current_buf()
    end
    -- A file returning to a window where the split left its diff on
    -- (the pair was torn down while the window showed another file): turn it off.
    split.clear_stale(win, buf)
    if M.mode == "inline" then
      split.teardown()
      if vim.bo[buf].buftype == "" then inline.render(core, buf) end
    elseif M.mode == "split" then
      inline.clear(core, buf)
      split.sync(core)
    else -- normal
      inline.clear(core, buf)
      split.teardown()
    end
    -- Review must NEVER collapse lines: open the folds in the window of the
    -- repo file (in all 3 modes). Without this, a user fold plugin
    -- (treesitter/ufo) would show "+-- N lines" hiding what is being reviewed.
    if vim.bo[buf].buftype == "" and core.git.rel_path(buf) then
      pcall(function()
        -- `[0]` = local to this window: without it the global changed too and
        -- files outside the repo were born without folds (contradicts D11).
        vim.wo[win][0].foldenable = false
        vim.wo[win][0].foldlevel = 99
      end)
    end
  end)
  applying = false
  if not ok then vim.notify("review.nvim views: " .. tostring(err), vim.log.levels.DEBUG) end
end

--- Changes the GLOBAL view mode and applies it to the current file. No-op if the
--- mode is invalid or already the current one.
function M.set(core, mode)
  if not VALID_MODES[mode] then return end
  if M.mode == mode then return end
  M.mode = mode
  apply_current(core)
  core.events.emit("view:changed", { mode = mode })
end

function M.setup(core, opts)
  M.mode = "normal"
  local group = vim.api.nvim_create_augroup("ReviewViews", { clear = true })

  ensure_diff_hl()
  vim.api.nvim_create_autocmd("ColorScheme", { group = group, callback = ensure_diff_hl })

  -- Invalidate the inline HEAD cache when the file is reloaded, and RELEASE it when
  -- the buffer is closed/deleted (otherwise the cache grows with every opened file).
  vim.api.nvim_create_autocmd({ "BufReadPost", "BufDelete", "BufWipeout" }, {
    group = group,
    callback = function(a) inline.invalidate(a.buf) end,
  })

  -- When returning to Neovim, HEAD may have changed outside (commit, `git add` with an
  -- index base) without touching the file: forget the cached HEADs and repaint the view.
  vim.api.nvim_create_autocmd("FocusGained", {
    group = group,
    callback = function()
      inline.invalidate()
      require("review.features.views.scrollbar").invalidate()
      vim.schedule(function() apply_current(core) end)
    end,
  })

  -- Review is permanent: when entering any file in the repo the current
  -- view (global, VSCode style) is applied and the folds are opened.
  vim.api.nvim_create_autocmd({ "BufWinEnter", "BufEnter" }, {
    group = group,
    callback = function(a)
      if vim.bo[a.buf].buftype ~= "" or split.is_scratch(a.buf) then return end
      vim.schedule(function() apply_current(core) end)
    end,
  })

  -- MANUAL close of either of the two split columns: it is taken as "I don't
  -- want split". The session is cleaned up and the global view becomes normal; otherwise
  -- the pair would reappear on the next focus or file change.
  vim.api.nvim_create_autocmd("WinClosed", {
    group = group,
    callback = function(a)
      local win = tonumber(a.match)
      if not win then return end
      -- First of all: if the window being closed is in diff mode, prevent
      -- Neovim from firing DiffUpdated in the middle of the close (split.lua, B19).
      if vim.api.nvim_win_is_valid(win) and vim.wo[win].diff then split.guard_diff_close() end
      split.forget_win(win)
      local ok, was_pair = pcall(split.on_win_closed, win)
      if ok and was_pair and M.mode == "split" then
        M.mode = "normal"
        core.events.emit("view:changed", { mode = "normal" })
      end
    end,
  })

  -- Live re-render while editing. Inline: repaints. Split: re-syncs to
  -- open/close the 2 columns as changes vs HEAD appear/disappear.
  -- In insert mode (TextChangedI) the inline repaint is batched with a single
  -- timer: it recomputes the diff of the whole buffer, and with 10,000 heavily
  -- changed lines that is 40 ms per keystroke. Outside insert (TextChanged) it is immediate.
  local inline_timer = assert(vim.uv.new_timer())
  local inline_buf
  local render_pending = vim.schedule_wrap(function()
    if inline_buf and vim.api.nvim_buf_is_valid(inline_buf) and M.mode == "inline" then
      pcall(inline.render, core, inline_buf)
    end
  end)
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    group = group,
    callback = function(a)
      if vim.bo[a.buf].buftype ~= "" then return end
      if M.mode == "inline" then
        inline_timer:stop()
        if a.event == "TextChangedI" then
          inline_buf = a.buf
          inline_timer:start(80, 0, render_pending)
        else
          pcall(inline.render, core, a.buf)
        end
      elseif M.mode == "split" and a.event == "TextChanged" then
        -- Only when a change FINISHES (not on every keystroke in insert): the native
        -- diff already updates live; this only detects whether it went back to HEAD.
        pcall(apply_current, core)
        vim.schedule(function() pcall(split.repad) end) -- re-align wrap
      end
    end,
  })

  -- When the column WIDTH changes (sidebar opens/closes, window resize)
  -- or when toggling `wrap` (<leader>w), the wrap heights change → recompute
  -- the virtual alignment padding.
  vim.api.nvim_create_autocmd({ "WinResized", "VimResized", "OptionSet" }, {
    group = group,
    callback = function(a)
      if M.mode ~= "split" then return end
      if a.event == "OptionSet" and a.match ~= "wrap" then return end
      vim.schedule(function() pcall(split.repad) end)
    end,
  })

  -- When the comparison BASE changes (:ReviewBase), invalidate the HEAD cache
  -- and re-render the current view with the new base.
  core.events.on("base:changed", function()
    inline.invalidate()
    vim.schedule(function() apply_current(core) end)
  end)

  local commands = require("review.features.views.commands")
  commands.setup(core, opts, M)

  -- Change markers in the scrollbar (nvim-scrollbar), if installed.
  require("review.features.views.scrollbar").setup(core)
end

require("review.core").registry.register({ name = "views", setup = M.setup })

return M
