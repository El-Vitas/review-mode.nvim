# Commands, aliases and keymaps

The long commands are capitalized (`:ReviewX`); each has a **real short
alias** (`:Rx`) and a **lowercase** version (`rx`) resolved by
`cnoreabbrev` in `plugin/review.lua` (you can type in lowercase and it expands
on confirm). The keymap prefix is `opts.leader` (default `<leader>r`).

## Comments

| Command | Alias | Keymap | Action |
|---|---|---|---|
| `:ReviewCommentMode` | `:Rcm` / `rcm` | `<leader>re` | edit the comment on the line |
| — | — | `<leader>rc` (n and v) | comment the line / the visual selection |
| — | — | `<leader>rd` | delete the comment on the line |
| — | — | `<leader>rx` | resolve / unresolve |
| `:ReviewList` | `:Rl` / `rl` | `<leader>rl` | list all (quickfix) |
| `:ReviewListFile` | `:Rlf` / `rlf` | `<leader>rL` | list those in the current file |
| `:ReviewToggle` | `:Rt` / `rt` | `<leader>rh` | hide / show all |
| `:ReviewPeek` | `:Rp` / `rp` | `<leader>rp` | centered floating card of the comment (toggle; only 1 at a time) |

**Comment popup:** starts in typing mode; Enter inserts line breaks;
`Esc` and `Enter` (in normal mode) submit; `q` cancels.

**Inside the list (quickfix):** `Enter` jumps to the comment and closes · `d` deletes
· `x` resolves · `f` cycles the filter (all → open → resolved → mine → agent →
answered → unanswered) · `q` closes. The list shows only top-level comments
(replies live in the parent's thread, visible in the peek).

## Agent (only with `features.agent = { enabled = true }`)

| Command | Action |
|---|---|
| `:ReviewReload` | reload the current buffer from disk with a minimal patch (manual fallback for AUTO re-anchoring, e.g. if there was a conflict due to unsaved changes) |

The rest of the agent control is through RPC (`_G.ReviewAgent`, see `docs/features.md`
and `docs/plans/05-agent.md`), not through user commands.

**Inside the peek card:** `x` resolve · `d` delete · `e` edit · `q`/`Esc` close. It is a single centered card (opening another closes the previous one).

## Views (diff)

| Command | Alias | Keymap | Action |
|---|---|---|---|
| `:ReviewView {normal\|inline\|split}` | `:Rv` / `rv` | `<leader>rv` (cycles) | set/cycle view |
| `:ReviewNormal` | `:Rvn` / `rvn` | `<leader>rn` | normal view |
| `:ReviewInline` | `:Rvi` / `rvi` | `<leader>ri` | inline (unified) view |
| `:ReviewSplit` | `:Rvs` / `rvs` | `<leader>rs` | split view (2 columns) |

The mode is global: it applies to all files and follows the active file.

**Changes (vs the base):** `<leader>rg` lists the ranges (quickfix; `Enter` jumps and
closes, `q` closes) · `]r` / `[r` jump to the next/previous change.

**Comparison base:** `:ReviewBase` / `:Rb` / `<leader>rb` opens a centered
modal to choose what the whole review is compared against (inline, split, changes):
`HEAD`, `index` (staged), or a recent commit (hash + name). `f` toggles the
**this branch** filter (the branch's own commits, `base..HEAD`) ↔ **global**
(full history, `+` loads more). `Enter` selects, `q`/`Esc` cancels. On
selection, it also syncs the gitsigns signs (`change_base`). The `changed`
sidebar (`<leader>s`) reflects the chosen base. Default: `HEAD`.

## Sidebar

| Command | Alias | Keymap | Action |
|---|---|---|---|
| `:ReviewSidebar {changed\|all}` | `:Rs` / `rs` | `<leader>s` (toggle) | open/switch changed ↔ all |

Inside the tree (native neo-tree): `z` closes all · `Z` expands all ·
`<CR>`/`o` toggles folder · `C` closes the current one · `:Neotree reveal` focuses the
current file.

## Export

| Command | Alias | Keymap | Action |
|---|---|---|---|
| `:ReviewYankFile` | `:Ryf` / `ryf` | `<leader>ryf` | copy (markdown) the comments of the current file |
| `:ReviewYankAll` | `:Rya` / `rya` | `<leader>rya` | copy all comments |

With the `agent` feature enabled, the yank prepends a header with the RPC socket
and each comment carries its `` `id:<id>` `` token (agent-ready).