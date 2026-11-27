local render = require("review.features.comments.render")
local commands = require("review.features.comments.commands")
local gutter = require("review.features.comments.gutter")
local mode = require("review.features.comments.mode")

local M = {}

-- Defines the highlight groups, with `default = true` so the user can
-- override them. We use our OWN COLORS (blue, not `Visual` nor brown) so a
-- comment is not confused with a selection. Tones for dark themes
-- (e.g. catppuccin macchiato).
local function ensure_hl()
  -- Range highlight: dim blue background + blue side bar.
  vim.api.nvim_set_hl(0, "ReviewCommentLine", { bg = "#2c3a52", default = true })
  vim.api.nvim_set_hl(0, "ReviewCommentLine2", { bg = "#26436b", default = true }) -- alternate tone
  vim.api.nvim_set_hl(0, "ReviewCommentLineResolved", { bg = "#2a2b38", default = true })
  vim.api.nvim_set_hl(0, "ReviewCommentSign", { fg = "#8aadf4", bold = true, default = true })
  vim.api.nvim_set_hl(0, "ReviewCommentSignResolved", { fg = "#6e738d", default = true })
  -- Agent comments (violet) and comments with an uncertain anchor (amber).
  vim.api.nvim_set_hl(0, "ReviewCommentAgent", { bg = "#3a2c52", default = true })
  vim.api.nvim_set_hl(0, "ReviewCommentStale", { bg = "#4a3a1d", default = true })
  vim.api.nvim_set_hl(0, "ReviewCommentSignAgent", { fg = "#c6a0f6", bold = true, default = true })
  vim.api.nvim_set_hl(0, "ReviewCommentBadgeAgent", { bg = "#3a2c52", fg = "#d8c4f5", default = true })
  vim.api.nvim_set_hl(0, "ReviewCommentBadgeEdgeAgent", { bg = "#3a2c52", fg = "#c6a0f6", default = true })
  -- Cyclic bracket palette (one color per comment).
  local palette = { "#8aadf4", "#a6da95", "#c6a0f6", "#f5a97f", "#8bd5ca", "#eed49f" }
  for i, hex in ipairs(palette) do
    vim.api.nvim_set_hl(0, "ReviewCommentSign" .. i, { fg = hex, bold = true, default = true })
  end
  -- Badge at the end of the line: chip with a blue background and a small edge.
  vim.api.nvim_set_hl(0, "ReviewCommentBadge", { bg = "#3b4b71", fg = "#cad3f5", default = true })
  vim.api.nvim_set_hl(0, "ReviewCommentBadgeEdge", { bg = "#3b4b71", fg = "#8aadf4", default = true })
  vim.api.nvim_set_hl(0, "ReviewCommentBadgeResolved", { bg = "#33343f", fg = "#8087a2", default = true })
  vim.api.nvim_set_hl(0, "ReviewCommentBadgeEdgeResolved", { bg = "#33343f", fg = "#6e738d", default = true })
  -- Peek float: our own OPAQUE background (so it does not look transparent if
  -- the theme has NormalFloat without a background), border and blue title.
  vim.api.nvim_set_hl(0, "ReviewPeekNormal", { bg = "#1e2030", fg = "#cad3f5", default = true })
  vim.api.nvim_set_hl(0, "ReviewPeekBorder", { bg = "#1e2030", fg = "#8aadf4", default = true })
  vim.api.nvim_set_hl(0, "ReviewPeekTitle", { bg = "#1e2030", fg = "#8aadf4", bold = true, default = true })
  vim.api.nvim_set_hl(0, "ReviewPeekHeader", { bg = "#2c3a52", fg = "#8aadf4", bold = true, default = true })
  vim.api.nvim_set_hl(0, "ReviewPeekSep", { bg = "#1e2030", fg = "#5b6078", default = true })
  -- Floating peek card: header of each thread message + footer.
  vim.api.nvim_set_hl(0, "ReviewPeekWho", { bg = "#1e2030", fg = "#8aadf4", bold = true, default = true })
  vim.api.nvim_set_hl(0, "ReviewPeekWhoAgent", { bg = "#1e2030", fg = "#c6a0f6", bold = true, default = true })
  vim.api.nvim_set_hl(0, "ReviewPeekFoot", { bg = "#1e2030", fg = "#6e738d", default = true })
end

function M.setup(core, opts)
  opts = opts or {}

  local group = vim.api.nvim_create_augroup("ReviewComments", { clear = true })

  ensure_hl()
  -- `:colorscheme` clears the highlights; redefine them when the theme changes.
  vim.api.nvim_create_autocmd("ColorScheme", { group = group, callback = ensure_hl })

  -- Does the buffer have comments? If not, relocate/sync cannot change anything and
  -- opening or saving the file does not rewrite comments.json.
  local function has_comments(buf)
    local rel = core.git.rel_path(buf)
    return rel ~= nil and #core.state.for_path(rel) > 0
  end

  -- When OPENING the file (just read from disk): re-locate by content
  -- (`anchor_text`) in case the file changed while the buffer was closed
  -- (e.g. the agent edited it), and persist the correction. Then render.
  vim.api.nvim_create_autocmd("BufReadPost", {
    group = group,
    callback = function(args)
      if has_comments(args.buf) then
        render.relocate(core, args.buf)
        core.state.persist()
      end
      render.render(core, args.buf)
    end,
  })
  vim.api.nvim_create_autocmd("BufEnter", {
    group = group,
    callback = function(args)
      render.render(core, args.buf)
    end,
  })

  vim.api.nvim_create_autocmd("BufWritePost", {
    group = group,
    callback = function(args)
      if not has_comments(args.buf) then return end
      render.sync_positions(core, args.buf)
      core.state.persist()
    end,
  })

  -- Release peek marks of closed/deleted buffers.
  vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
    group = group,
    callback = function(args) mode.cleanup_buffer(args.buf) end,
  })

  -- When comments change (including those the agent adds/edits via
  -- RPC), re-render the open repo-file buffers, so
  -- new comments get their anchor extmark without waiting for a BufEnter.
  -- We SYNC first (sync_positions) to capture any extmark drift
  -- from unsaved edits, and only then repaint: otherwise render
  -- would relocate the extmark to the old `lnum` and lose the shift by
  -- gravity. sync_positions only emits comments:changed if something changed → it converges
  -- (no loop); render.render does not mutate state.
  core.events.on("comments:changed", function()
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_loaded(b) and vim.bo[b].buftype == "" then
        pcall(render.sync_positions, core, b)
        pcall(render.render, core, b)
      end
    end
  end)

  -- The agent (or anyone) edited the file on disk and reconcile applied the
  -- patch to the buffer; we re-sync positions and mark the doubtful ones stale.
  core.events.on("buffer:reconciled", function(payload)
    if payload and payload.bufnr and vim.api.nvim_buf_is_valid(payload.bufnr) then
      render.reconcile(core, payload.bufnr)
    end
  end)

  commands.setup(core, opts)
  gutter.setup(core)
end

require("review.core").registry.register({ name = "comments", setup = M.setup })

return M
