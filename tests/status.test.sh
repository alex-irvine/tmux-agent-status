#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d /tmp/tmux-agent-status-flow.XXXXXX)"
SOCKET="$TMP/tmux.sock"
pane=
cleanup() {
  if [ "$?" -ne 0 ] && [ -n "$pane" ]; then
    tmux -S "$SOCKET" capture-pane -p -t "$pane" 2>/dev/null || true
    cat "$XDG_CACHE_HOME/tmux-agent-status/state" 2>/dev/null || true
  fi
  tmux -S "$SOCKET" kill-server 2>/dev/null || true
  rm -rf "$TMP"
}
trap cleanup EXIT

export XDG_CACHE_HOME="$TMP/cache"
export TMUX_AGENT_STATUS_DIR="$TMP/reports"
mkdir -p "$TMP/bin"

# Substitute the external agent's TUI and lifecycle reports. The plugin,
# tmux server, pane process, screen capture, cache and displayed badges are real.
cat >"$TMP/bin/codex" <<'EOF'
#!/usr/bin/env bash
exec -a codex bash --noprofile --norc -c '
  stty -echo
  state=idle
  while :; do
    printf "\033[2J\033[Hrendered-state: %s\n\n" "$state"
    case "$state" in
      working) printf "Working (7s • esc to interrupt)\n\n› Ask Codex to do anything\n? for shortcuts\n" ;;
      question) printf "Choose an option\n› 1. Continue\nenter to submit answer | esc to interrupt\n" ;;
      approval) printf "Would you like to run the following command?\n› 1. Yes, proceed\nPress enter to confirm or esc to cancel\n" ;;
      idle) printf "› Ask Codex to do anything\n? for shortcuts\n" ;;
    esac
    IFS= read -r state || exit 0
  done
'
EOF
chmod +x "$TMP/bin/codex"

read -r pane owner tty < <(tmux -S "$SOCKET" -f /dev/null new-session -d -s test -n agent \
  -P -F '#{pane_id} #{pane_pid} #{pane_tty}' "$TMP/bin/codex")
export TMUX="$SOCKET,$(tmux -S "$SOCKET" display-message -p '#{pid}'),0"
export TMUX_PANE="$pane"
tmux set-option -g @agent_status_poll off
tmux set-option -g @agent_status_agents codex
tmux set-option -g @agent_status_notify none

wait_for() {
  local attempt
  for ((attempt=0; attempt<300; attempt++)); do
    if "$@"; then return 0; fi
    sleep 0.01
  done
  printf 'FAIL: timed out waiting for %s\n' "$*" >&2
  return 1
}
rendered() { tmux capture-pane -p -t "$pane" | grep -Fxq "rendered-state: $1"; }
show_screen() {
  tmux send-keys -l -t "$pane" "$1"
  tmux send-keys -t "$pane" Enter
  wait_for rendered "$1"
}
write_report() {
  local dir="$TMUX_AGENT_STATUS_DIR/${pane#%}/codex"
  mkdir -p "$dir"
  printf 'version=1\nsource=codex\nrun=status-run\nowner=%s\npane=%s\nstate=%s\n' \
    "$owner" "$pane" "$1" >"$dir/report"
}
assert_badge() {
  bash "$ROOT/scripts/refresh.sh"
  local actual
  actual="$(tmux display-message -p -t "$pane" '#{@agent_status_state}')"
  if [ "$actual" != "$1" ]; then
    printf 'FAIL: %s (expected %s, got %s)\n' "$2" "$1" "$actual" >&2
    exit 1
  fi
}
refreshes_finished() { ! tmux show-messages -J | grep -Fq "$ROOT/scripts/refresh.sh"; }

wait_for rendered idle
bash "$ROOT/agent-status.tmux"
wait_for refreshes_finished
assert_badge idle 'a ready agent starts idle'

write_report working
show_screen working
assert_badge working 'a running turn is working'
show_screen question
assert_badge blocked 'a question needs the user despite a working report'
show_screen working
assert_badge working 'answering the question resumes the turn'

write_report blocked
show_screen approval
assert_badge blocked 'a command approval needs the user'
show_screen working
assert_badge working 'accepting approval resumes work before the next hook'
show_screen idle
assert_badge done 'finished work clears an outdated blocked report'
write_report waiting
assert_badge done 'the stop report preserves the completed turn'

printf 'PASS: agent badges follow questions, approvals and completed work\n'
