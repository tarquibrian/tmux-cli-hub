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
# Start the test server with -f /dev/null so it never loads the user's real
# tmux.conf — the smoke must be hermetic (its own defaults, not your live ones).
"$REAL_TMUX" -f /dev/null -L "$SOCK" new-session -d -s work -x 200 -y 50
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
T new-session -d -s cli-delta -x 80 -y 24 "sleep 300"
prefix="$(. "$SCRIPTS/lib.sh"; tmux_option @cli_hub_session_prefix agents)"
work_filter="#{?#{m/r:^(${prefix}|agents|cli|acp|vz)-,#{session_name}},0,1}"
agent_filter="#{m/r:^${prefix}-,#{session_name}}"
work="$(T list-sessions -f "$work_filter" -F '#{session_name}' 2>/dev/null | tr '\n' ' ')"
agents="$(T list-sessions -f "$agent_filter" -F '#{session_name}' 2>/dev/null | tr '\n' ' ')"
case " $work " in *" workzz "*) ok "work filter keeps a real session";; *) no "work filter keeps work" "$work";; esac
case "$work" in *acp-*|*vz-*|*cli-*|*agents-*) no "work filter drops hub sessions" "$work";; *) ok "work filter drops agents-/cli-/acp-/vz-";; esac
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
has() { if grep -Fq -e "$2" -- "$DUMP" 2>/dev/null; then ok "$1"; else no "$1" "missing '$2'"; fi; }
has "title shows project"     " cli-hub · myapp "
has "live agents header"      "-Live agents"
has "live agent row (claude)" "claude  ["
has "start-new header"        "-Start new"
has "New per provider (codex)" "＋ codex"
has "resume header"           "-Resume"
has "Resume per provider (claude)" "⟲ claude"
has "Resume per provider (codex)"  "⟲ codex"
has "all-agents entry"        "All agents (every project)…"
has "cancel entry"            "Cancel"
# resume launcher carries the provider's native resume flag + an ASCII name
has "resume cmd carries --resume"   "claude --resume"
has "resume window name is ASCII"   "'claude-resume'"
hasx() { if grep -Fxq -- "$2" "$DUMP" 2>/dev/null; then ok "$1"; else no "$1" "no line '$2'"; fi; }
hasx "menu -x flag present"          "-x"
hasx "menu -y flag present"          "-y"
hasx "menu anchored at status line"  "S"

# Empty project: the title carries the "no agents yet" hint.
sh "$SCRIPTS/menu-overlay.sh" dummyclient work %0 /tmp/nowhere/emptyproj >/dev/null 2>&1
has "empty project title hint"       "no agents yet"
has "empty project still offers New" "＋ claude"

# prefix+m with no popup routes to the overlay instead of a dead-end message.
sh "$SCRIPTS/toggle.sh" dummyclient work /tmp/nowhere/emptyproj %0 >/dev/null 2>&1
has "toggle w/o popup opens overlay"  "＋ claude"

# Regression: the dimmed "-" section headers require the "--" flag terminator,
# or display-menu reads them as flags ("unknown flag -L"). Restore the
# pass-through shim and point the real display-menu at a bogus client — a parse
# failure says "unknown flag"; a healthy menu only fails to find the client.
cat > "$SHIM/tmux" <<EOF
#!/bin/sh
exec "$REAL_TMUX" -L "$SOCK" "\$@"
EOF
chmod +x "$SHIM/tmux"
sh "$SCRIPTS/menu-overlay.sh" nopeclient agents-myapp %0 /tmp/proj/myapp 2>"$TMP/menuerr" >/dev/null
if grep -q "unknown flag" "$TMP/menuerr"; then no "overlay parses (no unknown-flag)" "$(cat "$TMP/menuerr")"; else ok "overlay parses (headers need --)"; fi
if grep -q "can't find client" "$TMP/menuerr"; then ok "overlay reached client check"; else no "overlay reached client check" "$(cat "$TMP/menuerr")"; fi

echo "== switcher rich format =="
fmt="$(. "$SCRIPTS/lib.sh"; agent_choose_format)"
o="$(printf '%s' "$fmt" | tr -cd '{' | wc -c | tr -d ' ')"
c="$(printf '%s' "$fmt" | tr -cd '}' | wc -c | tr -d ' ')"
chk "format braces balanced" "$o" "$c"
T set-window-option -t 'agents-myapp:claude' -q @cli_hub_provider claude
T set-window-option -t 'agents-myapp:claude' -q @cli_hub_status active
T select-pane -t 'agents-myapp:claude' -T 'x claude title' 2>/dev/null
render="$(T list-windows -t agents-myapp -F "$fmt" 2>/dev/null)"
case "$render" in *❋*)      ok "claude icon (❋) renders";;      *) no "claude icon" "$render";; esac
case "$render" in *active*)  ok "status word renders";;          *) no "status word" "$render";; esac
case "$render" in *"claude title"*) ok "pane title shown";;      *) no "pane title" "$render";; esac

echo "== resurrect exclude filter =="
RDIR="$TMP/resurrect"; mkdir -p "$RDIR"
T set-option -g @resurrect-dir "$RDIR"
save="$RDIR/tmux_resurrect_test.txt"
{
  printf 'pane\twork\t0\tzsh\t1\t\t0\t:zsh\t/home\t1\tzsh\t1\n'
  printf 'window\twork\t0\tzsh\t1\t*\n'
  printf 'pane\tcli-config\t0\tclaude\t1\t\t0\t:claude\t/cfg\t1\tzsh\t9\n'
  printf 'window\tagents-x\t0\tclaude\t1\t*\n'
  printf 'pane\tacp-foo\t0\tcodex\t1\t\t0\t:codex\t/foo\t1\tzsh\t9\n'
  printf 'window\tvz-bar\t0\tclaude\t1\t*\n'
} > "$save"
ln -sf "$(basename "$save")" "$RDIR/last"
sh "$SCRIPTS/resurrect-exclude.sh"
kept="$(awk -F'\t' '$1=="pane"||$1=="window"{print $2}' "$save" | sort -u | tr '\n' ' ')"
case " $kept " in *" work "*) ok "resurrect filter keeps work session";; *) no "keeps work" "$kept";; esac
case "$kept" in *cli-*|*agents-*|*acp-*|*vz-*) no "resurrect filter drops hub sessions" "$kept";; *) ok "resurrect filter drops cli/agents/acp/vz";; esac

# Custom prefix: sessions under @cli_hub_session_prefix are also dropped.
T set-option -g @cli_hub_session_prefix bots
{
  printf 'pane\twork\t0\tzsh\t1\t\t0\t:zsh\t/home\t1\tzsh\t1\n'
  printf 'pane\tbots-x\t0\tclaude\t1\t\t0\t:claude\t/x\t1\tzsh\t9\n'
} > "$save"
ln -sf "$(basename "$save")" "$RDIR/last"
sh "$SCRIPTS/resurrect-exclude.sh"
kept2="$(awk -F'\t' '{print $2}' "$save" | tr '\n' ' ')"
case "$kept2" in *bots-x*) no "resurrect filter honours custom prefix" "$kept2";; *) ok "resurrect filter honours custom prefix";; esac
case " $kept2 " in *" work "*) ok "custom-prefix run keeps work";; *) no "custom-prefix keeps work" "$kept2";; esac
T set-option -g @cli_hub_session_prefix agents

echo "== pipe in pane title (field-shift regression) =="
T new-session -d -s agents-pipe -x 80 -y 24 "sleep 300"
T set-option -t agents-pipe -q @cli_hub_project_path /tmp/proj/pipe
pp="$(T list-windows -t agents-pipe -F '#{pane_id}' | head -1)"
T select-pane -t "$pp" -T "left|needs permission to edit|right"
sh "$SCRIPTS/status.sh"
st="$(T list-windows -t agents-pipe -F '#{@cli_hub_status}' | head -1)"
chk "piped title still parses -> needs-input" "needs-input" "$st"

echo "== exact-match guard (prefix-sibling session) =="
# Only agents-demo-abcd exists; the overlay for a project whose candidate is
# agents-demo must NOT count the sibling's windows (list-windows prefix-matches).
T new-session -d -s agents-demo-abcd -x 80 -y 24 "sleep 300"
cat > "$SHIM/tmux" <<EOF
#!/bin/sh
if [ "\$1" = "display-menu" ]; then
  shift; : > "$DUMP"
  for a in "\$@"; do printf '%s\n' "\$a" >> "$DUMP"; done
  exit 0
fi
exec "$REAL_TMUX" -L "$SOCK" "\$@"
EOF
chmod +x "$SHIM/tmux"
sh "$SCRIPTS/menu-overlay.sh" dummyclient work %0 /tmp/nowhere/demo >/dev/null 2>&1
has "sibling session not miscounted"  "no agents yet"
if grep -Fq -e "-Live agents" -- "$DUMP"; then no "no live rows from sibling" "found -Live agents"; else ok "no live rows from sibling"; fi

echo "== quoted project path (space + apostrophe) =="
QP="$TMP/pro j'ect"
mkdir -p "$QP"
sh "$SCRIPTS/menu-overlay.sh" dummyclient work %0 "$QP" >/dev/null 2>&1
has "overlay escapes apostrophe path"  "j'\\''ect"
inner="$(grep -F "open.sh" "$DUMP" | head -1 | sed 's/^run-shell "//; s/"$//')"
if sh -n -c "$inner" 2>"$TMP/qerr"; then ok "menu command parses as shell"; else no "menu command parses" "$(cat "$TMP/qerr")"; fi
# restore the pass-through shim and actually open an agent in that path
cat > "$SHIM/tmux" <<EOF
#!/bin/sh
exec "$REAL_TMUX" -L "$SOCK" "\$@"
EOF
chmod +x "$SHIM/tmux"
sh "$SCRIPTS/open.sh" claude "sleep 300" "$QP" work "" "" >/dev/null 2>&1
qsess="$(T list-sessions -F '#{session_name}' | grep '^agents-pro-j-ect' | head -1)"
chk "quoted path -> sanitized session" "agents-pro-j-ect" "$qsess"
# macOS reports the realpath (/var -> /private/var), so compare by suffix.
qcwd="$(T display-message -p -t "agents-pro-j-ect:claude" '#{pane_current_path}' 2>/dev/null)"
case "$qcwd" in
  *"/pro j'ect") ok "agent cwd is the quoted path";;
  *) no "agent cwd is the quoted path" "$qcwd";;
esac

echo "== steady-state poll cost =="
# After one stabilising poll, a second poll with nothing changed must cost
# exactly 3 tmux calls (2 tmux_option reads + 1 list-windows) and 0 writes.
T set-option -g -q @cli_hub_active_secs 1
sleep 2
sh "$SCRIPTS/status.sh"
cat > "$SHIM/tmux" <<EOF
#!/bin/sh
printf '%s\n' "\$1" >> "$TMP/calls"
exec "$REAL_TMUX" -L "$SOCK" "\$@"
EOF
chmod +x "$SHIM/tmux"
: > "$TMP/calls"
sh "$SCRIPTS/status.sh"
total="$(wc -l < "$TMP/calls" | tr -d ' ')"
writes="$(grep -c 'set-window-option' "$TMP/calls")"
chk "steady poll: 3 tmux calls" "3" "$total"
chk "steady poll: 0 writes" "0" "$writes"

echo
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
