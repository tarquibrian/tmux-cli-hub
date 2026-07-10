#!/usr/bin/env sh

# Agent lifecycle: close one agent, kill a whole project's agents, or prune the
# dead ones. Uses tmux's native display-menu / choose-tree — no extra deps.

action="$1"
shift 2>/dev/null

script_dir="$(cd "$(dirname "$0")" && pwd)"
. "$script_dir/lib.sh"

prefix="$(tmux_option @cli_hub_session_prefix agents)"

case "$action" in
  kill-window)
    target="$1"
    [ -n "$target" ] || exit 0
    tmux kill-window -t "$target" 2>/dev/null
    ;;

  prune)
    dead="$(tmux list-panes -a -F "#{session_name}|#{window_id}|#{pane_dead}" 2>/dev/null |
      awk -F'|' -v p="$prefix" '$1 ~ "^"p"-" && $3 == 1 {print $2}')"
    n=0
    for w in $dead; do
      tmux kill-window -t "$w" 2>/dev/null && n=$((n + 1))
    done
    tmux display-message "cli-hub: pruned $n dead agent window(s)"
    ;;

  choose)
    client="$1"
    pane="$2"

    if ! tmux list-sessions -F "#{session_name}" 2>/dev/null | grep -Eq "^${prefix}-"; then
      tmux display-message "cli-hub: no agents to close"
      exit 0
    fi

    sh "$script_dir/status.sh"

    filter="#{m/r:^${prefix}-,#{session_name}}"
    format="#{@cli_hub_project_name} · #{window_name}  [#{@cli_hub_status}]"
    template="run-shell \"sh '$script_dir/close.sh' kill-window '%%'\""

    if [ -n "$pane" ] && pane_exists "$pane"; then
      tmux choose-tree -Zw -t "$pane" -f "$filter" -F "$format" "$template"
    else
      tmux choose-tree -Zw -f "$filter" -F "$format" "$template"
    fi
    ;;

  menu | "")
    client="$1"
    session="$2"
    pane="$3"
    window_id="$4"
    window_name="$5"
    current_path="$6"
    [ -n "$current_path" ] || current_path="$HOME"

    if is_agent_session "$session"; then
      tmux display-menu -c "$client" -T " cli-hub · $session " \
        "Close this agent ($window_name)" c "run-shell \"sh '$script_dir/close.sh' kill-window '$window_id'\"" \
        "Kill this project (all agents)"  k "confirm-before -p \"kill all agents in $session? (y/n)\" \"kill-session -t '$session'\"" \
        "" \
        "Prune dead agents (all projects)" p "run-shell \"sh '$script_dir/close.sh' prune\"" \
        "" \
        "Cancel" q ""
      exit 0
    fi

    # Outside a popup: offer this project's session (if any) plus global actions.
    project_path="$(project_root "$current_path")"
    project_session="$(agent_session_name "$project_path")"

    if tmux has-session -t "=$project_session" 2>/dev/null; then
      tmux display-menu -c "$client" -T " cli-hub " \
        "Close an agent…" c "run-shell \"sh '$script_dir/close.sh' choose '$client' '$pane'\"" \
        "Kill this project ($project_session)" k "confirm-before -p \"kill all agents in $project_session? (y/n)\" \"kill-session -t '$project_session'\"" \
        "" \
        "Prune dead agents (all projects)" p "run-shell \"sh '$script_dir/close.sh' prune\"" \
        "" \
        "Cancel" q ""
    else
      tmux display-menu -c "$client" -T " cli-hub " \
        "Close an agent…" c "run-shell \"sh '$script_dir/close.sh' choose '$client' '$pane'\"" \
        "" \
        "Prune dead agents (all projects)" p "run-shell \"sh '$script_dir/close.sh' prune\"" \
        "" \
        "Cancel" q ""
    fi
    ;;
esac
