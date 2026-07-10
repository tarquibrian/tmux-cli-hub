#!/usr/bin/env sh

current_client="$1"
current_session="$2"
current_pane="$3"

script_dir="$(cd "$(dirname "$0")" && pwd)"
. "$script_dir/lib.sh"

prefix="$(tmux_option @cli_hub_session_prefix agents)"

if is_agent_session "$current_session"; then
  # Inside the popup: switch among the cli agent sessions, staying in the
  # popup (switch-client on the popup's own client). This is the cli world,
  # not your work sessions — use `m` to drop back to work.
  agent_filter="#{m/r:^${prefix}-,#{session_name}}"

  count="$(tmux list-sessions -F '#{session_name}' 2>/dev/null | grep -Ec "^${prefix}-")"
  if [ "$count" -le 0 ]; then
    tmux display-message "cli-hub: no agent sessions"
    exit 0
  fi

  if [ -n "$current_pane" ] && pane_exists "$current_pane"; then
    tmux choose-tree -Zs -t "$current_pane" -f "$agent_filter" "switch-client -c \"$current_client\" -t '%%'"
  else
    tmux choose-tree -Zs -f "$agent_filter" "switch-client -c \"$current_client\" -t '%%'"
  fi
  exit 0
fi

# Outside the popup: a normal work-session chooser. Exclude every agent-hub
# session — this plugin's `agents-*`, plus a sibling/legacy acp-hub (`acp-*`)
# and the pre-rename `vz-*` — so orphan hub sessions never pollute the list.
work_filter="#{?#{m/r:^(${prefix}|acp|vz)-,#{session_name}},0,1}"
tmux choose-tree -Zs -f "$work_filter"
