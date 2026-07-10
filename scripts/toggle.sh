#!/usr/bin/env sh

target_client="$1"
current_session="$2"
current_path="$3"
target_pane="$4"

script_dir="$(cd "$(dirname "$0")" && pwd)"
. "$script_dir/lib.sh"

[ -n "$current_path" ] || current_path="$HOME"

if is_agent_session "$current_session"; then
  tmux set-option -gq @cli_hub_last "$current_session"
  tmux detach-client -t "$target_client"
  exit 0
fi

project_path="$(project_root "$current_path")"
project_hash="$(path_hash "$project_path")"
session="$(agent_session_name "$project_path")"

if tmux has-session -t "$session" 2>/dev/null; then
  set_session_metadata "$session" "$project_path" "$project_hash"
  set_popup_parent "$session" "$target_client" "$target_pane"
  tmux set-option -gq @cli_hub_last "$session"
  open_popup "$target_client" "$project_path" "$session" "$(project_name "$project_path") · agents"
  exit 0
fi

tmux display-message "No agent popup for this project"
