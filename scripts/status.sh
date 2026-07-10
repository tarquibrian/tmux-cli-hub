#!/usr/bin/env sh

script_dir="$(cd "$(dirname "$0")" && pwd)"
. "$script_dir/lib.sh"

prefix="$(tmux_option @cli_hub_session_prefix agents)"
active_secs="$(tmux_option @cli_hub_active_secs 10)"
now="$(date +%s)"

# Best-effort, poll-on-demand status. There is no protocol behind a raw CLI, so
# each signal carries a confidence and the strong ones win:
#   dead        (high)  pane process gone
#   exited      (high)  agent CLI quit; the window dropped to a shell prompt
#   needs-input (med)   pane title mentions a permission / approval prompt
#   active      (low)   produced output within @cli_hub_active_secs
#   running     (low)   alive, nothing else known
is_shell_command() {
  case "$1" in
    sh|bash|zsh|fish|dash|ksh|ksh93|mksh|tcsh|csh|ash|-sh|-bash|-zsh) return 0 ;;
    *) return 1 ;;
  esac
}

tmux list-windows -a -F "#{session_name}|#{window_id}|#{window_name}|#{pane_id}|#{pane_dead}|#{pane_title}|#{window_activity}|#{pane_current_command}|#{@cli_hub_provider}|#{@cli_hub_command}" 2>/dev/null |
while IFS='|' read -r session window_id window_name pane_id pane_dead pane_title window_activity current_command provider command; do
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

  # Strong signals (dead / exited) are checked first so they win over the weak
  # activity/title hints.
  status="running"

  if [ "$pane_dead" = "1" ]; then
    status="dead"
  elif is_shell_command "$current_command"; then
    # The launched CLI exited; the window is now sitting at a shell prompt.
    status="exited"
  elif printf "%s" "$pane_title" | grep -Eiq "permission|approve|approval|confirm|allow|trust|\(y/n\)"; then
    status="needs-input"
  elif [ -n "$window_activity" ] && [ "$((now - window_activity))" -le "$active_secs" ] 2>/dev/null; then
    status="active"
  fi

  tmux set-window-option -t "$window_id" -q @cli_hub_status "$status"
  tmux set-window-option -t "$window_id" -q @cli_hub_title "$pane_title"
done
