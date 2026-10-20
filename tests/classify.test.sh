#!/usr/bin/env bash
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMUX_AGENT_STATUS_DIR="$(mktemp -d "${TMPDIR:-/tmp}/tmux-agent-status-test.XXXXXX")"
export TMUX_AGENT_STATUS_DIR
trap 'rm -rf "$TMUX_AGENT_STATUS_DIR"' EXIT

. "$ROOT/lib/classify.sh"

tests=0
failures=0
alive_owner=123
tty_owner=123
fresh_report=1
capture='esc to interrupt'

agent_status_pid_alive() {
  [ "$1" = "$alive_owner" ]
}

agent_status_pid_on_tty() {
  [ "$1" = "$tty_owner" ] && [ "$2" = "/dev/pts/9" ]
}

agent_status_report_fresh() {
  [ "$fresh_report" = 1 ]
}

tmux() {
  if [ "${1:-}" = capture-pane ]; then
    printf '%s\n' "$capture"
    return 0
  fi
  return 1
}

pass() {
  tests=$((tests + 1))
  printf 'ok %d - %s\n' "$tests" "$1"
}

fail() {
  tests=$((tests + 1))
  failures=$((failures + 1))
  printf 'not ok %d - %s\n' "$tests" "$1"
}

assert_state() {
  local description="$1" expected="$2"
  shift 2
  local actual
  if actual="$("$@")" && [ "$actual" = "$expected" ]; then
    pass "$description"
  else
    fail "$description (expected $expected, got ${actual:-<none>})"
  fi
}

assert_rejected() {
  local description="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    fail "$description"
  else
    pass "$description"
  fi
}

write_report() {
  local source="$1" pane="$2" owner="$3" state="$4"
  local dir="$TMUX_AGENT_STATUS_DIR/${pane#%}/$source"
  mkdir -p "$dir"
  {
    printf 'version=1\n'
    printf 'source=%s\n' "$source"
    printf 'run=test-run\n'
    printf 'owner=%s\n' "$owner"
    printf 'pane=%s\n' "$pane"
    printf 'state=%s\n' "$state"
  } >"$dir/report"
}

remove_reports() {
  rm -rf "$TMUX_AGENT_STATUS_DIR"
  mkdir -p "$TMUX_AGENT_STATUS_DIR"
}

write_report opencode %9 123 working
assert_state 'accepts a valid OpenCode report' working reported_state %9 opencode /dev/pts/9
assert_state 'uses a valid report for an agent without screen heuristics' working classify_state %9 opencode /dev/pts/9

write_report claude %9 123 blocked
assert_state 'accepts a valid Claude report' blocked reported_state %9 claude /dev/pts/9
assert_state 'semantic state takes precedence over Claude screen markers' blocked classify_state %9 claude /dev/pts/9

remove_reports
write_report claude %9 123 working
printf 'version=1\nsource=opencode\nrun=test-run\nowner=123\npane=%%9\nstate=working\n' >"$TMUX_AGENT_STATUS_DIR/9/claude/report"
assert_rejected 'rejects a source mismatch' reported_state %9 claude /dev/pts/9

remove_reports
write_report opencode %8 123 working
printf 'version=1\nsource=opencode\nrun=test-run\nowner=123\npane=%%9\nstate=working\n' >"$TMUX_AGENT_STATUS_DIR/8/opencode/report"
assert_rejected 'rejects a pane mismatch' reported_state %8 opencode /dev/pts/9

write_report opencode %9 123 working
alive_owner=456
assert_rejected 'rejects a dead owner' reported_state %9 opencode /dev/pts/9
alive_owner=123

tty_owner=456
assert_rejected 'rejects an owner absent from the pane tty' reported_state %9 opencode /dev/pts/9
tty_owner=123

write_report opencode %9 123 unknown
assert_rejected 'rejects an unknown state' reported_state %9 opencode /dev/pts/9

write_report opencode %9 123 working
printf 'malformed\n' >>"$TMUX_AGENT_STATUS_DIR/9/opencode/report"
assert_rejected 'rejects a malformed line' reported_state %9 opencode /dev/pts/9

write_report opencode %9 123 working
printf 'state=blocked\n' >>"$TMUX_AGENT_STATUS_DIR/9/opencode/report"
assert_rejected 'rejects a duplicate key' reported_state %9 opencode /dev/pts/9

write_report opencode %9 123 working
printf 'version=1\nsource=opencode\nrun=test-run\nowner=123\npane=%%9\n' >"$TMUX_AGENT_STATUS_DIR/9/opencode/report"
assert_rejected 'rejects a missing key' reported_state %9 opencode /dev/pts/9

write_report opencode %9 123 working
printf 'extra=value\n' >>"$TMUX_AGENT_STATUS_DIR/9/opencode/report"
assert_rejected 'rejects an extra key' reported_state %9 opencode /dev/pts/9

write_report opencode %9 123 working
printf 'version=2\nsource=opencode\nrun=test-run\nowner=123\npane=%%9\nstate=working\n' >"$TMUX_AGENT_STATUS_DIR/9/opencode/report"
assert_rejected 'rejects an unsupported version' reported_state %9 opencode /dev/pts/9

write_report opencode %9 nope working
assert_rejected 'rejects a nonnumeric owner' reported_state %9 opencode /dev/pts/9

remove_reports
assert_rejected 'rejects a missing report' reported_state %9 claude /dev/pts/9
assert_state 'preserves Claude screen fallback without a report' working classify_state %9 claude /dev/pts/9

capture='⬝⬝■■ esc interrupt'
assert_state 'detects OpenCode working without a report' working classify_state %9 opencode /dev/pts/9
capture='Permission required
Allow once   Allow always   Reject'
assert_state 'detects OpenCode blocked without a report' blocked classify_state %9 opencode /dev/pts/9
capture='↑↓ select  enter submit  esc dismiss'
assert_state 'detects OpenCode questions without a report' blocked classify_state %9 opencode /dev/pts/9
capture='⇆ tab  ↑↓ select  enter confirm  esc dismiss'
assert_state 'detects OpenCode multi-question forms without a report' blocked classify_state %9 opencode /dev/pts/9
capture='⇆ select  enter confirm  esc reject'
assert_state 'detects OpenCode permission forms without a report' blocked classify_state %9 opencode /dev/pts/9
capture='up/down select   enter choose   tab next   esc dismiss'
assert_state 'detects OpenCode selection forms without a report' blocked classify_state %9 opencode /dev/pts/9
capture='Allow once   Always allow   Reject'
assert_state 'detects OpenCode permission choices without a report' blocked classify_state %9 opencode /dev/pts/9
capture='  ┃
  ┃
  ┃  Build · DeepSeek V4.1 Flash OpenRouter · max
  ╹▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀
   ■■⬝⬝⬝⬝⬝⬝⬝⬝ esc interrupt                                                                258.9K (25%) · $0.12  ctrl+p commands    ~/dotfiles:master'
assert_state 'detects a running footer at the foot of a full pane' working classify_state %9 opencode /dev/pts/9
capture='     ⬝⬝⬝⬝⬝⬝⬝⬝ esc interrupt    (stale line captured from another pane)
  ┃
  ┃
  ┃  Build · DeepSeek V4.1 Flash OpenRouter · max
  ╹▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀
  ~/dotfiles:master   12.6K (1%) · $0.00  ctrl+p commands    ~/dotfiles:master'
assert_state 'ignores stale working markers outside the footer' waiting classify_state %9 opencode /dev/pts/9
capture='  ┃  old transcript: ↑↓ select  enter submit  esc dismiss
  ┃
  ┃
  ┃  Build · DeepSeek V4.1 Flash OpenRouter · max
  ╹▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀
  ~/dotfiles:master   12.6K (1%) · $0.00  ctrl+p commands    ~/dotfiles:master'
assert_state 'ignores stale blocked markers outside the footer' waiting classify_state %9 opencode /dev/pts/9
capture='  ┃  Which colour should the new button be?
  ┃  1. Blue
  ┃  2. Green
  ┃  3. Type your own answer
  ┃
  ┃  ↑↓ select  enter submit  esc dismiss
  ┃                                                               ~/dotfiles:master'
assert_state 'detects a question footer at the foot of a full pane' blocked classify_state %9 opencode /dev/pts/9
capture='Build · GPT-5.6 Sol'
assert_state 'detects OpenCode waiting without a report' waiting classify_state %9 opencode /dev/pts/9

capture='  ┃
  ┃
  ┃  Build · DeepSeek V4.1 Flash OpenRouter · max
  ╹▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀
  ~/dotfiles:master   ↓ 1 shell · 12.4K (1%) · $0.00  ctrl+p commands    ~/dotfiles:master'
assert_state 'detects a background shell in the status line as working' working classify_state %9 opencode /dev/pts/9

capture='  ╹▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀
  ~/dotfiles:master   ↓ 1 subagent · 1 shell · 10.7K (1%) · $0.00  ctrl+p commands    ~/dotfiles:master'
assert_state 'detects background subagents and shells as working' working classify_state %9 opencode /dev/pts/9

capture='  ~/dotfiles:master   ↓ 2 shells · 13.3K (1%) · $0.00  ctrl+p commands'
assert_state 'detects plural background shells as working' working classify_state %9 opencode /dev/pts/9

capture='  ┃  Which colour should the new button be?
  ┃
  ┃  Allow once   Allow always   Reject
  ┃  ↓ 1 subagent · 10.7K (1%) · $0.00
  ┃  enter confirm  esc dismiss'
assert_state 'prefers a blocking prompt over background work' blocked classify_state %9 opencode /dev/pts/9

capture='  ┃  transcript: ↓ 2 shells running now
  ┃
  ┃
  ┃  Build · DeepSeek V4.1 Flash OpenRouter · max
  ╹▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀
  ~/dotfiles:master   12.6K (1%) · $0.00  ctrl+p commands    ~/dotfiles:master'
assert_state 'ignores a background counter outside the footer' waiting classify_state %9 opencode /dev/pts/9

write_report opencode %9 123 working
fresh_report=0
assert_state 'does not trust a stale OpenCode working report' waiting classify_state %9 opencode /dev/pts/9
capture='  ┃  Allow once   Allow always   Reject
  ┃  enter confirm  esc dismiss'
assert_state 'lets a blocking prompt outrank a stale working report' blocked classify_state %9 opencode /dev/pts/9
capture='  ~/dotfiles:master   ↓ 1 shell · 12.4K (1%) · $0.00  ctrl+p commands'
assert_state 'lets background work outrank a stale working report' working classify_state %9 opencode /dev/pts/9
fresh_report=1
capture='Build · GPT-5.6 Sol'
assert_state 'trusts a fresh OpenCode working report' working classify_state %9 opencode /dev/pts/9
capture='  ┃  Allow once   Allow always   Reject
  ┃  enter confirm  esc dismiss'
assert_state 'lets a blocking prompt outrank a fresh working report' blocked classify_state %9 opencode /dev/pts/9
capture='esc to interrupt'

mkdir -p "$TMUX_AGENT_STATUS_DIR/9"
printf 'version=1\nsource=.\nrun=test-run\nowner=123\npane=%%9\nstate=working\n' >"$TMUX_AGENT_STATUS_DIR/9/report"
assert_rejected 'rejects dot as a source path' reported_state %9 . /dev/pts/9
assert_rejected 'rejects dot-dot as a source path' reported_state %9 .. /dev/pts/9

write_report opencode %9 123 working
mkdir -p "$TMUX_AGENT_STATUS_DIR/9/.edges/opencode"
printf '%s\n' 72756e2d61 >"$TMUX_AGENT_STATUS_DIR/9/.edges/opencode/pending-working.1"
old_transition="$(agent_status_pending_working %9 opencode 72756e2d61)"
if [ "$old_transition" != 1 ]; then
  fail 'reads durable working edges for the reporting run'
else
  printf '%s\n' 72756e2d62 >"$TMUX_AGENT_STATUS_DIR/9/.edges/opencode/pending-working.2"
  agent_status_consume_working %9 opencode 72756e2d61 "$old_transition"
  if [ -e "$TMUX_AGENT_STATUS_DIR/9/.edges/opencode/pending-working.2" ]; then
    pass 'an old refresh cannot acknowledge a restarted run working edge'
  else
    fail 'an old refresh acknowledged a restarted run working edge'
  fi
fi

if agent_status_pending_working %9 opencode 72756e2d62 | grep -qx 2 &&
   ! agent_status_pending_working %9 opencode 72756e2d61 | grep -q .; then
  pass 'pending working edges are scoped to the reporting run'
else
  fail 'pending working edges leaked across reporting runs'
fi

if [ "$failures" -ne 0 ]; then
  printf '%d of %d tests failed\n' "$failures" "$tests" >&2
  exit 1
fi
printf 'all %d tests passed\n' "$tests"
