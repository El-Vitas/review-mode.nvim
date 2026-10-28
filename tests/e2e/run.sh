#!/usr/bin/env bash
# E2E runner: repo sintético + config real de nvim + scripts e2e. Repetible.
# Cada script corre con su propio fixture y con XDG_STATE_HOME aislado (no toca
# las sesiones reales del usuario). Verifica además que el repo NO se modifique
# (salvo split_hard.lua, que commitea su propio archivo de prueba).
# Uso: run.sh [script.lua ...]   (sin argumentos: todos). Exit != 0 si hay fails.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INIT="${REVIEW_E2E_INIT:-$HOME/.config/nvim/init.lua}"
SCRIPTS=("$@")
[ ${#SCRIPTS[@]} -eq 0 ] && SCRIPTS=(driver.lua split_reentry.lua split_hard.lua split_windows.lua folder_click.lua)

TOTAL_FAIL=0
for script in "${SCRIPTS[@]}"; do
  DIR="$(mktemp -d)"; STATE="$(mktemp -d)"; RESULTS="$(mktemp)"
  eval "$(bash "$HERE/fixture.sh" "$DIR")"   # define C0, C1
  pushd "$DIR" >/dev/null
  snap() { { git status --porcelain | sort; git rev-parse HEAD; git rev-parse --abbrev-ref HEAD; git diff --cached --name-status | sort; }; }
  BEFORE="$(snap)"

  # Sin UI (headless) lazy.nvim nunca dispara VeryLazy: se dispara a mano para
  # reproducir el arranque real (which-key, lualine, lsp-file-operations…).
  timeout 240 env XDG_STATE_HOME="$STATE" REVIEW_E2E_DIR="$DIR" REVIEW_E2E_C0="$C0" REVIEW_E2E_C1="$C1" \
    REVIEW_E2E_OUT="$RESULTS" \
    nvim --headless --cmd "set noexrc" -u "$INIT" "$DIR/src/keep.ts" \
    -c "lua vim.defer_fn(function() vim.api.nvim_exec_autocmds('User', { pattern = 'VeryLazy' }); local ok,e=pcall(dofile,'$HERE/$script'); if not ok then local fd=io.open('$RESULTS','a'); if fd then fd:write('DRIVER-ERROR '..tostring(e)..'\n'); fd:close() end; vim.cmd('qa!') end end, 3000)" \
    >/dev/null 2>&1

  AFTER="$(snap)"
  popd >/dev/null
  NOK="$(grep -c '^ok ' "$RESULTS")"; NFAIL="$(grep -c '^FAIL ' "$RESULTS")"; DERR="$(grep -c 'DRIVER-ERROR' "$RESULTS")"
  grep -E '^(FAIL|DRIVER-ERROR)' "$RESULTS"
  RO="intacto"
  if [ "$BEFORE" != "$AFTER" ] && [ "$script" != "split_hard.lua" ]; then RO="MODIFICADO"; NFAIL=$((NFAIL + 1)); fi
  [ "$NOK" = "0" ] && [ "$NFAIL" = "0" ] && [ "$DERR" = "0" ] && { echo "SIN RESULTADOS (¿hang/timeout?)"; NFAIL=1; }
  echo "── $script: ok=$NOK fail=$NFAIL driver_errors=$DERR repo=$RO"
  TOTAL_FAIL=$((TOTAL_FAIL + NFAIL + DERR))
  rm -rf "$DIR" "$STATE" "$RESULTS"
done

if [ "$TOTAL_FAIL" = "0" ]; then echo "E2E PASS ✓"; exit 0; else echo "E2E FAIL ✗ ($TOTAL_FAIL)"; exit 1; fi
