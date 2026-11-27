# E2E — git base consistency & sidebar/reveal/toggle

Harness that starts Neovim with the user's REAL config (`-u ~/.config/nvim/init.lua`)
on a **deterministic synthetic repo** (created by `fixture.sh`), drives the real
keymaps and asserts the behavior. Repeatable and never touches real repos.

> Golden rule: passing tests does NOT mean everything works. Think about side cases.

## Fixture (synthetic repo)
Commits:
- **C0 (root)**: `src/keep.ts`, `src/mod.ts`, `src/del.ts`, `src/ren_old.ts`, `nested/deep/f.ts`
- **C1**: add `src/newC1.ts`; modify `src/mod.ts`
- **C2 (HEAD)**: add `src/newC2.ts`; delete `src/del.ts`; rename `src/ren_old.ts`→`src/ren_new.ts`; modify `nested/deep/f.ts`
- **Working tree** (uncommitted): modify `src/keep.ts`; untracked `src/untracked.ts`; staged (git add) `src/staged.ts`

Bases to exercise: `C0` (root/general), `C1`, `HEAD`, `:` (index).

## Cases

### A. effective_base / core
- A1 HEAD → effective_base()==nil
- A2 ":" → nil
- A3 commit → that ref
- A4 set_base("") → base_ref=="HEAD", label nil

### B. head_content / changed_files base-aware
- B1 head_content(mod, C0) == `git show C0:src/mod.ts`
- B2 head_content(newC2, C1) == nil (does not exist in C1)
- B3 head_content(keep, HEAD) == `git show HEAD:src/keep.ts`
- B4 changed_files(C0) contains newC1,newC2,mod,del,ren_new; NOT keep-unchanged-in-commits
- B5 changed_files(HEAD) = only working tree (keep, untracked, staged)

### C. Sidebar open (changed / git_status)
- C1 :ReviewSidebar changed → source==git_status
- C2 git_base_by_worktree == effective_base (nil→EMPTY) for each base
- C3 tree contains added/modified/deleted/renamed vs base
- C4 tree does NOT contain files unchanged vs base
- C5 untracked always shows up (all bases)

### D. Reveal (<leader>E)
- D1 git_status open → cursor on the file (all bases)
- D2 **filesystem open → cursor on the file** (reported bug)
- D3 tree closed → opens and reveals
- D4 file WITHOUT changes vs base, in git_status → no-op (does not switch mode, notifies)
- D5 non-file buffer (buftype!="") → no-op
- D6 file in a nested subdirectory → reveals and expands parents
- D7 reveal after changing base → uses the new base

### E. Toggle (<leader>s)
- E1 closed → changed(git_status)
- E2 changed → all(filesystem)
- E3 all → changed(git_status)
- E4 base preserved after toggles
- E5 from a state opened by restore (does not desync)

### F. Close/reopen (<leader>e)
- F1 preserves source
- F2 preserves git_base
- F3 vs-base files REMAIN in the tree after reopen (neo-tree cache bug)
- F4 reopen after base→HEAD → git_base EMPTY

### G. base:changed live
- G1 with git_status open, changing the base updates the file set
- G2 back to HEAD → plain git status

### H. gitsigns object_name (cache inspection)
- H1 new-vs-base (committed) → object_name = empty blob, untracked=false (solid green)
- H2 untracked → object_name=nil, untracked=true (dotted)
- H3 modified-vs-base → object_name = the base's blob
- H4 with base=HEAD → native behavior (untracked ┆, nothing synthesized)

### I. Views inline/split
- I1 inline: file's head_content == git show base
- I2 split: same
- I3 changing base invalidates and re-renders

### J. Statusline
- J1 HEAD → empty component
- J2 ":" → "index"
- J3 commit → label (subject) WITHOUT mojibake, truncated

### K. Persistence
- K1 save_base/load_base JSON round trip {ref,label}
- K2 compat: old plain file → ref, label nil
- K3 restore ignores a nonexistent ref (rev-parse fails)
- K4 restore of HEAD → does nothing

### L. Side cases / robustness
- L1 file deleted-vs-base (exists in base, not on disk) → in tree as D, reveal skip
- L2 renamed-vs-base → in tree
- L3 base = commit where the file did NOT change → not in tree, reveal no-op
- L4 switch base back and forth N times → consistent
- L5 repo with no changes (base=HEAD, clean working tree) → empty tree, no errors
- L6 invalid base ref passed to set_base → does not break (git show fails → nil)
- L7 agent OFF (default) → does not affect sidebar/base
- L8 open several files and reveal each one

### M. Read-only
- M1 after EVERYTHING: branch, HEAD, git status --porcelain, staged → IDENTICAL (the repo was not touched)
