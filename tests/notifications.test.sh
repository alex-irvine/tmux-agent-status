#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d /tmp/tmux-agent-notifications.XXXXXX)"
SOCKET="$TMP/tmux.sock"
client=
cleanup() {
  if [ "$?" -ne 0 ]; then
    cat "$XDG_CACHE_HOME/tmux-agent-status/state" "$XDG_CACHE_HOME/tmux-agent-status/notify.log" 2>/dev/null || true
    find "$NOTIFY_DESKTOP/active" -type f -exec cat '{}' \;
  fi
  tmux -S "$SOCKET" kill-server 2>/dev/null || true
  exec 3>&-
  [ -z "$client" ] || wait "$client" 2>/dev/null || true
  rm -rf "$TMP"
}
trap cleanup EXIT

export XDG_CACHE_HOME="$TMP/cache"
export TMUX_AGENT_STATUS_DIR="$TMP/reports"
export NOTIFY_DESKTOP="$TMP/desktop"
mkdir -p "$TMP/bin" "$NOTIFY_DESKTOP/active"

# Only the desktop notification service is substituted. The plugin, tmux
# server, attached control client, pane processes and lifecycle reports are real.
cat >"$TMP/bin/notify-send" <<'EOF'
#!/usr/bin/env bash
set -eu
print_id=0
id=
while [ "$#" -gt 2 ]; do
  case "$1" in
    -p|--print-id) print_id=1; shift ;;
    -r|--replace-id) id="$2"; shift 2 ;;
    -a|-i|-u|-h) shift 2 ;;
    *) exit 1 ;;
  esac
done
if [ -z "$id" ] || [ ! -f "$NOTIFY_DESKTOP/active/$id" ]; then
  id="$(cat "$NOTIFY_DESKTOP/counter" 2>/dev/null || printf 100)"
  id=$((id + 1))
  printf '%s\n' "$id" >"$NOTIFY_DESKTOP/counter"
fi
printf '%s\n%s\n' "$1" "$2" >"$NOTIFY_DESKTOP/active/$id"
[ "$print_id" = 0 ] || printf '%s\n' "$id"
EOF
cat >"$TMP/bin/gdbus" <<'EOF'
#!/usr/bin/env bash
set -eu
case "$*" in *org.freedesktop.Notifications.CloseNotification*) ;; *) exit 1 ;; esac
[ ! -f "$NOTIFY_DESKTOP/fail-close" ] || exit 1
for id; do :; done
rm -f "$NOTIFY_DESKTOP/active/$id"
EOF
printf '#!/bin/sh\nexit 0\n' >"$TMP/bin/canberra-gtk-play"
printf '#!/usr/bin/env bash\nprintf "OpenCode ready\\n"\nexec -a opencode sleep 300\n' >"$TMP/bin/opencode"
chmod +x "$TMP/bin/"*
export PATH="$TMP/bin:$PATH"

tmux -S "$SOCKET" -f /dev/null new-session -d -s test -n away 'sleep 300'
export TMUX="$SOCKET,$(tmux -S "$SOCKET" display-message -p '#{pid}'),0"
tmux set-option -g @agent_status_poll off
tmux set-option -g @agent_status_statusbar off
tmux set-option -g @agent_status_agents opencode
tmux set-hook -g 'session-window-changed[0]' "run-shell 'touch $TMP/existing-hook'"
read -r pane_a owner_a < <(tmux new-window -d -t test -n agent-a -P -F '#{pane_id} #{pane_pid}' "$TMP/bin/opencode")
read -r pane_a2 owner_a2 < <(tmux split-window -d -t "$pane_a" -P -F '#{pane_id} #{pane_pid}' "$TMP/bin/opencode")
read -r pane_b owner_b < <(tmux new-window -d -t test -n agent-b -P -F '#{pane_id} #{pane_pid}' "$TMP/bin/opencode")
tmux new-session -d -s other -n away 'sleep 300'

wait_for() {
  local attempt
  for ((attempt=0; attempt<300; attempt++)); do
    if "$@"; then return 0; fi
    sleep 0.01
  done
  printf 'FAIL: timed out waiting for %s\n' "$*" >&2
  return 1
}

agent_ready() { [[ "$(ps -p "$1" -o args=)" == 'opencode 300' ]]; }
for owner in "$owner_a" "$owner_a2" "$owner_b"; do wait_for agent_ready "$owner"; done

write_report() {
  local pane="$1" owner="$2" state="$3" dir="$TMUX_AGENT_STATUS_DIR/${1#%}/opencode"
  mkdir -p "$dir"
  printf 'version=1\nsource=opencode\nrun=test-run\nowner=%s\npane=%s\nstate=%s\n' \
    "$owner" "$pane" "$state" >"$dir/report"
}
all_reports() {
  write_report "$pane_a" "$owner_a" "$1"
  write_report "$pane_a2" "$owner_a2" "$1"
  write_report "$pane_b" "$owner_b" "$1"
}
refresh() { bash "$ROOT/scripts/refresh.sh"; }
notification_count() { find "$NOTIFY_DESKTOP/active" -type f | wc -l; }
has_count() { [ "$(notification_count)" -eq "$1" ]; }

mkfifo "$TMP/client-input"
tmux -C attach-session -t test <"$TMP/client-input" >"$TMP/client.log" &
client=$!
exec 3>"$TMP/client-input"
attached() { [ "$(tmux display-message -p -t test '#{session_attached}')" = 1 ]; }
wait_for attached

all_reports waiting
bash "$ROOT/agent-status.tmux"
bash "$ROOT/agent-status.tmux" # Reload must preserve existing hooks.
wait_for test -f "$XDG_CACHE_HOME/tmux-agent-status/state"
all_reports working
refresh
all_reports waiting
refresh
wait_for has_count 3

# Focusing an unrelated window must leave all three notifications visible.
tmux select-window -t test:agent-b
wait_for has_count 2
grep -l 'agent-a — test' "$NOTIFY_DESKTOP/active/"* >/dev/null
test -f "$TMP/existing-hook"
tmux select-window -t test:away
refresh
has_count 2

# Focusing a window clears notifications from every pane in that window.
tmux select-window -t test:agent-a
wait_for has_count 0

# A notification sent while the window is visible remains until a focus event.
write_report "$pane_a" "$owner_a" blocked
refresh
wait_for has_count 1
refresh
has_count 1
tmux set-hook -R -t test:agent-a client-focus-in
wait_for has_count 0

# Returning from another session also counts as focusing the originating window.
write_report "$pane_a" "$owner_a" working
refresh
write_report "$pane_a" "$owner_a" waiting
refresh
wait_for has_count 1
client_name="$(tmux list-clients -F '#{client_name}')"
tmux switch-client -c "$client_name" -t other
refresh
has_count 1
tmux switch-client -c "$client_name" -t test
wait_for has_count 0

# A failed desktop close is retried when focus returns.
write_report "$pane_a" "$owner_a" blocked
refresh
wait_for has_count 1
touch "$NOTIFY_DESKTOP/fail-close"
tmux select-window -t test:away
tmux select-window -t test:agent-a
refresh # Wait behind the dismissal's refresh lock.
has_count 1
rm "$NOTIFY_DESKTOP/fail-close"
tmux set-hook -R -t test:agent-a client-focus-in
wait_for has_count 0

printf 'PASS: notifications clear when their tmux window gains focus\n'
