#!/usr/bin/env sh

# Unified agent overlay (prefix + M): for the current project, one native
# display-menu that lists the live agents (switch to them), plus "New" and
# "Resume" launchers for every configured provider. cli-hub keeps no history
# of its own — "Resume" just launches the CLI in its own resume mode
# (@cli_hub_resume_<provider>) and the CLI shows its own past-session picker.

current_client="$1"
current_session="$2"
current_pane="$3"
current_path="$4"

script_dir="$(cd "$(dirname "$0")" && pwd)"
. "$script_dir/lib.sh"

[ -n "$current_path" ] || current_path="$HOME"

if is_agent_session "$current_session"; then
  project_path="$(tmux show-option -t "$current_session" -qv @cli_hub_project_path)"
  [ -n "$project_path" ] || project_path="$current_path"
else
  project_path="$(project_root "$current_path")"
fi
project_session="$(agent_session_name "$project_path")"
project_label="$(project_name "$project_path")"

# Refresh status so the live rows carry an up-to-date glyph.
sh "$script_dir/status.sh"

live_count="$(tmux list-windows -t "$project_session" -F x 2>/dev/null | wc -l | tr -d ' ')"

# Title doubles as the "no agents yet" hint when the project has none. The menu
# is anchored bottom-left (-x 0 -y S) instead of the default centre.
if [ "${live_count:-0}" -gt 0 ]; then
  title=" cli-hub · $project_label "
else
  title=" cli-hub · $project_label — no agents yet, start one: "
fi
set -- -c "$current_client" -x 0 -y S -T "$title"

# --- Live agents in this project (switch to the window) ---
if [ "${live_count:-0}" -gt 0 ]; then
  while IFS='|' read -r wid wname wstatus; do
    [ -n "$wid" ] || continue
    label="$(status_glyph_for "$wstatus") $wname  [$wstatus]"
    cmd="run-shell \"sh '$script_dir/attach.sh' '$current_client' '$current_session' '$wid' '$current_pane'\""
    set -- "$@" "$label" "" "$cmd"
  done <<EOF
$(tmux list-windows -t "$project_session" -F '#{window_id}|#{window_name}|#{@cli_hub_status}' 2>/dev/null)
EOF
  set -- "$@" ""
fi

# --- New / Resume per configured provider ---
max_slots="$(tmux_option @cli_hub_agent_max_slots 20)"
slot=1
while [ "$slot" -le "$max_slots" ]; do
  entry="$(tmux show-option -gqv "@cli_hub_agent_$slot")"
  slot=$((slot + 1))
  [ -n "$entry" ] || continue

  name="$(printf '%s' "$entry" | cut -d: -f1)"
  command="$(printf '%s' "$entry" | cut -d: -f3)"
  [ -n "$name" ] && [ -n "$command" ] || continue

  new_cmd="run-shell \"sh '$script_dir/open.sh' '$name' '$command' '$project_path' '$current_session' '$current_client' '$current_pane'\""
  set -- "$@" "＋ New $name" "" "$new_cmd"

  provider="$(agent_provider "$name" "$command")"
  resume_cmd="$(tmux_option "@cli_hub_resume_$provider" "")"
  if [ -n "$resume_cmd" ]; then
    res_open="run-shell \"sh '$script_dir/open.sh' '${name}-resume' '$resume_cmd' '$project_path' '$current_session' '$current_client' '$current_pane'\""
    set -- "$@" "⟲ Resume $name" "" "$res_open"
  fi
done

set -- "$@" ""
set -- "$@" "All agents (every project)…" "a" "run-shell \"sh '$script_dir/menu.sh' '$current_client' '$current_session' '$current_path' '$current_pane'\""
set -- "$@" "Cancel" "q" ""

tmux display-menu "$@"
