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

agent_session_name() {
  prefix="$(tmux_option @cli_hub_session_prefix agents)"
  printf "%s-%s" "$prefix" "$(path_hash "$1")"
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

popup_width() {
  tmux_option @cli_hub_popup_width "80%"
}

popup_height() {
  tmux_option @cli_hub_popup_height "80%"
}
