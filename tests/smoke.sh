#!/usr/bin/env bash
# Headless smoke test for tmux-cli-hub.
#
# Runs the plugin's scripts against a throwaway tmux server (its own socket,
# reached through a PATH shim so the scripts' bare `tmux` calls land there and
# never touch your real server). Exercises project naming/collision, the status
# heuristic, and the close/prune lifecycle. No display; interactive surfaces
# (popup, menu, choose-tree) are covered only by a `sh -n` syntax check.
#
# Usage: tests/smoke.sh   (exit 0 = all passed)
set -u

REAL_TMUX="$(command -v tmux || true)"
[ -n "$REAL_TMUX" ] || { echo "tmux not found on PATH"; exit 2; }

PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPTS="$PLUGIN/scripts"
SOCK="clihub-smoke-$$"
TMP="$(mktemp -d 2>/dev/null || mktemp -d -t clihub)"
SHIM="$TMP/shim"

cleanup() { "$REAL_TMUX" -L "$SOCK" kill-server 2>/dev/null; rm -rf "$TMP"; }
trap cleanup EXIT INT TERM

pass=0; fail=0
ok() { pass=$((pass+1)); printf "  ok   %s\n" "$1"; }
no() { fail=$((fail+1)); printf "  FAIL %s (got: %s)\n" "$1" "$2"; }
chk() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1" "$3 != $2"; fi; }

mkdir -p "$SHIM"
cat > "$SHIM/tmux" <<EOF
#!/bin/sh
exec "$REAL_TMUX" -L "$SOCK" "\$@"
EOF
chmod +x "$SHIM/tmux"
export PATH="$SHIM:$PATH"
T() { "$REAL_TMUX" -L "$SOCK" "$@"; }

T kill-server 2>/dev/null
T new-session -d -s work -x 200 -y 50
sh "$PLUGIN/cli-hub.tmux"

echo "== syntax =="
for f in "$SCRIPTS"/*.sh "$PLUGIN/cli-hub.tmux"; do
  if sh -n "$f" 2>"$TMP/e"; then ok "sh -n $(basename "$f")"; else no "sh -n $(basename "$f")" "$(cat "$TMP/e")"; fi
done

echo "== naming =="
. "$SCRIPTS/lib.sh"
chk "sanitize folds :/./space" "my-project-v2-0" "$(sanitize_component 'my project:v2.0')"
T new-session -d -s agents-web -x 80 -y 24 "sleep 300"
T set-option -t agents-web -q @cli_hub_project_path "/tmp/a/web"
chk "same project reuses name"  "agents-web" "$(agent_session_name /tmp/a/web)"
case "$(agent_session_name /tmp/b/web)" in
  agents-web-*) ok "collision disambiguates";;
  *)            no "collision disambiguates" "$(agent_session_name /tmp/b/web)";;
esac

echo "== open create path =="
sh "$SCRIPTS/open.sh" claude "sleep 300" /tmp/proj/myapp work "" "" >/dev/null 2>&1
chk "readable session created" "agents-myapp" "$(T list-sessions -F '#{session_name}' | grep '^agents-myapp' | head -1)"

echo "== status =="
T set-option -g -q @cli_hub_active_secs 1
T set-option -g remain-on-exit on
T new-session -d -s agents-dead -x 80 -y 24 "sleep 300"
T set-option -t agents-dead -q @cli_hub_project_path /tmp/proj/dead
T new-window -d -t agents-dead: -n deadagent "sh -c 'exit 0'"
T new-window -d -t agents-dead: -n shellagent "sh"
T new-window -d -t agents-dead: -n runagent "sleep 300"
T new-window -d -t agents-dead: -n permagent "sleep 300"
pp="$(T list-windows -t agents-dead: -F '#{window_name} #{pane_id}' | awk '$1=="permagent"{print $2}')"
T select-pane -t "$pp" -T "waiting for permission to edit"
sleep 3
sh "$SCRIPTS/status.sh"
wstat() { T list-windows -t agents-dead: -F '#{window_name} #{@cli_hub_status}' | awk -v n="$1" '$1==n{print $2}'; }
chk "dead pane -> dead"                "dead"        "$(wstat deadagent)"
chk "shell command -> exited"          "exited"      "$(wstat shellagent)"
chk "non-shell stale -> running"       "running"     "$(wstat runagent)"
chk "permission title -> needs-input"  "needs-input" "$(wstat permagent)"
T set-option -g -q @cli_hub_active_secs 30
T new-window -d -t agents-dead: -n freshagent "sleep 300"
sh "$SCRIPTS/status.sh"
chk "fresh non-shell -> active"        "active"      "$(wstat freshagent)"

echo "== lifecycle =="
chk "deadagent present"       "1" "$(T list-windows -a -F '#{window_name}' | grep -c '^deadagent$')"
sh "$SCRIPTS/close.sh" prune >/dev/null 2>&1
chk "prune removed dead"      "0" "$(T list-windows -a -F '#{window_name}' | grep -c '^deadagent$')"
chk "prune kept live agent"   "1" "$(T list-windows -a -F '#{window_name}' | grep -c '^runagent$')"
rid="$(T list-windows -t agents-dead: -F '#{window_name} #{window_id}' | awk '$1=="runagent"{print $2}')"
sh "$SCRIPTS/close.sh" kill-window "$rid" >/dev/null 2>&1
chk "kill-window removed one" "0" "$(T list-windows -a -F '#{window_name}' | grep -c '^runagent$')"

echo "== session-menu filters =="
# The `s` chooser must show cli sessions (agents-*) inside the popup and, in the
# work view, exclude every agent-hub prefix (agents/acp/vz) so orphan sessions
# from a disabled/renamed sibling never pollute the list.
T new-session -d -s workzz -x 80 -y 24 "sleep 300"
T new-session -d -s acp-beta -x 80 -y 24 "sleep 300"
T new-session -d -s vz-gamma -x 80 -y 24 "sleep 300"
prefix="$(. "$SCRIPTS/lib.sh"; tmux_option @cli_hub_session_prefix agents)"
work_filter="#{?#{m/r:^(${prefix}|acp|vz)-,#{session_name}},0,1}"
agent_filter="#{m/r:^${prefix}-,#{session_name}}"
work="$(T list-sessions -f "$work_filter" -F '#{session_name}' 2>/dev/null | tr '\n' ' ')"
agents="$(T list-sessions -f "$agent_filter" -F '#{session_name}' 2>/dev/null | tr '\n' ' ')"
case " $work " in *" workzz "*) ok "work filter keeps a real session";; *) no "work filter keeps work" "$work";; esac
case "$work" in *agents-*|*acp-*|*vz-*) no "work filter drops hub sessions" "$work";; *) ok "work filter drops agents-/acp-/vz-";; esac
case " $agents " in *" agents-myapp "*) ok "agent filter keeps agents-*";; *) no "agent filter keeps agents-*" "$agents";; esac
case "$agents" in *workzz*|*acp-*|*vz-*) no "agent filter drops non-agents" "$agents";; *) ok "agent filter drops work/acp/vz";; esac

echo "== prefix+M overlay (menu construction) =="
# Intercept display-menu: dump its args instead of rendering (needs no client).
DUMP="$TMP/menu.dump"
cat > "$SHIM/tmux" <<EOF
#!/bin/sh
if [ "\$1" = "display-menu" ]; then
  shift
  : > "$DUMP"
  for a in "\$@"; do printf '%s\n' "\$a" >> "$DUMP"; done
  exit 0
fi
exec "$REAL_TMUX" -L "$SOCK" "\$@"
EOF
chmod +x "$SHIM/tmux"
sh "$SCRIPTS/menu-overlay.sh" dummyclient agents-myapp %0 /tmp/proj/myapp >/dev/null 2>&1
has() { if grep -Fq "$2" "$DUMP" 2>/dev/null; then ok "$1"; else no "$1" "missing '$2'"; fi; }
has "title shows project"     " cli-hub · myapp "
has "live agent row (claude)" "claude  ["
has "New per provider (codex)" "＋ New codex"
has "Resume per provider (claude)" "⟲ Resume claude"
has "Resume per provider (codex)"  "⟲ Resume codex"
has "all-agents entry"        "All agents (every project)…"
has "cancel entry"            "Cancel"
# resume launcher carries the provider's native resume flag + an ASCII name
has "resume cmd carries --resume"   "claude --resume"
has "resume window name is ASCII"   "'claude-resume'"

echo
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
