# Base-aware sidebar — keep neo-tree design, reflect the review base

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development or executing-plans. Steps use checkboxes.
> **Context:** `docs/commands.md` (Base section), `features/base/init.lua` (selector + `base:changed` event), `features/sidebar/init.lua` (opens neo-tree). Hard rule: features coordinate through core events, never `require` another feature.

**Goal:** make `<leader>s` (review's "changed" sidebar) show the changed files **relative to the base selected** with `:ReviewBase` (`core.git.base_ref`: `HEAD`, `:` index, or a commit), **keeping the current neo-tree design/UX identical** (tree, icons, indent guides, `z`/`Z` expanders, git status column, `●` marker for open files, purple background of the current file, highlights). When the base changes (`base:changed`), the sidebar refreshes by itself.

**Architecture:** neo-tree already knows how to render the git status tree; the only thing it lacks is **which base** to compare against. Its API `require("neo-tree.git").status(path, base_lookup, …)` and `.status_async(path, base_lookup, opts)` accept a `base_lookup` = `table<worktree_root, ref>`, but neo-tree's sources call it with `nil` (see `sources/filesystem/lib/fs_scan.lua:58-62` and the `git_status` source). The preferred strategy (Route 1) is to **inject** that `base_lookup` with the review base, without touching the design. Route 2 (fallback) is a custom source if rendering vs-base does not work.

**Tech Stack:** Lua, Neovim 0.12, neo-tree v3.x (in `~/.local/share/nvim/lazy/neo-tree.nvim`), review-mode.

## Global Constraints
- **Do not change the design**: renderers, `opened_marker` (●), purple background of the current file (`after_render` + `NeoTreeCurrentFileBg`), highlights (onedarkpro), netrw hijack, changed/all toggle — everything stays the same. They live in `~/.config/nvim/lua/plugins/neotree.lua` and `~/.config/nvim/lua/plugins/onedarkpro.lua`.
- **Do not break the default** (base = `HEAD`): with base HEAD/index the sidebar must look and behave **exactly** as it does today.
- review-mode: the base-aware logic lives in `features/sidebar` (which already opens neo-tree) or in a new review module; it coordinates through `core.events` (`base:changed`). Never `require` another feature.
- User-facing texts in English. Commits only by El-Vitas, no trailers. After each change run the tests (`nvim --headless -c "PlenaryBustedDirectory tests/ {minimal_init='tests/minimal_init.lua'}" -c "qa"`, they must stay green — 105 today).

## Files to read first (current state)
- `lua/review/core/git.lua` — `base_ref`, `set_base`, `head_content`, `changed_files` (**already** base-aware).
- `lua/review/features/base/init.lua` — modal selector; emits `core.events.emit("base:changed", {ref})`.
- `lua/review/features/sidebar/init.lua` — `open_sidebar(kind)`: changed → neo-tree source `git_status`; all → `filesystem`; `<leader>s` toggles.
- `lua/review/features/views/init.lua` + `views/scrollbar.lua` — already react to `base:changed` (model to imitate).
- `~/.config/nvim/lua/plugins/neotree.lua` — the DESIGN (renderers, `opened_marker`, `after_render` purple background, hijack, refresh autocmds).
- neo-tree internals:
  - `~/.local/share/nvim/lazy/neo-tree.nvim/lua/neo-tree/git/init.lua` — `M.status(path, base_lookup, …)`, `M.status_async(path, base_lookup, opts)`, `change_worktree_git_status(root, status, base, status_diff_base)` stores `worktree.status_diff[base]`.
  - `.../sources/git_status/init.lua` and `.../sources/filesystem/lib/fs_scan.lua` — they call `git.status(_async)` with `base_lookup = nil`.

---

### Task 1 (SPIKE): does neo-tree render the status vs base if we pass it a base_lookup?
Without this we do not know whether Route 1 is enough.

- [ ] **Step 1:** With a test repo and neo-tree loaded, manually call:
  `require("neo-tree.git").status(worktree_root, { [worktree_root] = "<old-commit>" })` and then open the git_status source; inspect `state.git_status` / `worktree.status_diff[base]` (see `change_worktree_git_status`). Confirm whether the tree shows the files that differ vs `<old-commit>` (not just `git status`).
- [ ] **Step 2:** Determine the exact point where the render decides which status to use (plain vs `status_diff[base]`). Look in `sources/git_status` and in the renderer's `git_status` component for how it reads `state.git_status`.
- [ ] **Decision:** if the render uses `status_diff[base]` when there is a base → **Route 1**. If it ignores the base when rendering → **Route 2**.

---

### Task 2 — Route 1 (preferred): inject base_lookup into neo-tree's git status
Goal: make neo-tree compute the status vs `core.git.base_ref` without touching the design.

**Files:** `lua/review/features/sidebar/init.lua` (or new `features/sidebar/base_patch.lua`).

- [ ] **Step 1:** In the sidebar's `setup`, wrap `require("neo-tree.git").status` and `.status_async` exactly **once**: if `base_lookup` is `nil` and `core.git.base_ref ~= "HEAD"`, build `base_lookup = { [worktree_root] = ref }` (ref = `base_ref`, and for `:` the index base — verify how `diff_name_status_job` expects it; if index does not apply, treat `:` as "no base" = normal git status). Keep the original function and delegate. Idempotent (no double-wrap).
- [ ] **Step 2:** The `worktree_root` for the base_lookup: derive it from the `path`/cwd as neo-tree does (`find_worktree_info`) or from `core.git.root()`.
- [ ] **Step 3:** Subscribe to `core.events.on("base:changed", …)` → if a neo-tree window of the git_status source is visible, `Neotree refresh` (recomputes with the new base). Reuse the views/scrollbar pattern.
- [ ] **Step 4 (manual verification):** repo with several commits. `<leader>s` (changed) with base HEAD → identical to today. `:ReviewBase` → pick an old commit → `<leader>s`/refresh shows the files changed **since that commit**, with the **same** design (icons, `●`, purple background, M/A/D status). Go back to HEAD → returns to the normal git status.
- [ ] **Step 5:** Confirm that `base = ":"` (index) and `base = HEAD` do not break (current behavior intact). Run the suite (105 green).

---

### Task 2' — Route 2 (fallback): custom source `review_changed`
Only if Task 1 concludes that the render does **not** respect the base.

**Files:** `lua/review/features/sidebar/source.lua` (new), `features/sidebar/init.lua`.

- [ ] **Step 1:** Implement a neo-tree source (interface: `name`, `display_name`, `setup(config, global_config)`, `navigate(state, path)`, `default_config`). Build the tree from `git diff --name-status <base>` (+ untracked) → file/directory nodes with their status (M/A/D). **Reuse** the renderers/components of the `filesystem`/`git_status` source so the design is identical (indent, icon, name, `opened_marker`, git_status, diagnostics).
- [ ] **Step 2:** Register the source in the user's neo-tree config: `sources = { "filesystem", "git_status", "review_changed" }` (+ its `review_changed = {...}`). Since this is user config, document the snippet in `docs/commands.md` and in `~/.config/nvim` (the plan applies it there).
- [ ] **Step 3:** `features/sidebar/init.lua`: `open_sidebar("changed")` opens the `review_changed` source instead of `git_status`. Keep `all` = filesystem and the `<leader>s` toggle.
- [ ] **Step 4:** `base:changed` → refresh the source. Manual verification same as Route 1 Step 4. Suite green.

---

### Task 3 — Integration and toggle
- [ ] Keep the `<leader>s` changed↔all toggle and the current auto-close/behavior.
- [ ] Ensure that the `●` (opened_marker) and the purple background of the current file keep working in the base-aware sidebar (same components/`after_render`).

### Task 4 — Docs
- [ ] `docs/commands.md`: note that the `changed` sidebar now respects the base.
- [ ] `docs/decisions.md`: new D — how the sidebar was made base-aware (Route chosen and why).

## Verification / Self-review
- Identical design with base=HEAD (compare visually with today).
- With base=commit: the tree shows the changes vs that commit, same look.
- `base:changed` refreshes the sidebar without flicker or leaks.
- Suite 105/105 green. Without breaking views/scrollbar/gitsigns (which are already base-aware).
- Prefer Route 1 (minimally invasive, design guaranteed). Route 2 only if the spike requires it.
