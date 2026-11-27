# Next steps (roadmap)

Design plan for what comes next. It is not implementation: it is the "how I would do it and
why", to discuss before coding.

---

## 1. `agent` feature — bidirectional bridge with the AI agent

Goal: let an external agent (Claude Code, etc.) **read, comment,
reply to, resolve and clean up** comments, and apply code changes **live**
on the same Neovim instance you are using, without collisions.

### 1.1 Transport: native Neovim RPC (no custom sockets)

- The "server" is the same `nvim` process (or a headless one with `--listen`).
- The agent invokes functions exposed in `_G.ReviewAgent` via
  `nvim --server <sock> --remote-expr 'luaeval("ReviewAgent.xxx(_A)", <json>)'`.
- No new dependencies, no HTTP. Disabled by default (`opts.agent.enabled`),
  because it exposes a remote write surface.
- All functions are **serializable**: they receive/return `string` (JSON) or
  primitives; never extmark ids or raw Lua tables.

### 1.2 Separation of responsibilities

Clear rule:
- **The agent writes the code to disk FREELY** (with its own
  tools), OUTSIDE Neovim. review.nvim does NOT edit code and does NOT interfere in
  how the agent modifies files.
- **The comments DO go through Neovim** (via `_G.ReviewAgent`, on top of
  `core.state`), which is the single source of truth for comments.

So the problem is NOT "editing code without collisions" (the agent handles that
on disk), but this: **when the agent changes a file on disk, Neovim has to
find out, reload the buffer and RE-ANCHOR the comments** (because an edit
on disk does NOT move the buffer's extmarks).

### 1.3 Reconciliation: detect changes on disk and re-anchor comments

**Decision: AUTO** (reload by itself, without the user pressing anything) — it is a thousand times
better UX. tuicr chose manual (`:e`) because it re-fetches remote PR diffs and has
no extmarks; we DO have extmarks and control of the local buffer, so
we can do auto properly. The manual `:ReviewReload` stays as a **fallback** for
the only case auto cannot resolve on its own (conflict with unsaved
changes). To make auto solid, it has to be done like this:

**Comments (state):** there is no real concurrency. `--remote-expr` calls run
serialized in the main event loop → agent and user mutate `core.state`
one at a time, with no data race. Each mutation emits `comments:changed` and persists.

#### The key technique: apply the disk change to the buffer as a minimal PATCH

The naive mistake is doing `:edit!` (full reload): that **destroys all the
extmarks** → they have to be re-anchored by hand and it is always fragile. Instead:

1. Read the NEW content from disk (without touching the buffer yet).
2. Diff the **current buffer lines (old) vs disk (new)** with `vim.diff`
   (`result_type = "indices"`) → hunks.
3. Apply **only those hunks** to the buffer with `nvim_buf_set_lines`/`set_text`
   (from bottom to top so as not to invalidate indices).

Result: the extmarks in the UNCHANGED zones **do not move**, and in the zones
with insertion/deletion **they shift by themselves** — exactly as if the agent had
edited inside the buffer.

> **Empirically validated (nvim 0.12):** inserting lines above an extmark
> moves it down (row 4→5); `set_text` without changing the number of lines does not
> move a later extmark (2→2); deleting above moves it up (5→4). It was also
> confirmed that `vim.uv.new_fs_event` and `vim.diff` exist. The patch-by-diff technique
> re-anchors the comments by itself. That is, **the comments are re-anchored automatically
via extmarks, without manual remapping**. In addition:
- The buffer is left `nomodified` (it matches disk).
- The diff views (inline/split) recompute by themselves (they compare buffer vs HEAD).
- It lands in the undo tree (you can undo the agent's change with `u`).

#### Detection (make it reliable, not dependent on focus)

`autoread` + `FileChangedShell` only check on certain events (focus,
CursorHold) → NOT enough if the agent edits in the background. Therefore:
- **Active watcher:** `vim.uv.fs_event` (or `fs_poll` as a fallback) for each open
  repo file buffer. On detecting a change → run the patch (above),
  with **debounce** (~100–200 ms) to group the agent's write bursts.
- **Agent signal:** `ReviewAgent.notify_changed(path)` forces the patch of that
  path immediately (an explicit, cheap path). Not mandatory, but it speeds things up.
- Close the watcher on `BufWipeout`/`BufDelete` (no leaks, like the other caches).

#### Conflict: buffer WITH unsaved changes

The only case where auto must NOT act on its own: you edited and did not save, and the
agent touched that file on disk → they diverged. **Never overwrite yours:**
- If the buffer is `modified` → do NOT apply the patch. Warn (`vim.notify`) and
  offer: view diff (buffer vs disk), apply anyway, or ignore. This is where the manual
  `:ReviewReload` comes in.
- **Prevention:** the agent queries `ReviewAgent.is_modified(path)` BEFORE
  editing; since it writes freely to disk, it should avoid (or warn about) the files that
  you are editing without saving.

#### Comments that fall inside a change

Even with the patch, a comment whose line the agent rewrote entirely
may end up misplaced. Safety net:
- **`anchor_text`** (a tuicr idea, `LineContext.content`): save the text of the
  commented line; if after the patch the extmark no longer lands on that text (nor
  near it), mark the comment **`stale`** with a visual indicator so that you
  review it, instead of showing it confidently in the wrong place.
- Record the HEAD-SHA at creation so as to warn if HEAD changed a lot.

#### Summary of the auto flow
disk changes → watcher (debounce) or `notify_changed` → if buffer `modified`:
warn + offer (do not overwrite) · otherwise: minimal patch by diff → extmarks
re-anchor by themselves → mark the doubtful ones `stale` (by `anchor_text`) → `nomodified` →
views recompute. All without the user doing anything.

**Notification:** when the agent comments/replies/resolves, a discreet `vim.notify`
(and an optional jump/decoration) so that you know what it touched.

### 1.4 `_G.ReviewAgent` API (proposal)

Only comments and coordination. **The code does NOT go through here** — the
agent writes it to disk with its tools.

Read:
- `list(filter?)` → JSON of comments. `filter`: `{ author?, path?, resolved?, answered? }`.
- `get(id)` → one comment (with its thread).
- `context(id)` → the comment + the lines of code it spans (so that the
  agent understands what it refers to without guessing).

Writing comments:
- `add({ path, lnum, end_lnum?, text })` → creates a comment with `author="agent"` (or the
  model). Returns id.
- `reply(parent_id, text)` → creates a comment linked to another (`reply_to`), typically
  to **reply to/justify** a comment of yours.
- `resolve(id)` / `unresolve(id)`.
- `update(id, text)`.
- `delete(id)`.
- `clean_resolved(path?)` → deletes the resolved ones (bulk cleanup).

Coordination with editing on disk:
- `is_modified(path)` → `boolean`: is that file open in Neovim with UNSAVED
  changes? The agent queries it BEFORE editing on disk, so as not to collide with
  something you are editing (see 1.3.3).
- `notify_changed(path)` → the agent signals that it finished editing that file on
  disk; Neovim does `checktime`, reloads and re-anchors the comments (see 1.3.2).
- `servername()` → the current socket (so that the agent knows where to connect).

### 1.5 Agent comments: authorship, threading, filters

Extension of the data model (backward compatible):
```
comment = {
  id, path, lnum, end_lnum, text, resolved, created_at,
  author,       -- "user" | "agent" | "<model-id>"
  reply_to?,    -- id of the parent comment (reply/justification)
}
```

- **Visible authorship:** the agent's comments are painted differently (🤖 icon /
  own color in gutter and badge) to tell them apart from yours.
- **Threading (linked replies):** `reply_to` links the agent's reply to
  your comment. In the **peek** you see the full thread (your comment + the
  agent's reply/justification below it). In the **list** it is marked whether one of your
  comments **has been answered** and by whom.
- **Filters** (extend the list's `f` and `list(filter)`):
  - by author: mine / agent's / all.
  - by state: open / resolved / all.
  - **answered / unanswered**: so that you see at a glance which of your
    questions already have a justification from the agent and which do not.
- **Typical flow:**
  1. You leave comments (questions, requests).
  2. `:Rya` copies the agent-ready markdown and you give it to the agent (or the agent
     reads it via `ReviewAgent.list`).
  3. The agent **edits the code on disk on its own** and, over RPC, **replies
     linked** to each comment (`reply`) with the justification, optionally resolves it,
     and signals `notify_changed(path)` for the files it touched.
  4. Neovim reloads those files and re-anchors the comments (1.3.2). You see it
     live: the badge/gutter shows that there is an agent reply; you open the peek and
     read the justification; you accept (it is left resolved) or reopen.
  5. `clean_resolved` to clean up what is closed.

### 1.6 Extra ideas for a better flow

- **"Answered by agent" marker** in the gutter (different color/icon) to
  quickly jump to what was answered.
- **`stale` marker** on comments whose line fell inside a zone that the
  agent changed on disk (uncertain re-anchoring) → you review them.
- **History per comment:** save the replies as a thread ordered by date.
- **"Accept reply":** a command that marks the thread as resolved and (optionally)
  archives it.
- **Session notes:** the agent can leave a "summary" comment at file level
  (lnum=1) with what it did.
- **Anti-echo:** when re-anchoring after a reload, do not re-emit events in a loop.

### 1.7 Suggested implementation order
1. Model: add `author`, `reply_to`, `anchor_text`, `stale` to `core.state`
   (with defaults; backward compatible).
2. Render/gutter/peek: distinguish author + show threads + `stale` mark.
3. List: filter by author and by answered/unanswered.
4. AUTO re-anchoring (the heart of the flow): watcher (`vim.uv.fs_event`, debounce) +
   `notify_changed` → **minimal patch by diff** to the buffer (extmarks re-anchor
   by themselves) → `anchor_text` + `stale` mark for the doubtful ones → conflict if
   `modified` (do not overwrite). Manual `:ReviewReload` as a fallback.
5. `rpc.lua`: list/get/context/add/reply/resolve/unresolve/update/delete/
   clean_resolved + is_modified/notify_changed.
6. `init.lua`: `_G.ReviewAgent`, `opts.enabled`, notifications.
7. Protocol docs + `--remote-expr` examples.

### 1.8 Ideas from tuicr (reference, do not copy)

Reviewed `~/Dev/tuicr-fork` (Rust). It validates a large part of our design and contributes:

- **Free-form `author`** (`src/model/comment.rs`): the agent passes its name
  (`--username "Claude …"`), the human falls back to `"user"`. Backward compatible (old JSON
  rehydrates as `"user"`). → Identical to our `author` field.
- **Content anchor** (`LineContext { new_line, old_line, content }`):
  they save the line's **text** in addition to the number. It is exactly our idea
  of `anchor_text` to re-locate after a change on disk. → Adopt.
- **`line_range`** (start/end inclusive) for multi-line. → We already have it
  (`lnum`/`end_lnum`).
- **Comment types** (`Note`/`Suggestion`/`Issue`/`Praise`/`Custom`): a future
  option (not a priority now).
- **Remote lifecycle** (`LocalDraft`/`PushedDraft`/`Submitted`, `remote_*_id`,
  `commit_id`): it is for integrating with GitHub PRs. It does NOT apply to our case
  (local review of the working tree), but it shows the pattern if we ever
  integrate a forge.

**Key context difference:** tuicr reviews a **PR diff**, so it anchors
in diff-space (side Old/New + old/new lineno) against a fixed diff. We
review the **live working tree**, which is why we use **extmarks** (which follow the
line while editing in the buffer) + **remapping by diff** and **content anchor**
when the change comes from disk (agent). Different context, same family of
ideas.

---

## 2. Clean up the Neovim config

Goal: keep only the plugins you use, understanding dependencies, without breaking anything.

### 2.1 Inventory
- List everything declared in `~/.config/nvim/lua/plugins/*.lua`.
- For each plugin: do you use it? (a command/keymap/event that triggers it) or is it a
  dependency of another?

### 2.2 Classify
- **Direct** (you use it): editor, LSP, treesitter, telescope, neo-tree, etc.
- **Dependency** (another one requires it): e.g. `plenary` (telescope/neo-tree/review),
  `nui` (review popups), `nvim-web-devicons`, `window-picker` (neo-tree).
  These are **not deleted** even if you do not "use" them directly.
- **Candidate for removal:** not referenced by anyone and you do not use it.

### 2.3 How to handle dependencies (lazy.nvim)
- If a plugin is in another's `dependencies = { ... }`, lazy installs it by itself; there is
  no need to declare it separately.
- Before removing something, check whether it appears as `dependencies` in other specs.
- `:Lazy` shows the tree and who loads what; `require("lazy").plugins()` gives the list.

### 2.4 Safe method
1. Do the inventory and mark candidates (without deleting).
2. Disable (do not delete) the candidates with `enabled = false`, one or a few
   at a time.
3. Restart, use it normally for a while, see if anything is missing.
4. If all is well, delete the spec; if something breaks, revert.
5. `:Lazy clean` to remove the ones that are no longer declared.

### 2.5 Deliverable
A report: table of plugins (direct / dependency / candidate for removal), with the
reason for each and what depends on what. It can be generated by reading
`lua/plugins/*.lua`. **It can be done as a separate task whenever you want** —
let me know and I will build the real inventory of your config.