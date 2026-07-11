#!/usr/bin/env sh

agent_name="$1"
agent_command="$2"
current_path="$3"
current_session="$4"
target_client="$5"
target_pane="$6"

script_dir="$(cd "$(dirname "$0")" && pwd)"
. "$script_dir/lib.sh"

[ -n "$current_path" ] || current_path="$HOME"
launched_from_agent="false"

if is_agent_session "$current_session"; then
  launched_from_agent="true"
  session="$current_session"
  project_path="$(tmux show-option -t "$session" -qv @cli_hub_project_path)"
  [ -n "$project_path" ] || project_path="$current_path"
  project_hash="$(tmux show-option -t "$session" -qv @cli_hub_project_hash)"
  [ -n "$project_hash" ] || project_hash="$(path_hash "$project_path")"
else
  project_path="$(project_root "$current_path")"
  project_hash="$(path_hash "$project_path")"
  session="$(agent_session_name "$project_path")"
fi

# "=" forces an exact session-name match: without it tmux falls back to prefix
# matching, so a missing "cli-web" would silently resolve to a different
# project's "cli-web-9f72". Once the exact session exists (or is created here),
# later fuzzy targets resolve exact-first and are safe.
if ! tmux has-session -t "=$session" 2>/dev/null; then
  tmux new-session -d -s "$session" -n "$agent_name" -c "$project_path" "$agent_command"
elif ! window_exists "$session" "$agent_name"; then
  tmux new-window -d -t "$session:" -n "$agent_name" -c "$project_path" "$agent_command"
fi

set_session_metadata "$session" "$project_path" "$project_hash"
set_window_metadata "$session:$agent_name" "$agent_name" "$agent_command"

[ "$launched_from_agent" = "true" ] || set_popup_parent "$session" "$target_client" "$target_pane"
tmux select-window -t "$session:$agent_name"

if [ "$current_session" = "$session" ]; then
  tmux switch-client -c "$target_client" -t "$session"
  exit 0
fi

open_popup "$target_client" "$project_path" "$session" "$(project_name "$project_path") · $agent_name"
