#!/usr/bin/env sh

CURRENT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$CURRENT_DIR/scripts/lib.sh"

set_default() {
  option="$1"
  value="$2"

  [ -n "$(tmux show-option -gqv "$option")" ] && return 0
  tmux set-option -gq "$option" "$value"
}

set_default @cli_hub_session_prefix "agents"
set_default @cli_hub_hash_length "8"
set_default @cli_hub_popup_width "80%"
set_default @cli_hub_popup_height "80%"
set_default @cli_hub_agent_max_slots "20"
set_default @cli_hub_active_secs "10"

# Each slot is "name:key:command[:autokey:autocommand]". `key` opens/creates
# the hub popup for `command`; the optional autokey/autocommand pair binds a
# second key that launches the same agent in its auto-approve/yolo mode.
# Override a slot in tmux.conf (before the plugin's `run` line) to change its
# key or command, add a new numbered slot to add an agent, or set a slot to
# an empty string to disable it. Slots are read 1..@cli_hub_agent_max_slots
# and gaps are allowed.
set_default @cli_hub_agent_1 "claude:0:claude:):claude --dangerously-skip-permissions"
set_default @cli_hub_agent_2 "codex:9:codex:(:codex --dangerously-bypass-approvals-and-sandbox"
set_default @cli_hub_agent_3 "antigravity:8:agy:*:agy --dangerously-skip-permissions"
set_default @cli_hub_agent_4 "opencode:o:opencode"
set_default @cli_hub_agent_5 "gemini:g:gemini"

# Resume commands per provider, used by the "Resume" entries in the prefix + M
# overlay. cli-hub keeps no history of its own — each launches the CLI in its
# own resume mode so the agent shows its own past-session picker. Keyed by the
# provider name (see agent_provider); override or set to "" to hide the entry.
set_default @cli_hub_resume_claude "claude --resume"
set_default @cli_hub_resume_codex "codex resume"
set_default @cli_hub_resume_antigravity "agy --continue"
set_default @cli_hub_resume_opencode "opencode --continue"
set_default @cli_hub_resume_gemini "gemini --resume latest"

tmux unbind-key -q m
tmux unbind-key -q s
tmux unbind-key -q y
tmux unbind-key -q X
tmux unbind-key -q M

# Static parts (script path, agent name/command) are shell-quoted at bind time;
# runtime values expand through #{q:...} so paths or session names containing
# quotes or spaces can't break — or inject into — the shell command. Each
# format is wrapped as #{?X,#{q:X},''} so an empty value still emits '' and
# the positional arguments after it can't shift.
fmt_arg() {
  printf "#{?%s,#{q:%s},''}" "$1" "$1"
}

bind_agent_open() {
  key="$1"
  name="$2"
  command="$3"

  [ -n "$key" ] || return 0
  [ -n "$name" ] || return 0
  [ -n "$command" ] || return 0

  tmux bind-key -r "$key" run-shell "sh $(shell_quote "$CURRENT_DIR/scripts/open.sh") $(shell_quote "$name") $(shell_quote "$command") $(fmt_arg pane_current_path) $(fmt_arg session_name) $(fmt_arg client_name) $(fmt_arg pane_id)"
}

max_slots="$(tmux show-option -gqv @cli_hub_agent_max_slots)"
[ -n "$max_slots" ] || max_slots=20

slot=1
while [ "$slot" -le "$max_slots" ]; do
  entry="$(tmux show-option -gqv "@cli_hub_agent_$slot")"

  if [ -n "$entry" ]; then
    name="$(printf "%s" "$entry" | cut -d: -f1)"
    key="$(printf "%s" "$entry" | cut -d: -f2)"
    command="$(printf "%s" "$entry" | cut -d: -f3)"
    autokey="$(printf "%s" "$entry" | cut -d: -f4)"
    autocommand="$(printf "%s" "$entry" | cut -d: -f5-)"

    bind_agent_open "$key" "$name" "$command"
    bind_agent_open "$autokey" "$name-auto" "$autocommand"
  fi

  slot=$((slot + 1))
done

scripts_q="$(shell_quote "$CURRENT_DIR/scripts")"
a_client="$(fmt_arg client_name)"
a_session="$(fmt_arg session_name)"
a_path="$(fmt_arg pane_current_path)"
a_pane="$(fmt_arg pane_id)"
a_wid="$(fmt_arg window_id)"
a_wname="$(fmt_arg window_name)"

tmux bind-key m run-shell "sh $scripts_q/toggle.sh $a_client $a_session $a_path $a_pane"
tmux bind-key s run-shell "sh $scripts_q/session-menu.sh $a_client $a_session $a_pane"
tmux bind-key y run-shell "sh $scripts_q/menu.sh $a_client $a_session $a_path $a_pane"
tmux bind-key X run-shell "sh $scripts_q/close.sh menu $a_client $a_session $a_pane $a_wid $a_wname $a_path"
tmux bind-key M run-shell "sh $scripts_q/menu-overlay.sh $a_client $a_session $a_pane $a_path"
