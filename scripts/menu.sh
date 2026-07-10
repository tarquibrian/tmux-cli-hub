#!/usr/bin/env sh

current_client="$1"
current_session="$2"
current_path="$3"
target_pane="$4"

script_dir="$(cd "$(dirname "$0")" && pwd)"
. "$script_dir/lib.sh"

prefix="$(tmux_option @cli_hub_session_prefix agents)"

if ! tmux list-sessions -F "#{session_name}" 2>/dev/null | grep -Eq "^${prefix}-"; then
  tmux display-message "No agent sessions"
  exit 0
fi

sh "$script_dir/status.sh"

filter="#{m/r:^${prefix}-,#{session_name}}"
format="#{session_name}:#{window_index} #{window_name} #{@cli_hub_provider} #{@cli_hub_status} #{@cli_hub_project_name} #{pane_title}"
template="run-shell 'sh \"$script_dir/attach.sh\" \"$current_client\" \"$current_session\" \"%%\" \"$target_pane\"'"

if [ -n "$target_pane" ] && pane_exists "$target_pane"; then
  tmux choose-tree -Zw -t "$target_pane" -f "$filter" -F "$format" "$template"
else
  tmux choose-tree -Zw -f "$filter" -F "$format" "$template"
fi
