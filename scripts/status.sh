#!/usr/bin/env sh

script_dir="$(cd "$(dirname "$0")" && pwd)"
. "$script_dir/lib.sh"

prefix="$(tmux_option @cli_hub_session_prefix agents)"
now="$(date +%s)"

tmux list-windows -a -F "#{session_name}|#{window_id}|#{window_name}|#{pane_id}|#{pane_dead}|#{pane_title}|#{window_activity}|#{@cli_hub_provider}|#{@cli_hub_command}" 2>/dev/null |
while IFS='|' read -r session window_id window_name pane_id pane_dead pane_title window_activity provider command; do
  case "$session" in
    "$prefix"-*) ;;
    *) continue ;;
  esac

  project_path="$(tmux show-option -t "$session" -qv @cli_hub_project_path)"
  [ -n "$project_path" ] || project_path="$(tmux display-message -p -t "$window_id" "#{pane_current_path}" 2>/dev/null)"
  [ -n "$project_path" ] && set_session_metadata "$session" "$project_path" "$(path_hash "$project_path")"

  if [ -z "$provider" ]; then
    provider="$(agent_provider "$window_name" "$command")"
    mode="$(agent_mode "$window_name")"
    tmux set-window-option -t "$window_id" -q @cli_hub_agent_name "$window_name"
    tmux set-window-option -t "$window_id" -q @cli_hub_provider "$provider"
    tmux set-window-option -t "$window_id" -q @cli_hub_mode "$mode"
  fi

  status="running"
  confidence="low"

  if [ "$pane_dead" = "1" ]; then
    status="dead"
    confidence="high"
  elif printf "%s" "$pane_title" | grep -Eiq "ready|idle"; then
    status="ready"
    confidence="medium"
  elif printf "%s" "$pane_title" | grep -Eiq "permission|approve|approval|confirm"; then
    status="needs-input"
    confidence="medium"
  elif [ -n "$window_activity" ] && [ "$((now - window_activity))" -le 15 ] 2>/dev/null; then
    status="active"
    confidence="medium"
  fi

  tmux set-window-option -t "$window_id" -q @cli_hub_status "$status"
  tmux set-window-option -t "$window_id" -q @cli_hub_status_confidence "$confidence"
  tmux set-window-option -t "$window_id" -q @cli_hub_title "$pane_title"
  tmux set-window-option -t "$window_id" -q @cli_hub_pane "$pane_id"
  tmux set-window-option -t "$window_id" -q @cli_hub_last_activity "$window_activity"
  tmux set-window-option -t "$window_id" -q @cli_hub_updated_at "$now"
done
