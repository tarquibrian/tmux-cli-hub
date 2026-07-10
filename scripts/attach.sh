#!/usr/bin/env sh

target_client="$1"
current_session="$2"
selected_target="$3"
target_pane="$4"

script_dir="$(cd "$(dirname "$0")" && pwd)"
. "$script_dir/lib.sh"

[ -n "$selected_target" ] || exit 0

session="$(tmux display-message -p -t "$selected_target" "#{session_name}" 2>/dev/null)"
window_id="$(tmux display-message -p -t "$selected_target" "#{window_id}" 2>/dev/null)"

if [ -z "$session" ] || [ -z "$window_id" ]; then
  tmux display-message "Invalid agent target: $selected_target"
  exit 1
fi

project_path="$(tmux show-option -t "$session" -qv @cli_hub_project_path)"
[ -n "$project_path" ] || project_path="$(tmux display-message -p -t "$window_id" "#{pane_current_path}" 2>/dev/null)"
[ -n "$project_path" ] || project_path="$HOME"

tmux select-window -t "$window_id"
tmux set-option -gq @cli_hub_last "$window_id"

if is_agent_session "$current_session"; then
  parent_client="$(tmux show-option -t "$current_session" -qv @cli_hub_parent_client)"
  parent_pane="$(tmux show-option -t "$current_session" -qv @cli_hub_parent_pane)"
  set_popup_parent "$session" "$parent_client" "$parent_pane"
  tmux switch-client -c "$target_client" -t "$session"
  exit 0
fi

window_name="$(tmux display-message -p -t "$window_id" "#{window_name}" 2>/dev/null)"
set_popup_parent "$session" "$target_client" "$target_pane"
open_popup "$target_client" "$project_path" "$session" "$(project_name "$project_path") · ${window_name:-agents}"
