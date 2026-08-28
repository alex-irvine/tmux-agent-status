#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"

cat >"$TMP/bin/tmux" <<'SH'
#!/bin/sh
if [ "$1" = "show-option" ] && [ "${3:-}" = "@agent_status_poll" ]; then
  printf '%s' "$TEST_POLL"
  exit 0
fi
printf '%s\n' "$*" >>"$TMUX_CALLS"
SH
chmod +x "$TMP/bin/tmux"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

binding_for() {
  local poll="$1" calls="$TMP/calls-$1"
  : >"$calls"
  TEST_POLL="$poll" TMUX_CALLS="$calls" PATH="$TMP/bin:$PATH" \
    bash "$ROOT/agent-status.tmux"
  grep '^bind-key ' "$calls"
}

calls_for() {
  local poll="$1"
  printf '%s' "$TMP/calls-$poll"
}

poll_on_bind="$(binding_for on)"
[[ "$poll_on_bind" == *"choose-tree -Zw -F"* ]] || fail "polling-on binding omitted chooser"
[[ "$poll_on_bind" != *"run-shell"* ]] || fail "polling-on binding refreshes synchronously"
[[ "$poll_on_bind" == *'@agent_status'* ]] || fail "polling-on binding omitted status badge"
[[ "$poll_on_bind" == *'@agent_status_state'* ]] || fail "polling-on binding omitted status colour state"
grep -q 'run-shell -b .*/scripts/daemon.sh' "$(calls_for on)" || fail "polling-on mode omitted daemon"

poll_off_bind="$(binding_for off)"
[[ "$poll_off_bind" == *"run-shell"* ]] || fail "polling-off binding omitted refresh"
[[ "$poll_off_bind" == *"scripts/refresh.sh"* ]] || fail "polling-off binding used wrong refresh command"
[[ "$poll_off_bind" == *"choose-tree -Zw -F"* ]] || fail "polling-off binding omitted chooser"
[[ "$poll_off_bind" == *'@agent_status'* ]] || fail "polling-off binding omitted status badge"
[[ "$poll_off_bind" == *'@agent_status_state'* ]] || fail "polling-off binding omitted status colour state"
if grep -q 'run-shell -b .*/scripts/daemon.sh' "$(calls_for off)"; then
  fail "polling-off mode started daemon"
fi

printf 'PASS: tmux chooser binding tests\n'
