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
    sh|bash|zsh|fish|dash|ksh|ksh93|mksh|tcsh|csh|ash|-sh|-bash|-zsh|-fish) return 0 ;;
    *) return 1 ;;
  esac
}

# One list-windows drives the whole poll. #{pane_title} is the only field an
# agent controls and may contain the "|" delimiter, so it goes LAST — the
# final `read` variable absorbs the rest of the line, separators included.
# #{@cli_hub_project_path} resolves the session-scoped option from the window
# context, saving a show-option round-trip per window; #{@cli_hub_status} lets
# us skip the write when nothing changed, so a steady-state poll costs a
# single tmux call in total.
tmux list-windows -a -F "#{session_name}|#{window_id}|#{window_name}|#{pane_dead}|#{window_activity}|#{pane_current_command}|#{@cli_hub_provider}|#{@cli_hub_status}|#{@cli_hub_project_path}|#{pane_title}" 2>/dev/null |
while IFS='|' read -r session window_id window_name pane_dead window_activity current_command provider old_status sess_path pane_title; do
  case "$session" in
    "$prefix"-*) ;;
    *) continue ;;
  esac

  # Heal missing session metadata (adopted/foreign sessions only).
  if [ -z "$sess_path" ]; then
    sess_path="$(tmux display-message -p -t "$window_id" "#{pane_current_path}" 2>/dev/null)"
    [ -n "$sess_path" ] && set_session_metadata "$session" "$sess_path" "$(path_hash "$sess_path")"
  fi

  # Heal missing window metadata, one tmux call for the three options.
  if [ -z "$provider" ]; then
    provider="$(agent_provider "$window_name" "")"
    tmux set-window-option -t "$window_id" -q @cli_hub_agent_name "$window_name" \; \
         set-window-option -t "$window_id" -q @cli_hub_provider "$provider" \; \
         set-window-option -t "$window_id" -q @cli_hub_mode "$(agent_mode "$window_name")"
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

  [ "$status" = "$old_status" ] || \
    tmux set-window-option -t "$window_id" -q @cli_hub_status "$status"
done
