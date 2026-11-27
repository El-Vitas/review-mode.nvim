# Decision log

Architecture, design, UX and optimization decisions made during
development, with their context and reasoning. Ordered by topic.

## Architecture and model

### D1 — Native in Neovim, without leaving the editor
Bring tuicr's review flow INSIDE Neovim. The "view" is only how the code is
painted (decorations), never new tabs or modified buffers. The
buffer remains the real, editable file.

### D2 — Core + vertical slices
A stable `core/` (the only dependency) + independent features that only
depend on the core contract and coordinate through events. It allows implementing the
features in parallel and testing them on their own. Hard rule: a feature never requires
another feature.

### D3 — Storage in `.git/review.nvim/comments.json`
Per-repo, outside the code, never committed. All I/O goes through `core.store`
(the only door to the filesystem). `state` is the in-memory source of truth and emits
`comments:changed`.

### D4 — Comments anchored with extmarks (with `end_row`)
Each comment has an anchor extmark that follows the line while editing; the range is
preserved with `end_row`. On `BufWritePost`, positions are re-synced. `lnum`
is recomputed from the extmark; `_extmark_id` is runtime and is not persisted.

### D5 — Compare against HEAD (last commit)
The views compare `current buffer (in memory) vs HEAD`. It shows everything
uncommitted (staged + unstaged + unsaved). Explicit user decision
over "index" or "base branch". Note: it does not match gitsigns, which compares against
the index.

## Views

### D6 — No diffview (ugly), Neovim's native diff for the split
The user rejected the diffview plugin. The split uses the **native diff mode**
(`:diffthis`), which aligns with filler, highlights and syncs scroll/mouse per
hunk, and re-diffs itself live.

### D7 — VSCode-style alignment: `linematch` + `histogram` + `inline:char`
Without `linematch`, the diff stacks the deleted and added blocks without aligning
the common lines (a visual "everything changed"). We force in `diffopt` (preserving the
user's flags): `linematch`, `algorithm:histogram`, `indent-heuristic`,
`inline:char` (to highlight the exact text that changed). `filler` for the
filler.

### D8 — Peek as VIRTUAL LINES, not a float
Long iteration: a floating window ALWAYS floats and "follows" the user. It was
changed to **virtual lines inserted below the block** (GitHub inline style):
it is part of the code flow, takes up space, moves with the scroll and does not follow
the cursor. `<leader>rp` is a per-comment toggle; several at once.

### D9 — GLOBAL, permanent view mode
The mode (normal/inline/split) is global (applies to all files, VSCode
style) and follows the active file. Review is a **permanent** mode: the 3
views are its modes, there is no "exit review". The `active` flag was removed.

### D10 — HEAD panel with `winfixbuf`
In the split, the HEAD panel (left) is a read-only scratch with `winfixbuf`
so that NO files can be opened in it. Original bug: when switching files, the
focused column was "hijacked". Now files always open in the
editing column and HEAD follows the file.

### D11 — Never compact lines: folds open in the repo
The native diff folds the unchanged lines ("+-- N lines"), and the user's
folds plugin does too. In repo files, `foldenable=false` + `foldlevel=99` are
forced in the 3 views. It is plugin-agnostic (native options), it does not touch
the folds plugin. Outside the repo nothing is touched.

## Comments: visuals and UX

### D12 — Telling comments apart: alternating background color + per-color bracket
The background alone did not distinguish adjacent comments. The tone alternates
(`ReviewCommentLine`/`Line2`) and the gutter bracket uses a cyclic palette of
6 colors (one per comment).

### D13 — Gutter with nested brackets via `statuscolumn`
The sign column only allows 1 sign per line → it is no good for nesting. The
`statuscolumn` of the repo windows is replaced to draw one bracket
for EACH comment that covers the line, stacked by depth. It preserves
signs (gitsigns) and number. Only on `buftype==""` of the repo; it never touches
special buffers (neo-tree/terminal) so as not to break them (the `<leader>e` bug).

### D14 — Multi-line popup: submit with Enter (no Ctrl)
The popup starts in insert, Enter inserts line breaks; it is submitted with **Enter in
normal mode**, cancelled with `q`. Before, `<Esc>` cancelled (it deleted what was typed);
that was removed. The user explicitly asked for Enter and to avoid `<C-...>`.

### D15 — List with actions and filter
The quickfix of `:Rl/:Rlf` allows `Enter` (jump and close), `d` (delete), `x`
(resolve), `f` (filter all/open/resolved), `q` (close), with a winbar of
shortcuts.

### D16 — Diff colors: background only, distinguish modified from exact text
No fg or bold (it was oversaturated). Modified line = soft yellow (`DiffChange`);
exact text that changed = red (left, removed) / green (right, added) via
`DiffText`; entire deleted/added line = red/green. Per-column colors with
`winhighlight`.

## Important bugs and their causes

### B1 — Repo root by cwd (not by file)
`git rev-parse` used Neovim's cwd, not the file's directory → "buffer
outside the repo" when opening files whose repo was not the cwd. Fix: `git.root(bufnr)`
resolves from the file's directory, with a fallback to cwd.

### B2 — CRLF: "everything changed"
`git show HEAD:file` returns `\r` in CRLF files, but Neovim strips it in
`fileformat=dos` → every line differed by the `\r` → everything marked as a change.
Fix: `head_content` normalizes CRLF (strips the trailing `\r`).

### B3 — Misaligned diff when switching files
When reusing the HEAD buffer and re-diffing after switching files, residual diff
state was left in the tab → the diff paired lines wrongly (identical lines as a change).
Fix: `diffoff!` cleans the tab before rebuilding, and a fresh scratch is always used.
In addition, there is no re-diff when reusing the same file.

### B4 — `E855` when closing a buffer with the split open
Closing a window inside the `WinClosed` autocmd aborts the command. Fix:
defer the close with `vim.schedule`.

### B5 — Cache leaks from closed buffers
The per-`bufnr` caches grew with every opened file. Fix: release them in
`BufDelete/BufWipeout` (and `_prev` in `WinClosed`).

### B6 — Split scroll
Iteration: `scrollbind` did not propagate the mouse wheel; manual sync through
`WinScrolled` caused jerks/bounces. The native diff (D6) solved scrolling
natively and the manual sync was discarded.

## Other decisions

### D17 — Sidebar reuses neo-tree, does not reimplement it
`changed` = `git_status`, `all` = `filesystem`. `<leader>rs` toggles. It opens with
the folders closed (`close_all_nodes`). Expanding/closing/revealing is done with
native neo-tree (`z`/`Z`, `:Neotree reveal`); review does not wrap them so as not to
grow more than needed.

### D18 — Export grouped by file
Agent-ready markdown: `## <path>` per group, sorted by file+line,
continuous numbering, `path:lnum` anchor, excludes resolved ones.

### D19 — User-facing texts in English
Everything visible to the user (notifications, hints, winbar, titles) is in English, and
the instructions say "Enter" (not "CR"). Code comments remain in
Spanish.

### D20 — Centralized lowercase aliases
`plugin/review.lua` defines `cnoreabbrev` (rcm, rl, rv, rs, …) in a single place,
not in each feature. The capitalized commands and their `:Rx` aliases are real
commands; the lowercase ones are abbrevs.

### D21 — agent RPC (implemented)
The `agent` feature (native RPC bridge) was implemented according to `roadmap.md` §1 /
`plans/05-agent.md`. It remains **disabled by default** (`features.agent.enabled`)
because it exposes a remote write surface.

### D22 — AUTO reconciliation by minimal patch by diff
The code is written by the agent to disk (outside nvim); only the comments
go through nvim. For Neovim to learn about the changes on disk and re-anchor the
comments, **AUTO** was chosen (not a manual `:edit!` like tuicr): a
`vim.uv.fs_event` watcher with debounce detects the change and applies a **minimal patch**
(`vim.diff` result_type=indices → `nvim_buf_set_lines` from bottom to top). That way
the extmarks re-anchor themselves by gravity, without manual remapping. Unsaved
changes are never overwritten (`modified` → `conflict`, with `:ReviewReload` as a fallback).
Safety net: `anchor_text` marks `stale` if the anchored line stopped
matching. Coordination with `comments` through the `buffer:reconciled` event (the
no-dependency rule between features is intact).

### D23 — Re-render comments on `comments:changed`
`comments` subscribes to `comments:changed` to re-render the open repo
buffers (before, it only did so on `BufEnter`), so the comments the agent adds
over RPC appear live. Before repainting it does `sync_positions` so as not to
relocate extmarks to their old `lnum` and lose the gravity displacement.

### D24 — Manually closing a split column switches to the normal view
User decision (2026-10-28). Manually closing either of the two columns
of the split (the HEAD one, the editing one, the tab that contains them or the
code window that held the pair) is taken as "I don't want a split": the other
column is closed and the global view switches to `normal`. Before, the pair reappeared on the
next `BufEnter` (changing focus or file), meaning the user's action
undid itself. Closes made by the plugin itself (`teardown` when
switching view or file) do not count: they release the session before closing the
window, so `on_win_closed` does not recognize it. Verified by
`tests/e2e/split_windows.lua` (W10-W16).

### D25 — The peek is a floating card (replaces D8)
D8 described the peek as virtual lines; the code made it a centered float
again (`comments/mode.lua`, `open_peek_float`), and `commands.md`
documents it that way. One card at a time; `x`, `d` and `e` act on the
comment it shows, by id.

### D26 — Git caches are invalidated when focus returns
`git commit`, `git mv`, `git add` or a `checkout` done outside Neovim change
HEAD or the renames without touching the open files, and the caches (root per
directory, renames map, inline and scrollbar HEAD) went stale: the
view kept marking as a change what was already committed. On `FocusGained` they are emptied
and the view is re-applied. Cost: one `git show` per visible buffer on return. The
renames map stopped being emptied in B22: it is recomputed only if git changed.

## Quality review (2026-10-28)

Bugs found by `lua-language-server`, `jscpd` and a review by axes
(security, integrity, performance, duplication, practices), fixed with tests.

### B7 — comments.json non-atomic and corrupt file treated as empty
`io.open(p, "w")` truncates before writing: a cut in the middle left the file
empty, `load()` took it as "no comments" and the next `persist()` overwrote
it. Fix: `write_json` writes to `.tmp` and does `fs_rename` (atomic),
checking `write`/`close`; an unreadable JSON is set aside as
`comments.json.corrupt-<date>` with a warning. Tests: `tests/core/store_spec.lua`.

### B8 — Comments were saved in the repo of the cwd at that moment
`store.path()` resolved the cwd on every save: after `:cd` to another repo, repo A's
list was written to B. With nvim open outside a repo, `persist()`
failed silently. Fix: `state` pins the root on load and saves there;
`DirChanged` saves the previous repo and loads the new one (`state.switch_root`); a
failed save warns once. Tests: `tests/core/state_spec.lua`.

### B9 — Two `git diff -M` for each new file
`rename_source` launched two full diffs per file (120-150 ms in FastCase
with base `HEAD~20`) and kept only the entry for that file. Fix: one
destination→origin map per repo and base, computed once. Tests:
`tests/core/git_spec.lua`.

### B10 — The agent's RPC API did not validate input
A text, table or `null` `lnum` was saved and broke the render (and the gutter, which
Neovim reset with E5108) on every startup; `context()` read files outside the
repo with `../` and iterated over ranges without a cap (2e7 lines = 741 ms and 60 MB); the
client could set `id`, `resolved` or sign as `user`. Fix: validation at the
edge (types, ranges, relative paths without `..`, text ≤ 64 KB, author ≠ `user`),
field allowlist, `realpath` confined to the repo and a cap of 500 lines;
`buf_for_path` compares by `rel_path` (symlinks and per-file root, as in B1).
Tests: `tests/agent/rpc_spec.lua`.

### B11 — Cursor actions with overlapping comments, and file peek
`find_at` returned the first comment by insertion order and the peek the most
specific: the peek's `e` edited a different comment. The peek of a file comment
failed by concatenating `lnum = nil`. Fix: a single criterion (the most
specific), edit by id from popup and peek, "file" title. Tests:
`tests/comments/mode_spec.lua`.

### B12 — `cnoreabbrev` expanded in any position
`:%s/rl/x/g` became `:%s/Rl/x/g` and `:g/rt/d` deleted the lines with "Rt". Fix:
`<expr>` abbreviation that only expands when the command line is the alias.

### B13 — Split window options leaked to the global value
`vim.wo[win].x = v` without `[0]` also changes the global value: new
windows were born with the split's folds and highlighting, against D11. In addition
`restore_main` restored `foldenable=false` as `true` (`false or true`). Fix:
`vim.wo[win][0]` and explicit restoration. Tests:
`tests/e2e/split_windows.lua` (W7).

### B14 — Dead agent watcher, silent conflict, corrupted latin1
If the file disappeared for more than 150 ms (checkout), the `fs_event` was not
re-armed and stayed registered, so it was never repaired. A conflict (unsaved
changes) was discarded without warning. `readfile()` on a latin1 file put invalid
bytes into the buffer. Fix: retries on re-arm and `detach` if it does not come back;
conflict warning once per buffer; non-UTF-8 files are not reconciled.
Tests: `tests/agent/watch_spec.lua`.

### B16 — The export mixed replies with pending items and changed order
The agent's replies came out as numbered items, so when pasting `:Rya` the
agent received its own replies as tasks; `table.sort` is not stable and
several comments on the same line changed number between exports.
Fix: replies are indented under their comment (`↳ author: text`) and the
order breaks ties by creation. Tests: `tests/export/markdown_spec.lua`.

### B17 — comments.json was rewritten when opening or saving any file
`BufReadPost` and `BufWritePost` always called `persist()`, even if the file
had no comments. Fix: only if the buffer has comments.

### B18 — A new comment landed on the old line if the file changed
The popup captured `lnum` when opened; if the agent inserted lines while
typing, the comment was anchored to the old number. Fix: the range is anchored with
temporary extmarks while the popup is open. Tests:
`tests/comments/mode_spec.lua`.

### B19 — Neovim crashed (SIGSEGV) when closing a split column with markdown
Reported by the user on 2026-10-28: in split, switching files closed
Neovim. Core dump: `f_win_findbuf` ← `DiffUpdated` autocmd ← `ex_diffupdate` ←
`diff_check_with_linestatus` ← `win_close`. Mechanism: `diff_check` runs
`ex_diffupdate()` if the tab's diff is invalidated, before checking whether
the window is in diff mode; when closing a window (the plugin's HEAD, or
any diff window with `:q`), Neovim resizes the neighbor, recomputes the
diff and fires `DiffUpdated` with the window list half changed. The
render-markdown callback (attached to the markdown buffer) calls `win_findbuf`
there and Neovim reads invalid memory. It is a Neovim bug: reproduced on 0.12.1 and
0.12.6, and with the review-mode and render-markdown code from before the
quality review; without render-markdown's autocmd it does not crash.
Fix on our side, in two places:
- `close_head_win`: before closing the HEAD column it turns off its diff, recomputes with
  `:diffupdate` at a safe moment and closes with `DiffUpdated` in
  `eventignore` only during the close.
- `guard_diff_close`: on `WinClosed` (runs before the window is removed from the
  layout) of any window in diff mode, it ignores `DiffUpdated` until the
  next tick. It covers the user's `:q`, which does not go through the plugin.
Tests: `tests/e2e/split_markdown.lua` (switching files in both directions,
switching view from each column, closing each column, closing the tab;
and that `eventignore` is left clean).

### B20 — A file came back in diff mode after leaving the split
Reported on 2026-10-28: after leaving the split, `<leader>rn/ri/rv` "did not change
the view". `'diff'` and the window options are stored per buffer in each
window. If the pair was torn down because the window switched to showing another file,
`diffoff` turned off the diff of the NEW file; the one for the pair's file stayed
stored and came back on (with the split's green highlighting) when that
file returned to the window, so in normal or inline it still looked like a
diff. It was also in the code from before the quality review; it was not visible before because
Neovim crashed on that very file switch (B19).
Fix: when tearing down the pair, if the window already shows another file, a note is made of
`[window][pair buffer]`; when that buffer returns to that window,
`clear_stale` turns off its diff and restores folds and highlighting. Only diffs
set by the split are touched: a user's `:diffthis` is not turned off. Tests:
`tests/e2e/split_windows.lua` (W18-W20).

### B21 — A file new relative to the base was not marked
Reported on 2026-10-28 in FastCase with base `efe1a41`: a file created
after the base (already committed) did not change with any view and the file
tree did not give it a letter. gitsigns painted it entirely green and the statusline
counted it, so each surface said something different.
- `head_content` returns nil if the file is not in the base, and inline and the
  scrollbar took that as "nothing to compare". They now use
  `git.base_lines`, which for a new file returns `{}`: inline paints it
  entirely as added. Files ignored by git are still not marked.
- Split does not change: with a new file it stays in one column, because an empty
  base column adds nothing (rule BR-b7435c0 in nvim-config).
- The file tree (`filesystem`) queried plain `git status`, and in the
  base the file was already committed. `neotree_exec` now passes `git_base` to
  both tree modes and `base:changed` re-applies the base to the one in
  view. The file shows `N`. `<leader>e` measured 13-68 ms (before 7-53 ms, with
  the same first-open noise).
Tests: `tests/core/git_spec.lua` and `tests/views/inline_spec.lua`.

### B22 — Opening a file new relative to the base froze for up to 700 ms
Reported on 2026-10-28 ("sometimes it takes a long time when switching files").
`rename_source` needs the base's renames map, and building it costs two
`git diff -M` of ~115 ms each in FastCase against `efe1a41`. They ran
synchronously the first time a file that does not exist in the base was opened,
and `FocusGained` threw the map away, so on returning from the browser they were paid
again: 272–708 ms.
- The map is no longer thrown away when focus returns. It carries a fingerprint (`repo_stamp`): mtime
  and size of the index, of HEAD and of HEAD's reflog, read with `fs_stat` without
  launching processes. A `git mv`, a commit, a checkout or a reset done outside
  changes it, and the map is recomputed. Editing files does not change it, nor does it need to,
  because a rename without `git add` is not a rename to git.
- `prefetch_renames` launches the diffs in the background (`vim.system` with a callback)
  after restoring the base at startup, when switching base and when focus returns
  if the fingerprint changed. `rename_source` uses the map if it is ready; if the
  computation is in progress, it waits for those same processes instead of launching others.
- Result: opening `pagination.constants.ts` for the first time went from 319–493 ms
  to 12–25 ms, and on returning from the browser from up to 708 ms to 8–10 ms.
Tests: `tests/core/git_spec.lua` (fingerprint, focus without changes, `git mv` and commit
done outside, computation reused).

### D27 — Inline view with debounce in insert
`inline.render` recomputes the diff of the whole buffer: 40 ms per keystroke with 10,000
heavily changed lines. On `TextChangedI` it is batched with a single 80 ms timer;
on `TextChanged` (outside insert) it remains immediate.

### B15 — Deletion at the end of the file painted over the last line
The inline view anchored the deleted lines above `new_start`, clamped to the
last line: a deleted "d" at the end appeared before "c". Fix: below the
last line. Tests: `tests/views/inline_spec.lua`.
