#!/usr/bin/env sh

current_client="$1"
current_session="$2"

script_dir="$(cd "$(dirname "$0")" && pwd)"
. "$script_dir/lib.sh"

prefix="$(tmux_option @cli_hub_session_prefix agents)"
normal_session_filter="#{?#{m/r:^${prefix}-,#{session_name}},0,1}"

detach_current_client() {
  [ -n "$current_client" ] || return 0
  [ "$current_client" = "$1" ] && return 0
  tmux detach-client -t "$current_client"
}

if is_agent_session "$current_session"; then
  parent_client="$(tmux show-option -t "$current_session" -qv @cli_hub_parent_client)"
  parent_pane="$(tmux show-option -t "$current_session" -qv @cli_hub_parent_pane)"

  tmux set-option -gq @cli_hub_last "$current_session"

  if [ -n "$parent_client" ] && client_exists "$parent_client" && [ -n "$parent_pane" ] && pane_exists "$parent_pane"; then
    tmux choose-tree -Zs -t "$parent_pane" -f "$normal_session_filter" "switch-client -c \"$parent_client\" -t '%%'"
    detach_current_client "$parent_client"
    exit 0
  fi

  if [ -n "$parent_client" ] && client_exists "$parent_client"; then
    prefix="$(tmux show-option -gqv prefix)"
    tmux send-keys -c "$parent_client" -K "$prefix" s
    detach_current_client "$parent_client"
    exit 0
  fi

  tmux display-message "No parent tmux client for agent popup"
  exit 1
fi

tmux choose-tree -Zs -f "$normal_session_filter"
