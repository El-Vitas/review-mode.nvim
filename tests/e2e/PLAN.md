# E2E — git base consistency & sidebar/reveal/toggle

Harness que arranca Neovim con la config REAL del usuario (`-u ~/.config/nvim/init.lua`)
sobre un **repo sintético determinista** (creado por `fixture.sh`), maneja los keymaps
reales y asserta el comportamiento. Repetible y sin tocar repos reales.

> Regla de oro: que pasen los tests NO significa que todo funcione. Pensar side-cases.

## Fixture (repo sintético)
Commits:
- **C0 (root)**: `src/keep.ts`, `src/mod.ts`, `src/del.ts`, `src/ren_old.ts`, `nested/deep/f.ts`
- **C1**: add `src/newC1.ts`; modifica `src/mod.ts`
- **C2 (HEAD)**: add `src/newC2.ts`; borra `src/del.ts`; renombra `src/ren_old.ts`→`src/ren_new.ts`; modifica `nested/deep/f.ts`
- **Working tree** (sin commitear): modifica `src/keep.ts`; untracked `src/untracked.ts`; staged (git add) `src/staged.ts`

Bases a ejercitar: `C0` (root/general), `C1`, `HEAD`, `:` (index).

## Casos

### A. effective_base / core
- A1 HEAD → effective_base()==nil
- A2 ":" → nil
- A3 commit → ese ref
- A4 set_base("") → base_ref=="HEAD", label nil

### B. head_content / changed_files base-aware
- B1 head_content(mod, C0) == `git show C0:src/mod.ts`
- B2 head_content(newC2, C1) == nil (no existe en C1)
- B3 head_content(keep, HEAD) == `git show HEAD:src/keep.ts`
- B4 changed_files(C0) contiene newC1,newC2,mod,del,ren_new; NO keep-sin-cambios-commiteado
- B5 changed_files(HEAD) = solo working (keep, untracked, staged)

### C. Sidebar open (changed / git_status)
- C1 :ReviewSidebar changed → source==git_status
- C2 git_base_by_worktree == effective_base (nil→EMPTY) por cada base
- C3 árbol contiene added/modified/deleted/renamed vs base
- C4 árbol NO contiene archivos sin cambios vs base
- C5 untracked aparece siempre (todas las bases)

### D. Reveal (<leader>E)
- D1 git_status abierto → cursor sobre el archivo (todas las bases)
- D2 **filesystem abierto → cursor sobre el archivo** (bug reportado)
- D3 árbol cerrado → abre y revela
- D4 archivo SIN cambios vs base, en git_status → no-op (no cambia de modo, notifica)
- D5 buffer no-archivo (buftype!="") → no-op
- D6 archivo en subdirectorio anidado → revela y expande padres
- D7 reveal tras cambiar base → usa la base nueva

### E. Toggle (<leader>s)
- E1 cerrado → changed(git_status)
- E2 changed → all(filesystem)
- E3 all → changed(git_status)
- E4 base preservada tras toggles
- E5 desde estado abierto por restore (no desincroniza)

### F. Close/reopen (<leader>e)
- F1 preserva source
- F2 preserva git_base
- F3 archivos vs-base SIGUEN en el árbol tras reopen (bug del cache neo-tree)
- F4 reopen tras base→HEAD → git_base EMPTY

### G. base:changed en vivo
- G1 con git_status abierto, cambiar base actualiza el set de archivos
- G2 volver a HEAD → git status plano

### H. gitsigns object_name (cache inspection)
- H1 nuevo-vs-base (commiteado) → object_name = blob vacío, untracked=false (verde sólido)
- H2 untracked → object_name=nil, untracked=true (punteado)
- H3 modificado-vs-base → object_name = blob de la base
- H4 con base=HEAD → comportamiento nativo (untracked ┆, sin sintetizar)

### I. Views inline/split
- I1 inline: head_content del archivo == git show base
- I2 split: idem
- I3 cambiar base invalida y re-renderiza

### J. Statusline
- J1 HEAD → componente vacío
- J2 ":" → "index"
- J3 commit → label (subject) SIN mojibake, truncado

### K. Persistencia
- K1 save_base/load_base roundtrip JSON {ref,label}
- K2 compat: archivo plano viejo → ref, label nil
- K3 restore ignora ref inexistente (rev-parse falla)
- K4 restore de HEAD → no hace nada

### L. Side-cases / robustez
- L1 archivo borrado-vs-base (existe en base, no en disco) → en árbol como D, reveal skip
- L2 renombrado-vs-base → en árbol
- L3 base = commit donde el archivo NO cambió → no en árbol, reveal no-op
- L4 switch base ida y vuelta N veces → consistente
- L5 repo sin cambios (base=HEAD, working limpio) → árbol vacío, sin errores
- L6 base ref inválido pasado a set_base → no rompe (git show falla → nil)
- L7 agente OFF (default) → no afecta sidebar/base
- L8 abrir varios archivos y revelar cada uno

### M. Read-only
- M1 tras TODO: branch, HEAD, git status --porcelain, staged → IDÉNTICOS (no se tocó el repo)
