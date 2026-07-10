#!/usr/bin/env sh

CURRENT_DIR="$(cd "$(dirname "$0")" && pwd)"

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

tmux set-option -gq @cli_hub_dir "$CURRENT_DIR"

tmux unbind-key -q m
tmux unbind-key -q s
tmux unbind-key -q y
tmux unbind-key -q X

bind_agent_open() {
  key="$1"
  name="$2"
  command="$3"

  [ -n "$key" ] || return 0
  [ -n "$command" ] || return 0

  tmux bind-key -r "$key" run-shell "sh \"$CURRENT_DIR/scripts/open.sh\" \"$name\" \"$command\" \"#{pane_current_path}\" \"#{session_name}\" \"#{client_name}\" \"#{pane_id}\""
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

tmux bind-key m run-shell "sh \"$CURRENT_DIR/scripts/toggle.sh\" \"#{client_name}\" \"#{session_name}\" \"#{pane_current_path}\" \"#{pane_id}\""
tmux bind-key s run-shell "sh \"$CURRENT_DIR/scripts/session-menu.sh\" \"#{client_name}\" \"#{session_name}\""
tmux bind-key y run-shell "sh \"$CURRENT_DIR/scripts/menu.sh\" \"#{client_name}\" \"#{session_name}\" \"#{pane_current_path}\" \"#{pane_id}\""
tmux bind-key X run-shell "sh \"$CURRENT_DIR/scripts/close.sh\" menu \"#{client_name}\" \"#{session_name}\" \"#{pane_id}\" \"#{window_id}\" \"#{window_name}\" \"#{pane_current_path}\""
