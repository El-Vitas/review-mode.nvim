# Features

## comments — review comments

CRUD of comments anchored to a line (or range) via extmarks, with re-anchoring on
edit, multi-line popup, gutter with nested brackets, inline peek and export.

- **Anchoring**: each comment has an anchor extmark (with `end_row`) that follows
  the line while editing. On `BufWritePost`, `lnum`/`end_lnum` are re-synced
  from the extmark (`sync_positions`) and persisted.
- **Render** (`render.lua`): for each comment in the file it paints the range
  background (`ReviewCommentLine`, **alternating** tone between consecutive comments
  with `ReviewCommentLine2` to tell them apart) + a **badge** at the end of the
  first line (chip with border `▏ 💬 text ▕`, short text ~44 chars; the
  full detail goes in the peek). Global visibility toggle (`render.hidden`).
- **Nested gutter** (`gutter.lua`): replaces the `statuscolumn` of windows
  with repo files to draw **one bracket for EACH comment** that
  covers the line (`┌ │ └`, `▌` if single-line), stacked according to nesting and
  with a **color per comment** (cyclic palette of 6). Preserves signs (gitsigns)
  and number. The sign column only allows 1 sign per line, which is why the nesting
  is done in the statuscolumn.
- **Mode / popup** (`mode.lua`): `add_here` opens a multi-line nui popup
  (starts in insert, Enter inserts line breaks; it is submitted with **Enter in normal
  mode**, cancelled with `q`). `edit_here` reopens the popup with the existing
  text. UI-free testable core: `_add/_delete_at/_resolve_at/_update_at`.
- **Inline peek** (`mode.peek_here`): shows the comment as **virtual lines
  inserted below the block** (GitHub inline style). It is NOT a float: it is
  part of the code flow, moves with the scroll and does not follow the cursor.
  Toggle per comment; several at once; `close_all_peeks`.
- **List** (`commands.lua`): quickfix with all (`:Rl`) or those of the file (`:Rlf`),
  sorted by file+line. Inside the list: `Enter` jumps and closes, `d`
  deletes, `x` resolves/unresolves, `f` filters (all/open/resolved), `q`
  closes. Winbar with the shortcuts.

## views — diff views (GLOBAL mode, VSCode style)

The mode (normal / inline / split) is **global**: it applies to all files.
Review is a **permanent** mode (there is no "exit"); the 3 views are its modes.
When entering any file in the repo, the current view is re-applied and the **folds
are opened** (so lines are never compacted).

- **Comparison**: always `current buffer (in memory) vs HEAD (last commit)`.
  It shows everything uncommitted. It does not match gitsigns if something is staged
  (gitsigns compares against the index).
- **normal**: plain buffer (with folds open).
- **inline** (`inline.lua`): unified view. Diffs HEAD vs buffer with
  `vim.diff` (in memory, live). Deleted lines as red virtual lines
  (full bar) above; added ones highlighted in green. Caches HEAD per
  buffer.
- **split** (`split.lua`): 2 columns with **Neovim's native diff**
  (`:diffthis`), NOT diffview. Read-only HEAD panel on the left (with
  `winfixbuf`, no files can be opened in it), editable file on the right.
  Single session that **follows the active file**; if the file has no changes or
  has no HEAD → a single column. `diffopt` with `linematch` + `histogram` +
  `inline:char` → VSCode-style line-by-line alignment. Colors per column
  (see highlights.md). `foldlevel=99` so nothing is folded.
- `diff.lua`: parsing of `git diff -U0` (`parse_unified_diff`, `hunks_for`) and
  in-memory diff (`hunks_between` with `vim.diff`).

## sidebar — neo-tree integration

- `:ReviewSidebar {changed|all}` / `:Rs` — opens neo-tree on `git_status`
  (changed) or `filesystem` (all), **with the folders closed**.
- `<leader>rs` — **toggle** between changed ↔ all.
- Subscribes to `comments:changed` to refresh; `files_with_comments()` is a
  pure helper (set of relpaths with comments); `comment_marker()` is optional.
- Degrades gracefully if neo-tree is not installed (pcall + notify).
- Expanding/closing folders and revealing a file are done with native neo-tree
  (`z`/`Z`, `:Neotree reveal`) — review does not wrap them.

## export — agent-ready markdown

- `markdown.lua`: formats the comments as markdown **grouped by file**
  (`## <path>`), sorted by file+line, continuous numbering, with anchor
  `` `path:lnum` `` (or `path:lnum-end`). Excludes resolved ones. Collapses line
  breaks in the text.
- `:ReviewYankFile` / `:Ryf` (current file), `:ReviewYankAll` / `:Rya`
  (all) → copy to the `+` register.

## agent — native RPC bridge + AUTO reconciliation

Implemented. **Disabled by default** (`features.agent = { enabled = true }`;
it exposes a remote write surface). See the full protocol in
`plans/05-agent.md`.

- **Transport**: native Neovim RPC (`--remote-expr`), with no custom sockets or
  dependencies. The agent uses the `nvim` binary as a client against `v:servername`.
- **Model**: the agent writes **code to disk** with its own tools
  (OUTSIDE nvim); only the **comments** go through nvim (`_G.ReviewAgent` on top of
  `core.state`, the single source of truth).
- **`_G.ReviewAgent` API**: `list(filter?)`, `get(id)`, `context(id)`, `add`,
  `reply(parent_id, text)`, `resolve`/`unresolve`, `update`, `delete`,
  `clean_resolved(path?)`, `is_modified(path)`, `notify_changed(path)`,
  `servername()`. Everything is serializable (JSON/primitives), without `_extmark_id`.
- **AUTO reconciliation** (`agent/reconcile.lua`): when the agent changes a
  file on disk, a watcher (`agent/watch.lua`, `vim.uv.fs_event` + debounce)
  detects it and applies the change to the buffer as a **minimal patch by diff**
  (`vim.diff` indices → `nvim_buf_set_lines` from bottom to top). The extmarks
  (and therefore the comments) **re-anchor themselves by gravity**, without
  `:edit!`. It emits `buffer:reconciled`; `comments` reacts by re-syncing
  positions and marking as `stale` those with an uncertain anchor (by `anchor_text`).
- **Conflict**: if the buffer has unsaved changes, it is **not** overwritten (it reports
  `conflict`); the agent can query `is_modified(path)` before editing.
  `:ReviewReload` forces the patch of the current buffer as a manual fallback.
- **Authorship / threading**: comments with `author`, replies linked with
  `reply_to`. `comments` distinguishes them visually (🤖 / violet), shows the thread
  in the peek and the `↩N` suffix; the list filters by author and answered/unanswered.