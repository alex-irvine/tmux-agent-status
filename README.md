# tmux-agent-status

See at a glance which of your tmux windows are running a coding agent — right in
the window chooser (`prefix + w`).

Pressing the chooser key refreshes every window, detects whether an agent
(Claude Code, Codex, opencode, …) is running in any of its panes and what it's
doing, then prepends a badge — the agent icon plus a bracketed status label,
colored by state — to windows that have one:

```
🤖 (working) 1: api      ← label in yellow
🤖 (blocked) 2: build    ← label in red — needs your input
🤖 (done)    3: worker   ← label in blue — finished, you haven't looked yet
🤖 (idle)    4: notes    ← label in green — finished and seen
             5: shell    ← no agent (plain shell)
```

Only windows actually running an agent get a badge. (The emoji keeps its own
color; the bracketed label is what gets tinted.)

## Status states

| Label       | Colour | State   | Meaning                                            |
|-------------|--------|---------|----------------------------------------------------|
| `(working)` | yellow | working | actively running (live spinner / "esc to interrupt") |
| `(blocked)` | red    | blocked | a prompt is waiting on you (e.g. `❯ 1. Yes`)       |
| `(done)`    | blue   | done    | finished since you last looked (working → idle)    |
| `(idle)`    | green  | idle    | at the prompt, and you've seen it                  |

**done → idle** flips automatically once you actually view the window (its
session is attached and the window is active), so `(done)` highlights "an agent
finished while you were away." The transition is tracked in a tiny per-pane
cache under `$XDG_CACHE_HOME/tmux-agent-status/state`.

Status detection has screen markers for **Claude Code**. Agent lifecycle
integrations can also provide the standard semantic report described below;
Claude Code and OpenCode integrations can use this capability. Other agents
still get a presence badge (their icon, no status label) until they provide a
report or screen markers are added.

> The state taxonomy and colours are adapted from
> [herdr](https://github.com/ogulcancelik/herdr) (an AGPL project) — concept
> only, no code is reused. This plugin is original MIT-licensed bash.

## Realtime updates & notifications

A small background poller (`scripts/daemon.sh`) re-scans every few seconds, so:

- the **status bar** shows a live colored badge on every window (no need to open
  the chooser) — the badge is appended to your `window-status-format`, preserving
  your existing theme;
- you get a **system notification** (macOS) when an agent **finishes**
  (working → stopped) or **becomes blocked** waiting on you — wherever you're
  looking.

The poller is single-instance (a reload cleanly replaces it) and exits when the
tmux server stops.

With polling enabled (the default), the chooser opens immediately from cached
event/poller state. Its worst-case freshness is `@agent_status_interval` (three
seconds by default). With `@agent_status_poll off`, opening the chooser performs
a synchronous on-demand refresh before rendering.

```tmux
set -g @agent_status_interval       3              # poll seconds (default 3)
set -g @agent_status_poll           on             # off to disable the poller
set -g @agent_status_statusbar      on             # off to keep badges out of the status bar
set -g @agent_status_statusbar_icon on             # off = status bar shows the label only (no icon)
set -g @agent_status_notify         "done blocked" # states that notify; "" to silence
set -g @agent_status_sound          Glass          # Notification Center sound name; "" for silent
```

For chooser-only use without live status-bar badges:

```tmux
set -g @agent_status_statusbar off
set -g @plugin 'alex-irvine/tmux-agent-status'
```

Notifications and their sound are delivered by your GUI session, so the sound
plays even from inside tmux. The plugin prefers
[`terminal-notifier`](https://github.com/julienXX/terminal-notifier) if it's
installed (most reliable — its own notification identity and permission):

```sh
brew install terminal-notifier
```

Without it, it falls back to `osascript`, whose notifications post as "Script
Editor" and are **silently dropped if that host isn't allowed** in System
Settings. If you hear/see nothing, run `scripts/test-notification.sh` (below).

Not hearing anything? Run the diagnostic — it fires the real Notification
Center banner + sound, and shows recently-fired notifications:

```sh
~/Projects/tmux-agent-status/scripts/test-notification.sh
```

If you get no banner/sound, notifications are blocked for the scripting host:
**System Settings → Notifications → "Script Editor" → Allow Notifications**
(it appears there after the first attempt), and disable Focus / Do Not Disturb.

## How detection works

Claude Code renames its own process to its version string (e.g. `2.1.185`), so
`#{pane_current_command}` is unreliable. Instead, for each pane we inspect the
processes on its **tty** (`ps -t <tty>`) and match each process's command
basename against a configurable agent list, preferring the foreground process.
This catches agents regardless of how tmux labels the pane.

### Semantic lifecycle reports

Lifecycle integrations can report state without relying on an agent's visible
screen. They write a version-1 report to
`${TMUX_AGENT_STATUS_DIR}/<pane-number>/<source>/report` (by default under
`${XDG_RUNTIME_DIR:-/tmp}/tmux-agent-status-<uid>`) with exactly these fields:

```text
version=1
source=opencode
run=<integration run identifier>
owner=<agent process id>
pane=%9
state=working
```

`source` is the detected agent name and `state` is `working`, `blocked`, or
`waiting`. Reports are parsed strictly as data, and are accepted only while the
owner process is alive on the pane's tty. A valid semantic report takes
precedence over screen markers. If the report is absent or invalid, detection
preserves the existing Claude screen fallback and presence-only behavior for
other agents.

Working-transition markers live at
`${TMUX_AGENT_STATUS_DIR}/<pane-number>/.edges/<source>/pending-working.<generation>`.
Each marker and each cache row carries the encoded reporting run identity. A
new run clears older pending markers without resetting the monotonic generation
counter, and cached transition history is ignored when its run differs from the
current report. A refresh acknowledges only an exact generation/run marker and
only after replacing the cache successfully, so a crashed or delayed old run
cannot make a reused pane display an inherited `done` state.

### Lock and stale-state recovery

The default runtime report root is
`${XDG_RUNTIME_DIR:-/tmp}/tmux-agent-status-<uid>`. Reports are at
`<root>/<pane-number>/<source>/report`, edge data is under
`<root>/<pane-number>/.edges/<source>/`, and reporter locks are
`<root>/<pane-number>/<source>.lock`. The refresh cache and lock are
`${XDG_CACHE_HOME:-$HOME/.cache}/tmux-agent-status/state` and
`${XDG_CACHE_HOME:-$HOME/.cache}/tmux-agent-status/refresh.lock`.

Locks contain a unique `owner.<pid>...` file. A contender reclaims a lock only
when that exact numeric PID is dead. Ownerless locks and locks with invalid owner
tokens deliberately fail closed; they are never reclaimed based on age because
doing so could admit two writers.

For diagnosis, list the exact lock directory and check the PID from
`owner.<pid>...` (or a legacy `pid` file):

```sh
ls -la /exact/path/to/refresh.lock
ps -p <pid> -o pid=,command=
```

Recover manually only after stopping the affected lifecycle integration and
poller and confirming that no `tmux-agent-report` or `scripts/refresh.sh`
process is active. For an ownerless empty lock, run `rmdir` on that exact lock
directory. For an invalid owner file, remove only the observed owner file and
then run `rmdir` on the empty lock directory. Never use `rm -rf`, never remove a
lock owned by a live PID, and never use lock age as evidence. Stale reports are
normally ignored automatically; after confirming their `owner=` PID is dead,
you may remove only the exact `report` file. The next integration `start`
replaces run state and clears prior pending edges.

## Requirements

- tmux 3.x, bash, `ps` (standard on macOS/Linux).
- Notifications are **macOS** today. Optional but recommended:
  [`terminal-notifier`](https://github.com/julienXX/terminal-notifier)
  (`brew install terminal-notifier`) for reliable banners + sound; without it the
  plugin falls back to `osascript`. (Linux `notify-send` is on the roadmap.)

## Install

### Option A — TPM ([Tmux Plugin Manager](https://github.com/tmux-plugins/tpm), recommended)

Add to `~/.tmux.conf`:

```tmux
set -g @plugin 'alex-irvine/tmux-agent-status'
```

Then press `prefix + I` to fetch and load it. (TPM clones the repo to
`~/.tmux/plugins/tmux-agent-status` and sources `agent-status.tmux`.)

### Option B — manual clone

```sh
git clone https://github.com/alex-irvine/tmux-agent-status ~/.tmux/plugins/tmux-agent-status
```

Add to `~/.tmux.conf`, then reload with `tmux source-file ~/.tmux.conf`:

```tmux
run-shell '~/.tmux/plugins/tmux-agent-status/agent-status.tmux'
```

Now press `prefix + w` (e.g. `C-a w`). Windows running an agent show a badge.
Put any configuration (below) **before** the `@plugin` / `run-shell` line.

## Configuration

All optional — set in `~/.tmux.conf` before the `run-shell` line.

### Which agents to detect

```tmux
# Program names to look for, in priority order (basename of the process).
set -g @agent_status_agents "claude codex opencode"
```

Add your own, e.g. `"claude codex opencode aider gemini"`.

### Icons (customisable)

```tmux
set -g @agent_status_icon          🤖     # fallback icon for any agent
set -g @agent_status_icon_claude   ✳️     # per-agent override
set -g @agent_status_icon_codex    🔷
set -g @agent_status_icon_opencode 🟢
```

A per-agent icon (`@agent_status_icon_<name>`) wins; otherwise the global
`@agent_status_icon` is used. With per-agent icons set, the chooser shows a
different icon per agent. Set `@agent_status_icon ""` for label-only badges
(no agent icon).

### Status labels and colours

```tmux
# Bracketed label text per state
set -g @agent_status_label_working working
set -g @agent_status_label_blocked blocked
set -g @agent_status_label_done    done
set -g @agent_status_label_idle    idle

# Colour per state (any tmux colour: named, colourNNN, or #RRGGBB)
set -g @agent_status_color_working yellow
set -g @agent_status_color_blocked red
set -g @agent_status_color_done    blue
set -g @agent_status_color_idle    green
```

### Auto-rename the window to the agent

```tmux
set -g @agent_status_rename window     # off (default) | window
```

When enabled, a window running an agent is renamed to the agent (e.g.
`claude`). The original window name and its `automatic-rename` setting are saved
and **restored automatically** when the agent exits — so your hand-named windows
come back unchanged. Windows without an agent are never touched.

### Chooser key

```tmux
set -g @agent_status_key w     # the prefix key to wrap (default: w)
```

## How it works

- **`agent-status.tmux`** — entry point. Rebinds the chooser key, appends the
  live badge to the status-bar formats, and starts the background poller.
- **`scripts/refresh.sh`** — for each window, scans its panes, picks the
  highest-priority detected agent and state, writes `@agent_status` /
  `@agent_status_state`, fires notifications on transitions, and optionally
  renames the window. A lock serializes the poller and the on-demand run.
- **`scripts/daemon.sh`** — the background poller loop.
- **`lib/classify.sh`** — `classify_pane()` (which agent) and `classify_state()`
  (what it's doing): the detection seam. Swap these to change detection.

## Roadmap

- **More agent state integrations** — lifecycle reports or screen markers for
  agents that currently get a presence-only badge.
- **Cross-platform notifications** — Linux (`notify-send`) support; today
  notifications use macOS `osascript`.

## License

MIT — see [LICENSE](LICENSE).
