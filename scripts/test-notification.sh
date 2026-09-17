#!/usr/bin/env bash
# test-notification.sh — the canonical way to test agent-status notifications.
# Uses the SAME delivery as the daemon's notify(): notify-send on Linux,
# terminal-notifier (else osascript) on macOS. The sound is played by the
# notification system / sound server in your GUI session, so it works from
# inside tmux.
#
# Usage:
#   test-notification.sh            # full diagnostic, using your configured sound
#   test-notification.sh <Sound>    # fire one test notification with <Sound>
#   test-notification.sh sounds     # audition every available sound, one banner each
set -u

OS="$(uname -s 2>/dev/null)"
tmux_opt() { tmux show-option -gqv "$1" 2>/dev/null; }
default_sound() { if [ "$OS" = Darwin ]; then echo Glass; else echo message-new-instant; fi; }
CONFIGURED="$(tmux_opt @agent_status_sound)"; [ -n "$CONFIGURED" ] || CONFIGURED="$(default_sound)"

backend() {
  if command -v terminal-notifier >/dev/null 2>&1; then echo terminal-notifier
  elif [ "$OS" = Darwin ] && command -v osascript >/dev/null 2>&1; then echo osascript
  elif command -v notify-send >/dev/null 2>&1; then echo notify-send
  else echo none
  fi
}

linux_session_env() {
  [ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ] && return 0
  local rt="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
  [ -S "$rt/bus" ] && export DBUS_SESSION_BUS_ADDRESS="unix:path=$rt/bus"
  return 0
}

play_sound_linux() {
  local sound="$1"
  [ -n "$sound" ] || return 1
  case "$sound" in
    */*)
      [ -f "$sound" ] || return 1
      if command -v pw-play >/dev/null 2>&1; then pw-play "$sound" >/dev/null 2>&1
      elif command -v paplay >/dev/null 2>&1; then paplay "$sound" >/dev/null 2>&1
      else return 1
      fi
      ;;
    *)
      command -v canberra-gtk-play >/dev/null 2>&1 || return 1
      canberra-gtk-play -i "$sound" -d tmux-agent-status >/dev/null 2>&1
      ;;
  esac
}

# THE delivery path (identical to refresh.sh notify()).
send() { # send <title> <message> <sound> [kind]
  local title msg sound kind="${4:-done}" urgency=normal
  title="$(printf '%s' "$1" | tr -d '"\\')"
  msg="$(printf '%s' "$2" | tr -d '"\\')"
  sound="$3"
  case "$(backend)" in
    terminal-notifier)
      terminal-notifier -title "$title" -message "$msg" ${sound:+-sound "$sound"} >/dev/null 2>&1
      ;;
    osascript)
      local sc=""; [ -n "$sound" ] && sc=" sound name \"$sound\""
      osascript -e "display notification \"$msg\" with title \"$title\"$sc" >/dev/null 2>&1
      ;;
    notify-send)
      linux_session_env
      [ "$kind" = blocked ] && urgency=critical
      notify-send -a tmux-agent-status -i utilities-terminal -u "$urgency" \
        -h string:x-canonical-private-synchronous:tmux-agent-status "$title" "$msg"
      play_sound_linux "$sound" &
      ;;
    *) echo "no notification backend found" >&2; return 1 ;;
  esac
}

list_sounds() {
  if [ "$OS" = Darwin ]; then
    ls /System/Library/Sounds/ 2>/dev/null | sed 's/\.aiff$//'
  else
    local dir
    for dir in "${XDG_DATA_HOME:-$HOME/.local/share}/sounds" /usr/local/share/sounds /usr/share/sounds; do
      [ -d "$dir/freedesktop/stereo" ] || continue
      ls "$dir/freedesktop/stereo" 2>/dev/null | sed 's/\.oga$//; s/\.ogg$//; s/\.wav$//'
    done | sort -u
  fi
}
sound_file_macos() {
  case "$1" in
    */*)                printf '%s' "$1" ;;
    *.aiff|*.wav|*.m4a) printf '/System/Library/Sounds/%s' "$1" ;;
    *)                  printf '/System/Library/Sounds/%s.aiff' "$1" ;;
  esac
}
# Audition without a banner (daemons coalesce rapid repeats, which would
# silence quick back-to-back tests).
preview() {
  if [ "$OS" = Darwin ]; then
    local f; f="$(sound_file_macos "$1")"; [ -f "$f" ] && afplay "$f" 2>/dev/null
  else
    play_sound_linux "$1"
  fi
}

case "${1:-}" in
  sounds|--sounds|--list)
    echo "Auditioning sounds (you'll hear each)…"
    for s in $(list_sounds); do printf '  ♪ %-36s' "$s"; preview "$s" || printf '(could not play)'; echo; done
    echo
    echo "Set your pick with:  set -g @agent_status_sound <Name>   (then reload tmux)"
    echo "Currently configured: $CONFIGURED"
    exit 0
    ;;
  ?*)
    echo "Previewing sound: $1"
    preview "$1" || echo "  (couldn't play $1)"
    echo "Like it? Set it with:  set -g @agent_status_sound $1   (then reload tmux)"
    exit 0
    ;;
esac

# --- no args: full diagnostic -----------------------------------------------
echo "tmux-agent-status — notification test"
echo "====================================="
echo "Platform           : $OS"
echo "Backend            : $(backend)"
echo "Configured sound   : $CONFIGURED"
if [ "$OS" != Darwin ]; then
  linux_session_env
  echo "Session bus        : ${DBUS_SESSION_BUS_ADDRESS:-<none found>}"
  echo "Sound player       : $(command -v canberra-gtk-play || command -v pw-play || command -v paplay || echo '<none>')"
fi
echo

echo "[1/3] Fire a banner + sound (the real path the daemon uses)…"
echo "      → You should SEE a banner and HEAR \"$CONFIGURED\"."
if send "🤖 tmux-agent-status test" "agent finished" "$CONFIGURED"; then echo "      sent ok"; else echo "      send FAILED"; fi
echo

echo "[2/3] Direct sound playback (informational)…"
if preview "$CONFIGURED"; then echo "      playback ok"; else echo "      playback failed (on macOS this is normal inside tmux)"; fi
echo

echo "[3/3] Recent notifications fired by the daemon (if any)"
LOG="${XDG_CACHE_HOME:-$HOME/.cache}/tmux-agent-status/notify.log"
if [ -f "$LOG" ]; then tail -5 "$LOG" | sed 's/^/  /'; else echo "  (none yet)"; fi
echo

if [ "$OS" = Darwin ]; then
cat <<'TIPS'
Try other sounds:  test-notification.sh sounds   (or: test-notification.sh Ping)

No banner?
  • Sound plays but no banner → alert style is off. System Settings →
    Notifications → terminal-notifier → set Alert style to Banners/Alerts.
  • Nothing at all → turn ON Allow Notifications for terminal-notifier, and
    disable Focus / Do Not Disturb.
No sound? Unmute / raise volume, or pick another:  test-notification.sh sounds
TIPS
else
cat <<'TIPS'
Try other sounds:  test-notification.sh sounds   (or: test-notification.sh complete)

No banner?
  • "no notification backend found" → install libnotify (provides notify-send).
  • Session bus "<none found>" → the tmux server has no DBus session. Start tmux
    from your desktop session, or export DBUS_SESSION_BUS_ADDRESS before it starts.
  • notify-send ran but nothing showed → no notification daemon is running
    (GNOME/KDE have one built in; on a bare WM start dunst, mako or swaync) or
    Do Not Disturb is on.
No sound?
  • Sound player "<none>" → install libcanberra (canberra-gtk-play) and
    sound-theme-freedesktop, or set @agent_status_sound to a file path
    (played with pw-play / paplay).
TIPS
fi
