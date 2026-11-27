# Performance and RAM

review runs logic on very frequent events (`BufEnter`, `TextChanged`,
render). These are the optimizations that keep it fast and lightweight, and how
memory leaks are avoided.

## Caches

| Cache | Where | Key | Released |
|---|---|---|---|
| Repo root | `core/git.lua` `root_cache` | directory | `FocusGained` (`git.clear_cache`) |
| Renames vs base | `core/git.lua` `rename_maps` | repo + base (+ `repo_stamp` fingerprint) | `set_base`; recomputed in the background if the fingerprint changes (B22) |
| Root by cwd | `core/store.lua` `_root_by_cwd` | cwd | `DirChanged` (`clear_root_cache`) |
| HEAD (inline) | `views/inline.lua` `_head_cache` | bufnr | `BufReadPost`, `BufDelete`, `BufWipeout`, `FocusGained` |
| HEAD and hunks (scrollbar) | `views/scrollbar.lua` `_head`, `_hunks` | bufnr (+ changedtick) | `BufReadPost`, `BufDelete/Wipeout`, `base:changed`, `FocusGained` |
| HEAD (split) | session `split._session.head` | per session | on close/file switch |
| Gutter ranking/color | `comments/gutter.lua` `_cache` | bufnr | `comments:changed` (full reset), `BufDelete/Wipeout` |
| Previous statuscolumn | `comments/gutter.lua` `_prev` | winid | `WinClosed` |

`FocusGained` empties the root and the HEAD caches because a commit, `git mv` or `checkout`
done outside Neovim leaves them stale without touching the open files
(decisions.md D26). The renames map is not emptied: it costs two `git diff -M` runs of
~115 ms in a large repo, so it is only recomputed, in the background, if the
fingerprint of the index, HEAD or the reflog changed (B22).

**Verified:** opening and closing 40 files leaves **1 entry** in each cache (not
40), and only 1 live HEAD buffer (the scratch uses `bufhidden=wipe`).

## Key optimization: repo root cache

`git rev-parse` is a subprocess, and `rel_path()`/`root()` are called on every
render/BufEnter/sync. Caching the root per directory brought the split reuse sync down
from **3.26 ms to 0.020 ms (≈163×)**. It benefits ALL features (all
of them resolve `rel_path`).

## Split: do not re-diff on reuse

Neovim's native diff **updates itself live** while editing. Our code
does **not** re-diff on the same file:

- On reuse of the same file, it only checks (via `changedtick`, without reading the
  buffer if it did not change) whether it became identical to HEAD again (→ one column). No
  git, no re-diff.
- The split re-syncs only on `TextChanged` (when a change finishes), not on
  every key in insert mode (the native diff is already live there).
- On **file switch** it is rebuilt with `diffoff!` + a fresh scratch (reusing the
  scratch left residual diff state and caused misalignment — see decisions.md).

## Inline: HEAD cached per buffer

`inline.render` runs on every `TextChanged/TextChangedI`. It used to do `git show`
per keystroke; now it caches the HEAD content per buffer (HEAD does not change while
you edit), invalidated when the buffer is reloaded/closed.

## No resource leaks

- Split scratch: `bufhidden = wipe` → destroyed when the window closes.
- `BufDelete/BufWipeout/WinClosed` autocmds release the per-buffer/window
  cache entries.
- Window closing from autocmds (`WinClosed`) is **deferred** with
  `vim.schedule` to avoid triggering `E855` (windows cannot be closed inside
  `WinClosed`).

## Edge cases verified without errors

File outside the repo, new file without HEAD, special buffer (neo-tree/nofile),
large file (pnpm-lock.yaml), 20 consecutive mode switches, 30 files in
inline, closing the buffer with the split open, round trip between files.