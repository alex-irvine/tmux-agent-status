#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/tmux-agent-refresh-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

export HOME="$TMP/home"
export XDG_CACHE_HOME="$TMP/cache"
export TMUX_AGENT_STATUS_DIR="$TMP/reports"
export FAKE_TMUX_STATE="$TMP/tmux-state"
export FAKE_TMUX_LOG="$TMP/tmux.log"
mkdir -p "$HOME" "$TMP/bin" "$TMUX_AGENT_STATUS_DIR/9/opencode" "$TMUX_AGENT_STATUS_DIR/10/opencode"
printf '0\n' >"$FAKE_TMUX_STATE"

cat >"$TMP/bin/tmux" <<'EOF'
#!/bin/sh
case "$1" in
  show-option)
    case "$*" in
      *@agent_status_agents*) printf 'opencode' ;;
      *@agent_status_notify*) printf 'done blocked' ;;
      *) printf '' ;;
    esac
    ;;
  list-windows)
    if [ "${TMUX_AGENT_TEST_RECLAIMER:-}" = A ]; then
      : >"$TMUX_AGENT_TEST_SYNC/a-scanning"
      while [ ! -e "$TMUX_AGENT_TEST_SYNC/release-a" ]; do sleep 0.01; done
    fi
    seen="$(cat "$FAKE_TMUX_STATE")"
    printf '@1 %s 1 test 1 agents\n' "$seen"
    ;;
  list-panes)
    printf '%%9 opencode /dev/pts/9\n'
    [ -f "$FAKE_TMUX_STATE.multi" ] && printf '%%10 opencode /dev/pts/10\n'
    ;;
  set-option)
    printf '%s\n' "$*" >>"$FAKE_TMUX_LOG"
    ;;
  *) ;;
esac
EOF
cat >"$TMP/bin/ps" <<'EOF'
#!/bin/sh
case "$*" in
  *state=,command=*) printf 'S+ opencode\n' ;;
  *pid=*) printf '%s\n' "$TMUX_AGENT_TEST_OWNER" ;;
esac
EOF
cat >"$TMP/bin/mv" <<'EOF'
#!/bin/sh
case "$*" in
  *state.new*) [ -n "${TMUX_AGENT_FAIL_CACHE_COMMIT:-}" ] && exit 1 ;;
esac
exec /bin/mv "$@"
EOF
cat >"$TMP/bin/rm" <<'EOF'
#!/bin/sh
for path in "$@"; do
  case "$path" in
    *owner.999999.stale-race)
      if [ "${TMUX_AGENT_TEST_RECLAIMER:-}" = B ]; then
        : >"$TMUX_AGENT_TEST_SYNC/b-observed"
        while [ ! -e "$TMUX_AGENT_TEST_SYNC/release-b" ]; do sleep 0.01; done
      fi
      ;;
  esac
done
exec /bin/rm "$@"
EOF
chmod +x "$TMP/bin/tmux" "$TMP/bin/ps" "$TMP/bin/mv" "$TMP/bin/rm"
export PATH="$TMP/bin:$PATH"
export TMUX_AGENT_TEST_OWNER="$$"

write_report() {
  pane="$1" state="$2"
  dir="$TMUX_AGENT_STATUS_DIR/$pane/opencode"
  mkdir -p "$dir"
  printf 'version=1\nsource=opencode\nrun=test-run\nowner=%s\npane=%%%s\nstate=%s\n' \
    "$$" "$pane" "$state" >"$dir/report"
}

refresh() {
  bash "$ROOT/scripts/refresh.sh"
}

wait_for_file() {
  path="$1"
  attempts=0
  while [ ! -e "$path" ]; do
    attempts=$((attempts + 1))
    [ "$attempts" -lt 200 ] || return 1
    sleep 0.01
  done
}

window_state() {
  awk '$0 ~ /@agent_status_state/ { value=$NF } END { print value }' "$FAKE_TMUX_LOG"
}

write_report 9 waiting
refresh
: >"$FAKE_TMUX_LOG"

mkdir -p "$TMUX_AGENT_STATUS_DIR/9/.edges/opencode"
: >"$TMUX_AGENT_STATUS_DIR/9/.edges/opencode/pending-working.1"
export TMUX_AGENT_FAIL_CACHE_COMMIT=1
refresh
[[ -e "$TMUX_AGENT_STATUS_DIR/9/.edges/opencode/pending-working.1" ]]
unset TMUX_AGENT_FAIL_CACHE_COMMIT
: >"$FAKE_TMUX_LOG"
refresh
[[ "$(window_state)" == done ]]
grep -q '^%9 done waiting$' "$XDG_CACHE_HOME/tmux-agent-status/state"
[[ ! -e "$TMUX_AGENT_STATUS_DIR/9/.edges/opencode/pending-working.1" ]]
: >"$FAKE_TMUX_LOG"

sleep 5 &
lock_owner=$!
mkdir -p "$XDG_CACHE_HOME/tmux-agent-status/refresh.lock"
printf '%s\n' "$lock_owner" >"$XDG_CACHE_HOME/tmux-agent-status/refresh.lock/pid"
write_report 9 working
refresh &
contending_refresh=$!
sleep 0.05
kill -0 "$contending_refresh"
kill "$lock_owner"
wait "$lock_owner" 2>/dev/null || true
wait "$contending_refresh"
grep -q '^%9 working working$' "$XDG_CACHE_HOME/tmux-agent-status/state"

race_sync="$TMP/refresh-lock-race"
mkdir "$race_sync"
mkdir "$XDG_CACHE_HOME/tmux-agent-status/refresh.lock"
: >"$XDG_CACHE_HOME/tmux-agent-status/refresh.lock/owner.999999.stale-race"
TMUX_AGENT_TEST_RECLAIMER=B TMUX_AGENT_TEST_SYNC="$race_sync" bash "$ROOT/scripts/refresh.sh" &
reclaimer_b=$!
if ! wait_for_file "$race_sync/b-observed"; then
  wait "$reclaimer_b" 2>/dev/null || true
  echo "FAIL: second refresh reclaimer did not pause after stale observation" >&2
  exit 1
fi
TMUX_AGENT_TEST_RECLAIMER=A TMUX_AGENT_TEST_SYNC="$race_sync" bash "$ROOT/scripts/refresh.sh" &
reclaimer_a=$!
wait_for_file "$race_sync/a-scanning"
: >"$race_sync/release-b"
kill -0 "$reclaimer_b"
compgen -G "$XDG_CACHE_HOME/tmux-agent-status/refresh.lock/owner.*" >/dev/null
[[ ! -e "$XDG_CACHE_HOME/tmux-agent-status/refresh.lock/owner.999999.stale-race" ]]
: >"$race_sync/release-a"
wait "$reclaimer_a"
wait "$reclaimer_b"

write_report 9 waiting
: >"$FAKE_TMUX_LOG"
refresh
[[ "$(window_state)" == done ]]

printf '1\n' >"$FAKE_TMUX_STATE"
: >"$FAKE_TMUX_LOG"
refresh
[[ "$(window_state)" == idle ]]

write_report 9 working
: >"$FAKE_TMUX_LOG"
refresh
[[ "$(window_state)" == working ]]
write_report 9 blocked
: >"$FAKE_TMUX_LOG"
refresh
[[ "$(window_state)" == blocked ]]
write_report 9 working
: >"$FAKE_TMUX_LOG"
refresh
[[ "$(window_state)" == working ]]

write_report 9 working
write_report 10 blocked
: >"$FAKE_TMUX_STATE.multi"
: >"$FAKE_TMUX_LOG"
refresh
[[ "$(window_state)" == blocked ]]

echo "PASS: tmux refresh tests"
