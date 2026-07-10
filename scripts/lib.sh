#!/usr/bin/env sh

tmux_option() {
  value="$(tmux show-option -gqv "$1" 2>/dev/null)"
  [ -n "$value" ] && printf "%s" "$value" || printf "%s" "$2"
}

project_root() {
  git -C "$1" rev-parse --show-toplevel 2>/dev/null || printf "%s" "$1"
}

project_name() {
  basename "$1"
}

path_hash() {
  hash_length="$(tmux_option @cli_hub_hash_length 8)"

  if command -v md5sum >/dev/null 2>&1; then
    printf "%s" "$1" | md5sum | cut -c1-"$hash_length"
  else
    printf "%s" "$1" | md5 | cut -c1-"$hash_length"
  fi
}

# tmux session names cannot contain "." or ":" and choke on spaces; fold every
# other character to "-" and squeeze/trim so a project basename becomes a safe,
# readable session component.
sanitize_component() {
  printf "%s" "$1" | tr -c 'A-Za-z0-9_-' '-' | sed -e 's/-\{2,\}/-/g' -e 's/^-//' -e 's/-$//'
}

# Readable session name: agents-<project> (e.g. agents-tmux-cli-hub). The short
# path hash is appended only when a DIFFERENT project already owns the bare
# name, so each project still resolves to a single stable session.
agent_session_name() {
  prefix="$(tmux_option @cli_hub_session_prefix agents)"
  base="$(sanitize_component "$(project_name "$1")")"
  [ -n "$base" ] || base="project"

  candidate="$prefix-$base"
  if tmux has-session -t "=$candidate" 2>/dev/null; then
    # show-option does not honour the "=" exact-match prefix; the exact session
    # is known to exist here, so a plain target resolves to it.
    owner_path="$(tmux show-option -t "$candidate" -qv @cli_hub_project_path)"
    if [ -n "$owner_path" ] && [ "$owner_path" != "$1" ]; then
      candidate="$prefix-$base-$(path_hash "$1" | cut -c1-4)"
    fi
  fi

  printf "%s" "$candidate"
}

is_agent_session() {
  prefix="$(tmux_option @cli_hub_session_prefix agents)"

  case "$1" in
    "$prefix"-*) return 0 ;;
    *) return 1 ;;
  esac
}

window_exists() {
  tmux list-windows -t "$1" -F "#{window_name}" 2>/dev/null | grep -Fxq "$2"
}

client_exists() {
  tmux list-clients -F "#{client_name}" 2>/dev/null | grep -Fxq "$1"
}

pane_exists() {
  tmux list-panes -a -F "#{pane_id}" 2>/dev/null | grep -Fxq "$1"
}

set_popup_parent() {
  [ -n "$1" ] || return 0
  [ -n "$2" ] || return 0

  tmux set-option -t "$1" -q @cli_hub_parent_client "$2"

  if [ -n "$3" ]; then
    tmux set-option -t "$1" -q @cli_hub_parent_pane "$3"
  fi
}

agent_provider() {
  name="$1"
  command="$2"

  case "$name $command" in
    *claude*) printf "claude" ;;
    *codex*) printf "codex" ;;
    *antigravity*|*agy*) printf "antigravity" ;;
    *gemini*) printf "gemini" ;;
    *opencode*) printf "opencode" ;;
    *) printf "unknown" ;;
  esac
}

agent_mode() {
  case "$1" in
    *auto*) printf "auto" ;;
    *) printf "normal" ;;
  esac
}

set_session_metadata() {
  session="$1"
  project_path="$2"
  project_hash="$3"
  now="$(date +%s)"

  tmux set-option -t "$session" -q @cli_hub_project_path "$project_path"
  tmux set-option -t "$session" -q @cli_hub_project_name "$(project_name "$project_path")"
  tmux set-option -t "$session" -q @cli_hub_project_hash "$project_hash"
  tmux set-option -t "$session" -q @cli_hub_updated_at "$now"

  [ -n "$(tmux show-option -t "$session" -qv @cli_hub_created_at)" ] || \
    tmux set-option -t "$session" -q @cli_hub_created_at "$now"
}

set_window_metadata() {
  target="$1"
  agent_name="$2"
  agent_command="$3"
  provider="$(agent_provider "$agent_name" "$agent_command")"
  mode="$(agent_mode "$agent_name")"
  now="$(date +%s)"

  tmux set-window-option -t "$target" -q @cli_hub_agent_name "$agent_name"
  tmux set-window-option -t "$target" -q @cli_hub_command "$agent_command"
  tmux set-window-option -t "$target" -q @cli_hub_provider "$provider"
  tmux set-window-option -t "$target" -q @cli_hub_mode "$mode"
  tmux set-window-option -t "$target" -q @cli_hub_status "running"
  tmux set-window-option -t "$target" -q @cli_hub_status_confidence "low"
  tmux set-window-option -t "$target" -q @cli_hub_updated_at "$now"

  [ -n "$(tmux show-options -w -t "$target" -qv @cli_hub_created_at)" ] || \
    tmux set-window-option -t "$target" -q @cli_hub_created_at "$now"
}

status_glyph_for() {
  case "$1" in
    dead)        printf '%s' '✗' ;;
    exited)      printf '%s' '⊘' ;;
    needs-input) printf '%s' '▲' ;;
    active)      printf '%s' '●' ;;
    *)           printf '%s' '·' ;;
  esac
}

# choose-tree -F format for the agent switcher (`s`) and agent menu (`y`),
# expanded window mode. Columns: provider icon · agent name · status · [yolo] ·
# last activity · the CLI's own pane title. Colors are emitted as #[fg=...]
# directives *returned* by the conditionals (tmux can't put a #{?} inside a
# style spec). Session parents render as "▣ <project>  <path>".
agent_choose_format() {
  icon='#{?#{==:#{@cli_hub_provider},claude},❋,#{?#{==:#{@cli_hub_provider},codex},⬡,#{?#{==:#{@cli_hub_provider},gemini},✦,#{?#{==:#{@cli_hub_provider},opencode},◉,#{?#{==:#{@cli_hub_provider},antigravity},✱,◆}}}}}'
  istyle='#{?#{==:#{@cli_hub_provider},claude},#[fg=colour173],#{?#{==:#{@cli_hub_provider},codex},#[fg=colour39],#{?#{==:#{@cli_hub_provider},gemini},#[fg=colour33],#{?#{==:#{@cli_hub_provider},opencode},#[fg=colour170],#{?#{==:#{@cli_hub_provider},antigravity},#[fg=colour208],#[fg=colour244]}}}}}'
  sglyph='#{?#{==:#{@cli_hub_status},dead},✗,#{?#{==:#{@cli_hub_status},exited},⊘,#{?#{==:#{@cli_hub_status},needs-input},▲,#{?#{==:#{@cli_hub_status},active},●,·}}}}'
  sstyle='#{?#{==:#{@cli_hub_status},dead},#[fg=red],#{?#{==:#{@cli_hub_status},needs-input},#[fg=yellow],#{?#{==:#{@cli_hub_status},active},#[fg=green],#[fg=colour244]}}}'
  yolo='#{?#{==:#{@cli_hub_mode},auto},#[fg=yellow]⚡ #[default],}'
  name='#{?#{@cli_hub_agent_name},#{@cli_hub_agent_name},#{window_name}}'
  info='#{=/38/…:#{?#{pane_title},#{pane_title},#{@cli_hub_title}}}'

  wline="${istyle}${icon}#[default] #[bold]#{p14:${name}}#[default] ${sstyle}${sglyph} #{p10:#{@cli_hub_status}}#[default] ${yolo}#[fg=colour244]#{t/f/%R:window_activity}  #[fg=colour244]${info}#[default]"
  sline='#[bold]▣ #{?#{@cli_hub_project_name},#{@cli_hub_project_name},#{session_name}}#[default]  #[fg=colour244]#{@cli_hub_project_path}#[default]'

  printf '%s' "#{?window_format,${wline},${sline}}"
}

popup_width() {
  tmux_option @cli_hub_popup_width "80%"
}

popup_height() {
  tmux_option @cli_hub_popup_height "80%"
}

# display-popup grew a -T title flag in tmux 3.3; feature-detect so the plugin
# keeps working on 3.2 (the display-popup floor) without the title.
tmux_supports_popup_title() {
  version="$(tmux -V | sed -E 's/[^0-9.]//g')"
  major="${version%%.*}"
  rest="${version#*.}"
  minor="${rest%%.*}"
  [ -n "$major" ] || return 1
  [ "$major" -gt 3 ] 2>/dev/null && return 0
  [ "$major" -eq 3 ] 2>/dev/null && [ "${minor:-0}" -ge 3 ] 2>/dev/null && return 0
  return 1
}

# Open the project's agent session in a popup, titled "<project> · <label>"
# when the running tmux supports popup titles.
# $1 client  $2 dir  $3 session  $4 title
open_popup() {
  if tmux_supports_popup_title; then
    tmux display-popup -c "$1" -d "$2" -w "$(popup_width)" -h "$(popup_height)" \
      -T " $4 " -E "tmux attach-session -t \"$3\""
  else
    tmux display-popup -c "$1" -d "$2" -w "$(popup_width)" -h "$(popup_height)" \
      -E "tmux attach-session -t \"$3\""
  fi
}
