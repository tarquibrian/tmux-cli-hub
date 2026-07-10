# tmux-cli-hub

A lightweight popup hub for AI CLI agents in tmux. Launch Claude Code, Codex,
Gemini, opencode, or any CLI-based agent in a persistent, per-project tmux
session, shown as a popup.

- **Persistent** — each project gets its own tmux session; close the popup,
  the agent keeps running in the background as a normal tmux session.
- **Configurable** — pick your own keybindings and CLI commands per agent,
  add new agents by adding a config line, no forking required.
- **Zero dependencies** — pure tmux + POSIX sh. No Node, no daemon, no
  protocol adapter.
- **Multi-project** — one keypress reopens the right session for whatever
  project you're currently in.

This is the lite counterpart to
[tmux-acp-hub](https://github.com/tarquibrian/tmux-acp-hub): acp-hub
runs agents through the Agent Client Protocol behind a persistent Node
daemon (rich rendering, true status, saved transcripts). tmux-cli-hub instead
just runs the agent's own CLI directly inside a tmux session — no protocol,
no daemon, works with anything you can run from a terminal.

## Requirements

| Need | Version / note |
|------|-----------------|
| tmux | >= 3.2 (uses `display-popup`) |
| sh | POSIX sh (dash, bash, or zsh's sh mode) |
| `md5sum` or `md5` | for project-path hashing — standard on macOS/Linux |

Each configured CLI is invoked directly — install and authenticate it
however you normally would; it just needs to be on `PATH`.

## Installation

With [TPM](https://github.com/tmux-plugins/tpm), add to `~/.tmux.conf`:

```tmux
set -g @plugin 'tarquibrian/tmux-cli-hub'
```

Then prefix + <kbd>I</kbd> to install.

Manual:

```sh
git clone https://github.com/tarquibrian/tmux-cli-hub ~/.config/tmux/plugins/tmux-cli-hub
```

```tmux
run '~/.config/tmux/plugins/tmux-cli-hub/cli-hub.tmux'
```

## Keybindings

Default (prefix + key):

| Key | Action |
|-----|--------|
| `0` | Open/create the Claude Code popup |
| `9` | Open/create the Codex popup |
| `8` | Open/create the Antigravity popup |
| `o` | Open/create the opencode popup |
| `g` | Open/create the Gemini popup |
| `)` | Claude Code, auto-approve mode |
| `(` | Codex, auto-approve mode |
| `*` | Antigravity, auto-approve mode |
| `m` | Toggle — hide the popup / return to it |
| `s` | Session chooser (normal tmux sessions; agent sessions filtered out) |
| `y` | Agent menu — every running agent across every project, with status |

**Security note:** `)`, `(`, and `*` launch the agent with its permission
prompts disabled (`--dangerously-skip-permissions` /
`--dangerously-bypass-approvals-and-sandbox`). In that mode the agent can run
commands and edit files without asking first. Only use these keys in
projects and environments you trust.

## Configuring agents

Each agent is one tmux option, read in order starting at `@cli_hub_agent_1`:

```
@cli_hub_agent_N = "name:key:command[:autokey:autocommand]"
```

- `name` — label shown in the menu/status.
- `key` — prefix-key that opens/creates this agent's popup.
- `command` — the CLI command to run.
- `autokey` / `autocommand` *(optional)* — a second key bound to the same
  agent in its auto-approve/yolo mode.

Defaults:

```tmux
set -g @cli_hub_agent_1 "claude:0:claude:):claude --dangerously-skip-permissions"
set -g @cli_hub_agent_2 "codex:9:codex:(:codex --dangerously-bypass-approvals-and-sandbox"
set -g @cli_hub_agent_3 "antigravity:8:agy:*:agy --dangerously-skip-permissions"
set -g @cli_hub_agent_4 "opencode:o:opencode"
set -g @cli_hub_agent_5 "gemini:g:gemini"
```

To customize, set these **before** the plugin's `run` line in `tmux.conf`:

```tmux
# Reorder / remap a default
set -g @cli_hub_agent_1 "codex:9:codex"

# Add a new agent — any CLI works
set -g @cli_hub_agent_6 "aider:a:aider --yes"

# Disable a default slot
set -g @cli_hub_agent_4 ""
```

Slots are scanned `1..@cli_hub_agent_max_slots` (default `20` — raise it if
you need more than 20 agents). Gaps are fine: disabling slot 4 doesn't stop
slot 5 from loading.

## How it works

- Each project gets a dedicated tmux session named `<prefix>-<hash>`
  (`@cli_hub_session_prefix`, default `agents`; the hash is derived from the
  project's git root, or the current directory if it isn't a git repo).
- Opening an agent creates a window in that session — or reuses it if
  already running — and shows it via `display-popup`. Closing the popup
  (`m`) doesn't kill the agent; it keeps running, detached, until you reopen
  or kill it yourself.
- The agent menu (`y`) lists every window across every `<prefix>-*` session
  with a best-effort status: `dead` (pane exited) and `active` (recent
  output, last 15s) are reliable for any CLI. `ready` / `needs-input` are
  opportunistic — they only fire if the CLI puts a matching word in its
  terminal title, which today is true for Gemini (`Ready`) but not for
  Claude Code, Codex, opencode, or Antigravity's own CLIs, which don't set a
  descriptive title. Those just show as `running`/`active`/`dead`. This is a
  pane-title heuristic, not a real protocol — there's no guarantee a given
  CLI's title reflects its actual state.

## Configuration (tmux options)

| Option | Default | Meaning |
|--------|---------|---------|
| `@cli_hub_session_prefix` | `agents` | Prefix for the per-project tmux sessions |
| `@cli_hub_hash_length` | `8` | Hash length used in the session name |
| `@cli_hub_popup_width` | `80%` | Popup width |
| `@cli_hub_popup_height` | `80%` | Popup height |
| `@cli_hub_agent_max_slots` | `20` | How many `@cli_hub_agent_N` slots to scan |

## Uninstall

Remove the `run` line from `tmux.conf`. Agent sessions aren't killed
automatically — list them with `tmux ls` and kill what you don't need with
`tmux kill-session -t <prefix>-<hash>`.

## License

MIT
