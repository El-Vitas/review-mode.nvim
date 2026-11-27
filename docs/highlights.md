# Colors (highlight groups)

All groups are defined with `default = true`, so **you can
override them** in your config (after loading the plugin, or in a `ColorScheme`
autocmd). The default tones are designed for dark themes
(catppuccin macchiato). The plugin re-applies them on `ColorScheme`.

## Comments (sign column, range background, badge)

| Group | Use | Default |
|---|---|---|
| `ReviewCommentLine` | range background (even comment) | `bg #2c3a52` (blue) |
| `ReviewCommentLine2` | range background (odd comment, alternates) | `bg #26436b` |
| `ReviewCommentLineResolved` | resolved range background | `bg #2a2b38` |
| `ReviewCommentAgent` | range background (agent comment) | `bg #3a2c52` (violet) |
| `ReviewCommentStale` | range background (uncertain anchor, ⚠) | `bg #4a3a1d` (amber) |
| `ReviewCommentSign1..6` | gutter bracket (cyclic color per comment) | blue/green/mauve/peach/teal/yellow |
| `ReviewCommentSignAgent` | gutter bracket for agent comment | `fg #c6a0f6` (violet) |
| `ReviewCommentSignResolved` | resolved bracket | `fg #6e738d` |
| `ReviewCommentBadge` / `…Edge` | end-of-line chip + its border | `bg #3b4b71` |
| `ReviewCommentBadgeAgent` / `…EdgeAgent` | agent chip + its border | `bg #3a2c52` (violet) |
| `ReviewCommentBadgeResolved` / `…EdgeResolved` | resolved chip | `bg #33343f` |

**Authorship / threads / stale:** agent comments (`author ~= "user"`) are painted with a violet
background and a 🤖 icon; those with replies show a `↩N` suffix in the badge; those marked
`stale` (the anchored line changed on disk) are painted amber with ⚠. The peek (`<leader>rp`) shows the
full thread: the parent comment and, indented below it, the replies with their author.

## Inline peek

| Group | Use | Default |
|---|---|---|
| `ReviewPeekNormal` | peek block background | `bg #1e2030` |
| `ReviewPeekBorder` | peek left bar | `fg #8aadf4` |
| `ReviewPeekHeader` | header (state · range · author) | `bg #2c3a52 fg #8aadf4` |
| `ReviewPeekSep` | separator | `fg #5b6078` |

## Split (diff) — colors per column

Native diff paints both sides with the same groups; we remap them **per
window** with `winhighlight` so that the HEAD column (left) is red and the file
column (right) is green. It distinguishes a **modified line** (soft yellow background) from the
**exact text that changed** (strong red/green). **Background only** (no fg/bold).

| Group | Use | Default |
|---|---|---|
| `ReviewDiffChange` | modified line (both columns) | `bg #44401d` (yellow) |
| `ReviewDiffDelLine` | entire deleted line (left) | `bg #37202a` (dark red) |
| `ReviewDiffDelText` | text removed within the line (left) | `bg #54232f` (red) |
| `ReviewDiffAddLine` | entire added line (right) | `bg #21331f` (dark green) |
| `ReviewDiffAddText` | text added within the line (right) | `bg #2c4a30` (green) |
| `ReviewDiffFiller` | alignment filler | `bg #2a2b38` |

## Override examples

```lua
-- Comments in a different tone
vim.api.nvim_set_hl(0, "ReviewCommentLine",  { bg = "#2e3440" })
vim.api.nvim_set_hl(0, "ReviewCommentLine2", { bg = "#3b4252" })

-- Diff: bluish modified line instead of yellow
vim.api.nvim_set_hl(0, "ReviewDiffChange", { bg = "#2b3350" })

-- Split reds/greens
vim.api.nvim_set_hl(0, "ReviewDiffDelText", { bg = "#54232f" })
vim.api.nvim_set_hl(0, "ReviewDiffAddText", { bg = "#2c4a30" })
```