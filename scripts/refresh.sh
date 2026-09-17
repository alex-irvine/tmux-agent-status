#!/usr/bin/env bash
# refresh.sh — scan every pane, detect which agent (if any) is running AND what
# it's doing, write a status badge into @agent_status per window, optionally
# rename the window, and fire a system notification on important transitions
# (agent finished while you were away / agent now needs you).
#
# Run continuously by daemon, at startup, after semantic events, and on-demand
# from the `w` binding only when polling is disabled.
# A lock serializes overlapping runs so notifications fire exactly once.
#
# Written for bash 3.2 (macOS system bash): no associative arrays.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/classify.sh
. "$SCRIPT_DIR/../lib/classify.sh"

tmux_opt() { # tmux_opt <@option> <default>
  local v; v="$(tmux show-option -gqv "$1" 2>/dev/null)"
  if [ -n "$v" ]; then printf '%s' "$v"; else printf '%s' "$2"; fi
}

CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/tmux-agent-status"
CACHE="$CACHE_DIR/state"
NEW="$CACHE.new"
LOCKDIR="$CACHE_DIR/refresh.lock"
LOCK_OWNER=
CONSUMED="$CACHE_DIR/consumed.$$"
mkdir -p "$CACHE_DIR"

# --- Serialize: wait for daemon/event overlap so lifecycle edges are scanned --
cleanup_refresh_lock() {
  rm -f "$CONSUMED"
  if [ -n "$LOCK_OWNER" ]; then
    rm -f "$LOCK_OWNER"
    rmdir "$LOCKDIR" 2>/dev/null
  fi
}
acquire_refresh_lock() {
  local attempt=0 owner_file owner_name oldpid
  while ! mkdir "$LOCKDIR" 2>/dev/null; do
    owner_file=
    for owner_file in "$LOCKDIR"/owner.* "$LOCKDIR/pid"; do
      [ -f "$owner_file" ] && break
      owner_file=
    done
    if [ -n "$owner_file" ]; then
      owner_name="${owner_file##*/}"
      case "$owner_name" in
        owner.*) oldpid="${owner_name#owner.}"; oldpid="${oldpid%%.*}" ;;
        pid) oldpid="$(cat "$owner_file" 2>/dev/null)" ;;
      esac
    else
      oldpid=
    fi
    case "$oldpid" in
      ''|0|*[!0-9]*) ;;
      *)
        if ! kill -0 "$oldpid" 2>/dev/null; then
          rm -f "$owner_file"
          rmdir "$LOCKDIR" 2>/dev/null
          continue
        fi
        ;;
    esac
    attempt=$((attempt + 1))
    [ "$attempt" -lt 200 ] || return 1
    sleep 0.01
  done
  LOCK_OWNER="$LOCKDIR/owner.$$.$(date +%s).$RANDOM.$RANDOM"
  : >"$LOCK_OWNER" || {
    LOCK_OWNER=
    rmdir "$LOCKDIR" 2>/dev/null
    return 1
  }
}
acquire_refresh_lock || exit 1
trap cleanup_refresh_lock EXIT
trap 'exit 1' INT TERM

# Cold start (no prior cache) → don't notify, or we'd alert for every existing
# blocked/done agent the moment the daemon launches.
NO_NOTIFY=0
[ -f "$CACHE" ] || NO_NOTIFY=1
: > "$NEW"
: > "$CONSUMED"

GLOBAL_ICON="$(tmux_opt @agent_status_icon 🤖)"
RENAME="$(tmux_opt @agent_status_rename off)"
AGENTS_ORDER="$(agent_status_agents)"
NOTIFY="$(tmux_opt @agent_status_notify 'done blocked')"   # states that notify

# --- State -> bracketed label (colored by the chooser/status-bar format) -----
L_WORKING="$(tmux_opt @agent_status_label_working working)"
L_BLOCKED="$(tmux_opt @agent_status_label_blocked blocked)"
L_DONE="$(tmux_opt @agent_status_label_done done)"
L_IDLE="$(tmux_opt @agent_status_label_idle idle)"
status_label() {
  case "$1" in
    working) printf '%s' "$L_WORKING" ;;
    blocked) printf '%s' "$L_BLOCKED" ;;
    done)    printf '%s' "$L_DONE" ;;
    idle)    printf '%s' "$L_IDLE" ;;
    *)       printf '' ;;
  esac
}
state_rank() {
  case "$1" in
    blocked) echo 4 ;; working) echo 3 ;; done) echo 2 ;; idle) echo 1 ;; *) echo 0 ;;
  esac
}
icon_for() {
  local v; v="$(tmux show-option -gqv "@agent_status_icon_$1" 2>/dev/null)"
  if [ -n "$v" ]; then printf '%s' "$v"; else printf '%s' "$GLOBAL_ICON"; fi
}

# --- Notifications (Linux + macOS) -------------------------------------------
should_notify() { case " $NOTIFY " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

# Backend: macOS prefers terminal-notifier (own notification identity and
# permission) and falls back to osascript; Linux uses notify-send (any
# freedesktop notification daemon: GNOME, KDE, dunst, mako, swaync, ...).
notify_backend() {
  if command -v terminal-notifier >/dev/null 2>&1; then echo terminal-notifier
  elif [ "$(uname -s 2>/dev/null)" = Darwin ] && command -v osascript >/dev/null 2>&1; then echo osascript
  elif command -v notify-send >/dev/null 2>&1; then echo notify-send
  else echo none
  fi
}

# Default sound per platform: a Notification Center sound name on macOS, a
# freedesktop sound-theme id on Linux. @agent_status_sound overrides either.
default_sound() {
  if [ "$(uname -s 2>/dev/null)" = Darwin ]; then echo Glass; else echo message-new-instant; fi
}

# The tmux server may have been started without a session bus in its
# environment (systemd unit, ssh). Point at the per-user bus when it exists.
linux_session_env() {
  [ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ] && return 0
  local rt="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
  [ -S "$rt/bus" ] && export DBUS_SESSION_BUS_ADDRESS="unix:path=$rt/bus"
  return 0
}

# Linux sound: play it ourselves so it works regardless of whether the
# notification daemon honours sound hints. A theme id goes through libcanberra;
# a file path goes through PipeWire/PulseAudio.
play_sound_linux() { # play_sound_linux <theme-id|/path/to/file>
  local sound="$1"
  [ -n "$sound" ] || return 0
  case "$sound" in
    */*)
      [ -f "$sound" ] || return 0
      if command -v pw-play >/dev/null 2>&1; then pw-play "$sound" >/dev/null 2>&1 &
      elif command -v paplay >/dev/null 2>&1; then paplay "$sound" >/dev/null 2>&1 &
      fi
      ;;
    *)
      if command -v canberra-gtk-play >/dev/null 2>&1; then
        canberra-gtk-play -i "$sound" -d tmux-agent-status >/dev/null 2>&1 &
      fi
      ;;
  esac
  return 0
}

# notify <title> <message> [kind]   kind = done | blocked
# Delivery is by the notification system in your GUI session (not this
# process), so it works from inside tmux where audio may not be reachable.
# On Linux a "blocked" notification is sent with critical urgency so it stays
# on screen until dismissed; "done" is normal urgency.
notify() {
  local title msg kind="${3:-done}" urgency=normal backend
  title="$(printf '%s' "$1" | tr -d '"\\')"
  msg="$(printf '%s' "$2" | tr -d '"\\')"
  printf '%s  %s | %s\n' "$(date '+%H:%M:%S')" "$title" "$msg" >> "$CACHE_DIR/notify.log" 2>/dev/null
  backend="$(notify_backend)"
  case "$backend" in
    terminal-notifier)
      terminal-notifier -title "$title" -message "$msg" ${SOUND:+-sound "$SOUND"} >/dev/null 2>&1 &
      ;;
    osascript)
      local sound_clause=""
      [ -n "$SOUND" ] && sound_clause=" sound name \"$SOUND\""
      osascript -e "display notification \"$msg\" with title \"$title\"$sound_clause" >/dev/null 2>&1 &
      ;;
    notify-send)
      linux_session_env
      [ "$kind" = blocked ] && urgency=critical
      notify-send -a tmux-agent-status -i utilities-terminal -u "$urgency" \
        -h string:x-canonical-private-synchronous:tmux-agent-status \
        "$title" "$msg" >/dev/null 2>&1 &
      play_sound_linux "$SOUND"
      ;;
    *) ;;
  esac
}

SOUND="$(tmux_opt @agent_status_sound "$(default_sound)")"  # empty = silent

# Cache columns: "<pane_id> <display_state> <raw_state> <run-token>"
prev_disp() { [ -f "$CACHE" ] && awk -v p="$1" '$1==p {print $2; exit}' "$CACHE"; }
prev_raw()  { [ -f "$CACHE" ] && awk -v p="$1" '$1==p {print $3; exit}' "$CACHE"; }
prev_run()  { [ -f "$CACHE" ] && awk -v p="$1" '$1==p {print $4; exit}' "$CACHE"; }

# display_state <raw> <prev_disp> <seen>   (seen = window visible on an attached client)
display_state() {
  local raw="$1" prev="$2" seen="$3"
  case "$raw" in
    working) echo working ;;
    blocked) echo blocked ;;
    unknown) echo unknown ;;
    *) if [ "$seen" = "1" ]; then echo idle
       elif [ "$prev" = "working" ] || [ "$prev" = "done" ]; then echo done
       else echo idle; fi ;;
  esac
}

# --- Optional window rename, with save/restore of the original name ----------
rename_present() { # rename_present <window_id> <agent>
  [ "$RENAME" = "window" ] || return 0
  local window_id="$1" agent="$2" cur prev auto
  cur="$(tmux display-message -p -t "$window_id" '#{window_name}')"
  [ "$cur" = "$agent" ] && return 0
  prev="$(tmux show-option -wqv -t "$window_id" @agent_status_prev_name 2>/dev/null)"
  if [ -z "$prev" ]; then
    tmux set-option -w -t "$window_id" @agent_status_prev_name "$cur"
    auto="$(tmux show-option -wqv -t "$window_id" automatic-rename 2>/dev/null)"
    tmux set-option -w -t "$window_id" @agent_status_auto_prev "${auto:-unset}"
  fi
  tmux set-option -w -t "$window_id" automatic-rename off
  tmux rename-window -t "$window_id" "$agent"
}
rename_absent() { # rename_absent <window_id>
  [ "$RENAME" = "window" ] || return 0
  local window_id="$1" prev auto
  prev="$(tmux show-option -wqv -t "$window_id" @agent_status_prev_name 2>/dev/null)"
  [ -n "$prev" ] || return 0
  tmux rename-window -t "$window_id" "$prev"
  tmux set-option -wu -t "$window_id" @agent_status_prev_name
  auto="$(tmux show-option -wqv -t "$window_id" @agent_status_auto_prev 2>/dev/null)"
  if [ -z "$auto" ] || [ "$auto" = "unset" ]; then
    tmux set-option -wu -t "$window_id" automatic-rename 2>/dev/null
  else
    tmux set-option -w -t "$window_id" automatic-rename "$auto"
  fi
  tmux set-option -wu -t "$window_id" @agent_status_auto_prev 2>/dev/null
}

# --- Scan every window, aggregating over its panes ---------------------------
# "seen" = the window is the active window of an ATTACHED session (i.e. actually
# on screen). Notifications, however, do NOT depend on this — they fire on the
# raw working->stopped / ->blocked edge regardless of where you're looking.
tmux list-windows -a -F '#{window_id} #{window_active} #{session_attached} #{session_name} #{window_index} #{window_name}' |
while read -r window_id window_active session_attached session_name window_index window_name; do
  [ -n "$window_id" ] || continue

  seen=0
  [ "$window_active" = "1" ] && [ "${session_attached:-0}" -ge 1 ] 2>/dev/null && seen=1

  found=" "
  best_state="none"
  best_rank=-1

  while read -r pane_id pane_cmd pane_tty; do
    [ -n "$pane_id" ] || continue
    agent="$(classify_pane "$window_id" "$window_index" "$pane_id" "$pane_cmd" "$window_name" "$pane_tty")"
    [ "$agent" = "none" ] && continue
    case "$found" in *" $agent "*) ;; *) found="$found$agent " ;; esac

    praw="$(prev_raw "$pane_id")"
    pdisp="$(prev_disp "$pane_id")"
    previous_run="$(prev_run "$pane_id")"
    status="$(classify_status "$pane_id" "$agent" "$pane_tty")"
    raw="${status%% *}"
    run_token="${status#* }"
    if [ "$previous_run" != "$run_token" ]; then
      praw=
      pdisp=
    fi
    pending_working="$(agent_status_pending_working "$pane_id" "$agent" "$run_token")" || pending_working=
    if [ -n "$pending_working" ] && [ "$raw" = waiting ]; then
      praw=working
      pdisp=working
    fi
    disp="$(display_state "$raw" "$pdisp" "$seen")"
    printf '%s %s %s %s\n' "$pane_id" "$disp" "$raw" "$run_token" >> "$NEW"
    for transition in $pending_working; do
      printf '%s %s %s %s\n' "$pane_id" "$agent" "$run_token" "$transition" >>"$CONSUMED"
    done

    # Notify on the raw transition — independent of which window you're viewing.
    if [ "$NO_NOTIFY" = 0 ]; then
      if [ "$raw" = "waiting" ] && [ "$praw" = "working" ] && should_notify done; then
        notify "🤖 $agent finished" "$window_name — $session_name" done
      elif [ "$raw" = "blocked" ] && [ "$praw" != "blocked" ] && should_notify blocked; then
        notify "🤖 $agent needs you" "$window_name — $session_name" blocked
      fi
    fi

    r="$(state_rank "$disp")"
    if [ "$r" -gt "$best_rank" ]; then best_rank="$r"; best_state="$disp"; fi
  done < <(tmux list-panes -t "$window_id" -F '#{pane_id} #{pane_current_command} #{pane_tty}')

  chosen=""
  for a in $AGENTS_ORDER; do
    case "$found" in *" $a "*) chosen="$a"; break ;; esac
  done

  if [ -n "$chosen" ]; then
    icon="$(icon_for "$chosen")"
    label="$(status_label "$best_state")"
    # @agent_status      = icon + label (used by the chooser)
    # @agent_status_text = label only   (used by the status bar when icon hidden)
    if [ -n "$label" ]; then
      tmux set-option -w -t "$window_id" @agent_status "$icon ($label) "
      tmux set-option -w -t "$window_id" @agent_status_text "($label) "
      tmux set-option -w -t "$window_id" @agent_status_state "$best_state"
    else
      tmux set-option -w -t "$window_id" @agent_status "$icon "
      tmux set-option -wu -t "$window_id" @agent_status_text 2>/dev/null
      tmux set-option -wu -t "$window_id" @agent_status_state 2>/dev/null
    fi
    rename_present "$window_id" "$chosen"
  else
    tmux set-option -wu -t "$window_id" @agent_status 2>/dev/null
    tmux set-option -wu -t "$window_id" @agent_status_text 2>/dev/null
    tmux set-option -wu -t "$window_id" @agent_status_state 2>/dev/null
    rename_absent "$window_id"
  fi
done

if mv -f "$NEW" "$CACHE" 2>/dev/null; then
  while read -r pane_id agent run_token transition; do
    [ -n "$pane_id" ] || continue
    agent_status_consume_working "$pane_id" "$agent" "$run_token" "$transition"
  done <"$CONSUMED"
fi
