#!/usr/bin/env bash
# Creates a DETERMINISTIC synthetic git repo for the e2e tests. Usage: fixture.sh <dir>
# Writes these lines to stdout: C0=<sha>  C1=<sha>  (bases for the driver).
set -euo pipefail
D="${1:?usage: fixture.sh <dir>}"
rm -rf "$D"; mkdir -p "$D"; cd "$D"
git init -q
git config user.email e2e@review.test
git config user.name "review e2e"
git config commit.gpgsign false

mkdir -p src nested/deep
printf 'keep line 1\nkeep line 2\n'      > src/keep.ts
printf 'mod v0 a\nmod v0 b\n'            > src/mod.ts
printf 'to be deleted\n'                 > src/del.ts
printf 'rename me\n'                     > src/ren_old.ts
printf 'deep original\n'                 > nested/deep/f.ts
printf 'stable forever\n'                > src/stable.ts   # NEVER changes (unchanged vs every base)
git add -A; git commit -q -m c0
C0=$(git rev-parse HEAD)

# C1: adds newC1, modifies mod
printf 'brand new C1\n'                  > src/newC1.ts
printf 'mod v1 a\nmod v1 b\nmod v1 c\n'  > src/mod.ts
git add -A; git commit -q -m c1
C1=$(git rev-parse HEAD)

# C2 (HEAD): adds newC2, deletes del, renames ren_old->ren_new, modifies deep
printf 'brand new C2\n'                  > src/newC2.ts
git rm -q src/del.ts
git mv src/ren_old.ts src/ren_new.ts
printf 'deep changed\n'                  > nested/deep/f.ts
git add -A; git commit -q -m c2

# Working tree (uncommitted): modifies keep, untracked, staged
printf 'keep line 1 CHANGED\nkeep line 2\n' > src/keep.ts   # unstaged mod
printf 'i am untracked\n'                    > src/untracked.ts # untracked
printf 'freshly staged\n'                    > src/staged.ts
git add src/staged.ts                                          # staged add

echo "C0=$C0"
echo "C1=$C1"
