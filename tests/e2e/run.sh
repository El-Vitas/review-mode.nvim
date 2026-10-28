#!/usr/bin/env bash
# E2E runner: repo sintético + config real de nvim + driver.lua. Repetible.
# Verifica además que el repo NO se modifique (read-only). Exit != 0 si hay fails.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INIT="${REVIEW_E2E_INIT:-$HOME/.config/nvim/init.lua}"
DIR="$(mktemp -d)"; trap 'rm -rf "$DIR"' EXIT

eval "$(bash "$HERE/fixture.sh" "$DIR")"   # define C0, C1
echo "fixture: $DIR  C0=$C0  C1=$C1"

cd "$DIR"
snap() { { git status --porcelain | sort; git rev-parse HEAD; git rev-parse --abbrev-ref HEAD; git diff --cached --name-status | sort; }; }
BEFORE="$(snap)"

RESULTS="$(mktemp)"; trap 'rm -rf "$DIR" "$RESULTS"' EXIT  # fuera del repo (no ensuciar git status)
OUT="$(timeout 180 env REVIEW_E2E_DIR="$DIR" REVIEW_E2E_C0="$C0" REVIEW_E2E_C1="$C1" REVIEW_E2E_OUT="$RESULTS" \
  nvim --headless --cmd "set noexrc" -u "$INIT" "$DIR/src/keep.ts" \
  -c "lua vim.defer_fn(function() local ok,e=pcall(dofile,'$HERE/driver.lua'); if not ok then local fd=io.open('$RESULTS','a'); if fd then fd:write('DRIVER-ERROR '..tostring(e)..'\n'); fd:close() end; vim.cmd('qa!') end end, 3000)" 2>&1)"

[ -f "$RESULTS" ] && cat "$RESULTS" || echo "(sin resultados — posible hang/timeout)"
AFTER="$(snap)"

echo "── read-only ──"
if [ "$BEFORE" = "$AFTER" ]; then echo "REPO INTACTO ✓"; else echo "REPO MODIFICADO ✗"; diff <(echo "$BEFORE") <(echo "$AFTER"); fi

FAILS="$(sed -n 's/^TOTAL fails=\([0-9]*\)/\1/p' "$RESULTS" 2>/dev/null | tail -1)"
NFAIL="$(grep -c '^FAIL ' "$RESULTS" 2>/dev/null)"; NFAIL="${NFAIL:-0}"
DERR="$(grep -c 'DRIVER-ERROR' "$RESULTS" 2>/dev/null)"; DERR="${DERR:-0}"
echo "── resumen: fails=${FAILS:-?}  (líneas FAIL=$NFAIL)  driver_errors=$DERR ──"
if [ "${FAILS:-1}" = "0" ] && [ "$DERR" = "0" ] && [ "$BEFORE" = "$AFTER" ]; then
  echo "E2E PASS ✓"; exit 0
else
  echo "E2E FAIL ✗"; exit 1
fi
